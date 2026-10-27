/** Pairs a video source with the mutable audio assignment used by its meter and subsequent recordings. */
public class Camera : GLib.Object
{
    public Input input
    {
        get;
        construct;
    }
    public Input? audio
    {
        get;
        set;
    }

    /** Include this channel's video and selected audio in subsequent takes; previews stay live. */
    public bool record_enabled
    {
        get;
        set;
        default = true;
    }

    /** Associate a video input with the audio selection used for metering and future takes. */
    public Camera (Input input, Input? audio = null)
    {
        Object(input: input, audio: audio);
    }
}
