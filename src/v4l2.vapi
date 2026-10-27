[CCode (cheader_filename = "linux/videodev2.h,sys/ioctl.h")]
namespace V4L2
{
    /** Kernel control metadata; the C header supplies the full structure layout. */
    [CCode (cname = "struct v4l2_queryctrl", has_type_id = false)]
    public struct QueryControl
    {
        public uint32 id;
        public uint32 type;
        public uint8 name[32];
        public int32 minimum;
        public int32 maximum;
        public int32 step;
        public int32 default_value;
        public uint32 flags;
    }

    /** A single kernel control value to write through the source's open descriptor. */
    [CCode (cname = "struct v4l2_control", has_type_id = false)]
    public struct Control
    {
        public uint32 id;
        public int32 value;
    }

    /** Scalar extended-control payload, using the kernel's packed structure layout. */
    [CCode (cname = "struct v4l2_ext_control", has_type_id = false)]
    public struct ExtControl
    {
        public uint32 id;
        public int32 value;
    }

    /** Extended-control request with one borrowed scalar payload. */
    [CCode (cname = "struct v4l2_ext_controls", has_type_id = false)]
    public struct ExtControls
    {
        public uint32 which;
        public uint32 count;
        public ExtControl* controls;
    }

    [CCode (cname = "VIDIOC_G_EXT_CTRLS")]
    public const ulong G_EXT_CTRLS;
    [CCode (cname = "VIDIOC_S_EXT_CTRLS")]
    public const ulong S_EXT_CTRLS;

    /** Read or write a scalar from any control class through the extended-control API. */
    [CCode (cname = "ioctl")]
    public int ext_controls(int fd, ulong request, ref ExtControls controls);

    /** Driver-supplied menu labels or integer menu values. */
    [CCode (cname = "struct v4l2_querymenu", has_type_id = false)]
    public struct QueryMenu
    {
        public uint32 id;
        public uint32 index;
        public uint8 name[32];
        public int64 value;
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

    [CCode (cname = "V4L2_CTRL_FLAG_NEXT_CTRL")]
    public const uint32 NEXT_CTRL;
    [CCode (cname = "V4L2_CTRL_FLAG_GRABBED")]
    public const uint32 GRABBED;
    [CCode (cname = "V4L2_CTRL_FLAG_WRITE_ONLY")]
    public const uint32 WRITE_ONLY;
    [CCode (cname = "V4L2_CTRL_FLAG_VOLATILE")]
    public const uint32 VOLATILE;
    [CCode (cname = "V4L2_CTRL_TYPE_INTEGER")]
    public const uint32 INTEGER;
    [CCode (cname = "V4L2_CTRL_TYPE_BOOLEAN")]
    public const uint32 BOOLEAN;
    [CCode (cname = "V4L2_CTRL_TYPE_MENU")]
    public const uint32 MENU;
    [CCode (cname = "V4L2_CTRL_TYPE_BUTTON")]
    public const uint32 BUTTON;
    [CCode (cname = "V4L2_CTRL_TYPE_INTEGER_MENU")]
    public const uint32 INTEGER_MENU;
    [CCode (cname = "V4L2_CID_BASE")]
    public const uint32 BASE;
    [CCode (cname = "V4L2_CID_LASTP1")]
    public const uint32 LASTP1;
    [CCode (cname = "V4L2_CID_PRIVATE_BASE")]
    public const uint32 PRIVATE_BASE;
    [CCode (cname = "VIDIOC_QUERYMENU")]
    public const ulong QUERYMENU;
    [CCode (cname = "VIDIOC_G_CTRL")]
    public const ulong G_CTRL;

    /** Read menu metadata through the kernel's native ioctl ABI. */
    [CCode (cname = "ioctl")]
    public int query_menu(int fd, ulong request, ref QueryMenu menu);

    [CCode (cname = "V4L2_CID_PAN_RELATIVE")]
    public const uint32 PAN_RELATIVE;
    [CCode (cname = "V4L2_CID_TILT_RELATIVE")]
    public const uint32 TILT_RELATIVE;
    [CCode (cname = "V4L2_CID_FOCUS_RELATIVE")]
    public const uint32 FOCUS_RELATIVE;
    [CCode (cname = "V4L2_CID_ZOOM_RELATIVE")]
    public const uint32 ZOOM_RELATIVE;
    [CCode (cname = "V4L2_CID_IRIS_RELATIVE")]
    public const uint32 IRIS_RELATIVE;
    [CCode (cname = "V4L2_CTRL_FLAG_EXECUTE_ON_WRITE")]
    public const uint32 EXECUTE_ON_WRITE;

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
