defmodule JuliaElixir.Runtime do
  @moduledoc """
  Installs checksum-verified official Julia binaries into the user cache.

  `JULIA_ELIXIR_EXECUTABLE` or the session's `:julia` option selects an existing
  executable. `JULIA_ELIXIR_CACHE` relocates the cache; `JULIA_ELIXIR_ARCHIVE`
  supplies an offline official archive, checked against the pinned checksum.
  """

  require Logger
  @version "1.13.2"
  @manifest Path.expand("../../priv/julia_releases.exs", __DIR__)
  @external_resource @manifest
  @releases elem(Code.eval_file(@manifest), 0)

  def version, do: @version
  def releases, do: @releases

  def executable(opts \\ []) do
    explicit =
      Keyword.get(opts, :julia) || Application.get_env(:julia_elixir, :julia) ||
        System.get_env("JULIA_ELIXIR_EXECUTABLE")

    if explicit do
      System.find_executable(explicit) ||
        raise "Julia executable not found: #{explicit}"
    else
      if :erlang.system_info(:wordsize) != 8, do: raise("Julia requires a 64-bit BEAM")

      arch =
        if :os.type() == {:win32, :nt},
          do: System.get_env("PROCESSOR_ARCHITECTURE", "unknown"),
          else: to_string(:erlang.system_info(:system_architecture))

      triplet = target(:os.type(), arch)

      cache =
        System.get_env("JULIA_ELIXIR_CACHE") ||
          :filename.basedir(:user_cache, String.to_charlist("julia_elixir")) |> to_string()

      home = Path.join(cache, "julia-#{@version}-#{triplet}")
      release = Map.fetch!(@releases, triplet)

      :global.trans({{__MODULE__, home}, self()}, fn ->
        unless installed?(home, triplet, release.sha256) do
          File.mkdir_p!(cache)

          archive =
            System.get_env("JULIA_ELIXIR_ARCHIVE") || Path.join(cache, Path.basename(release.url))

          if System.get_env("JULIA_ELIXIR_ARCHIVE") && !File.regular?(archive),
            do: raise("Julia offline archive not found: #{archive}")

          unless File.regular?(archive), do: download(release.url, archive, release.sha256)
          install(archive, home, triplet, release.sha256)
        end

        Path.join(home, binary_path(triplet))
      end)
    end
  end

  def setup(opts \\ []) do
    packages = Keyword.get(opts, :packages, [])

    if :os.type() == {:win32, :nt} and "Oscar" in packages do
      raise "OSCAR requires Linux/WSL or macOS: https://www.oscar-system.org/install/win/"
    end

    julia = executable(opts)

    unless packages == [] do
      # Pass package names as data.
      code = """
      import Pkg
      for name in ARGS
          if !haskey(Pkg.project().dependencies, name)
              if name == "Eirene"
                  Pkg.add(Pkg.PackageSpec(url="https://github.com/henselman-petrusek/Eirene.jl", rev="16622d0aa1d7237895919e7fbdc1e8a6196425ab"))
              else
                  Pkg.add(name)
              end
          end
      end
      Pkg.instantiate()
      Pkg.precompile()
      """

      {_output, status} =
        System.cmd(
          julia,
          ["--startup-file=no", "--history-file=no", "-e", code, "--" | packages],
          stderr_to_stdout: true,
          into: IO.stream(:stdio, :line),
          env: [{"JULIA_NUM_PRECOMPILE_TASKS", System.get_env("JULIA_NUM_PRECOMPILE_TASKS", "2")}]
        )

      if status != 0,
        do: raise("Julia package installation failed (exit #{status}); see output above")
    end

    :ok
  end

  def target(os, arch) do
    cpu = arch |> String.split("-") |> hd()

    case {os, cpu, String.contains?(arch, "musl")} do
      {{:unix, :linux}, "x86_64", false} -> "x86_64-linux-gnu"
      {{:unix, :linux}, "aarch64", false} -> "aarch64-linux-gnu"
      {{:unix, :darwin}, "x86_64", false} -> "x86_64-apple-darwin14"
      {{:unix, :darwin}, cpu, false} when cpu in ["arm64", "aarch64"] -> "aarch64-apple-darwin14"
      {{:win32, :nt}, cpu, false} when cpu in ["AMD64", "amd64", "x86_64"] -> "x86_64-w64-mingw32"
      _ -> raise "Unsupported Julia platform: #{inspect(os)} / #{arch}. See MULTIPLATFORM.md"
    end
  end

  defp binary_path(target) do
    if String.contains?(target, "mingw"), do: "bin/julia.exe", else: "bin/julia"
  end

  defp installed?(home, target, checksum) do
    File.read(Path.join(home, ".archive-sha256")) == {:ok, checksum} and
      File.regular?(Path.join(home, binary_path(target)))
  end

  @doc false
  def install(archive, home, target, expected) do
    verify_archive!(archive, expected)
    staging = home <> ".unpack-#{System.pid()}-#{System.unique_integer([:positive])}"
    File.mkdir_p!(staging)

    try do
      case :erl_tar.extract(String.to_charlist(archive), [
             :compressed,
             {:cwd, String.to_charlist(staging)}
           ]) do
        :ok -> :ok
        {:error, reason} -> raise "Cannot unpack Julia: #{inspect(reason)}"
      end

      root =
        File.ls!(staging)
        |> Enum.map(&Path.join(staging, &1))
        |> Enum.find(&File.regular?(Path.join(&1, binary_path(target))))

      unless root, do: raise("Julia archive is missing its #{target} executable")
      File.write!(Path.join(root, ".archive-sha256"), expected)

      unless installed?(home, target, expected) do
        case File.rename(root, home) do
          :ok ->
            :ok

          {:error, reason} ->
            unless installed?(home, target, expected) do
              File.rm_rf!(home)

              case File.rename(root, home) do
                :ok ->
                  :ok

                {:error, retry} ->
                  unless installed?(home, target, expected),
                    do: raise("Cannot install Julia: #{inspect({reason, retry})}")
              end
            end
        end
      end
    after
      File.rm_rf!(staging)
    end

    :ok
  end

  defp verify_archive!(archive, expected) do
    actual =
      File.open!(archive, [:read, :binary], fn io ->
        Stream.repeatedly(fn -> IO.binread(io, 1024 * 1024) end)
        |> Stream.take_while(&(&1 != :eof))
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)
      end)

    unless actual == expected, do: raise("Julia archive checksum mismatch: #{archive}")
  end

  defp download(url, destination, expected) do
    Logger.info("Downloading Julia #{@version} into the user cache (first use)")
    temporary = destination <> ".download-#{System.pid()}-#{System.unique_integer([:positive])}"
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    ca =
      case System.get_env("JULIA_ELIXIR_CACERTS") || System.get_env("SSL_CERT_FILE") do
        nil -> [cacerts: :public_key.cacerts_get()]
        path -> [cacertfile: String.to_charlist(path)]
      end

    ssl =
      [
        verify: :verify_peer,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ] ++ ca

    try do
      case :httpc.request(
             :get,
             {String.to_charlist(url), []},
             [ssl: ssl, connect_timeout: 30_000, timeout: 3_600_000],
             stream: String.to_charlist(temporary)
           ) do
        {:ok, :saved_to_file} ->
          verify_archive!(temporary, expected)
          File.rename!(temporary, destination)

        error ->
          raise "Julia download failed: #{inspect(error)}"
      end
    after
      File.rm(temporary)
    end
  end
end
