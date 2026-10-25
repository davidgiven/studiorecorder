"""Minimal UI and bounded, asynchronous recording shutdown."""

import argparse
import math
from pathlib import Path
import signal
import sys
import threading

import gi

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst

from .devices import Registry, test_cameras
from .media import Recorder


class Application:
    def __init__(self, *, test_sources=False, headless=False, duration=None):
        self.test_sources = test_sources
        self.headless = headless
        self.duration = duration
        self.loop = GLib.MainLoop()
        self.registry = Registry()
        self.recorder = None
        self.stopping = False
        self.done = False
        self.discovery_complete = False
        self.exit_code = 0
        self.startup_timer = 0
        self.stop_timer = 0
        self.duration_timer = 0
        self.signal_sources = []
        self.meters = {}
        self.window = None
        if not headless:
            self.create_window()

    def create_window(self):
        gi.require_version("Gtk", "4.0")
        from gi.repository import Gtk

        if not Gtk.init_check():
            raise RuntimeError("Cannot open a GTK display. Run from the Linux desktop session.")
        self.Gtk = Gtk
        self.window = Gtk.Window(title="StudioRecorder")
        self.window.set_default_size(960, 640)
        self.window.connect("close-request", self.on_close)
        layout = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.picture = Gtk.Picture(hexpand=True, vexpand=True)
        self.picture.set_can_shrink(True)
        layout.append(self.picture)
        self.thumbnails = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER)
        scroll.set_child(self.thumbnails)
        layout.append(scroll)
        self.status_label = Gtk.Label(label="Discovering capture devices…", xalign=0)
        self.status_label.set_wrap(True)
        layout.append(self.status_label)
        self.window.set_child(layout)
        self.window.present()

    def status(self, text):
        print(text, flush=True)
        if self.window:
            self.status_label.set_text(text)

    def run(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            self.signal_sources.append(GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signum, self.on_signal))
        GLib.idle_add(self.begin)
        self.loop.run()
        for source_id in self.signal_sources:
            GLib.source_remove(source_id)
        return self.exit_code

    def begin(self):
        self.startup_timer = GLib.timeout_add_seconds(30, self.startup_timeout)
        if self.test_sources:
            self.devices_ready(test_cameras(), None)
        else:
            # Provider startup may wait on a desktop service; never block GTK or
            # prevent Ctrl-C/window-close while discovery is in progress.
            threading.Thread(target=self.discover, daemon=True).start()
        return GLib.SOURCE_REMOVE

    def discover(self):
        try:
            cameras = self.registry.discover()
            error = None
        except Exception as exc:
            cameras, error = [], str(exc)
        if self.stopping or self.done:
            self.registry.stop()
            return
        GLib.idle_add(self.devices_ready, cameras, error)

    def devices_ready(self, cameras, error):
        self.discovery_complete = True
        if self.stopping or self.done:
            self.registry.stop()
            return GLib.SOURCE_REMOVE
        if error:
            self.fail(error)
            return GLib.SOURCE_REMOVE
        try:
            self.recorder = Recorder(cameras, Path.cwd(), preview=not self.headless,
                                     test_sources=self.test_sources)
            self.recorder.build()
            bus = self.recorder.pipeline.get_bus()
            bus.add_signal_watch()
            bus.connect("message", self.on_message)
            if self.window:
                self.populate_previews()
            for camera in cameras:
                self.status(f"Source: {camera.source.name}; audio: {camera.audio.name if camera.audio else 'no associated input'}")
            self.status(f"Starting recording: {self.recorder.final_path}")
            self.recorder.start()
            if self.duration is not None:
                self.duration_timer = GLib.timeout_add(max(1, int(self.duration * 1000)), self.duration_elapsed)
        except Exception as exc:
            self.fail(str(exc))
        return GLib.SOURCE_REMOVE

    def populate_previews(self):
        Gtk = self.Gtk
        first = True
        for camera, paintable in self.recorder.previews:
            column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            picture = Gtk.Picture.new_for_paintable(paintable)
            picture.set_size_request(180, 110)
            picture.set_can_shrink(True)
            overlay = Gtk.Overlay()
            overlay.set_child(picture)
            if camera.audio:
                meter = Gtk.LevelBar(min_value=0, max_value=1)
                meter.set_valign(Gtk.Align.END)
                overlay.add_overlay(meter)
                self.meters.setdefault(camera.audio.identity, []).append(meter)
            column.append(overlay)
            column.append(Gtk.Label(label=camera.source.name))
            button = Gtk.Button()
            button.set_child(column)
            button.connect("clicked", lambda _button, p=paintable: self.picture.set_paintable(p))
            self.thumbnails.append(button)
            if first:
                self.picture.set_paintable(paintable)
                first = False

    def on_message(self, _bus, message):
        if self.done:
            return
        if message.type == Gst.MessageType.ERROR:
            error, debug = message.parse_error()
            print(f"GStreamer: {debug}", file=sys.stderr, flush=True)
            self.fail(f"{message.src.name}: {error.message}")
        elif message.type == Gst.MessageType.EOS:
            self.finish(finalized=True)
        elif message.type == Gst.MessageType.APPLICATION:
            structure = message.get_structure()
            if structure and structure.get_name() == "studio-recorder-error":
                self.fail(structure.get_value("message"))
        elif message.type == Gst.MessageType.STATE_CHANGED and message.src == self.recorder.pipeline:
            _old, new, _pending = message.parse_state_changed()
            if new == Gst.State.PLAYING and not self.stopping:
                self.remove_timer("startup_timer")
                self.status(f"Recording: {self.recorder.final_path}")
        elif message.type == Gst.MessageType.ELEMENT:
            structure = message.get_structure()
            if structure and structure.get_name() == "level":
                values = structure.get_value("rms")
                db = max(values) if values else -60
                value = max(0.0, min(1.0, (db + 60) / 60)) if math.isfinite(db) else 0
                identity = self.recorder.level_sources.get(message.src.name)
                for meter in self.meters.get(identity, []):
                    meter.set_value(value)

    def on_close(self, _window):
        self.request_stop()
        return True  # Keep the window/main loop alive until muxer finalization.

    def on_signal(self):
        self.request_stop()
        return GLib.SOURCE_CONTINUE

    def duration_elapsed(self):
        self.duration_timer = 0
        self.request_stop()
        return GLib.SOURCE_REMOVE

    def startup_timeout(self):
        self.startup_timer = 0
        self.fail("Capture startup timed out.")
        return GLib.SOURCE_REMOVE

    def fail(self, message):
        self.exit_code = 1
        self.status(f"Error: {message}")
        self.request_stop()

    def request_stop(self):
        if self.stopping or self.done:
            return
        self.stopping = True
        self.remove_timer("startup_timer")
        self.remove_timer("duration_timer")
        if self.recorder is None or not self.recorder.started:
            self.finish()
            return
        self.status("Finalizing recording…")
        self.stop_timer = GLib.timeout_add_seconds(10, self.stop_timeout)
        if not self.recorder.stop():
            self.exit_code = 1
            self.finish()

    def stop_timeout(self):
        self.stop_timer = 0
        self.exit_code = 1
        self.status("Finalization timed out; preserving incomplete output.")
        self.finish()
        return GLib.SOURCE_REMOVE

    def remove_timer(self, name):
        timer = getattr(self, name)
        if timer:
            GLib.source_remove(timer)
            setattr(self, name, 0)

    def finish(self, finalized=False):
        if self.done:
            return
        self.done = True
        self.stopping = True
        for name in ("startup_timer", "stop_timer", "duration_timer"):
            self.remove_timer(name)
        if self.recorder:
            try:
                self.recorder.close(finalized=finalized)
                if self.recorder.partial_path:
                    self.status(f"{'Saved' if finalized else 'Incomplete recording'}: {self.recorder.final_path if finalized else self.recorder.partial_path}")
            except Exception as exc:
                self.exit_code = 1
                self.status(f"Could not finalize output: {exc}")
        # Discovery owns its provider until it hands back a result. Avoid
        # stopping a provider concurrently with an outstanding start().
        if self.discovery_complete:
            self.registry.stop()
        if self.window:
            self.window.destroy()
        self.loop.quit()


def main(argv=None):
    parser = argparse.ArgumentParser(description="Record cameras and their audio into a timestamped MKV in the current directory. Close the window or press Ctrl-C to stop.")
    parser.add_argument("--test-sources", action="store_true", help="Use two synthetic cameras, one microphone, and a software encoder for development only")
    parser.add_argument("--headless", action="store_true", help="Omit the preview window (requires --test-sources)")
    parser.add_argument("--duration", type=float, help="Stop after this many seconds (requires --test-sources)")
    args = parser.parse_args(argv)
    if (args.headless or args.duration is not None) and not args.test_sources:
        parser.error("--headless and --duration are development options requiring --test-sources")
    if args.duration is not None and (not math.isfinite(args.duration) or args.duration <= 0):
        parser.error("--duration must be a finite positive number")
    Gst.init(None)
    try:
        return Application(test_sources=args.test_sources, headless=args.headless, duration=args.duration).run()
    except (RuntimeError, ValueError) as exc:
        print(f"StudioRecorder: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
