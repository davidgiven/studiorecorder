/** Edits the destination and filename pattern used for subsequent recording takes. */
public class PreferencesDialog : Gtk.Window
{
    private Gtk.Entry directory;
    private Gtk.Entry pattern;
    private Gtk.Label example;
    private Gtk.Label error_label;

    /** Publish validated settings only after the user saves the dialog. */
    public signal void accepted(RecordingOutput output);

    /** Build destination controls, pattern help, and a live filename example. */
    public PreferencesDialog(Gtk.Window parent, RecordingOutput output)
    {
        Object(title: "Preferences", transient_for: parent, modal: true, default_width: 620, resizable: false);

        // Keep entries and their explanatory text inside a consistently padded content area.
        var content = new Gtk.Box(Gtk.Orientation.VERTICAL, 12)
        {
            margin_start = 24,
            margin_end = 24,
            margin_top = 24,
            margin_bottom = 24
        };
        child = content;
        content.append(
            /* child= */ new Gtk.Label("Output directory")
            {
                xalign = 0
            });
        var folder = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        directory = new Gtk.Entry()
        {
            text = output.directory, hexpand = true
        };
        folder.append(directory);
        var browse = new Gtk.Button.with_label("Browse…");
        browse.clicked.connect(() => choose_directory.begin());
        folder.append(browse);
        content.append(folder);
        content.append(
            /* child= */ new Gtk.Label("Filename pattern")
            {
                xalign = 0
            });
        pattern = new Gtk.Entry()
        {
            text = output.pattern
        };
        content.append(pattern);
        content.append(
            /* child= */ new Gtk.Label("Local time: %Y year, %y short year, %m month, %d day, %H hour, %M minute, %S second, %f microseconds, %z timezone. Use {uuid} for a unique ID and %% for %. End the filename with .mkv.")
            {
                xalign = 0, wrap = true, max_width_chars = 65
            });
        example = new Gtk.Label(null)
        {
            xalign = 0, wrap = true, selectable = true, max_width_chars = 65
        };
        content.append(example);
        content.append(
            /* child= */ new Gtk.Label("Changes apply to the next take. Existing filenames receive a numeric suffix.")
            {
                xalign = 0, wrap = true, max_width_chars = 65
            });
        error_label = new Gtk.Label(null)
        {
            xalign = 0, wrap = true, visible = false, max_width_chars = 65
        };
        error_label.add_css_class("error");
        content.append(error_label);

        // Keep dialog actions below the form while retaining the window's standard title bar.
        var actions = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6)
        {
            halign = Gtk.Align.END,
            margin_top = 12
        };
        var cancel = new Gtk.Button.with_label("Cancel");
        cancel.clicked.connect(() => close());
        actions.append(cancel);
        var save = new Gtk.Button.with_label("Save");
        save.add_css_class("suggested-action");
        save.clicked.connect(save_settings);
        actions.append(save);
        content.append(actions);
        set_default_widget(save);

        // Show pattern errors immediately without writing preferences until Save is pressed.
        pattern.changed.connect(update_example);
        update_example();
    }

    /** Snapshot entry values without altering the active take's settings. */
    private RecordingOutput edited_output()
    {
        var output = new RecordingOutput();
        output.directory = directory.text.strip();
        output.pattern = pattern.text;
        return output;
    }

    /** Render a fresh local-time filename or the reason its pattern is invalid. */
    private void update_example()
    {
        try
        {
            example.label = "Example: " + edited_output().filename(new DateTime.now_local(), "example-uuid");
        }
        catch (Error error)
        {
            example.label = error.message;
        }
    }

    /** Let the desktop's native folder picker fill the directory entry. */
    private async void choose_directory()
    {
        var chooser = new Gtk.FileDialog()
        {
            title = "Choose output directory"
        };
        if (Path.is_absolute(directory.text))
            chooser.initial_folder = File.new_for_path(directory.text);
        try
        {
            var folder = yield chooser.select_folder(this, null);
            string? path = folder.get_path();
            if (path != null)
                directory.text = path;
        }
        catch (Error error)
        {
            // Cancellation leaves the editable destination unchanged.
            if (!(error is Gtk.DialogError.DISMISSED))
            {
                error_label.label = error.message;
                error_label.visible = true;
            }
        }
    }

    /** Validate both fields before notifying the application and closing the dialog. */
    private void save_settings()
    {
        try
        {
            var output = edited_output();
            output.validate();
            accepted(output);
            close();
        }
        catch (Error error)
        {
            error_label.label = error.message;
            error_label.visible = true;
        }
    }
}
