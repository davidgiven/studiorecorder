/** Check saved destinations, date expansion, invalid patterns, and collision-safe reservations. */
private void test_recording_output()
{
    try
    {
        string directory = DirUtils.make_tmp("studio-output-XXXXXX");
        string path = Path.build_filename(directory, "preferences.ini");
        var preferences = new Preferences(path);
        var output = preferences.load_output();
        assert(output.pattern == RecordingOutput.DEFAULT_PATTERN);
        output.directory = directory;
        output.pattern = "Take_%Y-%m-%d_%H-%M-%S_{uuid}.mkv";
        var time = new DateTime.local(2026, 10, 29, 12, 34, 56);
        assert(output.filename(time, "id") == "Take_2026-10-29_12-34-56_id.mkv");
        preferences.save_output(output);
        var restored = new Preferences(path).load_output();
        assert(restored.directory == directory);
        assert(restored.pattern == output.pattern);

        // Constant names must skip both finished takes and reservations without modifying either.
        output.pattern = "Take.mkv";
        string existing = Path.build_filename(directory, "Take.mkv");
        FileUtils.set_contents(existing, "original take");
        string first = output.reserve();
        string second = output.reserve();
        assert(first == Path.build_filename(directory, "Take_1.mkv"));
        assert(second == Path.build_filename(directory, "Take_2.mkv"));
        string contents;
        FileUtils.get_contents(existing, out contents);
        assert(contents == "original take");

        // Reject paths, unsupported directives, control characters, and non-Matroska filenames.
        foreach (string invalid in new string[] { "../Take.mkv", "%D.mkv", "%n.mkv", "%.mkv", "Take\n.mkv", "Take.mp4", "" })
        {
            output.pattern = invalid;
            bool rejected = false;
            try
            {
                output.validate();
            }
            catch (Error error)
            {
                rejected = true;
            }
            assert(rejected);
        }

        // Remove only the isolated files created by this check.
        FileUtils.unlink(first + ".partial");
        FileUtils.unlink(second + ".partial");
        FileUtils.unlink(existing);
        FileUtils.unlink(path);
        DirUtils.remove(directory);
    }
    catch (Error error)
    {
        GLib.error("%s", error.message);
    }
}

/** Assert approximate equality for floating-point framerate calculations. */
private void assert_near(double actual, double expected)
{
    assert(Math.fabs(actual - expected) < 0.001);
}

/** Build the legacy boxed channel readings emitted by GStreamer's native level element. */
private Gst.Structure rms_message(double[] readings)
{
    var channels = new GLib.ValueArray(0);
    foreach (double reading in readings)
    {
        Value sample = Value(typeof(double));
        sample.set_double(reading);
        channels.append(sample);
    }

    // The structure owns a boxed copy after this helper's local array is released.
    Value value = Value(typeof(GLib.ValueArray));
    value.set_boxed(channels);
    var message = new Gst.Structure.empty("level");
    message.set_value("rms", value);
    return message;
}

/** Check channel selection, meter limits, invalid readings, and missing RMS metadata. */
private void test_level_rms()
{
    assert_near(level_rms(rms_message({ -30.0, -12.0 })), 0.8);
    assert_near(level_rms(rms_message({ -90.0 })), 0.0);
    assert_near(level_rms(rms_message({ 6.0 })), 1.0);
    assert_near(level_rms(rms_message({})), 0.0);

    // Non-finite channels must not hide a finite reading or light the meter on their own.
    assert_near(level_rms(rms_message({ double.NAN, double.INFINITY, -double.INFINITY, -30.0 })), 0.5);
    assert_near(level_rms(rms_message({ double.NAN, double.INFINITY, -double.INFINITY })), 0.0);

    var missing = new Gst.Structure.empty("level");
    assert_near(level_rms(missing), 0.0);
    missing.set_value("rms", "unexpected value type");
    assert_near(level_rms(missing), 0.0);

    Value empty = Value(typeof(GLib.ValueArray));
    empty.set_boxed(null);
    missing.set_value("rms", empty);
    assert_near(level_rms(missing), 0.0);
}

/** Exercise the real v4l2src signal callback without opening a physical capture device. */
private void test_camera_framerate_callback()
{
    try
    {
        var input = new Input("Unavailable test camera", "test-v4l2-callback");
        input.video_path = "/dev/studio-recorder-nonexistent-camera";
        var source = input.create_element();
        var caps = Gst.Caps.from_string("video/x-raw");

        // An invalid descriptor must take the warning path and return normally.
        Test.expect_message(
            /* log_domain= */ null,
            /* log_level= */ LogLevelFlags.LEVEL_WARNING,
            /* pattern= */ "*exposure-driven frame-rate control unavailable*");
        ((V4L2.Source) source).prepare_format(-1, caps);
        Test.assert_expected_messages();
    }
    catch (Error error)
    {
        GLib.error("%s", error.message);
    }
}

/** Cover rolling-window interpolation, stalled output, duplicate timestamps, and counter or clock resets. */
private void test_rates()
{
    var history = new RollingFramerate();
    assert(history.update(0, 0).is_nan());
    assert_near(history.update(Gst.SECOND, 30), 30);
    assert_near(history.update(9 * Gst.SECOND, 270), 30);

    // Cross the rolling boundary, then let all earlier encoded frames age out.
    assert_near(history.update(12 * Gst.SECOND, 360), 30);
    assert_near(history.update(22 * Gst.SECOND, 360), 0);

    // Counter resets, repeated timestamps, and clock resets must not reuse stale history.
    assert(history.update(23 * Gst.SECOND, 0).is_nan());
    assert_near(history.update(24 * Gst.SECOND, 60), 60);
    assert(history.update(24 * Gst.SECOND, 60).is_nan());
    assert(history.update(Gst.SECOND, 0).is_nan());
}

