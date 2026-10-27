/** Owns one preview or recording pipeline, including native media branches, mux pads, and safe take publication. */
public class Recorder : GLib.Object
{
    public Gst.Pipeline pipeline
    {
        get;
        private set;
    }
    public bool recording
    {
        get;
        private set;
    }
    public bool started
    {
        get;
        private set;
    }
    public string? final_path
    {
        get;
        private set;
    }
    public string? partial_path
    {
        get;
        private set;
    }
    public List<VideoTrack> videos = new List<VideoTrack> ();
    public HashTable<string, string> level_sources = new HashTable<string, string> (str_hash, str_equal);
    private HashTable<string, string> labels = new HashTable<string, string> (str_hash, str_equal);
    private Gst.Element? mux;
    private List<Gst.Pad> requested_pads = new List<Gst.Pad> ();
    private bool closed;
    private bool preview;
    private bool synthetic;
    private string? encoder;

    /** Create an unbuilt pipeline for either live preview or one independently finalized take. */
    public Recorder (bool recording, bool preview, bool synthetic)
    {
        this.recording = recording;
        this.preview = preview;
        this.synthetic = synthetic;
        pipeline = new Gst.Pipeline("studio-recorder");
    }

    /** Select an installed hardware H.264 encoder; allow software encoding only for synthetic inputs. */
    private static string choose_encoder(bool synthetic) throws Error
    {
        if (synthetic)
            return "x264enc";
        foreach (string factory in new string[] { "vah264enc", "vah264lpenc", "nvh264enc", "nvautogpuh264enc",
                                                  "qsvh264enc", "vaapih264enc", "v4l2h264enc" })
            if (Gst.ElementFactory.find(factory) != null)
                return factory;
        throw new RecorderError.FAILED("No hardware H.264 encoder available. Install the GStreamer plugin and GPU driver.");
    }

    /** Create a caps filter that constrains native GStreamer format negotiation. */
    private Gst.Element filter(string specification) throws Error
    {
        var element = make("capsfilter");
        element.set("caps", Gst.Caps.from_string(specification));
        return element;
    }

    /** Bound buffering by time, dropping stale preview frames while recording applies backpressure. */
    private Gst.Element queue(bool leaky = false) throws Error
    {
        var element = make("queue");
        element.set(
            /* first_property_name= */ "max-size-time",
            /* max_size_time= */ (uint64) (leaky ? 200 * Gst.MSECOND : 2 * Gst.SECOND),
            /* property_name= */ "max-size-buffers",
            /* max_size_buffers= */ (uint) 0,
            /* property_name= */ "max-size-bytes",
            /* max_size_bytes= */ (uint) 0,
            /* property_name= */ "leaky",
            /* leaky= */ leaky ? 2 : 0);
        return element;
    }

    /** Serialize source identification as stream tags for a native taginject element. */
    private Gst.Element tags(string title, string comment) throws Error
    {
        var list = new Gst.TagList.empty();
        list.set_scope(Gst.TagScope.STREAM);
        list.add_value(Gst.TagMergeMode.REPLACE, Gst.Tags.TITLE, title);
        list.add_value(Gst.TagMergeMode.REPLACE, Gst.Tags.COMMENT, comment);

        // taginject adds its own taglist prefix; retain GStreamer escaping for tag values.
        string serialized = list.to_string();
        var element = make("taginject");
        element.set("tags", serialized.substring(serialized.index_of(",") + 1).strip());
        return element;
    }

    /** Add elements to the pipeline and link adjacent elements, failing on any broken connection. */
    private void chain(Gst.Element[] elements) throws Error
    {
        foreach (var element in elements)
        {
            if (!pipeline.add(element))
                throw new RecorderError.FAILED("Cannot add %s", element.name);
        }

        // Link only after all elements have joined the same pipeline.
        for (int i = 1; i < elements.length; i++)
        {
            if (!elements[i - 1].link(elements[i]))
                throw new RecorderError.FAILED("Cannot link %s to %s", elements[i - 1].name, elements[i].name);
        }
    }

    /** Request and retain a distinct Matroska pad for one video or audio track. */
    private void mux_track(Gst.Element tail, string kind) throws Error
    {
        var pad = mux.request_pad_simple(kind + "_%u");
        if (pad == null)
            throw new RecorderError.FAILED("Cannot request %s mux pad", kind);
        requested_pads.append(pad);
        if (tail.get_static_pad("src").link(pad) != Gst.PadLinkReturn.OK)
            throw new RecorderError.FAILED("Cannot attach %s track", kind);
    }

