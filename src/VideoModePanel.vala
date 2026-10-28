/** Presents dependent resolution and frame-rate choices above the camera controls. */
public class VideoModePanel : Gtk.Box
{
    private Input input;
    private Gtk.DropDown resolution;
    private Gtk.DropDown rate;
    private string[] sizes = {};
    private VideoMode[] rates = {};
    private bool updating;

    /** Request a paused capture rebuild after a complete mode has been selected. */
    public signal void changed();

    /** Populate detected modes without committing a setting during widget construction. */
    public VideoModePanel(Input input)
    {
        Object(orientation: Gtk.Orientation.VERTICAL, spacing: 6);
        this.input = input;

        // Build distinct resolution choices only after the current capture mode is known.
        foreach (var mode in input.video_modes)
        {
            if (input.video_mode == null)
                break;
            string size = "%d × %d".printf(mode.width, mode.height);
            bool found = false;
            foreach (string existing in sizes)
                found |= existing == size;
            if (!found)
                sizes += size;
        }

        // Present resolution before its dependent frame-rate selector.
        append(
            /* child= */ new Gtk.Label("Resolution")
            {
                xalign = 0
            });
        resolution = new Gtk.DropDown.from_strings(sizes);
        append(resolution);
        append(
            /* child= */ new Gtk.Label("Frame rate")
            {
                xalign = 0
            });
        rate = new Gtk.DropDown.from_strings(new string[] {});
        append(rate);

        // Restore both selectors before connecting callbacks that commit user changes.
        updating = true;
        if (input.video_mode != null)
            for (uint index = 0; index < sizes.length; index++)
                if (sizes[index] == "%d × %d".printf(input.video_mode.width, input.video_mode.height))
                    resolution.selected = index;
        populate_rates();
        if (input.video_mode == null)
            append(
                /* child= */ new Gtk.Label("Waiting for capture format…")
                {
                    xalign = 0,
                    wrap = true
                });
        updating = false;
        resolution.sensitive = sizes.length > 0 && input.video_mode != null;

        // Commit a complete mode only after dependent rates have been repopulated.
        resolution.notify["selected"].connect(
            /* handler= */ () =>
            {
                updating = true;
                populate_rates();
                updating = false;
                commit();
            });
        rate.notify["selected"].connect(
            /* handler= */ () =>
            {
                if (!updating)
                    commit();
            });
    }

    /** Restrict rates to the selected resolution and preserve an existing exact rate when possible. */
    private void populate_rates()
    {
        rates = {};
        string[] labels = {};
        uint selected = 0;

        // Collect only rates for the selected size, retaining the current exact fraction when supported.
        foreach (var mode in input.video_modes)
        {
            if (resolution.selected >= sizes.length || sizes[resolution.selected] != "%d × %d".printf(mode.width, mode.height))
                continue;
            if (input.video_mode != null && (int64) mode.numerator * input.video_mode.denominator ==
                (int64) input.video_mode.numerator * mode.denominator)
                selected = rates.length;
            rates += mode;
            labels += "%.3g fps (%d/%d)".printf((double) mode.numerator / mode.denominator, mode.numerator, mode.denominator);
        }

        // Replace the rate choices together so selection indices always refer to the current size.
        rate.model = new Gtk.StringList(labels);
        rate.selected = selected;
        rate.sensitive = rates.length > 0 && input.video_mode != null;
    }

    /** Store the complete selection before requesting pipeline reconstruction. */
    private void commit()
    {
        input.video_mode = rates.length > 0 ? rates[rate.selected] : null;
        changed();
    }
}
