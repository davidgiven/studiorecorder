/** A supported output size and exact rational frame rate. */
public class VideoMode : Object
{
    public int width;
    public int height;
    public int numerator;
    public int denominator;

    /** Store a fixed capture mode without rounding fractional camera rates. */
    public VideoMode(int width, int height, int numerator, int denominator)
    {
        this.width = width;
        this.height = height;
        this.numerator = numerator;
        this.denominator = denominator;
    }

    /** Express the selection as caps, optionally constraining the source media type. */
    public string caps(string media = "video/x-raw")
    {
        return "%s,width=%d,height=%d,framerate=%d/%d".printf(media, width, height, numerator, denominator);
    }

    /** Add a unique mode while preserving the device's preferred ordering. */
    public static void add(Input input, VideoMode mode)
    {
        foreach (var existing in input.video_modes)
            if (existing.width == mode.width && existing.height == mode.height &&
                (int64) existing.numerator * mode.denominator == (int64) mode.numerator * existing.denominator)
                return;

        // Append only after every equivalent rational frame rate has been excluded.
        input.video_modes.append(mode);
    }

    /** Read the camera's active size and reciprocal frame interval before opening capture. */
    private static VideoMode? current(Input input)
    {
        if (input.video_path == null)
            return null;

        // Query a separate descriptor without changing capture settings or allocating buffers.
        int descriptor = Posix.open(input.video_path, Posix.O_RDWR | Posix.O_NONBLOCK | Posix.O_CLOEXEC);
        if (descriptor < 0)
            return null;

        // Read dimensions and frame interval together so the displayed mode is complete.
        try
        {
            V4L2.Format format = {};
            format.type = V4L2.VIDEO_CAPTURE;
            V4L2.StreamParameters parameters = {};
            parameters.type = V4L2.VIDEO_CAPTURE;
            if (V4L2.get_format(descriptor, V4L2.G_FMT, ref format) != 0 ||
                V4L2.get_parameters(descriptor, V4L2.G_PARM, ref parameters) != 0 ||
                format.width == 0 || format.height == 0 || parameters.numerator == 0 || parameters.denominator == 0 ||
                format.width > int.MAX || format.height > int.MAX || parameters.numerator > int.MAX || parameters.denominator > int.MAX)
                return null;

            // V4L2 reports seconds per frame; the UI and caps use its reciprocal.
            return new VideoMode((int) format.width, (int) format.height, (int) parameters.denominator, (int) parameters.numerator);
        }
        finally
        {
            Posix.close(descriptor);
        }
    }

    /** Query native source caps once, expanding discrete modes and sampling supported ranges. */
    public static void probe(Input input)
    {
        if (input.modes_probed)
            return;

        // Cache one probe per source; screen choices derive from its native dimensions.
        input.modes_probed = true;
        if (input.identity.has_prefix("desktop-screen"))
        {
            if (input.width > 0 && input.height > 0)
                foreach (int divisor in new int[] { 1, 2, 4 })
                    foreach (int rate in new int[] { 30, 60, 25, 15, 10, 5, 1 })
                        add(input, new VideoMode((int) input.width / divisor, (int) input.height / divisor, rate, 1));
            return;
        }

        // Preserve the active hardware mode before opening a native source for caps discovery.
        input.video_mode = current(input);
        if (input.video_mode != null)
            add(input, input.video_mode);

        // READY exposes supported formats without starting capture or negotiating a replacement.
        Gst.Element? source = null;
        try
        {
            source = input.create_element();
            if (source.set_state(Gst.State.READY) == Gst.StateChangeReturn.FAILURE)
                return;

            // Expand discrete caps before selecting exact sizes and frame intervals.
            var caps = source.get_static_pad("src").query_caps(null).normalize();
            if (caps.is_any() || caps.is_empty())
                return;

            // Keep advertised discrete modes and supported representatives of continuous ranges.
            for (uint index = 0; index < caps.get_size(); index++)
            {
                var single = caps.copy_nth(index);
                var fixed = single.copy().fixate();
                unowned var structure = fixed.get_structure(0);
                int width = 0, height = 0, numerator = 0, denominator = 0;
                if (!structure.get_int("width", out width) || !structure.get_int("height", out height) ||
                    !structure.get_fraction("framerate", out numerator, out denominator) || numerator <= 0 || denominator <= 0)
                    continue;
                add(input, new VideoMode(width, height, numerator, denominator));

                // Discrete values survive normalization; common rates also cover continuous ranges.
                foreach (int rate in new int[] { 60, 50, 30, 25, 24, 15, 10, 5, 1 })
                {
                    var mode = new VideoMode(width, height, rate, 1);
                    if (single.can_intersect(Gst.Caps.from_string(mode.caps(structure.get_name()))))
                        add(input, mode);
                }
            }
        }
        catch (Error error)
        {
            warning("Cannot detect video modes for %s: %s", input.name, error.message);
        }
        finally
        {
            if (source != null)
                source.set_state(Gst.State.NULL);
        }
    }
}
