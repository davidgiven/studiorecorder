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

BINARY = Path(__file__).resolve().parents[1] / "studio-recorder"


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
            self.assertEqual(stream["sample_rate"], "44100")
        for stream in info["streams"]:
            self.assertTrue(stream["tags"].get("TITLE"))
            self.assertTrue(stream["tags"].get("COMMENTS"))
        self.assertTrue(any("Computer" in s["tags"]["TITLE"] for s in audios))
        self.assertTrue(any("Screen" in s["tags"]["TITLE"] for s in videos))
        # Streaming MKV intentionally omits a final duration; measure the actual packet span instead.
        packets = json.loads(subprocess.check_output([
            "ffprobe", "-v", "error", "-show_packets", "-show_entries",
            "packet=pts_time,duration_time", "-of", "json", str(files[0])]))["packets"]
        starts = [float(p["pts_time"]) for p in packets if "pts_time" in p]
        ends = [float(p["pts_time"]) + float(p.get("duration_time", 0))
                for p in packets if "pts_time" in p]
        self.assertGreater(max(ends) - min(starts), 0)
        self.assertLess(max(ends) - min(starts), 5)
        self.verify_streaming_header(files[0])
        decoded = subprocess.run([
            "ffmpeg", "-v", "error", "-xerror", "-i", str(files[0]), "-map", "0", "-f", "null", "-"],
            capture_output=True, timeout=20)
        self.assertEqual(decoded.returncode, 0, decoded.stderr.decode())

    def verify_streaming_header(self, path):
        """Read EBML structure to verify an open-ended Segment and absence of finalization-only headers."""
        data = path.read_bytes()

        # EBML IDs preserve their length marker; sizes remove it and reserve all-one bits for unknown size.
        def element(offset):
            id_length = 9 - data[offset].bit_length()
            identifier = int.from_bytes(data[offset:offset + id_length], "big")
            offset += id_length
            size_length = 9 - data[offset].bit_length()
            size = int.from_bytes(data[offset:offset + size_length], "big") & ((1 << (7 * size_length)) - 1)
            unknown = size == (1 << (7 * size_length)) - 1
            return identifier, None if unknown else size, offset + size_length

        identifier, size, body = element(0)
        self.assertEqual(identifier, 0x1A45DFA3)
        identifier, size, body = element(body + size)
        self.assertEqual(identifier, 0x18538067)
        self.assertIsNone(size)

        # Inspect segment headers up to the first media cluster, skipping payload bytes structurally.
        while body < len(data):
            identifier, size, payload = element(body)
            if identifier == 0x1F43B675:
                return
            self.assertNotIn(identifier, (0x114D9B74, 0x1C53BB6B))
            self.assertIsNotNone(size)
            if identifier == 0x1549A966:
                child = payload
                while child < payload + size:
                    child_id, child_size, child_body = element(child)
                    self.assertNotEqual(child_id, 0x4489)
                    self.assertIsNotNone(child_size)
                    child = child_body + child_size
            body = payload + size
        self.fail("Streaming file has no media cluster")

    def test_crash_preserves_streaming_take(self):
        process = self.launch("--duration", "60")
        self.wait_for(process, b"\nRecording:")
        time.sleep(1)
        process.kill()
        process.communicate(timeout=10)
        partials = list(self.directory.glob("*.mkv.partial"))
        self.assertEqual(len(partials), 1)
        self.verify_streaming_header(partials[0])

        # Stream-copy all tracks from the abruptly terminated take, then verify that every track decodes.
        recovered = self.directory / "recovered.mkv"
        subprocess.run(["ffmpeg", "-v", "error", "-i", str(partials[0]), "-map", "0",
                        "-c", "copy", str(recovered)], check=True, capture_output=True, timeout=20)
        info = json.loads(subprocess.check_output([
            "ffprobe", "-v", "error", "-show_streams", "-of", "json", str(recovered)]))
        self.assertEqual(len(info["streams"]), 5)
        subprocess.run(["ffmpeg", "-v", "error", "-xerror", "-i", str(recovered), "-map", "0",
                        "-f", "null", "-"], check=True, capture_output=True, timeout=20)

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
