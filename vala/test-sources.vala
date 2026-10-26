namespace Studio
{
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
}
