defmodule JuliaElixir.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      case Application.get_env(:julia_elixir, :start_default_session, false) do
        true -> [{JuliaElixir.Session, name: JuliaElixir}]
        false -> []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: JuliaElixir.Supervisor)
  end
end
