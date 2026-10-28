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

/** Locate the permanent toolbar independently of the dock's widget structure. */
private Gtk.Widget? find_toolbar(Gtk.Widget root)
{
    if (root.has_css_class("toolbar"))
        return root;

    // Search descendants only after checking the current widget's role.
    for (var child = root.get_first_child(); child != null; child = child.get_next_sibling())
    {
        var found = find_toolbar(child);
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
        Gtk.Widget? toolbar = null;
        Gtk.Widget? transport_text = null;
        int toolbar_height = 0;
        int transport_width = 0;
        int transport_height = 0;
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

                    // Record the paused toolbar geometry before exercising capture and take transitions.
                    toolbar = find_toolbar(window);
                    assert(toolbar != null);
                    transport_text = toolbar.get_first_child().get_next_sibling().get_next_sibling();
                    toolbar_height = toolbar.get_height();
                    transport_width = transport_text.get_width();
                    transport_height = transport_text.get_height();

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

                // Status strings must not resize the toolbar, including Starting and Finalizing states.
                assert(toolbar.get_height() == toolbar_height);
                assert(transport_text.get_width() == transport_width);
                assert(transport_text.get_height() == transport_height);

                // The elapsed counter must fit its rendered large font without ellipsizing or clipping.
                var visible_status = (Gtk.Label) ((Gtk.Stack) transport_text).visible_child;
                var text_layout = visible_status.get_layout();
                int text_width, text_height;
                text_layout.get_pixel_size(out text_width, out text_height);
                assert(!text_layout.is_ellipsized());
                assert(visible_status.get_width() >= text_width);
                assert(visible_status.get_height() >= text_height);

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

/** Restore actual window bounds and a manually resized controls pane across two application launches. */
private void test_layout_restart()
{
    try
    {
        string directory = DirUtils.make_tmp("studio-layout-ui-XXXXXX");
        string path = Path.build_filename(directory, "preferences.ini");
        var initial = new WindowGeometry();
        initial.width = 1100;
        initial.height = 800;
        initial.controls_width = 320;
        new Preferences(path).save_window_geometry(initial);

        // Use only an explicit temporary preferences file even though media sources are synthetic.
        for (int pass = 0; pass < 2; pass++)
        {
            var app = new Application(true, false, 0, new Preferences(path));
            var window = (Gtk.Window) Gtk.Window.get_toplevels().get_item(0);
            int ticks = 0;
            int stage = 0;
            Timeout.add(
                /* interval= */ 100,
                /* function= */ () =>
                {
                    assert(++ticks < 150);
                    if (app.transport_state != TransportState.PAUSED || ticks < 10)
                        return Source.CONTINUE;
                    var controls = (VideoControlsView) find_widget(window, typeof(VideoControlsView));
                    if (pass == 0 && stage == 0)
                    {
                        assert(window.get_width() == 1100 && window.get_height() == 800);
                        assert(controls.get_width() == 320);

                        // Drive the real divider, then resize the window without changing the end-pane width.
                        var split = (Gtk.Paned) find_widget(window, typeof(Gtk.Paned));
                        split.position += 40;
                        stage = 1;
                        return Source.CONTINUE;
                    }
                    if (pass == 0 && stage == 1)
                    {
                        if (ticks < 13)
                            return Source.CONTINUE;
                        assert(controls.get_width() == 280);

                        // Resize after the drag has been allocated, as separate user interactions are.
                        window.set_default_size(1200, 820);
                        stage = 2;
                        return Source.CONTINUE;
                    }
                    if (pass == 0 && stage == 2)
                    {
                        if (ticks < 17)
                            return Source.CONTINUE;

                        // Move after GTK's resize transaction has settled, using exact client coordinates.
                        var placement = new WindowGeometry();
                        placement.positioned = true;
                        placement.x = 120;
                        placement.y = 100;
                        placement.restore_position(window);
                        stage = 3;
                        return Source.CONTINUE;
                    }
                    if (pass == 0 && ticks < 22)
                        return Source.CONTINUE;

                    // Both the live allocation and the next launch must match the saved manual sizes.
                    assert(window.get_width() == 1200 && window.get_height() == 820);
                    Test.message("pass=%d window=%dx%d controls=%d", pass, window.get_width(), window.get_height(), controls.get_width());
                    assert(controls.get_width() == 280);
                    var observed = new WindowGeometry();
                    observed.sample(window, controls);
                    if (window.get_surface() is Gdk.X11.Surface)
                    {
                        Test.message("position valid=%s actual=%d,%d", observed.positioned.to_string(), observed.x, observed.y);
                        assert(observed.positioned && observed.x == 120 && observed.y == 100);
                    }
                    app.request_exit();
                    return Source.REMOVE;
                });
            assert(app.run() == 0);
            var saved = new Preferences(path).load_window_geometry();
            assert(saved.width == 1200 && saved.height == 820 && saved.controls_width == 280);
        }

        // The restart test never writes user preferences or creates recordings.
        FileUtils.unlink(path);
        DirUtils.remove(directory);
    }
    catch (Error error)
    {
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
    Test.add_func("/studio/layout-restart", test_layout_restart);
    return Test.run();
}
