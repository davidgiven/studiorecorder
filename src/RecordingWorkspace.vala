/** Owns the dockable recording workspace independently of capture pipelines and their widgets. */
public class RecordingWorkspace : Gtk.Box
{
    private Panel.Dock dock;
    private Panel.Widget main_preview;
    public Menu view_menu = new Menu();
    public SimpleActionGroup view_actions = new SimpleActionGroup();

    /** Arrange three independently movable panels with the preview centered and controls alongside. */
    public RecordingWorkspace(Gtk.Widget preview, Gtk.Widget thumbnails, Gtk.Widget controls)
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
                  <object class="GtkPaned" id="preview_split">
                    <property name="orientation">horizontal</property>
                    <property name="resize-start-child">true</property>
                    <property name="resize-end-child">false</property>
                    <property name="shrink-start-child">true</property>
                    <property name="shrink-end-child">true</property>
                    <child><object class="PanelGrid" id="grid"/></child>
                    <child><object class="PanelGrid" id="controls_grid"/></child>
                  </object>
                </child>
                <child type="bottom">
                  <object class="PanelPaned">
                    <property name="orientation">vertical</property>
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
        var controls_grid = (Panel.Grid) builder.get_object("controls_grid");
        controls_grid.create_frame.connect(() => create_frame());
        dock.create_frame.connect((position) => create_frame());

        // Stable panel IDs identify the UI roles; media state stays owned by Application.
        main_preview = create_panel("main-preview", "Main preview", "camera-video-symbolic", preview);
        grid.add(main_preview);
        add_to_frame((Panel.Frame) builder.get_object("thumbnails"), create_panel("thumbnails", "Sources", "view-grid-symbolic", thumbnails));
        // A public GTK divider preserves the controls width independently of capture dimensions.
        controls_grid.add(create_panel("video-controls", "Video controls", "preferences-system-symbolic", controls));
        initialize_controls_width((Gtk.Paned) builder.get_object("preview_split"), controls_grid, controls);

        // Expose checked menu actions so hidden docking areas remain reachable above the workspace.
        add_area_toggle("Left panels", "left", "reveal-start");
        add_area_toggle("Right panels", "right", "reveal-end");
        add_area_toggle("Top panels", "top", "reveal-top");
        add_area_toggle("Bottom panels", "bottom", "reveal-bottom");
        append(dock);
    }

    /** Update the selected source statistics in the preview panel's native title bar. */
    public void set_preview_summary(string summary)
    {
        main_preview.title = "Main preview - " + summary;
    }

    /** Restore the end-pane width and preserve it independently of changes to the window allocation. */
    private static void initialize_controls_width(Gtk.Paned split, Panel.Grid column, Gtk.Widget controls)
    {
        var controls_reference = WeakRef(controls);
        var split_reference = WeakRef(split);
        int allocated_width = 0;
        int end_width = 0;
        int handle_width = 0;
        split.notify["position"].connect(
            /* handler= */ () =>
            {
                var view = controls_reference.get() as VideoControlsView;
                var paned = split_reference.get() as Gtk.Paned;
                if (view != null)
                    view.allow_manual_width();
                if (paned != null && allocated_width > 0 && paned.get_width() == allocated_width)
                    end_width = int.max(0, allocated_width - paned.position - handle_width);
            });

        // Native position is measured from the start; translate window resizes into a stable end width.
        var column_reference = WeakRef(column);
        split.add_tick_callback(
            /* callback= */ (widget, clock) =>
            {
                var paned = (Gtk.Paned) widget;
                var grid = column_reference.get() as Panel.Grid;
                if (grid == null)
                    return Source.REMOVE;
                int width = paned.get_width();
                if (width <= 0 || width == allocated_width)
                    return Source.CONTINUE;
                handle_width = int.max(0, width - paned.start_child.get_width() - paned.end_child.get_width());
                if (allocated_width == 0)
                {
                    int minimum;
                    grid.measure(Gtk.Orientation.HORIZONTAL, -1, out minimum, out end_width, null, null);
                }

                // Record the allocation before changing position so its notification sees consistent bounds.
                allocated_width = width;
                paned.position = int.max(0, width - end_width - handle_width);
                return Source.CONTINUE;
            });
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

    /** Reflect native dock visibility in a checked View menu action, including changes made by docking. */
    private void add_area_toggle(string label, string name, string property)
    {
        var action = new PropertyAction(name, dock, property);
        view_actions.add_action(action);
        view_menu.append(label, "view." + name);
    }
}
