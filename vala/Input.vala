namespace Studio
{
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
}