/** Check primary-monitor selection, single-monitor fallback, and rejection of ambiguous layouts. */
private void test_geometry()
{
    try
    {
        var primary = primary_monitor_geometry("DP-1 connected 1920x1080+0+0\nHDMI-1 connected primary 2560x1440+1920+0 (normal)");
        assert(primary.x == 1920 && primary.width == 2560 && primary.height == 1440);
        var only = primary_monitor_geometry("DP-1 connected 1920x1080+0+0 (normal)");
        assert(only.width == 1920);

        // Multiple active monitors without a primary must not silently record the whole desktop.
        bool rejected = false;
        try
        {
            primary_monitor_geometry("DP-1 connected 1920x1080+0+0\nDP-2 connected 1920x1080+1920+0");
        }
        catch (Error error)
        {
            rejected = true;
        }
        assert(rejected);
    }
    catch (Error error)
    {
        GLib.error("%s", error.message);
    }
}

/** Verify recording FPS comes from encoded output even when no preview sink exists. */
private void test_encoded_rate()
{
    string original = Environment.get_current_dir();
    try
    {
        string directory = DirUtils.make_tmp("studio-vala-fps-XXXXXX");
        var output = new RecordingOutput();
        output.directory = directory;
        output.pattern = "Configured-take.mkv";

        // Construct a real recording pipeline with synthetic inputs and no rendering branch.
        var inputs = test_cameras();
        inputs.nth_data(2).input.video_mode = new VideoMode(320, 240, 30, 1);
        var required = new List<Input> ();
        required.append(inputs.nth_data(2).audio);
        var recorder = new Recorder(true, false, true, output);
        recorder.build(inputs, required);
        recorder.start();

        // Wait for EOS before publishing the take; fail promptly on any media error.
        var loop = new MainLoop();
        var bus = recorder.pipeline.get_bus();
        bool finalized = false;
        bus.add_signal_watch();
        ulong handler = bus.message.connect(
            /* handler= */ (message) =>
            {
                if (message.type == Gst.MessageType.ERROR)
                    GLib.error("%s", recorder.describe_error(message));
                if (message.type == Gst.MessageType.EOS)
                {
                    finalized = true;
                    loop.quit();
                }
            });
        foreach (var track in recorder.videos)
            track.sample(Gst.Util.get_timestamp());

        // Allow encoded output to accumulate before checking its rate against negotiated FPS.
        uint timer = Timeout.add(
            /* interval= */ 1500,
            /* function= */ () =>
            {
                foreach (var track in recorder.videos)
                {
                    track.sample(Gst.Util.get_timestamp());
                    assert_near(track.target, 30);
                    if (track.camera.input == inputs.nth_data(2).input)
                    {
                        assert(track.width == 320);
                        assert(track.height == 240);
                    }
                    assert(track.actual > 25 && track.actual < 35);
                    assert(track.paintable == null);
                }
                assert(recorder.stop());
                return Source.REMOVE;
            });
        uint watchdog = Timeout.add_seconds(
            /* interval= */ 12,
            /* function= */ () =>
            {
                GLib.error("Recording test timed out");
            });
        loop.run();
        assert(finalized);
        Source.remove(watchdog);
        // timer already removed after sending EOS.
        timer = 0;
        bus.disconnect(handler);
        bus.remove_signal_watch();

        // Finalization must replace the partial name with a completed recording.
        recorder.close(true);
        assert(recorder.final_path == Path.build_filename(directory, "Configured-take.mkv"));
        assert(FileUtils.test(recorder.final_path, FileTest.EXISTS));
        assert(!FileUtils.test(recorder.partial_path, FileTest.EXISTS));
        FileUtils.unlink(recorder.final_path);
        Environment.set_current_dir(original);
        DirUtils.remove(directory);
    }
    catch (Error error)
    {
        Environment.set_current_dir(original);
        GLib.error("%s", error.message);
    }
}

