namespace Studio
{
    public errordomain RecorderError
    {
        FAILED
    }

    /** Create a required GStreamer element, reporting a missing plugin as an application error. */
    public Gst.Element make(string factory) throws Error
    {
        var element = Gst.ElementFactory.make(factory, null);
        if (element == null)
            throw new RecorderError.FAILED("Missing GStreamer element: %s", factory);
        return element;
    }

    public class Input : GLib.Object
    {
        public string name
        {
            get;
            construct;
        }
        public string identity
        {
            get;
            construct;
        }
        public string? physical_id
        {
            get;
            set;
        }
        public Gst.Device? device
        {
            get;
            set;
        }
        public string? video_path
        {
            get;
            set;
        }
        public string? audio_name
        {
            get;
            set;
        }
        public string? factory
        {
            get;
            set;
        }
        public int pattern
        {
            get;
            set;
            default = 0;
        }
        public int remote_fd
        {
            get;
            set;
            default = -1;
        }
        public string? remote_target
        {
            get;
            set;
        }
        public string? remote_path
        {
            get;
            set;
        }
        public uint x
        {
            get;
            set;
        }
        public uint y
        {
            get;
            set;
        }
        public uint width
        {
            get;
            set;
        }
        public uint height
        {
            get;
            set;
        }

        /** Describe a capture input using its display name and process-local routing identity. */
        public Input (string name, string identity)
        {
            Object(name: name, identity: identity);
        }

        /** Open this input through its explicit capture backend or provider-created source. */
        public Gst.Element create_element() throws Error
        {
            Gst.Element source;

            // Prefer stable device paths and PulseAudio node names over provider numeric targets.
            if (video_path != null)
            {
                source = make("v4l2src");
                source.set("device", video_path);
                Native.lock_framerate(source);
            }
            else if (audio_name != null)
            {
                source = make("pulsesrc");
                source.set("device", audio_name);
            }
            // Desktop and synthetic inputs carry explicit native element configuration.
            else if (factory != null)
            {
                source = make(factory);
                switch (factory)
                {
                    case "videotestsrc":
                        source.set("is-live", true, "pattern", pattern);
                        break;
                    case "audiotestsrc":
                        source.set("is-live", true, "freq", 440.0 + pattern * 220.0);
                        break;
                    case "ximagesrc":
                        source.set(
                            /* first_property_name= */ "use-damage",
                            /* use_damage= */ false,
                            /* property_name= */ "show-pointer",
                            /* show_pointer= */ true,
                            /* property_name= */ "startx",
                            /* startx= */ x,
                            /* property_name= */ "starty",
                            /* starty= */ y,
                            /* property_name= */ "endx",
                            /* endx= */ x + width - 1,
                            /* property_name= */ "endy",
                            /* endy= */ y + height - 1);
                        break;
                    case "pipewiresrc":
                        source.set("fd", remote_fd);
                        if (remote_target != null)
                            source.set("target-object", remote_target);
                        else
                            source.set("path", remote_path);
                        break;
                }
            }
            else
            {
                var created = device != null ? device.create_element(null) : null;
                if (created == null)
                    throw new RecorderError.FAILED("Cannot create capture source: %s", name);
                source = created;
            }
            return source;
        }
    }

    public class Camera : GLib.Object
    {
        public Input input
        {
            get;
            construct;
        }
        public Input? audio
        {
            get;
            set;
        }

        /** Associate a video input with the audio selection used for metering and future takes. */
        public Camera (Input input, Input? audio = null)
        {
            Object(input: input, audio: audio);
        }
    }

    public class Registry : GLib.Object
    {
        private Gst.DeviceProvider? provider;
        public List<Input> audio_sources = new List<Input> ();

        /** Read optional provider metadata as text, including numeric values stored in a GValue. */
        private static string? field(Gst.Structure? props, string key)
        {
            if (props == null)
                return null;
            unowned Value? value = props.get_value(key);
            if (value == null)
                return null;
            if (value.holds(typeof (string)))
                return value.get_string();
            return Gst.Value.serialize(value);
        }

