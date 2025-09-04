module WebSocketAPI

    using HTTP, JSON3, Dates, SHA, URIs, StructTypes, DataFrames
    using ..Config
    using ..Signature
    using ..Types
    using ..RESTAPI
    using ..RateLimiter
    using ..Filters
    using ..Account

    # --- Exports ---

    # Client and Connection
    export WebSocketClient, connect!, disconnect!, on_event

    # Session Management
    export session_logon, session_status, session_logout

    # General Methods
    export ping, time, exchangeInfo

    # Market Data
    export depth, trades_recent, trades_historical, trades_aggregate, klines, ui_klines,
        avg_price, ticker_24hr, ticker_trading_day, ticker, ticker_price, ticker_book

    # Trading
    export place_order, test_order, order_status, cancel_order, cancel_replace_order,
        amend_order, cancel_all_orders

    # Order Lists
    export place_oco_order, place_oto_order, place_otoco_order, cancel_order_list,
        order_list_status, open_order_lists_status, all_order_lists

    # SOR (Smart Order Routing)
    export place_sor_order, test_sor_order

    # Account
    export account_status, account_rate_limits_orders, orders_open, orders_all, my_trades,
        open_orders_status, all_orders, my_prevented_matches, my_allocations,
        account_commission, order_amendments

    # User Data Stream
    export user_data_stream_start, user_data_stream_ping, user_data_stream_stop,
        userdata_stream_subscribe, userdata_stream_unsubscribe, session_subscriptions,
        userdata_stream_subscribe_signature

    mutable struct WebSocketClient
        config::BinanceConfig
        signer::CryptoSigner
        base_url::String
        ws_connection::Any # Will hold the WebSocket connection
        request_id::Int64
        rate_limiter::BinanceRateLimit
        responses::Dict{Int64,Channel}
        ws_callbacks::Dict{String,Function} # For user data stream events
        time_offset::Int64
        is_authenticated::Bool
        exchange_info::Union{ExchangeInfo,Nothing}
        should_reconnect::Bool
        reconnect_task::Union{Task,Nothing}

        function WebSocketClient(config_path::String="config.toml")
            config = from_toml(config_path)

            signer = if config.signature_method == HMAC_SHA256
                HmacSigner(config.api_secret)
            elseif config.signature_method == ED25519
                Ed25519Signer(config.private_key_path, config.private_key_pass)
            elseif config.signature_method == RSA
                RsaSigner(config.private_key_path)
            else
                error("Unsupported signature method: $(config.signature_method)")
            end

            base_url = config.testnet ? "wss://ws-api.testnet.binance.vision/ws-api/v3" : "wss://ws-api.binance.com:443/ws-api/v3"
            if !config.ws_return_rate_limits
                base_url *= "?returnRateLimits=false"
            end

            rate_limiter = BinanceRateLimit(config)
            client = new(config, signer, base_url, nothing, 1, rate_limiter, Dict{Int64,Channel}(), Dict{String,Function}(), 0, false, nothing, true, nothing)

            # Set a temporary time offset assuming local time is UTC+8, as requested.
            # This will be synchronized with the server after the WebSocket connection is established.
            client.time_offset = -8 * 3600 * 1000

            return client
        end
    end

    function get_timestamp(client::WebSocketClient)
        return Int(round(datetime2unix(now()) * 1000)) + client.time_offset
    end

    function connect!(client::WebSocketClient)
        client.should_reconnect = true
        client.reconnect_task = @async begin
            for attempt in 1:(client.config.max_reconnect_attempts+1)
                if !client.should_reconnect
                    break
                end

                try
                    HTTP.WebSockets.open(client.base_url; connect_timeout=30, proxy=client.config.proxy) do ws
                        client.ws_connection = ws
                        @info "Successfully connected to WebSocket API."

                        # Spawn a setup task that runs in the background, allowing the main loop to listen immediately
                        @async begin
                            # Synchronize time with server
                            try
                                server_time_response = time(client)
                                server_time = server_time_response.serverTime
                                local_time = Int(round(datetime2unix(now()) * 1000))
                                client.time_offset = server_time - local_time
                                @info "Time synchronized with server. Offset: $(client.time_offset)ms"
                            catch e
                                @warn "Could not synchronize time with Binance server via WebSocket. Using initial offset. Error: $e"
                            end

                            if client.is_authenticated
                                try
                                    session_logon(client)
                                    @info "Session re-authenticated successfully after reconnect."

                                    # Automatically re-subscribe to user data stream if callbacks are registered
                                    if !isempty(client.ws_callbacks)
                                        try
                                            userdata_stream_subscribe(client)
                                            @info "Automatically re-subscribed to user data stream."
                                        catch e_subscribe
                                            @warn "Failed to automatically re-subscribe to user data stream: $e_subscribe"
                                        end
                                    end
                                catch e
                                    @warn "Failed to re-authenticate session after reconnect: $e"
                                    client.is_authenticated = false
                                end
                            end
                        end

                        # The main connection task immediately starts listening for messages
                        for msg in ws
                            try
                                data = JSON3.read(String(msg))

                                if haskey(data, :rateLimits)
                                    update_limits!(client.rate_limiter, data.rateLimits)
                                end

                                if haskey(data, :id) && haskey(client.responses, data.id)
                                    put!(client.responses[data.id], data)
                                elseif haskey(data, :event) && haskey(data.event, :e)
                                    event_type = data.event.e
                                    if haskey(client.ws_callbacks, event_type)
                                        client.ws_callbacks[event_type](data.event)
                                    else
                                        @info "Received unhandled event of type '$(event_type)': $(data.event)"
                                    end
                                else
                                    @info "Received unsolicited message: $data"
                                end
                            catch e
                                if e isa HTTP.WebSockets.WebSocketError || e isa EOFError
                                    @info "WebSocket connection closed."
                                    break
                                else
                                    @error "Error processing message: $e"
                                end
                            end
                        end
                    end
                catch e
                    @error "WebSocket connection error: $e"
                finally
                    client.ws_connection = nothing
                    if client.should_reconnect && attempt <= client.config.max_reconnect_attempts
                        @info "Attempting to reconnect in $(client.config.reconnect_delay) seconds... (Attempt $attempt of $(client.config.max_reconnect_attempts))"
                        sleep(client.config.reconnect_delay)
                    elseif client.should_reconnect
                        @error "Maximum reconnect attempts reached. Giving up."
                        client.should_reconnect = false
                    end
                end
            end
        end
    end

    """
    Registers a callback function for a specific user data stream event type.
    """
    function on_event(client::WebSocketClient, event_type::String, callback::Function)
        client.ws_callbacks[event_type] = callback
        @info "Registered callback for event type '$event_type'."
    end

    function disconnect!(client::WebSocketClient)
        client.should_reconnect = false
        if !isnothing(client.ws_connection)
            try
                close(client.ws_connection)
            catch e
                @warn "Error while closing WebSocket connection: $e"
            end
        end
        client.ws_connection = nothing
        client.is_authenticated = false
        if !isnothing(client.reconnect_task)
            wait(client.reconnect_task)
            client.reconnect_task = nothing
        end
        @info "WebSocket API connection closed."
    end

    function handle_ws_error(client::WebSocketClient, response)
        status = response.status
        error_data = response.error
        code = error_data.code
        msg = error_data.msg

        if status == 401 # Unauthorized, session is invalid
            client.is_authenticated = false
            @warn "WebSocket session authentication failed or was revoked (status 401)."
        end

        if status == 429 || status == 418
            if haskey(error_data, :data) && haskey(error_data.data, :retryAfter)
                retry_after = error_data.data.retryAfter
                set_backoff_until!(client.rate_limiter, retry_after)
            end
        end

        if status == 403
            throw(WAFViolationError())
        elseif status == 409
            throw(CancelReplacePartialSuccess(code, msg))
        elseif status == 429
            throw(RateLimitError(code, msg))
        elseif status == 418
            throw(IPAutoBannedError())
        elseif 400 <= status < 500
            throw(MalformedRequestError(code, msg))
        elseif 500 <= status < 600
            @warn "Binance Server Error via WebSocket (status=$(status), code=$(code), msg=\"$(msg)\"). Execution status is UNKNOWN."
            throw(BinanceServerError(status, code, msg))
        else
            throw(BinanceError(status, code, msg))
        end
    end

    function send_request(client::WebSocketClient, method::String, params::Dict{String,Any}; return_rate_limits::Union{Bool,Nothing}=nothing)
        if isnothing(client.ws_connection)
            error("WebSocket is not connected. Call connect! first.")
        end

        # Proactively check rate limits
        check_and_wait(client.rate_limiter, false) # Assuming false for is_order for now

        request_id = client.request_id
        client.request_id += 1

        # Create a channel to wait for the response
        response_channel = Channel(1)
        client.responses[request_id] = response_channel

        # Add returnRateLimits parameter if specified
        if !isnothing(return_rate_limits)
            params["returnRateLimits"] = return_rate_limits
        end

        request = Dict(
            "id" => request_id,
            "method" => method,
            "params" => params
        )

        try
            HTTP.WebSockets.send(client.ws_connection, JSON3.write(request))

            # Wait for the response
            response = take!(response_channel) # This will block until a response is received

            if response.status == 200
                return haskey(response, :result) ? response.result : nothing
            else
                handle_ws_error(client, response)
            end

        catch e
            @error "Failed to send request or receive response: $e"
            rethrow(e)
        finally
            # Clean up the response channel
            delete!(client.responses, request_id)
        end
    end

    function send_signed_request(client::WebSocketClient, method::String, params::Dict{String,Any})
        # Session management methods have special parameter handling.
        if method == "session.logon"
            params_to_sign = Dict{String,Any}(
                "apiKey" => client.config.api_key,
                "timestamp" => get_timestamp(client),
                "recvWindow" => client.config.recv_window,
            )
            query_string = RESTAPI.build_query_string(params_to_sign)
            signature = Signature.sign_message(client.signer, query_string)

            # Logon requires the full set of parameters.
            request_params = params_to_sign
            request_params["signature"] = signature

            return send_request(client, method, request_params)
        elseif method in ["session.logout", "session.status"]
            # For authenticated sessions, these methods do not require parameters
            if client.is_authenticated
                return send_request(client, method, Dict{String,Any}())
            else
                # If not authenticated, require full authentication parameters
                params_to_sign = Dict{String,Any}(
                    "apiKey" => client.config.api_key,
                    "timestamp" => get_timestamp(client),
                    "recvWindow" => client.config.recv_window,
                )
                query_string = RESTAPI.build_query_string(params_to_sign)
                signature = Signature.sign_message(client.signer, query_string)

                request_params = params_to_sign
                request_params["signature"] = signature

                return send_request(client, method, request_params)
            end
        end

        # Logic for all other signed requests
        params["apiKey"] = client.config.api_key
        params["timestamp"] = get_timestamp(client)
        params["recvWindow"] = client.config.recv_window

        # Add signature
        query_string = RESTAPI.build_query_string(params)
        params["signature"] = Signature.sign_message(client.signer, query_string)

        return send_request(client, method, params)
    end

    # --- Session Management ---

    function session_logon(client::WebSocketClient)
        if client.config.signature_method != "ED25519"
            @warn "Session logon is only officially supported for Ed25519 signature method."
        end
        response = send_signed_request(client, "session.logon", Dict{String,Any}())
        client.is_authenticated = true # Assume success if no exception is thrown
        return JSON3.read(JSON3.write(response), WebSocketConnection)
    end

    function session_status(client::WebSocketClient)
        response = send_signed_request(client, "session.status", Dict{String,Any}())
        return JSON3.read(JSON3.write(response), WebSocketConnection)
    end

    function session_logout(client::WebSocketClient)
        response = send_signed_request(client, "session.logout", Dict{String,Any}())
        client.is_authenticated = false
        return response
    end

    # --- General Methods ---

    function ping(client::WebSocketClient)
        return send_request(client, "ping", Dict{String,Any}())
    end

    function time(client::WebSocketClient)
        return send_request(client, "time", Dict{String,Any}())
    end

    function exchangeInfo(client::WebSocketClient; symbols::Union{Vector{String},Nothing}=nothing, permissions::Union{Vector{String},Nothing}=nothing)
        params = Dict{String,Any}()
        if !isnothing(symbols)
            params["symbols"] = symbols
        end
        if !isnothing(permissions)
            params["permissions"] = permissions
        end
        return send_request(client, "exchangeInfo", params)
    end

    # --- Market Data Requests ---

    function depth(client::WebSocketClient, symbol::String; limit::Int=100)
        params = Dict{String,Any}("symbol" => symbol)
        if limit != 100
            params["limit"] = limit
        end
        response = send_request(client, "depth", params)
        return JSON3.read(JSON3.write(response), OrderBook)
    end

    function trades_recent(client::WebSocketClient, symbol::String; limit::Int=500)
        params = Dict{String,Any}("symbol" => symbol)
        if limit != 500
            params["limit"] = limit
        end
        response = send_request(client, "trades.recent", params)
        return JSON3.read(JSON3.write(response), Vector{MarketTrade})
    end

    function trades_historical(client::WebSocketClient, symbol::String; from_id::Union{Int,Nothing}=nothing, limit::Int=500)
        params = Dict{String,Any}("symbol" => symbol)
        if !isnothing(from_id)
            params["fromId"] = from_id
        end
        if limit != 500
            params["limit"] = limit
        end
        response = send_request(client, "trades.historical", params)
        return JSON3.read(JSON3.write(response), Vector{MarketTrade})
    end

    function trades_aggregate(client::WebSocketClient, symbol::String; from_id::Union{Int,Nothing}=nothing,
        start_time::Union{Int,Nothing}=nothing, end_time::Union{Int,Nothing}=nothing, limit::Int=500)
        params = Dict{String,Any}("symbol" => symbol)
        if !isnothing(from_id)
            params["fromId"] = from_id
        end
        if !isnothing(start_time)
            params["startTime"] = start_time
        end
        if !isnothing(end_time)
            params["endTime"] = end_time
        end
        if limit != 500
            params["limit"] = limit
        end
        response = send_request(client, "trades.aggregate", params)
        return JSON3.read(JSON3.write(response), Vector{AggregateTrade})
    end

    function klines(client::WebSocketClient, symbol::String, interval::String;
        start_time::Union{Int,Nothing}=nothing, end_time::Union{Int,Nothing}=nothing,
        time_zone::String="0", limit::Int=500)
        params = Dict{String,Any}(
            "symbol" => symbol,
            "interval" => interval
        )
        if !isnothing(start_time)
            params["startTime"] = start_time
        end
        if !isnothing(end_time)
            params["endTime"] = end_time
        end
        if time_zone != "0"
            params["timeZone"] = time_zone
        end
        if limit != 500
            params["limit"] = limit
        end
        response = send_request(client, "klines", params)
        klines_vector = JSON3.read(JSON3.write(response), Vector{Kline})
        df = DataFrame(klines_vector)
        df.open_time = floor.(df.open_time, Second)
        df.close_time = floor.(df.close_time, Second)
        return df
    end

    function ui_klines(client::WebSocketClient, symbol::String, interval::String;
        start_time::Union{Int,Nothing}=nothing, end_time::Union{Int,Nothing}=nothing,
        time_zone::String="0", limit::Int=500)
        params = Dict{String,Any}(
            "symbol" => symbol,
            "interval" => interval
        )
        if !isnothing(start_time)
            params["startTime"] = start_time
        end
        if !isnothing(end_time)
            params["endTime"] = end_time
        end
        if time_zone != "0"
            params["timeZone"] = time_zone
        end
        if limit != 500
            params["limit"] = limit
        end
        response = send_request(client, "uiKlines", params)
        klines_vector = JSON3.read(JSON3.write(response), Vector{Kline})
        df = DataFrame(klines_vector)
        df.open_time = floor.(df.open_time, Second)
        df.close_time = floor.(df.close_time, Second)
        return df
    end

    function avg_price(client::WebSocketClient, symbol::String)
        params = Dict{String,Any}("symbol" => symbol)
        response = send_request(client, "avgPrice", params)
        return JSON3.read(JSON3.write(response), AveragePrice)
    end

    function ticker_24hr(client::WebSocketClient; symbol::String="", symbols::Vector{String}=String[], type::String="FULL")
        params = Dict{String,Any}()
        single_symbol = false
        if !isempty(symbol)
            params["symbol"] = symbol
            single_symbol = true
        elseif !isempty(symbols)
            params["symbols"] = symbols
        end
        if type != "FULL"
            params["type"] = type
        end
        response = send_request(client, "ticker.24hr", params)
        if single_symbol
            return type == "FULL" ? JSON3.read(JSON3.write(response), Ticker24hrRest) : JSON3.read(JSON3.write(response), Ticker24hrMini)
        else
            return type == "FULL" ? JSON3.read(JSON3.write(response), Vector{Ticker24hrRest}) : JSON3.read(JSON3.write(response), Vector{Ticker24hrMini})
        end
    end

    function ticker_trading_day(client::WebSocketClient; symbol::String="", symbols::Vector{String}=String[],
        time_zone::String="0", type::String="FULL")
        params = Dict{String,Any}()
        single_symbol = false
        if !isempty(symbol)
            params["symbol"] = symbol
            single_symbol = true
        elseif !isempty(symbols)
            params["symbols"] = symbols
        end
        if time_zone != "0"
            params["timeZone"] = time_zone
        end
        if type != "FULL"
            params["type"] = type
        end
        response = send_request(client, "ticker.tradingDay", params)
        if single_symbol
            return type == "FULL" ? JSON3.read(JSON3.write(response), TradingDayTicker) : JSON3.read(JSON3.write(response), TradingDayTickerMini)
        else
            return type == "FULL" ? JSON3.read(JSON3.write(response), Vector{TradingDayTicker}) : JSON3.read(JSON3.write(response), Vector{TradingDayTickerMini})
        end
    end

    function ticker(client::WebSocketClient; symbol::String="", symbols::Vector{String}=String[],
        window_size::String="1d", type::String="FULL")
        params = Dict{String,Any}()
        single_symbol = false
        if !isempty(symbol)
            params["symbol"] = symbol
            single_symbol = true
        elseif !isempty(symbols)
            params["symbols"] = symbols
        end
        if window_size != "1d"
            params["windowSize"] = window_size
        end
        if type != "FULL"
            params["type"] = type
        end
        response = send_request(client, "ticker", params)
        if single_symbol
            return type == "FULL" ? JSON3.read(JSON3.write(response), RollingWindowTicker) : JSON3.read(JSON3.write(response), RollingWindowTickerMini)
        else
            return type == "FULL" ? JSON3.read(JSON3.write(response), Vector{RollingWindowTicker}) : JSON3.read(JSON3.write(response), Vector{RollingWindowTickerMini})
        end
    end

    function ticker_price(client::WebSocketClient; symbol::String="", symbols::Vector{String}=String[])
        params = Dict{String,Any}()
        single_symbol = false
        if !isempty(symbol)
            params["symbol"] = symbol
            single_symbol = true
        elseif !isempty(symbols)
            params["symbols"] = symbols
        end
        response = send_request(client, "ticker.price", params)
        return single_symbol ? JSON3.read(JSON3.write(response), PriceTicker) : JSON3.read(JSON3.write(response), Vector{PriceTicker})
    end

    function ticker_book(client::WebSocketClient; symbol::String="", symbols::Vector{String}=String[])
        params = Dict{String,Any}()
        single_symbol = false
        if !isempty(symbol)
            params["symbol"] = symbol
            single_symbol = true
        elseif !isempty(symbols)
            params["symbols"] = symbols
        end
        response = send_request(client, "ticker.book", params)
        return single_symbol ? JSON3.read(JSON3.write(response), BookTicker) : JSON3.read(JSON3.write(response), Vector{BookTicker})
    end

    # --- Caching and Validation ---

    """
        get_cached_exchange_info!(client::WebSocketClient)

    Fetches and caches the exchange information if it hasn't been already.
    """
    function get_cached_exchange_info!(client::WebSocketClient)
        if isnothing(client.exchange_info)
            # The WebSocket API's exchangeInfo response needs to be converted to the ExchangeInfo struct
            raw_info = exchangeInfo(client)
            # A bit of a hack: convert the NamedTuple to a JSON string and then parse it
            json_str = JSON3.write(raw_info)
            client.exchange_info = JSON3.read(json_str, ExchangeInfo)
        end
        return client.exchange_info
    end


    # --- Trading Functions ---

    """
        place_order(client, symbol, side, type; kwargs...)

    Place a new order via WebSocket API.

    # Arguments
    - `client::WebSocketClient`: WebSocket client instance
    - `symbol::String`: Trading symbol (e.g., "BTCUSDT")
    - `side::String`: Order side ("BUY" or "SELL")
    - `type::String`: Order type ("LIMIT", "MARKET", "STOP_LOSS", etc.)

    # Optional Arguments
    - `timeInForce::String`: Time in force ("GTC", "IOC", "FOK")
    - `price::Union{Float64,String}`: Order price (required for LIMIT orders)
    - `quantity::Union{Float64,String}`: Order quantity
    - `quoteOrderQty::Union{Float64,String}`: Quote order quantity
    - `newClientOrderId::String`: Custom client order ID
    - `stopPrice::Union{Float64,String}`: Stop price for stop orders
    - `trailingDelta::Int`: Trailing delta for trailing stop orders
    - `icebergQty::Union{Float64,String}`: Iceberg quantity
    - `newOrderRespType::String`: Response type ("ACK", "RESULT", "FULL")
    - `strategyId::Int`: Strategy ID
    - `strategyType::Int`: Strategy type
    - `selfTradePreventionMode::String`: Self trade prevention mode
    """
    function place_order(
        client::WebSocketClient, symbol::String, side::String, type::String;
        timeInForce::String="", price::Union{Float64,String,Nothing}=nothing,
        quantity::Union{Float64,String,Nothing}=nothing, quoteOrderQty::Union{Float64,String,Nothing}=nothing,
        newClientOrderId::String="", stopPrice::Union{Float64,String,Nothing}=nothing,
        trailingDelta::Union{Int,Nothing}=nothing, icebergQty::Union{Float64,String,Nothing}=nothing,
        newOrderRespType::String="FULL", strategyId::Union{Int,Nothing}=nothing,
        strategyType::Union{Int,Nothing}=nothing, selfTradePreventionMode::String="",
        pegPriceType::String="", pegOffsetValue::Union{Int,Nothing}=nothing, pegOffsetType::String=""
    )

        # --- Validation ---
        exchange_info = get_cached_exchange_info!(client)
        symbol_info = nothing
        for s in exchange_info.symbols
            if s.symbol == symbol
                symbol_info = s
                break
            end
        end
        if isnothing(symbol_info)
            throw(ArgumentError("Symbol $symbol not found in exchange info."))
        end

        # --- Parameter Preparation ---
        params = Dict{String,Any}(
            "symbol" => symbol,
            "side" => side,
            "type" => type
        )

        # Add optional parameters
        !isempty(timeInForce) && (params["timeInForce"] = timeInForce)
        !isnothing(price) && (params["price"] = string(price))
        !isnothing(quantity) && (params["quantity"] = string(quantity))
        !isnothing(quoteOrderQty) && (params["quoteOrderQty"] = string(quoteOrderQty))
        !isempty(newClientOrderId) && (params["newClientOrderId"] = newClientOrderId)
        !isnothing(stopPrice) && (params["stopPrice"] = string(stopPrice))
        !isnothing(trailingDelta) && (params["trailingDelta"] = trailingDelta)
        !isnothing(icebergQty) && (params["icebergQty"] = string(icebergQty))
        !isempty(newOrderRespType) && (params["newOrderRespType"] = newOrderRespType)
        !isnothing(strategyId) && (params["strategyId"] = strategyId)
        !isnothing(strategyType) && (params["strategyType"] = strategyType)
        !isempty(selfTradePreventionMode) && (params["selfTradePreventionMode"] = selfTradePreventionMode)
        !isempty(pegPriceType) && (params["pegPriceType"] = pegPriceType)
        !isnothing(pegOffsetValue) && (params["pegOffsetValue"] = pegOffsetValue)
        !isempty(pegOffsetType) && (params["pegOffsetType"] = pegOffsetType)

        # --- Perform Validation ---
        validate_order(params, symbol_info.filters)

        return send_signed_request(client, "order.place", params)
    end

    """
        order_test(client, symbol, side, type; kwargs...)

    Test order placement without sending to matching engine.
    """
    function test_order(client::WebSocketClient, symbol::String, side::String, type::String;
        computeCommissionRates::Bool=false,
        kwargs...)

        params = Dict{String,Any}(
            "symbol" => symbol,
            "side" => side,
            "type" => type,
            "computeCommissionRates" => computeCommissionRates
        )

        # Add any additional parameters from kwargs
        for (key, value) in kwargs
            if !isnothing(value) && !isempty(string(value))
                params[string(key)] = isa(value, Number) ? value : string(value)
            end
        end

        return send_signed_request(client, "order.test", params)
    end

    """
        order_status(client, symbol; orderId, origClientOrderId)

    Query order status.
    """
    function order_status(client::WebSocketClient, symbol::String;
        orderId::Union{Int,Nothing}=nothing,
        origClientOrderId::String="")

        params = Dict{String,Any}("symbol" => symbol)

        if !isnothing(orderId)
            params["orderId"] = orderId
        elseif !isempty(origClientOrderId)
            params["origClientOrderId"] = origClientOrderId
        else
            error("Either orderId or origClientOrderId must be provided")
        end

        return send_signed_request(client, "order.status", params)
    end

    """
        order_cancel(client, symbol; kwargs...)

    Cancel an active order.
    """
    function cancel_order(client::WebSocketClient, symbol::String;
        orderId::Union{Int,Nothing}=nothing,
        origClientOrderId::String="",
        newClientOrderId::String="",
        cancelRestrictions::String="")

        params = Dict{String,Any}("symbol" => symbol)

        if !isnothing(orderId)
            params["orderId"] = orderId
        elseif !isempty(origClientOrderId)
            params["origClientOrderId"] = origClientOrderId
        else
            error("Either orderId or origClientOrderId must be provided")
        end

        !isempty(newClientOrderId) && (params["newClientOrderId"] = newClientOrderId)
        !isempty(cancelRestrictions) && (params["cancelRestrictions"] = cancelRestrictions)

        return send_signed_request(client, "order.cancel", params)
    end

    """
        order_cancel_replace(client, symbol, cancelReplaceMode, side, type; kwargs...)

    Cancel an existing order and place a new order.
    """
    function cancel_replace_order(
        client::WebSocketClient, symbol::String, cancelReplaceMode::String, side::String, type::String;
        cancelOrderId::Union{Int,Nothing}=nothing, cancelOrigClientOrderId::String="",
        cancelNewClientOrderId::String="", cancelRestrictions::String="", orderRateLimitExceededMode::String="DO_NOTHING",
        pegPriceType::String="", pegOffsetValue::Union{Int,Nothing}=nothing, pegOffsetType::String="", kwargs...
    )

        params = Dict{String,Any}(
            "symbol" => symbol,
            "cancelReplaceMode" => cancelReplaceMode,
            "side" => side,
            "type" => type
        )

        # Cancel parameters
        if !isnothing(cancelOrderId)
            params["cancelOrderId"] = cancelOrderId
        elseif !isempty(cancelOrigClientOrderId)
            params["cancelOrigClientOrderId"] = cancelOrigClientOrderId
        else
            error("Either cancelOrderId or cancelOrigClientOrderId must be provided")
        end

        !isempty(cancelNewClientOrderId) && (params["cancelNewClientOrderId"] = cancelNewClientOrderId)
        !isempty(cancelRestrictions) && (params["cancelRestrictions"] = cancelRestrictions)
        !isempty(orderRateLimitExceededMode) && (params["orderRateLimitExceededMode"] = orderRateLimitExceededMode)
        !isempty(pegPriceType) && (params["pegPriceType"] = pegPriceType)
        !isnothing(pegOffsetValue) && (params["pegOffsetValue"] = pegOffsetValue)
        !isempty(pegOffsetType) && (params["pegOffsetType"] = pegOffsetType)

        # Add new order parameters from kwargs
        for (key, value) in kwargs
            if !isnothing(value) && !isempty(string(value))
                params[string(key)] = isa(value, Number) ? value : string(value)
            end
        end

        return send_signed_request(client, "order.cancelReplace", params)
    end

    """
        order_amend_keep_priority(client, symbol; kwargs...)

    Reduce the quantity of an existing open order while keeping priority.
    """
    function amend_order(
        client::WebSocketClient, symbol::String; orderId::Union{Int,Nothing}=nothing,
        origClientOrderId::String="", newClientOrderId::String="", newQty::Union{Float64,String,Nothing}=nothing
    )

        params = Dict{String,Any}("symbol" => symbol)

        if !isnothing(orderId)
            params["orderId"] = orderId
        elseif !isempty(origClientOrderId)
            params["origClientOrderId"] = origClientOrderId
        else
            error("Either orderId or origClientOrderId must be provided")
        end

        if isnothing(newQty)
            error("newQty is required")
        end
        params["newQty"] = string(newQty)

        !isempty(newClientOrderId) && (params["newClientOrderId"] = newClientOrderId)

        return send_signed_request(client, "order.amend.keepPriority", params)
    end

    """
        open_orders_cancel_all(client, symbol)

    Cancel all open orders on a symbol.
    """
    function cancel_all_orders(client::WebSocketClient, symbol::String)
        params = Dict{String,Any}("symbol" => symbol)
        return send_signed_request(client, "openOrders.cancelAll", params)
    end

    # --- Order List Functions ---

    """
        order_list_place_oco(client, symbol, side, quantity, aboveType, belowType; kwargs...)

    Place a new OCO (One-Cancels-the-Other) order list.
    """
    function place_oco_order(
        client::WebSocketClient, symbol::String, side::String, quantity::Float64, aboveType::String, belowType::String;
        listClientOrderId::String="", aboveClientOrderId::String="", aboveIcebergQty::Union{Float64,Nothing}=nothing,
        abovePrice::Union{Float64,Nothing}=nothing, aboveStopPrice::Union{Float64,Nothing}=nothing, aboveTrailingDelta::Union{Int,Nothing}=nothing,
        aboveTimeInForce::String="", aboveStrategyId::Union{Int,Nothing}=nothing, aboveStrategyType::Union{Int,Nothing}=nothing,
        abovePegPriceType::String="", abovePegOffsetType::String="", abovePegOffsetValue::Union{Int,Nothing}=nothing, belowClientOrderId::String="",
        belowIcebergQty::Union{Float64,Nothing}=nothing, belowPrice::Union{Float64,Nothing}=nothing, belowStopPrice::Union{Float64,Nothing}=nothing,
        belowTrailingDelta::Union{Int,Nothing}=nothing, belowTimeInForce::String="", belowStrategyId::Union{Int,Nothing}=nothing,
        belowStrategyType::Union{Int,Nothing}=nothing, belowPegPriceType::String="", belowPegOffsetType::String="",
        belowPegOffsetValue::Union{Int,Nothing}=nothing, newOrderRespType::String="FULL", selfTradePreventionMode::String="")

        params = Dict{String,Any}(
            "symbol" => symbol,
            "side" => side,
            "quantity" => string(quantity),
            "aboveType" => aboveType,
            "belowType" => belowType
        )

        # Add optional parameters
        !isempty(listClientOrderId) && (params["listClientOrderId"] = listClientOrderId)
        !isempty(newOrderRespType) && (params["newOrderRespType"] = newOrderRespType)
        !isempty(selfTradePreventionMode) && (params["selfTradePreventionMode"] = selfTradePreventionMode)

        # Above order parameters
        !isempty(aboveClientOrderId) && (params["aboveClientOrderId"] = aboveClientOrderId)
        !isnothing(aboveIcebergQty) && (params["aboveIcebergQty"] = string(aboveIcebergQty))
        !isnothing(abovePrice) && (params["abovePrice"] = string(abovePrice))
        !isnothing(aboveStopPrice) && (params["aboveStopPrice"] = string(aboveStopPrice))
        !isnothing(aboveTrailingDelta) && (params["aboveTrailingDelta"] = aboveTrailingDelta)
        !isempty(aboveTimeInForce) && (params["aboveTimeInForce"] = aboveTimeInForce)
        !isnothing(aboveStrategyId) && (params["aboveStrategyId"] = aboveStrategyId)
        !isnothing(aboveStrategyType) && (params["aboveStrategyType"] = aboveStrategyType)
        !isempty(abovePegPriceType) && (params["abovePegPriceType"] = abovePegPriceType)
        !isempty(abovePegOffsetType) && (params["abovePegOffsetType"] = abovePegOffsetType)
        !isnothing(abovePegOffsetValue) && (params["abovePegOffsetValue"] = abovePegOffsetValue)

        # Below order parameters
        !isempty(belowClientOrderId) && (params["belowClientOrderId"] = belowClientOrderId)
        !isnothing(belowIcebergQty) && (params["belowIcebergQty"] = string(belowIcebergQty))
        !isnothing(belowPrice) && (params["belowPrice"] = string(belowPrice))
        !isnothing(belowStopPrice) && (params["belowStopPrice"] = string(belowStopPrice))
        !isnothing(belowTrailingDelta) && (params["belowTrailingDelta"] = belowTrailingDelta)
        !isempty(belowTimeInForce) && (params["belowTimeInForce"] = belowTimeInForce)
        !isnothing(belowStrategyId) && (params["belowStrategyId"] = belowStrategyId)
        !isnothing(belowStrategyType) && (params["belowStrategyType"] = belowStrategyType)
        !isempty(belowPegPriceType) && (params["belowPegPriceType"] = belowPegPriceType)
        !isempty(belowPegOffsetType) && (params["belowPegOffsetType"] = belowPegOffsetType)
        !isnothing(belowPegOffsetValue) && (params["belowPegOffsetValue"] = belowPegOffsetValue)

        return send_signed_request(client, "orderList.place.oco", params)
    end

    """
        order_list_place_oto(client, symbol, workingType, workingSide, workingPrice, workingQuantity, pendingType, pendingSide, pendingQuantity; kwargs...)

    Place a new OTO (One-Triggers-the-Other) order list.
    """
    function place_oto_order(
        client::WebSocketClient, symbol::String, workingType::String, workingSide::String, workingPrice::Float64,
        workingQuantity::Float64, pendingType::String, pendingSide::String, pendingQuantity::Float64;
        listClientOrderId::String="", newOrderRespType::String="FULL", selfTradePreventionMode::String="", workingClientOrderId::String="",
        workingIcebergQty::Union{Float64,Nothing}=nothing, workingTimeInForce::String="", workingStrategyId::Union{Int,Nothing}=nothing,
        workingStrategyType::Union{Int,Nothing}=nothing, workingPegPriceType::String="", workingPegOffsetType::String="",
        workingPegOffsetValue::Union{Int,Nothing}=nothing, pendingClientOrderId::String="", pendingPrice::Union{Float64,Nothing}=nothing,
        pendingStopPrice::Union{Float64,Nothing}=nothing, pendingTrailingDelta::Union{Int,Nothing}=nothing,
        pendingIcebergQty::Union{Float64,Nothing}=nothing, pendingTimeInForce::String="", pendingStrategyId::Union{Int,Nothing}=nothing,
        pendingStrategyType::Union{Int,Nothing}=nothing, pendingPegPriceType::String="", pendingPegOffsetType::String="", pendingPegOffsetValue::Union{Int,Nothing}=nothing
    )

        params = Dict{String,Any}(
            "symbol" => symbol,
            "workingType" => workingType,
            "workingSide" => workingSide,
            "workingPrice" => string(workingPrice),
            "workingQuantity" => string(workingQuantity),
            "pendingType" => pendingType,
            "pendingSide" => pendingSide,
            "pendingQuantity" => string(pendingQuantity)
        )

        # Add optional parameters
        !isempty(listClientOrderId) && (params["listClientOrderId"] = listClientOrderId)
        !isempty(newOrderRespType) && (params["newOrderRespType"] = newOrderRespType)
        !isempty(selfTradePreventionMode) && (params["selfTradePreventionMode"] = selfTradePreventionMode)

        # Working order parameters
        !isempty(workingClientOrderId) && (params["workingClientOrderId"] = workingClientOrderId)
        !isnothing(workingIcebergQty) && (params["workingIcebergQty"] = string(workingIcebergQty))
        !isempty(workingTimeInForce) && (params["workingTimeInForce"] = workingTimeInForce)
        !isnothing(workingStrategyId) && (params["workingStrategyId"] = workingStrategyId)
        !isnothing(workingStrategyType) && (params["workingStrategyType"] = workingStrategyType)
        !isempty(workingPegPriceType) && (params["workingPegPriceType"] = workingPegPriceType)
        !isempty(workingPegOffsetType) && (params["workingPegOffsetType"] = workingPegOffsetType)
        !isnothing(workingPegOffsetValue) && (params["workingPegOffsetValue"] = workingPegOffsetValue)

        # Pending order parameters
        !isempty(pendingClientOrderId) && (params["pendingClientOrderId"] = pendingClientOrderId)
        !isnothing(pendingPrice) && (params["pendingPrice"] = string(pendingPrice))
        !isnothing(pendingStopPrice) && (params["pendingStopPrice"] = string(pendingStopPrice))
        !isnothing(pendingTrailingDelta) && (params["pendingTrailingDelta"] = pendingTrailingDelta)
        !isnothing(pendingIcebergQty) && (params["pendingIcebergQty"] = string(pendingIcebergQty))
        !isempty(pendingTimeInForce) && (params["pendingTimeInForce"] = pendingTimeInForce)
        !isnothing(pendingStrategyId) && (params["pendingStrategyId"] = pendingStrategyId)
        !isnothing(pendingStrategyType) && (params["pendingStrategyType"] = pendingStrategyType)
        !isempty(pendingPegPriceType) && (params["pendingPegPriceType"] = pendingPegPriceType)
        !isempty(pendingPegOffsetType) && (params["pendingPegOffsetType"] = pendingPegOffsetType)
        !isnothing(pendingPegOffsetValue) && (params["pendingPegOffsetValue"] = pendingPegOffsetValue)

        return send_signed_request(client, "orderList.place.oto", params)
    end

    """
        order_list_place_otoco(client, symbol, workingType, workingSide, workingPrice, workingQuantity, pendingSide, pendingQuantity, pendingAboveType, pendingBelowType; kwargs...)

    Place a new OTOCO (One-Triggers-One-Cancels-the-Other) order list.
    """
    function place_otoco_order(
        client::WebSocketClient, symbol::String, workingType::String, workingSide::String, workingPrice::Float64,
        workingQuantity::Float64, pendingSide::String, pendingQuantity::Float64, pendingAboveType::String; kwargs...
    )

        params = Dict{String,Any}(
            "symbol" => symbol,
            "workingType" => workingType,
            "workingSide" => workingSide,
            "workingPrice" => string(workingPrice),
            "workingQuantity" => string(workingQuantity),
            "pendingSide" => pendingSide,
            "pendingQuantity" => string(pendingQuantity),
            "pendingAboveType" => pendingAboveType
        )

        # Add any additional parameters from kwargs
        for (key, value) in kwargs
            if !isnothing(value) && !isempty(string(value))
                params[string(key)] = isa(value, Number) ? value : string(value)
            end
        end

        return send_signed_request(client, "orderList.place.otoco", params)
    end

    """
        order_list_cancel(client, symbol; kwargs...)

    Cancel an active order list.
    """
    function cancel_order_list(client::WebSocketClient, symbol::String;
        orderListId::Union{Int,Nothing}=nothing,
        listClientOrderId::String="",
        newClientOrderId::String="")

        params = Dict{String,Any}("symbol" => symbol)

        if !isnothing(orderListId)
            params["orderListId"] = orderListId
        elseif !isempty(listClientOrderId)
            params["listClientOrderId"] = listClientOrderId
        else
            error("Either orderListId or listClientOrderId must be provided")
        end

        !isempty(newClientOrderId) && (params["newClientOrderId"] = newClientOrderId)

        return send_signed_request(client, "orderList.cancel", params)
    end

    # --- SOR Functions ---

    """
        sor_order_place(client, symbol, side, type, quantity; kwargs...)

    Place a new order using smart order routing (SOR).
    """
    function place_sor_order(client::WebSocketClient, symbol::String, side::String, type::String,
        quantity::Union{Float64,String};
        timeInForce::String="",
        price::Union{Float64,String,Nothing}=nothing,
        newClientOrderId::String="",
        newOrderRespType::String="FULL",
        icebergQty::Union{Float64,String,Nothing}=nothing,
        strategyId::Union{Int,Nothing}=nothing,
        strategyType::Union{Int,Nothing}=nothing,
        selfTradePreventionMode::String="")

        params = Dict{String,Any}(
            "symbol" => symbol,
            "side" => side,
            "type" => type,
            "quantity" => string(quantity)
        )

        # Add optional parameters
        !isempty(timeInForce) && (params["timeInForce"] = timeInForce)
        !isnothing(price) && (params["price"] = string(price))
        !isempty(newClientOrderId) && (params["newClientOrderId"] = newClientOrderId)
        !isempty(newOrderRespType) && (params["newOrderRespType"] = newOrderRespType)
        !isnothing(icebergQty) && (params["icebergQty"] = string(icebergQty))
        !isnothing(strategyId) && (params["strategyId"] = strategyId)
        !isnothing(strategyType) && (params["strategyType"] = strategyType)
        !isempty(selfTradePreventionMode) && (params["selfTradePreventionMode"] = selfTradePreventionMode)

        return send_signed_request(client, "sor.order.place", params)
    end

    """
        sor_order_test(client, symbol, side, type, quantity; kwargs...)

    Test new order creation using smart order routing (SOR).
    """
    function test_sor_order(client::WebSocketClient, symbol::String, side::String, type::String,
        quantity::Union{Float64,String};
        computeCommissionRates::Bool=false,
        kwargs...)

        params = Dict{String,Any}(
            "symbol" => symbol,
            "side" => side,
            "type" => type,
            "quantity" => string(quantity),
            "computeCommissionRates" => computeCommissionRates
        )

        # Add any additional parameters from kwargs
        for (key, value) in kwargs
            if !isnothing(value) && !isempty(string(value))
                params[string(key)] = isa(value, Number) ? value : string(value)
            end
        end

        return send_signed_request(client, "sor.order.test", params)
    end

    # --- Account Functions ---

    """
        account_status(client)

    Query account information.
    """
    function account_status(client::WebSocketClient)
        response = send_signed_request(client, "account.status", Dict{String,Any}())
        return JSON3.read(JSON3.write(response), AccountInfo)
    end

    """
        account_rate_limits_orders(client)

    Query current order count usage for all rate limiters.
    """
    function account_rate_limits_orders(client::WebSocketClient)
        return send_signed_request(client, "account.rateLimits.orders", Dict{String,Any}())
    end

    """
        orders_open(client; symbol)

    Query current open orders.
    """
    function orders_open(client::WebSocketClient; symbol::String="")
        params = Dict{String,Any}()
        !isempty(symbol) && (params["symbol"] = symbol)
        return send_signed_request(client, "openOrders.status", params)
    end

    """
        orders_all(client, symbol; kwargs...)

    Query all orders.
    """
    function orders_all(client::WebSocketClient, symbol::String;
        orderId::Union{Int,Nothing}=nothing,
        startTime::Union{Int,Nothing}=nothing,
        endTime::Union{Int,Nothing}=nothing,
        limit::Int=500)

        params = Dict{String,Any}(
            "symbol" => symbol,
            "limit" => limit
        )

        !isnothing(orderId) && (params["orderId"] = orderId)
        !isnothing(startTime) && (params["startTime"] = startTime)
        !isnothing(endTime) && (params["endTime"] = endTime)

        return send_signed_request(client, "allOrders", params)
    end

    """
        my_trades(client, symbol; kwargs...)

    Query account trade list.
    """
    function my_trades(client::WebSocketClient, symbol::String;
        orderId::Union{Int,Nothing}=nothing,
        startTime::Union{Int,Nothing}=nothing,
        endTime::Union{Int,Nothing}=nothing,
        fromId::Union{Int,Nothing}=nothing,
        limit::Int=500)

        params = Dict{String,Any}(
            "symbol" => symbol,
            "limit" => limit
        )

        !isnothing(orderId) && (params["orderId"] = orderId)
        !isnothing(startTime) && (params["startTime"] = startTime)
        !isnothing(endTime) && (params["endTime"] = endTime)
        !isnothing(fromId) && (params["fromId"] = fromId)

        return send_signed_request(client, "my_trades", params)
    end

    """
        open_orders_status(client; symbol)

    Query execution status of all open orders.
    """
    function open_orders_status(client::WebSocketClient; symbol::String="")
        params = Dict{String,Any}()
        !isempty(symbol) && (params["symbol"] = symbol)
        return send_signed_request(client, "openOrders.status", params)
    end

    """
        all_orders(client, symbol; kwargs...)

    Query information about all orders – active, canceled, filled – filtered by time range.
    """
    function all_orders(client::WebSocketClient, symbol::String;
        orderId::Union{Int,Nothing}=nothing,
        startTime::Union{Int,Nothing}=nothing,
        endTime::Union{Int,Nothing}=nothing,
        limit::Int=500)

        params = Dict{String,Any}(
            "symbol" => symbol,
            "limit" => limit
        )

        !isnothing(orderId) && (params["orderId"] = orderId)
        !isnothing(startTime) && (params["startTime"] = startTime)
        !isnothing(endTime) && (params["endTime"] = endTime)

        return send_signed_request(client, "allOrders", params)
    end

    """
        order_list_status(client; orderListId, origClientOrderId)

    Check execution status of an Order list.
    """
    function order_list_status(client::WebSocketClient;
        orderListId::Union{Int,Nothing}=nothing,
        origClientOrderId::String="")

        params = Dict{String,Any}()

        if !isnothing(orderListId)
            params["orderListId"] = orderListId
        elseif !isempty(origClientOrderId)
            params["origClientOrderId"] = origClientOrderId
        else
            throw(ArgumentError("Either orderListId or origClientOrderId must be provided"))
        end

        return send_signed_request(client, "orderList.status", params)
    end

    """
        open_order_lists_status(client)

    Query execution status of all open order lists.
    """
    function open_order_lists_status(client::WebSocketClient)
        return send_signed_request(client, "openOrderLists.status", Dict{String,Any}())
    end

    """
        all_order_lists(client; kwargs...)

    Query information about all order lists, filtered by time range.
    """
    function all_order_lists(client::WebSocketClient;
        fromId::Union{Int,Nothing}=nothing,
        startTime::Union{Int,Nothing}=nothing,
        endTime::Union{Int,Nothing}=nothing,
        limit::Int=500)

        params = Dict{String,Any}("limit" => limit)

        !isnothing(fromId) && (params["fromId"] = fromId)
        !isnothing(startTime) && (params["startTime"] = startTime)
        !isnothing(endTime) && (params["endTime"] = endTime)

        return send_signed_request(client, "allOrderLists", params)
    end

    """
        my_prevented_matches(client, symbol; kwargs...)

    Displays the list of orders that were expired due to STP.
    """
    function my_prevented_matches(client::WebSocketClient, symbol::String;
        preventedMatchId::Union{Int,Nothing}=nothing,
        orderId::Union{Int,Nothing}=nothing,
        fromPreventedMatchId::Union{Int,Nothing}=nothing,
        limit::Int=500)

        params = Dict{String,Any}(
            "symbol" => symbol,
            "limit" => limit
        )

        !isnothing(preventedMatchId) && (params["preventedMatchId"] = preventedMatchId)
        !isnothing(orderId) && (params["orderId"] = orderId)
        !isnothing(fromPreventedMatchId) && (params["fromPreventedMatchId"] = fromPreventedMatchId)

        return send_signed_request(client, "myPreventedMatches", params)
    end

    """
        my_allocations(client, symbol; kwargs...)

    Retrieves allocations resulting from SOR order placement.
    """
    function my_allocations(client::WebSocketClient, symbol::String;
        startTime::Union{Int,Nothing}=nothing,
        endTime::Union{Int,Nothing}=nothing,
        fromAllocationId::Union{Int,Nothing}=nothing,
        limit::Int=500,
        orderId::Union{Int,Nothing}=nothing)

        params = Dict{String,Any}(
            "symbol" => symbol,
            "limit" => limit
        )

        !isnothing(startTime) && (params["startTime"] = startTime)
        !isnothing(endTime) && (params["endTime"] = endTime)
        !isnothing(fromAllocationId) && (params["fromAllocationId"] = fromAllocationId)
        !isnothing(orderId) && (params["orderId"] = orderId)

        return send_signed_request(client, "myAllocations", params)
    end

    """
        account_commission(client, symbol)

    Get current account commission rates.
    """
    function account_commission(client::WebSocketClient, symbol::String)
        params = Dict{String,Any}("symbol" => symbol)
        return send_signed_request(client, "account.commission", params)
    end

    """
        order_amendments(client, symbol, orderId; kwargs...)

    Queries all amendments of a single order.
    """
    function order_amendments(client::WebSocketClient, symbol::String, orderId::Int;
        fromExecutionId::Union{Int,Nothing}=nothing,
        limit::Int=500)

        params = Dict{String,Any}(
            "symbol" => symbol,
            "orderId" => orderId,
            "limit" => limit
        )

        !isnothing(fromExecutionId) && (params["fromExecutionId"] = fromExecutionId)

        return send_signed_request(client, "order.amendments", params)
    end

    # --- User Data Stream Functions ---

    """
        user_data_stream_start(client)

    Start a new user data stream.
    """
    function user_data_stream_start(client::WebSocketClient)
        return send_signed_request(client, "userDataStream.start", Dict{String,Any}())
    end

    """
        user_data_stream_ping(client, listenKey)

    Ping/Keep-alive a user data stream.
    """
    function user_data_stream_ping(client::WebSocketClient, listenKey::String)
        params = Dict{String,Any}("listenKey" => listenKey)
        return send_signed_request(client, "userDataStream.ping", params)
    end

    """
        user_data_stream_stop(client, listenKey)

    Close a user data stream.
    """
    function user_data_stream_stop(client::WebSocketClient, listenKey::String)
        params = Dict{String,Any}("listenKey" => listenKey)
        return send_signed_request(client, "userDataStream.stop", params)
    end

    """
        userdata_stream_subscribe(client)

    Subscribe to the User Data Stream in the current WebSocket connection.
    This method requires an authenticated WebSocket connection using Ed25519 keys.
    """
    function userdata_stream_subscribe(client::WebSocketClient)
        return send_request(client, "userDataStream.subscribe", Dict{String,Any}())
    end

    """
        userdata_stream_unsubscribe(client; subscriptionId)

    Stop listening to the User Data Stream in the current WebSocket connection.
    When called with no subscriptionId parameter, this will close all subscriptions.
    When called with subscriptionId, this will attempt to close that specific subscription.
    """
    function userdata_stream_unsubscribe(client::WebSocketClient; subscriptionId::Union{Int,Nothing}=nothing)
        params = Dict{String,Any}()
        !isnothing(subscriptionId) && (params["subscriptionId"] = subscriptionId)
        return send_request(client, "userDataStream.unsubscribe", params)
    end

    """
        session_subscriptions(client)

    List all active User Data Stream subscriptions in the current session.
    """
    function session_subscriptions(client::WebSocketClient)
        return send_request(client, "session.subscriptions", Dict{String,Any}())
    end

    """
        userdata_stream_subscribe_signature(client, apiKey, timestamp, signature)

    Subscribe to User Data Stream using signature subscription for a specific API key.
    This allows subscribing to User Data Stream for any account with valid API key and signature.
    """
    function userdata_stream_subscribe_signature(client::WebSocketClient, apiKey::String, timestamp::Int, signature::String)
        params = Dict{String,Any}(
            "apiKey" => apiKey,
            "timestamp" => timestamp,
            "signature" => signature
        )
        return send_request(client, "userDataStream.subscribe.signature", params)
    end

end # module WebSocketAPI
