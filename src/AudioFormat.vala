/** Selects uncompressed capture formats that can be muxed without changing samples. */
public class AudioFormat : Object
{
    /** Format actual negotiated PCM caps for media summaries without assuming device defaults. */
    public static string summary(Gst.Caps? caps, bool compact = false)
    {
        if (caps == null || caps.is_empty() || caps.is_any())
            return "Detecting audio format…";
        unowned var format = caps.get_structure(0);
        int channels = 0;
        int rate = 0;
        string? sample = format.get_string("format");
        if (sample == null || !format.get_int("channels", out channels) || !format.get_int("rate", out rate))
            return "Detecting audio format…";

        // Use a compact single-line representation for the preview panel title.
        if (compact)
            return "%s x %d x %d Hz".printf(sample, channels, rate);
        return "%s · %d channels · %d Hz".printf(sample, channels, rate);
    }

    /** Prefer hardware float32; otherwise retain the source's ordering of Matroska-compatible PCM modes. */
    public static Gst.Caps capture_caps(Gst.Caps supported) throws Error
    {
        var preferred = Gst.Caps.from_string("audio/x-raw,format=F32LE,layout=interleaved");
        var floating = preferred.intersect(supported, Gst.CapsIntersectMode.FIRST);
        if (!floating.is_empty())
            return floating;

        // The recording branch contains no converter, so unsupported native formats must fail explicitly.
        var writable = Gst.Caps.from_string("audio/x-raw,format=(string){U8,S16LE,S16BE,S24LE,S24BE,S32LE,S32BE,F32LE,F64LE},layout=interleaved");
        var native = supported.intersect(writable, Gst.CapsIntersectMode.FIRST);
        if (native.is_empty())
            throw new RecorderError.FAILED("This input exposes no native PCM format supported by Matroska; conversion is disabled.");
        return native;
    }
}
