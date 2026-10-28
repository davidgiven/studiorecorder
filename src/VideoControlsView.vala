/** Keeps the controls' preferred width independent of the currently selected source. */
public class VideoControlsView : Gtk.Widget
{
    private Gtk.ScrolledWindow scroll;
    private bool manually_resized;
    private int saved_width;

    /** Scroll camera adjustments vertically while allowing the dock divider to set their width. */
    public VideoControlsView(Gtk.Widget controls, int saved_width = 0)
    {
        this.saved_width = saved_width;
        vexpand = true;
        hexpand = false;
        scroll = new Gtk.ScrolledWindow()
        {
            child = controls
        };
        scroll.set_policy(Gtk.PolicyType.EXTERNAL, Gtk.PolicyType.AUTOMATIC);
        scroll.set_parent(this);
    }

    /** Use a stable 20em natural width while retaining native vertical measurement and manual resizing. */
    protected override void measure(Gtk.Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline)
    {
        if (orientation == Gtk.Orientation.VERTICAL)
        {
            scroll.measure(orientation, for_size, out minimum, out natural, out minimum_baseline, out natural_baseline);
            return;
        }

        // Resolve em from the actual GTK font and its logical-pixel resolution, including absolute font sizes.
        var context = get_pango_context();
        var font = context.get_font_description();
        double size = (double) font.get_size() / Pango.SCALE;
        double resolution = Pango.cairo_context_get_resolution(context);
        if (resolution <= 0)
            resolution = 96;
        if (!font.get_size_is_absolute())
            size *= resolution / 72;

        // Protect the startup width until an explicit divider position takes over.
        natural = saved_width > 0 ? saved_width : (int) Math.ceil(20 * size);
        minimum = manually_resized ? int.min(180, natural) : natural;
        minimum_baseline = -1;
        natural_baseline = -1;
    }

    /** Release the startup minimum once the divider has an explicit restored or user-selected position. */
    public void allow_manual_width()
    {
        if (manually_resized)
            return;
        manually_resized = true;
        queue_resize();
    }

    /** Let the dock allocate the scroller at the default or manually chosen width. */
    protected override void size_allocate(int width, int height, int baseline)
    {
        scroll.allocate(width, height, baseline, null);
    }

    /** Draw the native scroller and its control widgets. */
    protected override void snapshot(Gtk.Snapshot snapshot)
    {
        snapshot_child(scroll, snapshot);
    }

    /** Unparent the native scroller before disposing its owner. */
    protected override void dispose()
    {
        if (scroll.get_parent() == this)
            scroll.unparent();
        base.dispose();
    }
}
