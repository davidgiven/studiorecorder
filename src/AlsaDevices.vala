/** Maps discovered microphones to raw ALSA hardware devices without conversion plugins. */
public class AlsaDevices : Object
{
    /** Read optional integer metadata whether the provider stores it as a number or string. */
    private static string? field(Gst.Structure? properties, string name)
    {
        if (properties == null)
            return null;
        unowned Value? value = properties.get_value(name);
        if (value == null)
            return null;
        return value.holds(typeof(string)) ? value.get_string() : Gst.Value.serialize(value);
    }

    /** Resolve a provider's exact capture PCM, avoiding default/plughw software conversion paths. */
    public static string? hardware(Gst.Structure? properties)
    {
        string? card = field(properties, "api.alsa.pcm.card") ?? field(properties, "alsa.card") ?? field(properties, "api.alsa.card");
        string? device = field(properties, "api.alsa.pcm.device") ?? field(properties, "alsa.device");
        int card_number = -1, device_number = -1;
        if (card != null && device != null && int.try_parse(card, out card_number) &&
            int.try_parse(device, out device_number) && card_number >= 0 && device_number >= 0)
            return "hw:%d,%d".printf(card_number, device_number);

        // Accept only explicit numeric hardware paths when individual PCM metadata is absent.
        string path = field(properties, "api.alsa.path") ?? "";
        try
        {
            MatchInfo match;
            if (new Regex("^hw:([0-9]+)(?:,([0-9]+))?$").match(path, 0, out match))
                return "hw:%d,%d".printf(int.parse(match.fetch(1)), match.fetch(2).length > 0 ? int.parse(match.fetch(2)) : 0);
        }
        catch (RegexError error)
        {
            assert_not_reached();
        }
        return null;
    }

    /** Prefer the ALSA card identifier for settings while retaining numeric routing for this discovery. */
    public static string identity(string hardware)
    {
        string[] parts = hardware.substring(3).split(",");
        string card = parts[0];
        try
        {
            string name;
            FileUtils.get_contents("/proc/asound/card%s/id".printf(card), out name);
            card = name.strip();
        }
        catch (FileError error)
        {
            // Numeric identity remains usable when the kernel does not expose a card identifier.
        }
        return "alsa:%s:%s".printf(card, parts[1]);
    }

    /** Parse kernel capture entries, including devices omitted by the sound server's current profile. */
    public static List<Input> parse(string devices)
    {
        var inputs = new List<Input>();
        try
        {
            var expression = new Regex("^([0-9]+)-([0-9]+): ([^:]+) :.*\\bcapture [1-9][0-9]*\\b");
            foreach (string line in devices.split("\n"))
            {
                MatchInfo match;
                if (!expression.match(line, 0, out match))
                    continue;
                string card = int.parse(match.fetch(1)).to_string();
                string device = int.parse(match.fetch(2)).to_string();
                string hardware = "hw:%s,%s".printf(card, device);
                var input = new Input("%s (%s)".printf(match.fetch(3).strip(), hardware), identity(hardware));
                input.alsa_device = hardware;
                input.preference_id = input.identity;
                input.physical_id = Registry.usb_parent("/sys/class/sound/card%s/device".printf(card));
                inputs.append(input);
            }
        }
        catch (RegexError error)
        {
            assert_not_reached();
        }
        return inputs;
    }

    /** Supplement provider metadata with native capture devices without opening or recording them. */
    public static List<Input> discover()
    {
        try
        {
            string devices;
            FileUtils.get_contents("/proc/asound/pcm", out devices);
            return parse(devices);
        }
        catch (FileError error)
        {
            return new List<Input>();
        }
    }
}
