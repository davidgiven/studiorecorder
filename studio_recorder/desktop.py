"""Desktop video and default-output monitor audio, including Wayland consent."""

import ctypes
import ctypes.util
import os
import re
import subprocess
import uuid

from gi.repository import Gio, GLib

from .devices import Camera, Source
from .media import make


def initialize_x11():
    """ximagesrc requires XInitThreads before GTK or capture threads start."""
    if os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
        library = ctypes.util.find_library("X11")
        if not library or not ctypes.CDLL(library).XInitThreads():
            raise RuntimeError("Could not initialize X11 screen capture threading.")


class ElementDevice:
    def __init__(self, factory, **properties):
        self.factory = factory
        self.properties = properties

    def create_element(self, _name):
        return make(self.factory, **self.properties)


def computer_audio():
    # PulseAudio's monitor special name resolves to the default output rather
    # than the default microphone. This also works through pipewire-pulse.
    return Source("Computer audio", ElementDevice("pulsesrc", device="@DEFAULT_MONITOR@"),
                  None, "desktop-audio")


def primary_monitor_geometry(layout):
    active = []
    for line in layout.splitlines():
        match = re.match(r"^\S+ connected (primary )?(\d+)x(\d+)\+(\d+)\+(\d+)(?:\s|$)", line)
        if match:
            primary, width, height, x, y = match.groups()
            geometry = (int(x), int(y), int(width), int(height))
            if primary:
                return geometry
            active.append(geometry)
    if len(active) == 1:
        return active[0]
    raise RuntimeError("No active primary monitor is configured. Set a primary monitor in the desktop display settings.")


def x11_primary_monitor():
    try:
        result = subprocess.run(["xrandr", "--query"], capture_output=True, text=True,
                                check=True, timeout=5, env=dict(os.environ, LC_ALL="C"))
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeError(f"Cannot query the primary monitor with xrandr: {exc}") from exc
    return primary_monitor_geometry(result.stdout)


