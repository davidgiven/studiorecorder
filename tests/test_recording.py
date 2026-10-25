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

    def launch(self, *args, code=None):
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

    def wait_for_recording(self, process):
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
                    if b"\nRecording:" in output:
                        return output.decode()
                    if not chunk:
                        break
        self.fail(f"Recording never started: {output.decode()}")

    def verify_output(self, process, prior_output=""):
        output, _ = process.communicate(timeout=20)
        self.assertEqual(process.returncode, 0, prior_output + output)
        files = list(self.directory.glob("*.mkv"))
        self.assertEqual(len(files), 1, prior_output + output)
        self.assertFalse(list(self.directory.glob("*.partial")))
        data = json.loads(subprocess.check_output([
            "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(files[0])]))
        video = [s for s in data["streams"] if s["codec_type"] == "video"]
        audio = [s for s in data["streams"] if s["codec_type"] == "audio"]
        self.assertEqual(len(video), 2)
        self.assertEqual(len(audio), 1, "Shared microphone must not be duplicated")
        self.assertEqual([s["codec_name"] for s in video], ["h264", "h264"])
        self.assertEqual(audio[0]["codec_name"], "pcm_f32le")
        self.assertEqual(audio[0]["sample_rate"], "48000")
        self.assertGreater(float(data["format"]["duration"]), 0)
        for stream in data["streams"]:
            self.assertTrue(stream["tags"].get("TITLE"))
            self.assertTrue(stream["tags"].get("COMMENTS"))
        # Decode all tracks, not just the default video/audio selection.
        decoded = subprocess.run(["ffmpeg", "-v", "error", "-xerror", "-i", str(files[0]),
                                  "-map", "0", "-f", "null", "-"], capture_output=True, text=True, timeout=15)
        self.assertEqual(decoded.returncode, 0, decoded.stderr)

    def test_timed_recording(self):
        self.verify_output(self.launch("--duration", "1"))

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
    if app.recorder and app.recorder.started:
        state = app.recorder.pipeline.get_state(0)[1]
        if state == Gst.State.PLAYING:
            app.on_close(None)
            return GLib.SOURCE_REMOVE
    return GLib.SOURCE_CONTINUE
GLib.timeout_add(500, close_when_playing)
raise SystemExit(app.run())
"""
        self.verify_output(self.launch(code=code))


if __name__ == "__main__":
    unittest.main()
