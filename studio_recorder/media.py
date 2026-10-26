"""One pipeline, one multitrack Matroska writer, native preview rendering."""

from datetime import datetime
from collections import deque
from pathlib import Path
import os
import uuid

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gst


def make(factory, **props):
    element = Gst.ElementFactory.make(factory)
    if element is None:
        raise RuntimeError(f"Missing GStreamer element: {factory}")
    for name, value in props.items():
        element.set_property(name.replace("_", "-"), value)
    return element


def caps(value):
    return make("capsfilter", caps=Gst.Caps.from_string(value))


def queue(preview=False):
    return make("queue", max_size_time=2 * Gst.SECOND if not preview else 200 * Gst.MSECOND,
                max_size_buffers=0, max_size_bytes=0, leaky=2 if preview else 0)


def track_tags(title, comment):
    tags = Gst.TagList.new_empty()
    tags.set_scope(Gst.TagScope.STREAM)
    tags.add_value(Gst.TagMergeMode.REPLACE, Gst.TAG_TITLE, title)
    tags.add_value(Gst.TagMergeMode.REPLACE, Gst.TAG_COMMENT, comment)
    # taginject prepends "taglist," itself; keep Gst's escaping of values.
    return make("taginject", tags=tags.to_string().partition(",")[2].strip())


def encoder_factory(test_sources=False):
    if test_sources:
        return "x264enc"
    for factory in ("vah264enc", "vah264lpenc", "nvh264enc", "nvautogpuh264enc",
                    "qsvh264enc", "vaapih264enc", "v4l2h264enc"):
        if Gst.ElementFactory.find(factory):
            return factory
    raise RuntimeError("No hardware H.264 encoder is available. Install the GStreamer plugin and GPU driver for VA-API, NVIDIA, Quick Sync, or V4L2 encoding. Software encoding is only used with --test-sources.")


class RollingFramerate:
    """Ten-second rate from timestamped cumulative native frame counts."""

    def __init__(self):
        self.samples = deque()

    def update(self, now, rendered):
        if self.samples and (now < self.samples[-1][0] or rendered < self.samples[-1][1]):
            self.samples.clear()
        if self.samples and now == self.samples[-1][0]:
            return None
        self.samples.append((now, rendered))
        cutoff = now - 10 * Gst.SECOND
        # Keep one sample at/before the boundary for interpolation when the
        # half-second UI timer is delayed or does not land on it exactly.
        while len(self.samples) > 1 and self.samples[1][0] <= cutoff:
            self.samples.popleft()
        start, initial = self.samples[0]
        if start < cutoff and len(self.samples) > 1:
            next_time, next_count = self.samples[1]
            initial += (next_count - initial) * (cutoff - start) / (next_time - start)
            start = cutoff
        return (rendered - initial) * Gst.SECOND / (now - start) if now > start else None


