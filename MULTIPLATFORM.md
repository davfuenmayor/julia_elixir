# Julia runtime delivery and validation

This wrapper uses Ports, not a NIF. Its Elixir code requires no native build.
Use Elixir 1.14+ with OTP 25+ (for the system CA certificate API).
On first use it downloads the complete official Julia 1.13.2 runtime, verifies
the SHA-256 in `priv/julia_releases.exs`, and extracts it into the user cache.
Downloads and unpacking use OTP; no curl, tar, C compiler or Rust toolchain is
required on the user's machine. The vendored MIT-licensed ErlangTerm.jl transport
removes the separate `Pkg.add("ErlangTerm")` step.

## Targets

| Runtime | Delivery | Validation in this container |
| --- | --- | --- |
| Linux glibc x86-64 | Official tar.gz | 26 real tests and Port smoke passed |
| Linux glibc ARM64 | Official tar.gz | Real Port smoke passed under QEMU, longer test timeouts |
| macOS Intel | Official tar.gz | Native runner unavailable; execution pending |
| macOS Apple Silicon | Official tar.gz | Native runner unavailable; execution pending |
| Windows x86-64 | Official tar.gz | 26 real tests and Port smoke passed under Wine |

musl, 32-bit systems and native Windows ARM64 are outside the automatic matrix.
The runtime must meet Julia's upstream OS/CPU requirements. Native machines are
still needed to establish minimum supported OS versions and validate performance;
emulation does not establish either.

OSCAR does not support native Windows. Run Livebook and Julia together inside
WSL for that notebook: https://www.oscar-system.org/install/win/ . Eirene and
OSCAR also download their own package artifacts. Runtime availability does not
guarantee every Julia package supports every target.
The two science notebooks set `JULIA_PROJECT` to separate user-cache projects
before setup. Their workers inherit this setting. This prevents installing
Eirene first from silently selecting an older OSCAR in a shared default project.
Julia's package/artifact depot remains shared, so downloads can still be reused.

## Build and installation

```
mix deps.get
mix compile --warnings-as-errors
mix test
mix run scripts/check_port.exs
mix hex.build
```

Only the worker, transport and release manifest are packaged, not large Julia
archives. Windows builds copy `priv` explicitly because symlinks may be disabled.
The macOS tarballs use a portable `julia-1.13.2/bin/julia` tree, rather than the
`.app/Contents/Resources` layout of the DMG installer; the downloader uses tarballs.
Verify a built package in a fresh project, including a path containing spaces,
without Julia on PATH. Test once with an empty runtime cache and again offline
with the populated cache. A first run needs HTTPS access, trusted CA roots,
space for the archive and unpacked runtime, and permission to execute cached files.

`JULIA_ELIXIR_EXECUTABLE` or the session `:julia` option selects your own Julia.
Use Julia's [build guide](https://docs.julialang.org/en/v1/devdocs/build/build/),
including its macOS and Windows platform instructions. Retain the complete
build/install tree and validate the same worker and notebook checks. A custom
Julia does not need a rebuild of this wrapper.

For air-gapped machines, supply the matching archive via `JULIA_ELIXIR_ARCHIVE`
and cache packages/artifacts in Julia's depot beforehand. The override does not
bypass checksum verification. Set `JULIA_ELIXIR_CACHE` to relocate the cache.
`JULIA_ELIXIR_CACERTS` selects a PEM CA bundle for the runtime download;
Julia's own package downloader uses `JULIA_SSL_CA_ROOTS_PATH` when a custom CA
bundle is needed.

## Test procedure

`mix test` runs the bridge against real Julia: no conditional success or skipped
integration tests when Julia is missing. The installer tests exercise all five
archive layouts, checksums, incomplete installations and concurrent extraction.
An additional real setup test checks that a globally loadable stdlib is declared
in the selected project, and that repeated setup reuses the environment.
`scripts/check_port.exs` checks framing, UTF-8, containers, state, functions,
errors, stdout isolation and concurrent callers through a real Port.