    /** Keep all previews live while recording enabled video channels and their deduplicated audio. */
    public void build(List<Camera> cameras, List<Input> required_audio) throws Error
    {
        if (cameras.length() == 0)
            throw new RecorderError.FAILED("No video inputs.");
        if (preview && Gst.ElementFactory.find("gtk4paintablesink") == null)
            throw new RecorderError.FAILED("Missing gtk4paintablesink (install gst-plugin-gtk4).");

        // Screen inclusion also controls its independent computer-audio track.
        bool screen_enabled = false;
        bool any_channel_enabled = false;
        foreach (var camera in cameras)
        {
            if (!camera.record_enabled)
                continue;
            any_channel_enabled = true;
            if (camera.input.identity.has_prefix("desktop-screen"))
                screen_enabled = true;
        }
        if (recording && !any_channel_enabled)
            throw new RecorderError.FAILED("Enable at least one channel before recording.");

        // Only a take allocates a writer and encoders; paused preview creates no output.
        if (recording)
        {
            encoder = choose_encoder(synthetic);
            string stamp = new DateTime.now_local().format("%Y-%m-%d_%H-%M-%S_%f%z");
            final_path = Path.build_filename(
                /* first_element= */ Environment.get_current_dir(),
                /* path_component= */ "StudioRecorder_%s_%s.mkv".printf(stamp, Uuid.string_random()));
            partial_path = final_path + ".partial";
            // Exclusive reservation; never truncate a pre-existing take.
            var reserved = File.new_for_path(partial_path).create(FileCreateFlags.NONE);
            reserved.close();
            mux = make("matroskamux");
            mux.set("writing-app", "StudioRecorder (Vala)", "offset-to-zero", true);
            var sink = make("filesink");
            sink.set("location", partial_path, "sync", false);
            chain({ mux, sink });
        }

        // Keep all meters live, but record independent computer audio only when Screen is enabled.
        var audio = new HashTable<string, Input> (str_hash, str_equal);
        var recorded_audio = new HashTable<string, bool> (str_hash, str_equal);
        foreach (var input in required_audio)
        {
            audio.insert(input.identity, input);
            if (input.identity != "desktop-audio" || screen_enabled)
                recorded_audio.insert(input.identity, true);
        }
        foreach (var camera in cameras)
        {
            add_video(camera);
            if (camera.audio != null)
            {
                audio.insert(camera.audio.identity, camera.audio);
                if (camera.record_enabled)
                    recorded_audio.insert(camera.audio.identity, true);
            }
        }

        // Disabled channels keep live meters but only enabled associations appear in recording metadata.
        foreach (var input in audio.get_values())
        {
            string[] associated = {};
            foreach (var camera in cameras)
                if ((!recording || camera.record_enabled) && camera.audio != null && camera.audio.identity == input.identity)
                    associated += camera.input.name;
            add_audio(input, string.joinv(", ", associated), recording && recorded_audio.contains(input.identity));
        }
    }

    /** Split decoded video into native preview and optional hardware-encoded recording branches. */
    private void add_video(Camera camera) throws Error
    {
        var source = camera.input.create_element();
        var decoder = make("decodebin");
        string label = "Video input '%s' [%s]".printf(camera.input.name, camera.input.identity);
        labels.insert(source.name, label);
        labels.insert(decoder.name, label);

        // Constrain portal sources to video before decodebin, which otherwise also accepts audio.
        var tee = make("tee");
        if (source.get_factory().get_name() == "pipewiresrc")
            chain({ source, filter("video/x-raw"), decoder });
        else
            chain({ source, decoder });
        pipeline.add(tee);
        var track = new VideoTrack(camera, tee.get_static_pad("sink"));
        videos.append(track);

        // Decoded pads arrive asynchronously; only raw video can feed the video tee.
        // Capture only the pad and a weak pipeline, avoiding a pipeline/closure cycle.
        Gst.Pad target = tee.get_static_pad("sink");
        weak Gst.Pipeline weak_pipeline = pipeline;
        decoder.pad_added.connect(
            /* handler= */ (pad) =>
            {
                var current = pad.get_current_caps() ?? pad.query_caps(null);
                if (current != null && current.to_string().has_prefix("video/x-raw") && !target.is_linked())
                {
                    if (pad.link(target) != Gst.PadLinkReturn.OK && weak_pipeline != null)
                    {
                        var detail = new Gst.Structure.empty("studio-recorder-error");
                        detail.set("message", typeof (string), "Cannot link decoded video: " + label);
                        weak_pipeline.post_message(new Gst.Message.application(weak_pipeline, (owned) detail));
                    }
                }
            });
        if (recording && camera.record_enabled)
        {
            var input_queue = queue();
            var encode = make(encoder);
            if (synthetic)
            {
                Gst.Util.set_object_arg(encode, "tune", "zerolatency");
                Gst.Util.set_object_arg(encode, "speed-preset", "ultrafast");
            }
            else if (encode.get_class().find_property("bitrate") != null)
                encode.set("bitrate", (uint) 8000);

            // AU alignment after h264parse makes one native counter increment represent one frame.
            var counter = make("identity");
            counter.set("silent", true, "signal-handoffs", false);
            var output_queue = queue();
            chain(
                /* elements= */ { input_queue, make("videoconvert"), make("videoscale"),
                                  filter(synthetic ? "video/x-raw,format=I420" : "video/x-raw,format=NV12"), encode,
                                  make("h264parse"), filter("video/x-h264,stream-format=avc,alignment=au"),
                                  tags(
                                      /* title= */ camera.input.name,
                                      /* comment= */ "Video source: %s; audio: %s".printf(
                                          /* source_identity= */ camera.input.identity,
                                          /* audio_name= */ camera.audio != null ? camera.audio.name : "none")), counter, output_queue });
            if (!tee.link(input_queue))
                throw new RecorderError.FAILED("Cannot attach recording branch.");
            track.counter = counter;
            mux_track(output_queue, "video");
        }

        // Preview queues may discard stale frames without changing the recording counters.
        if (preview)
        {
            var preview_queue = queue(true);
            var sink = make("gtk4paintablesink");
            sink.set("sync", false, "async", false);
            chain({ preview_queue, make("videoconvert"), sink });
            if (!tee.link(preview_queue))
                throw new RecorderError.FAILED("Cannot attach preview.");
            Gdk.Paintable paintable;
            sink.get("paintable", out paintable);
            track.paintable = paintable;
        }
        else if (!recording || !camera.record_enabled)
        {
            var preview_queue = queue(true);
            var sink = make("fakesink");
            sink.set("sync", false, "async", false);
            chain({ preview_queue, sink });
            if (!tee.link(preview_queue))
                throw new RecorderError.FAILED("Cannot attach headless preview.");
        }
    }

