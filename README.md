# julia_elixir

`julia_elixir` is a small Elixir to Julia bridge built on BEAM Ports and the
Erlang External Term Format.

It starts a long-lived Julia worker as an external OS process, sends ETF-encoded
requests over stdin/stdout, and decodes ETF replies back into ordinary Elixir
terms. Julia stays out of the BEAM: there are no NIFs and no embedded Julia VM.

This library is intentionally minimal. It is useful for trusted local
experimentation, notebooks, prototypes, and stateful Julia sessions from Elixir.
It is not a sandbox.

## Features

- Out-of-process Julia workers owned by Elixir processes
- BEAM Port boundary with `{:packet, 4}` framing
- ETF wire format via `:erlang.term_to_binary/1`, `:erlang.binary_to_term/1`,
  and [`ErlangTerm.jl`](https://github.com/helgee/ErlangTerm.jl)
- Stateful Julia sessions: variables, functions, and loaded packages persist
  across calls
- Arbitrary Julia `eval` for trusted workflows
- Direct Julia function calls with `call/3`
- Convenience rendering of Elixir values into Julia literals
- Livebook examples for getting started, topological data analysis with
  Eirene.jl, and computer algebra with OSCAR.jl

## Requirements

- Elixir 1.14+ and OTP 25+
- Internet access on first use, and writable cache and Julia package directories

Julia 1.13.2 is downloaded automatically from Julia's official distribution,
verified with a pinned SHA-256 checksum, and reused from the user cache. No
Julia installation or compiler is required. The ETF transport is bundled.

Automatic downloads cover Linux glibc x86-64/ARM64, macOS Intel/Apple Silicon,
and Windows x86-64. musl and Windows ARM64 are not supported automatically.
This is a delivery matrix, not a claim that every target has been tested;
see [MULTIPLATFORM.md](MULTIPLATFORM.md) for validation and remaining checks.

The initial runtime download is roughly 220–320 MB. Scientific packages,
particularly OSCAR, need additional downloads, disk space and precompilation
time. Subsequent runs reuse them.

## Installation

Install directly from GitHub:

```elixir
def deps do
  [
    {:julia_elixir, github: "davfuenmayor/julia_elixir"}
  ]
end
```

## Quick Start

Start a named session explicitly:

```elixir
{:ok, _pid} = JuliaElixir.start_link(name: JuliaElixir)

{:ok, 3} = JuliaElixir.eval("1 + 2")

41 = JuliaElixir.eval!("x = 41")
42 = JuliaElixir.eval!("x + 1")

{:ok, 3.0} = JuliaElixir.call("sqrt", [9.0], module: "Base")
```

Session state lives in the Julia OS process. When the session stops, that state
is gone.

Multiline snippets and direct Julia function calls are supported:

```elixir
JuliaElixir.eval!(
  """
  function hypotenuse(a, b)
    sqrt(a^2 + b^2)
  end

  hypotenuse(3, 4)
  """
)

JuliaElixir.call!("hypotenuse", [5, 12])
```

Elixir numbers and booleans can be interpolated directly into trusted Julia
snippets:

```elixir
a = 5
b = 12
enabled = true

JuliaElixir.eval!(
  """
  Dict(
    :distance => hypotenuse(#{a}, #{b}),
    :enabled => #{enabled}
  )
  """
)
```

Use `JuliaElixir.literal/1` when interpolating structured values or values that
need Julia syntax, such as lists, tuples, maps, strings, atoms, `nil`,
`:infinity`, `:negative_infinity`, or `:nan`:

```elixir
flags = [true, false, true]
metadata = %{label: "demo", active: true, missing: nil}

JuliaElixir.eval!(
  """
  flags = #{JuliaElixir.literal(flags)}
  metadata = #{JuliaElixir.literal(metadata)}

  Dict(:label => metadata[:label], :true_count => count(identity, flags))
  """
)
```

`literal/1` is a code-generation helper, not a security boundary. Do not
interpolate untrusted input into Julia source.

## Livebook Examples

Example notebooks are included in `livebooks/`:

- `getting_started.livemd` covers the core bridge workflow.
- `eirene_TDA.livemd` covers topological data analysis and persistent homology.
- `oscar_computer_algebra.livemd` covers computer algebra topics including
  matroids and finite/Galois fields.

Open a notebook **from this checkout** in Livebook and choose **Evaluate all**.
Setup obtains Julia and the required packages automatically; the first run
can take many minutes, especially for OSCAR. Keep the notebook beside its parent
project directory so its local dependency can be found. Merely importing the notebook text into
an unrelated directory does not copy the project.

Eirene uses a pinned upstream revision for modern Julia compatibility. The two
science notebooks use separate cached Julia projects to keep dependencies apart.
OSCAR supports Linux and macOS; Windows users must run **Livebook and Julia inside
WSL**, following [OSCAR's Windows instructions](https://www.oscar-system.org/install/win/).
The core bridge also supports native Windows.

## Supervision

Add a Julia session to your application supervision tree:

```elixir
children = [
  {JuliaElixir, name: JuliaElixir}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

or start several independent Julia sessions:

```elixir
children = [
  {JuliaElixir, name: :julia_a},
  {JuliaElixir, name: :julia_b, julia_args: ["--startup-file=no", "--project=/path/to/project"]}
]
```

`JuliaElixir.start_link/1` starts a session linked to the caller. In interactive
environments such as Livebook, prefer the unlinked `JuliaElixir.start/1`:

```elixir
{:ok, _pid} = JuliaElixir.start(name: :notebook_julia)
JuliaElixir.eval!("versioninfo()", server: :notebook_julia)
```

Stop a session explicitly:

```elixir
JuliaElixir.stop(:notebook_julia)
```

Stopping the session closes the Port. The Julia worker reads EOF on stdin and
exits.

## Configuration

By default, the application does **not** auto-start a Julia process. This avoids
downloads and worker processes at application boot. Setup or starting a session
obtains the runtime when needed.

You can opt into a default supervised session registered as `JuliaElixir`:

```elixir
config :julia_elixir,
  start_default_session: true,
  julia: "/usr/local/bin/julia",
  startup_timeout: 10_000
```

Custom session options:

```elixir
JuliaElixir.Session.start_link(
  name: :custom_julia,
  julia: "julia",
  julia_args: ["--startup-file=no", "--history-file=no", "--project=/path/to/project"],
  startup_timeout: 20_000
)
```

To prepare packages explicitly, call `JuliaElixir.setup(packages: ["Oscar"])`.
Julia's usual project and depot settings apply, including `JULIA_PROJECT` and
`JULIA_DEPOT_PATH`. A custom session's `--project` must match the environment
where its packages were installed.

To use an existing or locally compiled Julia, set `JULIA_ELIXIR_EXECUTABLE` to
its executable, configure `:julia`, or pass `julia: "/path/to/julia"` to a
session. macOS and Windows users can follow Julia's
[source build instructions](https://docs.julialang.org/en/v1/devdocs/build/build/)
and select the resulting binary the same way. Keep its complete runtime directory;
copying only the executable is insufficient. A local build can target your CPU,
but should be validated with your packages before replacing the pinned runtime.

`JULIA_ELIXIR_CACHE` relocates downloaded runtimes. For offline installation,
`JULIA_ELIXIR_ARCHIVE` selects the official archive for your platform, still
checked against the pinned checksum. Package dependencies must also be cached.
`JULIA_ELIXIR_CACERTS` (or `SSL_CERT_FILE`) selects a PEM CA bundle when needed.

## Data Mapping

The worker recursively normalizes values before ETF serialization.

| Julia value | Elixir value |
| --- | --- |
| `Int`, integer types | integer |
| `Float64`, finite floats | float |
| `String` | binary string |
| `Symbol("name")` | atom |
| `true`, `false` | `true`, `false` |
| `nothing` | `nil` |
| `Inf` | `:infinity` |
| `-Inf` | `:negative_infinity` |
| `NaN` | `:nan` |
| `Tuple` | tuple |
| `AbstractArray` | list |
| `Dict` | map |

Elixir call arguments are normalized back for Julia calls:

| Elixir value | Julia value |
| --- | --- |
| `true`, `false` | `true`, `false` |
| `nil` | `nothing` |
| `:infinity` | `Inf` |
| `:negative_infinity` | `-Inf` |
| `:nan` | `NaN` |
| lists, tuples, maps | recursively normalized containers |

Two display caveats matter in practice:

- Julia may promote booleans in mixed numeric arrays before the bridge sees
  them. For example, `[true, false, 1, 0]` is a Julia integer vector. Use
  `Any[true, false, 1, 0]` when preserving mixed booleans and integers matters.
- Elixir displays lists of printable integers as charlists. A decoded Julia
  vector like `[35, 75]` may appear as `~c"#K"`. The value is still `[35, 75]`.
  Use `JuliaElixir.inspect_as_data/2` or `inspect(value, charlists: :as_lists)`
  when inspecting nested integer vectors.

Unsupported Julia objects fall back to `repr(value)` through `ErlangTerm.jl`.
For large Julia objects, prefer returning compact summaries or keeping objects
in Julia state and retrieving fields on demand.

## Protocol

Elixir sends ETF tuples:

```elixir
{:eval, request_id, code}
{:call, request_id, module_name, function_name, args}
{:ping, request_id}
```

Julia replies with:

```elixir
{:ok, request_id, value}
{:error, request_id, %{class: class, message: message, stacktrace: stacktrace}}
```

The Port uses `{:packet, 4}`, so each ETF payload is length-prefixed by the
runtime.

## Safety

`JuliaElixir.eval/2` runs arbitrary Julia code in the worker process. That code
can read files, spawn OS processes, allocate memory, mutate session state, and
use any Julia package available in the worker environment.

Only use `eval` and `literal` with trusted local input.