/** Exercise paused audio edits, busy-loop scheduling, duplicate controls, and separate finalized takes. */
private void test_transport()
{
    string original = Environment.get_current_dir();
    try
    {
        string directory = DirUtils.make_tmp("studio-vala-transport-XXXXXX");
        Environment.set_current_dir(directory);
        var app = new Application(true, true);
        int phase = 0;
        int recordings = 0;
        uint64 start = 0;
        uint busy = 0;

        // Drive transport through public controls while simulating continuously ready preview work.
        uint poll = Timeout.add(
            /* interval= */ 50,
            /* function= */ () =>
            {
                var state = app.transport_state;
                if (state == TransportState.PAUSED)
                {
                    if (phase == 0)
                    {
                        assert(!app.select_audio("test-video-0", "missing"));
                        assert(app.select_audio("test-video-0", null));
                        assert(!app.select_audio("test-video-1", null)); // locked during rebuild
                        busy = Idle.add(() => Source.CONTINUE, Priority.DEFAULT_IDLE - 10);
                        phase = 1;
                    }
                    else if (phase == 1)
                    {
                        Source.remove(busy);
                        assert(app.select_audio("desktop-screen", null));
                        phase = 2;
                    }
                    else if (phase == 2 || phase == 4)
                    {
                        app.play();
                        app.play();
                        phase = 3;
                        start = 0;
                    }
                    else if (phase == 5)
                    {
                        app.request_exit();
                        return Source.REMOVE;
                    }
                }
                else if (state == TransportState.RECORDING && phase == 3)
                {
                    assert(!app.select_audio("test-video-1", null));
                    if (start == 0)
                        start = Gst.Util.get_timestamp();
                    if (Gst.Util.get_timestamp() - start > 400 * Gst.MSECOND)
                    {
                        recordings++;
                        app.stop();
                        app.stop();
                        phase = recordings == 1 ? 4 : 5;
                    }
                }
                return Source.CONTINUE;
            });
        uint watchdog = Timeout.add_seconds(
            /* interval= */ 12,
            /* function= */ () =>
            {
                GLib.error("Transport test timed out");
            });
        assert(app.run() == 0);
        Source.remove(watchdog);
        poll = 0;
        assert(recordings == 2);

        // Inspect both completed takes and ensure no unfinished partial files remain.
        var dir = Dir.open(directory);
        string? filename;
        uint files = 0;
        while ((filename = dir.read_name()) != null)
        {
            assert(filename.has_suffix(".mkv"));
            // Validate deduplication and mandatory computer audio even with screen audio disabled.
            string output;
            int result;
            Process.spawn_sync(
                /* working_directory= */ null,
                /* argv= */ new string[] { "ffprobe", "-v", "error", "-select_streams", "a",
                                           "-show_entries", "stream=codec_name", "-of", "csv=p=0", Path.build_filename(directory, filename) },
                /* envp= */ null,
                /* _flags= */ SpawnFlags.SEARCH_PATH,
                /* child_setup= */ null,
                /* standard_output= */ out output,
                /* standard_error= */ null,
                /* wait_status= */ out result);
            assert(result == 0);
            assert(output.strip().split("\n").length == 2);
            FileUtils.unlink(filename);
            files++;
        }
        assert(files == 2);
        Environment.set_current_dir(original);
        DirUtils.remove(directory);
    }
    catch (Error error)
    {
        Environment.set_current_dir(original);
        GLib.error("%s", error.message);
    }
}

/** Record one short synthetic take and verify channel selection through actual saved tracks. */
private void verify_channel_take(List<Camera> cameras, string[] included, string[] excluded)
{
    try
    {
        var required = new List<Input> ();
        // Computer audio follows Screen even when its audio dropdown selects another input.
        required.append(test_input("Computer audio", "desktop-audio", false, 2));
        var recorder = new Recorder(true, false, true);
        recorder.build(cameras, required);
        var loop = new MainLoop();
        var bus = recorder.pipeline.get_bus();
        bus.add_signal_watch();
        bool finalized = false;
        ulong handler = bus.message.connect(
            /* handler= */ (message) =>
            {
                if (message.type == Gst.MessageType.ERROR)
                    GLib.error("%s", recorder.describe_error(message));
                if (message.type == Gst.MessageType.EOS)
                {
                    finalized = true;
                    loop.quit();
                }
            });
        recorder.start();
        Timeout.add(
            /* interval= */ 400,
            /* function= */ () =>
            {
                assert(recorder.stop());
                return Source.REMOVE;
            });
        uint watchdog = Timeout.add_seconds(
            /* interval= */ 12,
            /* function= */ () =>
            {
                GLib.error("Channel recording timed out");
            });
        loop.run();
        Source.remove(watchdog);
        assert(finalized);
        bus.disconnect(handler);
        bus.remove_signal_watch();
        recorder.close(true);

        // Source IDs in stream comments identify both omitted tracks and shared-audio associations.
        string output;
        int result;
        Process.spawn_sync(
            /* working_directory= */ null,
            /* argv= */ new string[] { "ffprobe", "-v", "error", "-show_entries", "stream=codec_type:stream_tags=title,comments", "-of", "compact", recorder.final_path },
            /* envp= */ null,
            /* _flags= */ SpawnFlags.SEARCH_PATH,
            /* child_setup= */ null,
            /* standard_output= */ out output,
            /* standard_error= */ null,
            /* wait_status= */ out result);
        assert(result == 0);
        assert(output.strip().split("\n").length == included.length);
        output = output.replace("\\", "");
        foreach (string identity in included)
            assert(output.contains(identity));
        foreach (string identity in excluded)
            assert(!output.contains(identity));

        // Disabled video branches still negotiate and disabled audio still supplies meters.
        assert(recorder.videos.length() == 3);
        foreach (var track in recorder.videos)
            assert((track.counter != null) == track.camera.record_enabled);
        FileUtils.unlink(recorder.final_path);
    }
    catch (Error error)
    {
        GLib.error("%s", error.message);
    }
}

