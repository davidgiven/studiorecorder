# StudioRecorder design

Status: initial proposal. Requirements come from [AGENTS.md](AGENTS.md); choices below are provisional until implementation validates them on Linux hardware.

Initial implementation milestone: provide a minimal preview window without recording controls or settings. Automatically start recording on launch into one timestamped MKV in the current directory. Closing the window or receiving Ctrl-C/SIGTERM drains the pipeline with EOS, finalizes the output, and exits. The settings and interactive session controls described below are later milestones; see [README.md](README.md) for the skeleton's implemented scope and dependencies.

## Scope and user experience

StudioRecorder records independent camera and audio tracks from a Linux desktop. It discovers camera devices, attempts to associate each with its audio input, and presents all usable cameras for preview. A recording preserves every enabled source; selecting a thumbnail changes only the large preview.

The first version is a local desktop application. It does not mix cameras into a program output, stream to a service, or provide editing, effects, or audio monitoring through speakers. Desktop/screen capture is a possible later source type, not part of initial device discovery.

On launch:

1. Discover cameras and audio inputs, restore saved device choices, and show live thumbnails as devices become ready.
2. Select the first ready camera for the large preview.
3. Show the proposed output MKV path, recording format, enabled sources, and any unresolved audio associations.
4. Enable Record after the enabled sources pass preflight. An ambiguous audio association requires a visible choice of an input or “No audio”; never guess silently.

The main window has a large aspect-preserving preview above a scrollable thumbnail strip. Each thumbnail includes the camera name, selection border, recording enable toggle, and an overlaid audio meter. The selected source's settings expose capture mode and audio assignment. Shared audio is explicitly labeled. Audio-only inputs enabled manually appear as meter cards.

A persistent control bar contains Record/Stop, elapsed time, destination, and session status. Errors stay visible on the affected source and in a session status area. Selecting a source remains available during recording; capture settings, source membership, and audio assignments are locked until recording stops. Devices discovered during recording are offered for the next session.

## Proposed implementation stack

Use Python with PyGObject bindings for GTK 4, GLib, and GStreamer. Application logic handles device discovery, pipeline construction, session state, settings, and UI updates; none of these requires a performance-oriented implementation language. Confirm the supported distribution and library versions before pinning dependencies.

Keep the media data path in native GStreamer elements: capture, decoding, conversion, encoding, metering, and muxing must not process frames or audio samples in Python. Render through the native paintable sink and consume bounded-rate level messages rather than copying media buffers into application code. Python callbacks should be short, especially callbacks invoked from streaming threads; use them only to signal serialized control work. Move blocking filesystem operations off the GTK main loop. If future features require custom per-frame processing, evaluate a native element for that work separately.

Use `gtk4paintablesink` to render each camera once. Bind its paintable to both the thumbnail and, when selected, the main preview. This avoids opening a camera twice or rebuilding its pipeline when selection changes. Validate simultaneous paintable use and rendering performance in the first UI spike. Keep GTK mutations on the main thread; marshal pipeline bus events to application state there.

Do not require a particular GPU vendor. Hide encoder-specific elements and properties behind an encoder adapter. Hardware H.264 is the initial default; H.265 is selectable when a usable adapter is available. A missing hardware encoder is a clear preflight error, with installation/capability diagnostics. Software encoding is not an automatic fallback because hardware encoding is a requirement.

## Components and ownership

| Component | Responsibility |
| --- | --- |
| Device registry | Discover devices, track hotplug, normalize identities and capabilities. |
| Association resolver | Match cameras to audio devices and apply persisted overrides. |
| Capability probe | Validate capture modes and hardware encoder combinations. |
| Capture engine | Own the GStreamer graph, clock policy, source bins, and previews. |
| Session controller | Serialize prepare/start/stop, own the recording state machine and recovery journal. |
| Recording writer | Own recording branches, one shared Matroska muxer, its track mapping, and the output file lifecycle. |
| UI model | Present source state, session state, meter values, and actionable errors. |
| Settings store | Persist preferences, stable source identities, and explicit overrides. |

