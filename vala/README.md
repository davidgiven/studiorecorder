# StudioRecorder — Vala port

This is a native Vala implementation of StudioRecorder's GTK 4 / GStreamer application. The Python implementation remains available for comparison. No Python code is loaded by the Vala executable.

## Build and run

Install `valac`, a C compiler, `make`, `pkg-config`, and development packages for GTK 4, GStreamer, GLib/GIO (including gio-unix), Xlib, and Linux V4L2 headers. On Fedora, the additional development packages typically include `vala gtk4-devel gstreamer1-devel libX11-devel`. Runtime plugins and hardware drivers are the same as those described in the root README. Target GTK 4.12+ and GStreamer 1.24+; the compiler used for validation was Vala 0.56.

From the repository root:

```sh
make vala
make run-vala
```

Launch the executable from another directory to save takes there:

```sh
/path/to/studio/build/studio-recorder-vala
```

To inspect the interface without opening cameras, desktop sharing, or hardware encoders:

```sh
make run-vala ARGS=--test-sources
```

The window starts paused, with live previews and audio meters. Play opens a new take; Stop finalizes it and restores preview. Audio dropdowns are available while paused. Closing the window, Ctrl-C, and SIGTERM finalize an active take before exiting. Screen capture and computer audio are mandatory in normal operation; on Wayland, choose your primary monitor in the system chooser.

## Structure

- `devices.vala`: input models, PipeWire discovery, physical USB association, source factories, and explicit synthetic sources.
- `desktop.vala`: primary-monitor geometry, asynchronous X11 query, asynchronous portal requests, descriptor ownership, and portal cleanup.
- `media.vala`: capture/preview/recording graphs, hardware encoder selection, tags, audio deduplication, encoded-frame statistics, and exclusive output publication.
- `app.vala`: GTK interface, typed transport state, paused audio changes, discovery worker, bus handling, timeouts, and graceful shutdown.
- `main.vala`: command-line validation and initialization.
- `native.c` / `native.vapi`: a small C boundary for V4L2's format-preparation signal/ioctl, XInitThreads, realpath, and the legacy GValueArray returned by the level element. No frame or sample processing occurs here or in Vala.

Vala properties, signals, async methods, delegates, automatic reference ownership, and GLib collections replace Python's dynamic application machinery. GStreamer plugin-specific properties remain accessed through GObject properties; encoder enum strings use GStreamer's property parser. No parallel ObjFW/JVM object runtime is involved.

The current pipeline-rebuild architecture is preserved: Play, Stop, and audio changes reopen capture. Record video stays in native elements; audio remains interleaved F32LE at 48 kHz with no channel-count restriction. Hardware H.264 is required in normal operation; only explicit synthetic mode uses x264enc. Post-parser identity statistics count encoded access units for the rolling ten-second FPS display.

## Checks

```sh
make test-vala
```

Requires `ffprobe`, `ffmpeg`, `dbus-run-session`, Python/PyGObject for the isolated mock portal, and the synthetic GStreamer plugins including `x264enc`. The Vala GLib tests exercise rolling-window interpolation/reset/stalls, monitor geometry, encoded FPS without preview, audio selection under busy main-loop work, duplicate transport actions, multiple takes, and mandatory computer audio with screen audio disabled. The black-box Python test driver executes the compiled binary, checks initial paused behavior and invalid arguments, verifies SIGINT/SIGTERM finalization, inspects all five tracks and their tags, and decodes every track. Five further scenarios run the compiled portal client against a mock service on a private D-Bus: serial-based targeting and descriptor lifetime, node-ID fallback, denial, multiple-stream rejection, and cancellation. The mock deliberately sends its Response before the method reply. Python is used only as a test driver.

Validated locally: all 13 Vala/black-box/portal scenarios and the original 32 Python tests passed; a synthetic GTK preview/record/finalize smoke test also passed.

Real cameras, portal behavior on actual Wayland desktops, hardware encoder allocation, and long-duration synchronization require separate hardware validation of this port. Existing Python hardware smoke-test results do not validate the Vala implementation. Native libraries and plugins are still required at runtime. Vala 0.56 generates C qualifier warnings against newer GLib/GTK headers; the audio-meter helper also accesses a deprecated type because that is what the level plugin publishes.
