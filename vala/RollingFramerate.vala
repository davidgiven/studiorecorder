namespace Studio
{
    /** Stores one monotonic observation of a cumulative encoded-frame counter for rolling FPS calculations. */
    private class FrameSample : GLib.Object
    {
        public uint64 time;
        public double count;

        /** Store a monotonic timestamp and cumulative encoded-frame count for rate calculation. */
        public FrameSample (uint64 time, double count)
        {
            this.time = time;
            this.count = count;
        }
    }

    /** Maintains a ten-second frame-count history with boundary interpolation and reset handling. */
    public class RollingFramerate : GLib.Object
    {
        private Queue<FrameSample> samples = new Queue<FrameSample> ();

        /** Compute a ten-second encoded-frame rate, interpolating the boundary and resetting on discontinuities. */
        public double update(uint64 now, uint64 count)
        {
            // Discard history when counters or the monotonic clock move backwards.
            var last = samples.peek_tail();
            if (last != null && (now < last.time || count < last.count))
                samples.clear();
            else if (last != null && now == last.time)
                return double.NAN;
            samples.push_tail(new FrameSample(now, count));

            // Keep the sample before the window boundary so delayed UI polling can be interpolated.
            uint64 cutoff = now > 10 * Gst.SECOND ? now - 10 * Gst.SECOND : 0;
            while (samples.length > 1 && samples.peek_nth(1).time <= cutoff)
                samples.pop_head();

            // Interpolate a partial boundary interval instead of rounding the window to a sample.
            var first = samples.peek_head();
            uint64 start = first.time;
            double initial = first.count;
            if (start < cutoff && samples.length > 1)
            {
                var next = samples.peek_nth(1);
                initial += (next.count - initial) * (cutoff - start) / (next.time - start);
                start = cutoff;
            }
            return now > start ? (count - initial) * Gst.SECOND / (now - start) : double.NAN;
        }
    }
}
