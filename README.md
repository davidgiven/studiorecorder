# StudioRecorder

A native Vala/GStreamer application for multitrack recording on a Linux desktop.

Build and launch from the repository root:

```sh
make
make run
```

To save recordings elsewhere, launch the compiled executable from the destination directory:

```sh
/path/to/studio/build/studio-recorder
```

See [vala/README.md](vala/README.md) for the source guide and development details. `make test` runs the checks, and `make format` applies the repository's Uncrustify configuration. The application does not require Python; Python is used only by test drivers.

It discovers cameras through PipeWire, matches microphones using physical USB identity, and previews every discovered camera and its associated audio, plus primary-monitor capture and computer audio. It starts stopped and creates no output until Play is pressed. A screen-only session works even without a webcam. Physical V4L2 webcams are opened directly through `v4l2src` using their advertised device path; other camera types use their provider's capture element. Named audio inputs use `pulsesrc` through the PulseAudio-compatible service, with provider capture as a fallback when a node name is unavailable. It writes one timestamped `StudioRecorder_*.mkv` in the current directory, containing independent H.264 video tracks and deduplicated, uncompressed float32 PCM audio tracks. Track names/comments identify sources and audio associations.

## Preview and recording controls

The window shows a large selected preview, clickable thumbnail buttons (including Screen), and audio meters. Each button has a centered capture-resolution/target-FPS summary above its image and the source name below. Clicking it selects the large preview without changing the recording.

An audio dropdown below each source name offers discovered inputs, Computer audio, and No audio. It is enabled only while paused. Changing it rebuilds preview, updates the meter, and applies to subsequent takes; dropdowns become available again when preview is ready. Assignments last for the current run and shared audio inputs are recorded only once. Computer audio remains an independent required track even if the screen is assigned another input or No audio.

The main preview's top-left overlay shows target FPS and actual **recording** FPS. Recording FPS counts complete encoded video frames after the H.264 parser, averaged over the last ten seconds and refreshed every quarter-second. It is independent of preview FPS and shows a dash while paused. During warmup it averages over available sampling time. If encoded output stalls, the rate gradually falls to zero as earlier frames leave the window.

The bar between the main preview and thumbnails contains Play and Stop:

- Stopped: prominent red **PAUSED** text, live previews/meters, and no output file.
- Play: create a new timestamped MKV and show elapsed time as HH:MM:SS once the pipeline is running.
- Stop: drain, finalize, and close that take, then return to PAUSED. Play and audio selection stay disabled until finalization and preview preparation finish.

Capture pipelines reopen at each recording transition or audio change, so previews can briefly restart. Stop does not exit the application. Close the window, press Ctrl-C, or send SIGTERM to exit; an active take finalizes first. Exiting while stopped creates no recording file.

Output has a `.mkv.partial` suffix until finalization succeeds. Publishing the final filename uses a hard link followed by removal of the temporary name, so the output filesystem must support hard links. Existing recordings are never overwritten. Failed finalization preserves incomplete output and reports a nonzero exit status. SIGKILL cannot finalize a recording, and partial files are not guaranteed recoverable.

## Dependencies

For building, install Vala (`valac`), a C compiler, Make, pkg-config, and development headers for GTK 4, GStreamer, GLib/GIO (including gio-unix), Xlib, and Linux V4L2. Install matching runtime packages for:

- GTK 4.12+, GLib/GIO, GStreamer 1.24+, and libX11.
- GStreamer core/base/good/bad plugins, including PipeWire, `identity`, `decodebin`, `videoconvert`, `videoscale`, `audioconvert`, `audioresample`, `level`, `taginject`, `h264parse`, and `matroskamux`.
- The GTK 4 GStreamer sink, `gtk4paintablesink` (often packaged as `gst-plugin-gtk4`). GTK 3's `gtksink` is a different plugin.
- A hardware H.264 encoder and its working driver: VA-API (`vah264enc`/`vah264lpenc`), NVIDIA (`nvh264enc`/`nvautogpuh264enc`), Quick Sync (`qsvh264enc`), legacy VA-API, or V4L2.
- A running desktop PipeWire service with access to the cameras and audio inputs.
- For computer audio: `pulsesrc` and a PulseAudio-compatible server (normally `pipewire-pulse`). It captures the default output monitor, not the default microphone.
- For X11 screen capture: `ximagesrc`, libX11, and `xrandr`. Only the primary monitor is captured, including its pointer. With multiple monitors and no configured primary, startup fails instead of recording the entire desktop.
- For Wayland screen capture: `xdg-desktop-portal` with the desktop's ScreenCast backend. The system screen-sharing chooser appears during preview setup. Select your primary monitor; only one monitor can be selected. The portable portal API cannot automatically identify or select the primary monitor. Cancelling or denying consent aborts startup. There is no automatic fallback to recording an Xwayland window.
- The GStreamer V4L2 plugin and read/write access to `/dev/video*` for physical webcams.

