# StudioRecorder

StudioRecorder is a Vala desktop application for multitrack recording on Linux, using GTK 4, GLib, and GStreamer. Keep media processing in native GStreamer elements rather than processing video frames or audio samples in Vala.

Discover available cameras and audio inputs, associate camera microphones by physical device identity where possible, and allow manual audio selection while paused. Always include primary-monitor capture and computer audio from the default output monitor. X11 capture uses only the primary monitor; Wayland uses the system screen-sharing chooser with one monitor, which the user must select as primary.

Start stopped with live previews and meters. A permanent toolbar below the traditional menu bar contains the recording controls and status, showing prominent red PAUSED text while stopped and elapsed time while recording. File contains About and Exit; View contains panel-area visibility toggles. Each Play creates a new timestamped MKV in the working directory. Each Stop finalizes and closes that take before returning to preview. Window close, Ctrl-C, and SIGTERM finalize any active take before exit.

Use streaming Matroska so written media does not depend on a final duration/index trailer; Stop still drains and closes the take. Record enabled video inputs as independent tracks in one MKV, using hardware-accelerated H.264 (H.265 is planned). Capture physical microphones directly through ALSA `hw:` devices, preferring float32 only when supported by hardware. Record each unique selected audio input once as uncompressed interleaved PCM in its negotiated native sample format, rate, and channel count, without conversion or resampling in the recording branch. Convert only on a separate metering branch. Computer audio remains a sound-server monitor source. When Screen is enabled for recording, computer audio remains an independent track even if its thumbnail is assigned another microphone or No audio. Disabling Screen also disables that independent computer-audio track; an enabled channel explicitly selecting the same audio input still records it once. Embed source-identifying track names and comments.

The UI has a large selected preview and clickable thumbnails with overlaid audio meters. Put a centered resolution/target-FPS summary above each thumbnail image, its source name below, and an audio dropdown below the source name. Audio selection is enabled only while paused and affects the meter and subsequent takes. Put a default-on Record channel toggle below each thumbnail; enable it only while paused. It controls inclusion of that channel's video and selected audio in subsequent takes, while live previews and meters continue. Draw a large red X over excluded thumbnails without intercepting clicks or stopping their previews. Preserve inclusion choices across pipeline rebuilds. Shared audio remains recorded once while any enabled channel selects it. Disable Play when every channel is off. Keep the main preview's target/actual recording FPS overlay; actual FPS must count post-encoding frames over a rolling ten-second window, not preview frames. Disable exposure-driven dynamic frame rate on supported V4L2 cameras without changing their exposure mode; warn and continue when unavailable.

See [README.md](README.md) for dependencies, usage, and checks, and [DESIGN.md](DESIGN.md) for current architecture, validation limits, and future work. The implementation currently rebuilds capture pipelines at recording transitions and audio changes; per-channel audio selections, resolution/frame-rate selections, recording inclusion, V4L2 camera-control values, controls-pane width, and main-window geometry are saved in user preferences, while other saved settings, hotplug recovery, and seamless recording-branch transitions remain future work.

Do not update README.md with changes to the design unless explicitly asked to.

## Source layout and native APIs

Application sources and VAPI declarations live in `src/`. Put each major class in its own file named after the class; trivial helpers may stay beside their users. Application types live at the top level without a custom application namespace. Keep external bindings grouped in `Native` and `V4L2`.

Use existing Vala/POSIX bindings or small VAPI declarations for native APIs. `Native.xinit_threads()` binds directly to Xlib, filesystem link resolution uses `Posix.realpath()`, and camera control logic lives in `src/CameraControl.vala` and `src/CameraControls.vala`, with capture-lifecycle hooks in `src/camera-controls.vala` and typed Linux declarations in `src/v4l2.vapi`. There are no handwritten C helpers. Initialize Xlib threading before GTK/GStreamer uses X11. Keep GTK work on the main loop; GStreamer owns its capture and media-processing threads.

Vala test programs and Python test drivers live in `tests/`. Python is a test dependency only; do not restore the retired Python application. Keep synthetic input factories in `src/test-sources.vala`, since the application's explicit `--test-sources` mode uses them.

## Build and checks

- `make` builds `./studio-recorder` in the repository root.
- `make run` launches the application; pass options through `ARGS`, for example `make run ARGS=--test-sources`.
- `make test` builds and runs the Vala checks, executable recording tests, and private-D-Bus portal tests. These need ffprobe, ffmpeg, Python/PyGObject, dbus-run-session, and synthetic GStreamer plugins.
- `make format` runs Uncrustify on Vala sources in both `src/` and `tests/` using `uncrustify.cfg`, then formats `README.md` as GitHub-flavored Markdown with Pandoc at 80 columns.
- `make clean` removes `.obj/` and `studio-recorder`. Build intermediates and test executables belong in `.obj/`; recordings must not be cleaned.

Use synthetic sources for automated recording checks. Do not treat synthetic or mocked portal results as hardware validation; document real-camera, screen-capture, and encoder validation separately.

## Code conventions

Document every class, constructor, function, and method. Divide code into logical paragraphs. Separate each paragraph from the preceding code with a blank line followed by a comment explaining the next paragraph’s purpose, ownership, or lifecycle constraints. Apply this within longer functions, constructors, methods, loops, and callbacks; keep short, single-purpose bodies together.

Use four-space indentation and Allman-style braces. Do not put spaces before function-call or function-declaration parentheses, including calls following `yield`. Put separate assignments and statements on separate lines. Indent switch bodies and case bodies, and leave blank lines between a clause's `break` and the next case. Do not put a first statement beside its case label unless the complete clause, including `break`, fits on that line; separate lines are always acceptable.

For multiline calls, put the first argument on the line after the opening parenthesis and each subsequent argument on its own line. Multiline lambda bodies start on the line after the opening brace and are indented one level inside it.

Annotate every argument of a multiline function, method, or constructor call with a preceding `/* parameter_name= */` comment on the same line as its value. Use the parameter name from the declaration; for variadic arguments, use a meaningful name describing the value's role or the GObject property being set. Use member-name comments for multiline struct initializers, with each member value on its own line. Keep annotations accurate when changing calls, including calls in tests, and preserve them when running `make format`.
