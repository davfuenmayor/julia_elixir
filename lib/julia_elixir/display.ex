defmodule JuliaElixir.Display do
  @moduledoc """
  Display helpers for Julia values decoded into Elixir terms.
  """

  @doc """
  Inspects a decoded Julia value without rendering integer lists as charlists.

  Elixir displays lists of printable integers as charlists, so a Julia vector
  like `[35, 75]` may appear as `~c"#K"` in newer Elixir versions. The underlying
  value is still `[35, 75]`; this helper only changes formatting.
  """
  @spec inspect_as_data(term(), keyword()) :: String.t()
  def inspect_as_data(term, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:pretty, true)
      |> Keyword.put_new(:charlists, :as_lists)

    inspect(term, opts)
  end
end
