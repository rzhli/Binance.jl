module MarketDataStreams

    using HTTP, JSON3, Dates, URIs, StructTypes
    using ..Config
    using ..Filters
    using ..Types

    export MarketDataStreamClient, subscribe, subscribe_ticker, subscribe_mini_ticker,
        subscribe_all_tickers, subscribe_all_mini_tickers, subscribe_book_ticker,
        subscribe_all_book_tickers,
        subscribe_depth, subscribe_diff_depth, subscribe_kline, subscribe_trade,
        subscribe_agg_trade, subscribe_rolling_ticker, subscribe_user_data,
        subscribe_combined, unsubscribe, close_all_connections, list_active_streams,
        subscribe_avg_price

    """
    A client for subscribing to Binance Market Data WebSocket streams.
    """
    mutable struct MarketDataStreamClient
        config::BinanceConfig
        ws_base_url::String
        ws_connections::Dict{String,Task}
        ws_callbacks::Dict{String,Function}
        should_reconnect::Dict{String,Bool}

        function MarketDataStreamClient(config_path::String="config.toml")
            config = from_toml(config_path)
            ws_base_url = config.testnet ? "wss://stream.testnet.binance.vision/ws/" : "wss://stream.binance.com:9443/ws/"
            new(config, ws_base_url, Dict{String,Task}(), Dict{String,Function}(), Dict{String,Bool}())
        end
    end

    # --- Websocket Functions ---

    function subscribe(client::MarketDataStreamClient, stream_name::String, callback::Function; struct_type=nothing)
        client.ws_callbacks[stream_name] = callback
        client.should_reconnect[stream_name] = true

        uri = client.ws_base_url * stream_name
        proxy_url = isempty(client.config.proxy) ? nothing : client.config.proxy
        ws_kwargs = Dict{Symbol,Any}(:suppress_close_error => true)
        if proxy_url !== nothing
            ws_kwargs[:proxy] = proxy_url
        end

        task = @async begin
            while get(client.should_reconnect, stream_name, false) # Check reconnection flag
                try
                    HTTP.WebSockets.open(uri; ws_kwargs...) do ws
                        println("✅ Successfully connected to '$stream_name'.")
                        for msg in ws
                            if !get(client.should_reconnect, stream_name, false)
                                break     # Stop processing if unsubscribed
                            end
                            try
                                data = if !isnothing(struct_type)
                                    JSON3.read(msg, struct_type)
                                else
                                    JSON3.read(msg)
                                end
                                if haskey(client.ws_callbacks, stream_name)
                                    client.ws_callbacks[stream_name](data)
                                end
                            catch e
                                println("⚠️ Error processing WebSocket message on stream '$stream_name': $e")
                                println("   Raw message: $msg")
                            end
                        end
                    end

                if get(client.should_reconnect, stream_name, false)
                    println("⚪ WebSocket connection for '$stream_name' closed. Reconnecting in 5 seconds...")
                    sleep(5) # Wait 5 seconds before attempting to reconnect
                end

                catch e
                    if e isa InterruptException || !get(client.should_reconnect, stream_name, false)
                        println("🛑 WebSocket task for '$stream_name' received stop signal.")
                        break # Exit the while loop
                    end
                    if get(client.should_reconnect, stream_name, false)
                        println("❌ WebSocket connection error for '$stream_name': $e. Retrying in 5 seconds...")
                        sleep(5)
                    end
                end
            end
            println("🛑 WebSocket task for '$stream_name' has terminated.")
        end

        client.ws_connections[stream_name] = task
        return stream_name
    end

    function subscribe_ticker(client::MarketDataStreamClient, symbol::String, callback::Function)
        symbol = lowercase(validate_symbol(symbol))
        stream_name = "$(symbol)@ticker"
        return subscribe(client, stream_name, callback, struct_type=Ticker24hr)
    end

    function subscribe_mini_ticker(client::MarketDataStreamClient, symbol::String, callback::Function)
        symbol = lowercase(validate_symbol(symbol))
        stream_name = "$(symbol)@miniTicker"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_all_tickers(client::MarketDataStreamClient, callback::Function)
        stream_name = "!ticker@arr"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_all_mini_tickers(client::MarketDataStreamClient, callback::Function)
        stream_name = "!miniTicker@arr"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_book_ticker(client::MarketDataStreamClient, symbol::String, callback::Function)
        symbol = lowercase(validate_symbol(symbol))
        stream_name = "$(symbol)@bookTicker"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_all_book_tickers(client::MarketDataStreamClient, callback::Function)
        stream_name = "!bookTicker@arr"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_depth(
        client::MarketDataStreamClient, symbol::String, callback::Function;
        levels::Union{Int,String}="", update_speed::String="1000ms"
    )
        symbol = lowercase(validate_symbol(symbol))

        stream_name = if isempty(string(levels))
            "$(symbol)@depth"
        else
            if !(levels in [5, 10, 20, "5", "10", "20"])
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
        client::MarketDataStreamClient, symbol::String, callback::Function;
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

    function subscribe_kline(client::MarketDataStreamClient, symbol::String, interval::String, callback::Function)
        symbol = lowercase(validate_symbol(symbol))
        interval = validate_interval(interval)
        stream_name = "$(symbol)@kline_$(interval)"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_trade(client::MarketDataStreamClient, symbol::String, callback::Function)
        symbol = lowercase(validate_symbol(symbol))
        stream_name = "$(symbol)@trade"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_agg_trade(client::MarketDataStreamClient, symbol::String, callback::Function)
        symbol = lowercase(validate_symbol(symbol))
        stream_name = "$(symbol)@aggTrade"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_avg_price(client::MarketDataStreamClient, symbol::String, callback::Function)
        symbol = lowercase(validate_symbol(symbol))
        stream_name = "$(symbol)@avgPrice"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_rolling_ticker(client::MarketDataStreamClient, symbol::String, window_size::String, callback::Function)

        symbol = lowercase(validate_symbol(symbol))

        if !(window_size in ["1h", "4h", "1d"])
            error("Invalid window size. Must be '1h', '4h', or '1d'")
        end

        stream_name = "$(symbol)@ticker_$(window_size)"
        return subscribe(client, stream_name, callback)
    end

    function subscribe_combined(client::MarketDataStreamClient, streams::Vector{String}, callback::Function)
        combined_stream = join(streams, "/")
        return subscribe(client, combined_stream, callback)
    end

    function unsubscribe(client::MarketDataStreamClient, stream::String)
        if haskey(client.ws_connections, stream)
            # Set reconnection flag to false first
            client.should_reconnect[stream] = false

            task = client.ws_connections[stream]
            try
                if !istaskdone(task)
                    schedule(task, InterruptException(), error=true)
                end
                # Wait a brief moment for the task to stop
                sleep(0.1)
            catch e
                println("⚠️ Error stopping task for '$stream': $e")
            finally
                delete!(client.ws_connections, stream)
                delete!(client.ws_callbacks, stream)
                delete!(client.should_reconnect, stream)
                println("🛑 Unsubscribed from stream: $stream")
            end
            return true
        else
            println("⚠️ Stream '$stream' not found in active connections.")
            return false
        end
    end

    function close_all_connections(client::MarketDataStreamClient)
        # Set all reconnection flags to false
        for stream in keys(client.should_reconnect)
            client.should_reconnect[stream] = false
        end

        for (stream, task) in client.ws_connections
            try
                if !istaskdone(task)
                    schedule(task, InterruptException(), error=true)
                end
            catch e
                println("⚠️ Error stopping task for '$stream': $e")
            end
        end

        # Wait a brief moment for all tasks to stop
        sleep(0.2)

        empty!(client.ws_connections)
        empty!(client.ws_callbacks)
        empty!(client.should_reconnect)
        println("🛑 All WebSocket connections closed.")
    end

    function list_active_streams(client::MarketDataStreamClient)
        return collect(keys(client.ws_connections))
    end

end # end of module