class DesktopCapture:
    BUS = "org.freedesktop.portal.Desktop"
    PATH = "/org/freedesktop/portal/desktop"
    SCREENCAST = "org.freedesktop.portal.ScreenCast"

    def __init__(self, ready, error):
        self.ready = ready
        self.error = error
        self.connection = None
        self.session = None
        self.remote_fd = None
        self.pending_request = None
        self.subscriptions = set()
        self.closed = False
        self.cancellable = Gio.Cancellable()

    def start(self):
        if os.environ.get("WAYLAND_DISPLAY") or os.environ.get("XDG_SESSION_TYPE") == "wayland":
            Gio.bus_get(Gio.BusType.SESSION, self.cancellable, self._connected)
        elif os.environ.get("DISPLAY"):
            try:
                x, y, width, height = x11_primary_monitor()
            except RuntimeError as exc:
                self._fail(str(exc))
                return
            video = Source("Screen (primary)", ElementDevice(
                "ximagesrc", use_damage=False, show_pointer=True,
                startx=x, starty=y, endx=x + width - 1, endy=y + height - 1),
                           None, "desktop-screen")
            self.ready([Camera(video, computer_audio())])
        else:
            self.error("Screen capture requires an X11 or Wayland desktop session.")

    def _fail(self, message):
        if not self.closed:
            self.error(f"Screen capture: {message}")

    def _connected(self, _source, result):
        try:
            self.connection = Gio.bus_get_finish(result)
            if self.closed:
                return
            # Remember the predictable session path even if the application is
            # closed while CreateSession is still in flight.
            token = "studio_" + uuid.uuid4().hex
            sender = self.connection.get_unique_name()[1:].replace(".", "_")
            self.session = f"{self.PATH}/session/{sender}/{token}"
            self._request("CreateSession", None,
                          {"session_handle_token": GLib.Variant("s", token)}, self._created)
        except GLib.Error as exc:
            self._fail(exc.message)

    def _request(self, method, prefix, options, complete):
        token = "studio_" + uuid.uuid4().hex
        sender = self.connection.get_unique_name()[1:].replace(".", "_")
        path = f"{self.PATH}/request/{sender}/{token}"
        self.pending_request = path
        options = dict(options, handle_token=GLib.Variant("s", token))

        def response(_connection, _sender, _path, _interface, _signal, parameters):
            self.connection.signal_unsubscribe(subscription)
            self.subscriptions.discard(subscription)
            self.pending_request = None
            if self.closed:
                return
            code, results = parameters.unpack()
            if code:
                self._fail("permission was cancelled or denied; screen and computer audio are required inputs.")
                return
            try:
                complete(results)
            except (GLib.Error, RuntimeError, KeyError, ValueError) as exc:
                self._fail(str(exc))

        subscription = self.connection.signal_subscribe(
            self.BUS, "org.freedesktop.portal.Request", "Response", path, None,
            Gio.DBusSignalFlags.NONE, response)
        self.subscriptions.add(subscription)
        if method == "CreateSession":
            parameters = GLib.Variant("(a{sv})", (options,))
        elif method == "SelectSources":
            parameters = GLib.Variant("(oa{sv})", (prefix, options))
        else:
            parameters = GLib.Variant("(osa{sv})", (prefix, "", options))

        def requested(connection, result):
            try:
                connection.call_finish(result)
            except GLib.Error as exc:
                self._fail(exc.message)

        self.connection.call(self.BUS, self.PATH, self.SCREENCAST, method, parameters,
                             GLib.VariantType.new("(o)"), Gio.DBusCallFlags.NONE,
                             10000, self.cancellable, requested)

    def _created(self, results):
        self.session = results["session_handle"]
        subscription = self.connection.signal_subscribe(
            self.BUS, "org.freedesktop.portal.Session", "Closed", self.session, None,
            Gio.DBusSignalFlags.NONE,
            lambda *_args: self._fail("desktop sharing session was closed."))
        self.subscriptions.add(subscription)
        self._request("SelectSources", self.session,
                      {"types": GLib.Variant("u", 1), "multiple": GLib.Variant("b", False)},
                      lambda _results: self._request("Start", self.session, {}, self._started))

    def _started(self, results):
        streams = results.get("streams", [])
        if len(streams) != 1:
            raise RuntimeError("Select only the primary monitor in the screen-sharing chooser.")

        def opened(connection, result):
            try:
                reply, descriptors = connection.call_with_unix_fd_list_finish(result)
                descriptor = descriptors.get(reply.unpack()[0])
                if self.closed:
                    os.close(descriptor)
                    return
                self.remote_fd = descriptor
                inputs = []
                audio = computer_audio()
                for index, (node, props) in enumerate(streams, 1):
                    options = {"fd": descriptor}
                    if props.get("pipewire-serial") is not None:
                        options["target_object"] = str(props["pipewire-serial"])
                    else:
                        options["path"] = str(node)
                    video = Source(f"Screen {index}", ElementDevice("pipewiresrc", **options),
                                   None, f"desktop-screen-{index}")
                    inputs.append(Camera(video, audio))
                self.ready(inputs)
            except (GLib.Error, RuntimeError, ValueError) as exc:
                self._fail(str(exc))

        self.connection.call_with_unix_fd_list(
            self.BUS, self.PATH, self.SCREENCAST, "OpenPipeWireRemote",
            GLib.Variant("(oa{sv})", (self.session, {})), GLib.VariantType.new("(h)"),
            Gio.DBusCallFlags.NONE, 10000, None, self.cancellable, opened)

    def close(self):
        self.closed = True
        self.cancellable.cancel()
        if self.connection:
            for subscription in self.subscriptions:
                self.connection.signal_unsubscribe(subscription)
            self.subscriptions.clear()
            for path, interface in ((self.pending_request, "org.freedesktop.portal.Request"),
                                    (self.session, "org.freedesktop.portal.Session")):
                if path:
                    self.connection.call(self.BUS, path, interface, "Close", None, None,
                                         Gio.DBusCallFlags.NONE, 1000, None, None)
        if self.remote_fd is not None:
            os.close(self.remote_fd)
            self.remote_fd = None
