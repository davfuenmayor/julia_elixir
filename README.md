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

- Elixir 1.14+
- Julia available on `PATH`
- Julia package `ErlangTerm`

Install the Julia dependency once:

```julia
import Pkg
Pkg.add("ErlangTerm")
```

If your Julia project uses a custom environment, start sessions with a matching
`--project=...` argument.

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

Example notebooks are included in `livebook_examples/`:

- `getting_started.livemd` covers the core bridge workflow.
- `eirene_TDA.livemd` covers topological data analysis and persistent homology.
- `oscar_computer_algebra.livemd` covers computer algebra topics including
  matroids and finite/Galois fields.

Open them from Livebook and run the setup cells first. The Eirene notebook
installs Eirene from GitHub because the registered release may not resolve on
newer Julia versions. The OSCAR notebook installs OSCAR, which is large and may
take several minutes to precompile on first run.

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
surprising host applications at boot time when Julia or `ErlangTerm.jl` is not
installed.

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