/** Check shared microphones, disabled screen audio, re-enabling, and all-off recording rejection. */
private void test_channel_recording()
{
    string original = Environment.get_current_dir();
    try
    {
        string directory = DirUtils.make_tmp("studio-channel-recording-XXXXXX");
        Environment.set_current_dir(directory);
        var cameras = test_cameras();
        foreach (var camera in cameras)
            assert(camera.record_enabled);

        // One enabled camera retains its shared microphone; Screen contributes neither video nor computer audio.
        cameras.nth_data(0).record_enabled = false;
        cameras.nth_data(2).record_enabled = false;
        verify_channel_take(
            /* cameras= */ cameras,
            /* included= */ { "test-video-1", "test-audio" },
            /* excluded= */ { "test-video-0", "desktop-screen", "desktop-audio", "Test camera 1" });

        // If every microphone association is off, only Screen and its independent computer audio remain.
        cameras.nth_data(1).record_enabled = false;
        cameras.nth_data(2).record_enabled = true;
        verify_channel_take(
            /* cameras= */ cameras,
            /* included= */ { "desktop-screen", "desktop-audio" },
            /* excluded= */ { "test-video-0", "test-video-1", "test-audio" });

        // Enabled Screen retains independent computer audio even when its dropdown selects the shared microphone.
        var computer = cameras.nth_data(2).audio;
        cameras.nth_data(2).audio = cameras.nth_data(1).audio;
        verify_channel_take(
            /* cameras= */ cameras,
            /* included= */ { "desktop-screen", "desktop-audio", "test-audio" },
            /* excluded= */ { "test-video-0", "test-video-1" });
        cameras.nth_data(2).audio = computer;

        // A shared computer-audio input is still recorded if another enabled channel explicitly selects it.
        cameras.nth_data(0).audio = cameras.nth_data(2).audio;
        cameras.nth_data(0).record_enabled = true;
        cameras.nth_data(2).record_enabled = false;
        verify_channel_take(
            /* cameras= */ cameras,
            /* included= */ { "test-video-0", "desktop-audio" },
            /* excluded= */ { "test-video-1", "desktop-screen", "test-audio" });

        foreach (var camera in cameras)
            camera.record_enabled = true;
        verify_channel_take(
            /* cameras= */ cameras,
            /* included= */ { "test-video-0", "test-video-1", "desktop-screen", "test-audio", "desktop-audio" },
            /* excluded= */ {});

        // All-off preview remains valid, but rejecting an empty take must not reserve an output file.
        foreach (var camera in cameras)
            camera.record_enabled = false;
        var required = new List<Input> ();
        required.append(cameras.nth_data(2).audio);
        var preview = new Recorder(false, false, true);
        preview.build(cameras, required);
        assert(preview.videos.length() == 3);
        preview.close();
        var empty = new Recorder(true, false, true);
        bool rejected = false;
        try
        {
            empty.build(cameras, required);
        }
        catch (RecorderError error)
        {
            rejected = true;
        }
        assert(rejected);
        assert(empty.partial_path == null);
        empty.close();
        assert(Dir.open(directory).read_name() == null);
        Environment.set_current_dir(original);
        DirUtils.remove(directory);
    }
    catch (Error error)
    {
        Environment.set_current_dir(original);
        GLib.error("%s", error.message);
    }
}

/** Verify inclusion controls are stopped-only and survive audio-driven preview reconstruction. */
private void test_channel_transport()
{
    string original = Environment.get_current_dir();
    try
    {
        string directory = DirUtils.make_tmp("studio-channel-transport-XXXXXX");
        Environment.set_current_dir(directory);
        var app = new Application(true, true);
        int phase = 0;
        uint64 started = 0;
        assert(!app.set_record_enabled("test-video-0", false));
        uint poll = Timeout.add(
            /* interval= */ 50,
            /* function= */ () =>
            {
                if (app.transport_state == TransportState.PAUSED)
                {
                    if (phase == 0)
                    {
                        assert(!app.set_record_enabled("unknown", false));
                        assert(!app.set_record_enabled("test-video-0", true));
                        assert(app.set_record_enabled("test-video-0", false));
                        assert(app.set_record_enabled("test-video-1", false));
                        assert(app.set_record_enabled("desktop-screen", false));
                        app.play();
                        assert(app.transport_state == TransportState.PAUSED);
                        try
                        {
                            assert(Dir.open(directory).read_name() == null);
                        }
                        catch (Error error)
                        {
                            GLib.error("%s", error.message);
                        }
                        assert(app.select_audio("test-video-0", null));
                        assert(!app.set_record_enabled("test-video-0", true));
                        phase = 1;
                    }
                    else if (phase == 1)
                    {
                        assert(!app.set_record_enabled("test-video-0", false));
                        assert(app.set_record_enabled("test-video-1", true));
                        app.play();
                        assert(!app.set_record_enabled("test-video-1", false));
                        phase = 2;
                    }
                    else if (phase == 3)
                    {
                        assert(!app.set_record_enabled("test-video-0", false));
                        assert(!app.set_record_enabled("desktop-screen", false));
                        app.request_exit();
                        return Source.REMOVE;
                    }
                }
                else if (phase == 2 && app.transport_state == TransportState.RECORDING)
                {
                    assert(!app.set_record_enabled("test-video-1", false));
                    if (started == 0)
                        started = Gst.Util.get_timestamp();
                    if (Gst.Util.get_timestamp() - started > 400 * Gst.MSECOND)
                    {
                        app.stop();
                        assert(!app.set_record_enabled("test-video-1", false));
                        phase = 3;
                    }
                }
                return Source.CONTINUE;
            });
        uint watchdog = Timeout.add_seconds(
            /* interval= */ 12,
            /* function= */ () =>
            {
                GLib.error("Channel transport timed out");
            });
        assert(app.run() == 0);
        Source.remove(watchdog);
        poll = 0;
        assert(phase == 3);
        var dir = Dir.open(directory);
        string? filename;
        uint files = 0;
        while ((filename = dir.read_name()) != null)
        {
            assert(filename.has_suffix(".mkv"));
            FileUtils.unlink(filename);
            files++;
        }
        assert(files == 1);
        Environment.set_current_dir(original);
        DirUtils.remove(directory);
    }
    catch (Error error)
    {
        Environment.set_current_dir(original);
        GLib.error("%s", error.message);
    }
}

