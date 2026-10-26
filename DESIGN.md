# StudioRecorder design

This document describes the current implementation and identifies remaining work separately. [AGENTS.md](AGENTS.md) gives the project requirements; [README.md](README.md) covers running the application and dependencies.

## Current behavior

StudioRecorder is a local Linux multitrack recorder implemented in Python with PyGObject, GTK 4, GLib, and GStreamer. Capture, decoding, conversion, scaling, hardware encoding, metering, and muxing run in native GStreamer elements. Python coordinates devices, pipeline lifecycle, and UI updates; it does not process individual video frames or audio samples.

The application starts stopped, with live camera and screen previews and audio meters. No recording file is created until Play is pressed. A control bar between the main preview and thumbnails contains Play/Stop and prominent red PAUSED text, replaced by HH:MM:SS elapsed time during recording. Each Play creates a separate timestamped MKV in the working directory. Stop drains and closes that take before returning to live preview. Controls prevent overlapping take transitions.

The large preview displays the selected source. Clicking a thumbnail changes only the displayed source, including during recording. Each preview button has a centered resolution/target-FPS summary above the image and its source name below the image. An audio dropdown beneath the button selects a discovered input, Computer audio, or No audio. Dropdowns are enabled only while paused. Assignments survive pipeline rebuilds and subsequent takes within the current run, but are not saved across application launches.

Audio meters overlay thumbnail images. The main preview's top-left overlay shows the selected source's negotiated target FPS and actual post-encoding recording FPS. Actual FPS is a ten-second rolling average of complete encoded video frames, refreshed every half-second. It uses available sampling time during warmup, resets for each take, and shows a dash while paused. The measurement comes from the recording branch and is independent of preview frame delivery. It measures encoder output throughput, not physical sensor synchronization or durable disk writes.

## Components and ownership

| Module | Current responsibility |
| --- | --- |
| `app.py` | GTK UI, transport state, audio assignment, timers, bus events, pipeline rebuilds, and shutdown. |
| `devices.py` | PipeWire discovery, physical camera/audio association, source construction, and synthetic development sources. |
| `desktop.py` | Primary-monitor capture on X11, single-monitor portal capture on Wayland, computer audio, and portal resource lifetime. |
| `media.py` | Capture/recording graph, hardware encoder selection, MKV output, track tags, counters, and rolling FPS calculation. |
| `v4l2.py` | Best-effort camera frame-rate locking through the source's open V4L2 descriptor. |

GTK updates and transport transitions run on the main loop. Device discovery runs in a worker so waiting on desktop services does not freeze the window. GStreamer bus messages are dispatched on the main loop. An audio change defers preview reconstruction until after the dropdown notification returns, using normal GLib priority: ordinary idle priority can be starved by continuous preview redraws.

There is one pipeline per preview mode or take. Play closes the preview pipeline and opens a recording pipeline. Stop finalizes the recording pipeline, closes it, and opens a fresh preview pipeline. Changing an audio assignment also rebuilds preview. Devices are opened once per pipeline, with tees for video preview and recording; selecting a thumbnail does not reopen devices. Preview images can briefly restart during mode or audio-assignment changes.

## Discovery and audio assignment

Discovery uses the GStreamer PipeWire device provider directly. Physical V4L2 webcams are captured through `v4l2src` using their advertised device paths. This avoids the observed case where PipeWire advertises a webcam but its capture stream fails with “target not found.” Other video sources use provider-created capture elements. Named PipeWire audio inputs open through `pulsesrc` using their node names on the PulseAudio-compatible service; provider capture remains the fallback when no node name is available. Physical webcam routing recognizes alternate V4L2 path metadata even when `device.api` is absent.

Physical audio association uses shared USB ancestry in sysfs, with PipeWire's kernel USB bus metadata as a fallback. Names alone do not establish a match. Missing or ambiguous matches default to No audio and can be resolved using the paused audio selector. The selector also offers discovered microphones that were not automatically associated with a camera. Multiple cameras can share one audio input; capture and recording deduplicate it by identity.

Current identities use provider object paths, node names, or display names as a final fallback. They support the current process but are not a complete persistent device-identity scheme. There is no hotplug reconciliation, physical-camera grouping across arbitrary duplicate capture nodes, saved override store, or per-source enable/Retry UI yet. Capture failures stop the application rather than silently omitting a required source.

## Screen and computer audio

Screen capture and computer audio are required inputs, including when no webcam is connected.

On X11, `xrandr --query` identifies the active primary monitor. `ximagesrc` captures its pixel rectangle, including the pointer, rather than the entire multi-monitor desktop. If only one monitor is active, it is used even without a primary flag. Multiple active monitors without a configured primary cause startup to fail. X11 threading is initialized before GTK and capture start.

