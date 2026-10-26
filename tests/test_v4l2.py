import errno
import struct
import unittest
from unittest.mock import Mock, patch

from studio_recorder.v4l2 import EXPOSURE_AUTO_PRIORITY, QUERYCTRL, S_CTRL, lock_framerate


class FrameRateLockTests(unittest.TestCase):
    @patch("studio_recorder.v4l2.fcntl.ioctl")
    def test_disables_dynamic_rate_without_changing_exposure_mode(self, ioctl):
        applied = []
        def driver(descriptor, request, data, *args):
            self.assertEqual(descriptor, 42)
            if request == QUERYCTRL:
                self.assertEqual(struct.unpack_from("=I", data)[0], EXPOSURE_AUTO_PRIORITY)
            elif request == S_CTRL:
                applied.append(struct.unpack("=Ii", data))
        ioctl.side_effect = driver
        self.assertTrue(lock_framerate(Mock(), 42, None))
        self.assertEqual(applied, [(EXPOSURE_AUTO_PRIORITY, 0)])

    @patch("studio_recorder.v4l2.fcntl.ioctl", side_effect=OSError(errno.EINVAL, "Unsupported control"))
    def test_unsupported_camera_warns_and_can_still_capture(self, ioctl):
        with self.assertLogs(level="WARNING"):
            self.assertFalse(lock_framerate(Mock(), 42, None))
        self.assertEqual(ioctl.call_count, 1)

    @patch("studio_recorder.v4l2.fcntl.ioctl")
    def test_read_only_control_is_not_written(self, ioctl):
        def driver(descriptor, request, data, *args):
            struct.pack_into("=I", data, 56, 4)
        ioctl.side_effect = driver
        with self.assertLogs(level="WARNING"):
            self.assertFalse(lock_framerate(Mock(), 42, None))
        self.assertEqual(ioctl.call_count, 1)
