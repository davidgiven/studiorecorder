/** Gives a native preview and its overlays a fixed 192 × 108 allocation regardless of source caps. */
public class ThumbnailImage : Gtk.Widget
{
    private Gtk.Widget content;

    /** Parent the complete preview overlay inside a clipped 16:9 viewport. */
    public ThumbnailImage(Gtk.Widget content)
    {
        this.content = content;
        overflow = Gtk.Overflow.HIDDEN;
        halign = Gtk.Align.CENTER;
        valign = Gtk.Align.START;
        content.set_parent(this);
    }

    /** Report fixed dimensions instead of the source paintable's intrinsic resolution. */
    protected override void measure(Gtk.Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline)
    {
        minimum = orientation == Gtk.Orientation.HORIZONTAL ? 192 : 108;
        natural = minimum;
        minimum_baseline = -1;
        natural_baseline = -1;
    }

    /** Allocate the native picture, meter, and exclusion overlay to the same fixed viewport. */
    protected override void size_allocate(int width, int height, int baseline)
    {
        content.allocate(192, 108, -1, null);
    }

    /** Delegate rendering to GTK and the native sink paintable without processing video frames. */
    protected override void snapshot(Gtk.Snapshot snapshot)
    {
        snapshot_child(content, snapshot);
    }

    /** Release the child before this custom container is disposed. */
    protected override void dispose()
    {
        if (content.get_parent() == this)
            content.unparent();
        base.dispose();
    }
}
