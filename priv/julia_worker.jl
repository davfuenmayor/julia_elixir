#!/usr/bin/env julia

include(joinpath(@__DIR__, "vendor", "ErlangTerm", "src", "ErlangTerm.jl"))
import .ErlangTerm

const STDOUT_HANDLE = stdout
const STDERR_HANDLE = stderr

function read_frame(io)
    header = read(io, 4)
    length(header) == 0 && return nothing
    length(header) == 4 || error("short frame header")

    n = (UInt32(header[1]) << 24) |
        (UInt32(header[2]) << 16) |
        (UInt32(header[3]) << 8) |
        UInt32(header[4])

    payload = read(io, Int(n))
    length(payload) == Int(n) || error("short frame payload")
    payload
end

function write_frame(io, payload::Vector{UInt8})
    n = UInt32(length(payload))
    header = UInt8[
        (n >> 24) & 0xff,
        (n >> 16) & 0xff,
        (n >> 8) & 0xff,
        n & 0xff,
    ]

    write(io, header)
    write(io, payload)
    flush(io)
end

function beam_value(value::Bool)
    value ? Symbol("true") : Symbol("false")
end

function beam_value(::Nothing)
    :nil
end

function beam_value(value::AbstractFloat)
    if isinf(value) && value > 0
        Symbol("infinity")
    elseif isinf(value) && value < 0
        Symbol("negative_infinity")
    elseif isnan(value)
        Symbol("nan")
    else
        Float64(value)
    end
end

function beam_value(value::Tuple)
    tuple((beam_value(item) for item in value)...)
end

function beam_value(value::AbstractArray)
    Any[beam_value(item) for item in value]
end

function beam_value(value::Dict)
    Dict(beam_value(key) => beam_value(val) for (key, val) in value)
end

function beam_value(value)
    value
end

function julia_value(value::Symbol)
    if value == Symbol("true")
        true
    elseif value == Symbol("false")
        false
    elseif value == :nil
        nothing
    elseif value == Symbol("infinity")
        Inf
    elseif value == Symbol("negative_infinity")
        -Inf
    elseif value == Symbol("nan")
        NaN
    else
        value
    end
end

function julia_value(value::Tuple)
    tuple((julia_value(item) for item in value)...)
end

function julia_value(value::AbstractArray)
    Any[julia_value(item) for item in value]
end

function julia_value(value::Dict)
    Dict(julia_value(key) => julia_value(val) for (key, val) in value)
end

function julia_value(value)
    value
end

function reply_ok(request_id, value)
    write_frame(STDOUT_HANDLE, ErlangTerm.serialize((:ok, request_id, beam_value(value))))
end

function reply_error(request_id, err, bt = catch_backtrace())
    details = Dict(
        :class => string(typeof(err)),
        :message => sprint(showerror, err),
        :stacktrace => sprint(Base.show_backtrace, bt),
    )

    write_frame(STDOUT_HANDLE, ErlangTerm.serialize((:error, request_id, beam_value(details))))
end

function eval_in_main(code::String)
    redirect_stdout(STDERR_HANDLE) do
        Base.include_string(Main, code, "JuliaElixir.eval")
    end
end

function resolve_module(module_name::String)
    value = Core.eval(Main, Meta.parse(module_name))
    value isa Module || error("$(module_name) did not resolve to a Julia module")
    value
end

function call_function(module_name::String, function_name::String, args)
    mod = resolve_module(module_name)
    fn = Base.invokelatest(getfield, mod, Symbol(function_name))
    julia_args = julia_value(args)

    redirect_stdout(STDERR_HANDLE) do
        Base.invokelatest(fn, julia_args...)
    end
end

function handle_request(request)
    command = request[1]
    request_id = request[2]

    try
        if command == :ping
            reply_ok(request_id, :pong)
        elseif command == :eval
            reply_ok(request_id, eval_in_main(request[3]))
        elseif command == :call
            reply_ok(request_id, call_function(request[3], request[4], request[5]))
        else
            error("unknown command: $(command)")
        end
    catch err
        reply_error(request_id, err)
    end
end

function main()
    while true
        payload = read_frame(stdin)
        payload === nothing && break
        request = ErlangTerm.deserialize(payload)
        handle_request(request)
    end
end

main()
