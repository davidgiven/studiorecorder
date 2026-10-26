/* Only APIs without convenient Vala declarations live here. No media processing. */
#include "native.h"
#include <X11/Xlib.h>
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <stdlib.h>
#include <math.h>
#include <errno.h>
#include <string.h>

/* Disable dynamic frame intervals through the already-open camera descriptor; keep exposure mode intact. */
static void prepare_format(GstElement *source, gint fd, GstCaps *caps, gpointer data) {
    (void)caps; (void)data;
    struct v4l2_queryctrl query = { .id = V4L2_CID_EXPOSURE_AUTO_PRIORITY };
    struct v4l2_control control = { .id = V4L2_CID_EXPOSURE_AUTO_PRIORITY, .value = 0 };

    /* Check writability before changing this optional control; unsupported cameras keep running. */
    if (ioctl(fd, VIDIOC_QUERYCTRL, &query) < 0 ||
        (query.flags & (V4L2_CTRL_FLAG_DISABLED | V4L2_CTRL_FLAG_READ_ONLY | V4L2_CTRL_FLAG_INACTIVE))) {
        g_warning("%s: exposure-driven frame-rate control unavailable", GST_OBJECT_NAME(source));
        return;
    }

    /* A failed write is diagnostic only and must not prevent capture. */
    if (ioctl(fd, VIDIOC_S_CTRL, &control) < 0)
        g_warning("%s: cannot lock camera frame rate: %s", GST_OBJECT_NAME(source), strerror(errno));
}

/* Attach the callback before v4l2src negotiates its capture format. */
void studio_lock_framerate(GstElement *source) {
    g_signal_connect(source, "prepare-format", G_CALLBACK(prepare_format), NULL);
}

/* Map channel RMS values from the level plugin's legacy GValueArray to a normalized UI meter. */
double studio_level_rms(const GstStructure *structure) {
    const GValue *value = gst_structure_get_value(structure, "rms");
    double loudest = -60.0;

    /* Ignore non-finite readings and keep the loudest channel without downmixing audio. */
    if (value && G_VALUE_HOLDS(value, G_TYPE_VALUE_ARRAY)) {
        GValueArray *array = g_value_get_boxed(value);
        for (guint i = 0; array && i < array->n_values; ++i) {
            double db = g_value_get_double(g_value_array_get_nth(array, i));
            if (isfinite(db) && db > loudest) loudest = db;
        }
    }

    /* Match the UI's -60 to 0 dBFS display range. */
    return CLAMP((loudest + 60.0) / 60.0, 0.0, 1.0);
}

/* Initialize Xlib threading before GTK and GStreamer use the display. */
int studio_xinit_threads(void) { return XInitThreads(); }

/* Resolve filesystem links and copy libc-owned storage into a GLib-owned string. */
char *studio_realpath(const char *path) {
    char *resolved = realpath(path, NULL);
    char *result = resolved ? g_strdup(resolved) : NULL;
    free(resolved);
    return result;
}
