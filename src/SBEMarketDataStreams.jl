"""
SBE Market Data Streams Module

Provides access to Binance's Simple Binary Encoding (SBE) market data streams,
which offer more efficient data transmission compared to JSON streams.

# Features
- Binary encoding for reduced bandwidth and latency
- Real-time trade data
- Best bid/ask updates with auto-culling
- Incremental order book updates (20ms from 2026-08-04 ~07:00 UTC; 25ms before)
- Partial book depth snapshots

# Official Documentation
https://binance-docs.github.io/apidocs/spot/en/#sbe-market-data-streams

# Connection Details
- Base URL: wss://stream-sbe.binance.com:443/ws (port 9443 is also supported)
- Requires Ed25519 API Key in X-MBX-APIKEY header
- No signature required for public market data
- Connection valid for 24 hours
- All timestamps in microseconds
"""
module SBEMarketDataStreams

using HTTP, JSON, Dates, URIs
using ..Config
using ..Types
using ..RateLimiter: backoff_delay

# Binance sends a WebSocket ping every 20 seconds on the SBE stream endpoint;
# 60 seconds without any inbound frame means the connection is dead. HTTP.jl
# turns the idle timeout into a 1006 close, which drives the reconnect loop.
const SBE_READ_IDLE_TIMEOUT = 60

include("SBEDecoder.jl")
using .SBEDecoder

export SBEStreamClient, connect_sbe!, sbe_subscribe, sbe_unsubscribe,
    sbe_subscribe_trade, sbe_subscribe_best_bid_ask,
    sbe_subscribe_depth, sbe_subscribe_depth20,
    sbe_subscribe_combined, sbe_close_all, sbe_list_streams,
    sbe_unsubscribe_trade, sbe_unsubscribe_best_bid_ask,
    sbe_unsubscribe_depth, sbe_unsubscribe_depth20

# Re-export SBE data types
export TradeEvent, TradeData, BestBidAskEvent, DepthSnapshotEvent, DepthDiffEvent

struct SBEStreamCallback{F}
    callback::F
end

# A REPL may register a newly defined callback after the reader task starts.
# Cross the world-age boundary only when entering user code.
@inline (callback::SBEStreamCallback{F})(data) where {F} = Base.invokelatest(callback.callback, data)

"""
SBE Market Data Stream Client

Connects to Binance's SBE (Simple Binary Encoding) market data streams
for efficient real-time market data delivery.

# Fields
- `config::BinanceConfig`: Configuration including API key
- `ws_base_url::String`: WebSocket base URL for SBE streams
- `ws_connection::Union{WebSocket,Nothing}`: Active WebSocket connection
- `ws_task::Union{Task,Nothing}`: Background task for WebSocket
- `subscriptions::Dict{String,SBEStreamCallback}`: Callbacks for each stream
- `should_reconnect::Bool`: Reconnection flag
"""
mutable struct SBEStreamClient
    config::BinanceConfig
    ws_base_url::String
    ws_connection::Union{HTTP.WebSockets.WebSocket,Nothing}  # Typed WebSocket connection
    ws_task::Union{Task,Nothing}
    subscriptions::Dict{String,SBEStreamCallback}  # stream_name => callback
    should_reconnect::Bool
    next_request_id::Int
    request_lock::ReentrantLock
    subscriptions_lock::ReentrantLock
    send_lock::ReentrantLock
    connection_changed::Threads.Condition
    connection_error::Union{Exception,Nothing}

    function SBEStreamClient(config_path::String="config.toml"; port::Int=443)
        port in (443, 9443) || throw(ArgumentError("SBE port must be 443 or 9443"))
        config = from_toml(config_path)

        # Verify Ed25519 API key
        if config.signature_method != "ED25519"
            @warn "SBE streams require Ed25519 API keys. Current method: $(config.signature_method)"
        end

        # Prefer the standard TLS port; some networks/proxies disrupt 9443.
        ws_base_url = config.testnet ?
                      "wss://stream-sbe.testnet.binance.vision:$port" :
                      "wss://stream-sbe.binance.com:$port"

        new(
            config, ws_base_url, nothing, nothing, Dict{String,SBEStreamCallback}(),
            true, 1, ReentrantLock(), ReentrantLock(), ReentrantLock(),
            Threads.Condition(), nothing,
        )
    end
end

function subscription_callback(client::SBEStreamClient, stream_name::String)
    return lock(client.subscriptions_lock) do
        get(client.subscriptions, stream_name, nothing)
    end
end

function subscription_names(client::SBEStreamClient)
    return lock(client.subscriptions_lock) do
        collect(keys(client.subscriptions))
    end
