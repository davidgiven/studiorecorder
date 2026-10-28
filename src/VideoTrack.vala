/** Tracks one camera's preview paintable, negotiated video format, and native post-encoding frame statistics. */
public class VideoTrack : GLib.Object
{
    public Camera camera;
    public Gdk.Paintable? paintable;
    public Gst.Pad caps_pad;
    public Gst.Element? counter;
    public RollingFramerate history = new RollingFramerate();
    public double target = double.NAN;
    public double actual = double.NAN;
    public int width;
    public int height;

    /** Keep a camera and its negotiated-video pad together with preview and recording statistics. */
    public VideoTrack (Camera camera, Gst.Pad caps_pad)
    {
        this.camera = camera;
        this.caps_pad = caps_pad;
    }

    /** Refresh negotiated dimensions and target FPS, then sample native post-encoding buffer counts. */
    public void sample(uint64 now)
    {
        var caps = caps_pad.get_current_caps();
        if (caps != null && !caps.is_empty())
        {
            unowned var structure = caps.get_structure(0);
            int numerator = 0, denominator = 0;
            if (structure.get_fraction("framerate", out numerator, out denominator) && denominator > 0)
                target = (double) numerator / denominator;
            structure.get_int("width", out width);
            structure.get_int("height", out height);

            // Backends without a readable current format use the first negotiated capture caps.
            if (camera.input.video_mode == null && width > 0 && height > 0 && numerator > 0 && denominator > 0)
            {
                var input = camera.input;
                if (input.identity.has_prefix("desktop-screen") && input.video_modes.length() == 0)
                {
                    input.width = (uint) width;
                    input.height = (uint) height;
                    input.modes_probed = false;
                    VideoMode.probe(input);
                }

                // Retain the negotiated mode even when the initial caps probe omitted it.
                input.video_mode = new VideoMode(width, height, numerator, denominator);
                VideoMode.add(input, input.video_mode);
            }
        }

        // Count encoded access units, independently of preview delivery or rendering speed.
        if (counter != null)
        {
            Gst.Structure stats;
            counter.get("stats", out stats);
            uint64 count;
            if (stats.get_uint64("num-buffers", out count))
                actual = history.update(now, count);
        }
    }
}