/** Verify restart persistence, stable identities, explicit silence, and unavailable-device retention. */
private void test_preferences()
{
    try
    {
        string directory = DirUtils.make_tmp("studio-preferences-XXXXXX");
        string path = Path.build_filename(directory, "preferences.ini");
        var video = new Input("Camera", "transient-video-1");
        video.preference_id = "usb-camera/video-index0";
        var audio = new Input("Microphone", "transient-audio-1");
        audio.preference_id = "alsa_input.usb-microphone";
        var camera = new Camera(video, audio);
        var sources = new List<Input>();
        sources.append(audio);
        var preferences = new Preferences(path);

        // Missing preferences leave automatic association intact.
        preferences.restore_audio(camera, sources);
        assert(camera.audio == audio);
        preferences.save_audio(camera);
        var reopened = new Preferences(path);
        var new_video = new Input("Renamed camera", "transient-video-2");
        new_video.preference_id = video.preference_id;
        var restored = new Camera(new_video);
        reopened.restore_audio(restored, sources);
        assert(restored.audio == audio);

        // A missing microphone must not silently select another one or erase the saved override.
        reopened.restore_audio(restored, new List<Input>());
        assert(restored.audio == null);
        reopened.restore_audio(restored, sources);
        assert(restored.audio == audio);
        restored.audio = null;
        reopened.save_audio(restored);
        restored.audio = audio;
        new Preferences(path).restore_audio(restored, sources);
        assert(restored.audio == null);

        // Channel groups remain independent and preserve unrelated future keys.
        var other = new Camera(new Input("Other", "other-channel"), audio);
        reopened.save_audio(other);
        var contents = new KeyFile();
        contents.load_from_file(path, KeyFileFlags.NONE);
        contents.set_boolean("channel:other-channel", "future-setting", true);
        contents.save_to_file(path);
        var extended = new Preferences(path);
        extended.save_audio(camera);
        contents.load_from_file(path, KeyFileFlags.NONE);
        assert(contents.get_boolean("channel:other-channel", "future-setting"));
        extended.restore_audio(restored, sources);
        assert(restored.audio == audio);
        other.audio = null;
        new Preferences(path).restore_audio(other, sources);
        assert(other.audio == audio);
        // Camera values share the stable video-source group and survive intervening audio writes.
        extended.save_control(video, V4L2.BASE, -12);
        extended.save_control(video, V4L2.BASE + 1, 0);
        extended.save_audio(camera);
        var after_restart = new Preferences(path);
        var values = after_restart.load_controls(new_video);
        assert(values.contains(V4L2.BASE.to_string()));
        assert(values.lookup(V4L2.BASE.to_string()) == -12);
        assert(values.contains((V4L2.BASE + 1).to_string()));
        assert(values.lookup((V4L2.BASE + 1).to_string()) == 0);
        assert(after_restart.load_controls(other.input).size() == 0);
        after_restart.restore_audio(restored, sources);
        assert(restored.audio == audio);
        // Exact fractional capture modes survive audio/control saves and routing changes.
        var selected_mode = new VideoMode(1920, 1080, 30000, 1001);
        video.video_mode = selected_mode;
        extended.save_video_mode(video);
        extended.save_audio(camera);
        extended.save_control(video, V4L2.BASE, -12);
        var current_mode = new VideoMode(640, 480, 30, 1);
        new_video.video_modes.append(current_mode);
        new_video.video_modes.append(selected_mode);
        new_video.video_mode = current_mode;
        new Preferences(path).restore_video_mode(new_video);
        assert(new_video.video_mode == selected_mode);
        assert(new_video.video_mode.numerator == 30000);
        assert(new_video.video_mode.denominator == 1001);

        // Unavailable modes and malformed fractions retain the camera's current setting.
        new_video.video_modes = new List<VideoMode>();
        new_video.video_modes.append(current_mode);
        new_video.video_mode = current_mode;
        new Preferences(path).restore_video_mode(new_video);
        assert(new_video.video_mode == current_mode);
        new_video.video_modes.append(selected_mode);
        contents.load_from_file(path, KeyFileFlags.NONE);
        contents.set_integer("channel:" + Uri.escape_string(video.preference_id, null, false), "video-rate-denominator", 0);
        contents.save_to_file(path);
        new Preferences(path).restore_video_mode(new_video);
        assert(new_video.video_mode == current_mode);

        // New channels default on; saved exclusion follows stable identity across routing changes.
        var inclusion = new Preferences(path);
        inclusion.restore_record_enabled(restored);
        assert(restored.record_enabled);
        camera.record_enabled = false;
        inclusion.save_record_enabled(camera);
        inclusion.save_audio(camera);
        inclusion.save_video_mode(video);
        inclusion.save_control(video, V4L2.BASE, -12);
        new Preferences(path).restore_record_enabled(restored);
        assert(!restored.record_enabled);
        new Preferences(path).restore_record_enabled(other);
        assert(other.record_enabled);

        // Inclusion writes preserve audio, format, camera controls, and unrelated future settings.
        contents.load_from_file(path, KeyFileFlags.NONE);
        string video_group = "channel:" + Uri.escape_string(video.preference_id, null, false);
        assert(contents.get_string(video_group, "audio-source") == audio.preference_id);
        assert(contents.get_integer(video_group, "video-width") == 1920);
        assert(contents.get_integer(video_group, "v4l2-" + V4L2.BASE.to_string()) == -12);
        assert(contents.get_boolean("channel:other-channel", "future-setting"));
        camera.record_enabled = true;
        inclusion.save_record_enabled(camera);
        new Preferences(path).restore_record_enabled(restored);
        assert(restored.record_enabled);

        // X11 and Wayland screen routes share the same saved inclusion choice.
        var x11_screen = new Camera(new Input("Screen", "desktop-screen"));
        var wayland_screen = new Camera(new Input("Screen 1", "desktop-screen-1"));
        x11_screen.record_enabled = false;
        inclusion.save_record_enabled(x11_screen);
        new Preferences(path).restore_record_enabled(wayland_screen);
        assert(!wayland_screen.record_enabled);

        // Preserve an all-off configuration rather than silently enabling a channel on restart.
        camera.record_enabled = false;
        other.record_enabled = false;
        inclusion.save_record_enabled(camera);
        inclusion.save_record_enabled(other);
        var all_off = new Preferences(path);
        restored.record_enabled = true;
        other.record_enabled = true;
        all_off.restore_record_enabled(restored);
        all_off.restore_record_enabled(other);
        all_off.restore_record_enabled(wayland_screen);
        assert(!restored.record_enabled && !other.record_enabled && !wayland_screen.record_enabled);

        // A malformed boolean is ignored, keeping a newly discovered channel enabled.
        contents.load_from_file(path, KeyFileFlags.NONE);
        contents.set_string(video_group, "record-enabled", "invalid");
        contents.save_to_file(path);
        var invalid_channel = new Camera(new_video);
        new Preferences(path).restore_record_enabled(invalid_channel);
        assert(invalid_channel.record_enabled);

        // Remove only this test's private preference file and directory.
        FileUtils.unlink(path);
        DirUtils.remove(directory);
    }
    catch (Error error)
    {
        GLib.error("%s", error.message);
    }
}

