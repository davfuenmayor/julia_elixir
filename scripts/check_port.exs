{:ok, server} = JuliaElixir.start(startup_timeout: 120_000)

try do
  3 = JuliaElixir.eval!("1 + 2", server: server)
  "Julia \u03bb \u2713" = JuliaElixir.eval!(~S|"Julia \u03bb \u2713"|, server: server)
  true = JuliaElixir.eval!("VERSION >= v\"1.10\"", server: server)

  %{ok: true, missing: nil, values: [1, 2, 3], limit: :infinity} =
    JuliaElixir.eval!("Dict(:ok => true, :missing => nothing, :values => [1,2,3], :limit => Inf)",
      server: server
    )

  JuliaElixir.eval!("answer = 40; increment(x) = x + 2", server: server)
  42 = JuliaElixir.call!("increment", [40], server: server)
  42 = JuliaElixir.eval!("answer + 2", server: server)
  {:error, %{message: _}} = JuliaElixir.eval("error(\"expected failure\")", server: server)
  42 = JuliaElixir.eval!("println(\"stdout stays off the ETF wire\"); 42", server: server)

  workers =
    for n <- 1..4, do: Task.async(fn -> JuliaElixir.eval!("#{n} * #{n}", server: server) end)

  [1, 4, 9, 16] = Enum.map(workers, &Task.await(&1, 30_000))

  IO.puts(
    "PASS real Julia Port: state, UTF-8, ETF containers, functions, errors, output and concurrent callers"
  )
after
  JuliaElixir.stop(server)
end
