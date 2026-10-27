/** Owns the dockable recording workspace independently of capture pipelines and their widgets. */
public class RecordingWorkspace : Gtk.Box
{
    private Panel.Dock dock;

    /** Arrange four independently movable panels with the preview centered and controls alongside. */
    public RecordingWorkspace(Gtk.Widget preview, Gtk.Widget transport, Gtk.Widget thumbnails, Gtk.Widget controls)
    {
        Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);

        // Dock areas are assigned through GtkBuilder's typed children rather than widget parenting.
        var builder = new Gtk.Builder.from_string(
            /* string= */ """
            <interface>
              <object class="PanelDock" id="dock">
                <property name="vexpand">true</property>
                <property name="hexpand">true</property>
                <property name="reveal-bottom">true</property>
                <child>
                  <object class="PanelGrid" id="grid"/>
                </child>
                <child type="bottom">
                  <object class="PanelPaned">
                    <property name="orientation">vertical</property>
                    <child><object class="PanelFrame" id="transport"/></child>
                    <child><object class="PanelFrame" id="thumbnails"/></child>
                  </object>
                </child>
              </object>
            </interface>
            """,
            /* length= */ -1);
        dock = (Panel.Dock) builder.get_object("dock");
        var grid = (Panel.Grid) builder.get_object("grid");
        grid.create_frame.connect(() => create_frame());
        dock.create_frame.connect((position) => create_frame());

        // Stable panel IDs identify the UI roles; media state stays owned by Application.
        var main_preview = create_panel("main-preview", "Main preview", "camera-video-symbolic", preview);
        grid.add(main_preview);
        add_to_frame((Panel.Frame) builder.get_object("transport"), create_panel("transport", "Recording and status", "media-record-symbolic", transport));
        add_to_frame((Panel.Frame) builder.get_object("thumbnails"), create_panel("thumbnails", "Sources", "view-grid-symbolic", thumbnails));
        // Keep the controls split inside the preview area, above the full-width bottom panels.
        grid.insert_column(1);
        add_to_frame(
            /* frame= */ grid.get_column(1).get_row(0),
            /* panel= */ create_panel(
                /* id= */ "video-controls",
                /* title= */ "Video controls",
                /* icon_name= */ "preferences-system-symbolic",
                /* child= */ controls));

        // Area toggles remain accessible even when an entire docking area is hidden.
        var visibility = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6)
        {
            margin_start = 8,
            margin_end = 8,
            margin_top = 4,
            margin_bottom = 4
        };
        visibility.append(new Gtk.Label("Panels"));
        add_area_toggle(visibility, "Left", "reveal-start");
        add_area_toggle(visibility, "Right", "reveal-end");
        add_area_toggle(visibility, "Top", "reveal-top");
        add_area_toggle(visibility, "Bottom", "reveal-bottom");
        append(visibility);
        append(dock);
    }

    /** Create an icon-and-title draggable frame for initial panels and future drag-created destinations. */
    private static Panel.Frame create_frame()
    {
        var frame = new Panel.Frame();
        frame.set_header(create_header());
        return frame;
    }

    /** Install a draggable frame header before attaching an initial panel. */
    private static void add_to_frame(Panel.Frame frame, Panel.Widget panel)
    {
        frame.set_header(create_header());
        frame.add(panel);
    }

    /** Let the whole title bar initiate libpanel's native panel drag instead of a separate grip. */
    private static Panel.FrameHeaderBar create_header()
    {
        var header = new Panel.FrameHeaderBar()
        {
            show_icon = true
        };
        var grip = find_drag_grip(header);
        if (grip != null)
        {
            var controllers = grip.observe_controllers();
            for (uint index = 0; index < controllers.get_n_items(); index++)
            {
                var source = controllers.get_item(index) as Gtk.DragSource;
                if (source == null)
                    continue;

                // Retain the existing controller and its libpanel callbacks across reparenting.
                grip.remove_controller(source);
                header.add_controller((owned) source);
                grip.visible = false;
                break;
            }
        }
        return header;
    }

    /** Locate the standard header's grip through widget properties without private template access. */
    private static Gtk.Button? find_drag_grip(Gtk.Widget widget)
    {
        var button = widget as Gtk.Button;
        if (button != null && button.icon_name == "list-drag-handle-symbolic")
            return button;
        for (var child = widget.get_first_child(); child != null; child = child.get_next_sibling())
        {
            var grip = find_drag_grip(child);
            if (grip != null)
                return grip;
        }
        return null;
    }

    /** Wrap an existing view without changing its ownership of recording or preview state. */
    private static Panel.Widget create_panel(string id, string title, string icon_name, Gtk.Widget child)
    {
        return new Panel.Widget()
               {
                   id = id,
                   title = title,
                   icon_name = icon_name,
                   child = child,
                   reorderable = true
               };
    }

    /** Bind a dock area's visibility to an always-reachable button. */
    private void add_area_toggle(Gtk.Box toolbar, string label, string property)
    {
        var toggle = new Gtk.ToggleButton.with_label(label);
        dock.bind_property(
            /* source_property= */ property,
            /* target= */ toggle,
            /* target_property= */ "active",
            /* flags= */ BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
        toolbar.append(toggle);
    }
}