Run `elixir scripts/check_livebook_cells.exs` to execute notebook Elixir cells
with shared bindings. This installs the notebooks' Elixir dependencies and Julia
packages, and can take much longer than the bridge tests.

For actual Livebook runtime checks, start a local server with matching node
cookie, for example:

```
LIVEBOOK_DISTRIBUTION=name LIVEBOOK_NODE=jlbooks@127.0.0.1 \
LIVEBOOK_COOKIE=julia-check LIVEBOOK_PORT=8291 livebook server
elixir --name jlcheck@127.0.0.1 --cookie julia-check \
  scripts/check_livebooks.exs jlbooks@127.0.0.1
```

The checker evaluates disposable copies so Livebook autosave cannot alter the
authoritative lessons. Only notebook setup cells may change in this work.
Native macOS and Windows runners should repeat these checks; on Windows use
the core notebook and run OSCAR separately in WSL.

All three notebooks passed in Livebook 0.19.9 on Linux: Getting Started (27
cells), Eirene TDA (21) and OSCAR computer algebra (17), including plotting and
the complete algebra computations. The isolated science projects resolved Eirene
1.4.0 at the revision below and OSCAR 1.8.2 with Julia 1.13.2.
Getting Started's 26 executable cells after `Mix.install` also passed under
Windows OTP/Wine.
The built Hex archive also passed the real Port smoke after extraction into a
fresh directory containing spaces, with PATH cleared before starting Julia.
Notebook comparison confirms that all prose and lesson cells remain unchanged;
only the dependency/runtime setup and environment-check cells differ.

## Updating upstream

Use Julia's [official downloads](https://julialang.org/downloads/manual-downloads/)
and `https://julialang-s3.julialang.org/bin/versions.json` to update the version,
all five URLs and SHA-256 values together. Re-run installation, package loading
and complete notebooks before adopting a release. Eirene is pinned to upstream
revision `16622d0aa1d7237895919e7fbdc1e8a6196425ab`; the registered older release
has dependency constraints that can prevent modern Julia installation.

ErlangTerm.jl 0.1.1 is vendored at revision
`9b3f18a0dc8e8fafda6ac90d84660b2ea5efe6e6`; its source and license are retained
in `priv/vendor/ErlangTerm`. Julia and downloaded package artifacts retain their
own licenses and notices in their complete distribution directories.

## Remaining validation

- Repeat Windows bridge and notebook checks on native Windows.
- Repeat ARM64 bridge and notebook checks on native ARM64 Linux.
- Obtain both macOS runners for fresh-cache installation and notebook runs.

ARM64 execution uses the official ARM64 Julia with QEMU user emulation and an
ARM64 glibc sysroot, controlled by the native x86-64 BEAM. Julia starts and basic
ETF evaluations work. The first exception evaluation exceeded the normal
30-second call timeout under emulation; the complete smoke passed with
600-second test-only timeouts. Production defaults are unchanged. Native ARM64
BEAM and performance validation remain pending.

To reproduce the emulated Port check, extract the matching official archive
and set `JULIA_ELIXIR_EXECUTABLE` to a shell wrapper that executes
`qemu-aarch64-static -L /path/to/arm64-sysroot /path/to/arm64-julia/bin/julia "$@"`.
Run `scripts/check_port.exs`, allowing longer startup and call timeouts for JIT
compilation. Native ARM64 validation must additionally exercise automatic target
selection using an ARM64 BEAM.

Windows checks used Windows OTP 29.1.1 and Elixir 1.20.4 under Wine 10, with the
official Windows Julia installed through this module's archive installer.
The project was copied into a separate Windows build directory, then compiled
and tested by Windows Mix. This exposed and verified the `priv` copy fix. The
Windows archive was prefetched; checksum verification, extraction and execution
used the wrapper. A separate Windows OTP probe passed certificate-verified HTTPS
streaming of Julia's official release index into the cache. The notebook cell
check executes real Julia through Windows Ports; it does not
validate a Windows Livebook server or native Windows filesystem behavior.
