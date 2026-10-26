[CCode (cheader_filename = "native.h")]
namespace Native {
    /** Attach a V4L2 format callback that disables exposure-driven dynamic frame rate. */
    [CCode (cname = "studio_lock_framerate")]
    public void lock_framerate (Gst.Element source);

    /** Map the loudest finite channel RMS value onto the thumbnail meter range. */
    [CCode (cname = "studio_level_rms")]
    public double level_rms (Gst.Structure structure);

    /** Initialize Xlib threading before any GTK or screen-capture threads start. */
    [CCode (cname = "studio_xinit_threads")]
    public int xinit_threads ();

    /** Resolve a sysfs path, returning an owned GLib-compatible string or null. */
    [CCode (cname = "studio_realpath")]
    public string? realpath (string path);
}