On Wayland, the ScreenCast portal creates a session, requests single-monitor selection, waits for user consent, and provides a PipeWire remote descriptor and stream target. The portable portal API cannot automatically identify/select the primary monitor, so the user must select it in the chooser. Multiple returned streams are rejected. The portal descriptor and session remain alive until application shutdown; cancellation, denial, or session closure fails capture. The media startup timeout does not run while the user is choosing a monitor.

Computer audio uses `pulsesrc device=@DEFAULT_MONITOR@` through PulseAudio or `pipewire-pulse`, capturing the default output monitor rather than the default microphone. It remains a separate required input even if the screen's dropdown is assigned a different microphone or No audio. That assignment determines the screen's associated meter/track metadata; it does not disable the independent computer-audio track.

## Capture and recording graphs

Camera modes negotiate automatically. MJPEG or other compressed camera output passes through `decodebin` before the raw video tee. PipeWire video sources have a `video/x-raw` caps filter before `decodebin`: their unrestricted caps otherwise allow audio negotiation and can cause a portal stream to fail with “target not found,” followed by blocked cleanup. The current production codec is hardware H.264. Encoder factories are considered in this order: `vah264enc`, `vah264lpenc`, `nvh264enc`, `nvautogpuh264enc`, `qsvh264enc`, `vaapih264enc`, and `v4l2h264enc`. Factory availability selects a candidate; actual driver allocation and caps negotiation occur at pipeline startup. There is no automatic software fallback or retry with a different hardware backend after a startup failure.

```text
video input -> decodebin -> raw video tee
                             |-> leaky queue -> videoconvert -> gtk4paintablesink
                             `-> queue -> videoconvert -> videoscale -> NV12
                                 -> hardware H.264 encoder -> h264parse
                                 -> AVC / AU alignment -> track tags
                                 -> native frame counter -> queue -> shared matroskamux

audio input -> audioconvert -> audioresample -> F32LE / interleaved / 48 kHz
            -> level -> track tags -> queue -> shared matroskamux

