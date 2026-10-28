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
    public Gtk.Picture image;
    public Gtk.LevelBar meter;
    public Gtk.DropDown selector;
    public Gtk.ToggleButton record_toggle;

    /** Group each preview track with the widgets updated by meters, statistics, and audio selection. */
    public Thumbnail (VideoTrack track, Gtk.Label details, Gtk.Picture image, Gtk.LevelBar meter, Gtk.DropDown selector, Gtk.ToggleButton record_toggle)
    {
        this.track = track;
        this.details = details;
        this.image = image;
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
    private WindowGeometry geometry = new WindowGeometry();
    private VideoControlsView? controls_view;
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
    private Gtk.Stack transport_status;
    private Gtk.Label status_label;
    private Gtk.Button play_button;
    private Gtk.Button stop_button;
    private Gtk.Box thumbnails;
    private Gtk.Box preview_controls;
    private CameraControlsPanel? camera_controls_panel;
    private VideoModePanel? video_mode_panel;
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

    /** Initialize transport and preferences, allowing explicit isolated settings for synthetic tests. */
    public Application (bool synthetic = false, bool headless = false, double duration = 0, Preferences? stored_preferences = null) throws Error
    {
        this.synthetic = synthetic;
        this.headless = headless;
        this.duration = duration;
        preferences = stored_preferences;
        if (preferences == null && !synthetic)
            preferences = new Preferences();
        if (preferences != null)
            geometry = preferences.load_window_geometry();
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
        geometry.restore(window);
        var initial_placement = new WindowGeometry();
        initial_placement.positioned = geometry.positioned;
        initial_placement.x = geometry.x;
        initial_placement.y = geometry.y;
        bool placement_restored = false;
        window.map.connect(
            /* handler= */ () =>
            {
                if (placement_restored)
                    return;
                placement_restored = true;

                // Restore after the initial GTK resize and window-manager placement transactions.
                Timeout.add(
                    /* interval= */ 100,
                    /* function= */ () =>
                    {
                        if (!exiting)
                            initial_placement.restore_position(window);
                        return Source.REMOVE;
                    });
            });
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

        // Keep take controls and status in a permanent toolbar beneath the menu bar.
        var transport = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 12)
        {
            margin_start = 8,
            margin_end = 8,
            margin_top = 4,
            margin_bottom = 4
        };
        transport.add_css_class("toolbar");
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
        // Measure every status at its actual rendered font size, including a long elapsed-time sample.
        transport.append(create_transport_status());

        // Keep wide collections scrollable while leaving transport and status visible.
        thumbnails = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        var scroll = new Gtk.ScrolledWindow();
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER);
        scroll.child = thumbnails;

        status_label = new Gtk.Label("Discovering capture devices…")
        {
            xalign = 0,
            hexpand = true,
            ellipsize = Pango.EllipsizeMode.END,
            single_line_mode = true,
            max_width_chars = 1
        };
        transport.append(status_label);

        // Menus and transport stay outside the dock so panel visibility never hides them.
        var workspace = new RecordingWorkspace(overlay, scroll, controls);
        var layout = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        layout.append(create_menu_bar(workspace));
        layout.append(transport);
        layout.append(new Gtk.Separator(Gtk.Orientation.HORIZONTAL));
        layout.append(workspace);
        window.child = layout;
        update_transport();
        window.present();
    }

    /** Reserve stable status dimensions using real rendered labels rather than base-font character counts. */
    private Gtk.Widget create_transport_status()
    {
        transport_status = new Gtk.Stack()
        {
            hhomogeneous = true,
            vhomogeneous = true,
            transition_type = Gtk.StackTransitionType.NONE
        };
        transport_label = create_transport_label("00:00:00");
        transport_status.add_named(transport_label, "recording");
        transport_status.add_named(create_transport_label("PAUSED", true), "paused");
        transport_status.add_named(create_transport_label("Starting…"), "starting");
        transport_status.add_named(create_transport_label("Finalizing…"), "finalizing");

        // The hidden sample keeps the allocation stable as elapsed digits change or hours grow.
        transport_status.add_named(create_transport_label("000000:00:00"), "reserve");
        return transport_status;
    }

    /** Render one complete status line without truncation at the shared prominent font size. */
    private static Gtk.Label create_transport_label(string text, bool paused = false)
    {
        var label = new Gtk.Label(null)
        {
            single_line_mode = true
        };
        label.set_markup(
            /* str= */ "<span font_family='monospace' size='xx-large' weight='bold'%s>%s</span>".printf(
                /* foreground= */ paused ? " foreground='#ff2020'" : "",
                /* text= */ Markup.escape_text(text)));
        return label;
    }

    /** Build a traditional File/View menu bar backed by window actions and native dock properties. */
    private Gtk.Widget create_menu_bar(RecordingWorkspace workspace)
    {
        var actions = new SimpleActionGroup();
        var about = new SimpleAction("about", null);
        about.activate.connect(() => show_about());
        actions.add_action(about);
        var exit = new SimpleAction("exit", null);
        exit.activate.connect(() => request_exit());
        actions.add_action(exit);
        window.insert_action_group("window", actions);
        window.insert_action_group("view", workspace.view_actions);

        // Property-backed View actions stay checked when dock visibility changes elsewhere.
        var file = new Menu();
        file.append("_About", "window.about");
        file.append("E_xit", "window.exit");
        var menu = new Menu();
        menu.append_submenu("_File", file);
        menu.append_submenu("_View", workspace.view_menu);
        return new Gtk.PopoverMenuBar.from_model(menu);
    }

    /** Present application information without interrupting an active capture or take. */
    private void show_about()
    {
        var dialog = new Gtk.AboutDialog()
        {
            transient_for = window,
            modal = true,
            program_name = "StudioRecorder",
            comments = "Multitrack video and audio recorder for Linux.",
            authors = new string[]
            { "David Given" },
            website = "https://cowlark.com/"
        };
        dialog.present();
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
        // Keep the preferred width stable across sources while preserving the dock's manual divider.
        controls_view = new VideoControlsView(preview_controls, geometry.controls_width);
        return controls_view;
    }

    /** Write progress to the terminal and mirror it in the window when one is present. */
    private void status(string message)
    {
        stdout.printf("%s\n", message);
        stdout.flush();
        if (window != null)
        {
            status_label.label = message;
            status_label.tooltip_text = message;
        }
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
            {
                preferences.restore_audio(camera, audio_sources);
                preferences.restore_record_enabled(camera);
                camera.input.saved_controls = preferences.load_controls(camera.input);
            }

        // Probe current formats before applying any still-supported saved choices.
        foreach (var camera in cameras)
        {
            VideoMode.probe(camera.input);
            if (preferences != null)
                preferences.restore_video_mode(camera.input);
        }
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
                freeze_previews();
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

        // Persist an accepted inclusion change before updating transport readiness and its thumbnail.
        foreach (var camera in cameras)
        {
            if (camera.input.identity != video_identity || camera.record_enabled == enabled)
                continue;
            camera.record_enabled = enabled;
            if (preferences != null)
                preferences.save_record_enabled(camera);
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
        if (video_mode_panel != null)
            video_mode_panel.sensitive = state == TransportState.PAUSED && !exiting;
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
                /* str= */ "<span font_family='monospace' size='xx-large' weight='bold'>%02u:%02u:%02u</span>".printf(
                    /* hours= */ (uint) (elapsed / 3600),
                    /* minutes= */ (uint) ((elapsed / 60) % 60),
                    /* seconds= */ (uint) (elapsed % 60)));
            transport_status.visible_child_name = "recording";
        }
        else if (state == TransportState.FINALIZING)
            transport_status.visible_child_name = "finalizing";
        else if (state == TransportState.STARTING)
            transport_status.visible_child_name = "starting";
        else
            transport_status.visible_child_name = "paused";
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

    /** Retain immutable native paintable snapshots while capture devices are reopened. */
    private void freeze_previews()
    {
        if (headless)
            return;

        // Snapshot the displayed frames before their owning capture graph is closed.
        if (picture.paintable != null)
            picture.paintable = picture.paintable.get_current_image();
        foreach (var item in items)
            if (item.image.paintable != null)
                item.image.paintable = item.image.paintable.get_current_image();
    }

    /** Rebind existing widgets when the source list is unchanged, preserving focus and scroll positions. */
    private bool rebind_previews()
    {
        if (items.length() == 0 || items.length() != recorder.videos.length())
            return false;

        // Match every source before committing any widget changes.
        var replacements = new List<Thumbnail>();
        foreach (var track in recorder.videos)
        {
            Thumbnail? match = null;
            foreach (var item in items)
                if (item.track.camera.input.identity == track.camera.input.identity)
                    match = item;
            if (match == null)
                return false;
            replacements.append(match);
        }

        // Rebind the validated widgets and reset meters for the replacement capture graph.
        uint index = 0;
        foreach (var track in recorder.videos)
        {
            var item = replacements.nth_data(index++);
            item.track = track;
            item.meter.visible = track.camera.audio != null;
            item.meter.value = 0;

            // Reflect audio changes without replacing the dropdown or its focus state.
            uint selected = 0;
            uint audio_index = 1;
            foreach (var audio in audio_sources)
            {
                if (track.camera.audio != null && audio.identity == track.camera.audio.identity)
                    selected = audio_index;
                audio_index++;
            }
            item.selector.selected = selected;
        }
        update_ui();
        return true;
    }

    /** Select the current track for a stable source identity rather than retaining a retired graph. */
    private void select_source(string identity)
    {
        if (recorder == null)
            return;

        // Resolve clicks against the replacement graph rather than a captured retired track.
        foreach (var track in recorder.videos)
            if (track.camera.input.identity == identity)
            {
                select_preview(track);
                return;
            }
    }

    /** Ellipsize selected audio names so device labels cannot widen thumbnail cards. */
    private static Gtk.ListItemFactory thumbnail_audio_factory()
    {
        var factory = new Gtk.SignalListItemFactory();
        factory.setup.connect(
            /* handler= */ (item) =>
            {
                ((Gtk.ListItem) item).child = new Gtk.Label(null)
                {
                    xalign = 0,
                    ellipsize = Pango.EllipsizeMode.END,
                    max_width_chars = 1,
                    single_line_mode = true
                };
            });

        // Keep the complete device name available even when its visible text is clipped.
        factory.bind.connect(
            /* handler= */ (item) =>
            {
                var row = (Gtk.ListItem) item;
                var label = (Gtk.Label) row.child;
                label.label = ((Gtk.StringObject) row.item).get_string();
                label.tooltip_text = label.label;
            });
        return factory;
    }

    /** Rebuild thumbnails and audio selectors while preserving the selected main preview. */
    private void populate_previews()
    {
        if (rebind_previews())
            return;

        // Only a changed source list requires replacing thumbnail widgets.
        items = new List<Thumbnail> ();
        Gtk.Widget? child;
        while ((child = thumbnails.get_first_child()) != null)
            thumbnails.remove(child);

        // Rebuild each selectable preview and its independent audio selector.
        VideoTrack? selected_track = null;
        foreach (var track in recorder.videos)
        {
            var camera = track.camera;
            var column = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
            var details = new Gtk.Label("— × — · — fps")
            {
                xalign = 0.5f,
                can_target = false,
                ellipsize = Pango.EllipsizeMode.END,
                max_width_chars = 1,
                single_line_mode = true
            };
            column.append(details);

            // Keep the video image and its overlays separate from source labels and selectors.
            var image = new Gtk.Picture.for_paintable(track.paintable)
            {
                can_shrink = true,
                content_fit = Gtk.ContentFit.CONTAIN
            };
            var overlay = new Gtk.Overlay()
            {
                child = image
            };

            // A thumbnail meter follows its selected audio input, including shared microphones.
            var meter = new Gtk.LevelBar.for_interval(0, 1)
            {
                valign = Gtk.Align.END,
                can_target = false,
                visible = camera.audio != null
            };
            overlay.add_overlay(meter);

            // Bind exclusion visibility to the model so toggles and pipeline rebuilds stay in sync.
            var exclusion = new Gtk.DrawingArea()
            {
                can_target = false,
                hexpand = true,
                vexpand = true
            };
            exclusion.set_draw_func(draw_channel_exclusion);
            camera.bind_property(
                /* source_property= */ "record-enabled",
                /* target= */ exclusion,
                /* target_property= */ "visible",
                /* flags= */ BindingFlags.SYNC_CREATE | BindingFlags.INVERT_BOOLEAN);
            overlay.add_overlay(exclusion);
            column.append(new ThumbnailImage(overlay));

            // Thumbnail clicks select video without changing its audio assignment.
            column.append(
                /* child= */ new Gtk.Label(camera.input.name)
                {
                    ellipsize = Pango.EllipsizeMode.END,
                    max_width_chars = 1,
                    single_line_mode = true,
                    tooltip_text = camera.input.name
                });
            var button = new Gtk.Button()
            {
                child = column
            };
            button.clicked.connect(() => select_source(camera.input.identity));
            var item = new Gtk.Box(Gtk.Orientation.VERTICAL, 2)
            {
                width_request = 216,
                halign = Gtk.Align.START,
                valign = Gtk.Align.START
            };
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
                if (camera.audio != null && audio.identity == camera.audio.identity)
                    selected = index;
                index++;
            }
            var selector = new Gtk.DropDown.from_strings(names)
            {
                selected = selected,
                sensitive = state == TransportState.PAUSED && !exiting,
                factory = thumbnail_audio_factory(),
                tooltip_text = "Audio input (editable while paused)"
            };
            selector.notify["selected"].connect(
                /* handler= */ () =>
                {
                    uint choice = selector.selected;
                    if (choice > audio_sources.length())
                        return;
                    Input? input = choice > 0 ? audio_sources.nth_data(choice - 1) : null;
                    select_audio(camera.input.identity, input != null ? input.identity : null);
                });
            item.append(selector);

            // Recording inclusion is independent of preview selection and paused audio assignment.
            var record_toggle = new Gtk.ToggleButton.with_label("Record channel")
            {
                active = camera.record_enabled,
                sensitive = state == TransportState.PAUSED && !exiting,
                tooltip_text = camera.input.identity.has_prefix("desktop-screen")
                    ? "Record Screen, its selected audio, and independent computer audio"
                    : "Record this channel's video and selected audio in subsequent takes"
            };
            record_toggle.toggled.connect(
                /* handler= */ () =>
                {
                    if (!set_record_enabled(camera.input.identity, record_toggle.active))
                        record_toggle.active = camera.record_enabled;
                });
            item.append(record_toggle);

            // Publish the complete thumbnail and retain its widgets for future graph replacements.
            thumbnails.append(item);
            items.append(
                /* data= */ new Thumbnail(
                    /* track= */ track,
                    /* details= */ details,
                    /* image= */ image,
                    /* meter= */ meter,
                    /* selector= */ selector,
                    /* record_toggle= */ record_toggle));
            if (camera.input.identity == selected_identity)
                selected_track = track;
        }

        // Resolve the old selection before choosing a fallback; selecting the first would overwrite it.
        if (selected_track == null)
            selected_track = recorder.videos.nth_data(0);
        if (selected_track != null)
            select_preview(selected_track);
        update_ui();
    }

    /** Display an existing track paintable without changing capture or recording assignments. */
    private void select_preview(VideoTrack track)
    {
        bool changed = selected_identity != track.camera.input.identity;
        selected_identity = track.camera.input.identity;
        foreach (var item in items)
            if (item.track == track)
                picture.paintable = item.image.paintable;

        // Keep existing controls and scroll position when only the underlying graph changed.
        show_framerate(track);
        if (changed || camera_controls_panel == null)
            populate_camera_controls(track.camera.input);
    }

    /** Probe the selected source's real camera controls without rebuilding capture pipelines. */
    private void populate_camera_controls(Input input)
    {
        Gtk.Widget? child;
        while ((child = preview_controls.get_first_child()) != null)
            preview_controls.remove(child);

        // Format changes persist immediately and defer graph replacement until notifications finish.
        video_mode_panel = new VideoModePanel(input);
        video_mode_panel.sensitive = state == TransportState.PAUSED && !exiting;
        video_mode_panel.changed.connect(
            /* handler= */ () =>
            {
                if (state != TransportState.PAUSED || exiting)
                    return;

                // Save the complete selection before beginning a paused preview rebuild.
                if (preferences != null)
                    preferences.save_video_mode(input);
                set_state(TransportState.PREPARING);
                Idle.add(
                    /* function= */ () =>
                    {
                        if (!exiting)
                            prepare_pipeline(false);
                        return Source.REMOVE;
                    },
                    /* priority= */ Priority.DEFAULT);
            });

        // Keep format selectors below the source name and above native camera adjustments.
        camera_controls_panel = new CameraControlsPanel(input, preferences, video_mode_panel);
        preview_controls.append(camera_controls_panel);
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
        geometry.sample(window, controls_view);
        uint64 now = Gst.Util.get_timestamp();
        bool restore_capture = false;
        foreach (var item in items)
        {
            bool detecting_mode = item.track.camera.input.video_mode == null;
            item.track.sample(now);

            // Some backends expose the current mode only after their first negotiated frame.
            if (detecting_mode && item.track.camera.input.video_mode != null)
            {
                var input = item.track.camera.input;
                var negotiated = input.video_mode;
                if (preferences != null)
                    preferences.restore_video_mode(input);
                restore_capture |= input.video_mode != negotiated;
                if (input.identity == selected_identity)
                    populate_camera_controls(input);
            }

            // Retain the previous format summary until replacement caps provide real dimensions.
            var track = item.track;
            string size = track.width > 0 ? "%d × %d".printf(track.width, track.height) : "— × —";
            if (track.width > 0)
                item.details.label = "%s · %s fps".printf(size, rate_text(track.target));

            // New sink paintables remain empty until the first frame; keep the previous snapshot meanwhile.
            if (track.paintable != null && track.paintable.get_intrinsic_width() > 0)
                item.image.paintable = track.paintable;
            if (track.camera.input.identity == selected_identity)
            {
                picture.paintable = item.image.paintable;
                if (!track.target.is_nan())
                    show_framerate(track);
            }
        }

        // Portal dimensions may arrive only with negotiated caps; restore saved scaling afterward.
        if (restore_capture && !exiting && (state == TransportState.PAUSED || state == TransportState.PREPARING))
        {
            set_state(TransportState.PREPARING);
            Idle.add(
                /* function= */ () =>
                {
                    if (!exiting)
                        prepare_pipeline(false);
                    return Source.REMOVE;
                },
                /* priority= */ Priority.DEFAULT);
        }

        // Synchronize transport sensitivity after any deferred format restoration.
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
                    if (camera_controls_panel != null)
                        camera_controls_panel.refresh();
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
            freeze_previews();
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

        // Capture final normal bounds and divider width before GTK destroys their native surfaces.
        if (window != null)
        {
            geometry.sample(window, controls_view);
            if (preferences != null)
                preferences.save_window_geometry(geometry);
            window.destroy();
        }
        items = new List<Thumbnail> ();
        set_state(TransportState.CLOSED);
        loop.quit();
    }
}
