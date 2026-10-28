/** Holds normal window bounds, native placement, display state, and the controls width across launches. */
public class WindowGeometry : Object
{
    public int width = 960;
    public int height = 640;
    public int controls_width;
    public bool maximized;
    public bool fullscreen;
    public bool positioned;
    public int x;
    public int y;

    /** Restore normal bounds before requesting any maximized or fullscreen state. */
    public void restore(Gtk.Window window)
    {
        window.set_default_size(width, height);
        if (maximized)
            window.maximize();
        if (fullscreen)
            window.fullscreen();
    }

    /** Request saved X11 client coordinates with StaticGravity so decorations do not cause drift. */
    public void restore_position(Gtk.Window window)
    {
        var surface = window.get_surface() as Gdk.X11.Surface;
        if (!positioned || surface == null)
            return;
        unowned var display = ((Gdk.X11.Display) surface.get_display()).get_xdisplay();
        unowned var screen = display.default_screen();
        if (x < 0 || y < 0 || x >= screen.width || y >= screen.height)
            return;

        // StaticGravity refers to the client origin rather than the manager's decoration frame.
        X.Event request = {};
        request.xclient.type = X.EventType.ClientMessage;
        request.xclient.display = display;
        request.xclient.window = surface.get_xid();
        request.xclient.message_type = display.intern_atom("_NET_MOVERESIZE_WINDOW", false);
        request.xclient.format = 32;
        request.xclient.l[0] = 10 | (1 << 8) | (1 << 9) | (1 << 12);
        request.xclient.l[1] = x;
        request.xclient.l[2] = y;
        display.send_event(
            /* w= */ display.default_root_window(),
            /* propagate= */ false,
            /* event_mask= */ X.EventMask.SubstructureNotifyMask | X.EventMask.SubstructureRedirectMask,
            /* event_send= */ ref request);
        display.flush();
    }

    /** Sample normal bounds without overwriting them with maximized or fullscreen allocations. */
    public void sample(Gtk.Window window, VideoControlsView? controls)
    {
        if (!window.get_mapped())
            return;
        maximized = window.is_maximized();
        fullscreen = window.is_fullscreen();
        if (controls != null && controls.get_mapped() && controls.get_width() > 0)
            controls_width = controls.get_width();
        if (maximized || fullscreen)
            return;

        // Preserve the last normal dimensions for restoring an unmaximized window next time.
        if (window.get_width() > 0 && window.get_height() > 0)
        {
            width = window.get_width();
            height = window.get_height();
        }
        var surface = window.get_surface() as Gdk.X11.Surface;
        if (surface == null)
            return;
        unowned var display = ((Gdk.X11.Display) surface.get_display()).get_xdisplay();
        X.Window child;
        positioned = display.translate_coordinates(surface.get_xid(), display.default_root_window(), 0, 0, out x, out y, out child);
    }
}
