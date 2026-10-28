/** Stores extensible per-video-source preferences without coupling them to capture routing. */
public class Preferences : GLib.Object
{
    private KeyFile settings = new KeyFile();
    private string path;

    /** Load saved channel groups from the user configuration directory or an explicit test path. */
    public Preferences(string? path = null)
    {
        this.path = path ?? Path.build_filename(Environment.get_user_config_dir(), "studio-recorder", "preferences.ini");
        try
        {
            settings.load_from_file(this.path, KeyFileFlags.KEEP_COMMENTS);
        }
        catch (FileError error)
        {
            if (error.code != FileError.NOENT)
                warning("Cannot load preferences: %s", error.message);
        }
        catch (KeyFileError error)
        {
            warning("Cannot parse preferences: %s", error.message);
        }
    }

    /** Normalize desktop capture and prefer persistent hardware identities over routing identities. */
    private static string source_key(Input input)
    {
        if (input.identity.has_prefix("desktop-screen"))
            return "desktop-screen";
        return input.preference_id ?? input.identity;
    }

    /** Encode arbitrary source identities into safe, distinct key-file group names. */
    private static string channel_group(Input input)
    {
        return "channel:" + Uri.escape_string(source_key(input), null, false);
    }

    /** Restore an explicit assignment; retain missing-device overrides while safely using no audio. */
    public void restore_audio(Camera camera, List<Input> sources)
    {
        string saved;
        try
        {
            saved = settings.get_string(channel_group(camera.input), "audio-source");
        }
        catch (KeyFileError error)
        {
            return;
        }

        // An empty value represents an explicit No audio choice, unlike an absent preference.
        camera.audio = null;
        if (saved.length == 0)
            return;
        foreach (var source in sources)
        {
            if (source_key(source) == saved)
            {
                camera.audio = source;
                return;
            }
        }
    }

    /** Save only the changed audio key, preserving other channels and future preference keys. */
    public void save_audio(Camera camera)
    {
        settings.set_string(channel_group(camera.input), "audio-source", camera.audio != null ? source_key(camera.audio) : "");
        save();
    }

    /** Restore only a still-supported mode, keeping the probed current mode for stale settings. */
    public void restore_video_mode(Input input)
    {
        try
        {
            string group = channel_group(input);
            int width = settings.get_integer(group, "video-width");
            int height = settings.get_integer(group, "video-height");
            int numerator = settings.get_integer(group, "video-rate-numerator");
            int denominator = settings.get_integer(group, "video-rate-denominator");

            // Reject incomplete values before matching the exact rational rate to supported modes.
            if (width <= 0 || height <= 0 || numerator <= 0 || denominator <= 0)
                return;
            foreach (var mode in input.video_modes)
                if (mode.width == width && mode.height == height &&
                    (int64) mode.numerator * denominator == (int64) numerator * mode.denominator)
                {
                    input.video_mode = mode;
                    return;
                }
        }
        catch (KeyFileError error)
        {
            // Missing or malformed preferences retain the device's actual current mode.
        }
    }

    /** Persist exact dimensions and rational FPS alongside other source preferences. */
    public void save_video_mode(Input input)
    {
        var mode = input.video_mode;
        if (mode == null)
            return;

        // Update only format keys so audio, scalar controls, and future settings survive.
        string group = channel_group(input);
        settings.set_integer(group, "video-width", mode.width);
        settings.set_integer(group, "video-height", mode.height);
        settings.set_integer(group, "video-rate-numerator", mode.numerator);
        settings.set_integer(group, "video-rate-denominator", mode.denominator);
        save();
    }

    /** Load saved scalar camera values without removing settings for temporarily absent controls. */
    public HashTable<string, int> load_controls(Input input)
    {
        var values = new HashTable<string, int>(str_hash, str_equal);
        try
        {
            string group = channel_group(input);
            foreach (string key in settings.get_keys(group))
            {
                if (!key.has_prefix("v4l2-"))
                    continue;
                uint64 id;
                string number = key.substring(5);
                if (!uint64.try_parse(number, out id) || id > uint32.MAX)
                    continue;
                try
                {
                    values.insert(number, settings.get_integer(group, key));
                }
                catch (KeyFileError error)
                {
                    warning("Ignoring invalid camera preference %s: %s", key, error.message);
                }
            }
        }
        catch (KeyFileError error)
        {
            // A source without a saved group retains its hardware settings.
        }
        return values;
    }

    /** Persist an accepted camera value alongside the source's audio selection and other keys. */
    public void save_control(Input input, uint32 id, int value)
    {
        settings.set_integer(channel_group(input), "v4l2-" + id.to_string(), value);
        save();
    }

    /** Atomically replace the preferences file after creating its private parent directory. */
    private void save()
    {
        try
        {
            string directory = Path.get_dirname(path);
            if (DirUtils.create_with_parents(directory, 0700) != 0)
                throw new FileError.FAILED("Cannot create preferences directory: %s", directory);
            FileUtils.set_contents(path, settings.to_data());
        }
        catch (FileError error)
        {
            warning("Cannot save preferences: %s", error.message);
        }
    }
}
