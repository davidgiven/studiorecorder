/** Find a widget by type without depending on libpanel's intermediate containers. */
private Gtk.Widget? find_widget(Gtk.Widget root, Type type)
{
    if (root.get_type().is_a(type))
        return root;

    // Search children only after checking the current widget.
    for (var child = root.get_first_child(); child != null; child = child.get_next_sibling())
    {
        var found = find_widget(child, type);
        if (found != null)
            return found;
    }
    return null;
}

/** Locate a source thumbnail by its visible source name. */
private Gtk.Button? find_source(Gtk.Widget root, string name)
{
    var label = root as Gtk.Label;
    if (label != null && label.label == name)
        for (var parent = root.get_parent(); parent != null; parent = parent.get_parent())
            if (parent is Gtk.Button)
                return (Gtk.Button) parent;

    // Search children only after checking the current widget.
    for (var child = root.get_first_child(); child != null; child = child.get_next_sibling())
    {
        var found = find_source(child, name);
        if (found != null)
            return found;
    }
    return null;
}

/** Find the main image independently of the thumbnail pictures inside buttons. */
private Gtk.Picture? find_main_picture(Gtk.Widget root)
{
    if (root is Gtk.Picture)
    {
        bool thumbnail = false;
        for (var parent = root.get_parent(); parent != null; parent = parent.get_parent())
            thumbnail |= parent is Gtk.Button;
        if (!thumbnail)
            return (Gtk.Picture) root;
    }

    // Search children only after checking the current widget.
    for (var child = root.get_first_child(); child != null; child = child.get_next_sibling())
    {
        var found = find_main_picture(child);
        if (found != null)
            return found;
    }
    return null;
}

