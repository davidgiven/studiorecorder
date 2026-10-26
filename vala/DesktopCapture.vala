namespace Studio
{
    /** Describes a monitor rectangle in X11 desktop coordinates for primary-monitor screen capture. */
    public class Geometry : GLib.Object
    {
        public uint x;
        public uint y;
        public uint width;
        public uint height;

        /** Store the primary monitor rectangle in X11 desktop coordinates. */
        public Geometry (uint x, uint y, uint width, uint height)
        {
            this.x = x;
            this.y = y;
            this.width = width;
            this.height = height;
        }
    }

    /** Parse xrandr output, accepting a lone active display when no primary is marked. */
    public Geometry primary_monitor_geometry(string layout) throws Error
    {
        var expression = new Regex("^\\S+ connected (primary )?([0-9]+)x([0-9]+)\\+([0-9]+)\\+([0-9]+)(?:\\s|$)");
        Geometry? only = null;
        uint count = 0;

        // A marked primary takes precedence regardless of connector order or position.
        foreach (string line in layout.split("\n"))
        {
            MatchInfo match;
            if (!expression.match(line, 0, out match))
                continue;
            var geometry = new Geometry(
                /* x= */ uint.parse(match.fetch(4)),
                /* y= */ uint.parse(match.fetch(5)),
                /* width= */ uint.parse(match.fetch(2)),
                /* height= */ uint.parse(match.fetch(3)));
            if (match.fetch(1) == "primary ")
                return geometry;
            only = geometry;
            count++;
        }

        // A lone display is safe to select; multiple unmarked displays are ambiguous.
        if (count == 1)
            return only;
        throw new RecorderError.FAILED("No active primary monitor configured. Set a primary monitor in display settings.");
    }

    /** Route required computer audio to the default output monitor rather than the microphone. */
    public Input computer_audio()
    {
        var audio = new Input("Computer audio", "desktop-audio");
        audio.audio_name = "@DEFAULT_MONITOR@";
        return audio;
    }

    /** Prepares required desktop inputs and owns the Wayland portal session and remote descriptor until shutdown. */
    public class DesktopCapture : GLib.Object
    {
        private const string BUS = "org.freedesktop.portal.Desktop";
        private const string PATH = "/org/freedesktop/portal/desktop";
        private const string SCREENCAST = "org.freedesktop.portal.ScreenCast";
        private DBusConnection? connection;
        private string? session;
        private string? pending_request;
        private int remote_fd = -1;
        private Cancellable cancellable = new Cancellable();
        private uint response_subscription;
        private uint closed_subscription;
        private bool closed;

        /** Report unexpected closure of an established desktop-sharing session. */
        public signal void failed(string message);

        /** Prepare required desktop inputs using the Wayland chooser or the X11 primary monitor. */
        public async Camera prepare() throws Error
        {
            if (Environment.get_variable("WAYLAND_DISPLAY") != null ||
                Environment.get_variable("XDG_SESSION_TYPE") == "wayland")
                return yield prepare_wayland();
            if (Environment.get_variable("DISPLAY") == null)
                throw new RecorderError.FAILED("Screen capture requires an X11 or Wayland desktop session.");

            // Query X11 asynchronously and bound an unresponsive xrandr process.
            var process = new Subprocess.newv(
                /* argv= */ new string[] { "xrandr", "--query" },
                /* flags= */ SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            var query_cancel = new Cancellable();
            uint timeout = Timeout.add_seconds(
                /* interval= */ 5,
                /* function= */ () =>
                {
                    query_cancel.cancel();
                    process.force_exit();
                    return Source.REMOVE;
                });
            string output;
            try
            {
                yield process.communicate_utf8_async(null, query_cancel, out output, null);
            }
            finally
            {
                Source.remove(timeout);
            }
            if (!process.get_successful())
                throw new RecorderError.FAILED("Cannot query primary monitor with xrandr.");

            // Restrict screen capture to the chosen monitor rectangle.
            var geometry = primary_monitor_geometry(output);
            var screen = new Input("Screen (primary)", "desktop-screen");
            screen.factory = "ximagesrc";
            screen.x = geometry.x;
            screen.y = geometry.y;
            screen.width = geometry.width;
            screen.height = geometry.height;
            return new Camera(screen, computer_audio());
        }

        /** Build a portal options dictionary with an optional request token. */
        private static Variant options(string? token = null)
        {
            var builder = new VariantBuilder(new VariantType("a{sv}"));
            if (token != null)
                builder.add("{sv}", "handle_token", new Variant.string(token));
            return builder.end();
        }

        // Subscribe before invoking a portal method: Response can arrive before its reply.

        /** Await a portal response without losing signals that arrive before the method reply. */
        private async Variant request(string method) throws Error
        {
            string token = "studio_" + Uuid.string_random().replace("-", "");
            string sender = connection.get_unique_name().substring(1).replace(".", "_");
            pending_request = PATH + "/request/" + sender + "/" + token;
            Variant? response = null;
            bool waiting = false;
            SourceFunc resume = request.callback;

            // Listen before invoking the method because portal responses may arrive first.
            response_subscription = connection.signal_subscribe(
                /* sender= */ BUS,
                /* interface_name= */ "org.freedesktop.portal.Request",
                /* member= */ "Response",
                /* object_path= */ pending_request,
                /* arg0= */ null,
                /* flags= */ DBusSignalFlags.NONE,
                /* callback= */ (conn, sender_name, path, iface, name, parameters) =>
                {
                    response = parameters;
                    if (waiting)
                    {
                        waiting = false;
                        resume();
                    }
                });

            // Wake a suspended request on cancellation without disconnecting inside its own handler.
            ulong cancel_handler = cancellable.cancelled.connect(
                /* handler= */ () =>
                {
                    if (waiting)
                    {
                        waiting = false;
                        // Disconnecting a cancellable handler from inside itself can deadlock.
                        Idle.add(
                            /* function= */ () =>
                            {
                                resume();
                                return Source.REMOVE;
                            });
                    }
                });
            try
            {
                // Build the method-specific arguments, always requesting only one monitor.
                var builder = new VariantBuilder(new VariantType("a{sv}"));
                builder.add("{sv}", "handle_token", new Variant.string(token));
                Variant parameters;
                if (method == "CreateSession")
                {
                    builder.add("{sv}", "session_handle_token", new Variant.string(session.substring(session.last_index_of("/") + 1)));
                    parameters = new Variant("(@a{sv})", builder.end());
                }
                else if (method == "SelectSources")
                {
                    builder.add("{sv}", "types", new Variant.uint32(1));
                    builder.add("{sv}", "multiple", new Variant.boolean(false));
                    parameters = new Variant("(o@a{sv})", session, builder.end());
                }
                else
                {
                    parameters = new Variant("(os@a{sv})", session, "", builder.end());
                }

                // Wait for both the method reply and the separate consent response.
                yield connection.call(
                    /* bus_name= */ BUS,
                    /* object_path= */ PATH,
                    /* interface_name= */ SCREENCAST,
                    /* method_name= */ method,
                    /* parameters= */ parameters,
                    /* reply_type= */ new VariantType ("(o)"),
                    /* flags= */ DBusCallFlags.NONE,
                    /* timeout_msec= */ 10000,
                    /* cancellable= */ cancellable);
                if (response == null && !cancellable.is_cancelled())
                {
                    waiting = true;
                    yield;
                }
                if (closed || cancellable.is_cancelled())
                    throw new IOError.CANCELLED("Screen sharing cancelled.");

                // A denied or cancelled response must never proceed to capture.
                uint code = response.get_child_value(0).get_uint32();
                if (code != 0)
                    throw new RecorderError.FAILED("Screen sharing was cancelled or denied; the screen is required.");
                return response.get_child_value(1);
            }
            finally
            {
                // Every completion path releases the request signal handlers.
                cancellable.disconnect(cancel_handler);
                if (response_subscription != 0)
                {
                    connection.signal_unsubscribe(response_subscription);
                    response_subscription = 0;
                }
                pending_request = null;
            }
        }

        /** Obtain one monitor stream and retain the portal session and PipeWire remote descriptor. */
        private async Camera prepare_wayland() throws Error
        {
            connection = yield Bus.get(BusType.SESSION, cancellable);
            string sender = connection.get_unique_name().substring(1).replace(".", "_");
            session = PATH + "/session/" + sender + "/studio_" + Uuid.string_random().replace("-", "");
            Variant created = yield request("CreateSession");
            Variant? handle = created.lookup_value("session_handle", new VariantType("o"));
            if (handle == null)
                throw new RecorderError.FAILED("Portal did not return a session.");
            session = handle.get_string();
            closed_subscription = connection.signal_subscribe(
                /* sender= */ BUS,
                /* interface_name= */ "org.freedesktop.portal.Session",
                /* member= */ "Closed",
                /* object_path= */ session,
                /* arg0= */ null,
                /* flags= */ DBusSignalFlags.NONE,
                /* callback= */ () =>
                {
                    if (!closed)
                        failed("Desktop sharing session was closed.");
                });

            // Let the user choose the primary monitor, then reject any multi-stream response.
            yield request("SelectSources");
            Variant started = yield request("Start");
            Variant? streams = started.lookup_value("streams", new VariantType("a(ua{sv})"));
            if (streams == null || streams.n_children() != 1)
                throw new RecorderError.FAILED("Select only your primary monitor in the screen-sharing chooser.");

            // Receive a real Unix descriptor and hold it for all subsequent pipeline rebuilds.
            UnixFDList descriptors;
            Variant reply = yield connection.call_with_unix_fd_list(
                /* bus_name= */ BUS,
                /* object_path= */ PATH,
                /* interface_name= */ SCREENCAST,
                /* method_name= */ "OpenPipeWireRemote",
                /* parameters= */ new Variant ("(o@a{sv})", session, options()),
                /* reply_type= */ new VariantType ("(h)"),
                /* flags= */ DBusCallFlags.NONE,
                /* timeout_msec= */ 10000,
                /* fd_list= */ null,
                /* cancellable= */ cancellable,
                /* out_fd_list= */ out descriptors);
            remote_fd = descriptors.get(reply.get_child_value(0).get_handle());
            if (closed)
            {
                Posix.close(remote_fd);
                remote_fd = -1;
                throw new IOError.CANCELLED("Screen sharing cancelled.");
            }

            // Prefer a stable PipeWire serial, falling back to the portal node ID.
            var stream = streams.get_child_value(0);
            var screen = new Input("Screen 1", "desktop-screen-1");
            screen.factory = "pipewiresrc";
            screen.remote_fd = remote_fd;
            var properties = stream.get_child_value(1);
            Variant? serial = properties.lookup_value("pipewire-serial", null);
            if (serial != null)
                screen.remote_target = serial.print(false).replace("uint64 ", "").replace("uint32 ", "");
            else
                screen.remote_path = stream.get_child_value(0).get_uint32().to_string();
            return new Camera(screen, computer_audio());
        }

        /** Cancel pending consent requests, close the sharing session, and release its remote descriptor. */
        public void close()
        {
            if (closed)
                return;
            closed = true;
            // Send Close before cancelling pending operations, while request paths are available.
            if (connection != null)
            {
                if (closed_subscription != 0)
                    connection.signal_unsubscribe(closed_subscription);
                if (pending_request != null)
                    connection.call.begin(
                        /* bus_name= */ BUS,
                        /* object_path= */ pending_request,
                        /* interface_name= */ "org.freedesktop.portal.Request",
                        /* method_name= */ "Close",
                        /* parameters= */ null,
                        /* reply_type= */ null,
                        /* flags= */ DBusCallFlags.NONE,
                        /* timeout_msec= */ 1000,
                        /* cancellable= */ null);
                if (session != null)
                    connection.call.begin(
                        /* bus_name= */ BUS,
                        /* object_path= */ session,
                        /* interface_name= */ "org.freedesktop.portal.Session",
                        /* method_name= */ "Close",
                        /* parameters= */ null,
                        /* reply_type= */ null,
                        /* flags= */ DBusCallFlags.NONE,
                        /* timeout_msec= */ 1000,
                        /* cancellable= */ null);
            }

            // Only release the remote after portal close requests have been queued.
            cancellable.cancel();
            if (remote_fd >= 0)
            {
                Posix.close(remote_fd);
                remote_fd = -1;
            }
        }
    }
}
