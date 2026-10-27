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
        Environment.set_current_dir(directory);

        // Construct a real recording pipeline with synthetic inputs and no rendering branch.
        var inputs = test_cameras();
        var required = new List<Input> ();
        required.append(inputs.nth_data(2).audio);
        var recorder = new Recorder(true, false, true);
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
    Test.add_func("/studio/preferences", test_preferences);
    Test.add_func("/studio/level-rms", test_level_rms);
    Test.add_func("/studio/rolling-framerate", test_rates);
    Test.add_func("/studio/primary-monitor", test_geometry);
    Test.add_func("/studio/encoded-framerate", test_encoded_rate);
    Test.add_func("/studio/transport-and-audio", test_transport);
    Test.add_func("/studio/channel-recording", test_channel_recording);
    Test.add_func("/studio/channel-transport", test_channel_transport);
    return Test.run();
}
