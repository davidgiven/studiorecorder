# StudioRecorder design

This document describes the current implementation and identifies remaining work separately. [AGENTS.md](AGENTS.md) gives the project requirements; [README.md](README.md) covers running the application and dependencies.

## Current behavior

StudioRecorder is a local Linux multitrack recorder implemented in Vala with GTK 4, GLib, and GStreamer. Capture, decoding, conversion, scaling, hardware encoding, metering, and muxing run in native GStreamer elements. Vala coordinates devices, pipeline lifecycle, and UI updates; it does not process individual video frames or audio samples.

The application starts stopped, with live camera and screen previews and audio meters. No recording file is created until Play is pressed. A control bar between the main preview and thumbnails contains Play/Stop and prominent red PAUSED text, replaced by HH:MM:SS elapsed time during recording. Each Play creates a separate timestamped MKV in the working directory. Stop drains and closes that take before returning to live preview. Controls prevent overlapping take transitions.

The large preview displays the selected source. Clicking a thumbnail changes only the displayed source, including during recording. Each preview button has a centered resolution/target-FPS summary above the image and its source name below the image. An audio dropdown beneath the button selects a discovered input, Computer audio, or No audio. Dropdowns are enabled only while paused. Assignments survive pipeline rebuilds and subsequent takes within the current run, but are not saved across application launches.

A default-on Record channel toggle below each thumbnail controls whether its video and selected audio appear in subsequent takes. Toggles are editable only while paused, preserve their values across rebuilds, and do not interrupt preview when changed. A large red X marks excluded thumbnails using a click-through drawing overlay bound to the channel's inclusion state. Disabled channels retain live previews and meters, including during other channels' takes, but have no encoder/frame counter or muxed video track. Their audio is recorded only if an enabled channel also selects it. Screen's toggle additionally controls the independent computer-audio track. With every channel off, Play is disabled and no empty take can be created.

Audio meters overlay thumbnail images. The main preview's top-left overlay shows the selected source's negotiated target FPS and actual post-encoding recording FPS. Actual FPS is a ten-second rolling average of complete encoded video frames, refreshed every quarter-second. It uses available sampling time during warmup, resets for each take, and shows a dash while paused. The measurement comes from the recording branch and is independent of preview frame delivery. It measures encoder output throughput, not physical sensor synchronization or durable disk writes.

## Source and build layout

`src/` contains the Vala application and its native API declarations. `tests/` contains Vala test entry points and Python test drivers. Python is required only for the test drivers; the retired Python application and its packaging have been removed. Each major application class has a matching source filename, and small helpers remain beside their users. Application types have no custom namespace; external API declarations use `Native` and `V4L2`.

The default `make` target builds `./studio-recorder`; `make run` launches it with optional `ARGS`. Compiler working directories are `.obj/app`, `.obj/unit`, and `.obj/portal`. Test executables are `.obj/test-unit` and `.obj/test-portal`. `make test` builds and runs all test groups. `make format` formats `src/*.vala` and `tests/*.vala` with the checked-in Uncrustify configuration, then reformats `README.md` with Pandoc (GitHub-flavored Markdown, prose wrapped at 80 columns). `make clean` removes `.obj/` and the root executable, leaving recordings intact.

## Components and ownership

| Module | Current responsibility |
| --- | --- |
| `src/Application.vala` | GTK UI, transport state, audio assignment, timers, bus events, pipeline rebuilds, and shutdown. |
| `src/Input.vala`, `src/Camera.vala`, `src/Registry.vala` | Input models, source construction, PipeWire discovery, and physical camera/audio association. |
| `src/DesktopCapture.vala` | Primary-monitor capture on X11, single-monitor portal capture on Wayland, computer audio, and portal lifetime. |
| `src/Recorder.vala` | Capture/recording graph, hardware encoder selection, MKV output, track tags, and finalization. |
| `src/VideoTrack.vala`, `src/RollingFramerate.vala` | Negotiated video formats, native encoded-frame counters, and rolling FPS. |
| `src/camera-controls.vala`, `src/v4l2.vapi` | Best-effort camera frame-rate locking through the source's open V4L2 descriptor and typed Linux API declarations. |
| `src/capture-utils.vala`, `src/test-sources.vala`, `src/main.vala` | Shared element construction, explicit synthetic inputs, command-line handling, and initialization. |
| `src/native.vapi` | Direct Xlib `XInitThreads` binding. |
| `tests/tests.vala` | GLib unit and synthetic pipeline/transport checks. |
| `tests/check_recording.py` | Executes the root binary, inspects and decodes saved tracks, and checks startup/options/signals. |
| `tests/portal-test.vala`, `tests/check_portal.py` | Native portal client plus an isolated mock D-Bus service. |