end

function next_request_id!(client::SBEStreamClient)
    return lock(client.request_lock) do
        id = client.next_request_id
        client.next_request_id += 1
        return id
    end
end

@inline function network_timeout(client::SBEStreamClient)
    return max(client.config.timeout, 1)
end

# ============================================================================
# WebSocket Connection Management
# ============================================================================

# Helper function to handle WebSocket session (extracted to avoid code duplication)
function _handle_sbe_ws_session(client::SBEStreamClient, ws)
    # Capture previous subscriptions before waking new subscribers, otherwise
    # their first SUBSCRIBE can also be sent as an automatic resubscription.
    streams = subscription_names(client)
    accepted = lock(client.connection_changed) do
        # Closing during the handshake must not publish a late connection.
        client.should_reconnect || return false
        client.ws_connection = ws
        client.connection_error = nothing
        notify(client.connection_changed; all=true)
        return true
    end
    accepted || return nothing
    @info "✅ Connected to SBE Market Data Stream"

    # Resubscribe to existing streams
    if !isempty(streams)
        @info "Resubscribing to $(length(streams)) streams..."

        # Send subscription request for all streams
        subscribe_msg = JSON.json(Dict(
            "method" => "SUBSCRIBE",
            "params" => streams,
            "id" => next_request_id!(client)
        ))

        try
            lock(client.send_lock) do
                HTTP.WebSockets.send(ws, subscribe_msg)
            end
            @info "Sent resubscription request for: $(join(streams, ", "))"
        catch e
            @error "Failed to resubscribe: $e"
        end
    end

    for msg in ws
        if !client.should_reconnect
            break
        end

        # Check message type: text (JSON control) or binary (SBE data)
        if msg isa String
            handle_control_message(client, msg)
        elseif msg isa Vector{UInt8}
            handle_sbe_message(client, msg)
        else
            @warn "Unknown message type: $(typeof(msg))"
        end
    end
end

"""
    connect_sbe!(client::SBEStreamClient)

Establish WebSocket connection to SBE stream endpoint with API key authentication.

Wait until a usable connection exists or all configured attempts fail. The
connection timeout applies to each handshake, including retries. Concurrent
callers wait on the same connection task. On exhaustion, throw the last error.
"""
function connect_sbe!(client::SBEStreamClient)
    return connect_sbe_with!(HTTP.WebSockets.open, client)
end

function sbe_connected(client::SBEStreamClient)
    ws = client.ws_connection
    return ws !== nothing && !HTTP.WebSockets.isclosed(ws)
end

# The opener is passed explicitly so the connection lifecycle can be tested
# with in-memory WebSockets and scripted handshake failures.
function connect_sbe_with!(open_websocket, client::SBEStreamClient)
    client.config.max_reconnect_attempts >= 0 ||
        throw(ArgumentError("max_reconnect_attempts must be >= 0"))
    return lock(client.connection_changed) do
        client.should_reconnect && sbe_connected(client) && return nothing
        if client.ws_task === nothing || istaskdone(client.ws_task)
            client.ws_connection = nothing
            client.connection_error = nothing
            client.should_reconnect = true
            client.ws_task = errormonitor(@async Base.invokelatest(run_sbe_connection!, open_websocket, client))
        end

        @info "Waiting for SBE WebSocket connection (including configured retries)..."
        while true
            if !client.should_reconnect || istaskdone(client.ws_task)
                client.connection_error === nothing && error("SBE WebSocket connection stopped")
                throw(client.connection_error)
            end
            sbe_connected(client) && return nothing
            wait(client.connection_changed)
        end
    end
end

# A condition notification from sbe_close_all interrupts a backoff immediately.
function wait_sbe_retry(client::SBEStreamClient, delay::Real)
    deadline = time_ns() + round(UInt64, max(delay, 0) * 1e9)
    timer = Timer(max(delay, 0)) do _
        lock(client.connection_changed) do
            notify(client.connection_changed; all=true)
        end
    end
    try
        return lock(client.connection_changed) do
            while client.should_reconnect && time_ns() < deadline
                wait(client.connection_changed)
            end
            return client.should_reconnect
        end
    finally
        close(timer)
    end
end

