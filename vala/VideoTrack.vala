namespace Studio
{
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
                int numerator, denominator;
                if (structure.get_fraction("framerate", out numerator, out denominator) && denominator > 0)
                    target = (double) numerator / denominator;
                structure.get_int("width", out width);
                structure.get_int("height", out height);
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
}
