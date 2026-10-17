defmodule JuliaElixir.RuntimeTest do
  use ExUnit.Case, async: true
  alias JuliaElixir.Runtime

  @tag :tmp_dir
  test "installs, reuses and repairs portable archives for every supported layout", %{
    tmp_dir: dir
  } do
    for target <- Map.keys(Runtime.releases()) do
      path =
        if String.contains?(target, "mingw"),
          do: "julia-1.13.2/bin/julia.exe",
          else: "julia-1.13.2/bin/julia"

      archive = Path.join(dir, target <> ".tar.gz")

      :ok =
        :erl_tar.create(String.to_charlist(archive), [{String.to_charlist(path), "fixture"}], [
          :compressed
        ])

      checksum = hash(archive)
      home = Path.join(dir, target <> " with spaces")
      assert :ok = Runtime.install(archive, home, target, checksum)
      assert :ok = Runtime.install(archive, home, target, checksum)
      relative = path |> String.split("/", parts: 2) |> List.last()
      executable = Path.join(home, relative)
      assert File.read!(executable) == "fixture"
      File.rm!(executable)
      assert :ok = Runtime.install(archive, home, target, checksum)
      assert File.read!(executable) == "fixture"
    end

    assert Path.wildcard(Path.join(dir, "*.unpack-*")) == []
  end

  @tag :tmp_dir
  test "rejects corruption and wrong-platform payloads before replacing a runtime", %{
    tmp_dir: dir
  } do
    archive = Path.join(dir, "bad.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(archive),
        [{String.to_charlist("julia/not-a-program"), "data"}],
        [:compressed]
      )

    home = Path.join(dir, "installed")
    File.mkdir_p!(home)
    File.write!(home <> "/keep", "previous installation")

    assert_raise RuntimeError, ~r/checksum mismatch/, fn ->
      Runtime.install(archive, home, "x86_64-linux-gnu", "wrong checksum")
    end

    assert_raise RuntimeError, ~r/missing its/, fn ->
      Runtime.install(archive, home, "x86_64-linux-gnu", hash(archive))
    end

    assert File.read!(home <> "/keep") == "previous installation"
    assert Path.wildcard(home <> ".unpack-*") == []
  end

  @tag :tmp_dir
  test "concurrent installers converge on one complete runtime", %{tmp_dir: dir} do
    archive = Path.join(dir, "julia.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(archive),
        [{String.to_charlist("julia/bin/julia"), "fixture"}],
        [:compressed]
      )

    checksum = hash(archive)
    home = Path.join(dir, "installed")

    1..3
    |> Task.async_stream(fn _ -> Runtime.install(archive, home, "x86_64-linux-gnu", checksum) end)
    |> Enum.each(fn result -> assert result == {:ok, :ok} end)

    assert File.read!(home <> "/bin/julia") == "fixture"
    assert Path.wildcard(home <> ".unpack-*") == []
  end

  test "selects official targets and rejects unsupported runtimes" do
    for {os, arch, expected} <- [
          {{:unix, :linux}, "x86_64-pc-linux-gnu", "x86_64-linux-gnu"},
          {{:unix, :linux}, "aarch64-unknown-linux-gnu", "aarch64-linux-gnu"},
          {{:unix, :darwin}, "arm64-apple-darwin", "aarch64-apple-darwin14"},
          {{:unix, :darwin}, "x86_64-apple-darwin", "x86_64-apple-darwin14"},
          {{:win32, :nt}, "AMD64", "x86_64-w64-mingw32"}
        ] do
      assert Runtime.target(os, arch) == expected
      assert Map.has_key?(Runtime.releases(), expected)
    end

    for {os, arch} <- [
          {{:unix, :linux}, "x86_64-linux-musl"},
          {{:win32, :nt}, "ARM64"},
          {{:unix, :linux}, "i686-linux-gnu"}
        ] do
      assert_raise RuntimeError, ~r/Unsupported Julia platform/, fn ->
        Runtime.target(os, arch)
      end
    end
  end

  test "missing explicit Julia never falls back to a download" do
    assert_raise RuntimeError, ~r/Julia executable not found/, fn ->
      Runtime.executable(julia: "/does/not/exist/julia")
    end
  end

  defp hash(file), do: :crypto.hash(:sha256, File.read!(file)) |> Base.encode16(case: :lower)
end