Only the session controller initiates recording graph changes. Streaming callbacks must not perform filesystem work, block on the UI, or change GTK widgets directly. Pipeline operations and their completion events are serialized to avoid races between Stop, device removal, and errors.

Suggested eventual modules: `devices`, `association`, `media`, `encoders`, `session`, `settings`, and `ui`. Keep pipeline construction independent of widgets so synthetic sources can exercise it without a display.

## Discovery and audio association

Use `GstDeviceMonitor` with video-source and audio-source filters, with provider-specific metadata normalization. Initially target V4L2 cameras and one selected desktop audio backend. Probe PipeWire support first and evaluate a PulseAudio-compatible provider as a fallback; do not enumerate the same physical audio endpoint through both backends at once. Backend availability and permissions must be established on the target desktop.

Group multiple V4L2 nodes belonging to one physical camera and distinguish capture nodes from metadata-only endpoints. Select a usable capture node and mode per camera rather than treating every `/dev/video*` entry as an independent camera. Exclude desktop audio monitor/loopback sources from automatic association.

Device identity preference:

1. Hardware serial plus endpoint/interface identity where available.
2. Stable bus/topology identifier plus endpoint identity.
3. Backend identity as a last resort, with a warning that reconnects may invalidate it.

Device paths and display names alone are not stable keys. Distinguish identical cameras without serial numbers by topology; moving them to another port can require confirmation of the saved mapping.

Audio association priority is an explicit saved override, then an unambiguous shared physical-device identifier or USB parent. Names may suggest candidates but cannot establish a match. A camera may have no audio. Several cameras may use one audio input, which is captured and recorded only once. Preserve channel count by default and expose it in the assignment UI; do not silently downmix.

Open all usable cameras for preview by default, but show busy, inaccessible, or bandwidth-limited sources separately with a Retry action. A source can be excluded from the session to unblock preflight. Never silently omit a source the user has enabled for recording.

## Capture graph and preview

Use one top-level pipeline with a bin per unique capture device. Open each device once, then branch with tees. Negotiate a supported raw or compressed camera mode explicitly. MJPEG/compressed camera modes need a decoder before the raw tee; the initial recording path always uses the selected hardware encoder.

Conceptual graph (conversion elements depend on negotiated caps):

```text
camera -> decode if needed -> raw video tee
                               |-> bounded leaky queue -> preview conversion -> paintable sink
                               `-> bounded queue -> encoder conversion/upload -> HW encoder
                                   -> H.264/H.265 parser -> shared muxer video pad

unique audio input -> convert/resample -> F32LE interleaved, 48 kHz -> audio tee
                               |-> bounded leaky queue -> level -> fakesink
                               `-> bounded queue -> shared muxer audio pad

all recording pads -> one matroskamux -> filesink -> session.mkv
```

Maintain camera aspect ratio. Bound preview queues and drop stale preview frames so a slow display cannot stall capture. Recording queues are bounded and non-leaky: sustained saturation becomes a visible recording failure rather than silent data loss or unlimited memory growth. Initial queue budgets and overload thresholds need measurement with multiple cameras.

Use GStreamer's `level` messages for per-channel RMS and peak readings at approximately 20 Hz. Present RMS as the main meter, peak hold as a marker, and a clipping indicator. Clamp the display at a useful floor such as -60 dBFS. This is a digital level meter, not a claim of calibrated analog VU ballistics. Meters represent the signal being recorded, without UI gain processing. Clear stale values when a source stops or disconnects.

Prefer efficient GPU-memory paths where compatible, but prove correctness with ordinary memory first. Preview conversion and encoder upload requirements differ by GPU and sink; zero-copy operation is an optimization, not a prerequisite for the first version.

## Recording format and synchronization

Each take produces one MKV file containing one video track per enabled camera and one audio track per unique enabled audio input. Video uses hardware H.264 or H.265; audio uses interleaved IEEE float32 PCM (`F32LE`). All recording branches feed request pads on one `matroskamux`, which writes through one `filesink`. A shared microphone is recorded once even when associated with several cameras. Preserve each input's channel count.

