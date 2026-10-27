public enum TransportState
{
    PREPARING, PAUSED, STARTING, RECORDING, FINALIZING, CLOSED
}

/** Map native channel RMS readings onto a normalized meter without changing the audio stream. */
internal double level_rms(Gst.Structure structure)
{
    unowned Value? value = structure.get_value("rms");
    double loudest = -60.0;

    // level publishes a legacy boxed ValueArray; borrow it while the message remains alive.
    if (value != null && value.holds(typeof(GLib.ValueArray)))
    {
        unowned GLib.ValueArray? channels = (GLib.ValueArray?) value.get_boxed();
        if (channels != null)
        {
            for (uint i = 0; i < channels.n_values; i++)
            {
                double db = channels.get_nth(i).get_double();
                if (!db.is_nan() && db.is_infinity() == 0 && db > loudest)
                    loudest = db;
            }
        }
    }

    // Ignore non-finite readings and display the loudest channel in the -60 to 0 dBFS range.
    return ((loudest + 60.0) / 60.0).clamp(0.0, 1.0);
}

/** Holds a preview track and its thumbnail widgets for meter, format, and audio-choice updates. */
private class Thumbnail : GLib.Object
{
    public VideoTrack track;
    public Gtk.Label details;
    public Gtk.LevelBar? meter;
    public Gtk.DropDown selector;
    public Gtk.ToggleButton record_toggle;

    /** Group each preview track with the widgets updated by meters, statistics, and audio selection. */
    public Thumbnail (VideoTrack track, Gtk.Label details, Gtk.LevelBar? meter, Gtk.DropDown selector, Gtk.ToggleButton record_toggle)
    {
        this.track = track;
        this.details = details;
        this.meter = meter;
        this.selector = selector;
        this.record_toggle = record_toggle;
    }
}

/** Coordinates the GTK interface, capture discovery, transport transitions, and graceful take finalization on the main loop. */
public class Application : GLib.Object
{
    private MainLoop loop = new MainLoop();
    private Registry registry = new Registry();
    private Preferences? preferences;
    private DesktopCapture? desktop;
    private Recorder? recorder;
    private List<Camera> cameras = new List<Camera> ();
    private List<Input> audio_sources = new List<Input> ();
    private List<Input> required_audio = new List<Input> ();
    private List<Thumbnail> items = new List<Thumbnail> ();
    private TransportState state = TransportState.PREPARING;
    private bool exiting;
    private bool discovery_complete;
    private bool synthetic;
    private bool headless;
    private double duration;
    private uint startup_timer;
    private uint stop_timer;
    private uint duration_timer;
    private uint ui_timer;
    private uint64 recording_started;
    private Gst.Bus? bus;
    private ulong bus_handler;
    private string? selected_identity;
    private Gtk.Window? window;
    private Gtk.Picture picture;
    private Gtk.Label fps_label;
    private Gtk.Label transport_label;
    private Gtk.Label status_label;
    private Gtk.Button play_button;
    private Gtk.Button stop_button;
    private Gtk.Box thumbnails;
    private Gtk.Box preview_controls;
    public int exit_code
    {
        get;
        private set;
    }

    /** Notify observers after a transport transition and its control updates. */
    public signal void transport_changed(TransportState state);

    /** Expose readiness to control clients without allowing them to bypass transitions. */
    public TransportState transport_state
    {
        get
        {
            return state;
        }
    }

    /** Initialize transport options and create the desktop window unless running headless tests. */
    public Application (bool synthetic = false, bool headless = false, double duration = 0) throws Error
    {
        this.synthetic = synthetic;
        this.headless = headless;
        this.duration = duration;
        if (!synthetic)
            preferences = new Preferences();
        if (!headless)
            create_window();
    }