    /** Convert one unique input to 48 kHz float32 PCM without restricting its channel count. */
    private void add_audio(Input input, string associated, bool record_audio) throws Error
    {
        var source = input.create_element();
        labels.insert(source.name, "Audio input '%s' [%s]".printf(input.name, input.identity));

        // Use the same converted audio path for metering and recording, preserving channel count.
        var meter = make("level");
        meter.set("interval", (uint64) (50 * Gst.MSECOND), "post-messages", true);
        var output_queue = queue();
        chain(
            /* elements= */ { source, make("audioconvert"), make("audioresample"),
                              filter("audio/x-raw,format=F32LE,layout=interleaved,rate=48000"), meter,
                              tags(input.name, "Audio source: %s; cameras: %s".printf(input.identity, associated)), output_queue });
        level_sources.insert(meter.name, input.identity);

        // Disabled and paused audio end after metering; only selected recording inputs reach the muxer.
        if (record_audio)
            mux_track(output_queue, "audio");
        else
        {
            var sink = make("fakesink");
            sink.set("sync", false, "async", false);
            pipeline.add(sink);
            if (!output_queue.link(sink))
                throw new RecorderError.FAILED("Cannot attach audio preview.");
        }
    }

    /** Add capture-source identity and GStreamer debug details to a pipeline error. */
    public string describe_error(Gst.Message message)
    {
        Error error;
        string? debug;
        message.parse_error(out error, out debug);
        string detail = "%s: %s".printf(message.src.get_path_string(), error.message);

        // Walk element ancestry to attach the human-readable source label to nested failures.
        Gst.Object? source = message.src;
        while (source != null)
        {
            string? label = labels.lookup(source.name);
            if (label != null)
            {
                detail = label + "\n" + detail;
                break;
            }
            source = source.get_parent();
        }
        if (debug != null)
            detail += "\n" + debug;
        return detail;
    }

    /** Start capture and preserve synchronous startup diagnostics before pipeline cleanup flushes them. */
    public void start() throws Error
    {
        started = pipeline.set_state(Gst.State.PLAYING) != Gst.StateChangeReturn.FAILURE;

        // Drain startup errors before setting NULL can flush the bus.
        if (!started)
        {
            string detail = "";
            Gst.Message? message;
            while ((message = pipeline.get_bus().pop_filtered(Gst.MessageType.ERROR)) != null)
                detail += describe_error(message) + "\n";
            throw new RecorderError.FAILED("%s could not start: %s", recording ? "Recording" : "Live preview", detail);
        }
    }

    /** Send EOS through all branches so the shared muxer can drain and finalize the take. */
    public bool stop()
    {
        return pipeline.send_event(new Gst.Event.eos());
    }

    /** Release pipeline resources and publish only finalized takes without replacing existing files. */
    public void close(bool finalized = false) throws Error
    {
        if (closed)
            return;
        closed = true;
        pipeline.set_state(Gst.State.NULL);
        foreach (var pad in requested_pads)
            mux.release_request_pad(pad);
        requested_pads = new List<Gst.Pad> ();

        // A hard link publishes the final name atomically without overwriting an existing file.
        if (finalized && recording && partial_path != null)
        {
            if (Posix.link(partial_path, final_path) != 0)
                throw new RecorderError.FAILED("Cannot publish take: %s", strerror(errno));
            if (Posix.unlink(partial_path) != 0)
                throw new RecorderError.FAILED("Take saved, but cannot remove partial name: %s", strerror(errno));
        }
    }
}
