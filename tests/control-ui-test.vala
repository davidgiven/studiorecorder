/** Verify native-value adjustment, reset behavior, wheel propagation, and rejected-write rollback. */
private void test_control_row()
{
    var device = new FakeCameraControls();
    var control = device.probe().nth_data(0);
    var row = new CameraControlRow(device, control);
    var controls = (Gtk.Box) row.get_first_child().get_next_sibling();
    var slider = (Gtk.Scale) controls.get_first_child();
    var reset = (Gtk.Button) slider.get_next_sibling();
    int commits = 0;
    int actual = 0;
    int failures = 0;
    row.committed.connect(
        /* handler= */ (id, value, persistent) =>
        {
            assert(id == V4L2.BASE);
            assert(persistent);
            actual = value;
            commits++;
        });
    row.failed.connect(() => failures++);
    assert(control.value_at(slider.get_value()) == 8);
    slider.set_value(control.position_of(12));
    assert(commits == 1 && actual == 12);
    reset.clicked();
    assert(commits == 2 && actual == control.default_value);
    assert(control.value_at(slider.get_value()) == control.default_value);

    // Failed writes do not emit a persistence event, and the slider returns to hardware readback.
    device.reject_writes = true;
    slider.set_value(control.position_of(16));
    assert(failures == 1 && commits == 2);
    assert(control.value_at(slider.get_value()) == control.default_value);
    var controllers = slider.observe_controllers();
    uint wheel_handlers = 0;
    for (uint index = 0; index < controllers.get_n_items(); index++)
    {
        var wheel = controllers.get_item(index) as Gtk.EventControllerScroll;
        if (wheel != null)
        {
            assert(wheel.propagation_phase == Gtk.PropagationPhase.NONE);
            wheel_handlers++;
        }
    }
    assert(wheel_handlers > 0);

    // An auto-mode-dependent manual control becomes editable after the driver changes mode.
    var manual = new CameraControlRow(device, device.probe().nth_data(2));
    var manual_controls = (Gtk.Box) manual.get_first_child().get_next_sibling();
    var manual_slider = (Gtk.Scale) manual_controls.get_first_child();
    assert(!manual_slider.sensitive);
    device.automatic = false;
    manual.refresh();
    assert(manual_slider.sensitive);
}

/** Run display-dependent widget checks separately from headless recording and portal tests. */
int main(string[] args)
{
    Test.init(ref args);
    if (!Gtk.init_check())
    {
        stderr.printf("Control widget checks require a GTK display.\n");
        return 1;
    }
    Adw.init();
    Test.add_func("/studio/control-row", test_control_row);
    return Test.run();
}
