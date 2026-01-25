"""
SBE Market Data Streams Module

Provides access to Binance's Simple Binary Encoding (SBE) market data streams,
which offer more efficient data transmission compared to JSON streams.

# Features
- Binary encoding for reduced bandwidth and latency
- Real-time trade data
- Best bid/ask updates with auto-culling
- Incremental order book updates (50ms)
- Partial book depth snapshots

# Official Documentation
https://binance-docs.github.io/apidocs/spot/en/#sbe-market-data-streams

# Connection Details
- Base URL: wss://stream-sbe.binance.com:9443/ws
- Requires Ed25519 API Key in X-MBX-APIKEY header
- No signature required for public market data
- Connection valid for 24 hours
- All timestamps in microseconds
"""
module SBEMarketDataStreams

using HTTP, JSON3, Dates, URIs
using ..Config
using ..Types

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

"""
SBE Market Data Stream Client

Connects to Binance's SBE (Simple Binary Encoding) market data streams
for efficient real-time market data delivery.

# Fields
- `config::BinanceConfig`: Configuration including API key
- `ws_base_url::String`: WebSocket base URL for SBE streams
- `ws_connection::Union{WebSocket,Nothing}`: Active WebSocket connection
- `ws_task::Union{Task,Nothing}`: Background task for WebSocket
- `subscriptions::Dict{String,Function}`: Callbacks for each stream
- `should_reconnect::Bool`: Reconnection flag
"""
mutable struct SBEStreamClient
    config::BinanceConfig
    ws_base_url::String
    ws_connection::Union{HTTP.WebSockets.WebSocket,Nothing}  # Typed WebSocket connection
    ws_task::Union{Task,Nothing}
    subscriptions::Dict{String,Function}  # stream_name => callback
    should_reconnect::Bool
    next_request_id::Int

    function SBEStreamClient(config_path::String="config.toml")
        config = from_toml(config_path)

        # Verify Ed25519 API key
        if config.signature_method != "ED25519"
            @warn "SBE streams require Ed25519 API keys. Current method: $(config.signature_method)"
        end

        # SBE stream base URL
        ws_base_url = config.testnet ?
                      "wss://stream-sbe.testnet.binance.vision:9443" :
                      "wss://stream-sbe.binance.com:9443"

        new(config, ws_base_url, nothing, nothing, Dict{String,Function}(), true, 1)
    end
end

function next_request_id!(client::SBEStreamClient)
    id = client.next_request_id
    client.next_request_id += 1
    return id
end

# ============================================================================
# WebSocket Connection Management
# ============================================================================

# Helper function to handle WebSocket session (extracted to avoid code duplication)
function _handle_sbe_ws_session(client::SBEStreamClient, ws)
    client.ws_connection = ws
    @info "✅ Connected to SBE Market Data Stream"

    # Resubscribe to existing streams
    if !isempty(client.subscriptions)
        streams = collect(keys(client.subscriptions))
        @info "Resubscribing to $(length(streams)) streams..."

        # Send subscription request for all streams
        subscribe_msg = JSON3.write(Dict(
            "method" => "SUBSCRIBE",
            "params" => streams,
            "id" => next_request_id!(client)
        ))

        try
            HTTP.WebSockets.send(ws, subscribe_msg)
            @info "Sent resubscription request for: $(join(streams, ", "))"
        catch e
            @error "Failed to resubscribe: $e"
        end
    end

    # Start ping/pong handler
    ping_task = @async handle_ping_pong(client, ws)

    try
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
    finally
        # Stop ping task
        if !isnothing(ping_task) && !istaskdone(ping_task)
            Base.@async Base.throwto(ping_task, InterruptException())
        end
    end
end