/** Verify independent layout defaults, exact geometry round trips, and preservation of channel settings. */
private void test_layout_preferences()
{
    try
    {
        string directory = DirUtils.make_tmp("studio-layout-XXXXXX");
        string path = Path.build_filename(directory, "preferences.ini");
        var preferences = new Preferences(path);
        var defaults = preferences.load_window_geometry();
        assert(defaults.width == 960 && defaults.height == 640);
        assert(defaults.controls_width == 0 && !defaults.positioned);

        // Layout and channel settings share a file without overwriting each other.
        var camera = new Camera(new Input("Camera", "layout-camera"));
        camera.record_enabled = false;
        preferences.save_record_enabled(camera);
        var layout = new WindowGeometry();
        layout.width = 1200;
        layout.height = 800;
        layout.controls_width = 280;
        layout.x = 140;
        layout.y = 80;
        layout.positioned = true;
        layout.maximized = true;
        layout.fullscreen = true;
        preferences.save_window_geometry(layout);
        preferences.save_record_enabled(camera);
        var restored = new Preferences(path).load_window_geometry();
        assert(restored.width == 1200 && restored.height == 800);
        assert(restored.controls_width == 280);
        assert(restored.positioned && restored.x == 140 && restored.y == 80);
        assert(restored.maximized && restored.fullscreen);
        camera.record_enabled = true;
        new Preferences(path).restore_record_enabled(camera);
        assert(!camera.record_enabled);

        // A session without position access preserves previously saved X11 coordinates.
        layout.positioned = false;
        preferences.save_window_geometry(layout);
        restored = new Preferences(path).load_window_geometry();
        assert(restored.positioned && restored.x == 140 && restored.y == 80);

        // Invalid dimensions and incomplete coordinates fall back independently to safe defaults.
        var contents = new KeyFile();
        contents.load_from_file(path, KeyFileFlags.NONE);
        contents.set_integer("window", "width", -1);
        contents.set_integer("window", "controls-width", int.MAX);
        contents.remove_key("window", "y");
        contents.save_to_file(path);
        restored = new Preferences(path).load_window_geometry();
        assert(restored.width == 960 && restored.height == 800);
        assert(restored.controls_width == 0 && !restored.positioned);
        FileUtils.unlink(path);
        DirUtils.remove(directory);
    }
    catch (Error error)
    {
        GLib.error("%s", error.message);
    }
}

/** Validate real-metadata slider mapping and restore ordering against a simulated V4L2 driver. */
private void test_camera_controls()
{
    try
    {
        var device = new FakeCameraControls();
        var controls = device.probe();
        assert(controls.length() == 5);
        var brightness = controls.nth_data(0);
        assert(brightness.minimum == -64);
        assert(brightness.maximum == 64);
        assert(brightness.value_at(0) == -64);
        assert(brightness.value_at(brightness.last_position()) == 64);
        assert(brightness.value_at(brightness.position_of(12)) == 12);
        assert(!brightness.accepts(13));
        assert(!brightness.accepts(128));
        assert(!controls.nth_data(2).writable());
        assert(!controls.nth_data(4).writable());
        var menu = controls.nth_data(3);
        assert(menu.choices.length == 3);
        assert(menu.value_at(0) == 1);
        assert(menu.value_at(1) == 3);
        assert(menu.value_at(2) == 7);
        assert(menu.describe(1) == "300");
        assert(!menu.accepts(2));
        assert(menu.default_value == 3);

        // Auto-mode settings restore before manual values, regardless of native ID ordering.
        var saved = new HashTable<string, int>(str_hash, str_equal);
        saved.insert(V4L2.BASE.to_string(), 12);
        saved.insert((V4L2.BASE + 1).to_string(), 0);
        saved.insert((V4L2.BASE + 2).to_string(), 20);
        saved.insert((V4L2.BASE + 3).to_string(), 3);
        saved.insert((V4L2.BASE + 4).to_string(), 24);
        saved.insert(V4L2.EXPOSURE_AUTO_PRIORITY.to_string(), 1);
        saved.insert("999", 42);
        device.restore(saved);
        assert(!device.automatic);
        assert(device.read(V4L2.BASE) == 12);
        assert(device.read(V4L2.BASE + 2) == 20);
        assert(device.read(V4L2.BASE + 3) == 3);
        assert(device.writes.length() == 4);
        assert(device.writes.nth_data(0) == (V4L2.BASE + 1).to_string());
        assert(device.writes.nth_data(1) == (V4L2.BASE + 3).to_string());

        // Stale ranges and sparse-menu holes are skipped rather than silently clamped and saved.
        saved = new HashTable<string, int>(str_hash, str_equal);
        saved.insert(V4L2.BASE.to_string(), 13);
        saved.insert((V4L2.BASE + 3).to_string(), 2);
        device.restore(saved);
        assert(device.writes.length() == 4);
        device.write(menu.id, menu.default_value);
        assert(device.read(menu.id) == menu.default_value);
        device.legacy = true;
        assert(device.probe().length() == 5);

        // Driver rejections warn and preserve the previously accepted camera value.
        device.reject_writes = true;
        saved = new HashTable<string, int>(str_hash, str_equal);
        saved.insert(V4L2.BASE.to_string(), 16);
        Test.expect_message(
            /* log_domain= */ null,
            /* log_level= */ LogLevelFlags.LEVEL_WARNING,
            /* pattern= */ "*Test control: Simulated driver rejection*");
        device.restore(saved);
        Test.assert_expected_messages();
        assert(device.read(V4L2.BASE) == 12);

        // The native backend fails gracefully for an invalid device instead of fabricating controls.
        var unavailable = new CameraControls.borrowed(-1);
        assert(unavailable.probe().length() == 0);
        bool failed = false;
        try
        {
            unavailable.read(V4L2.BASE);
        }
        catch (Error error)
        {
            failed = true;
        }
        assert(failed);
    }
    catch (Error error)
    {
        GLib.error("%s", error.message);
    }
}

