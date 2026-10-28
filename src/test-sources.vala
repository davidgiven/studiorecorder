/** Describe a live synthetic source without accessing physical capture devices. */
public Input test_input(string name, string identity, bool video, int pattern)
{
    var input = new Input(name, identity);
    input.factory = video ? "videotestsrc" : "audiotestsrc";
    input.pattern = pattern;
    return input;
}

/** Create two test cameras sharing a microphone, plus screen and independent computer audio. */
public List<Camera> test_cameras()
{
    var cameras = new List<Camera> ();
    var audio = test_input("Test microphone", "test-audio", false, 0);
    for (int i = 0; i < 2; i++)
        cameras.append(
            /* data= */ new Camera(
                /* input= */ test_input(
                    /* name= */ "Test camera %d".printf(i + 1),
                    /* identity= */ "test-video-%d".printf(i),
                    /* video= */ true,
                    /* pattern= */ i),
                /* audio= */ audio));

    // Computer audio remains separate from the shared test microphone.
    cameras.append(
        /* data= */ new Camera(
            /* input= */ test_input("Screen", "desktop-screen", true, 2),
            /* audio= */ test_input("Computer audio", "desktop-audio", false, 2)));
    return cameras;
}

/** Constrain a synthetic source before capture negotiation to emulate native-only hardware PCM. */
public Gst.Element test_audio_source(Input input) throws Error
{
    var bin = new Gst.Bin(null);
    var source = make("audiotestsrc");
    source.set("is-live", true, "freq", 440.0 + input.pattern * 220.0);
    var format = make("capsfilter");
    format.set("caps", Gst.Caps.from_string(input.test_audio_caps));
    bin.add(source);
    bin.add(format);
    if (!source.link(format))
        throw new RecorderError.FAILED("Cannot constrain synthetic native audio format.");

    // Expose only the constrained pad so Recorder negotiates against the emulated hardware modes.
    bin.add_pad(new Gst.GhostPad("src", format.get_static_pad("src")));
    return bin;
}
