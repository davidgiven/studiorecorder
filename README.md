# StudioRecorder

A Python/GStreamer application for multitrack recording on a Linux desktop.

Launch the application from the directory where recordings should be saved:

```sh
python3 -m studio_recorder
```

It discovers cameras through PipeWire, matches microphones using physical USB identity, and previews every discovered camera and its associated audio, plus primary-monitor capture and computer audio. It starts stopped and creates no output until Play is pressed. A screen-only session works even without a webcam. Physical V4L2 webcams are opened directly through `v4l2src` using their advertised device path; other camera types and audio inputs use their provider's capture element. It writes one timestamped `StudioRecorder_*.mkv` in the current directory, containing independent H.264 video tracks and deduplicated, uncompressed float32 PCM audio tracks. Track names/comments identify sources and audio associations.

The window shows a selected source, clickable thumbnails (including Screen), and audio meters. Below each source name, an audio dropdown lists discovered input devices, Computer audio, and No audio. It is enabled only while paused; changing it restarts the live preview and updates the meter and next take. Assignments last for the current application run. Shared inputs are still recorded only once. Computer audio remains a required independent track even when the screen is assigned another input or No audio. Each preview button shows its negotiated capture resolution and target FPS, above its thumbnail image. These summaries update every half-second. The large preview also shows the selected camera's target and actual FPS in a top-left overlay, using the same ten-second rolling average. During startup the average uses the elapsed sampling time until ten seconds are available. Unknown rates display as a dash; a stalled preview gradually falls to zero as its last frames leave the window. A bar between the main preview and thumbnails contains Play and Stop buttons. While stopped, prominent red PAUSED text is shown and live previews/meters remain active. Play creates a new timestamped MKV and shows elapsed time as HH:MM:SS. Stop drains, finalizes, and closes that take, then returns to PAUSED; Play is disabled until finalization and preview preparation finish. Capture pipelines are reopened at these transitions, so previews can briefly restart. Close the window, press Ctrl-C in the terminal, or send SIGTERM to exit, finalizing an active take first. The application keeps its event loop alive while EOS drains the pipeline and finalizes the MKV, then exits. Output is named `.mkv.partial` until finalization succeeds; interrupted or failed finalization preserves that file and reports a nonzero exit status. SIGKILL cannot finalize a recording.

## Dependencies

Use the distribution's Python 3.11+ and install matching system packages for:

- PyGObject (`gi`), GTK 4.12+, and GStreamer 1.24+ introspection bindings.
- GStreamer core/base/good/bad plugins, including PipeWire, `decodebin`, `videoconvert`, `videoscale`, `audioconvert`, `audioresample`, `level`, `taginject`, `h264parse`, and `matroskamux`.
- The GTK 4 GStreamer sink, `gtk4paintablesink` (often packaged as `gst-plugin-gtk4`). GTK 3's `gtksink` is a different plugin.
- A hardware H.264 encoder and its working driver: VA-API (`vah264enc`/`vah264lpenc`), NVIDIA (`nvh264enc`/`nvautogpuh264enc`), Quick Sync (`qsvh264enc`), legacy VA-API, or V4L2.
- A running desktop PipeWire service with access to the cameras and audio inputs.
- For computer audio: `pulsesrc` and a PulseAudio-compatible server (normally `pipewire-pulse`). It captures the default output monitor, not the default microphone.
- For X11 screen capture: `ximagesrc`, libX11, and `xrandr`. Only the primary monitor is captured, including its pointer. With multiple monitors and no configured primary, startup fails instead of recording the entire desktop.
- For Wayland screen capture: `xdg-desktop-portal` with the desktop's ScreenCast backend. The system screen-sharing chooser is shown before recording starts; select your primary monitor; only one monitor can be selected. The portable portal API cannot automatically identify or select the primary monitor. Cancelling or denying consent aborts startup. There is no automatic fallback to recording an Xwayland window.
- The GStreamer V4L2 plugin and read/write access to `/dev/video*` for physical webcams.

Distribution package names vary. Install PyGObject and media dependencies through system packages; `pip` alone does not supply GTK, GStreamer plugins, or hardware drivers. An optional `pip install -e . --no-deps` installs the `studio-recorder` command when the system dependencies are already available.

Check individual elements with `gst-inspect-1.0 gtk4paintablesink` or `gst-inspect-1.0 vah264enc`. Finding an encoder plugin does not guarantee the driver can allocate every requested encoder session; startup reports negotiation/allocation failures. There is no automatic software fallback in normal operation.

## Development checks

A separate synthetic mode uses two test cameras, one shared test microphone, a screen source, computer audio, and the native software `x264enc` plugin. It never accesses capture devices. Headless operation and automatic stop duration are development options only. An explicit `--duration` synthetic run automatically starts one take after preview initialization and exits when its duration expires; normal launches always start stopped:

```sh
python3 -m studio_recorder --test-sources --headless --duration 3
python3 -m unittest discover -s tests -v
```

The integration tests additionally require `ffprobe` and `ffmpeg`. They verify one MKV containing both camera tracks, the screen track, and two float32 audio tracks, embedded identification tags, successful decoding of all tracks, stopped startup without output files, separate files across repeated Play/Stop cycles, and finalization through Stop, Ctrl-C, and the window-close handler. A desktop smoke test is still needed for preview rendering and real hardware capture.

## Current scope

This is the initial preview and per-take recording implementation of [DESIGN.md](DESIGN.md). It requires PipeWire and uses H.264; H.265 selection, saved settings/overrides, recovery journals, and hotplug handling are not implemented. In addition to computer audio from the default output monitor, it records audio physically associated with each camera, rather than guessing a default microphone. A camera with no match or an ambiguous match starts with No audio; choose an input while paused. Other microphones are recorded only when selected.

Camera modes currently negotiate automatically. Recording branches use native video scaling when a source (such as an ultrawide desktop) exceeds the hardware encoder's supported dimensions; thumbnail resolutions describe the capture/preview dimensions, which may be larger than the encoded video. Preview queues drop stale frames, while recording queues apply bounded backpressure. Multi-camera bandwidth, sustained overload handling, encoder choice across multiple GPUs, and long-duration synchronization need hardware validation. Device/pipeline errors stop the take, attempt bounded finalization, and return a nonzero exit code. A failed take that successfully finalizes can still produce an MKV; terminal diagnostics distinguish it from a successful take.

GStreamer's Matroska tag writer may expose escaped string values in some readers; check track metadata in the intended editor. Track naming/comment entry will arrive with source settings.
