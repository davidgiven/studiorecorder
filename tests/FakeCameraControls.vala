/** Simulates driver metadata, sparse menus, and auto/manual dependencies without camera hardware. */
private class FakeCameraControls : CameraControls
{
    public bool automatic = true;
    public bool reject_writes;
    public bool legacy;
    public List<string> writes = new List<string>();
    private HashTable<string, int> values = new HashTable<string, int>(str_hash, str_equal);

    /** Initialize an inert borrowed descriptor; overridden operations never access the kernel. */
    public FakeCameraControls()
    {
        base.borrowed(-1);
        values.insert(V4L2.BASE.to_string(), 8);
        values.insert((V4L2.BASE + 2).to_string(), 16);
        values.insert((V4L2.BASE + 3).to_string(), 7);
    }

    /** Enumerate synthetic controls and report flags according to the simulated auto mode. */
    public override bool query(ref V4L2.QueryControl control)
    {
        uint32[] ids =
        { V4L2.BASE, V4L2.BASE + 1, V4L2.BASE + 2, V4L2.BASE + 3, V4L2.BASE + 4, V4L2.BASE + 5, V4L2.EXPOSURE_AUTO_PRIORITY };
        uint32 requested = control.id;
        uint32 id = requested;
        if ((requested & V4L2.NEXT_CTRL) != 0)
        {
            if (legacy)
                return false;
            id = 0;
            foreach (uint32 candidate in ids)
                if (candidate > (requested & ~V4L2.NEXT_CTRL))
                {
                    id = candidate;
                    break;
                }
        }
        bool found = false;
        foreach (uint32 candidate in ids)
            found |= candidate == id;
        if (!found)
            return false;
        V4L2.QueryControl result = {};
        result.id = id;
        result.type = V4L2.INTEGER;
        result.minimum = -64;
        result.maximum = 64;
        result.step = 4;
        result.default_value = 0;
        string name = "Test control";
        for (int index = 0; index < name.length; index++)
            result.name[index] = name[index];
        if (id == V4L2.BASE + 1 || id == V4L2.EXPOSURE_AUTO_PRIORITY)
        {
            result.type = V4L2.BOOLEAN;
            result.minimum = 0;
            result.maximum = 1;
            result.step = 1;
            result.default_value = 1;
        }
        if (id == V4L2.BASE + 2 && automatic)
            result.flags = V4L2.INACTIVE;
        if (id == V4L2.BASE + 3)
        {
            result.type = V4L2.INTEGER_MENU;
            result.minimum = 1;
            result.maximum = 7;
            result.step = 1;
            result.default_value = 3;
        }
        if (id == V4L2.BASE + 4)
            result.flags = V4L2.READ_ONLY;
        if (id == V4L2.BASE + 5)
            result.type = V4L2.BUTTON;
        control = result;
        return true;
    }

    /** Expose sparse integer menu entries with holes between valid indices. */
    public override bool menu(ref V4L2.QueryMenu item)
    {
        if (item.id != V4L2.BASE + 3 || (item.index != 1 && item.index != 3 && item.index != 7))
            return false;
        item.value = item.index * 100;
        return true;
    }

    /** Read the current simulated value, including the dynamic auto-mode boolean. */
    public override int read(uint32 id) throws Error
    {
        return id == V4L2.BASE + 1 ? (automatic ? 1 : 0) : values.lookup(id.to_string());
    }

    /** Reject unavailable values and log the order in which valid settings were applied. */
    public override void write(uint32 id, int value) throws Error
    {
        V4L2.QueryControl metadata = {};
        metadata.id = id;
        if (reject_writes || !query(ref metadata) || (metadata.flags & (V4L2.INACTIVE | V4L2.READ_ONLY)) != 0)
            throw new IOError.FAILED("Simulated driver rejection");
        if (id == V4L2.BASE + 1)
            automatic = value != 0;
        values.insert(id.to_string(), value);
        writes.append(id.to_string());
    }
}