function run_sbe_connection!(open_websocket, client::SBEStreamClient)
    uri = client.ws_base_url * "/ws"
    headers = ["X-MBX-APIKEY" => client.config.api_key]
    # Proxy settings: an empty proxy means "follow the standard proxy environment
    # variables" (HTTP.jl's default), not "force direct".
    timeout = network_timeout(client)
    open_kwargs = if isempty(client.config.proxy)
        (; headers=headers, suppress_close_error=true, subprotocols=["stream"],
           connect_timeout=timeout, request_timeout=timeout,
           read_idle_timeout=SBE_READ_IDLE_TIMEOUT)
    else
        (; headers=headers, suppress_close_error=true, subprotocols=["stream"],
           connect_timeout=timeout, request_timeout=timeout,
           read_idle_timeout=SBE_READ_IDLE_TIMEOUT, proxy=client.config.proxy)
    end

    @info "Connecting to SBE stream: $uri"

    failures = 0
    try
        while client.should_reconnect
            failure = nothing
            failure_backtrace = nothing
            try
                # Binance SBE streams require the "stream" subprotocol during handshake
                open_websocket(uri; open_kwargs...) do ws
                    failures = 0
                    _handle_sbe_ws_session(client, ws)
                end
            catch e
                if e isa InterruptException || !client.should_reconnect
                    break
                end
                failure = e
                failure_backtrace = catch_backtrace()
            finally
                lock(client.connection_changed) do
                    client.ws_connection = nothing
                    notify(client.connection_changed; all=true)
                end
            end

            client.should_reconnect || break
            failures += 1
            lock(client.connection_changed) do
                client.connection_error = failure === nothing ? EOFError() : failure
            end
            if failures > client.config.max_reconnect_attempts
                @error "SBE WebSocket connection attempts exhausted" attempts=failures uri exception=client.connection_error
                break
            end

            delay = backoff_delay(client.config.reconnect_delay, failures)
            if failure === nothing
                @info "SBE WebSocket closed; reconnecting" retry=failures max_retries=client.config.max_reconnect_attempts delay=round(delay, digits=2)
            else
                @warn "SBE WebSocket connection failed; retrying" retry=failures max_retries=client.config.max_reconnect_attempts delay=round(delay, digits=2) uri exception=failure
                @debug "SBE WebSocket failure details" exception=(failure, failure_backtrace)
            end
            wait_sbe_retry(client, delay) || break
        end
    finally
        lock(client.connection_changed) do
            client.should_reconnect = false
            client.ws_connection = nothing
            notify(client.connection_changed; all=true)
        end
        @info "SBE WebSocket task terminated"
    end
    return nothing
end

"""
    handle_ping_pong(client, ws)

Handle WebSocket ping/pong frames. Server sends ping every 20 seconds,
client must respond with pong within 60 seconds.
"""
function handle_ping_pong(client::SBEStreamClient, ws)
    # Note: HTTP.jl WebSocket client automatically handles ping/pong frames
    # This is a placeholder for custom ping/pong logic if needed
    @debug "Ping/pong handler started"
end

"""
    handle_control_message(client, msg)

Handle JSON control messages (subscription responses and serverShutdown events).
"""
function handle_control_message(client::SBEStreamClient, msg::String)
    try
        data = JSON.parse(msg)

        # Subscription response format:
        # {"result":null,"id":1}  (success)
        # {"id":1,"error":{"code":-1121,"msg":"Invalid symbol."}}  (error)

        if isa(data, AbstractDict) && get(data, :e, nothing) == "serverShutdown"
            event_time = haskey(data, :E) ? unix2datetime(data[:E] / 1000) : nothing
            @warn "serverShutdown received on SBE stream. Closing connection for reconnect." event_time
            if !isnothing(client.ws_connection)
                try
                    close(client.ws_connection)
                catch close_error
                    @warn "Error while closing SBE WebSocket after serverShutdown: $close_error"
                end
            end
        elseif haskey(data, :result)
            @info "Subscription successful: $msg"
        elseif haskey(data, :error)
            @error "Subscription error: $(data.error.msg)"
        else
            @debug "Control message: $msg"
        end
    catch e
        @warn "Failed to parse control message: $e\n  Raw: $msg"
    end
end