    /** Assemble the selected preview, transport controls, thumbnail strip, and status display. */
    private void create_window() throws Error
    {
        if (!Gtk.init_check())
            throw new RecorderError.FAILED("Cannot open GTK display. Run from a desktop session.");
        Adw.init();
        Panel.init();
        window = new Gtk.Window();
        window.title = "StudioRecorder — Vala";
        window.set_default_size(960, 640);
        window.close_request.connect(
            /* handler= */ () =>
            {
                request_exit();
                return true;
            });

        // The main preview reuses a selected thumbnail paintable rather than opening another capture.
        picture = new Gtk.Picture()
        {
            hexpand = true, vexpand = true, can_shrink = true
        };
        var overlay = new Gtk.Overlay()
        {
            hexpand = true, vexpand = true
        };
        overlay.child = picture;
        fps_label = new Gtk.Label(null)
        {
            halign = Gtk.Align.START, valign = Gtk.Align.START,
            margin_start = 8, margin_top = 8, can_target = false
        };
        overlay.add_overlay(fps_label);
        var controls = create_preview_controls();

        // Place take controls between the main preview and thumbnail strip.
        var transport = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 12)
        {
            margin_start = 8, margin_end = 8
        };
        play_button = new Gtk.Button.with_label("● Record")
        {
            tooltip_text = "Start a new recording"
        };
        play_button.clicked.connect(play);
        stop_button = new Gtk.Button.with_label("■ Stop")
        {
            tooltip_text = "Finalize and close this take"
        };
        stop_button.clicked.connect(stop);
        transport.append(play_button);
        transport.append(stop_button);
        transport_label = new Gtk.Label(null)
        {
            hexpand = true
        };
        transport.append(transport_label);
        var transport_panel = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
        transport_panel.append(transport);

