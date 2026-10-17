# Usage and the local Livebook server command are in MULTIPLATFORM.md.
# Execute in Livebook's own process so its parser, runtimes and Kino are real.
[target | paths] = System.argv()
server = String.to_atom(target)
true = Node.connect(server)
root = Path.expand("..", __DIR__)

checker = ~S'''
defmodule JuliaLivebookCheck do
  def run(root, paths) do
    # Never associate a Livebook session with authoritative notebook files:
    # autosaving can otherwise persist runtime transformations and outputs.
    copy = Path.join(System.tmp_dir!(), "julia_elixir-livebooks-#{System.unique_integer([:positive])}")
    File.mkdir_p!(copy)

    try do
      File.cp_r!(Path.join(root, "livebooks"), Path.join(copy, "livebooks"))
      for name <- ["mix.exs", "lib", "priv", "scripts"] do
        File.cp_r!(Path.join(root, name), Path.join(copy, name))
      end
      run_copies(copy, paths)
    after
      File.rm_rf!(copy)
    end
  end

  defp run_copies(root, paths) do
    notebooks = Path.wildcard(Path.join(root, "livebooks/**/*.livemd"))
    selected = if paths == [], do: notebooks,
      else: Enum.filter(notebooks, &(Path.relative_to(&1, root) in paths))
    unknown = paths -- Enum.map(selected, &Path.relative_to(&1, root))
    if unknown != [], do: raise("Unknown notebook paths: #{inspect(unknown)}")
    if selected == [], do: raise("No notebooks found")

    Enum.map(selected, fn path ->
      name = Path.relative_to(path, root)
      IO.puts("CHECK #{name}")
      {notebook, %{warnings: []}} = Livebook.LiveMarkdown.notebook_from_livemd(File.read!(path))
      cells = for section <- Livebook.Notebook.all_sections(notebook),
                  %{__struct__: Livebook.Notebook.Cell.Code, source: source} = cell <- section.cells,
                  String.trim(source) != "", do: cell

      true = Enum.all?(cells, &(&1.language == :elixir))
      file = Livebook.FileSystem.File.local(path)
      {:ok, session} = Livebook.Sessions.create_session(notebook: notebook, file: file, origin: {:file, file})

      try do
        Livebook.Session.queue_full_evaluation(session.pid, [])
        await(session.pid, System.monotonic_time(:millisecond) + 3_600_000)
        IO.puts("PASS #{name}: #{length(cells)} cells")
        {name, {:passed, length(cells)}}
      after
        Livebook.Session.close(session.pid)
      end
    end)
  end

  defp await(pid, deadline) do
    data = Livebook.Session.get_data(pid)
    evals = for {_, %{eval: eval}} <- data.cell_infos, do: eval

    cond do
      Enum.any?(evals, &(&1.errored or &1.validity == :aborted)) ->
        errors = for section <- Livebook.Notebook.all_sections(data.notebook),
                     %{outputs: outputs} <- section.cells,
                     {_, %{type: :error} = error} <- outputs, do: error
        raise "Notebook evaluation failed: #{data.notebook.name}: #{inspect(errors)}"

      Enum.all?(evals, &(&1.validity == :evaluated)) -> :ok
      System.monotonic_time(:millisecond) >= deadline -> raise "Notebook evaluation timed out: #{data.notebook.name}"
      true ->
        Process.sleep(100)
        await(pid, deadline)
    end
  end
end
'''

case :rpc.call(
       server,
       Code,
       :eval_string,
       [checker <> "\nJuliaLivebookCheck.run(#{inspect(root)}, #{inspect(paths)})"],
       :infinity
     ) do
  {results, _binding} when is_list(results) -> IO.inspect(results, label: "Livebook checks")
  error -> raise "Livebook checks failed: #{inspect(error)}"
end
