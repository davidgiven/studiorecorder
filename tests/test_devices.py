"""Source routing checks for discovered V4L2 and PipeWire devices."""

import unittest
from unittest.mock import Mock

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gst

from studio_recorder.devices import Camera, Source, v4l2_device_path
from studio_recorder.media import Recorder


class SourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        Gst.init(None)

    def test_pipewire_video_negotiation_excludes_audio(self):
        if not Gst.ElementFactory.find("pipewiresrc"):
            self.skipTest("pipewiresrc not installed")
        element = Gst.ElementFactory.make("pipewiresrc")
        device = Mock()
        device.create_element.return_value = element
        camera = Camera(Source("Portal screen", device, None, "screen"))
        recorder = Recorder([camera], ".", preview=False, record=False)
        self.addCleanup(recorder.close)
        recorder.build()
        # Test the formats offered back to the source, without opening a real
        # portal connection. decodebin alone would leave these as ANY.
        offered = element.get_static_pad("src").peer_query_caps(None)
        self.assertFalse(offered.is_any())
        self.assertFalse(offered.is_empty())
        self.assertTrue(offered.is_subset(Gst.Caps.from_string("video/x-raw")))

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

    def test_v4l2_paths_work_without_device_api_metadata(self):
        for props in ({"api.v4l2.path": "/dev/video0"},
                      {"device.path": "/dev/video0"},
                      {"object.path": "v4l2:/dev/video0"}):
            with self.subTest(props=props):
                self.assertEqual(v4l2_device_path(props), "/dev/video0")

    def test_pipewire_node_ids_are_not_used_as_v4l2_paths(self):
        self.assertIsNone(v4l2_device_path({"device.path": "42", "object.path": "alsa:acp:Device:0:capture"}))

    def test_named_audio_opens_exact_pulse_source(self):
        if not Gst.ElementFactory.find("pulsesrc"):
            self.skipTest("pulsesrc not installed")
        device = Mock()
        source = Source("Microphone", device, "usb-camera", "audio-node",
                        audio_name="alsa_input.usb-camera.analog-stereo")
        element = source.create_element()
        self.assertEqual(element.get_factory().get_name(), "pulsesrc")
        self.assertEqual(element.get_property("device"), "alsa_input.usb-camera.analog-stereo")
        device.create_element.assert_not_called()
