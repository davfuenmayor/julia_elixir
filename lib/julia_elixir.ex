defmodule JuliaElixir do
  @moduledoc """
  Minimal Elixir to Julia bridge using a BEAM Port and Erlang External Term Format.

  `JuliaElixir` exposes a small API against a Julia session process. You can
  start sessions manually, add `JuliaElixir.Session` to your supervision tree,
  or configure the application to start a default session registered as
  `JuliaElixir`.

  Arbitrary Julia evaluation is intentionally supported for experimentation:

      {:ok, 3} = JuliaElixir.eval("1 + 2")
      41 = JuliaElixir.eval!("x = 41")
      42 = JuliaElixir.eval!("x + 1")

  This is unsafe for untrusted input. Treat it like a local REPL.
  """

  alias JuliaElixir.Session

  @doc "Prepares Julia and optionally installs named Julia packages for notebook sessions."
  def setup(opts \\ []), do: JuliaElixir.Runtime.setup(opts)

  @typedoc "A Julia session process or registered name."
  @type server :: GenServer.server()

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, JuliaElixir),
      start: {JuliaElixir.Session, :start_link, [opts]}
    }
  end

  @doc """
  Starts a Julia session process linked to the caller.

  This is useful for explicit session management or when adding the session to a
  supervisor.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Session.start_link(opts)
  end

  @doc """
  Starts an unlinked Julia session process.

  This is useful in interactive environments such as Livebook, where a worker
  crash should be returned as an error instead of taking down the evaluator.
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts \\ []) do
    Session.start(opts)
  end

  @doc """
  Evaluates Julia source code in the session's `Main` module.

  State is preserved in the long-lived Julia process:

      JuliaElixir.eval!("answer = 42")
      JuliaElixir.eval!("answer")
      #=> 42
  """
  @spec eval(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def eval(code, opts \\ []) when is_binary(code) do
    server = Keyword.get(opts, :server, JuliaElixir)
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(server, {:eval, code}, timeout)
  end

  @doc """
  Evaluates Julia source code and returns the value or raises on error.
  """
  @spec eval!(String.t(), keyword()) :: term()
  def eval!(code, opts \\ []) do
    case eval(code, opts) do
      {:ok, value} -> value
      {:error, error} -> raise JuliaElixir.Error, error
    end
  end

  @doc """
  Converts an Elixir value into a Julia literal string for interpolation.

  This is a convenience helper for trusted local `eval` snippets:

      a = 3
      b = 4
      JuliaElixir.eval!("hypotenuse(\#{JuliaElixir.literal(a)}, \#{JuliaElixir.literal(b)})")

  Supported values are numbers, booleans, `nil`, strings, atoms, lists, tuples,
  and maps. Lists are emitted as `Any[...]` so mixed booleans and integers keep
  their Elixir meaning instead of being promoted by Julia.

  This helper is for code generation, not sandboxing. Do not interpolate
  untrusted input into Julia source.
  """
  @spec literal(term()) :: String.t()
  def literal(value), do: JuliaElixir.Literal.to_julia(value)

  @doc """
  Inspects a decoded Julia value without rendering integer lists as charlists.

  This is useful for nested Julia vectors. Elixir may display `[35, 75]` as a
  charlist, such as `~c"#K"`, even though the value is still the list
  `[35, 75]`.
  """
  @spec inspect_as_data(term(), keyword()) :: String.t()
  def inspect_as_data(term, opts \\ []) do
    JuliaElixir.Display.inspect_as_data(term, opts)
  end

  @doc """
  Calls a Julia function by name.

  By default functions are resolved from `Main`. Pass `module: "Base"` or any
  other module path accepted by Julia's `eval(Meta.parse(module_name))`.

      JuliaElixir.call("sqrt", [9.0], module: "Base")
      #=> {:ok, 3.0}
  """
  @spec call(String.t(), list(), keyword()) :: {:ok, term()} | {:error, term()}
  def call(function, args \\ [], opts \\ []) when is_binary(function) and is_list(args) do
    server = Keyword.get(opts, :server, JuliaElixir)
    timeout = Keyword.get(opts, :timeout, 30_000)
    module_name = Keyword.get(opts, :module, "Main")

    GenServer.call(server, {:call, module_name, function, args}, timeout)
  end

  @doc """
  Calls a Julia function and returns the value or raises on error.
  """
  @spec call!(String.t(), list(), keyword()) :: term()
  def call!(function, args \\ [], opts \\ []) do
    case call(function, args, opts) do
      {:ok, value} -> value
      {:error, error} -> raise JuliaElixir.Error, error
    end
  end

  @doc """
  Stops a Julia session.
  """
  @spec stop(server(), timeout()) :: :ok
  def stop(server \\ JuliaElixir, timeout \\ 5_000) do
    GenServer.stop(server, :normal, timeout)
  end
end