/** Check actual GTK selection and widget retention through format, audio, and take rebuilds. */
private void test_preview_rebuild()
{
    string original = Environment.get_current_dir();
    try
    {
        string directory = DirUtils.make_tmp("studio-preview-ui-XXXXXX");
        Environment.set_current_dir(directory);

        // Drive the real GTK workspace with synthetic sources and software encoding.
        var app = new Application(true, false);
        var windows = Gtk.Window.get_toplevels();
        var window = (Gtk.Window) windows.get_item(0);
        Gtk.Widget? panel = null;
        Gtk.Button? screen = null;
        Gtk.DropDown? resolution = null;
        Gtk.DropDown? rate = null;
        Gtk.Picture? preview = null;
        VideoControlsView? controls_view = null;
        int controls_width = 0;
        int phase = 0;
        int ticks = 0;

        // Advance only after readiness so each assertion observes a completed graph transition.
        uint timer = Timeout.add(
            /* interval= */ 100,
            /* function= */ () =>
            {
                assert(++ticks < 200);
                if (app.transport_state == TransportState.CLOSED)
                    assert_not_reached();
                if (phase == 0)
                {
                    if (app.transport_state != TransportState.PAUSED || ticks < 10)
                        return Source.CONTINUE;

                    // View actions remain reachable outside the dock and track its native visibility.
                    assert(find_widget(window, typeof(Gtk.PopoverMenuBar)) != null);
                    var dock = (Panel.Dock) find_widget(window, typeof(Panel.Dock));
                    assert(dock.reveal_bottom);
                    assert(window.activate_action("view.bottom", null));
                    assert(!dock.reveal_bottom);
                    assert(window.activate_action("view.bottom", null));
                    assert(dock.reveal_bottom);

                    // The About action opens a separate dialog without replacing the recording workspace.
                    assert(window.activate_action("window.about", null));
                    bool found_about = false;
                    for (uint index = 0; index < windows.get_n_items(); index++)
                    {
                        var about = windows.get_item(index) as Gtk.AboutDialog;
                        if (about != null)
                        {
                            assert(about.program_name == "StudioRecorder");
                            about.destroy();
                            found_about = true;
                            break;
                        }
                    }
                    assert(found_about);

                    // Choose a non-first source before changing its format through the actual widgets.
                    controls_view = (VideoControlsView) find_widget(window, typeof(VideoControlsView));
                    controls_width = controls_view.get_width();
                    int minimum_width, natural_width;
                    controls_view.measure(Gtk.Orientation.HORIZONTAL, -1, out minimum_width, out natural_width, null, null);
                    assert(controls_width >= natural_width);
                    screen = find_source(window, "Screen");
                    assert(screen != null);
                    screen.clicked();
                    preview = find_main_picture(window);
                    assert(preview != null);
                    assert(preview.paintable != null && preview.paintable.get_intrinsic_width() > 0);

                    // Retain widget identities to detect unnecessary replacements on later rebuilds.
                    panel = find_widget(window, typeof(CameraControlsPanel));
                    assert(((Gtk.Label) panel.get_first_child()).label == "Screen");
                    var formats = panel.get_first_child().get_next_sibling();
                    resolution = (Gtk.DropDown) formats.get_first_child().get_next_sibling();
                    rate = (Gtk.DropDown) resolution.get_next_sibling().get_next_sibling();
                    assert(resolution.model.get_n_items() == 3);
                    resolution.selected = (resolution.selected + 1) % 3;
                    assert(app.transport_state == TransportState.PREPARING);
                    phase++;
                    return Source.CONTINUE;
                }

                // Even while replacement sinks are empty, the main preview retains a visible frame.
                assert(preview.paintable != null && preview.paintable.get_intrinsic_width() > 0);
                if (app.transport_state != TransportState.PAUSED && app.transport_state != TransportState.RECORDING)
                    return Source.CONTINUE;

                // Changing source and format must not move the default, untouched controls divider.
                assert(controls_view.get_width() == controls_width);

                // The same controls and thumbnail survive every replacement graph.
                assert(find_widget(window, typeof(CameraControlsPanel)) == panel);
                assert(((Gtk.Label) panel.get_first_child()).label == "Screen");
                assert(find_source(window, "Screen") == screen);
                assert(resolution.get_parent() == panel.get_first_child().get_next_sibling());

                // Exercise format, audio, recording-start, and recording-stop replacements in turn.
                switch (phase)
                {
                    case 1:
                        rate.selected = (rate.selected + 1) % rate.model.get_n_items();
                        phase++;
                        break;

                    case 2:
                        assert(app.select_audio("desktop-screen", null));
                        phase++;
                        break;

                    case 3:
                        app.play();
                        phase++;
                        break;

                    case 4:
                        if (app.transport_state == TransportState.RECORDING)
                        {
                            app.stop();
                            phase++;
                        }
                        break;

                    case 5:
                        screen.clicked();
                        var thumbnail = (Gtk.Picture) find_widget(screen, typeof(Gtk.Picture));
                        assert(preview.paintable == thumbnail.paintable);
                        assert(app.transport_state == TransportState.PAUSED);
                        app.play();
                        phase++;
                        break;

                    case 6:
                        if (app.transport_state == TransportState.RECORDING)
                        {
                            // Exit must finalize the active take through the regular shutdown path.
                            assert(window.activate_action("window.exit", null));
                            phase++;
                            return Source.REMOVE;
                        }
                        break;
                }
                return Source.CONTINUE;
            });

        // Run until all transitions have completed, then remove only this test’s recordings.
        assert(app.run() == 0);
        assert(phase == 7);
        assert(timer != 0);
        Environment.set_current_dir(original);
        var recordings = Dir.open(directory);
        string? name;
        while ((name = recordings.read_name()) != null)
        {
            assert(name.has_suffix(".mkv"));
            FileUtils.unlink(Path.build_filename(directory, name));
        }
        DirUtils.remove(directory);
    }
    catch (Error error)
    {
        Environment.set_current_dir(original);
        GLib.error("%s", error.message);
    }
}

/** Run the rebuild regression with native synthetic media and a real GTK display. */
int main(string[] args)
{
    Test.init(ref args);

    // Initialize native threading before GTK and GStreamer can open display resources.
    Native.xinit_threads();
    Gst.init(ref args);
    Test.add_func("/studio/preview-rebuild", test_preview_rebuild);
    return Test.run();
}
