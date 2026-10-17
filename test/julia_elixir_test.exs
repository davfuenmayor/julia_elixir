defmodule JuliaElixirTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 3_600_000

  setup do
    start_supervised!({JuliaElixir.Session, name: __MODULE__.Session})
    {:ok, server: __MODULE__.Session}
  end

  test "eval preserves Julia state across calls", %{server: server} do
    assert {:ok, 3} = JuliaElixir.eval("1 + 2", server: server)
    assert {:ok, 41} = JuliaElixir.eval("x = 41", server: server)
    assert {:ok, 42} = JuliaElixir.eval("x + 1", server: server)
  end

  test "eval accepts multi-expression Julia snippets", %{server: server} do
    assert {:ok, "total: 6"} =
             JuliaElixir.eval(
               """
               values = [1, 2, 3]
               total = sum(values)
               "total: " * string(total)
               """,
               server: server
             )
  end

  test "literal renders Elixir values as Julia source" do
    assert JuliaElixir.literal(3) == "3"
    assert JuliaElixir.literal(3.5) == "3.5"
    assert JuliaElixir.literal(true) == "true"
    assert JuliaElixir.literal(false) == "false"
    assert JuliaElixir.literal(nil) == "nothing"
    assert JuliaElixir.literal(:infinity) == "Inf"
    assert JuliaElixir.literal(:negative_infinity) == "-Inf"
    assert JuliaElixir.literal(:nan) == "NaN"
    assert JuliaElixir.literal("hello") == ~s("hello")
    assert JuliaElixir.literal(:ok) == ~s|Symbol("ok")|
    assert JuliaElixir.literal([true, false, 1, 0]) == "Any[true, false, 1, 0]"
    assert JuliaElixir.literal({:flags, true, false}) == ~s|(Symbol("flags"), true, false)|
    assert JuliaElixir.literal({:only}) == ~s|(Symbol("only"),)|
  end

  test "literal renders maps as Julia Dict source" do
    assert JuliaElixir.literal(%{ok: true}) == ~s|Dict(Symbol("ok") => true)|

    rendered = JuliaElixir.literal(%{"items" => [1, true], :status => {:ok, nil}})

    assert rendered =~ ~s|"items" => Any[1, true]|
    assert rendered =~ ~s|Symbol("status") => (Symbol("ok"), nothing)|
    assert String.starts_with?(rendered, "Dict(")
  end

  test "eval supports interpolation of numeric Elixir literals", %{server: server} do
    JuliaElixir.eval!(
      """
      function hypotenuse(a, b)
        sqrt(a^2 + b^2)
      end
      """,
      server: server
    )

    a = 5
    b = 12

    assert 13.0 ==
             JuliaElixir.eval!(
               "hypotenuse(#{JuliaElixir.literal(a)}, #{JuliaElixir.literal(b)})",
               server: server
             )
  end

  test "eval supports multiline interpolation of booleans lists tuples and maps", %{
    server: server
  } do
    flags = [true, false, true]
    point = {3, 4}
    metadata = %{label: "demo", active: true, missing: nil}

    assert %{
             active: true,
             false_count: 1,
             label: "demo",
             missing_is_nothing: true,
             norm: 5.0,
             true_count: 2
           } =
             JuliaElixir.eval!(
               """
               flags = #{JuliaElixir.literal(flags)}
               point = #{JuliaElixir.literal(point)}
               metadata = #{JuliaElixir.literal(metadata)}

               Dict(
                 :active => metadata[:active],
                 :false_count => count(x -> x == false, flags),
                 :label => metadata[:label],
                 :missing_is_nothing => isnothing(metadata[:missing]),
                 :norm => sqrt(point[1]^2 + point[2]^2),
                 :true_count => count(identity, flags)
               )
               """,
               server: server
             )
  end

  test "eval preserves Julia booleans as Elixir booleans", %{server: server} do
    assert {:ok, true} = JuliaElixir.eval("true", server: server)
    assert {:ok, false} = JuliaElixir.eval("false", server: server)
  end

  test "eval preserves booleans inside common container types", %{server: server} do
    assert {:ok, [true, false]} = JuliaElixir.eval("[true, false]", server: server)

    assert {:ok, [true, false, 1, 0]} =
             JuliaElixir.eval("Any[true, false, 1, 0]", server: server)

    assert {:ok, {:flags, true, false}} =
             JuliaElixir.eval("(:flags, true, false)", server: server)

    assert {:ok, %{ok: true, error: false, one: 1, zero: 0}} =
             JuliaElixir.eval(
               "Dict(:ok => true, :error => false, :one => 1, :zero => 0)",
               server: server
             )
  end

  test "eval reflects Julia promotion before bridge serialization", %{server: server} do
    assert {:ok, [1, 0, 1, 0]} = JuliaElixir.eval("[true, false, 1, 0]", server: server)
  end

  test "eval preserves nested booleans and nil values", %{server: server} do
    assert {:ok, %{items: [true, %{nested: false}], value: nil}} =
             JuliaElixir.eval(
               "Dict(:items => Any[true, Dict(:nested => false)], :value => nothing)",
               server: server
             )
  end

  test "eval maps Julia non-finite floats to Elixir atoms", %{server: server} do
    assert {:ok, %{maxrad: :infinity, minrad: :negative_infinity, missing: :nan}} =
             JuliaElixir.eval(
               "Dict(:maxrad => Inf, :minrad => -Inf, :missing => NaN)",
               server: server
             )
  end

  test "call maps Elixir non-finite atoms into Julia floats", %{server: server} do
    assert {:ok, true} = JuliaElixir.call("isinf", [:infinity], module: "Base", server: server)

    assert {:ok, true} =
             JuliaElixir.call("isinf", [:negative_infinity], module: "Base", server: server)

    assert {:ok, true} = JuliaElixir.call("isnan", [:nan], module: "Base", server: server)
  end

  test "eval can return Eirene-style input metadata with infinities", %{server: server} do
    assert {:ok,
            %{
              "fastop" => true,
              "maxrad" => :infinity,
              "minrad" => :negative_infinity,
              "numrad" => :infinity,
              "nodrad" => []
            }} =
             JuliaElixir.eval(
               ~S"""
               Dict(
                 "fastop" => true,
                 "maxrad" => Inf,
                 "minrad" => -Inf,
                 "numrad" => Inf,
                 "nodrad" => Any[]
               )
               """,
               server: server
             )
  end

  test "eval decodes nested integer vectors as lists even when Elixir displays charlists",
       context do
    server = context[:server]

    assert {:ok, [[35, 75], [35, 47], [112, 43], [14, 34]]} =
             JuliaElixir.eval("[[35, 75], [35, 47], [112, 43], [14, 34]]",
               server: server
             )
  end

  test "inspect_as_data renders printable integer lists as lists" do
    assert JuliaElixir.inspect_as_data([[35, 75], [112, 43]]) == "[[35, 75], [112, 43]]"
  end

  test "call invokes a Julia function", %{server: server} do
    assert {:ok, 3.0} = JuliaElixir.call("sqrt", [9.0], module: "Base", server: server)
  end

  test "call preserves boolean return values", %{server: server} do
    assert {:ok, true} = JuliaElixir.call("isodd", [3], module: "Base", server: server)
    assert {:ok, false} = JuliaElixir.call("isodd", [4], module: "Base", server: server)
  end

  test "call maps Elixir booleans and nil into Julia values", %{server: server} do
    assert {:ok, false} = JuliaElixir.call("xor", [true, true], module: "Base", server: server)

    assert {:ok, true} = JuliaElixir.call("isnothing", [nil], module: "Base", server: server)

    assert {:ok, [true, false, nil]} =
             JuliaElixir.call("identity", [[true, false, nil]], module: "Base", server: server)
  end

  test "call invokes a function defined during the session", %{server: server} do
    assert {:ok, _} =
             JuliaElixir.eval(
               """
               function hypotenuse(a, b)
                 sqrt(a^2 + b^2)
               end
               """,
               server: server
             )

    assert {:ok, 13.0} = JuliaElixir.call("hypotenuse", [5, 12], server: server)
  end

  test "eval returns structured errors", %{server: server} do
    assert {:error, %{message: message, class: class, stacktrace: stacktrace}} =
             JuliaElixir.eval("missing_function()", server: server)

    assert class in ["LoadError", "UndefVarError"]
    assert message =~ "missing_function"
    assert is_binary(stacktrace)
  end
end
