/** Presents one probed scalar control with native values, wheel-safe adjustment, and a default reset. */
public class CameraControlRow : Gtk.Box
{
    private CameraControls device;
    private CameraControl control;
    private Gtk.Scale slider;
    private Gtk.Button reset;
    private Gtk.Label state_label;
    private bool updating;
    private bool readable;

    /** Report a successful write and readback so the panel can persist it and refresh dependencies. */
    public signal void committed(uint32 id, int value, bool persistent);

    /** Report a driver failure without losing the last accepted selection or saved setting. */
    public signal void failed(string message);

    /** Build the labeled slider and its adjacent reset button without writing initial values. */
    public CameraControlRow(CameraControls device, CameraControl control)
    {
        Object(orientation: Gtk.Orientation.VERTICAL, spacing: 4);
        this.device = device;
        this.control = control;
        var label = new Gtk.Label(control.name)
        {
            xalign = 0,
            wrap = true
        };
        append(label);
        var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        slider = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, double.max(1, control.last_position()), 1)
        {
            hexpand = true,
            draw_value = true,
            value_pos = Gtk.PositionType.RIGHT,
            digits = 0,
            round_digits = 0,
            tooltip_text = control.name
        };
        slider.set_size_request(280, -1);
        slider.set_format_value_func((scale, value) => control.describe(value));
        label.set_mnemonic_widget(slider);
        disable_scrolling(slider);
        row.append(slider);
        reset = new Gtk.Button.from_icon_name("edit-undo-symbolic")
        {
            tooltip_text = "Reset to device default (%d)".printf(control.default_value)
        };
        reset.clicked.connect(() => apply(control.default_value, true));
        row.append(reset);
        append(row);
        state_label = new Gtk.Label(null)
        {
            xalign = 0,
            wrap = true
        };
        state_label.add_css_class("dim-label");
        append(state_label);
        refresh();
        slider.value_changed.connect(
            /* handler= */ () =>
            {
                if (!updating)
                    apply(control.value_at(slider.get_value()));
            });
    }

    /** Disable the scale's own wheel handler while leaving events available to the parent scroller. */
    private static void disable_scrolling(Gtk.Scale slider)
    {
        var controllers = slider.observe_controllers();
        for (uint index = 0; index < controllers.get_n_items(); index++)
        {
            var controller = controllers.get_item(index) as Gtk.EventControllerScroll;
            if (controller != null)
                controller.propagation_phase = Gtk.PropagationPhase.NONE;
        }
    }

    /** Re-read current values and dynamic availability after auto/manual mode changes. */
    public void refresh()
    {
        V4L2.QueryControl query = {};
        query.id = control.id;
        bool available = device.query(ref query);
        if (available)
            control.flags = query.flags;
        readable = false;
        updating = true;
        try
        {
            int value = device.read(control.id);
            slider.set_value(control.position_of(value));
            readable = true;
            state_label.label = !available ? "Unavailable" :
                                (control.flags & V4L2.READ_ONLY) != 0 ? "Read only" :
                                (control.flags & V4L2.INACTIVE) != 0 ? "Inactive in the current mode" :
                                (control.flags & V4L2.GRABBED) != 0 ? "Busy" : "";
        }
        catch (Error error)
        {
            state_label.label = error.message;
        }
        updating = false;
        state_label.visible = state_label.label.length > 0;
        slider.sensitive = available && readable && control.writable() && control.last_position() > 0;
        reset.sensitive = available && readable && control.writable() && control.accepts(control.default_value);
    }

    /** Write one valid value, persist only readback, and restore the display when the driver rejects it. */
    private void apply(int value, bool force = false)
    {
        if (updating || !readable || !control.accepts(value))
            return;
        V4L2.QueryControl query = {};
        query.id = control.id;
        if (!device.query(ref query))
        {
            refresh();
            return;
        }
        control.flags = query.flags;
        if (!control.writable())
        {
            refresh();
            return;
        }
        try
        {
            // GTK can re-emit value-changed after rolling back an adjustment inside its handler.
            // Do not turn the readback display update into a second hardware write.
            if (!force && device.read(control.id) == value)
                return;
            device.write(control.id, value);
            int actual = device.read(control.id);
            committed(control.id, actual, (control.flags & V4L2.VOLATILE) == 0);
        }
        catch (Error error)
        {
            failed("%s: %s".printf(control.name, error.message));
        }
        refresh();
    }
}
