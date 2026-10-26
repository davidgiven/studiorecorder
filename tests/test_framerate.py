import unittest

from studio_recorder.media import Gst, RollingFramerate


class RollingFramerateTests(unittest.TestCase):
    def test_warmup_uses_available_elapsed_time(self):
        rate = RollingFramerate()
        self.assertIsNone(rate.update(0, 0))
        self.assertEqual(rate.update(2 * Gst.SECOND, 60), 30)

    def test_old_frames_leave_window_and_stall_reaches_zero(self):
        rate = RollingFramerate()
        rate.update(0, 0)
        for second in range(1, 11):
            self.assertEqual(rate.update(second * Gst.SECOND, second * 30), 30)
        self.assertEqual(rate.update(15 * Gst.SECOND, 300), 15)
        self.assertEqual(rate.update(20 * Gst.SECOND, 300), 0)

    def test_irregular_updates_interpolate_window_boundary(self):
        rate = RollingFramerate()
        rate.update(0, 0)
        rate.update(4 * Gst.SECOND, 120)
        rate.update(9 * Gst.SECOND, 220)
        # Last ten seconds start at t=2, interpolated count=60.
        self.assertEqual(rate.update(12 * Gst.SECOND, 250), 19)

    def test_counter_reset_starts_a_new_window(self):
        rate = RollingFramerate()
        rate.update(0, 100)
        rate.update(Gst.SECOND, 130)
        self.assertIsNone(rate.update(2 * Gst.SECOND, 0))
        self.assertEqual(rate.update(3 * Gst.SECOND, 20), 20)