The `Thumbnail` widget holder and RMS-to-meter helper stay with `Application`; `Geometry` stays with desktop capture, and `FrameSample` stays with `RollingFramerate`. Native APIs are called through VAPI declarations and existing POSIX bindings; there are no handwritten C helpers. `Registry` uses `Posix.realpath()` to resolve sysfs ancestry. See [src/README.md](src/README.md) for build and validation details.

GTK updates and transport transitions run on the main loop. Device discovery runs in a worker so waiting on desktop services does not freeze the window. GStreamer bus messages are dispatched on the main loop. An audio change defers preview reconstruction until after the dropdown notification returns, using normal GLib priority: ordinary idle priority can be starved by continuous preview redraws.

There is one pipeline per preview mode or take. Play closes the preview pipeline and opens a recording pipeline. Stop finalizes the recording pipeline, closes it, and opens a fresh preview pipeline. Changing an audio assignment also rebuilds preview. Devices are opened once per pipeline, with tees for video preview and recording; selecting a thumbnail does not reopen devices. Preview images can briefly restart during mode or audio-assignment changes.

## Discovery and audio assignment

Discovery uses the GStreamer PipeWire device provider directly. Physical V4L2 webcams are captured through `v4l2src` using their advertised device paths. This avoids the observed case where PipeWire advertises a webcam but its capture stream fails with “target not found.” Other video sources use provider-created capture elements. Named PipeWire audio inputs open through `pulsesrc` using their node names on the PulseAudio-compatible service; provider capture remains the fallback when no node name is available. Physical webcam routing recognizes alternate V4L2 path metadata even when `device.api` is absent.

Physical audio association uses shared USB ancestry in sysfs, with PipeWire's kernel USB bus metadata as a fallback. Names alone do not establish a match. Missing or ambiguous matches default to No audio and can be resolved using the paused audio selector. The selector also offers discovered microphones that were not automatically associated with a camera. Multiple cameras can share one audio input; capture and recording deduplicate it by identity.

Current identities use provider object paths, node names, or display names as a final fallback. They support the current process but are not a complete persistent device-identity scheme. There is no hotplug reconciliation, physical-camera grouping across arbitrary duplicate capture nodes, saved override store, or per-source enable/Retry UI yet. Capture failures stop the application rather than silently omitting a required source.

## Screen and computer audio

Screen capture and computer audio are required inputs, including when no webcam is connected.

On X11, `xrandr --query` identifies the active primary monitor. `ximagesrc` captures its pixel rectangle, including the pointer, rather than the entire multi-monitor desktop. If only one monitor is active, it is used even without a primary flag. Multiple active monitors without a configured primary cause startup to fail. Xlib threading is initialized through the direct `XInitThreads` binding before GTK and capture start. This enables process-wide Xlib locking; GStreamer owns the capture threads, and GTK still runs on the main thread.

On Wayland, the ScreenCast portal creates a session, requests single-monitor selection, waits for user consent, and provides a PipeWire remote descriptor and stream target. The portable portal API cannot automatically identify/select the primary monitor, so the user must select it in the chooser. Multiple returned streams are rejected. The portal descriptor and session remain alive until application shutdown; cancellation, denial, or session closure fails capture. The media startup timeout does not run while the user is choosing a monitor.

Computer audio uses `pulsesrc device=@DEFAULT_MONITOR@` through PulseAudio or `pipewire-pulse`, capturing the default output monitor rather than the default microphone. While Screen is enabled for recording, computer audio remains a separate track even if its dropdown selects another microphone or No audio. Disabling Screen removes that independent track; computer audio can still be recorded if another enabled channel explicitly selects it. The dropdown determines Screen's associated meter/track metadata.

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

Only enabled video channels receive an encoder/writer branch in a take. Disabled channels retain their preview branch; headless mode terminates their video at a fakesink. Audio from disabled channels still feeds meters but terminates at a fakesink unless an enabled channel selects the same input or enabled Screen requires computer audio. Audio tags list only enabled camera associations.

In preview-only mode, video has no encoder/writer branch and audio terminates at `fakesink` after metering. Headless synthetic preview uses video `fakesink` elements. No file or hardware encoder is needed for preview-only mode.

Preview queues are leaky and bounded to 200 ms. Recording queues are non-leaky and bounded to two seconds. Both disable the default byte and buffer-count queue limits. Recording saturation currently applies backpressure; explicit sustained-overload detection is future work.

Native scaling allows input dimensions beyond the encoder's limits to negotiate a supported recording size. Thumbnail resolution describes capture/preview dimensions, which can differ from encoded dimensions. Efficient GPU-memory paths and optimal capture-mode selection remain future performance work.

