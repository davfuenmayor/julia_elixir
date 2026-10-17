defmodule JuliaElixir.RuntimeSetupTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  @moduletag timeout: 3_600_000

  @tag :tmp_dir
  test "setup declares packages in the active project even when globally loadable", %{
    tmp_dir: dir
  } do
    previous = System.get_env("JULIA_PROJECT")
    System.put_env("JULIA_PROJECT", dir)

    try do
      # Random is always loadable as a stdlib; that alone must not skip Pkg.add.
      capture_io(fn ->
        assert :ok = JuliaElixir.setup(packages: ["Random"])
        assert :ok = JuliaElixir.setup(packages: ["Random"])
      end)

      assert File.read!(Path.join(dir, "Project.toml")) =~ "Random ="
      assert File.regular?(Path.join(dir, "Manifest.toml"))
    after
      if previous,
        do: System.put_env("JULIA_PROJECT", previous),
        else: System.delete_env("JULIA_PROJECT")
    end
  end
end
