"""Exercise the Vala portal client over real D-Bus, isolated from desktop services."""
import os
from pathlib import Path
import subprocess
import sys
import time

if "--inside" not in sys.argv:
    raise SystemExit(subprocess.call(["dbus-run-session", "--", sys.executable, __file__, "--inside"], timeout=60))

from gi.repository import Gio, GLib

BINARY = Path(__file__).resolve().parents[1] / "build/test-vala-portal"
BUS = "org.freedesktop.portal.Desktop"
PATH = "/org/freedesktop/portal/desktop"
XML = """<node><interface name="org.freedesktop.portal.ScreenCast">
<method name="CreateSession"><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method>
<method name="SelectSources"><arg type="o" direction="in"/><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method>
<method name="Start"><arg type="o" direction="in"/><arg type="s" direction="in"/><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method>
<method name="OpenPipeWireRemote"><arg type="o" direction="in"/><arg type="a{sv}" direction="in"/><arg type="h" direction="out"/></method>
</interface></node>"""
connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
connection.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                     GLib.Variant("(su)", (BUS, 0)), GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, -1, None)
scenario = ""
methods = []


def method_call(conn, sender, path, interface, method, parameters, invocation):
    methods.append(method)
    values = parameters.unpack()
    if method == "OpenPipeWireRemote":
        descriptors = Gio.UnixFDList.new()
        fd = os.open(os.devnull, os.O_RDONLY)
        try:
            index = descriptors.append(fd)
        finally:
            os.close(fd)
        invocation.return_value_with_unix_fd_list(GLib.Variant("(h)", (index,)), descriptors)
        return
    options = values[-1]
    token = options["handle_token"]
    sender_path = sender[1:].replace(".", "_")
    request_path = f"{PATH}/request/{sender_path}/{token}"
    results = {}
    response = 0
    if method == "CreateSession":
        session = f"{PATH}/session/{sender_path}/{options['session_handle_token']}"
        results["session_handle"] = GLib.Variant("o", session)
        if scenario == "denied":
            response = 1
    elif method == "SelectSources":
        assert options["types"] == 1 and options["multiple"] is False
    elif method == "Start":
        props = {"pipewire-serial": GLib.Variant("t", 123)} if scenario == "serial" else {}
        streams = [(5, props)]
        if scenario == "multiple":
            streams.append((6, {}))
        results["streams"] = GLib.Variant("a(ua{sv})", streams)
    # Deliberately deliver Response before the method reply to test the portal race.
    if scenario != "cancel":
        conn.emit_signal(sender, request_path, "org.freedesktop.portal.Request", "Response",
                         GLib.Variant("(ua{sv})", (response, results)))
    invocation.return_value(GLib.Variant("(o)", (request_path,)))


registration = connection.register_object(PATH, Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], method_call, None, None)
for scenario in ("serial", "node", "denied", "multiple", "cancel"):
    methods.clear()
    process = subprocess.Popen([str(BINARY), scenario], env=dict(os.environ, WAYLAND_DISPLAY="test-wayland",
                               G_DEBUG="fatal-criticals"), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    loop = GLib.MainLoop()
    deadline = time.monotonic() + 12

    def poll():
        if time.monotonic() > deadline:
            process.kill()
        if process.poll() is not None:
            loop.quit()
            return GLib.SOURCE_REMOVE
        return GLib.SOURCE_CONTINUE

    GLib.timeout_add(20, poll)
    try:
        loop.run()
    finally:
        if process.poll() is None:
            process.kill()
    output = process.communicate()[0].decode()
    if process.returncode != 0:
        raise AssertionError(f"{scenario}: {output}")
    assert methods[0] == "CreateSession"
    if scenario in ("serial", "node"):
        assert methods == ["CreateSession", "SelectSources", "Start", "OpenPipeWireRemote"]
    print(f"portal {scenario}: ok", flush=True)
connection.unregister_object(registration)
