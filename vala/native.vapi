namespace Native {
    /** Initialize Xlib threading before any GTK or screen-capture threads start. */
    [CCode (cname = "XInitThreads", cheader_filename = "X11/Xlib.h")]
    public int xinit_threads ();

}
