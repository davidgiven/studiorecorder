/** Exports native GStreamer topology and a rendered diagram readable by GTK's render-node editor. */
public class PipelineGraphExport : Object
{
    /** Render a captured DOT snapshot asynchronously, preserving the topology as a companion file. */
    public static async string write(string dot, string directory, Cancellable? cancellable = null) throws Error
    {
        string stamp = new DateTime.now_local().format("%Y-%m-%d_%H-%M-%S_%f%z");
        string base_path = Path.build_filename(directory, "StudioRecorderGraph_%s_%s".printf(stamp, Uuid.string_random()));
        string dot_path = base_path + ".dot";
        string node_path = base_path + ".node";
        var graph = File.new_for_path(dot_path).create(FileCreateFlags.NONE, cancellable);
        graph.write_all(dot.data, null, cancellable);
        graph.close(cancellable);

        // Keep the DOT snapshot usable even if the optional Graphviz renderer is not installed.
        string? renderer = Environment.find_program_in_path("dot");
        if (renderer == null)
            throw new RecorderError.FAILED("Install Graphviz (dot) to render GTK diagrams. Native DOT saved to %s.", dot_path);

        // Keep graph layout off the GTK loop; bound rendering so diagnostics cannot hang indefinitely.
        var process = new Subprocess.newv(
            /* argv= */ new string[] { renderer, "-Tpng", "-Gdpi=72", "-Gsize=160,160" },
            /* flags= */ SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
        uint timeout = Timeout.add_seconds(
            /* interval= */ 15,
            /* function= */ () =>
            {
                process.force_exit();
                return Source.REMOVE;
            });
        ulong cancel_handler = 0;
        if (cancellable != null)
            cancel_handler = cancellable.cancelled.connect(() => process.force_exit());
        Bytes? rendered;
        Bytes? diagnostic;
        try
        {
            yield process.communicate_async(new Bytes(dot.data), cancellable, out rendered, out diagnostic);
        }
        catch (Error error)
        {
            process.force_exit();
            throw error;
        }
        finally
        {
            // Release cancellation and deadline hooks after the renderer has completed or been stopped.
            if (cancellable != null && cancel_handler != 0)
                cancellable.disconnect(cancel_handler);
            if (MainContext.default().find_source_by_id(timeout) != null)
                Source.remove(timeout);
        }
        if (!process.get_successful() || rendered == null)
            throw new RecorderError.FAILED("Graphviz could not render the graph. Native DOT saved to %s. %s", dot_path, diagnostic != null ? ((string) diagnostic.get_data()).ndup(diagnostic.get_size()) : "");

        // GTK render nodes describe drawing operations; embed the diagram as a texture node, not fake topology.
        var texture = Gdk.Texture.from_bytes(rendered);
        var snapshot = new Gtk.Snapshot();
        var bounds = Graphene.Rect();
        bounds.init(0, 0, texture.get_width(), texture.get_height());
        snapshot.append_texture(texture, bounds);
        var node = snapshot.to_node();
        if (node == null)
            throw new RecorderError.FAILED("Cannot create the GTK graph diagram. Native DOT saved to %s.", dot_path);
        var output = File.new_for_path(node_path).create(FileCreateFlags.NONE, cancellable);
        output.write_all(node.serialize().get_data(), null, cancellable);
        output.close(cancellable);
        return node_path;
    }
}
