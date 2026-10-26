"""Initial PipeWire discovery and conservative camera/audio association."""

from dataclasses import dataclass
from pathlib import Path
import re

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gst

from .v4l2 import lock_framerate


@dataclass
class Source:
    name: str
    device: object
    physical_id: str | None
    identity: str
    video_path: str | None = None
    audio_name: str | None = None

    def create_element(self):
        if self.video_path:
            # PipeWire can advertise a webcam that cannot be opened as a
            # PipeWire stream. Use its V4L2 path, retaining discovery metadata.
            element = Gst.ElementFactory.make("v4l2src")
            if element is None:
                raise RuntimeError("Missing GStreamer element: v4l2src")
            element.set_property("device", self.video_path)
            element.connect("prepare-format", lock_framerate)
        elif self.audio_name:
            element = Gst.ElementFactory.make("pulsesrc")
            if element is None:
                raise RuntimeError("Missing GStreamer element: pulsesrc")
            # pipewire-pulse exposes source node names as PulseAudio device
            # names. Avoid provider-created pipewiresrc numeric targets, which
            # can become invalid across PipeWire/device-profile changes.
            element.set_property("device", self.audio_name)
        else:
            element = self.device.create_element(None)
        if element is None:
            raise RuntimeError(f"Cannot create capture source for {self.name}")
        return element


@dataclass
class Camera:
    source: Source
    audio: Source | None = None


def properties(device):
    props = device.get_properties()
    if props is None:
        return {}
    return {props.nth_field_name(i): props.get_value(props.nth_field_name(i))
            for i in range(props.n_fields())}


def v4l2_device_path(props):
    # PipeWire versions expose different metadata; device.api is not always
    # present. Only accept physical video paths, never arbitrary node IDs.
    for key in ("api.v4l2.path", "device.path", "object.path"):
        path = str(props.get(key, "")).removeprefix("v4l2:")
        if re.fullmatch(r"/dev/video\d+", path):
            return path
    return None


def usb_parent(path):
    """Return a physical USB device, rather than its audio/video interface."""
    resolved = Path(path).resolve()
    for parent in (resolved, *resolved.parents):
        if (parent / "idVendor").exists() and (parent / "idProduct").exists():
            return str(parent)
    return None


def physical_id(props):
    video_path = v4l2_device_path(props)
    if video_path:
        parent = usb_parent(Path("/sys/class/video4linux") / Path(str(video_path)).name / "device")
        if parent:
            return parent
    card = props.get("api.alsa.pcm.card") or props.get("alsa.card")
    if card is not None:
        parent = usb_parent(Path(f"/sys/class/sound/card{card}/device"))
        if parent:
            return parent
    # PipeWire also exposes the kernel USB bus identity when sysfs is unavailable.
    bus = props.get("api.v4l2.cap.bus_info")
    if bus and str(bus).startswith("usb-"):
        return str(bus)
    long_name = props.get("alsa.long_card_name", "")
    match = re.search(r" at (usb-[^, ]+)", str(long_name))
    return match.group(1) if match else None


class Registry:
    def __init__(self):
        self.provider = None
        self.audio_sources = []

    def discover(self):
        # Use one backend so the same hardware is not captured through both
        # PipeWire and PulseAudio. PipeWire supplies V4L2 and ALSA metadata.
        self.provider = Gst.DeviceProviderFactory.get_by_name("pipewiredeviceprovider")
        if self.provider is None or not self.provider.start():
            raise RuntimeError("PipeWire device discovery is unavailable. Check the desktop PipeWire service and GStreamer PipeWire plugin.")
        videos, audios = [], []
        seen = set()
        for device in self.provider.get_devices():
            kind = device.get_device_class()
            if kind not in ("Video/Source", "Audio/Source"):
                continue
            props = properties(device)
            if props.get("device.class") == "monitor" or str(props.get("node.name", "")).endswith(".monitor"):
                continue
            identity = str(props.get("object.path") or props.get("node.name") or device.get_display_name())
            if (kind, identity) in seen:
                continue
            seen.add((kind, identity))
            video_path = v4l2_device_path(props) if kind == "Video/Source" else None
            audio_name = props.get("node.name") if kind == "Audio/Source" else None
            source = Source(device.get_display_name(), device, physical_id(props), identity,
                            video_path, audio_name)
            (videos if kind == "Video/Source" else audios).append(source)
        cameras = []
        self.audio_sources = sorted(audios, key=lambda source: (source.name, source.identity))
        for video in sorted(videos, key=lambda item: item.identity):
            matches = [audio for audio in audios
                       if video.physical_id and audio.physical_id == video.physical_id]
            # Leave ambiguous matches unassigned so the paused device selector
            # can resolve them without guessing or preventing application startup.
            cameras.append(Camera(video, matches[0] if len(matches) == 1 else None))
        return cameras

    def stop(self):
        if self.provider is not None:
            self.provider.stop()
            self.provider = None


class TestDevice:
    """Synthetic sources are only enabled by the explicit development flag."""

    def __init__(self, video, index):
        self.video, self.index = video, index

    def create_element(self, _name):
        element = Gst.ElementFactory.make("videotestsrc" if self.video else "audiotestsrc")
        element.set_property("is-live", True)
        if self.video:
            element.set_property("pattern", self.index)
        else:
            element.set_property("freq", 440 + 220 * self.index)
        return element


def test_cameras():
    audio = Source("Test microphone", TestDevice(False, 0), "test", "test-audio")
    cameras = [Camera(Source(f"Test camera {i + 1}", TestDevice(True, i), "test", f"test-video-{i}"), audio)
               for i in range(2)]
    screen = Source("Screen", TestDevice(True, 2), None, "desktop-screen")
    computer_audio = Source("Computer audio", TestDevice(False, 2), None, "desktop-audio")
    return cameras + [Camera(screen, computer_audio)]