        /** Accept only physical V4L2 device paths from the supported provider metadata fields. */
        private static string? video_path(Gst.Structure? props)
        {
            foreach (string key in new string[] { "api.v4l2.path", "device.path", "object.path" })
            {
                string path = field(props, key) ?? "";
                if (path.has_prefix("v4l2:"))
                    path = path.substring(5);
                if (Regex.match_simple("^/dev/video[0-9]+$", path))
                    return path;
            }
            return null;
        }

        /** Resolve sysfs links and find the USB device shared by its video and audio interfaces. */
        private static string? usb_parent(string path)
        {
            string? current = Native.realpath(path);
            while (current != null && current != "/")
            {
                if (FileUtils.test(Path.build_filename(current, "idVendor"), FileTest.EXISTS) &&
                    FileUtils.test(Path.build_filename(current, "idProduct"), FileTest.EXISTS))
                    return current;
                current = Path.get_dirname(current);
            }
            return null;
        }

        /** Prefer shared sysfs ancestry, falling back to kernel USB identities advertised by PipeWire. */
        private static string? physical_id(Gst.Structure? props, string? video)
        {
            string? physical = null;
            if (video != null)
                physical = usb_parent("/sys/class/video4linux/%s/device".printf(Path.get_basename(video)));

            // Audio and video interfaces must resolve to the same physical USB device.
            string? card = field(props, "api.alsa.pcm.card") ?? field(props, "alsa.card");
            if (physical == null && card != null)
                physical = usb_parent("/sys/class/sound/card%s/device".printf(card));
            if (physical != null)
                return physical;

            // Some providers expose USB identity only through metadata, without usable sysfs paths.
            string? bus = field(props, "api.v4l2.cap.bus_info");
            if (bus != null && bus.has_prefix("usb-"))
                return bus;
            try
            {
                var expression = new Regex(" at (usb-[^, ]+)");
                MatchInfo match;
                if (expression.match(field(props, "alsa.long_card_name") ?? "", 0, out match))
                    return match.fetch(1);
            }
            catch (RegexError error)
            {
                assert_not_reached();
            }
            return null;
        }

        /** Enumerate PipeWire inputs and assign microphones only when physical identity matches uniquely. */
        public List<Camera> discover() throws Error
        {
            provider = Gst.DeviceProviderFactory.get_by_name("pipewiredeviceprovider");
            if (provider == null || !provider.start())
                throw new RecorderError.FAILED("PipeWire discovery unavailable. Check the service and GStreamer plugin.");

            // Enumerate one backend and suppress duplicate inputs and output-monitor sources.
            var videos = new List<Input> ();
            var seen = new HashTable<string, bool> (str_hash, str_equal);
            foreach (var device in provider.get_devices())
            {
                string kind = device.get_device_class();
                if (kind != "Video/Source" && kind != "Audio/Source")
                    continue;
                var props = device.get_properties();
                string node = field(props, "node.name") ?? "";
                if (field(props, "device.class") == "monitor" || node.has_suffix(".monitor"))
                    continue;
                string identity = field(props, "object.path") ?? field(props, "node.name") ?? device.get_display_name();
                if (seen.contains(kind + identity))
                    continue;
                seen.insert(kind + identity, true);

                // Retain routing metadata so later pipeline rebuilds reopen the same source.
                var input = new Input(device.get_display_name(), identity);
                input.device = device;
                if (kind == "Video/Source")
                    input.video_path = video_path(props);
                else
                    input.audio_name = node.length > 0 ? node : null;
                input.physical_id = physical_id(props, input.video_path);
                if (kind == "Video/Source")
                    videos.append(input);
                else
                    audio_sources.append(input);
            }

            // Sort the UI choices, then associate only unambiguous physical matches.
            audio_sources.sort((a, b) => strcmp(a.name + a.identity, b.name + b.identity));
            videos.sort((a, b) => strcmp(a.identity, b.identity));
            var cameras = new List<Camera> ();
            foreach (var video in videos)
            {
                Input? selected = null;
                int matches = 0;
                foreach (var audio in audio_sources)
                {
                    if (video.physical_id != null && video.physical_id == audio.physical_id)
                    {
                        selected = audio;
                        matches++;
                    }
                }
                cameras.append(new Camera(video, matches == 1 ? selected : null));
            }
            return cameras;
        }

        /** Release the discovery provider after its worker has finished using it. */
        public void stop()
        {
            if (provider != null)
            {
                provider.stop();
                provider = null;
            }
        }
    }

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
