defmodule JuliaElixir.Session do
  @moduledoc """
  A GenServer that owns one out-of-process Julia worker through a BEAM Port.

  The port uses `{:packet, 4}` framing and sends each payload as one ETF term:

  * `{:eval, request_id, code}`
  * `{:call, request_id, module_name, function_name, args}`
  * `{:ping, request_id}`

  Replies are shaped as `{:ok, request_id, value}` or
  `{:error, request_id, details}`.
  """

  use GenServer

  require Logger

  defstruct [:port, :next_id, :worker_path, pending: %{}]

  @type option ::
          {:name, GenServer.name()}
          | {:julia, String.t()}
          | {:worker_path, Path.t()}
          | {:julia_args, [String.t()]}
          | {:startup_timeout, timeout()}

  @doc """
  Starts a Julia session linked to the caller.

  Options:

  * `:name` - GenServer registration name.
  * `:julia` - Julia executable path. Defaults to config `:julia` or `"julia"`.
  * `:worker_path` - path to `julia_worker.jl`.
  * `:julia_args` - extra arguments before the worker path.
  * `:startup_timeout` - timeout for the initial worker ping. Defaults to
    config `:startup_timeout` or `5_000`.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {genserver_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  @doc """
  Starts an unlinked Julia session.

  Prefer this in interactive environments such as Livebook when a failed Julia
  worker should not terminate the evaluating process.
  """
  @spec start([option()]) :: GenServer.on_start()
  def start(opts \\ []) do
    {genserver_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start(__MODULE__, opts, genserver_opts)
  end

  @impl true
  def init(opts) do
    julia = Keyword.get(opts, :julia, Application.get_env(:julia_elixir, :julia, "julia"))
    worker_path = Keyword.get(opts, :worker_path, default_worker_path())
    julia_args = Keyword.get(opts, :julia_args, ["--startup-file=no", "--history-file=no"])

    startup_timeout =
      Keyword.get(
        opts,
        :startup_timeout,
        Application.get_env(:julia_elixir, :startup_timeout, 5_000)
      )

    port =
      Port.open({:spawn_executable, System.find_executable(julia) || julia}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:args, julia_args ++ [worker_path]}
      ])

    with :ok <- await_ready(port, startup_timeout) do
      {:ok, %__MODULE__{port: port, next_id: 1, worker_path: worker_path}}
    else
      {:error, reason} ->
        close_port(port)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:eval, code}, from, state) do
    send_request({:eval, state.next_id, code}, from, state)
  end

  def handle_call({:call, module_name, function_name, args}, from, state) do
    send_request({:call, state.next_id, module_name, function_name, args}, from, state)
  end

  def handle_call(:ping, from, state) do
    send_request({:ping, state.next_id}, from, state)
  end

  @impl true
  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    case :erlang.binary_to_term(packet) do
      {:ok, request_id, value} ->
        reply(request_id, {:ok, value}, state)

      {:error, request_id, details} ->
        reply(request_id, {:error, normalize_error(details)}, state)

      other ->
        Logger.warning("Julia worker sent unexpected packet: #{inspect(other)}")
        {:noreply, state}
    end
  rescue
    error ->
      Logger.warning("Could not decode Julia worker packet: #{Exception.message(error)}")
      {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    error = {:port_exit, status}

    Enum.each(state.pending, fn {_request_id, from} ->
      GenServer.reply(from, {:error, error})
    end)

    {:stop, error, %{state | pending: %{}}}
  end

  def handle_info(message, state) do
    Logger.debug("JuliaElixir.Session ignored message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    close_port(port)
  end

  def terminate(_reason, _state), do: :ok

  defp send_request(request, from, state) do
    request_id = elem(request, 1)

    case Port.command(state.port, :erlang.term_to_binary(request)) do
      true ->
        pending = Map.put(state.pending, request_id, from)
        {:noreply, %{state | pending: pending, next_id: request_id + 1}}

      false ->
        {:reply, {:error, :port_closed}, state}
    end
  end

  defp await_ready(port, timeout) do
    request_id = 0

    case Port.command(port, :erlang.term_to_binary({:ping, request_id})) do
      true ->
        receive do
          {^port, {:data, packet}} ->
            case :erlang.binary_to_term(packet) do
              {:ok, ^request_id, :pong} -> :ok
              {:error, ^request_id, details} -> {:error, normalize_error(details)}
              other -> {:error, {:unexpected_startup_reply, other}}
            end

          {^port, {:exit_status, status}} ->
            {:error, {:port_exit, status}}
        after
          timeout -> {:error, :startup_timeout}
        end

      false ->
        {:error, :port_closed}
    end
  rescue
    error -> {:error, {:startup_decode_error, Exception.message(error)}}
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  catch
    :error, _ -> :ok
  end

  defp reply(request_id, result, state) do
    case Map.pop(state.pending, request_id) do
      {nil, pending} ->
        Logger.warning("Julia worker replied for unknown request id #{inspect(request_id)}")
        {:noreply, %{state | pending: pending}}

      {from, pending} ->
        GenServer.reply(from, result)
        {:noreply, %{state | pending: pending}}
    end
  end

  defp normalize_error(details) when is_map(details), do: details
  defp normalize_error(details), do: %{message: inspect(details), raw: details}

  defp default_worker_path do
    case :code.priv_dir(:julia_elixir) do
      path when is_list(path) -> Path.join(List.to_string(path), "julia_worker.jl")
      {:error, _} -> Path.expand("../../priv/julia_worker.jl", __DIR__)
    end
  end
end
