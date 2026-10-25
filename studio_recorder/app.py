"""Live preview, per-take transport controls, and bounded finalization."""

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
from .desktop import DesktopCapture, initialize_x11


class Application:
    def __init__(self, *, test_sources=False, headless=False, duration=None):
        self.test_sources = test_sources
        self.headless = headless
        self.duration = duration
        self.loop = GLib.MainLoop()
        self.registry = Registry()
        self.desktop = None
        self.recorder = None
        self.sources = []
        self.audio_sources = []
        self.required_audio = []
        self.audio_selectors = {}
        self.state = "preparing"
        self.exiting = False
        self.recording_started_at = None
        self.elapsed_timer = 0
        self.bus = None
        self.bus_handler = None
        self.stopping = False
        self.done = False
        self.discovery_complete = False
        self.exit_code = 0
        self.startup_timer = 0
        self.stop_timer = 0
        self.duration_timer = 0
        self.fps_timer = 0
        self.fps_rates = {}
        self.selected_source = None
        self.signal_sources = []
        self.meters = {}
        self.thumbnail_details = {}
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
        preview_overlay = Gtk.Overlay(hexpand=True, vexpand=True)
        preview_overlay.set_child(self.picture)
        self.fps_label = Gtk.Label()
        self.fps_label.set_halign(Gtk.Align.START)
        self.fps_label.set_valign(Gtk.Align.START)
        self.fps_label.set_margin_start(8)
        self.fps_label.set_margin_top(8)
        self.fps_label.set_can_target(False)
        preview_overlay.add_overlay(self.fps_label)
        layout.append(preview_overlay)
        self.show_framerate()
        transport = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        transport.set_margin_start(8)
        transport.set_margin_end(8)
        self.play_button = Gtk.Button(label="▶ Play")
        self.play_button.set_tooltip_text("Start a new recording")
        self.play_button.connect("clicked", self.start_recording)
        self.stop_button = Gtk.Button(label="■ Stop")
        self.stop_button.set_tooltip_text("Finalize and close the current recording")
        self.stop_button.connect("clicked", lambda _button: self.request_stop())
        transport.append(self.play_button)
        transport.append(self.stop_button)
        self.transport_label = Gtk.Label(hexpand=True)
        transport.append(self.transport_label)
        layout.append(transport)
        self.update_transport()
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
        if self.test_sources:
            return self.sources_ready(cameras)
        # A Wayland portal chooser may remain open as long as the user needs.
        # Resume the capture startup timeout after consent, not during it.
        self.remove_timer("startup_timer")
        self.status("Preparing primary monitor and computer audio capture… Select your primary monitor if prompted.")
        def desktop_ready(inputs):
            if not self.stopping and not self.done:
                self.startup_timer = GLib.timeout_add_seconds(30, self.startup_timeout)
                self.sources_ready(cameras + inputs)
        self.desktop = DesktopCapture(desktop_ready, self.fail)
        self.desktop.start()
        return GLib.SOURCE_REMOVE

    def sources_ready(self, cameras):
        self.sources = cameras
        audio = {source.identity: source for source in self.registry.audio_sources}
        for camera in cameras:
            if camera.audio:
                audio[camera.audio.identity] = camera.audio
        self.audio_sources = sorted(audio.values(), key=lambda source: (source.name, source.identity))
        # Computer audio remains an independent required input even if the
        # screen's thumbnail is assigned a different microphone.
        self.required_audio = [source for source in self.audio_sources if source.identity == "desktop-audio"]
        self.prepare_pipeline(record=False)
        return GLib.SOURCE_REMOVE

    def disconnect_bus(self):
        if self.bus:
            self.bus.disconnect(self.bus_handler)
            self.bus.remove_signal_watch()
            self.bus = None
            self.bus_handler = None

    def prepare_pipeline(self, *, record):
        try:
            self.remove_timer("fps_timer")
            self.remove_timer("startup_timer")
            self.disconnect_bus()
            if self.recorder:
                self.recorder.close()
                self.recorder = None
            self.state = "starting" if record else "preparing"
            self.update_transport()
            self.recorder = Recorder(self.sources, Path.cwd(), preview=not self.headless,
                                     test_sources=self.test_sources, record=record,
                                     additional_audio=self.required_audio)
            self.recorder.build()
            self.bus = self.recorder.pipeline.get_bus()
            self.bus.add_signal_watch()
            self.bus_handler = self.bus.connect("message", self.on_message)
            if self.window:
                self.populate_previews()
                self.fps_timer = GLib.timeout_add(500, self.update_framerates)
            self.startup_timer = GLib.timeout_add_seconds(30, self.startup_timeout)
            self.status(f"Starting recording: {self.recorder.final_path}" if record else "Preparing live previews…")
            self.recorder.start()
        except Exception as exc:
            self.fail(str(exc))

    def start_recording(self, _button=None):
        if self.state != "paused" or self.stopping or self.exiting or not self.sources:
            return GLib.SOURCE_REMOVE
        self.prepare_pipeline(record=True)
        return GLib.SOURCE_REMOVE

    def update_transport(self):
        if not self.window:
            return
        self.play_button.set_sensitive(self.state == "paused" and not self.exiting)
        for selector in self.audio_selectors.values():
            selector.set_sensitive(self.state == "paused" and not self.exiting)
        self.stop_button.set_sensitive(self.state in ("starting", "recording") and not self.exiting)
        if self.state == "recording":
            elapsed = max(0, int((Gst.util_get_timestamp() - self.recording_started_at) / Gst.SECOND))
            hours, remainder = divmod(elapsed, 3600)
            minutes, seconds = divmod(remainder, 60)
            self.transport_label.set_markup(f'<span size="xx-large" weight="bold">{hours:02}:{minutes:02}:{seconds:02}</span>')
        elif self.state == "finalizing":
            self.transport_label.set_text("Finalizing…")
        elif self.state == "starting":
            self.transport_label.set_text("Starting…")
        else:
            self.transport_label.set_markup('<span foreground="#ff2020" size="xx-large" weight="bold">PAUSED</span>')

    def update_elapsed(self):
        self.update_transport()
        return GLib.SOURCE_CONTINUE

    def populate_previews(self):
        Gtk = self.Gtk
        selected = self.selected_source
        child = self.thumbnails.get_first_child()
        while child:
            following = child.get_next_sibling()
            self.thumbnails.remove(child)
            child = following
        self.meters.clear()
        self.thumbnail_details.clear()
        self.audio_selectors.clear()
        self.fps_rates.clear()
        first = True
        for camera, paintable in self.recorder.previews:
            column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            picture = Gtk.Picture.new_for_paintable(paintable)
            picture.set_size_request(180, 110)
            picture.set_can_shrink(True)
            overlay = Gtk.Overlay()
            overlay.set_child(picture)
            details = Gtk.Label(label="— × — · — fps", xalign=0.5)
            details.set_justify(Gtk.Justification.CENTER)
            details.set_can_target(False)
            column.append(details)
            self.thumbnail_details[camera.source.identity] = details
            if camera.audio:
                meter = Gtk.LevelBar(min_value=0, max_value=1)
                meter.set_valign(Gtk.Align.END)
                overlay.add_overlay(meter)
                self.meters.setdefault(camera.audio.identity, []).append(meter)
            column.append(overlay)
            column.append(Gtk.Label(label=camera.source.name))
            button = Gtk.Button()
            button.set_child(column)
            button.connect("clicked", lambda _button, identity=camera.source.identity, p=paintable: self.select_preview(identity, p))
            # Keep the interactive selector outside the preview button so its
            # popup and keyboard controls do not also activate that button.
            item = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            item.append(button)
            choices = [None, *self.audio_sources]
            names = ["No audio", *(source.name for source in self.audio_sources)]
            selector = Gtk.DropDown.new_from_strings(names)
            selector.set_tooltip_text("Audio input for this source (editable while paused)")
            selected_audio = camera.audio.identity if camera.audio else None
            selector.set_selected(next(index for index, source in enumerate(choices)
                                       if (source.identity if source else None) == selected_audio))
            selector.set_sensitive(self.state == "paused" and not self.exiting)
            selector.connect("notify::selected", self.audio_selection_changed,
                             camera.source.identity, choices)
            self.audio_selectors[camera.source.identity] = selector
            item.append(selector)
            self.thumbnails.append(item)
            if first or camera.source.identity == selected:
                self.select_preview(camera.source.identity, paintable)
                first = False

    def audio_selection_changed(self, selector, _property, video_identity, choices):
        selected = selector.get_selected()
        if selected < len(choices):
            audio = choices[selected]
            self.select_audio(video_identity, audio.identity if audio else None)

    def select_audio(self, video_identity, audio_identity):
        if self.state != "paused" or self.exiting or self.stopping or self.done:
            return False
        camera = next((source for source in self.sources if source.source.identity == video_identity), None)
        audio = next((source for source in self.audio_sources if source.identity == audio_identity), None)
        if camera is None or (audio_identity is not None and audio is None):
            return False
        if (camera.audio.identity if camera.audio else None) == audio_identity:
            return False
        camera.audio = audio
        self.state = "preparing"
        self.update_transport()
        # Leave the dropdown notification/popup stack before rebuilding widgets,
        # but use normal priority: continuous preview redraws can starve a
        # default-priority idle and leave the controls disabled indefinitely.
        GLib.idle_add(self.restart_audio_preview, priority=GLib.PRIORITY_DEFAULT)
        return True

    def restart_audio_preview(self):
        if not self.exiting and not self.done:
            self.prepare_pipeline(record=False)
        return GLib.SOURCE_REMOVE

    def select_preview(self, identity, paintable):
        self.selected_source = identity
        self.picture.set_paintable(paintable)
        self.show_framerate()

    def update_framerates(self):
        self.fps_rates = self.recorder.recording_framerates()
        resolutions = self.recorder.preview_resolutions()
        for identity, label in self.thumbnail_details.items():
            resolution = resolutions.get(identity)
            size_text = f"{resolution[0]} × {resolution[1]}" if resolution else "— × —"
            target, actual = self.fps_rates.get(identity, (None, None))
            target_text = f"{target:.1f}" if target is not None else "—"
            label.set_text(f"{size_text} · {target_text} fps")
        self.show_framerate()
        return GLib.SOURCE_CONTINUE

    def show_framerate(self):
        target, actual = self.fps_rates.get(self.selected_source, (None, None))
        target_text = f"{target:.1f}" if target is not None else "—"
        actual_text = f"{actual:.1f}" if actual is not None else "—"
        self.fps_label.set_markup(f'<span background="#202020" foreground="white">  Target: {target_text} fps   Recording: {actual_text} fps  </span>')

    def on_message(self, _bus, message):
        if self.done:
            return
        if message.type == Gst.MessageType.ERROR:
            error, debug = message.parse_error()
            print(f"GStreamer: {debug}", file=sys.stderr, flush=True)
            self.fail(f"{message.src.name}: {error.message}")
        elif message.type == Gst.MessageType.EOS:
            if self.recorder.record:
                self.complete_take(finalized=True)
            else:
                self.fail("Live capture ended unexpectedly.")
        elif message.type == Gst.MessageType.APPLICATION:
            structure = message.get_structure()
            if structure and structure.get_name() == "studio-recorder-error":
                self.fail(structure.get_value("message"))
        elif message.type == Gst.MessageType.STATE_CHANGED and message.src == self.recorder.pipeline:
            _old, new, _pending = message.parse_state_changed()
            if new == Gst.State.PLAYING and not self.stopping:
                self.remove_timer("startup_timer")
                if self.recorder.record:
                    self.state = "recording"
                    self.recording_started_at = Gst.util_get_timestamp()
                    self.elapsed_timer = GLib.timeout_add(250, self.update_elapsed)
                    self.status(f"Recording: {self.recorder.final_path}")
                    if self.duration is not None:
                        self.duration_timer = GLib.timeout_add(max(1, int(self.duration * 1000)), self.duration_elapsed)
                else:
                    self.state = "paused"
                    self.status("Paused — ready to record.")
                    # Explicit timed synthetic runs remain convenient for tests.
                    if self.duration is not None:
                        GLib.idle_add(self.start_recording)
                self.update_transport()
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
        self.request_exit()
        return True  # Keep the window/main loop alive until muxer finalization.

    def on_signal(self):
        self.request_exit()
        return GLib.SOURCE_CONTINUE

    def duration_elapsed(self):
        self.duration_timer = 0
        self.request_exit()
        return GLib.SOURCE_REMOVE

    def startup_timeout(self):
        self.startup_timer = 0
        self.fail("Capture startup timed out.")
        return GLib.SOURCE_REMOVE

    def fail(self, message):
        self.exit_code = 1
        self.status(f"Error: {message}")
        self.request_exit()

    def request_exit(self):
        self.exiting = True
        if self.recorder and self.recorder.record:
            self.request_stop()
        else:
            self.finish()

    def request_stop(self):
        if self.stopping or self.done:
            return
        if self.recorder is None or not self.recorder.record:
            if self.exiting:
                self.finish()
            return
        self.stopping = True
        self.state = "finalizing"
        self.update_transport()
        self.remove_timer("startup_timer")
        self.remove_timer("duration_timer")
        self.remove_timer("elapsed_timer")
        if not self.recorder.started:
            self.complete_take()
            return
        self.status("Finalizing recording…")
        self.stop_timer = GLib.timeout_add_seconds(10, self.stop_timeout)
        if not self.recorder.stop():
            self.exit_code = 1
            self.exiting = True
            self.complete_take()

    def complete_take(self, finalized=False):
        self.remove_timer("stop_timer")
        self.remove_timer("elapsed_timer")
        self.remove_timer("duration_timer")
        self.disconnect_bus()
        try:
            self.recorder.close(finalized=finalized)
            path = self.recorder.final_path if finalized else self.recorder.partial_path
            self.status(f"{'Saved' if finalized else 'Incomplete recording'}: {path}")
        except Exception as exc:
            self.exit_code = 1
            self.exiting = True
            self.status(f"Could not finalize output: {exc}")
        self.recorder = None
        self.recording_started_at = None
        self.stopping = False
        if self.exiting:
            self.finish()
        else:
            self.prepare_pipeline(record=False)

    def stop_timeout(self):
        self.stop_timer = 0
        self.exit_code = 1
        self.exiting = True
        self.status("Finalization timed out; preserving incomplete output.")
        self.complete_take()
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
        for name in ("startup_timer", "stop_timer", "duration_timer", "fps_timer", "elapsed_timer"):
            self.remove_timer(name)
        self.disconnect_bus()
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
        if self.desktop:
            self.desktop.close()
        if self.window:
            self.window.destroy()
        self.loop.quit()


def main(argv=None):
    parser = argparse.ArgumentParser(description="Preview cameras and screen. Play starts a new timestamped MKV; Stop finalizes the take. Close the window or press Ctrl-C to exit.")
    parser.add_argument("--test-sources", action="store_true", help="Use synthetic cameras, screen, microphone, computer audio, and a software encoder for development only")
    parser.add_argument("--headless", action="store_true", help="Omit the preview window (requires --test-sources)")
    parser.add_argument("--duration", type=float, help="Stop after this many seconds (requires --test-sources)")
    args = parser.parse_args(argv)
    if (args.headless or args.duration is not None) and not args.test_sources:
        parser.error("--headless and --duration are development options requiring --test-sources")
    if args.duration is not None and (not math.isfinite(args.duration) or args.duration <= 0):
        parser.error("--duration must be a finite positive number")
    try:
        initialize_x11()
        Gst.init(None)
        return Application(test_sources=args.test_sources, headless=args.headless, duration=args.duration).run()
    except (RuntimeError, ValueError) as exc:
        print(f"StudioRecorder: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