class Recorder:
    def __init__(self, cameras, directory, *, preview=True, test_sources=False, record=True, additional_audio=()):
        self.pipeline = Gst.Pipeline.new("studio-recorder")
        self.previews = []
        self.preview_sinks = {}
        self._recording_samples = {}
        self.recording_counters = {}
        self.video_caps_pads = {}
        self.level_sources = {}
        self.source_labels = {}
        self.final_path = None
        self.partial_path = None
        self.started = False
        self.finished = False
        self._requested_pads = []
        self.record = record
        self.encoder = encoder_factory(test_sources) if record else None
        self.cameras = cameras
        self.additional_audio = additional_audio
        self.test_sources = test_sources
        self.preview = preview
        self.directory = Path(directory)

    def add_chain(self, *elements):
        for element in elements:
            self.pipeline.add(element)
        for left, right in zip(elements, elements[1:]):
            if not left.link(right):
                raise RuntimeError(f"Cannot link {left.name} to {right.name}")

    def mux_track(self, tail, kind):
        pad = self.mux.request_pad_simple(f"{kind}_%u")
        if pad is None or tail.get_static_pad("src").link(pad) != Gst.PadLinkReturn.OK:
            raise RuntimeError(f"Cannot attach {kind} track to Matroska muxer")
        self._requested_pads.append(pad)

    def build(self):
        if not self.cameras:
            raise RuntimeError("Cannot record without cameras")
        if self.preview and not Gst.ElementFactory.find("gtk4paintablesink"):
            raise RuntimeError("Missing gtk4paintablesink. Install the GStreamer GTK 4 plugin (gst-plugin-gtk4).")
        if self.record:
            # Reserve exclusively; even concurrent launches must not overwrite output.
            stamp = datetime.now().astimezone().strftime("%Y-%m-%d_%H-%M-%S_%f%z")
            self.final_path = self.directory / f"StudioRecorder_{stamp}_{uuid.uuid4().hex[:8]}.mkv"
            self.partial_path = self.final_path.with_suffix(".mkv.partial")
            with self.partial_path.open("xb"):
                pass
            self.mux = make("matroskamux", writing_app="StudioRecorder", offset_to_zero=True)
            self.sink = make("filesink", location=str(self.partial_path), sync=False)
            self.add_chain(self.mux, self.sink)
        audio_inputs = {source.identity: source for source in self.additional_audio}
        for camera in self.cameras:
            self.add_video(camera)
            if camera.audio:
                audio_inputs[camera.audio.identity] = camera.audio
        for audio in audio_inputs.values():
            associated = [c.source.name for c in self.cameras
                          if c.audio and c.audio.identity == audio.identity]
            self.add_audio(audio, associated)

    def add_video(self, camera):
        source = camera.source.create_element()
        decoder = make("decodebin")
        label = f"Video input {camera.source.name!r} [{camera.source.identity}]"
        self.source_labels[source.name] = label
        self.source_labels[decoder.name] = label
        tee = make("tee")
        if source.get_factory().get_name() == "pipewiresrc":
            # Portal sources advertise ANY. Constrain negotiation to video:
            # decodebin also accepts audio, so it cannot supply this constraint.
            self.add_chain(source, caps("video/x-raw"), decoder)
        else:
            self.add_chain(source, decoder)
        self.pipeline.add(tee)
        self.video_caps_pads[camera.source.identity] = tee.get_static_pad("sink")

        def decoded(_decoder, pad):
            current = pad.get_current_caps() or pad.query_caps(None)
            if current and current.to_string().startswith("video/x-raw"):
                target = tee.get_static_pad("sink")
                if not target.is_linked() and pad.link(target) != Gst.PadLinkReturn.OK:
                    structure = Gst.Structure.new_empty("studio-recorder-error")
                    structure.set_value("message", f"Cannot link decoded video for {camera.source.name}")
                    self.pipeline.post_message(Gst.Message.new_application(self.pipeline, structure))

        decoder.connect("pad-added", decoded)
        if self.record:
            record_queue = queue()
            converter = make("videoconvert")
            scaler = make("videoscale")
            raw_caps = "video/x-raw,format=NV12"
            if self.test_sources:
                raw_caps = "video/x-raw,format=I420"
            raw_filter = caps(raw_caps)
            encoder = make(self.encoder)
            if self.test_sources:
                encoder.set_property("tune", "zerolatency")
                encoder.set_property("speed-preset", "ultrafast")
            elif encoder.find_property("bitrate"):
                encoder.set_property("bitrate", 8000)
            parser = make("h264parse")
            encoded_filter = caps("video/x-h264,stream-format=avc,alignment=au")
            tags = track_tags(camera.source.name, f"Video source: {camera.source.identity}; audio: {camera.audio.name if camera.audio else 'none'}")
            # Encoders may buffer; a queue after encoding lets the muxer interleave
            # without blocking another camera's encoder startup.
            encoded_queue = queue()
            # AU alignment makes each native counter increment one complete
            # encoded frame. No Python per-frame probes or handoff callbacks.
            counter = make("identity", silent=True, signal_handoffs=False)
            self.add_chain(record_queue, converter, scaler, raw_filter, encoder, parser, encoded_filter, tags, counter, encoded_queue)
            self.recording_counters[camera.source.identity] = counter
            if not tee.link(record_queue):
                raise RuntimeError("Cannot attach recording video branch")
            self.mux_track(encoded_queue, "video")
        if self.preview:
            preview_queue, preview_converter = queue(True), make("videoconvert")
            sink = make("gtk4paintablesink", sync=False)
            sink.set_property("async", False)
            self.add_chain(preview_queue, preview_converter, sink)
            if not tee.link(preview_queue):
                raise RuntimeError("Cannot attach preview")
            self.previews.append((camera, sink.get_property("paintable")))
            self.preview_sinks[camera.source.identity] = sink

        elif not self.record:
            preview_queue, sink = queue(True), make("fakesink", sync=False)
            sink.set_property("async", False)
            self.add_chain(preview_queue, sink)
            if not tee.link(preview_queue):
                raise RuntimeError("Cannot attach headless preview")

    def preview_resolutions(self):
        resolutions = {}
        for identity, sink in self.preview_sinks.items():
            negotiated = sink.get_static_pad("sink").get_current_caps()
            if negotiated:
                structure = negotiated.get_structure(0)
                has_width, width = structure.get_int("width")
                has_height, height = structure.get_int("height")
                if has_width and has_height:
                    resolutions[identity] = (width, height)
        return resolutions

    def recording_framerates(self):
        """Capture target FPS and encoded recording FPS over the last ten seconds."""
        now = Gst.util_get_timestamp()
        rates = {}
        for identity, pad in self.video_caps_pads.items():
            target = None
            negotiated = pad.get_current_caps()
            if negotiated:
                valid, numerator, denominator = negotiated.get_structure(0).get_fraction("framerate")
                if valid and numerator > 0 and denominator > 0:
                    target = numerator / denominator
            actual = None
            counter = self.recording_counters.get(identity)
            if counter is not None:
                encoded = counter.get_property("stats").get_value("num-buffers")
                history = self._recording_samples.setdefault(identity, RollingFramerate())
                actual = history.update(now, encoded)
            rates[identity] = (target, actual)
        return rates

    def add_audio(self, source_info, cameras):
        source = source_info.create_element()
        self.source_labels[source.name] = f"Audio input {source_info.name!r} [{source_info.identity}]"
        converter, resampler = make("audioconvert"), make("audioresample")
        raw_filter = caps("audio/x-raw,format=F32LE,layout=interleaved,rate=48000")
        meter = make("level", interval=50 * Gst.MSECOND, post_messages=True)
        tags = track_tags(source_info.name, f"Audio source: {source_info.identity}; cameras: {', '.join(cameras)}")
        audio_queue = queue()
        self.add_chain(source, converter, resampler, raw_filter, meter, tags, audio_queue)
        self.level_sources[meter.name] = source_info.identity
        if self.record:
            self.mux_track(audio_queue, "audio")
        else:
            sink = make("fakesink", sync=False)
            sink.set_property("async", False)
            self.pipeline.add(sink)
            if not audio_queue.link(sink):
                raise RuntimeError("Cannot attach audio meter preview")

    def describe_error(self, message):
        error, debug = message.parse_error()
        element = message.src
        label = None
        while element is not None:
            label = self.source_labels.get(element.name)
            if label:
                break
            element = element.get_parent()
        detail = f"{message.src.get_path_string()}: {error.message}"
        if label:
            detail = f"{label}\n{detail}"
        if debug:
            detail += f"\n{debug}"
        return detail

    def start(self):
        result = self.pipeline.set_state(Gst.State.PLAYING)
        self.started = result != Gst.StateChangeReturn.FAILURE
        if not self.started:
            # A synchronous failure precedes dispatch of the GLib bus watch.
            # Preserve the useful errors before application cleanup flushes it.
            errors = []
            bus = self.pipeline.get_bus()
            while (message := bus.pop_filtered(Gst.MessageType.ERROR)) is not None:
                errors.append(self.describe_error(message))
            detail = "\n".join(errors) or "No GStreamer error was posted; rerun with GST_DEBUG=2 for driver and negotiation diagnostics."
            if self.record:
                summary = f"Recording pipeline could not start (encoder: {self.encoder})"
            else:
                summary = "Live preview pipeline could not start (no encoder is used while paused)"
            raise RuntimeError(f"{summary}:\n{detail}")

    def stop(self):
        # There is no ongoing preview after this skeleton stops: EOS can drain
        # the whole graph. The shared muxer waits for EOS from every input.
        return self.pipeline.send_event(Gst.Event.new_eos())

    def close(self, finalized=False):
        self.pipeline.set_state(Gst.State.NULL)
        for pad in self._requested_pads:
            self.mux.release_request_pad(pad)
        self._requested_pads.clear()
        if finalized and self.record and self.partial_path:
            # hard link creates the final name without replacing any existing
            # file, then removes only this take's temporary name.
            os.link(self.partial_path, self.final_path)
            self.partial_path.unlink()
        self.finished = True
