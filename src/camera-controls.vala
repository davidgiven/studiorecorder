/** Disable exposure-driven frame intervals without changing the camera's exposure mode. */
private void prepare_format(string source_name, int descriptor, Gst.Caps caps)
{
    V4L2.QueryControl query = {};
    query.id = V4L2.EXPOSURE_AUTO_PRIORITY;

    // Unsupported or unwritable controls are optional; warn and continue capture.
    if (V4L2.query_control(descriptor, V4L2.QUERYCTRL, ref query) < 0 ||
        (query.flags & (V4L2.DISABLED | V4L2.READ_ONLY | V4L2.INACTIVE)) != 0)
    {
        warning("%s: exposure-driven frame-rate control unavailable", source_name);
        return;
    }

    // Only this control changes; the driver retains the existing exposure mode.
    V4L2.Control control = {};
    control.id = V4L2.EXPOSURE_AUTO_PRIORITY;
    control.value = 0;
    if (V4L2.set_control(descriptor, V4L2.S_CTRL, ref control) < 0)
        warning("%s: cannot lock camera frame rate: %s", source_name, strerror(errno));
}

/** Attach the frame-rate callback before v4l2src negotiates its capture format. */
internal void lock_framerate(Gst.Element source, HashTable<string, int>? saved = null)
{
    // Capture the label rather than the source itself to avoid a signal ownership cycle.
    string source_name = source.name;
    ((V4L2.Source) source).prepare_format.connect(
        /* handler= */ (descriptor, caps) =>
        {
            // The immutable snapshot avoids accessing preferences or GTK from a streaming thread.
            if (saved != null && saved.size() > 0)
                new CameraControls.borrowed(descriptor).restore(saved);
            prepare_format(source_name, descriptor, caps);
        });
}
