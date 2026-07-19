module MarketDataStreams

    using HTTP, JSON3, Dates, URIs, StructTypes
    using ..Config
    using ..Filters
    using ..Types

    export MarketDataStreamClient, subscribe, subscribe_ticker, subscribe_mini_ticker,
        subscribe_all_tickers, subscribe_all_mini_tickers, subscribe_book_ticker,
        subscribe_all_book_tickers,
        subscribe_depth, subscribe_diff_depth, subscribe_kline, subscribe_trade,
        subscribe_agg_trade, subscribe_block_trade, subscribe_rolling_ticker, subscribe_user_data,
        subscribe_combined, unsubscribe, close_all_connections, list_active_streams,
        subscribe_avg_price, subscribe_reference_price

    struct StreamCallback{F}
        callback::F
    end

    @inline (callback::StreamCallback{F})(data) where {F} = callback.callback(data)

    """
    A client for subscribing to Binance Market Data WebSocket streams.
    """
    mutable struct MarketDataStreamClient
        config::BinanceConfig
        ws_base_url::String
        ws_connections::Dict{String,Task}
        ws_callbacks::Dict{String,StreamCallback}
        should_reconnect::Dict{String,Bool}
        state_lock::ReentrantLock

        function MarketDataStreamClient(config_path::String="config.toml")
            config = from_toml(config_path)
            ws_base_url = config.testnet ? "wss://stream.testnet.binance.vision/ws/" : "wss://stream.binance.com:9443/ws/"
            new(
                config, ws_base_url, Dict{String,Task}(),
                Dict{String,StreamCallback}(), Dict{String,Bool}(), ReentrantLock(),
            )
        end
    end

    @inline function network_timeout(client::MarketDataStreamClient)
        return max(client.config.timeout, 1)
    end

    function reconnect_enabled(client::MarketDataStreamClient, stream_name::String)
        return lock(client.state_lock) do
            get(client.should_reconnect, stream_name, false)
        end
    end

    function stream_callback(client::MarketDataStreamClient, stream_name::String)
        return lock(client.state_lock) do
            get(client.ws_callbacks, stream_name, nothing)
        end
    end

    # --- Websocket Functions ---

    function subscribe(client::MarketDataStreamClient, stream_name::String, callback; struct_type=nothing)
        lock(client.state_lock) do
            haskey(client.ws_connections, stream_name) && throw(ArgumentError(
                "Stream '$stream_name' is already subscribed",
            ))
            client.ws_callbacks[stream_name] = StreamCallback(callback)
            client.should_reconnect[stream_name] = true
        end

        uri = client.ws_base_url * stream_name
        proxy_url = isempty(client.config.proxy) ? nothing : client.config.proxy
        timeout = network_timeout(client)

        task = errormonitor(@async begin
            while reconnect_enabled(client, stream_name)
                try
                    # 根据是否有 proxy 选择不同的调用方式，避免每次创建 Dict
                    if proxy_url !== nothing
                        HTTP.WebSockets.open(uri; suppress_close_error=true, proxy=proxy_url,
                                             connect_timeout=timeout, request_timeout=timeout) do ws
                            _handle_ws_messages(client, ws, stream_name, struct_type)
                        end
                    else
                        HTTP.WebSockets.open(uri; suppress_close_error=true,
                                             connect_timeout=timeout, request_timeout=timeout) do ws
                            _handle_ws_messages(client, ws, stream_name, struct_type)
                        end
                    end

                    if reconnect_enabled(client, stream_name)
                        @info "WebSocket connection closed; reconnecting" stream_name delay=client.config.reconnect_delay
                        sleep(client.config.reconnect_delay)
                    end

                catch e
                    if e isa InterruptException || !reconnect_enabled(client, stream_name)
                        @debug "WebSocket task received stop signal" stream_name
                        break # Exit the while loop
                    end
                    if reconnect_enabled(client, stream_name)
                        @error "WebSocket connection error; retrying" stream_name delay=client.config.reconnect_delay exception=(e, catch_backtrace())
                        sleep(client.config.reconnect_delay)
                    end
                end
            end
            @debug "WebSocket task terminated" stream_name
        end)

        lock(client.state_lock) do
            client.ws_connections[stream_name] = task
        end
        return stream_name
    end

    # 提取消息处理逻辑，避免代码重复
    function _handle_ws_messages(client::MarketDataStreamClient, ws, stream_name::String, struct_type)
        @info "Successfully connected to WebSocket stream" stream_name
        for msg in ws
            if !reconnect_enabled(client, stream_name)
                break     # Stop processing if unsubscribed
            end
            try
                # Parse once so we can detect serverShutdown control events. These
                # arrive on WebSocket Streams in addition to the WebSocket API. Close
                # the current socket so the outer loop opens a fresh connection.
                raw = JSON3.read(msg)
                if isa(raw, JSON3.Object) && get(raw, :e, nothing) == "serverShutdown"
                    event_time = haskey(raw, :E) ? unix2datetime(raw[:E] / 1000) : nothing
                    @warn "⚠️  serverShutdown received on stream '$stream_name'. Closing connection for reconnect." event_time
                    try
                        close(ws)
                    catch close_error
                        @warn "Error while closing WebSocket after serverShutdown: $close_error"
                    end
                    break
                end
                data = isnothing(struct_type) ? raw : to_struct(struct_type, raw)
                cb = stream_callback(client, stream_name)
                if cb !== nothing
                    cb(data)
                end
            catch e
                @error "Error processing WebSocket message" stream_name message_bytes=sizeof(msg) exception=(e, catch_backtrace())
            end
        end
    end

    function subscribe_ticker(client::MarketDataStreamClient, symbol::String, callback)
        symbol = lowercase(validate_symbol(symbol))
        stream_name = "$(symbol)@ticker"
        return subscribe(client, stream_name, callback, struct_type=Ticker24hr)
    end

    function subscribe_mini_ticker(client::MarketDataStreamClient, symbol::String, callback)
        symbol = lowercase(validate_symbol(symbol))
        stream_name = "$(symbol)@miniTicker"
        return subscribe(client, stream_name, callback)
    end

    """
        subscribe_all_tickers(client::MarketDataStreamClient, callback::Function)

    **DEPRECATED**: This function uses the deprecated `!ticker@arr` stream.

    As of 2025-11-14, Binance has deprecated the All Market Tickers Stream (`!ticker@arr`).
    This stream will be removed from Binance systems at a later date.

    **Please use one of these alternatives instead:**
    - `subscribe_all_mini_tickers()` - Subscribe to all mini ticker updates using `!miniTicker@arr`
    - `subscribe_ticker(symbol)` - Subscribe to individual symbol tickers using `<symbol>@ticker`

    See: https://binance-docs.github.io/apidocs/spot/en/#change-log
    """
    function subscribe_all_tickers(client::MarketDataStreamClient, callback)
        @warn """
        DEPRECATION WARNING: subscribe_all_tickers() uses the deprecated !ticker@arr stream.
        This stream has been deprecated by Binance as of 2025-11-14 and will be removed in the future.

        Please migrate to one of these alternatives:
        - subscribe_all_mini_tickers() for all market mini tickers (!miniTicker@arr)
        - subscribe_ticker(symbol) for individual symbol tickers (<symbol>@ticker)
        """
        stream_name = "!ticker@arr"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_all_mini_tickers(client::MarketDataStreamClient, callback)
        stream_name = "!miniTicker@arr"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_book_ticker(client::MarketDataStreamClient, symbol::String, callback)
        symbol = lowercase(validate_symbol(symbol))
        stream_name = "$(symbol)@bookTicker"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_all_book_tickers(client::MarketDataStreamClient, callback)
        stream_name = "!bookTicker@arr"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_depth(
        client::MarketDataStreamClient, symbol::String, callback;
        levels::Union{Int,String}="", update_speed::String="1000ms"
    )
        symbol = lowercase(validate_symbol(symbol))

        stream_name = if isempty(string(levels))
            "$(symbol)@depth"
        else
            if !(levels in (5, 10, 20, "5", "10", "20"))
                error("Invalid depth levels. Must be 5, 10, or 20")
            end
            "$(symbol)@depth$(levels)"
        end

        if update_speed == "100ms"
            stream_name *= "@100ms"
        elseif update_speed != "1000ms"
            error("Invalid update speed. Must be '100ms' or '1000ms'")
        end

        return subscribe(client, stream_name, callback)
    end

    function subscribe_diff_depth(
        client::MarketDataStreamClient, symbol::String, callback;
        update_speed::String="1000ms"
    )
        symbol = lowercase(validate_symbol(symbol))

        stream_name = "$(symbol)@depth"
        if update_speed == "100ms"
            stream_name *= "@100ms"
        elseif update_speed != "1000ms"
            error("Invalid update speed. Must be '100ms' or '1000ms'")
        end

        return subscribe(client, stream_name, callback)
    end

    function subscribe_kline(client::MarketDataStreamClient, symbol::String, interval::String, callback)
        symbol = lowercase(validate_symbol(symbol))
        interval = validate_interval(interval)
        stream_name = "$(symbol)@kline_$(interval)"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_trade(client::MarketDataStreamClient, symbol::String, callback)
        symbol = lowercase(validate_symbol(symbol))
        stream_name = "$(symbol)@trade"
        return subscribe(client, stream_name, callback, struct_type=WebSocketTrade)
    end

    function subscribe_agg_trade(client::MarketDataStreamClient, symbol::String, callback)
        symbol = lowercase(validate_symbol(symbol))
        stream_name = "$(symbol)@aggTrade"
        return subscribe(client, stream_name, callback, struct_type=AggregateTrade)
    end

    # Block Trade Stream (rollout 2026-05-12). Emits an event per off-book
    # block trade matched against the separate block-trade liquidity pool.
    function subscribe_block_trade(client::MarketDataStreamClient, symbol::String, callback)
        symbol = lowercase(validate_symbol(symbol))
        stream_name = "$(symbol)@blockTrade"
        return subscribe(client, stream_name, callback, struct_type=WebSocketBlockTrade)
    end

    function subscribe_avg_price(client::MarketDataStreamClient, symbol::String, callback)
        symbol = lowercase(validate_symbol(symbol))
        stream_name = "$(symbol)@avgPrice"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_reference_price(client::MarketDataStreamClient, symbol::String, callback)
        symbol = lowercase(validate_symbol(symbol))
        stream_name = "$(symbol)@referencePrice"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_rolling_ticker(client::MarketDataStreamClient, symbol::String, window_size::String, callback)

        symbol = lowercase(validate_symbol(symbol))

        if !(window_size in ("1h", "4h", "1d"))
            error("Invalid window size. Must be '1h', '4h', or '1d'")
        end

        stream_name = "$(symbol)@ticker_$(window_size)"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_combined(client::MarketDataStreamClient, streams::Vector{String}, callback)
        combined_stream = join(streams, "/")
        return subscribe(client, combined_stream, callback)
    end

    function subscribe_user_data(
        client::MarketDataStreamClient, listen_key::String, callback,
    )
        isempty(listen_key) && throw(ArgumentError("listen_key cannot be empty"))
        return subscribe(client, listen_key, callback)
    end

    function unsubscribe(client::MarketDataStreamClient, stream::String)
        task = lock(client.state_lock) do
            task = get(client.ws_connections, stream, nothing)
            task === nothing || (client.should_reconnect[stream] = false)
            return task
        end

        if task !== nothing
            try
                if !istaskdone(task)
                    schedule(task, InterruptException(), error=true)
                end
                wait_status = timedwait(() -> istaskdone(task), network_timeout(client))
                wait_status == :timed_out && @warn "Timed out waiting for WebSocket task to stop" stream
            catch e
                @warn "Error stopping WebSocket task" stream exception=(e, catch_backtrace())
            finally
                lock(client.state_lock) do
                    delete!(client.ws_connections, stream)
                    delete!(client.ws_callbacks, stream)
                    delete!(client.should_reconnect, stream)
                end
                @info "Unsubscribed from WebSocket stream" stream
            end
            return true
        else
            @warn "Stream not found in active connections" stream
            return false
        end
    end

    function close_all_connections(client::MarketDataStreamClient)
        tasks = lock(client.state_lock) do
            for stream in keys(client.should_reconnect)
                client.should_reconnect[stream] = false
            end
            return collect(client.ws_connections)
        end

        for (stream, task) in tasks
            try
                if !istaskdone(task)
                    schedule(task, InterruptException(), error=true)
                end
            catch e
                @warn "Error stopping WebSocket task" stream exception=(e, catch_backtrace())
            end
        end

        for (stream, task) in tasks
            wait_status = timedwait(() -> istaskdone(task), network_timeout(client))
            wait_status == :timed_out && @warn "Timed out waiting for WebSocket task to stop" stream
        end

        lock(client.state_lock) do
            empty!(client.ws_connections)
            empty!(client.ws_callbacks)
            empty!(client.should_reconnect)
        end
        @info "All WebSocket connections closed"
    end

    function list_active_streams(client::MarketDataStreamClient)
        return lock(client.state_lock) do
            collect(keys(client.ws_connections))
        end
    end

end # end of module
