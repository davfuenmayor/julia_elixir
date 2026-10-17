# Fast checks; check_livebooks.exs additionally uses Livebook's real runtime.
root = Path.expand("..", __DIR__)

Mix.install(
  [{:julia_elixir, path: root}, {:kino, "~> 0.19.0"}, {:kino_vega_lite, "~> 0.1.13"}],
  force: true
)

for path <- Path.wildcard(Path.join(root, "livebooks/**/*.livemd")) do
  # Livebook explicitly marks illustrative Elixir fences as Markdown.
  text =
    Regex.replace(
      ~r/<!-- livebook:\{"force_markdown":true\} -->\s*```[^\n]*\n.*?^```/ms,
      File.read!(path),
      ""
    )

  cells =
    Regex.scan(~r/^```elixir\n(.*?)^```/ms, text, capture: :all_but_first)
    |> List.flatten()

  Enum.each(cells, &Code.string_to_quoted!/1)

  # Dependencies match notebook setup. Keep bindings and imports between cells.
  initial = {[], Code.env_for_eval(file: path)}

  executable = Enum.reject(cells, &String.starts_with?(String.trim(&1), "Mix.install("))

  Enum.reduce(executable, initial, fn source, {binding, env} ->
    {_, binding, env} = Code.eval_quoted_with_env(Code.string_to_quoted!(source), binding, env)
    {binding, env}
  end)

  IO.puts("PASS #{Path.relative_to(path, root)}: #{length(cells)} cells")
end
