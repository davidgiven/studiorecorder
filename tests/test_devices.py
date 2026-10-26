"""Source routing checks for discovered V4L2 and PipeWire devices."""

import unittest
from unittest.mock import Mock

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gst

from studio_recorder.devices import Source


class SourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        Gst.init(None)

    def test_v4l2_camera_opens_advertised_device_directly(self):
        if not Gst.ElementFactory.find("v4l2src"):
            self.skipTest("v4l2src not installed")
        device = Mock()
        source = Source("Camera", device, "usb-camera", "camera-node", "/dev/video42")
        element = source.create_element()
        self.assertEqual(element.get_factory().get_name(), "v4l2src")
        self.assertEqual(element.get_property("device"), "/dev/video42")
        device.create_element.assert_not_called()

    def test_audio_retains_provider_capture_element(self):
        device = Mock()
        source = Source("Microphone", device, "usb-camera", "audio-node")
        self.assertIs(source.create_element(), device.create_element.return_value)
        device.create_element.assert_called_once_with(None)
