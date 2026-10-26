// A real D-Bus client exercised against an isolated mock portal by check_portal.py.

/** Exercise portal preparation, failure handling, and descriptor cleanup against a private mock service. */
int main(string[] args)
{
    var loop = new MainLoop();
    string scenario = args[1];
    var capture = new Studio.DesktopCapture();
    int code = 1;
    uint watchdog = Timeout.add_seconds(
        /* interval= */ 8,
        /* function= */ () =>
        {
            GLib.error("Portal test timed out: %s", scenario);
        });

    // Cancel while the mock portal withholds its response to exercise pending-request cleanup.
    if (scenario == "cancel")
        Timeout.add(
            /* interval= */ 150,
            /* function= */ () =>
            {
                capture.close();
                return Source.REMOVE;
            });
    capture.prepare.begin(
        /* callback= */ (object, result) =>
        {
            try
            {
                var camera = capture.prepare.end(result);
                assert(scenario == "serial" || scenario == "node");
                assert(camera.audio.identity == "desktop-audio");
                assert(camera.audio.audio_name == "@DEFAULT_MONITOR@");
                assert(camera.input.factory == "pipewiresrc");
                if (scenario == "serial")
                    assert(camera.input.remote_target == "123");
                else
                    assert(camera.input.remote_path == "5");

                // The descriptor must remain open for capture and be released with the portal session.
                int fd = camera.input.remote_fd;
                assert(Posix.fcntl(fd, Posix.F_GETFD) >= 0);
                capture.close();
                assert(Posix.fcntl(fd, Posix.F_GETFD) < 0);
                code = 0;

            }
            catch (Error error)
            {
                // Each negative scenario must fail for its intended reason, not an unrelated D-Bus error.
                if (scenario == "denied")
                    assert(error.message.contains("cancelled or denied"));
                else if (scenario == "multiple")
                    assert(error.message.contains("primary monitor"));
                else if (scenario == "cancel")
                    assert(error is IOError.CANCELLED);
                else
                    GLib.error("Unexpected portal failure: %s", error.message);
                capture.close();
                code = 0;
            }
            loop.quit();
        });

    // The watchdog bounds failures even if no asynchronous completion arrives.
    loop.run();
    Source.remove(watchdog);
    return code;
}