Audio remains uncompressed float32 PCM by design; do not add audio compression or convert recording samples to integer PCM.

The MKV contains independent selectable tracks. Give tracks descriptive names and stable ordering within a take. Record camera/audio associations and device identities as container metadata where supported, and retain detailed diagnostics in application state. Validate metadata round-tripping and multivideo/float32 audio import in the intended editor during the capture spike.

Allow an editable name and optional comment for each source before recording, persisted with its device settings. Default names come from device labels; examples are “Camera 1 — front” and “Audio — front camera microphone”. Write the name into the Matroska track name for compatibility with track selectors, and write the comment as track-scoped metadata for additional notes, device identity, and camera/audio associations. A shared audio input's comment lists all associated cameras. Send stream-scoped GStreamer title/comment tag events on each recording branch before the muxer writes track headers; global muxer tags describe the whole take and cannot substitute for per-track tags. Validate names and comments after demuxing on the supported GStreamer version and in the intended editor, since metadata display varies between readers.

The selected destination is a single filename, for example `2026-10-25_14-30-00_<session-id>.mkv`. Never overwrite an existing recording. Write to a temporary suffix such as `.mkv.partial`, then rename after successful finalization. No adjacent manifest is required to play or synchronize the recording. Keep a versioned recovery journal in the application's XDG state directory, updated atomically, with the output path, source-to-track mapping, negotiated caps, encoder details, timing diagnostics, and errors. Preserve incomplete output for recovery.

Use a common pipeline clock and base time. Record a session origin in pipeline running time when recording is armed. Map every recording branch's timestamps/segments to that same origin before muxing. Do not independently reset each track's first buffer to zero: this would erase relative start offsets. The MKV timestamps must preserve those offsets without an external manifest. Treat audio device clock drift through the selected backend's clock-slaving/resampling behavior and verify it experimentally; sharing a pipeline alone does not guarantee physical synchronization.

Before committing the session, prepare all encoders and the shared writer, allocate every muxer pad, and establish a common capture boundary. Video tracks begin at decodable keyframes; retain their actual start offsets from that boundary. Validate this behavior in the graph spike, including encoder preroll, latency, keyframe requests, and muxer interleaving when sources start at different times. The UI reports Recording only after every required branch has begun supplying the writer and output has started. A timeout fails startup and finalizes or preserves the partial output.

Expect ordinary USB cameras to lack hardware frame synchronization. The target is a common software timeline with measured residual offsets and drift, not guaranteed simultaneous sensor exposure. Measure startup alignment and long-duration drift using a shared flash/clap test before setting a numerical synchronization claim.

Use one MKV per take without segmentation. `splitmuxsink` accepts only one video stream per instance and therefore does not fit this multivideo output. Do not present unfinished MKV files as guaranteed crash-recoverable.

## Session lifecycle and failures

```text
Discovering -> Previewing -> Preparing -> Recording -> Finalizing -> Previewing
                                 |            |
                                 `-> Failed <-'