"""
    handle_sbe_message(client, data)

Handle binary SBE-encoded market data messages.
"""
function handle_sbe_message(client::SBEStreamClient, data::Vector{UInt8})
    try
        # Decode SBE message using the decoder
        decoded = SBEDecoder.decode_sbe_message(data)

        # Skip unknown message types (e.g., NonRepresentableMessage from newer schema versions)
        if isnothing(decoded)
            return
        end

        # Route to appropriate callback based on message type
        # Use get() for single lookup instead of haskey() + indexing (avoids double lookup)
        if decoded isa TradeEvent
            stream_name = string(lowercase(decoded.symbol), "@trade")
            callback = subscription_callback(client, stream_name)
            if callback !== nothing
                callback(decoded)
            end

        elseif decoded isa BestBidAskEvent
            stream_name = string(lowercase(decoded.symbol), "@bestBidAsk")
            callback = subscription_callback(client, stream_name)
            if callback !== nothing
                callback(decoded)
            end

        elseif decoded isa DepthSnapshotEvent
            stream_name = string(lowercase(decoded.symbol), "@depth20")
            callback = subscription_callback(client, stream_name)
            if callback !== nothing
                callback(decoded)
            end

        elseif decoded isa DepthDiffEvent
            stream_name = string(lowercase(decoded.symbol), "@depth")
            callback = subscription_callback(client, stream_name)
            if callback !== nothing
                callback(decoded)
            end
        else
            @warn "Unknown SBE message type: $(typeof(decoded))"
        end

    catch e
        @error "Failed to handle SBE message" exception=(e, catch_backtrace())
        @debug "  Data length: $(length(data)) bytes"
        @debug "  First 16 bytes: $(data[1:min(16, length(data))])"
    end
end

# ============================================================================
# Subscription Management
# ============================================================================

"""
    sbe_subscribe(client::SBEStreamClient, stream_name::String, callback)

Subscribe to an SBE stream.

# Parameters
- `client`: SBEStreamClient instance
- `stream_name`: Stream name (e.g., "btcusdt@trade", "btcusdt@bestBidAsk")
- `callback`: Function to call with decoded data

# Example
```julia
client = SBEStreamClient()
connect_sbe!(client)

sbe_subscribe(client, "btcusdt@trade", data -> begin
    println("Trade: \$(data)")
end)
```
"""
function sbe_subscribe(client::SBEStreamClient, stream_name::String, callback)
    # Ensure connection is established and open
    if isnothing(client.ws_connection) || HTTP.WebSockets.isclosed(client.ws_connection)
        connect_sbe!(client)
    end

    if isnothing(client.ws_connection) || HTTP.WebSockets.isclosed(client.ws_connection)
        @error "Failed to establish SBE WebSocket connection; cannot subscribe to $stream_name"
        throw(ErrorException("SBE WebSocket connection unavailable"))
    end

    # Register callback
    lock(client.subscriptions_lock) do
        client.subscriptions[stream_name] = SBEStreamCallback(callback)
    end

    # Send subscription request (JSON format)
    subscribe_msg = JSON.json(Dict(
        "method" => "SUBSCRIBE",
        "params" => [stream_name],
        "id" => next_request_id!(client)
    ))

    try
        lock(client.send_lock) do
            HTTP.WebSockets.send(client.ws_connection, subscribe_msg)
        end
        @info "Subscribed to SBE stream: $stream_name"
    catch e
        @error "Failed to subscribe to $stream_name: $e"
        lock(client.subscriptions_lock) do
            delete!(client.subscriptions, stream_name)
        end
        rethrow(e)
    end

    return stream_name
end

"""
    sbe_unsubscribe(client::SBEStreamClient, stream_name::String)

Unsubscribe from an SBE stream.
"""
function sbe_unsubscribe(client::SBEStreamClient, stream_name::String)
    if isnothing(client.ws_connection)
        @warn "No active SBE connection"
        return
    end

    # Send unsubscribe request
    unsubscribe_msg = JSON.json(Dict(
        "method" => "UNSUBSCRIBE",
        "params" => [stream_name],
        "id" => next_request_id!(client)
    ))

    try
        lock(client.send_lock) do
            HTTP.WebSockets.send(client.ws_connection, unsubscribe_msg)
        end
        lock(client.subscriptions_lock) do
            delete!(client.subscriptions, stream_name)
        end
        @info "Unsubscribed from SBE stream: $stream_name"
    catch e
        @error "Failed to unsubscribe from $stream_name: $e"
    end
end

# ============================================================================
# Convenience Subscription Functions
# ============================================================================

"""
    sbe_subscribe_trade(client::SBEStreamClient, symbol::String, callback)

Subscribe to real-time trade stream.

SBE Message: TradesStreamEvent
Stream: <symbol>@trade
Update Speed: Real-time
"""
function sbe_subscribe_trade(client::SBEStreamClient, symbol::String, callback)
    stream_name = "$(lowercase(symbol))@trade"
    return sbe_subscribe(client, stream_name, callback)
end