/** Verify screen scaling choices and exact fractional caps without capture hardware. */
private void test_video_modes()
{
    var screen = new Input("Screen", "desktop-screen");
    screen.width = 3840;
    screen.height = 2160;
    VideoMode.probe(screen);
    assert(screen.video_modes.length() == 21);
    assert(screen.video_modes.nth_data(0).width == 3840);
    assert(screen.video_modes.nth_data(7).width == 1920);
    assert(screen.video_modes.nth_data(14).height == 540);
    VideoMode.probe(screen);
    assert(screen.video_modes.length() == 21);
    var mode = new VideoMode(1920, 1080, 30000, 1001);
    var caps = Gst.Caps.from_string(mode.caps());
    int numerator, denominator;
    assert(caps.get_structure(0).get_fraction("framerate", out numerator, out denominator));
    assert(numerator == 30000 && denominator == 1001);
}

/** Verify a constrained native source survives metering and Matroska muxing without PCM conversion. */
private void verify_native_audio(string caps, string codec, int rate, int channels)
{
    string original = Environment.get_current_dir();
    try
    {
        string directory = DirUtils.make_tmp("studio-native-audio-XXXXXX");
        Environment.set_current_dir(directory);
        var audio = test_input("Native microphone", "native-audio", false, 0);
        audio.test_audio_caps = caps;
        var cameras = new List<Camera>();
        cameras.append(new Camera(test_input("Camera", "native-video", true, 0), audio));
        var recorder = new Recorder(true, false, true);
        recorder.build(cameras, new List<Input>());

        // Record actual native buffers while checking that the independent meter remains active.
        var loop = new MainLoop();
        var bus = recorder.pipeline.get_bus();
        bus.add_signal_watch();
        bool finalized = false;
        int levels = 0;
        ulong handler = bus.message.connect(
            /* handler= */ (message) =>
            {
                if (message.type == Gst.MessageType.ERROR)
                    GLib.error("%s", recorder.describe_error(message));
                if (message.type == Gst.MessageType.ELEMENT && message.get_structure().get_name() == "level")
                    levels++;
                if (message.type == Gst.MessageType.EOS)
                {
                    finalized = true;
                    loop.quit();
                }
            });
        recorder.start();
        Timeout.add(
            /* interval= */ 400,
            /* function= */ () =>
            {
                assert(recorder.stop());
                return Source.REMOVE;
            });
        uint watchdog = Timeout.add_seconds(
            /* interval= */ 12,
            /* function= */ () =>
            {
                GLib.error("Native audio recording timed out");
            });
        loop.run();
        Source.remove(watchdog);
        assert(finalized && levels > 0);
        string negotiated_audio = recorder.audio_summary(audio);
        assert(negotiated_audio.contains(rate.to_string() + " Hz"));
        assert(negotiated_audio.contains(channels.to_string() + " channels"));
        assert(negotiated_audio.contains(codec == "pcm_f32le" ? "F32LE" : codec == "pcm_s24le" ? "S24LE" : codec == "pcm_s32le" ? "S32LE" : "S16LE"));
        bus.disconnect(handler);
        bus.remove_signal_watch();
        recorder.close(true);

        // Container metadata must retain the exact input format, sample rate, and channel count.
        string output;
        int result;
        Process.spawn_sync(
            /* working_directory= */ null,
            /* argv= */ new string[] { "ffprobe", "-v", "error", "-select_streams", "a", "-show_entries",
                                       "stream=codec_name,sample_rate,channels", "-of", "compact", recorder.final_path },
            /* envp= */ null,
            /* _flags= */ SpawnFlags.SEARCH_PATH,
            /* child_setup= */ null,
            /* standard_output= */ out output,
            /* standard_error= */ null,
            /* wait_status= */ out result);
        assert(result == 0);
        assert(output.contains("codec_name=" + codec));
        assert(output.contains("sample_rate=" + rate.to_string()));
        assert(output.contains("channels=" + channels.to_string()));

        // Decode every native audio track as well, catching malformed PCM payloads and mux metadata.
        Process.spawn_sync(
            /* working_directory= */ null,
            /* argv= */ new string[] { "ffmpeg", "-v", "error", "-xerror", "-i", recorder.final_path,
                                       "-map", "0:a", "-f", "null", "-" },
            /* envp= */ null,
            /* _flags= */ SpawnFlags.SEARCH_PATH,
            /* child_setup= */ null,
            /* standard_output= */ null,
            /* standard_error= */ null,
            /* wait_status= */ out result);
        assert(result == 0);
        FileUtils.unlink(recorder.final_path);
        Environment.set_current_dir(original);
        DirUtils.remove(directory);
    }
    catch (Error error)
    {
        Environment.set_current_dir(original);
        GLib.error("%s", error.message);
    }
}

