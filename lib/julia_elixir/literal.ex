defmodule JuliaElixir.Literal do
  @moduledoc false

  def to_julia(value) when is_integer(value), do: Integer.to_string(value)

  def to_julia(value) when is_float(value) do
    Float.to_string(value)
  end

  def to_julia(true), do: "true"
  def to_julia(false), do: "false"
  def to_julia(nil), do: "nothing"
  def to_julia(:infinity), do: "Inf"
  def to_julia(:negative_infinity), do: "-Inf"
  def to_julia(:nan), do: "NaN"

  def to_julia(value) when is_binary(value) do
    inspect(value)
  end

  def to_julia(value) when is_atom(value) do
    "Symbol(" <> inspect(Atom.to_string(value)) <> ")"
  end

  def to_julia(value) when is_list(value) do
    "Any[" <> Enum.map_join(value, ", ", &to_julia/1) <> "]"
  end

  def to_julia(value) when is_tuple(value) do
    case Tuple.to_list(value) do
      [] -> "()"
      [item] -> "(" <> to_julia(item) <> ",)"
      items -> "(" <> Enum.map_join(items, ", ", &to_julia/1) <> ")"
    end
  end

  def to_julia(value) when is_map(value) do
    pairs =
      value
      |> Enum.map(fn {key, val} -> to_julia(key) <> " => " <> to_julia(val) end)
      |> Enum.join(", ")

    "Dict(" <> pairs <> ")"
  end
end
