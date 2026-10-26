"""Best-effort hardware frame-rate locking without changing exposure mode."""

import errno
import fcntl
import logging
import struct


# Linux videodev2.h: the numeric CID is stable even when drivers rename the
# control from exposure_auto_priority to exposure_dynamic_framerate.
EXPOSURE_AUTO_PRIORITY = 0x009A0903
QUERYCTRL = 0xC0445624
S_CTRL = 0xC008561C
DISABLED = 0x0001
READ_ONLY = 0x0004
INACTIVE = 0x0010


def lock_framerate(source, descriptor, _caps):
    """Called by v4l2src before format negotiation, using its already-open fd."""
    query = bytearray(68)
    struct.pack_into("=I", query, 0, EXPOSURE_AUTO_PRIORITY)
    try:
        fcntl.ioctl(descriptor, QUERYCTRL, query, True)
        flags = struct.unpack_from("=I", query, 56)[0]
        if flags & (DISABLED | READ_ONLY | INACTIVE):
            logging.warning("%s: camera frame-rate lock control is unavailable", source.get_property("device"))
            return False
        fcntl.ioctl(descriptor, S_CTRL, struct.pack("=Ii", EXPOSURE_AUTO_PRIORITY, 0))
        return True
    except OSError as exc:
        if exc.errno in (errno.EINVAL, errno.ENOTTY):
            logging.warning("%s: camera does not support exposure-driven frame-rate locking", source.get_property("device"))
        else:
            logging.warning("%s: could not lock camera frame rate: %s", source.get_property("device"), exc)
        return False
