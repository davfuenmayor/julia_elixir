defmodule JuliaElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :julia_elixir,
      version: "0.1.0",
      elixir: "~> 1.14",
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
      extra_applications: [:logger],
      mod: {JuliaElixir.Application, []}
    ]
  end

  defp deps do
    []
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib priv livebook_examples .formatter.exs mix.exs README.md LICENSE),
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
      extras: ["README.md"]
    ]
  end
end
