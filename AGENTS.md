# StudioRecorder

StudioRecorder is a Python desktop application for multitrack recording on Linux, using PyGObject, GTK 4, GLib, and GStreamer. Keep media processing in native GStreamer elements rather than processing video frames or audio samples in Python.

Discover available cameras and audio inputs, associate camera microphones by physical device identity where possible, and allow manual audio selection while paused. Always include primary-monitor capture and computer audio from the default output monitor. X11 capture uses only the primary monitor; Wayland uses the system screen-sharing chooser with one monitor, which the user must select as primary.

Start stopped with live previews and meters. A Play/Stop bar between the main preview and thumbnails shows prominent red PAUSED text while stopped and elapsed time while recording. Each Play creates a new timestamped MKV in the working directory. Each Stop finalizes and closes that take before returning to preview. Window close, Ctrl-C, and SIGTERM finalize any active take before exit.

Record all video inputs as independent tracks in one MKV, using hardware-accelerated H.264 (H.265 is planned). Record each unique selected audio input once as uncompressed interleaved float32 PCM at 48 kHz, preserving channel count. Computer audio remains a required independent track even when a thumbnail is assigned another microphone or No audio. Embed source-identifying track names and comments.

The UI has a large selected preview and clickable thumbnails with overlaid audio meters. Put a centered resolution/target-FPS summary above each thumbnail image, its source name below, and an audio dropdown below the source name. Audio selection is enabled only while paused and affects the meter and subsequent takes. Keep the main preview's target/actual recording FPS overlay; actual FPS must count post-encoding frames over a rolling ten-second window, not preview frames. Disable exposure-driven dynamic frame rate on supported V4L2 cameras without changing their exposure mode; warn and continue when unavailable.

See [README.md](README.md) for dependencies, usage, and checks, and [DESIGN.md](DESIGN.md) for current architecture, validation limits, and future work. The implementation currently rebuilds capture pipelines at recording transitions and audio changes; saved settings, hotplug recovery, and seamless recording-branch transitions remain future work.

In the Vala port, annotate every argument of a multiline function, method, or constructor call with a preceding `/* parameter_name= */` comment. Use the parameter name from the declaration; for variadic arguments, use a meaningful name describing the value's role or the GObject property being set. Keep annotations accurate when changing calls, including calls in tests, and preserve them when running `make format`.