"""
    sbe_subscribe_best_bid_ask(client::SBEStreamClient, symbol::String, callback)

Subscribe to best bid/ask stream with auto-culling.

SBE Message: BestBidAskStreamEvent
Stream: <symbol>@bestBidAsk
Update Speed: Real-time

Note: Auto-culling means outdated events may be dropped under high load.
"""
function sbe_subscribe_best_bid_ask(client::SBEStreamClient, symbol::String, callback)
    stream_name = "$(lowercase(symbol))@bestBidAsk"
    return sbe_subscribe(client, stream_name, callback)
end

"""
    sbe_subscribe_depth(client::SBEStreamClient, symbol::String, callback)

Subscribe to incremental order book updates (diff depth).

SBE Message: DepthDiffStreamEvent
Stream: <symbol>@depth
Update Speed: 20ms from 2026-08-04 ~07:00 UTC (25ms before rollout)

Use this to maintain a local order book with incremental updates.
"""
function sbe_subscribe_depth(client::SBEStreamClient, symbol::String, callback)
    stream_name = "$(lowercase(symbol))@depth"
    return sbe_subscribe(client, stream_name, callback)
end

"""
    sbe_subscribe_depth20(client::SBEStreamClient, symbol::String, callback)

Subscribe to partial order book snapshots (top 20 levels).

SBE Message: DepthSnapshotStreamEvent
Stream: <symbol>@depth20
Update Speed: 50ms
"""
function sbe_subscribe_depth20(client::SBEStreamClient, symbol::String, callback)
    stream_name = "$(lowercase(symbol))@depth20"
    return sbe_subscribe(client, stream_name, callback)
end

"""
    sbe_unsubscribe_trade(client::SBEStreamClient, symbol::String)

Unsubscribe from real-time trade stream.
"""
function sbe_unsubscribe_trade(client::SBEStreamClient, symbol::String)
    stream_name = "$(lowercase(symbol))@trade"
    sbe_unsubscribe(client, stream_name)
end

"""
    sbe_unsubscribe_best_bid_ask(client::SBEStreamClient, symbol::String)

Unsubscribe from best bid/ask stream.
"""
function sbe_unsubscribe_best_bid_ask(client::SBEStreamClient, symbol::String)
    stream_name = "$(lowercase(symbol))@bestBidAsk"
    sbe_unsubscribe(client, stream_name)
end

"""
    sbe_unsubscribe_depth(client::SBEStreamClient, symbol::String)

Unsubscribe from incremental order book updates.
"""
function sbe_unsubscribe_depth(client::SBEStreamClient, symbol::String)
    stream_name = "$(lowercase(symbol))@depth"
    sbe_unsubscribe(client, stream_name)
end

"""
    sbe_unsubscribe_depth20(client::SBEStreamClient, symbol::String)

Unsubscribe from partial order book snapshots.
"""
function sbe_unsubscribe_depth20(client::SBEStreamClient, symbol::String)
    stream_name = "$(lowercase(symbol))@depth20"
    sbe_unsubscribe(client, stream_name)
end

"""
    sbe_subscribe_combined(client::SBEStreamClient, streams::Vector{String}, callback)

Subscribe to multiple streams with a single callback.

# Example
```julia
streams = ["btcusdt@trade", "ethusdt@trade", "btcusdt@bestBidAsk"]
sbe_subscribe_combined(client, streams, data -> println(data))
```
"""
function sbe_subscribe_combined(client::SBEStreamClient, streams::Vector{String}, callback)
    for stream in streams
        sbe_subscribe(client, stream, callback)
    end
end

"""
    sbe_close_all(client::SBEStreamClient)

Close all SBE stream subscriptions and disconnect.
"""
function sbe_close_all(client::SBEStreamClient)
    @info "Closing all SBE streams..."

    # Stop first: an unsubscribe/send error must not leave reconnection running.
    ws, task = lock(client.connection_changed) do
        client.should_reconnect = false
        client.connection_error = nothing
        notify(client.connection_changed; all=true)
        (client.ws_connection, client.ws_task)
    end
    lock(client.subscriptions_lock) do
        empty!(client.subscriptions)
    end

    # Close WebSocket
    if ws !== nothing
        try
            close(ws)
        catch e
            @debug "Error closing WebSocket: $e"
        end
    end

    # A callback may close its own client; waiting on that same task deadlocks.
    if task !== nothing && task !== current_task()
        wait(task)
    end
    lock(client.connection_changed) do
        client.ws_connection = nothing
    end

    @info "All SBE streams closed"
end

"""
    sbe_list_streams(client::SBEStreamClient)

List all active SBE stream subscriptions.
"""
function sbe_list_streams(client::SBEStreamClient)
    return subscription_names(client)
end

end # module SBEMarketDataStreams
