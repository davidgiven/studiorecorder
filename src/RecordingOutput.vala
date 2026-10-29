/** Names and reserves takes using the user's output directory and date pattern. */
public class RecordingOutput : Object
{
    public const string DEFAULT_PATTERN = "StudioRecorder_%Y-%m-%d_%H-%M-%S_%f%z_{uuid}.mkv";
    public string directory = Environment.get_current_dir();
    public string pattern = DEFAULT_PATTERN;

    /** Validate a filename-only pattern with supported local-time placeholders. */
    public string filename(DateTime time, string uuid) throws Error
    {
        if (pattern.length == 0 || pattern.contains("/") || !pattern.has_suffix(".mkv"))
            throw new RecorderError.FAILED("Use a filename ending in .mkv, without directory separators.");

        // Restrict date directives so formatting cannot introduce paths or control characters.
        for (int i = 0; i < pattern.length; i++)
        {
            if ((uint8) pattern[i] < 32 || pattern[i] == 127)
                throw new RecorderError.FAILED("The filename pattern cannot contain control characters.");
            if (pattern[i] == '%')
            {
                i++;
                if (i >= pattern.length || "YymdHMSfz%".index_of_char(pattern[i]) < 0)
                    throw new RecorderError.FAILED("Supported date fields: %Y, %y, %m, %d, %H, %M, %S, %f, %z, and %%.");
            }
        }

        // Expand the optional UUID after formatting to keep its literal contents independent of dates.
        string? formatted = time.format(pattern);
        if (formatted == null)
            throw new RecorderError.FAILED("Cannot format the filename pattern.");
        return formatted.replace("{uuid}", uuid);
    }

    /** Reject unavailable directories and invalid patterns before accepting preferences. */
    public void validate() throws Error
    {
        if (!Path.is_absolute(directory) || !FileUtils.test(directory, FileTest.IS_DIR))
            throw new RecorderError.FAILED("Choose an existing absolute output directory.");
        filename(new DateTime.now_local(), Uuid.string_random());
    }

    /** Exclusively reserve a partial take, adding a numeric suffix for repeated filenames. */
    public string reserve() throws Error
    {
        validate();
        string name = filename(new DateTime.now_local(), Uuid.string_random());
        string stem = name.substring(0, name.length - 4);

        // Existing completed or partial takes are preserved even with a constant filename pattern.
        for (int suffix = 0; suffix < 100000; suffix++)
        {
            string candidate = Path.build_filename(directory, suffix == 0 ? name : "%s_%d.mkv".printf(stem, suffix));
            if (FileUtils.test(candidate, FileTest.EXISTS))
                continue;
            try
            {
                var reserved = File.new_for_path(candidate + ".partial").create(FileCreateFlags.NONE);
                reserved.close();
                return candidate;
            }
            catch (IOError.EXISTS error)
            {
                // Another take already reserved this name; try the next suffix.
            }
        }
        throw new RecorderError.FAILED("No unused recording filename is available.");
    }
}
