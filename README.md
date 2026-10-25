# StudioRecorder

A Python/GStreamer skeleton for automatic multitrack recording on a Linux desktop.

Launch the application from the directory where recordings should be saved:

```sh
python3 -m studio_recorder
```

It discovers cameras through PipeWire, matches microphones using physical USB identity, and immediately starts recording every discovered camera and its associated audio. Physical V4L2 webcams are opened directly through `v4l2src` using their advertised device path; other camera types and audio inputs use their provider's capture element. It writes one timestamped `StudioRecorder_*.mkv` in the current directory, containing independent H.264 video tracks and deduplicated, uncompressed float32 PCM audio tracks. Track names/comments identify sources and audio associations.

The window shows a selected camera, clickable thumbnails, and audio meters. There are no recording controls or settings. Close the window, press Ctrl-C in the terminal, or send SIGTERM to stop. The application keeps its event loop alive while EOS drains the pipeline and finalizes the MKV, then exits. Output is named `.mkv.partial` until finalization succeeds; interrupted or failed finalization preserves that file and reports a nonzero exit status. SIGKILL cannot finalize a recording.

## Dependencies

Use the distribution's Python 3.11+ and install matching system packages for:

- PyGObject (`gi`), GTK 4.12+, and GStreamer 1.24+ introspection bindings.
- GStreamer core/base/good/bad plugins, including PipeWire, `decodebin`, `videoconvert`, `audioconvert`, `audioresample`, `level`, `taginject`, `h264parse`, and `matroskamux`.
- The GTK 4 GStreamer sink, `gtk4paintablesink` (often packaged as `gst-plugin-gtk4`). GTK 3's `gtksink` is a different plugin.
- A hardware H.264 encoder and its working driver: VA-API (`vah264enc`/`vah264lpenc`), NVIDIA (`nvh264enc`/`nvautogpuh264enc`), Quick Sync (`qsvh264enc`), legacy VA-API, or V4L2.
- A running desktop PipeWire service with access to the cameras and audio inputs.
- The GStreamer V4L2 plugin and read/write access to `/dev/video*` for physical webcams.

Distribution package names vary. Install PyGObject and media dependencies through system packages; `pip` alone does not supply GTK, GStreamer plugins, or hardware drivers. An optional `pip install -e . --no-deps` installs the `studio-recorder` command when the system dependencies are already available.

Check individual elements with `gst-inspect-1.0 gtk4paintablesink` or `gst-inspect-1.0 vah264enc`. Finding an encoder plugin does not guarantee the driver can allocate every requested encoder session; startup reports negotiation/allocation failures. There is no automatic software fallback in normal operation.

## Development checks

A separate synthetic mode uses two test cameras, one shared test microphone, and the native software `x264enc` plugin. It never accesses capture devices. Headless operation and automatic stop duration are development options only:

```sh
python3 -m studio_recorder --test-sources --headless --duration 3
python3 -m unittest discover -s tests -v
```

The integration tests additionally require `ffprobe` and `ffmpeg`. They verify one MKV containing both video tracks and one float32 audio track, embedded identification tags, successful decoding of all tracks, and finalization through automatic stop, Ctrl-C, and the window-close handler. A desktop smoke test is still needed for preview rendering and real hardware capture.

## Current scope

This is the initial startup-to-shutdown implementation of [DESIGN.md](DESIGN.md). It requires PipeWire and uses H.264; H.265 selection, settings, overrides, recovery journals, and hotplug handling are not implemented. It records only audio physically associated with a camera, rather than guessing a default microphone. A camera with no match records video only; an ambiguous match aborts startup. Unrelated microphones are not recorded.

Camera modes currently negotiate automatically. Preview queues drop stale frames, while recording queues apply bounded backpressure. Multi-camera bandwidth, sustained overload handling, encoder choice across multiple GPUs, and long-duration synchronization need hardware validation. Device/pipeline errors stop the take, attempt bounded finalization, and return a nonzero exit code. A failed take that successfully finalizes can still produce an MKV; terminal diagnostics distinguish it from a successful take.

GStreamer's Matroska tag writer may expose escaped string values in some readers; check track metadata in the intended editor. Track naming/comment entry will arrive with source settings.
