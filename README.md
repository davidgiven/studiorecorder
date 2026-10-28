# StudioRecorder

A crudely AI-slopped multitrack video recorder and screen capture tool.

# What?

This is a Linux tool to help me do workbench recordings. It captures all
available video sources, with associated audio, plus a screen capture. There's
live preview via thumbnails with VU meters plus a big preview of any thumbnail.
Everything goes into a single huge timestamped MKV file for the best possible
synchronsiation.

# AI disclosure

Ha ha ha! Hahaha! Haha ha ha hahaha!

# How?

It's written in Vala. Build from the makefile:

``` sh
make
```

You'll get a binary called `./studio-recorder`.

## Dependencies

For building, install Vala (`valac`), a C compiler, Make, pkg-config, and
development headers for GTK 4, libadwaita, libpanel, GStreamer, GLib/GIO
(including gio-unix), Xlib, and Linux V4L2. Install matching runtime packages
for:

- GTK 4.12+, libadwaita 1.4+, libpanel 1.4+, GLib/GIO, GStreamer 1.24+, and
  libX11.
- GStreamer core/base/good/bad plugins, including PipeWire, `identity`,
  `decodebin`, `videoconvert`, `videoscale`, `audioconvert`, `audioresample`,
  `level`, `taginject`, `h264parse`, and `matroskamux`.
- The GTK 4 GStreamer sink, `gtk4paintablesink` (often packaged as
  `gst-plugin-gtk4`). GTK 3's `gtksink` is a different plugin.
- A hardware H.264 encoder and its working driver: VA-API
  (`vah264enc`/`vah264lpenc`), NVIDIA (`nvh264enc`/`nvautogpuh264enc`), Quick
  Sync (`qsvh264enc`), legacy VA-API, or V4L2.
- A running desktop PipeWire service with access to the cameras and audio
  inputs.
- For computer audio: `pulsesrc` and a PulseAudio-compatible server (normally
  `pipewire-pulse`). It captures the default output monitor, not the default
  microphone.
- For X11 screen capture: `ximagesrc`, libX11, and `xrandr`. Only the primary
  monitor is captured, including its pointer. With multiple monitors and no
  configured primary, startup fails instead of recording the entire desktop.
- For Wayland screen capture: `xdg-desktop-portal` with the desktop's ScreenCast
  backend. The system screen-sharing chooser appears during preview setup.
  Select your primary monitor; only one monitor can be selected. The portable
  portal API cannot automatically identify or select the primary monitor.
  Cancelling or denying consent aborts startup. There is no automatic fallback
  to recording an Xwayland window.
- The GStreamer V4L2 plugin and read/write access to `/dev/video*` for physical
  webcams.

# License?

Everything here can be redistributed under the terms of the 2-clause simplified
BSD license. Look at the LICENSE file for the full text.

# Who?

This program was written by myself, David Given <dg@cowlark.com>; I have a
website at <http://cowlark.com>. There may or may not be anything interesting
there.

Audio selections and V4L2 camera-control values are saved per video source in
`$XDG_CONFIG_HOME/studio-recorder/preferences.ini` (normally
`~/.config/studio-recorder/preferences.ini`), including explicit No audio
choices. If a saved microphone is unavailable, the channel uses No audio and
keeps the saved choice for a later launch. Camera sliders use probed device
ranges and defaults, with a reset button beside each slider. Accepted values are
restored at startup and capture rebuilds. Resolution and frame-rate selections
and each Record channel on/off choice are also saved per source. Channels
without a saved choice start enabled; if all saved channels are off, enable one
to use Play. Other channel settings are not yet persisted. Synthetic test mode
does not access user preferences.

Resolution and frame-rate dropdowns appear below the selected source's name,
above its camera adjustments. Change them while paused; the live preview is
rebuilt and the choice applies to subsequent takes. Camera options come from
native source caps, with frame rates filtered by resolution. Without a supported
saved choice, the selectors show the camera's current mode. Backends without
current-format queries use the first negotiated preview format. Screen offers
native, half, and quarter dimensions with selectable target FPS. Selections are
saved per source across launches; unavailable saved modes retain the current
capture format.
