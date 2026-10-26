import os
import unittest
from unittest.mock import Mock, patch

from studio_recorder.desktop import DesktopCapture, GLib, primary_monitor_geometry


class DesktopCaptureTests(unittest.TestCase):
    @patch.dict(os.environ, {"DISPLAY": ":42", "XDG_SESSION_TYPE": "x11"}, clear=True)
    @patch("studio_recorder.desktop.x11_primary_monitor", return_value=(1400, 200, 3840, 2160))
    def test_x11_includes_screen_and_default_output_monitor(self, _monitor):
        ready, error = Mock(), Mock()
        capture = DesktopCapture(ready, error)
        capture.start()
        inputs = ready.call_args.args[0]
        self.assertEqual(len(inputs), 1)
        self.assertEqual(inputs[0].source.device.factory, "ximagesrc")
        props = inputs[0].source.device.properties
        self.assertEqual((props["startx"], props["starty"], props["endx"], props["endy"]),
                         (1400, 200, 5239, 2359))
        self.assertEqual(inputs[0].audio.device.factory, "pulsesrc")
        self.assertEqual(inputs[0].audio.device.properties["device"], "@DEFAULT_MONITOR@")
        error.assert_not_called()
        capture.close()

    @patch.dict(os.environ, {"DISPLAY": ":42", "WAYLAND_DISPLAY": "wayland-0"}, clear=True)
    @patch("studio_recorder.desktop.Gio.bus_get")
    def test_wayland_uses_portal_instead_of_xwayland(self, bus_get):
        capture = DesktopCapture(Mock(), Mock())
        capture.start()
        bus_get.assert_called_once()
        capture.ready.assert_not_called()
        capture.close()

    def test_denied_portal_request_does_not_start_recording(self):
        capture = DesktopCapture(Mock(), Mock())
        capture.connection = Mock()
        capture.connection.get_unique_name.return_value = ":1.99"
        capture._request("CreateSession", None, {}, Mock())
        callback = capture.connection.signal_subscribe.call_args.args[-1]
        callback(None, None, None, None, None, GLib.Variant("(ua{sv})", (1, {})))
        capture.ready.assert_not_called()
        self.assertIn("cancelled or denied", capture.error.call_args.args[0])
        capture.close()

    def test_portal_stream_includes_computer_audio_and_releases_remote(self):
        capture = DesktopCapture(Mock(), Mock())
        capture.connection = Mock()
        capture.session = "/session/test"
        descriptor = os.open(os.devnull, os.O_RDONLY)
        descriptors = Mock()
        descriptors.get.return_value = descriptor
        capture.connection.call_with_unix_fd_list_finish.return_value = (GLib.Variant("(h)", (0,)), descriptors)
        capture._started({"streams": [(5, {"pipewire-serial": 123})]})
        opened = capture.connection.call_with_unix_fd_list.call_args.args[-1]
        opened(capture.connection, Mock())
        inputs = capture.ready.call_args.args[0]
        self.assertEqual(len(inputs), 1)
        self.assertEqual(inputs[0].audio.identity, "desktop-audio")
        self.assertEqual(inputs[0].source.device.properties["target_object"], "123")
        capture.close()
        with self.assertRaises(OSError):
            os.fstat(descriptor)

    def test_primary_monitor_is_not_assumed_to_be_first_or_at_origin(self):
        layout = "HDMI-0 connected 1400x900+0+0 (normal)\nDP-0 connected primary 3840x2160+1400+200 (normal)\n"
        self.assertEqual(primary_monitor_geometry(layout), (1400, 200, 3840, 2160))

    def test_single_active_monitor_is_used_without_primary_flag(self):
        self.assertEqual(primary_monitor_geometry("DP-0 connected 1920x1080+0+0 (normal)"),
                         (0, 0, 1920, 1080))

    def test_multiple_monitors_without_primary_are_not_captured_together(self):
        with self.assertRaisesRegex(RuntimeError, "No active primary"):
            primary_monitor_geometry("DP-0 connected 1920x1080+0+0\nDP-1 connected 1920x1080+1920+0")

    def test_portal_rejects_multiple_monitor_streams(self):
        capture = DesktopCapture(Mock(), Mock())
        with self.assertRaisesRegex(RuntimeError, "only the primary monitor"):
            capture._started({"streams": [(5, {}), (6, {})]})
        capture.ready.assert_not_called()

    def test_portal_requests_single_monitor_selection(self):
        capture = DesktopCapture(Mock(), Mock())
        capture.connection = Mock()
        capture._request = Mock()
        capture._created({"session_handle": "/session/test"})
        options = capture._request.call_args.args[2]
        self.assertFalse(options["multiple"].unpack())
        self.assertEqual(options["types"].unpack(), 1)
        capture.close()
