private bool synthetic;
private bool headless;
private double duration;

/** Validate development options, initialize native libraries, and run the recorder application. */
int main(string[] args)
{
    OptionEntry[] options =
    {
        {
            "test-sources", 0, 0, OptionArg.NONE, ref synthetic, "Use synthetic sources and software encoding", null
        },
        {
            "headless", 0, 0, OptionArg.NONE, ref headless, "Omit the window (requires --test-sources)", null
        },
        {
            "duration", 0, 0, OptionArg.DOUBLE, ref duration, "Record one take for SECONDS (requires --test-sources)", "SECONDS"
        },
        {
            null
        }
    };
    try
    {
        var context = new OptionContext("— Linux multitrack recorder");
        context.add_main_entries(options, null);
        bool explicit_duration = false;
        // OptionArg.DOUBLE defaults to zero; detect a supplied zero as invalid too.
        foreach (string argument in args)
            if (argument == "--duration" || argument.has_prefix("--duration="))
                explicit_duration = true;

        // Validate explicit development options before opening any capture or display resources.
        context.parse(ref args);
        if (args.length > 1)
            throw new OptionError.UNKNOWN_OPTION("Unexpected argument: %s", args[1]);
        if ((headless || explicit_duration) && !synthetic)
            throw new OptionError.BAD_VALUE("--headless and --duration require --test-sources");
        if (explicit_duration && (duration <= 0 || duration.is_nan() || duration.is_infinity() != 0))
            throw new OptionError.BAD_VALUE("--duration must be finite and positive");

        // Initialize Xlib threading before GTK or GStreamer can create capture threads.
        if (Environment.get_variable("DISPLAY") != null && Environment.get_variable("WAYLAND_DISPLAY") == null)
            if (Native.xinit_threads() == 0)
                throw new Studio.RecorderError.FAILED("Cannot initialize X11 threading.");
        Gst.init(ref args);
        var app = new Studio.Application(synthetic, headless, duration);
        return app.run();
    }
    catch (Error error)
    {
        stderr.printf("StudioRecorder: %s\n", error.message);
        return 1;
    }
}