`level` posts channel RMS/peak measurements every 50 ms. The current thumbnail bar displays the largest channel RMS mapped from -60 to 0 dBFS. The Vala `level_rms()` helper borrows the message's legacy boxed `GLib.ValueArray`, ignores non-finite readings, and clamps the meter to its display range. It processes channel statistics, not audio samples. Separate channel bars, peak hold, and clipping indicators are not implemented. The meter uses the same converted audio path as recording and applies no UI gain or downmix.

Recording FPS uses `identity` statistics after H.264 parsing with access-unit alignment, counting complete encoded frames without application per-frame callbacks. Timestamped cumulative counts feed a bounded ten-second history; the rolling window interpolates its boundary between samples when UI timing is irregular. Counter or clock resets start a new history.

## Camera frame-rate locking

The Vala `lock_framerate()` function connects the typed plugin signal before capture begins, retaining only a source-name string in the closure to avoid an ownership cycle. Kernel headers provide the actual ioctl request values and struct layouts through `src/v4l2.vapi`.

Before V4L2 format negotiation, the source's `prepare-format` callback queries `V4L2_CID_EXPOSURE_AUTO_PRIORITY` and sets it to zero when writable. This disables exposure-driven dynamic frame-rate changes while preserving the current exposure mode. The numeric control ID handles driver naming differences such as `exposure_dynamic_framerate` and `exposure_auto_priority`.

Automatic exposure can take time to settle and may make low-light images darker or noisier to fit the negotiated frame interval. Unsupported, disabled, inactive, or read-only controls produce a warning; capture continues. This is not a guarantee against USB, driver, decoder, or encoder drops, and it does not force a particular frame rate on every device.

## Output, timestamps, and metadata

Every take contains independent video tracks for enabled cameras and Screen, plus one audio track for each unique input selected by an enabled channel and the independent computer-audio track when Screen is enabled. Audio is uncompressed IEEE float32 PCM (`F32LE`), interleaved at 48 kHz, preserving negotiated channel count. Do not add audio compression or integer conversion to the recording path.

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

The controller waits for pipeline PLAYING before reporting Paused or Recording. Recording elapsed time begins at that transition. Channel toggles and audio selectors are enabled only while paused; Play additionally requires at least one enabled channel; Stop is enabled while starting/recording. During finalization, new takes and assignment changes are blocked.

Stop sends EOS to the entire current recording pipeline and waits for all sinks, including the shared muxer/filesink, to finish. It then closes that pipeline and reopens preview. Closing the window, Ctrl-C, or SIGTERM follows the same finalization path but exits instead of reopening preview. Exiting while stopped creates no file.

Media startup has a 30-second timeout; finalization has a ten-second timeout. Pipeline errors, startup failures, and finalization failures return a nonzero process exit code. Synchronous startup errors are read from the GStreamer bus before cleanup flushes it, preserving the failing element and driver/debug details. Both synchronous and asynchronous errors include the video/audio input name and identity when identifiable, so a failed PipeWire microphone can be distinguished from a portal screen stream. A failed take can still produce a finalized MKV if draining succeeds. SIGKILL cannot finalize output.

## Validation to date

The current implementation has 19 automated checks: eight Vala GLib tests, four executable recording tests, and seven private-D-Bus portal scenarios. They cover channel exclusion/re-enabling, shared-audio deduplication, Screen/computer-audio inclusion, all-off rejection, stopped-only controls, RMS-to-meter conversion, the actual v4l2src callback with an invalid descriptor, primary-monitor geometry, rolling encoded FPS, paused startup, multiple takes, audio changes and recording-time locking, resistance to GLib idle starvation, output codecs/tags, decoding every track, command-line validation, SIGINT/SIGTERM finalization, and portal consent/descriptor lifetime. Recording integration uses synthetic sources and native software H.264; `ffprobe`/`ffmpeg` inspect and decode the files. Portal tests use a private D-Bus with a mock service, including the protocol’s string-typed session handle, missing or malformed session handles, responses arriving before method replies, and pending-request cancellation.

A synthetic GTK preview/record/finalize smoke test also passed. On the current Wayland desktop, a startup smoke test reached live preview readiness after correcting the portal session-handle type; recording and encoder allocation were not exercised by that check. Real X11 capture, Wayland recording, physical camera control writes, hardware encoder allocation, additional GPU backends, multi-camera limits, editor interoperability, long takes, drift, disk exhaustion, and unplug behavior still need validation of the Vala application.

Historical hardware tests of the retired Python implementation exercised a C920 webcam, NVIDIA H.264, primary-monitor capture, webcam and stereo computer audio, multiple takes, and audio switching on X11; a Wayland startup test with an HP Wide Vision HD camera reached preview readiness. Those results informed the architecture but do not validate the current Vala implementation.

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