Distribution package names vary. On Fedora, build dependencies typically include `vala gtk4-devel gstreamer1-devel libX11-devel`. Install media plugins and GPU drivers through system packages; compiling the application does not supply them.

Check individual elements with `gst-inspect-1.0 gtk4paintablesink` or `gst-inspect-1.0 vah264enc`. Finding an encoder plugin does not guarantee the driver can allocate every requested encoder session; starting a take reports negotiation/allocation failures. Preview-only mode does not allocate a hardware encoder. A live-preview startup failure therefore concerns capture, audio, or rendering; the lines below the error summary identify the failing GStreamer element. There is no automatic software fallback in normal operation.

## Development checks

A separate synthetic mode uses two test cameras, one shared test microphone, a screen source, computer audio, and the native software `x264enc` plugin. It never accesses capture devices. Headless operation and automatic stop duration are development options only. An explicit `--duration` synthetic run automatically starts one take after preview initialization and exits when its duration expires; normal launches always start stopped:

```sh
./build/studio-recorder --test-sources --headless --duration 3
make test
```

The suite contains 15 checks across Vala GLib tests, executable recording tests, and an isolated mock portal. They cover RMS-to-meter conversion, the V4L2 callback's unsupported-descriptor fallback, rolling FPS, primary-monitor selection, paused audio changes, busy-preview scheduling, multiple takes, track codecs/tags, decoding every track, command-line validation, signal finalization, and portal descriptor/consent handling.

Checks require `ffprobe`, `ffmpeg`, `dbus-run-session`, Python 3 with PyGObject (for the mock portal), and synthetic GStreamer plugins including `x264enc`. Override the test interpreter with `make PYTHON=/path/to/python3 test` if needed.

The current Vala implementation has passed the automated suite and a synthetic GTK preview/record/finalize smoke test. Real cameras, X11/Wayland capture, hardware encoders, and long-duration/multi-camera operation still need validation of this implementation. Earlier hardware results belonged to the retired Python version.

## Current scope

This is the initial preview and per-take recording implementation of [DESIGN.md](DESIGN.md). It requires PipeWire and uses H.264; H.265 selection, saved settings/overrides, recovery journals, and hotplug handling are not implemented. In addition to computer audio from the default output monitor, it records audio physically associated with each camera, rather than guessing a default microphone. A camera with no match or an ambiguous match starts with No audio; choose an input while paused. Other microphones are recorded only when selected.

Camera modes currently negotiate automatically. When a V4L2 camera exposes the standard exposure-driven dynamic-frame-rate control, the application disables it before format negotiation so automatic exposure respects the negotiated frame interval. Exposure can take a few frames to settle; darker scenes may look darker or noisier. Unsupported or unwritable controls produce a warning and capture continues; this is not a guarantee against USB, driver, or processing drops. Recording branches use native video scaling when a source (such as an ultrawide desktop) exceeds the hardware encoder's supported dimensions; thumbnail resolutions describe the capture/preview dimensions, which may be larger than the encoded video. Preview queues drop stale frames, while recording queues apply bounded backpressure. Multi-camera bandwidth, sustained overload handling, encoder choice across multiple GPUs, and long-duration synchronization need hardware validation. Device/pipeline errors stop the take, attempt bounded finalization, and return a nonzero exit code. A failed take that successfully finalizes can still produce an MKV; terminal diagnostics distinguish it from a successful take.

GStreamer's Matroska tag writer may expose escaped string values in some readers; check track metadata in the intended editor. Track naming/comment entry will arrive with source settings.
