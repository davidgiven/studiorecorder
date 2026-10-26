[CCode (cheader_filename = "linux/videodev2.h,sys/ioctl.h")]
namespace V4L2
{
    /** Kernel control metadata; the C header supplies the full structure layout. */
    [CCode (cname = "struct v4l2_queryctrl", has_type_id = false)]
    public struct QueryControl
    {
        public uint32 id;
        public uint32 flags;
    }

    /** A single kernel control value to write through the source's open descriptor. */
    [CCode (cname = "struct v4l2_control", has_type_id = false)]
    public struct Control
    {
        public uint32 id;
        public int32 value;
    }

    [CCode (cname = "V4L2_CID_EXPOSURE_AUTO_PRIORITY")]
    public const uint32 EXPOSURE_AUTO_PRIORITY;
    [CCode (cname = "V4L2_CTRL_FLAG_DISABLED")]
    public const uint32 DISABLED;
    [CCode (cname = "V4L2_CTRL_FLAG_READ_ONLY")]
    public const uint32 READ_ONLY;
    [CCode (cname = "V4L2_CTRL_FLAG_INACTIVE")]
    public const uint32 INACTIVE;
    [CCode (cname = "VIDIOC_QUERYCTRL")]
    public const ulong QUERYCTRL;
    [CCode (cname = "VIDIOC_S_CTRL")]
    public const ulong S_CTRL;

    /** Query a control using the native ioctl request width and structure layout. */
    [CCode (cname = "ioctl")]
    public int query_control(int fd, ulong request, ref QueryControl control);

    /** Write a control using the native ioctl request width and structure layout. */
    [CCode (cname = "ioctl")]
    public int set_control(int fd, ulong request, ref Control control);

    /** Expose the v4l2src plugin signal on its underlying GStreamer element. */
    [CCode (cname = "GstElement", cheader_filename = "gst/gst.h", type_id = "GST_TYPE_ELEMENT")]
    public class Source : Gst.Element
    {
        [CCode (has_construct_function = false)]
        protected Source();

        /** Notify the application before format negotiation, using the source's already-open descriptor. */
        public signal void prepare_format(int fd, Gst.Caps caps);
    }
}
