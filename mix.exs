defmodule JuliaElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :julia_elixir,
      version: "0.1.0",
      elixir: "~> 1.14",
      compilers: Mix.compilers() ++ [:julia_resources],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      description:
        "A minimal Elixir to Julia bridge using BEAM Ports and Erlang External Term Format"
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl],
      mod: {JuliaElixir.Application, []}
    ]
  end

  defp deps do
    []
  end

  defp package do
    [
      licenses: ["MIT"],
      files:
        ~w(lib priv livebooks scripts .formatter.exs mix.exs README.md MULTIPLATFORM.md LICENSE),
      links: %{
        "Erlang External Term Format" => "https://www.erlang.org/doc/apps/erts/erl_ext_dist.html",
        "ErlangTerm.jl" => "https://github.com/helgee/ErlangTerm.jl",
        "Elixir Ports" => "https://hexdocs.pm/elixir/Port.html"
      }
    ]
  end

  defp docs do
    [
      main: "JuliaElixir",
      extras: ["README.md", "MULTIPLATFORM.md"]
    ]
  end
end

# Windows may lack permission to create Mix's usual priv directory symlink.
defmodule Mix.Tasks.Compile.JuliaResources do
  use Mix.Task.Compiler

  def run(_) do
    if match?({:win32, _}, :os.type()) do
      File.cp_r!("priv", Path.join(Mix.Project.app_path(), "priv"))
    end

    {:ok, []}
  end
end
