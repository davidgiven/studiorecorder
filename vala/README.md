# StudioRecorder — source and development guide

StudioRecorder is implemented in native Vala. The application has no Python runtime dependency; the Python scripts in this directory drive executable and mock-portal tests.

## Build and run

Install `valac`, a C compiler, `make`, `pkg-config`, and development packages for GTK 4, GStreamer, GLib/GIO (including gio-unix), Xlib, and Linux V4L2 headers. On Fedora, the additional development packages typically include `vala gtk4-devel gstreamer1-devel libX11-devel`. Runtime plugins and hardware drivers are the same as those described in the root README. Target GTK 4.12+ and GStreamer 1.24+; the compiler used for validation was Vala 0.56.

From the repository root:

```sh
make
make run
```

Launch the executable from another directory to save takes there:

```sh
/path/to/studio/build/studio-recorder
```

To inspect the interface without opening cameras, desktop sharing, or hardware encoders:

```sh
make run ARGS=--test-sources
```

The window starts paused, with live previews and audio meters. Play opens a new take; Stop finalizes it and restores preview. Audio dropdowns are available while paused. Closing the window, Ctrl-C, and SIGTERM finalize an active take before exiting. Screen capture and computer audio are mandatory in normal operation; on Wayland, choose your primary monitor in the system chooser.

## Structure

- `Application.vala`: GTK interface, transport state, audio changes, discovery worker, and shutdown. The small `Thumbnail` widget holder, `TransportState` enum, and Vala RMS-to-meter helper stay alongside their owner.
- `Input.vala`: capture-input metadata and source construction.
- `Camera.vala`: video input and its selected audio association.
- `Registry.vala`: PipeWire discovery and physical USB association.
- `DesktopCapture.vala`: asynchronous X11/Wayland screen capture and portal lifetime. Its small `Geometry` helper and desktop-input functions stay in the same file.
- `Recorder.vala`: capture/preview/recording graphs, encoder selection, track tags, audio deduplication, and exclusive output publication.
- `VideoTrack.vala`: per-track preview, negotiated video format, and encoded-frame statistics.
- `RollingFramerate.vala`: ten-second FPS history, with its private `FrameSample` helper.
- `camera-controls.vala` / `v4l2.vapi`: Vala format-preparation callback and frame-rate locking through typed Linux ioctl declarations; camera exposure mode is preserved.
- `capture-utils.vala`: shared element creation and capture error domain.
- `test-sources.vala`: explicit synthetic development inputs.
- `main.vala`: command-line validation and initialization.
- `native.vapi`: a direct Xlib binding for XInitThreads. Filesystem link resolution uses the existing `Posix.realpath` binding. No handwritten C helpers remain; media processing stays in native GStreamer elements.

The application uses Vala properties, signals, async methods, delegates, automatic reference ownership, and GLib collections. GStreamer plugin-specific properties are accessed through GObject properties; encoder enum strings use GStreamer's property parser.

The current pipeline-rebuild architecture is preserved: Play, Stop, and audio changes reopen capture. Record video stays in native elements; audio remains interleaved F32LE at 48 kHz with no channel-count restriction. Hardware H.264 is required in normal operation; only explicit synthetic mode uses x264enc. Post-parser identity statistics count encoded access units for the rolling ten-second FPS display.

## Checks

```sh
make test
```

Requires `ffprobe`, `ffmpeg`, `dbus-run-session`, Python/PyGObject for the isolated mock portal, and the synthetic GStreamer plugins including `x264enc`. The Vala GLib tests exercise the actual v4l2src format signal with an invalid descriptor, channel RMS-to-meter conversion (including missing and non-finite readings), rolling-window interpolation/reset/stalls, monitor geometry, encoded FPS without preview, audio selection under busy main-loop work, duplicate transport actions, multiple takes, and mandatory computer audio with screen audio disabled. The black-box Python test driver executes the compiled binary, checks initial paused behavior and invalid arguments, verifies SIGINT/SIGTERM finalization, inspects all five tracks and their tags, and decodes every track. Five further scenarios run the compiled portal client against a mock service on a private D-Bus: serial-based targeting and descriptor lifetime, node-ID fallback, denial, multiple-stream rejection, and cancellation. The mock deliberately sends its Response before the method reply. Python is used only as a test driver.

Validated locally: all 15 Vala/black-box/portal scenarios passed; a synthetic GTK preview/record/finalize smoke test also passed.

Real cameras, portal behavior on actual Wayland desktops, hardware encoder allocation, and long-duration synchronization require separate hardware validation. Historical hardware smoke-test results from the retired implementation do not validate the current application. Native libraries and plugins are still required at runtime. Vala 0.56 generates C qualifier warnings against newer GLib/GTK headers; the audio-meter helper also accesses a deprecated type because that is what the level plugin publishes.

The previous `make vala`, `make run-vala`, and `make test-vala` targets remain aliases for `make`, `make run`, and `make test`.
