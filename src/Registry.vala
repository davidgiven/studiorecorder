/** Owns PipeWire device discovery and matches camera microphones conservatively by physical USB identity. */
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
        string? current = Posix.realpath(path);
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

    /** Prefer persistent V4L2 links, then backend node names, over transient routing identities. */
    private static string preference_identity(Input input, string node)
    {
        if (input.video_path != null)
        {
            foreach (string directory in new string[] { "/dev/v4l/by-id", "/dev/v4l/by-path" })
            {
                try
                {
                    var links = Dir.open(directory);
                    string? name;
                    string? selected = null;
                    while ((name = links.read_name()) != null)
                    {
                        string path = Path.build_filename(directory, name);
                        if (Posix.realpath(path) == Posix.realpath(input.video_path) &&
                            (selected == null || strcmp(path, selected) < 0))
                            selected = path;
                    }
                    if (selected != null)
                        return selected;
                }
                catch (FileError error)
                {
                    // A backend without persistent links can still expose a stable node name.
                }
            }
        }
        return node.length > 0 ? node : input.identity;
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
            input.preference_id = preference_identity(input, node);
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