```

Treat source health separately from session state: unavailable, opening, ready, recording, or failed. A Failed session still runs bounded cleanup/finalization before another recording is permitted.

Preflight checks the destination's writability and free space, enabled device readiness, resolved audio choices, negotiated modes, and actual hardware encoder availability for the whole session. Finding an encoder factory is insufficient: test allocation and caps negotiation for concurrent sources. Show estimated disk usage using configured video rates and exact PCM rate (48,000 samples × channels × 4 bytes per second). Free-space estimates are advisory; monitor space and write errors during recording.

Attach/detach recording branches using pad blocking and explicit completion handling. On Stop, send EOS to every active recording input and wait for the shared muxer/filesink to finish, then detach the recording bin and return to preview. Track completion within the recording bin because preview sinks remain active. Do not send EOS to the whole preview graph. Use a finite finalization timeout, preserve the incomplete MKV, and report whether the container finalized successfully.

For the first version, loss of any enabled source, encoder failure, timestamp discontinuity that cannot be handled, or sustained disk/queue failure stops the entire take and attempts to finalize the shared MKV using the data already received. Ensure failed inputs cannot leave the muxer waiting indefinitely for EOS. This simpler policy avoids producing a silently partial session. A shared pipeline can propagate errors across bins; treat failures as session-wide and rebuild preview bins afterward if necessary. Continuing unaffected tracks is a later feature requiring explicit pipeline isolation.

Closing the window during recording requests Stop and shows finalization progress. A forced exit may leave an incomplete MKV; the next launch detects unfinished recovery journals and offers the output locations and diagnostics. Do not delete partial takes automatically.

## Settings and session data

Store versioned user settings under the XDG configuration directory and diagnostics under the XDG state directory. Persist destination, preferred codec, capture mode per device, enabled state, and audio overrides. Hardware-derived identity changes must not silently attach an old override to a different device.

The versioned recovery journal includes a unique session ID, application/library versions, UTC start time, session running-time origin, chosen clock, device configurations, association provenance, the output path, container track mapping, and timeline diagnostics, finalization state, and timestamped warnings/errors. Store media timestamps as integer nanoseconds. Distinguish a completed take, a failed but finalized take, and an incomplete take. Avoid logging captured audio/video content.

## Implementation sequence and validation

1. **Capture spike:** exercise synthetic video/audio and multiple video tracks and at least one real camera with a hardware encoder, float32 PCM audio in the same MKV, common timestamps, branch start/stop, and file finalization. Inspect negotiated caps and demuxed timestamps; confirm the editor can access every video and audio track in the MKV.
2. **Preview shell:** build the GTK window, shared paintables, selection, meters, and source health display. Confirm selection does not reopen capture or affect recording.
3. **Discovery and pairing:** implement stable identity, physical-camera grouping, explicit overrides, and hotplug. Test ambiguous matches and shared audio deduplication.
4. **Session controller:** add preflight, recovery journals, atomic file handling, recording controls, timeouts, and useful failures.
5. **Hardware validation:** test multiple cameras, concurrent encoder limits, USB bandwidth pressure, reconnects, disk exhaustion, and long takes. Measure synchronization and drift before publishing supported configurations.

Automated integration tests should use `videotestsrc` and `audiotestsrc` to verify that one MKV contains exactly the enabled video tracks and deduplicated audio tracks, audio remains float32, preview switching leaves the recording graph intact, timestamps preserve relative offsets, and Stop finalizes playable output. Inject source/write errors and verify bounded cleanup and honest recovery journal states. Hardware encoder tests are conditional and must report skipped coverage when no supported device exists; real hardware validation remains necessary.

## Decisions to validate first

- Confirm the minimum Python, PyGObject, GTK 4, and GStreamer versions on the supported Linux distributions.
- Validate access to all video and float32 audio tracks in one MKV with the intended editor.
- Identify the first hardware encoder backend from the development machine, then validate a second backend before claiming portability.
- Establish expected camera counts, resolutions, frame rates, and take duration; use measurements to choose bitrate and queue defaults.
- Verify the desktop audio backend exposes enough metadata for reliable camera/audio association.

## Technical references

- [GstDeviceMonitor](https://gstreamer.freedesktop.org/documentation/gstreamer/gstdevicemonitor.html): discovery and device-added/removed messages.
- [gtk4paintablesink](https://gstreamer.freedesktop.org/documentation/gtk4/index.html): GTK paintable rendering and optional GPU paths.
- [matroskamux](https://gstreamer.freedesktop.org/documentation/matroska/matroskamux.html): accepted video and raw float32 audio caps.
- [splitmuxsink](https://gstreamer.freedesktop.org/documentation/multifile/splitmuxsink.html): segmentation constraints and asynchronous finalization.
- [Matroska tag precedence](https://www.matroska.org/technical/tags-precedence.html): track names provide compatibility with readers that do not display tags.
- [Matroska tags](https://www.matroska.org/technical/tagging.html): comments and other descriptive metadata.