"""
    connect_sbe!(client::SBEStreamClient)

Establish WebSocket connection to SBE stream endpoint with API key authentication.
"""
function connect_sbe!(client::SBEStreamClient)
    # Check if already connected AND connection is still open
    if !isnothing(client.ws_connection)
        if !HTTP.WebSockets.isclosed(client.ws_connection)
            @info "SBE WebSocket already connected"
            return
        else
            # Connection exists but is closed - clear stale reference
            @debug "Clearing stale SBE WebSocket connection reference"
            client.ws_connection = nothing
        end
    end

    # Check if reconnection task is already running
    if !isnothing(client.ws_task) && !istaskdone(client.ws_task)
        @info "SBE WebSocket reconnection already in progress, waiting..."
        for i in 1:30
            if !isnothing(client.ws_connection) && !HTTP.WebSockets.isclosed(client.ws_connection)
                @info "SBE reconnection completed after $(i * 0.5) seconds"
                return
            end
            sleep(0.5)
        end
        @warn "SBE reconnection did not complete in time"
        return
    end

    # Reset reconnection flag in case it was disabled by sbe_close_all
    client.should_reconnect = true

    # Build connection URL
    uri = client.ws_base_url * "/ws"

    # Prepare headers with API key
    headers = [
        "X-MBX-APIKEY" => client.config.api_key
    ]

    # Proxy settings
    proxy_url = isempty(client.config.proxy) ? nothing : client.config.proxy

    @info "Connecting to SBE stream: $uri"

    client.ws_task = @async begin
        while client.should_reconnect
            try
                # Binance SBE streams require the "stream" subprotocol during handshake
                # Use direct keyword args to avoid NamedTuple merge overhead
                if proxy_url !== nothing
                    HTTP.WebSockets.open(uri; headers=headers, suppress_close_error=true,
                                         subprotocols=["stream"], proxy=proxy_url) do ws
                        _handle_sbe_ws_session(client, ws)
                    end
                else
                    HTTP.WebSockets.open(uri; headers=headers, suppress_close_error=true,
                                         subprotocols=["stream"]) do ws
                        _handle_sbe_ws_session(client, ws)
                    end
                end

                if client.should_reconnect
                    @info "SBE WebSocket closed. Reconnecting in 5 seconds..."
                    sleep(5)
                end

            catch e
                if e isa InterruptException || !client.should_reconnect
                    @info "SBE WebSocket task stopped"
                    break
                end

                if client.should_reconnect
                    @error """SBE WebSocket error: $e
                    Connection details:
                      URI: $uri
                      Proxy: $(client.config.proxy)
                      API Key: $(client.config.api_key[1:8])...
                    Retrying in 5 seconds..."""
                    # Print the full exception for debugging
                    @error "Full error:" exception = (e, catch_backtrace())
                    sleep(5)
                end
            end
        end

        client.ws_connection = nothing
        @info "SBE WebSocket task terminated"
    end

    # Wait for connection to establish
    @info "Waiting for WebSocket connection to establish..."
    for i in 1:30
        if !isnothing(client.ws_connection)
            @info "Connection established successfully after $(i * 0.5) seconds"
            return
        end
        sleep(0.5)
        if i % 4 == 0
            @debug "Still waiting for connection... ($(i * 0.5)s elapsed)"
        end
    end

    @error """Failed to establish SBE WebSocket connection after 15 seconds.
    Possible reasons:
      1. Network connectivity issues
      2. Proxy configuration problem (current: $(client.config.proxy))
      3. Invalid API key or wrong signature method (current: $(client.config.signature_method))
      4. Binance SBE service may be unavailable

    Please check:
      - Your internet connection and proxy settings
      - That you have a valid Ed25519 API key
      - The Binance SBE service status"""
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

Handle JSON control messages (subscription responses).
"""
function handle_control_message(client::SBEStreamClient, msg::String)
    try
        data = JSON3.read(msg)

        # Subscription response format:
        # {"result":null,"id":1}  (success)
        # {"id":1,"error":{"code":-1121,"msg":"Invalid symbol."}}  (error)

        if haskey(data, :result)
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

        # Route to appropriate callback based on message type
        # Use get() for single lookup instead of haskey() + indexing (avoids double lookup)
        if decoded isa TradeEvent
            stream_name = "$(lowercase(decoded.symbol))@trade"
            callback = get(client.subscriptions, stream_name, nothing)
            if callback !== nothing
                Base.invokelatest(callback, decoded)
            end

        elseif decoded isa BestBidAskEvent
            stream_name = "$(lowercase(decoded.symbol))@bestBidAsk"
            callback = get(client.subscriptions, stream_name, nothing)
            if callback !== nothing
                Base.invokelatest(callback, decoded)
            end

        elseif decoded isa DepthSnapshotEvent
            stream_name = "$(lowercase(decoded.symbol))@depth20"
            callback = get(client.subscriptions, stream_name, nothing)
            if callback !== nothing
                Base.invokelatest(callback, decoded)
            end

        elseif decoded isa DepthDiffEvent
            stream_name = "$(lowercase(decoded.symbol))@depth"
            callback = get(client.subscriptions, stream_name, nothing)
            if callback !== nothing
                Base.invokelatest(callback, decoded)
            end
        else
            @warn "Unknown SBE message type: $(typeof(decoded))"
        end

    catch e
        @error "Failed to decode SBE message: $e"
        @debug "  Data length: $(length(data)) bytes"
        @debug "  First 16 bytes: $(data[1:min(16, length(data))])"
    end
end

# ============================================================================
# Subscription Management
# ============================================================================

"""
    sbe_subscribe(client::SBEStreamClient, stream_name::String, callback::Function)

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
function sbe_subscribe(client::SBEStreamClient, stream_name::String, callback::Function)
    # Ensure connection is established and open
    if isnothing(client.ws_connection) || HTTP.WebSockets.isclosed(client.ws_connection)
        connect_sbe!(client)
    end

    if isnothing(client.ws_connection) || HTTP.WebSockets.isclosed(client.ws_connection)
        @error "Failed to establish SBE WebSocket connection; cannot subscribe to $stream_name"
        throw(ErrorException("SBE WebSocket connection unavailable"))
    end

    # Register callback
    client.subscriptions[stream_name] = callback

    # Send subscription request (JSON format)
    subscribe_msg = JSON3.write(Dict(
        "method" => "SUBSCRIBE",
        "params" => [stream_name],
        "id" => next_request_id!(client)
    ))

    try
        HTTP.WebSockets.send(client.ws_connection, subscribe_msg)
        @info "Subscribed to SBE stream: $stream_name"
    catch e
        @error "Failed to subscribe to $stream_name: $e"
        delete!(client.subscriptions, stream_name)
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
    unsubscribe_msg = JSON3.write(Dict(
        "method" => "UNSUBSCRIBE",
        "params" => [stream_name],
        "id" => next_request_id!(client)
    ))

    try
        HTTP.WebSockets.send(client.ws_connection, unsubscribe_msg)
        delete!(client.subscriptions, stream_name)
        @info "Unsubscribed from SBE stream: $stream_name"
    catch e
        @error "Failed to unsubscribe from $stream_name: $e"
    end
