/** Holds driver-probed metadata and maps slider positions to valid native control values. */
public class CameraControl : GLib.Object
{
    public uint32 id;
    public uint32 kind;
    public string name;
    public int minimum;
    public int maximum;
    public int step;
    public int default_value;
    public uint32 flags;
    public int[] choices = {};
    public string[] labels = {};

    /** Copy metadata out of the kernel structure while its fixed-size name is still available. */
    public CameraControl(V4L2.QueryControl query)
    {
        id = query.id;
        kind = query.type;
        name = ((string) query.name).dup();
        minimum = query.minimum;
        maximum = query.maximum;
        step = int.max(1, query.step);
        default_value = query.default_value;
        flags = query.flags;
    }

    /** Decide whether this control has menu-index rather than arithmetic slider positions. */
    public bool is_menu()
    {
        return kind == V4L2.MENU || kind == V4L2.INTEGER_MENU;
    }

    /** Return the last slider position without overflowing a signed 32-bit native value. */
    public double last_position()
    {
        return is_menu() ? int.max(0, choices.length - 1) : (double) (((int64) maximum - minimum) / step);
    }

    /** Convert a rounded slider position into a driver-supported integer or sparse menu index. */
    public int value_at(double position)
    {
        int64 index = (int64) Math.round(position.clamp(0, last_position()));
        return is_menu() ? choices[(int) index] : (int) ((int64) minimum + index * step);
    }

    /** Locate a native value on the slider, including sparse menu indices. */
    public double position_of(int value)
    {
        if (is_menu())
        {
            for (int index = 0; index < choices.length; index++)
                if (choices[index] == value)
                    return index;
            return 0;
        }
        return ((double) value - minimum) / step;
    }

    /** Reject saved values which no longer fit the driver's current range or menu. */
    public bool accepts(int value)
    {
        if (is_menu())
        {
            foreach (int choice in choices)
                if (value == choice)
                    return true;
            return false;
        }
        return value >= minimum && value <= maximum && ((int64) value - minimum) % step == 0;
    }

    /** Respect dynamic control availability and the application's fixed-frame-rate policy. */
    public bool writable()
    {
        return (flags & (V4L2.DISABLED | V4L2.READ_ONLY | V4L2.INACTIVE | V4L2.GRABBED | V4L2.WRITE_ONLY)) == 0;
    }

    /** Format the real native value or menu label rather than the slider's internal position. */
    public string describe(double position)
    {
        return is_menu() ? labels[(int) Math.round(position.clamp(0, last_position()))] : value_at(position).to_string();
    }
}
