"""Integration checks against real GStreamer pipelines and output files."""

import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("ffprobe") and shutil.which("ffmpeg"), "ffprobe and ffmpeg are required")
class RecordingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.env = dict(os.environ, PYTHONPATH=str(ROOT), GST_REGISTRY=str(self.directory / "gst-registry.bin"))

    def launch(self, *args, code=None, auto_start=True):
        if code is None and not args and auto_start:
            code = """
from studio_recorder.app import Application, GLib, Gst
Gst.init(None)
app = Application(test_sources=True, headless=True)
def play_when_ready():
    if app.state == "paused":
        app.start_recording()
        return GLib.SOURCE_REMOVE
    return GLib.SOURCE_CONTINUE
GLib.timeout_add(50, play_when_ready)
raise SystemExit(app.run())
"""
        command = [sys.executable, "-c", code] if code else [sys.executable, "-m", "studio_recorder", "--test-sources", "--headless", *args]
        process = subprocess.Popen(command, cwd=self.directory, env=self.env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, bufsize=1)
        self.addCleanup(self.terminate, process)
        return process

    @staticmethod
    def terminate(process):
        if process.poll() is None:
            process.kill()
        process.wait()
        process.stdout.close()

    def wait_for_recording(self, process, marker=b"\nRecording:"):
        # Read bytes to avoid TextIO buffering hiding already-ready lines from
        # select. Waiting for readiness makes the signal test deterministic.
        output = b""
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if selector.select(0.2):
                    chunk = os.read(process.stdout.fileno(), 4096)
                    output += chunk
                    if marker in output:
                        return output.decode()
                    if not chunk:
                        break
        self.fail(f"Recording never started: {output.decode()}")

    def verify_output(self, process, prior_output="", expected_files=1):
        output, _ = process.communicate(timeout=20)
        self.assertEqual(process.returncode, 0, prior_output + output)
        files = list(self.directory.glob("*.mkv"))
        self.assertEqual(len(files), expected_files, prior_output + output)
        self.assertFalse(list(self.directory.glob("*.partial")))
        for path in files:
            self.verify_file(path)

    def verify_file(self, path):
        data = json.loads(subprocess.check_output([
            "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]))
        video = [s for s in data["streams"] if s["codec_type"] == "video"]
        audio = [s for s in data["streams"] if s["codec_type"] == "audio"]
        self.assertEqual(len(video), 3, "Both cameras and the screen must be recorded")
        self.assertEqual(len(audio), 2, "Record computer audio once, and deduplicate the shared microphone")
        self.assertEqual([s["codec_name"] for s in video], ["h264"] * 3)
        for stream in audio:
            self.assertEqual(stream["codec_name"], "pcm_f32le")
            self.assertEqual(stream["sample_rate"], "48000")
        self.assertTrue(any("Computer" in s["tags"].get("TITLE", "") for s in audio))
        self.assertTrue(any("Screen" in s["tags"].get("TITLE", "") for s in video))
        self.assertGreater(float(data["format"]["duration"]), 0)
        self.assertLess(float(data["format"]["duration"]), 5, "A new take must not retain the previous timeline")
        for stream in data["streams"]:
            self.assertTrue(stream["tags"].get("TITLE"))
            self.assertTrue(stream["tags"].get("COMMENTS"))
        # Decode all tracks, not just the default video/audio selection.
        decoded = subprocess.run(["ffmpeg", "-v", "error", "-xerror", "-i", str(path),
                                  "-map", "0", "-f", "null", "-"], capture_output=True, text=True, timeout=15)
        self.assertEqual(decoded.returncode, 0, decoded.stderr)

    def test_timed_recording(self):
        self.verify_output(self.launch("--duration", "1"))

    def test_recording_fps_measures_encoded_frames_without_preview(self):
        code = """
from studio_recorder.app import Application, GLib, Gst
Gst.init(None)
app = Application(test_sources=True, headless=True)
sample_start = None
def check_rates():
    global sample_start
    if app.state == "paused":
        assert all(actual is None for target, actual in app.recorder.recording_framerates().values())
        app.start_recording()
    elif app.state == "recording":
        rates = app.recorder.recording_framerates()
        if sample_start is None:
            sample_start = Gst.util_get_timestamp()
        elif Gst.util_get_timestamp() - sample_start > Gst.SECOND:
            assert len(rates) == 3
            assert not app.recorder.preview_sinks
            for target, actual in rates.values():
                assert target == 30, rates
                assert 25 < actual < 35, rates
            app.on_close(None)
            return GLib.SOURCE_REMOVE
    return GLib.SOURCE_CONTINUE
GLib.timeout_add(100, check_rates)
raise SystemExit(app.run())
"""
        self.verify_output(self.launch(code=code))

    def test_synchronous_startup_error_keeps_gstreamer_diagnostic(self):
        from studio_recorder.devices import test_cameras
        from studio_recorder.media import Gst, Recorder

        Gst.init(None)
        recorder = Recorder(test_cameras(), self.directory, preview=False, test_sources=True)
        try:
            recorder.build()
            missing = self.directory / "nonexistent-directory" / "recording.mkv"
            recorder.sink.set_property("location", str(missing))
            with self.assertRaises(RuntimeError) as caught:
                recorder.start()
            diagnostic = str(caught.exception)
            self.assertIn("filesink", diagnostic)
            self.assertIn(str(missing), diagnostic)
            self.assertIn("encoder: x264enc", diagnostic)
            self.assertFalse(recorder.started)
        finally:
            recorder.close()

    def test_ctrl_c_finalizes(self):
        process = self.launch()
        output = self.wait_for_recording(process)
        time.sleep(0.3)
        process.send_signal(signal.SIGINT)
        self.verify_output(process, output)

    def test_window_close_handler_finalizes(self):
        # Invoke the same handler attached to Gtk.Window.close-request, with no
        # display dependency. Actual GTK rendering requires a desktop smoke test.
        code = """
from studio_recorder.app import Application, GLib, Gst
Gst.init(None)
app = Application(test_sources=True, headless=True)
def close_when_playing():
    if app.state == "paused":
        app.start_recording()
    if app.state == "recording":
        state = app.recorder.pipeline.get_state(0)[1]
        if state == Gst.State.PLAYING:
            app.on_close(None)
            return GLib.SOURCE_REMOVE
    return GLib.SOURCE_CONTINUE
GLib.timeout_add(500, close_when_playing)
raise SystemExit(app.run())
"""
        self.verify_output(self.launch(code=code))

    def test_launch_stopped_creates_no_file(self):
        process = self.launch(auto_start=False)
        output = self.wait_for_recording(process, b"Paused")
        time.sleep(0.3)
        self.assertFalse(list(self.directory.glob("*.mkv*")))
        process.send_signal(signal.SIGINT)
        rest, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, output + rest)
        self.assertFalse(list(self.directory.glob("*.mkv*")))

    def test_audio_selection_is_not_starved_by_busy_preview(self):
        code = """
from studio_recorder.app import Application, GLib, Gst
from studio_recorder.devices import Source, TestDevice
Gst.init(None)
app = Application(test_sources=True, headless=True)
phase = 0
busy_source = None
previous = None
def exercise_audio():
    global phase, busy_source, previous
    if phase == 0 and app.state == "paused":
        previous = app.recorder
        app.audio_sources.append(Source("Alternate microphone", TestDevice(False, 3), None, "alternate-audio"))
        assert app.select_audio("test-video-0", "alternate-audio")
        # Model continuously ready preview/GTK work ahead of default idle work.
        busy_source = GLib.idle_add(lambda: GLib.SOURCE_CONTINUE,
                                   priority=GLib.PRIORITY_DEFAULT_IDLE - 10)
        phase = 1
    elif phase == 1 and app.state == "paused":
        assert app.recorder is not previous
        assert "alternate-audio" in app.recorder.level_sources.values()
        GLib.source_remove(busy_source)
        app.on_close(None)
        return GLib.SOURCE_REMOVE
    return GLib.SOURCE_CONTINUE
def watchdog():
    app.fail("Audio selection was starved by preview work")
    return GLib.SOURCE_REMOVE
GLib.timeout_add(50, exercise_audio)
GLib.timeout_add_seconds(3, watchdog)
raise SystemExit(app.run())
"""
        process = self.launch(code=code)
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, output)
        self.assertFalse(list(self.directory.glob("*.mkv*")))

    def test_audio_selection_updates_next_take_and_is_locked_while_recording(self):
        code = """
from studio_recorder.app import Application, GLib, Gst
from studio_recorder.devices import Source, TestDevice
Gst.init(None)
app = Application(test_sources=True, headless=True)
phase = 0
def exercise_audio():
    global phase
    if app.state == "paused":
        if phase == 0:
            app.audio_sources.append(Source("Alternate microphone", TestDevice(False, 3), None, "alternate-audio"))
            assert not app.select_audio("test-video-0", "missing-device")
            assert app.select_audio("test-video-0", "alternate-audio")
            phase = 1
        elif phase == 1:
            assert app.select_audio("test-video-1", None)
            phase = 2
        elif phase == 2:
            assert app.select_audio("desktop-screen", None)
            phase = 3
        elif phase == 3:
            app.start_recording()
            phase = 4
        elif phase == 5:
            assert app.sources[0].audio.identity == "alternate-audio"
            assert app.sources[1].audio is None
            app.on_close(None)
            return GLib.SOURCE_REMOVE
    elif phase == 4 and app.state == "recording":
        assert not app.select_audio("test-video-0", "test-audio")
        assert app.sources[0].audio.identity == "alternate-audio"
        if Gst.util_get_timestamp() - app.recording_started_at > 400 * Gst.MSECOND:
            app.request_stop()
            phase = 5
    return GLib.SOURCE_CONTINUE
GLib.timeout_add(50, exercise_audio)
raise SystemExit(app.run())
"""
        self.verify_output(self.launch(code=code))
        path = next(self.directory.glob("*.mkv"))
        data = json.loads(subprocess.check_output([
            "ffprobe", "-v", "error", "-show_streams", "-of", "json", str(path)]))
        names = [stream["tags"].get("TITLE", "") for stream in data["streams"]
                 if stream["codec_type"] == "audio"]
        self.assertTrue(any("Alternate" in name for name in names))
        self.assertFalse(any("Test" in name for name in names))

    def test_stop_finalizes_then_play_starts_new_take(self):
        code = """
from pathlib import Path
from studio_recorder.app import Application, GLib, Gst
Gst.init(None)
app = Application(test_sources=True, headless=True)
phase = 0
def exercise_controls():
    global phase
    if phase == 0 and app.state == "paused":
        assert not list(Path('.').glob('*.mkv*'))
        app.start_recording()
        app.start_recording()  # A duplicate click cannot create a second writer.
        phase = 1
    elif phase in (1, 3) and app.state == "recording":
        if Gst.util_get_timestamp() - app.recording_started_at > 400 * Gst.MSECOND:
            if phase == 1:
                app.request_stop()
                app.request_stop()
                phase = 2
            else:
                app.on_close(None)
                return GLib.SOURCE_REMOVE
    elif phase == 2 and app.state == "paused":
        assert len(list(Path('.').glob('*.mkv'))) == 1
        assert not list(Path('.').glob('*.partial'))
        app.start_recording()
        phase = 3
    return GLib.SOURCE_CONTINUE
GLib.timeout_add(50, exercise_controls)
raise SystemExit(app.run())
"""
        self.verify_output(self.launch(code=code), expected_files=2)


if __name__ == "__main__":
    unittest.main()