        // Keep wide collections scrollable while leaving transport and status visible.
        thumbnails = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        var scroll = new Gtk.ScrolledWindow();
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER);
        scroll.child = thumbnails;

        status_label = new Gtk.Label("Discovering capture devices…")
        {
            xalign = 0, wrap = true
        };
        transport_panel.append(status_label);
        window.child = new RecordingWorkspace(overlay, transport_panel, scroll, controls);
        update_transport();
        window.present();
    }

    /** Build the vertically scrolling video controls hosted by their own dock panel. */
    private Gtk.Widget create_preview_controls()
    {
        // Future controls belong in this scrollable container, independent of capture rebuilds.
        preview_controls = new Gtk.Box(Gtk.Orientation.VERTICAL, 12)
        {
            margin_start = 16,
            margin_end = 16,
            margin_bottom = 16
        };
        var scroll = new Gtk.ScrolledWindow()
        {
            vexpand = true,
            child = preview_controls
        };
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        scroll.min_content_width = 180;
        return scroll;
    }

    /** Write progress to the terminal and mirror it in the window when one is present. */
    private void status(string message)
    {
        stdout.printf("%s\n", message);
        stdout.flush();
        if (window != null)
            status_label.label = message;
    }

    /** Publish a transport transition after bringing control sensitivity and labels up to date. */
    private void set_state(TransportState next)
    {
        state = next;
        update_transport();
        transport_changed(next);
    }

    /** Remove an active GLib source and clear its handle so cleanup remains safe to repeat. */
    private static void remove_timer(ref uint timer)
    {
        if (timer != 0)
        {
            Source.remove(timer);
            timer = 0;
        }
    }

    /** Bound pipeline preparation time, excluding time spent in the screen-sharing chooser. */
    private void arm_startup_timeout()
    {
        remove_timer(ref startup_timer);
        startup_timer = Timeout.add_seconds(
            /* interval= */ 30,
            /* function= */ () =>
            {
                startup_timer = 0;
                fail("Capture startup timed out.");
                return Source.REMOVE;
            });
    }

    /** Run the GLib event loop with signal handlers that finalize active recordings before exit. */
    public int run()
    {
        uint interrupt = Unix.signal_add(
            /* signum= */ Posix.Signal.INT,
            /* handler= */ () =>
            {
                request_exit();
                return Source.CONTINUE;
            });
        uint terminate = Unix.signal_add(
            /* signum= */ Posix.Signal.TERM,
            /* handler= */ () =>
            {
                request_exit();
                return Source.CONTINUE;
            });
        Idle.add(
            /* function= */ () =>
            {
                begin();
                return Source.REMOVE;
            });

        // Signal callbacks keep the loop alive until any recording has finalized.
        loop.run();
        Source.remove(interrupt);
        Source.remove(terminate);
        return exit_code;
    }

    /** Start synthetic preview immediately or discover physical inputs on a worker thread. */
    private void begin()
    {
        arm_startup_timeout();
        if (synthetic)
        {
            discovery_complete = true;
            sources_ready(test_cameras());
            return;
        }
        // Device-provider startup may wait for a service. GTK and signals stay responsive.
        new Thread<void*> (
            /* name= */ "device-discovery",
            /* func= */ () =>
            {
                List<Camera> discovered = new List<Camera> ();
                string? failure = null;
                try
                {
                    discovered = registry.discover();
                }
                catch (Error error)
                {
                    failure = error.message;
                }

                // Transfer discovery results back to the GTK thread before touching application state.
                Idle.add(
                    /* function= */ () =>
                    {
                        discovery_complete = true;
                        if (exiting)
                        {
                            registry.stop();
                            return Source.REMOVE;
                        }
                        if (failure != null)
                            fail(failure);
                        else
                            prepare_desktop.begin((owned) discovered);
                        return Source.REMOVE;
                    });
                return null;
            });
    }

    /** Await monitor selection without a startup deadline, then join it to discovered cameras. */
    private async void prepare_desktop(owned List<Camera> discovered)
    {
        remove_timer(ref startup_timer);
        status("Preparing desktop capture… Select your primary monitor if prompted.");
        desktop = new DesktopCapture();
        desktop.failed.connect(fail);
        try
        {
            var screen = yield desktop.prepare();
            if (exiting)
                return;
            discovered.append(screen);
            sources_ready((owned) discovered);
        }
        catch (Error error)
        {
            if (!exiting)
                fail(error.message);
        }
    }

    /** Build the audio-choice list and retain computer audio independently of thumbnail assignments. */
    private void sources_ready(owned List<Camera> discovered)
    {
        cameras = (owned) discovered;
        var unique = new HashTable<string, Input> (str_hash, str_equal);
        foreach (var audio in registry.audio_sources)
            unique.insert(audio.identity, audio);
        foreach (var camera in cameras)
            if (camera.audio != null)
                unique.insert(camera.audio.identity, camera.audio);

        // The screen dropdown may change, but required computer audio must remain captured.
        foreach (var audio in unique.get_values())
        {
            audio_sources.append(audio);
            if (audio.identity == "desktop-audio")
                required_audio.append(audio);
        }
        audio_sources.sort((a, b) => strcmp(a.name + a.identity, b.name + b.identity));
        if (preferences != null)
            foreach (var camera in cameras)
                preferences.restore_audio(camera, audio_sources);
        prepare_pipeline(false);
    }

    /** Detach the current pipeline watch before replacing or shutting down its recorder. */
    private void disconnect_bus()
    {
        if (bus != null)
        {
            bus.disconnect(bus_handler);
            bus.remove_signal_watch();
            bus = null;
            bus_handler = 0;
        }
    }

    /** Replace the previous graph with preview or recording and wait for PLAYING readiness. */
    private void prepare_pipeline(bool recording)
    {
        if (exiting)
            return;
        remove_timer(ref startup_timer);
        remove_timer(ref ui_timer);
        disconnect_bus();

        // Close the old graph before opening the same capture devices for its replacement.
        try
        {
            if (recorder != null)
            {
                recorder.close();
                recorder = null;
            }
            set_state(recording ? TransportState.STARTING : TransportState.PREPARING);
            recorder = new Recorder(recording, !headless, synthetic);
            recorder.build(cameras, required_audio);

            // Observe readiness and errors on the main loop before starting the graph.
            bus = recorder.pipeline.get_bus();
            bus.add_signal_watch();
            bus_handler = bus.message.connect(on_message);
            if (!headless)
            {
                populate_previews();
                ui_timer = Timeout.add(
                    /* interval= */ 250,
                    /* function= */ () =>
                    {
                        update_ui();
                        return Source.CONTINUE;
                    });
            }

            // Controls become ready only when the pipeline reports PLAYING.
            arm_startup_timeout();
            status(recording ? "Starting recording: " + recorder.final_path : "Preparing live previews…");
            recorder.start();
        }
        catch (Error error)
        {
            fail(error.message);
        }
    }

    /** Start a new take only when preview is ready and no shutdown is pending. */
    public void play()
    {
        if (state == TransportState.PAUSED && !exiting && has_recording_channels())
            prepare_pipeline(true);
    }

    /** Report whether a take would contain at least one enabled video channel. */
    private bool has_recording_channels()
    {
        foreach (var camera in cameras)
            if (camera.record_enabled)
                return true;
        return false;
    }

    /** Change a channel's recording inclusion only while stopped, without interrupting its preview. */
    public bool set_record_enabled(string video_identity, bool enabled)
    {
        if (state != TransportState.PAUSED || exiting)
            return false;

        foreach (var camera in cameras)
        {
            if (camera.input.identity != video_identity || camera.record_enabled == enabled)
                continue;
            camera.record_enabled = enabled;
            update_transport();
            status(has_recording_channels() ? "Paused — ready to record." : "Enable a channel to record.");
            return true;
        }
        return false;
    }

    /** Apply a changed, valid audio assignment while paused and defer preview reconstruction. */
    public bool select_audio(string video_identity, string? audio_identity)
    {
        if (state != TransportState.PAUSED || exiting)
            return false;

        // Reject stale or unknown selector identities before modifying a camera assignment.
        Input? audio = null;
        if (audio_identity != null)
        {
            foreach (var input in audio_sources)
                if (input.identity == audio_identity)
                    audio = input;
            if (audio == null)
                return false;
        }

        // Commit one changed assignment and leave the dropdown callback before rebuilding widgets.
        foreach (var camera in cameras)
        {
            if (camera.input.identity != video_identity)
                continue;
            if ((camera.audio != null ? camera.audio.identity : null) == audio_identity)
                return false;
            camera.audio = audio;
            if (preferences != null)
                preferences.save_audio(camera);
            set_state(TransportState.PREPARING);
            // Let the dropdown notification finish; normal priority prevents redraw starvation.
            Idle.add(
                /* function= */ () =>
                {
                    if (!exiting)
                        prepare_pipeline(false);
                    return Source.REMOVE;
                },
                /* priority= */ Priority.DEFAULT);
            return true;
        }
        return false;
    }

    /** Reflect transport readiness, recording elapsed time, and finalization in the controls. */
    private void update_transport()
    {
        if (window == null)
            return;
        play_button.sensitive = state == TransportState.PAUSED && !exiting && has_recording_channels();
        stop_button.sensitive = (state == TransportState.RECORDING || state == TransportState.STARTING) && !exiting;
        foreach (var item in items)
        {
            item.selector.sensitive = state == TransportState.PAUSED && !exiting;
            item.record_toggle.sensitive = state == TransportState.PAUSED && !exiting;
            item.record_toggle.active = item.track.camera.record_enabled;
        }
        if (state == TransportState.RECORDING)
        {
            uint64 elapsed = (Gst.Util.get_timestamp() - recording_started) / Gst.SECOND;
            transport_label.set_markup(
                /* str= */ "<span size='xx-large' weight='bold'>%02u:%02u:%02u</span>".printf(
                    /* hours= */ (uint) (elapsed / 3600),
                    /* minutes= */ (uint) ((elapsed / 60) % 60),
                    /* seconds= */ (uint) (elapsed % 60)));
        }
        else if (state == TransportState.FINALIZING)
            transport_label.label = "Finalizing…";
        else if (state == TransportState.STARTING)
            transport_label.label = "Starting…";
        else
            transport_label.set_markup("<span foreground='#ff2020' size='xx-large' weight='bold'>PAUSED</span>");
    }

    /** Draw a high-contrast red exclusion mark scaled to the thumbnail's allocation. */
    private static void draw_channel_exclusion(Gtk.DrawingArea area, Cairo.Context cr, int width, int height)
    {
        double stroke = double.max(6.0, double.min(width, height) * 0.08);
        double margin = stroke * 1.5;
        cr.set_line_cap(Cairo.LineCap.ROUND);
        cr.move_to(margin, margin);
        cr.line_to(width - margin, height - margin);
        cr.move_to(width - margin, margin);
        cr.line_to(margin, height - margin);

        // A dark outline keeps the red diagonals visible over bright camera or desktop content.
        cr.set_source_rgba(0.0, 0.0, 0.0, 0.8);
        cr.set_line_width(stroke + 4.0);
        cr.stroke_preserve();
        cr.set_source_rgb(1.0, 0.125, 0.125);
        cr.set_line_width(stroke);
        cr.stroke();
    }

    /** Rebuild thumbnails and audio selectors while preserving the selected main preview. */
    private void populate_previews()
    {
        picture.paintable = null;
        items = new List<Thumbnail> ();
        Gtk.Widget? child;
        while ((child = thumbnails.get_first_child()) != null)
            thumbnails.remove(child);

        // Rebuild each selectable preview and its independent audio selector.
        bool first = true;
        foreach (var track in recorder.videos)
        {
            var column = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
            var details = new Gtk.Label("— × — · — fps")
            {
                xalign = 0.5f, can_target = false
            };
            column.append(details);
            var image = new Gtk.Picture.for_paintable(track.paintable)
            {
                can_shrink = true
            };
            image.set_size_request(180, 110);
            var overlay = new Gtk.Overlay()
            {
                child = image
            };

            // A thumbnail meter follows its selected audio input, including shared microphones.
            Gtk.LevelBar? meter = null;
            if (track.camera.audio != null)
            {
                meter = new Gtk.LevelBar.for_interval(0, 1)
                {
                    valign = Gtk.Align.END, can_target = false
                };
                overlay.add_overlay(meter);
            }
            // Bind exclusion visibility to the model so toggles and pipeline rebuilds stay in sync.
            var exclusion = new Gtk.DrawingArea()
            {
                can_target = false,
                hexpand = true,
                vexpand = true
            };
            exclusion.set_draw_func(draw_channel_exclusion);
            track.camera.bind_property(
                /* source_property= */ "record-enabled",
                /* target= */ exclusion,
                /* target_property= */ "visible",
                /* flags= */ BindingFlags.SYNC_CREATE | BindingFlags.INVERT_BOOLEAN);
            overlay.add_overlay(exclusion);
            column.append(overlay);
            column.append(new Gtk.Label(track.camera.input.name));
            var button = new Gtk.Button()
            {
                child = column
            };
            button.clicked.connect(() => select_preview(track));
            var item = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
            item.append(button);

            // Keep the dropdown outside the preview button so interacting with it does not select video.
            string[] names =
            {
                "No audio"
            };
            uint selected = 0;
            uint index = 1;
            foreach (var audio in audio_sources)
            {
                names += audio.name;
                if (track.camera.audio != null && audio.identity == track.camera.audio.identity)
                    selected = index;
                index++;
            }
            var selector = new Gtk.DropDown.from_strings(names)
            {
                selected = selected, sensitive = state == TransportState.PAUSED && !exiting,
                tooltip_text = "Audio input (editable while paused)"
            };
            selector.notify["selected"].connect(
                /* handler= */ () =>
                {
                    uint choice = selector.selected;
                    if (choice > audio_sources.length())
                        return;
                    Input? input = choice > 0 ? audio_sources.nth_data(choice - 1) : null;
                    select_audio(track.camera.input.identity, input != null ? input.identity : null);
                });
            item.append(selector);

            // Recording inclusion is independent of preview selection and paused audio assignment.
            var record_toggle = new Gtk.ToggleButton.with_label("Record channel")
            {
                active = track.camera.record_enabled,
                sensitive = state == TransportState.PAUSED && !exiting,
                tooltip_text = track.camera.input.identity.has_prefix("desktop-screen")
                    ? "Record Screen, its selected audio, and independent computer audio"
                    : "Record this channel's video and selected audio in subsequent takes"
            };
            record_toggle.toggled.connect(
                /* handler= */ () =>
                {
                    if (!set_record_enabled(track.camera.input.identity, record_toggle.active))
                        record_toggle.active = track.camera.record_enabled;
                });
            item.append(record_toggle);
            thumbnails.append(item);
            items.append(
                /* data= */ new Thumbnail(
                    /* track= */ track,
                    /* details= */ details,
                    /* meter= */ meter,
                    /* selector= */ selector,
                    /* record_toggle= */ record_toggle));
            if (first || track.camera.input.identity == selected_identity)
            {
                select_preview(track);
                first = false;
            }
        }
        update_ui();
    }

    /** Display an existing track paintable without changing capture or recording assignments. */
    private void select_preview(VideoTrack track)
    {
        selected_identity = track.camera.input.identity;
        picture.paintable = track.paintable;
        show_framerate(track);
        populate_camera_controls(track.camera.input);
    }

    /** Show illustrative camera sliders for the selected source without querying or changing hardware. */
    private void populate_camera_controls(Input input)
    {
        Gtk.Widget? child;
        while ((child = preview_controls.get_first_child()) != null)
            preview_controls.remove(child);

        var source = new Gtk.Label(input.name)
        {
            xalign = 0,
            wrap = true
        };
        source.add_css_class("heading");
        preview_controls.append(source);

        // Screen capture has no camera controls; camera sources use an illustrative common set.
        bool screen = input.identity.has_prefix("desktop-screen");
        var notice = new Gtk.Label(screen ? "Camera controls are not available for screen capture." : "Preview only — sliders do not change camera settings.")
        {
            xalign = 0,
            wrap = true
        };
        notice.add_css_class("dim-label");
        preview_controls.append(notice);
        if (screen)
            return;

        string[] names =
        {
            "Brightness", "Contrast", "Saturation", "Hue", "Gamma", "Sharpness",
            "Gain", "Exposure", "White balance", "Focus", "Zoom", "Backlight"
        };
        for (int index = 0; index < names.length; index++)
        {
            var column = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
            var label = new Gtk.Label(names[index])
            {
                wrap = true,
                xalign = 0
            };
            var slider = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 1)
            {
                hexpand = true,
                draw_value = true,
                value_pos = Gtk.PositionType.RIGHT,
                digits = 0,
                tooltip_text = names[index] + " (preview only)"
            };
            slider.set_value(50);
            slider.set_size_request(280, -1);
            disable_slider_scrolling(slider);
            label.set_mnemonic_widget(slider);
            column.append(label);
            column.append(slider);
            preview_controls.append(column);
        }
    }

    /** Disable only the scale's wheel handler so scroll events reach the enclosing scrolled window. */
    private static void disable_slider_scrolling(Gtk.Scale slider)
    {
        var controllers = slider.observe_controllers();
        for (uint index = 0; index < controllers.get_n_items(); index++)
        {
            var controller = controllers.get_item(index) as Gtk.EventControllerScroll;
            if (controller != null)
                controller.propagation_phase = Gtk.PropagationPhase.NONE;
        }
    }

    /** Display a measured rate to one decimal place, or a dash when no sample is available. */
    private static string rate_text(double rate)
    {
        return rate.is_nan() ? "—" : "%.1f".printf(rate);
    }

    /** Render target and post-encoding FPS for the selected video track. */
    private void show_framerate(VideoTrack track)
    {
        fps_label.set_markup(
            /* str= */ "<span background='#202020' foreground='white'>  Target: %s fps   Recording: %s fps  </span>".printf(
                /* target_fps= */ rate_text(track.target),
                /* recording_fps= */ rate_text(track.actual)));
    }

    /** Sample track statistics and refresh thumbnail summaries, the FPS overlay, and elapsed time. */
    private void update_ui()
    {
        if (recorder == null)
            return;

        // Use one monotonic timestamp for every track in this UI refresh.
        uint64 now = Gst.Util.get_timestamp();
        foreach (var item in items)
        {
            item.track.sample(now);
            var track = item.track;
            string size = track.width > 0 ? "%d × %d".printf(track.width, track.height) : "— × —";
            item.details.label = "%s · %s fps".printf(size, rate_text(track.target));
            if (track.camera.input.identity == selected_identity)
                show_framerate(track);
        }
        update_transport();
    }

    /** Translate pipeline readiness, errors, EOS, and audio-level messages into application updates. */
    private void on_message(Gst.Bus source_bus, Gst.Message message)
    {
        if (state == TransportState.CLOSED || recorder == null)
            return;

        // Only the pipeline state controls transport readiness; child-element transitions are ignored.
        switch (message.type)
        {
            case Gst.MessageType.ERROR:
                fail(recorder.describe_error(message));
                break;

            // EOS confirms that the muxer drained every branch and the take may be published.
            case Gst.MessageType.EOS:
                if (recorder.recording)
                    complete_take(true);
                else
                    fail("Live capture ended unexpectedly.");
                break;

            case Gst.MessageType.APPLICATION:
                unowned var detail = message.get_structure();
                if (detail != null && detail.get_name() == "studio-recorder-error")
                    fail(detail.get_string("message") ?? "Cannot link decoded video.");
                break;

            case Gst.MessageType.STATE_CHANGED:
                if (message.src != recorder.pipeline || state == TransportState.FINALIZING)
                    break;
                Gst.State old_state, new_state, pending;
                message.parse_state_changed(out old_state, out new_state, out pending);
                if (new_state == Gst.State.PLAYING)
                {
                    remove_timer(ref startup_timer);
                    if (recorder.recording)
                    {
                        recording_started = Gst.Util.get_timestamp();
                        set_state(TransportState.RECORDING);
                        status("Recording: " + recorder.final_path);
                        if (duration > 0)
                            duration_timer = Timeout.add(
                                /* interval= */ (uint) double.max(1, double.min(duration * 1000, uint.MAX)),
                                /* function= */ () =>
                                {
                                    duration_timer = 0;
                                    request_exit();
                                    return Source.REMOVE;
                                });
                    }
                    else
                    {
                        set_state(TransportState.PAUSED);
                        status(has_recording_channels() ? "Paused — ready to record." : "Enable a channel to record.");
                        if (duration > 0)
                            Idle.add(
                                /* function= */ () =>
                                {
                                    play();
                                    return Source.REMOVE;
                                });
                    }
                }
                break;

            // The native level element computes RMS; the UI only maps its result onto meters.
            case Gst.MessageType.ELEMENT:
                unowned var structure = message.get_structure();
                if (structure != null && structure.get_name() == "level" && window != null)
                {
                    string? identity = recorder.level_sources.lookup(message.src.name);
                    double level = level_rms(structure);
                    foreach (var item in items)
                        if (item.meter != null && item.track.camera.audio != null && item.track.camera.audio.identity == identity)
                            item.meter.value = level;
                }
                break;
                default:
                break;
        }
    }

    /** Record a failing exit status and begin graceful shutdown with the diagnostic visible. */
    private void fail(string message)
    {
        exit_code = 1;
        status("Error: " + message);
        request_exit();
    }

    /** Finalize an active take before exiting, or close preview immediately when stopped. */
    public void request_exit()
    {
        if (state == TransportState.CLOSED)
            return;
        exiting = true;
        if (recorder != null && recorder.recording)
            stop();
        else
            finish();
    }

    /** Begin bounded EOS finalization once, keeping transport actions disabled until it completes. */
    public void stop()
    {
        if (state == TransportState.FINALIZING || state == TransportState.CLOSED)
            return;
        if (recorder == null || !recorder.recording)
        {
            if (exiting)
                finish();
            return;
        }

        // Prevent duplicate Stop actions and remove startup or timed-recording deadlines.
        set_state(TransportState.FINALIZING);
        remove_timer(ref startup_timer);
        remove_timer(ref duration_timer);
        if (!recorder.started)
        {
            complete_take(false);
            return;
        }

        // Bound EOS draining so capture failures cannot leave shutdown waiting indefinitely.
        status("Finalizing recording…");
        stop_timer = Timeout.add_seconds(
            /* interval= */ 10,
            /* function= */ () =>
            {
                stop_timer = 0;
                exit_code = 1;
                exiting = true;
                status("Finalization timed out; preserving incomplete output.");
                complete_take(false);
                return Source.REMOVE;
            });
        if (!recorder.stop())
        {
            exit_code = 1;
            exiting = true;
            complete_take(false);
        }
    }

    /** Close and report the take, then either rebuild preview or finish the pending exit. */
    private void complete_take(bool finalized)
    {
        remove_timer(ref stop_timer);
        remove_timer(ref duration_timer);
        remove_timer(ref ui_timer);
        disconnect_bus();

        // Publish only after EOS; preserve the partial file when finalization did not complete.
        try
        {
            recorder.close(finalized);
            status(
                /* message= */ (finalized ? "Saved: " : "Incomplete recording: ") +
                (finalized ? recorder.final_path : recorder.partial_path));
        }
        catch (Error error)
        {
            exit_code = 1;
            exiting = true;
            status("Could not finalize output: " + error.message);
        }
        recorder = null;
        if (exiting)
            finish();
        else
            prepare_pipeline(false);
    }

    /** Release timers, capture services, and UI resources before stopping the main loop. */
    private void finish()
    {
        if (state == TransportState.CLOSED)
            return;
        remove_timer(ref startup_timer);
        remove_timer(ref stop_timer);
        remove_timer(ref duration_timer);
        remove_timer(ref ui_timer);
        disconnect_bus();
        if (recorder != null)
        {
            try
            {
                recorder.close();
            }
            catch (Error error)
            {
                exit_code = 1;
                status(error.message);
            }
            recorder = null;
        }

        // Discovery owns its provider until its worker returns; avoid a concurrent provider stop.
        if (discovery_complete)
            registry.stop();
        if (desktop != null)
            desktop.close();
        if (window != null)
            window.destroy();
        items = new List<Thumbnail> ();
        set_state(TransportState.CLOSED);
        loop.quit();
    }
}
