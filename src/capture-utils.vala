public errordomain RecorderError
{
    FAILED
}

/** Create a required GStreamer element, reporting a missing plugin as an application error. */
public Gst.Element make(string factory) throws Error
{
    var element = Gst.ElementFactory.make(factory, null);
    if (element == null)
        throw new RecorderError.FAILED("Missing GStreamer element: %s", factory);
    return element;
}