end

# ============================================================================
# Convenience Subscription Functions
# ============================================================================

"""
    sbe_subscribe_trade(client::SBEStreamClient, symbol::String, callback::Function)

Subscribe to real-time trade stream.

SBE Message: TradesStreamEvent
Stream: <symbol>@trade
Update Speed: Real-time
"""
function sbe_subscribe_trade(client::SBEStreamClient, symbol::String, callback::Function)
    stream_name = "$(lowercase(symbol))@trade"
    return sbe_subscribe(client, stream_name, callback)
end

"""
    sbe_subscribe_best_bid_ask(client::SBEStreamClient, symbol::String, callback::Function)

Subscribe to best bid/ask stream with auto-culling.

SBE Message: BestBidAskStreamEvent
Stream: <symbol>@bestBidAsk
Update Speed: Real-time

Note: Auto-culling means outdated events may be dropped under high load.
"""
function sbe_subscribe_best_bid_ask(client::SBEStreamClient, symbol::String, callback::Function)
    stream_name = "$(lowercase(symbol))@bestBidAsk"
    return sbe_subscribe(client, stream_name, callback)
end

"""
    sbe_subscribe_depth(client::SBEStreamClient, symbol::String, callback::Function)

Subscribe to incremental order book updates (diff depth).

SBE Message: DepthDiffStreamEvent
Stream: <symbol>@depth
Update Speed: 50ms

Use this to maintain a local order book with incremental updates.
"""
function sbe_subscribe_depth(client::SBEStreamClient, symbol::String, callback::Function)
    stream_name = "$(lowercase(symbol))@depth"
    return sbe_subscribe(client, stream_name, callback)
end

"""
    sbe_subscribe_depth20(client::SBEStreamClient, symbol::String, callback::Function)

Subscribe to partial order book snapshots (top 20 levels).

SBE Message: DepthSnapshotStreamEvent
Stream: <symbol>@depth20
Update Speed: 50ms
"""
function sbe_subscribe_depth20(client::SBEStreamClient, symbol::String, callback::Function)
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
    sbe_subscribe_combined(client::SBEStreamClient, streams::Vector{String}, callback::Function)

Subscribe to multiple streams with a single callback.

# Example
```julia
streams = ["btcusdt@trade", "ethusdt@trade", "btcusdt@bestBidAsk"]
sbe_subscribe_combined(client, streams, data -> println(data))
```
"""
function sbe_subscribe_combined(client::SBEStreamClient, streams::Vector{String}, callback::Function)
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

    # Unsubscribe from all streams
    for stream_name in keys(client.subscriptions)
        sbe_unsubscribe(client, stream_name)
    end

    # Stop reconnection
    client.should_reconnect = false

    # Close WebSocket
    if !isnothing(client.ws_connection)
        try
            close(client.ws_connection)
        catch e
            @debug "Error closing WebSocket: $e"
        end
        client.ws_connection = nothing
    end

    # Wait for task to complete
    if !isnothing(client.ws_task) && !istaskdone(client.ws_task)
        wait(client.ws_task)
    end

    @info "All SBE streams closed"
end

"""
    sbe_list_streams(client::SBEStreamClient)

List all active SBE stream subscriptions.
"""
function sbe_list_streams(client::SBEStreamClient)
    return collect(keys(client.subscriptions))
end

end # module SBEMarketDataStreams
