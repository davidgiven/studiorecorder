/** Opens a camera's control interface without allocating capture buffers or processing media. */
public class CameraControls : GLib.Object
{
    private int descriptor = -1;
    private bool owns_descriptor;

    /** Open a separate nonblocking descriptor for main-loop control probing and adjustment. */
    public CameraControls(string path) throws Error
    {
        descriptor = Posix.open(path, Posix.O_RDWR | Posix.O_NONBLOCK | Posix.O_CLOEXEC);
        if (descriptor < 0)
            throw new IOError.FAILED("Cannot open camera controls: %s", strerror(errno));
        owns_descriptor = true;
    }

    /** Borrow GStreamer's descriptor during prepare-format without changing its lifetime. */
    public CameraControls.borrowed(int descriptor)
    {
        this.descriptor = descriptor;
    }

    /** Close only the separately opened UI descriptor. */
    ~CameraControls()
    {
        if (owns_descriptor && descriptor >= 0)
            Posix.close(descriptor);
    }

    /** Query metadata; virtual dispatch also permits deterministic driver simulations in tests. */
    public virtual bool query(ref V4L2.QueryControl control)
    {
        return V4L2.query_control(descriptor, V4L2.QUERYCTRL, ref control) == 0;
    }

    /** Query a sparse menu entry without treating holes as fatal driver errors. */
    public virtual bool menu(ref V4L2.QueryMenu item)
    {
        return V4L2.query_menu(descriptor, V4L2.QUERYMENU, ref item) == 0;
    }

    /** Read the actual current value rather than assuming a previous write was accepted unchanged. */
    public virtual int read(uint32 id) throws Error
    {
        V4L2.ExtControl value = {};
        value.id = id;
        V4L2.ExtControls request = {};
        request.count = 1;
        request.controls = &value;
        if (V4L2.ext_controls(descriptor, V4L2.G_EXT_CTRLS, ref request) == 0)
            return value.value;

        // Older drivers may expose only the legacy scalar ioctls.
        V4L2.Control control = {};
        control.id = id;
        if (V4L2.set_control(descriptor, V4L2.G_CTRL, ref control) < 0)
            throw new IOError.FAILED("Cannot read camera control: %s", strerror(errno));
        return control.value;
    }

    /** Set a scalar control; callers validate the driver's range and read the accepted value back. */
    public virtual void write(uint32 id, int value) throws Error
    {
        V4L2.ExtControl scalar = {};
        scalar.id = id;
        scalar.value = value;
        V4L2.ExtControls request = {};
        request.count = 1;
        request.controls = &scalar;
        if (V4L2.ext_controls(descriptor, V4L2.S_EXT_CTRLS, ref request) == 0)
            return;

        V4L2.Control control = {};
        control.id = id;
        control.value = value;
        if (V4L2.set_control(descriptor, V4L2.S_CTRL, ref control) < 0)
            throw new IOError.FAILED("Cannot set camera control: %s", strerror(errno));
    }

    /** Convert supported scalar metadata and query menu holes while ignoring unsafe control types. */
    private CameraControl? describe(V4L2.QueryControl query)
    {
        // Relative movement and execute-on-write commands have no persistent absolute position.
        if (query.id == V4L2.EXPOSURE_AUTO_PRIORITY || query.id == V4L2.PAN_RELATIVE ||
            query.id == V4L2.TILT_RELATIVE || query.id == V4L2.FOCUS_RELATIVE ||
            query.id == V4L2.ZOOM_RELATIVE || query.id == V4L2.IRIS_RELATIVE ||
            (query.flags & (V4L2.DISABLED | V4L2.WRITE_ONLY | V4L2.EXECUTE_ON_WRITE)) != 0 || query.maximum < query.minimum)
            return null;
        if (query.type != V4L2.INTEGER && query.type != V4L2.BOOLEAN &&
            query.type != V4L2.MENU && query.type != V4L2.INTEGER_MENU)
            return null;
        var control = new CameraControl(query);
        if (control.is_menu())
        {
            int[] choices = {};
            string[] labels = {};
            for (int64 index = query.minimum; index <= query.maximum; index++)
            {
                V4L2.QueryMenu item = {};
                item.id = query.id;
                item.index = (uint32) index;
                if (!menu(ref item))
                    continue;
                choices += (int) index;
                labels += query.type == V4L2.MENU ? ((string) item.name).dup() : item.value.to_string();
            }
            control.choices = (owned) choices;
            control.labels = (owned) labels;
            if (control.choices.length == 0)
                return null;
        }
        return control;
    }

    /** Enumerate supported scalar controls in driver order, with a legacy user-control fallback. */
    public List<CameraControl> probe()
    {
        var result = new List<CameraControl>();
        uint32 previous = 0;
        bool enumerated = false;
        while (true)
        {
            V4L2.QueryControl query = {};
            query.id = previous | V4L2.NEXT_CTRL;
            if (!this.query(ref query) || query.id <= previous)
                break;
            enumerated = true;
            previous = query.id;
            var control = describe(query);
            if (control != null)
                result.append(control);
        }
        if (!enumerated)
        {
            for (uint32 id = V4L2.BASE; id < V4L2.LASTP1; id++)
            {
                V4L2.QueryControl query = {};
                query.id = id;
                if (!this.query(ref query))
                    continue;
                var control = describe(query);
                if (control != null)
                    result.append(control);
            }
        }
        return result;
    }

    /** Restore mode controls before numeric values so saved manual settings can become active. */
    public void restore(HashTable<string, int> saved)
    {
        var controls = probe();
        for (int pass = 0; pass < 2; pass++)
        {
            foreach (var control in controls)
            {
                bool mode = control.is_menu() || control.kind == V4L2.BOOLEAN;
                if (mode != (pass == 0))
                    continue;
                string key = control.id.to_string();
                if (!saved.contains(key))
                    continue;
                int value = saved.lookup(key);
                V4L2.QueryControl query = {};
                query.id = control.id;
                if (!this.query(ref query))
                    continue;
                var current = describe(query);
                if (current == null || !current.writable() || !current.accepts(value) || (current.flags & V4L2.VOLATILE) != 0)
                    continue;
                try
                {
                    write(current.id, value);
                }
                catch (Error error)
                {
                    warning("%s: %s", control.name, error.message);
                }
            }
        }
    }
}
