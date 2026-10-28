/** Hosts probed camera controls for one selected input and persists accepted user adjustments. */
public class CameraControlsPanel : Gtk.Box
{
    private List<CameraControlRow> rows = new List<CameraControlRow>();

    /** Show the source name, optional format selectors, and supported V4L2 adjustments. */
    public CameraControlsPanel(Input input, Preferences? preferences, Gtk.Widget? format_controls = null)
    {
        Object(orientation: Gtk.Orientation.VERTICAL, spacing: 12);
        var source = new Gtk.Label(input.name)
        {
            xalign = 0,
            wrap = true
        };
        source.add_css_class("heading");
        append(source);
        if (format_controls != null)
            append(format_controls);

        // Display unsupported controls and driver errors beneath the format selectors.
        var message = new Gtk.Label(null)
        {
            xalign = 0,
            wrap = true,
            visible = false
        };
        append(message);
        if (input.video_path == null)
        {
            message.label = "V4L2 controls are not available for this source.";
            message.visible = true;
            return;
        }
        try
        {
            var device = new CameraControls(input.video_path);
            var owner = WeakRef(this);
            foreach (var control in device.probe())
            {
                var row = new CameraControlRow(device, control);
                row.failed.connect(
                    /* handler= */ (error) =>
                    {
                        message.label = error;
                        message.visible = true;
                    });
                row.committed.connect(
                    /* handler= */ (id, value, persistent) =>
                    {
                        message.visible = false;
                        if (persistent)
                        {
                            input.saved_controls.insert(id.to_string(), value);
                            if (preferences != null)
                                preferences.save_control(input, id, value);
                        }

                        // Mode controls can enable manual sliders without recreating widgets mid-drag.
                        var panel = owner.get() as CameraControlsPanel;
                        if (panel != null)
                            panel.refresh();
                    });
                rows.append(row);
                append(row);
            }
            if (rows.length() == 0)
            {
                message.label = "This device exposes no supported scalar V4L2 controls.";
                message.visible = true;
            }
        }
        catch (Error error)
        {
            message.label = error.message;
            message.visible = true;
        }
    }
    /** Refresh values after capture startup restoration or a control dependency change. */
    public void refresh()
    {
        foreach (var row in rows)
            row.refresh();
    }

}
