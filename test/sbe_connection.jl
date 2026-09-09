using Test
using Binance
using HTTP
using Logging

const SBE = Binance.SBEMarketDataStreams

function offline_client(; retries=2, delay=0)
    return mktempdir() do dir
        key_path = joinpath(dir, "test-key.pem")
        write(key_path, "offline fixture")
        config_path = joinpath(dir, "config.toml")
        write(config_path, """
        [api]
        api_key = "offline-sbe-key"
        signature_method = "ED25519"
        private_key_path = "$key_path"
        [connection]
        timeout = 1
        max_reconnect_attempts = $retries
        reconnect_delay = $delay
        """)
        SBE.SBEStreamClient(config_path)
    end
end

function memory_websocket(f)
    stream = Base.BufferStream()
    ws = HTTP.WebSockets.WebSocket(stream, () -> close(stream))
    try
        return f(ws)
    finally
        # The in-memory peer finishes together with the scripted session.
        ws.readclosed = true
        close(ws)
    end
end

@testset "SBE connection lifecycle" begin
    @testset "A running reader can invoke a newly defined callback" begin
        callbacks = Channel{Any}(1)
        reader = @async take!(callbacks)(41)
        yield()
        late_callback = Core.eval(@__MODULE__, :(x -> x + 1))
        put!(callbacks, SBE.SBEStreamCallback(late_callback))
        @test fetch(reader) == 42
    end

    @testset "A full handshake timeout still permits a successful retry" begin
        client = offline_client(retries=1)
        attempts = Ref(0)
        entered = Channel{Nothing}(1)
        opener = function (f, uri; kwargs...)
            attempts[] += 1
            @test uri == "wss://stream-sbe.binance.com:443/ws"
            @test kwargs[:connect_timeout] == 1
            @test kwargs[:request_timeout] == 1
            if attempts[] == 1
                put!(entered, nothing)
                # The old foreground wait expired here, before retry #1.
                sleep(1.1)
                throw(HTTP.TimeoutError("request", 1_000_000_000))
            end
            return memory_websocket(f)
        end
        try
            first_waiter = @async SBE.connect_sbe_with!(opener, client)
            take!(entered)
            worker = client.ws_task
            second_waiter = @async SBE.connect_sbe_with!(opener, client)
            @test timedwait(() -> istaskdone(first_waiter) && istaskdone(second_waiter), 5) == :ok
            @test fetch(first_waiter) === nothing
            @test fetch(second_waiter) === nothing
            @test SBE.sbe_connected(client)
            @test attempts[] == 2
            @test client.ws_task === worker
            @test SBE.connect_sbe!(client) === nothing
            @test client.ws_task === worker
        finally
            SBE.sbe_close_all(client)
        end
        @test client.ws_connection === nothing
        @test istaskdone(client.ws_task)
        @test !client.should_reconnect
    end

    @testset "Retry exhaustion wakes callers and terminates the worker" begin
        client = offline_client(retries=2)
        attempts = Ref(0)
        opener = function (f, uri; kwargs...)
            attempts[] += 1
            throw(EOFError())
        end
        try
            with_logger(NullLogger()) do
                @test_throws EOFError SBE.connect_sbe_with!(opener, client)
            end
            wait(client.ws_task)
            @test attempts[] == 3  # Initial attempt plus two configured retries.
            @test client.connection_error isa EOFError
            @test client.ws_connection === nothing
            @test istaskdone(client.ws_task)
            @test !client.should_reconnect
        finally
            SBE.sbe_close_all(client)
        end
    end

    @testset "Shutdown interrupts backoff and clears subscriptions" begin
        client = offline_client(retries=5, delay=60)
        attempts = Ref(0)
        opener = function (f, uri; kwargs...)
            attempts[] += 1
            throw(EOFError())
        end
        waiter = @async try
            SBE.connect_sbe_with!(opener, client)
        catch e
            e
        end
        @test timedwait(() -> client.connection_error !== nothing, 2) == :ok
        client.subscriptions["btcusdt@depth20"] = SBE.SBEStreamCallback(identity)
        closer = @async SBE.sbe_close_all(client)
        @test timedwait(() -> istaskdone(closer), 2) == :ok
        fetch(closer)
        @test fetch(waiter) isa ErrorException
        @test attempts[] == 1
        @test isempty(SBE.sbe_list_streams(client))
        @test istaskdone(client.ws_task)
        @test !client.should_reconnect
    end

    @testset "A handshake finishing after shutdown cannot revive the client" begin
        client = offline_client()
        entered = Channel{Nothing}(1)
        finish_handshake = Channel{Nothing}(1)
        late_ws = Ref{Any}(nothing)
        opener = function (f, uri; kwargs...)
            put!(entered, nothing)
            take!(finish_handshake)
            return memory_websocket() do ws
                late_ws[] = ws
                f(ws)
                @test client.ws_connection === nothing
            end
        end
        waiter = @async try
            SBE.connect_sbe_with!(opener, client)
        catch e
            e
        end
        take!(entered)
        closer = @async SBE.sbe_close_all(client)
        @test timedwait(() -> !client.should_reconnect, 2) == :ok
        put!(finish_handshake, nothing)
        @test timedwait(() -> istaskdone(closer) && istaskdone(waiter), 2) == :ok
        fetch(closer)
        @test fetch(waiter) isa ErrorException
        @test HTTP.WebSockets.isclosed(late_ws[])
        @test client.ws_connection === nothing
        @test istaskdone(client.ws_task)
    end
end