/** Cover integer fallback, packed 24-bit metering, native rates/channels, and preferred float32. */
private void test_native_audio()
{
    verify_native_audio("audio/x-raw,format=S16LE,layout=interleaved,rate=44100,channels=1", "pcm_s16le", 44100, 1);
    verify_native_audio("audio/x-raw,format=S24LE,layout=interleaved,rate=96000,channels=2", "pcm_s24le", 96000, 2);
    verify_native_audio("audio/x-raw,format=S32LE,layout=interleaved,rate=48000,channels=4", "pcm_s32le", 48000, 4);
    verify_native_audio("audio/x-raw,format=F32LE,layout=interleaved,rate=88200,channels=2", "pcm_f32le", 88200, 2);
    verify_native_audio("audio/x-raw,format=(string){S16LE,F32LE},layout=interleaved,rate=44100,channels=2", "pcm_f32le", 44100, 2);

    // A hardware format that Matroska cannot represent must not be silently transcoded.
    bool rejected = false;
    try
    {
        AudioFormat.capture_caps(Gst.Caps.from_string("audio/x-raw,format=S24_32LE,layout=interleaved,rate=48000,channels=2"));
    }
    catch (Error error)
    {
        rejected = true;
    }
    assert(rejected);
}

/** Verify provider mapping, native-only discovery, backend preference migration, and raw source selection. */
private void test_alsa_discovery()
{
    try
    {
        var properties = new Gst.Structure.empty("properties");
        properties.set("api.alsa.pcm.card", typeof(string), "9999", "api.alsa.pcm.device", typeof(int), 2);
        assert(AlsaDevices.hardware(properties) == "hw:9999,2");
        var source = new Input("Microphone", "microphone");
        source.alsa_device = "hw:9999,2";
        source.audio_name = "must-not-use-sound-server";
        var element = source.create_element();
        assert(element.get_factory().get_name() == "alsasrc");
        string device;
        element.get("device", out device);
        assert(device == "hw:9999,2");

        // Parse capture endpoints without offering playback-only PCMs as microphones.
        var inputs = AlsaDevices.parse("99-00: Mic : Native : capture 1\n99-01: Playback : Output : playback 1\n99-02: Duplex : Native : playback 1 : capture 1");
        assert(inputs.length() == 2);
        assert(inputs.nth_data(0).alsa_device == "hw:99,0");
        assert(inputs.nth_data(1).alsa_device == "hw:99,2");
        var fallback = new Gst.Structure.empty("properties");
        fallback.set("api.alsa.path", typeof(string), "hw:9999,3");
        assert(AlsaDevices.hardware(fallback) == "hw:9999,3");
        fallback.set("api.alsa.path", typeof(string), "plughw:9999,3");
        assert(AlsaDevices.hardware(fallback) == null);

        // Audio assignments saved under provider identities still resolve after switching to ALSA.
        string directory = DirUtils.make_tmp("studio-alsa-preferences-XXXXXX");
        string path = Path.build_filename(directory, "preferences.ini");
        var old = new Input("Old", "old-backend");
        var camera = new Camera(new Input("Camera", "alsa-video"), old);
        var preferences = new Preferences(path);
        preferences.save_audio(camera);
        source.preference_id = "alsa:card:2";
        source.add_preference_alias("old-backend");
        var sources = new List<Input>();
        sources.append(source);
        new Preferences(path).restore_audio(camera, sources);
        assert(camera.audio == source);

        // A subsequent launch can resolve the migrated choice without the old provider profile.
        source.preference_aliases = {};
        camera.audio = null;
        new Preferences(path).restore_audio(camera, sources);
        assert(camera.audio == source);
        FileUtils.unlink(path);
        DirUtils.remove(directory);
    }
    catch (Error error)
    {
        GLib.error("%s", error.message);
    }
}

/** Register and run the Vala unit and synthetic recording integration checks. */
int main(string[] args)
{
    Test.init(ref args);
    Gst.init(ref args);
    Test.add_func("/studio/camera-framerate-callback", test_camera_framerate_callback);
    Test.add_func("/studio/camera-controls", test_camera_controls);
    Test.add_func("/studio/video-modes", test_video_modes);
    Test.add_func("/studio/preferences", test_preferences);
    Test.add_func("/studio/recording-output", test_recording_output);
    Test.add_func("/studio/native-audio", test_native_audio);
    Test.add_func("/studio/alsa-discovery", test_alsa_discovery);
    Test.add_func("/studio/layout-preferences", test_layout_preferences);
    Test.add_func("/studio/level-rms", test_level_rms);
    Test.add_func("/studio/rolling-framerate", test_rates);
    Test.add_func("/studio/primary-monitor", test_geometry);
    Test.add_func("/studio/encoded-framerate", test_encoded_rate);
    Test.add_func("/studio/transport-and-audio", test_transport);
    Test.add_func("/studio/channel-recording", test_channel_recording);
    Test.add_func("/studio/channel-transport", test_channel_transport);
    return Test.run();
}