shared matroskamux -> filesink -> one MKV per take
```

In preview-only mode, video has no encoder/writer branch and audio terminates at `fakesink` after metering. Headless synthetic preview uses video `fakesink` elements. No file or hardware encoder is needed for preview-only mode.

Preview queues are leaky and bounded to 200 ms. Recording queues are non-leaky and bounded to two seconds. Both disable the default byte and buffer-count queue limits. Recording saturation currently applies backpressure; explicit sustained-overload detection is future work.

Native scaling allows input dimensions beyond the encoder's limits to negotiate a supported recording size. Thumbnail resolution describes capture/preview dimensions, which can differ from encoded dimensions. Efficient GPU-memory paths and optimal capture-mode selection remain future performance work.

`level` posts channel RMS/peak measurements every 50 ms. The current thumbnail bar displays the largest channel RMS mapped from -60 to 0 dBFS. Separate channel bars, peak hold, and clipping indicators are not implemented. The meter uses the same converted audio path as recording and applies no UI gain or downmix.

Recording FPS uses `identity` statistics after H.264 parsing with access-unit alignment, counting complete encoded frames without Python handoff callbacks. Timestamped cumulative counts feed a bounded ten-second history; the rolling window interpolates its boundary between samples when UI timing is irregular. Counter or clock resets start a new history.

## Camera frame-rate locking

Before V4L2 format negotiation, the source's `prepare-format` callback queries `V4L2_CID_EXPOSURE_AUTO_PRIORITY` and sets it to zero when writable. This disables exposure-driven dynamic frame-rate changes while preserving the current exposure mode. The numeric control ID handles driver naming differences such as `exposure_dynamic_framerate` and `exposure_auto_priority`.

Automatic exposure can take time to settle and may make low-light images darker or noisier to fit the negotiated frame interval. Unsupported, disabled, inactive, or read-only controls produce a warning; capture continues. This is not a guarantee against USB, driver, decoder, or encoder drops, and it does not force a particular frame rate on every device.

## Output, timestamps, and metadata

Every take contains independent video tracks for the discovered cameras and primary screen, plus one audio track for each unique assigned input and required computer-audio input. Audio is uncompressed IEEE float32 PCM (`F32LE`), interleaved at 48 kHz, preserving negotiated channel count. Do not add audio compression or integer conversion to the recording path.

Output names follow `StudioRecorder_<local timestamp with microseconds and UTC offset>_<random suffix>.mkv`. The application exclusively reserves the `.mkv.partial` path and never overwrites an existing take. After EOS and pipeline closure, a hard link publishes the final name without replacing an existing file, then the temporary name is removed. The filesystem must support this operation. Failed/incomplete finalization preserves partial output; crash recovery is not guaranteed.

Stream-scoped title/comment tags identify sources, device identities, and camera/audio associations. A shared audio track lists its associated sources. User-editable track names/comments are not implemented. Some readers expose escaped values from GStreamer's Matroska tag writer; intended-editor compatibility still needs validation.

All tracks share a pipeline clock and base time. `matroskamux` uses `offset-to-zero=true` to normalize the common output timeline without independently zeroing every input. A new pipeline creates a fresh timeline for each take. There is no adjacent manifest or recovery journal. Physical sensor synchronization, measured start offsets, and long-duration audio clock drift have not been comprehensively validated.

## Lifecycle and failures

```text
Discovering / portal consent -> Preparing preview -> Paused
Paused -> Starting take -> Recording -> Finalizing -> Preparing preview -> Paused
Paused -> Changing audio -> Preparing preview -> Paused
Any state -> Exit; an active take is finalized first
```

The controller waits for pipeline PLAYING before reporting Paused or Recording. Recording elapsed time begins at that transition. Play and audio selectors are enabled only while paused; Stop is enabled while starting/recording. During finalization, new takes and assignment changes are blocked.

Stop sends EOS to the entire current recording pipeline and waits for all sinks, including the shared muxer/filesink, to finish. It then closes that pipeline and reopens preview. Closing the window, Ctrl-C, or SIGTERM follows the same finalization path but exits instead of reopening preview. Exiting while stopped creates no file.

Media startup has a 30-second timeout; finalization has a ten-second timeout. Pipeline errors, startup failures, and finalization failures return a nonzero process exit code. Synchronous startup errors are read from the GStreamer bus before cleanup flushes it, preserving the failing element and driver/debug details. Both synchronous and asynchronous errors include the video/audio input name and identity when identifiable, so a failed PipeWire microphone can be distinguished from a portal screen stream. A failed take can still produce a finalized MKV if draining succeeds. SIGKILL cannot finalize output.

## Validation to date

The automated suite currently has 32 tests covering source routing, primary-monitor selection, portal request policy/resource cleanup, rolling FPS, V4L2 locking/fallback behavior, paused startup without files, multiple takes, audio reassignment and recording-time locking, resistance to GLib idle starvation, encoded-rate measurement without preview, output codecs/tags, decoding all tracks, startup diagnostics, and Stop/exit finalization. Media integration tests use synthetic sources and native software H.264 encoding; `ffprobe`/`ffmpeg` inspect and decode the files.

Manual X11 smoke tests have exercised a C920 webcam, primary-monitor capture, webcam microphone, stereo computer audio, NVIDIA H.264 encoding, previews, successive takes, and audio selector recovery. With dynamic frame rate enabled, the camera delivered about 24 FPS despite 30 FPS caps. Disabling it shortened auto exposure from about 41.6 ms to 33.3 ms; the final four seconds of the test recording measured 30.0 FPS. These are results for the tested configuration, not universal hardware guarantees.

Wayland portal behavior has automated mocked coverage. A real Wayland startup smoke test with an HP Wide Vision HD camera reached live-preview readiness and exited cleanly; Wayland recording transitions still need validation. Additional GPU backends, multi-camera bandwidth/encoder limits, editor interoperability, long takes, drift, disk exhaustion, and unplug behavior need hardware validation.

## Future work

- H.265 selection and tested encoder adapters/fallback among usable hardware backends.
- Persistent settings, stable physical device identities, saved audio overrides, and editable track names/comments.
- Per-source enable/Retry controls, hotplug reconciliation, richer source health, and audio-only meter cards.
- Continuous capture with recording branches attached/detached at safe boundaries, replacing full pipeline rebuilds. Recording-only EOS must then avoid ending preview.
- Destination/free-space preflight, disk-use estimates, sustained-backpressure diagnostics, and recoverable session state.
- Per-channel meters, peak hold, clipping indicators, and stale-value handling on device failures.
- Measured synchronization guarantees, explicit common capture boundaries, and long-duration drift validation.

## Technical references

- [ScreenCast portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html): consent, stream selection, and remote descriptors.
- [ximagesrc](https://gstreamer.freedesktop.org/documentation/ximagesrc/): X11 capture rectangles and threading.
- [gtk4paintablesink](https://gstreamer.freedesktop.org/documentation/gtk4/index.html): GTK rendering.
- [matroskamux](https://gstreamer.freedesktop.org/documentation/matroska/matroskamux.html): video/float32 audio formats and muxing.
- [identity](https://gstreamer.freedesktop.org/documentation/coreelements/identity.html): native encoded-buffer counters.
- [V4L2 camera controls](https://docs.kernel.org/userspace-api/media/v4l/ext-ctrls-camera.html): exposure and dynamic frame-rate control.
- [Matroska tags](https://www.matroska.org/technical/tagging.html) and [tag precedence](https://www.matroska.org/technical/tags-precedence.html): track identification and reader compatibility.
