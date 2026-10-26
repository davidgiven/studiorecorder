"""Black-box validation of the compiled Vala executable; no Python application imports."""
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import time
import unittest

BINARY = Path(__file__).resolve().parents[1] / "build/studio-recorder"


class ValaRecordingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="studio-vala-check-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def launch(self, *args):
        process = subprocess.Popen(
            [str(BINARY), "--test-sources", "--headless", *args], cwd=self.directory,
            env=dict(os.environ, G_DEBUG="fatal-criticals"), stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        self.addCleanup(self.cleanup, process)
        return process

    @staticmethod
    def cleanup(process):
        if process.poll() is None:
            process.kill()
        process.wait()
        process.stdout.close()

    def wait_for(self, process, marker):
        output = b""
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if selector.select(0.2):
                    chunk = os.read(process.stdout.fileno(), 8192)
                    output += chunk
                    if marker in output:
                        return output
                    if not chunk:
                        break
        self.fail(f"Missing {marker!r}: {output.decode()}")

    def verify(self, process, prior=b""):
        output = process.communicate(timeout=20)[0]
        self.assertEqual(process.returncode, 0, (prior + output).decode())
        files = list(self.directory.glob("*.mkv"))
        self.assertEqual(len(files), 1)
        self.assertFalse(list(self.directory.glob("*.partial")))
        info = json.loads(subprocess.check_output([
            "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(files[0])]))
        videos = [s for s in info["streams"] if s["codec_type"] == "video"]
        audios = [s for s in info["streams"] if s["codec_type"] == "audio"]
        self.assertEqual([s["codec_name"] for s in videos], ["h264"] * 3)
        self.assertEqual([s["codec_name"] for s in audios], ["pcm_f32le"] * 2)
        for stream in audios:
            self.assertEqual(stream["sample_rate"], "48000")
        for stream in info["streams"]:
            self.assertTrue(stream["tags"].get("TITLE"))
            self.assertTrue(stream["tags"].get("COMMENTS"))
        self.assertTrue(any("Computer" in s["tags"]["TITLE"] for s in audios))
        self.assertTrue(any("Screen" in s["tags"]["TITLE"] for s in videos))
        self.assertGreater(float(info["format"]["duration"]), 0)
        self.assertLess(float(info["format"]["duration"]), 5)
        decoded = subprocess.run([
            "ffmpeg", "-v", "error", "-xerror", "-i", str(files[0]), "-map", "0", "-f", "null", "-"],
            capture_output=True, timeout=20)
        self.assertEqual(decoded.returncode, 0, decoded.stderr.decode())

    def test_timed_take(self):
        self.verify(self.launch("--duration", "1"))

    def test_signals_finalize(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):
                process = self.launch("--duration", "60")
                output = self.wait_for(process, b"\nRecording:")
                time.sleep(0.3)
                process.send_signal(signum)
                self.verify(process, output)
                for path in self.directory.glob("*.mkv"):
                    path.unlink()

    def test_starts_paused_without_output(self):
        process = self.launch()
        output = self.wait_for(process, b"Paused")
        self.assertFalse(list(self.directory.glob("*.mkv*")))
        process.send_signal(signal.SIGTERM)
        rest = process.communicate(timeout=15)[0]
        self.assertEqual(process.returncode, 0, (output + rest).decode())
        self.assertFalse(list(self.directory.glob("*.mkv*")))

    def test_invalid_arguments(self):
        for arguments in (("--duration", "0"), ("--duration", "nan"), ("--duration", "-1")):
            with self.subTest(arguments=arguments):
                process = self.launch(*arguments)
                output = process.communicate(timeout=10)[0]
                self.assertEqual(process.returncode, 1, output.decode())
                self.assertFalse(list(self.directory.glob("*.mkv*")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
