module RESTAPI

    using HTTP, JSON3, Dates, SHA, URIs, StructTypes
    using FixedPointDecimals
    using ..Config
    using ..Signature
    using ..RateLimiter
    using ..Signature: HMAC_SHA256, ED25519, RSA
    using ..Types
    using ..Filters
    using ..Errors

    export RESTClient, make_request, get_server_time, get_exchange_info, ping,
        place_order, cancel_order, cancel_all_orders, get_order,
        get_open_orders, get_all_orders, get_orderbook,
        get_order_list, get_all_order_lists, get_open_order_lists,
        get_my_trades, get_recent_trades, get_historical_trades, get_agg_trades,
        get_klines, get_symbol_ticker, get_ticker_24hr, get_ticker_book,
        get_ui_klines, get_avg_price, get_trading_day_ticker, get_ticker,
        test_order, cancel_replace_order, amend_order, place_oco_order,
        place_oto_order, place_otoco_order, place_opo_order, place_opoco_order,
        cancel_order_list, place_sor_order, test_sor_order, get_my_filters

    """
    A client for interacting with the Binance REST API.
    """
    mutable struct RESTClient
        config::BinanceConfig
        signer::CryptoSigner
        rate_limiter::BinanceRateLimit
        time_offset::Int64
        exchange_info::Union{ExchangeInfo, Nothing}
        symbol_cache::Dict{String, SymbolInfo}  # 缓存 symbol -> SymbolInfo 映射

        function RESTClient(config_path::String="config.toml")
            config = from_toml(config_path)
            rate_limiter = BinanceRateLimit(config)

            signer = if config.signature_method == HMAC_SHA256
                HmacSigner(config.api_secret)
            elseif config.signature_method == ED25519
                Ed25519Signer(config.private_key_path, config.private_key_pass)
            elseif config.signature_method == RSA
                RsaSigner(config.private_key_path)
            else
                error("Unsupported signature method: $(config.signature_method)")
            end

            client = new(config, signer, rate_limiter, 0, nothing, Dict{String, SymbolInfo}())

            try
                server_time_response = get_server_time(client)
                server_time = Int64(round(datetime2unix(server_time_response) * 1000))
                local_time = Int(round(datetime2unix(now(Dates.UTC)) * 1000))
                client.time_offset = server_time - local_time
            catch e
                @warn "Could not synchronize time with Binance server for REST client. Using local time. Error: $e"
                client.time_offset = 0
            end

            return client
        end
    end

    function get_base_url(client::RESTClient)
        return client.config.testnet ? "https://testnet.binance.vision" : "https://api.binance.com"
    end

    function generate_signature(client::RESTClient, query_string::String)
        return sign_message(client.signer, query_string)
    end

    function get_timestamp(client::RESTClient)
        return Int(round(datetime2unix(now(Dates.UTC)) * 1000)) + client.time_offset
    end

    function build_headers(client::RESTClient)
        # 返回类型稳定的 Vector{Pair{String,String}}
        if !isempty(client.config.api_key)
            return ["X-MBX-APIKEY" => client.config.api_key]
        else
            return Pair{String,String}[]
        end
    end

    function build_query_string(params::Dict{String,Any})
        if isempty(params)
            return ""
        end

        encoded_pairs = String[]
        for k in sort(collect(keys(params)))
            encoded_key = URIs.escapeuri(string(k))
            value = params[k]
            encoded_value = if isa(value, AbstractVector)
                URIs.escapeuri(JSON3.write(value))
            else
                URIs.escapeuri(string(value))
            end
            push!(encoded_pairs, "$encoded_key=$encoded_value")
        end

        return join(encoded_pairs, "&")
    end

    function build_signed_query_string(client::RESTClient, params::Dict{String,Any})
        params["timestamp"] = get_timestamp(client)
        # The recvWindow parameter is used to specify the number of milliseconds after the timestamp that the request is valid for.
        # If the request is received after recvWindow milliseconds from the timestamp, it will be rejected.
        # The value of recvWindow can be up to 60000. It now supports microseconds.
        params["recvWindow"] = client.config.recv_window

        query_string = build_query_string(params)
        signature = generate_signature(client, query_string)
        encoded_signature = URIs.escapeuri(signature)

        return "$query_string&signature=$encoded_signature"
    end

    function handle_error(client::RESTClient, response)
        status = response.status
        body = String(response.body)
        headers = response.headers
        code = 0
        msg = body

        try
            json_body = JSON3.read(body)
            if haskey(json_body, :code) && haskey(json_body, :msg)
                code = json_body.code
                msg = json_body.msg
            end
        catch
            # Ignore JSON parsing errors
        end

        if status == 429 || status == 418
            # 避免使用 filter 闭包，直接循环查找
            for h in headers
                if lowercase(h[1]) == "retry-after"
                    retry_seconds = parse(Int, h[2])
                    set_backoff!(client.rate_limiter, retry_seconds)
                    break
                end
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
            @warn "Binance Server Error (http_status=$(status), code=$(code), msg=\"$(msg)\"). Execution status is UNKNOWN."
            throw(BinanceServerError(status, code, msg))
        else
            throw(BinanceError(status, code, msg))
        end
    end

    function make_request(
        client::RESTClient, method::String, endpoint::String;
        params::Dict{String,Any}=Dict{String,Any}(), signed::Bool=false
        )
        request_type = occursin("/api/v3/order", endpoint) ? "ORDERS" : "REQUEST_WEIGHT"
        check_and_wait(client.rate_limiter, request_type)

        url = get_base_url(client) * endpoint
        body = ""
        headers = build_headers(client)

        if signed
            query_string = build_signed_query_string(client, params)
            url *= "?$query_string"
        elseif !isempty(params)
            if method == "GET" || method == "DELETE"
                query_string = build_query_string(params)
                url *= "?$query_string"
            elseif method in ("POST", "PUT")
                body = build_query_string(params)
                push!(headers, "Content-Type" => "application/x-www-form-urlencoded")
            end
        end

        try
            proxy_url = isempty(client.config.proxy) ? nothing : client.config.proxy
            # Use direct keyword args to avoid Dict allocation on every request
            if !isempty(body)
                if proxy_url !== nothing
                    response = HTTP.request(method, url; headers=headers, body=body, proxy=proxy_url)
                else
                    response = HTTP.request(method, url; headers=headers, body=body)
                end
            else
                if proxy_url !== nothing
                    response = HTTP.request(method, url; headers=headers, proxy=proxy_url)
                else
                    response = HTTP.request(method, url; headers=headers)
                end
            end

            if response.status in (200, 201, 202)
                return JSON3.read(String(response.body))
            else
                handle_error(client, response)
            end
        catch e
            if e isa HTTP.ExceptionRequest.StatusError
                handle_error(client, e.response)
            else
                rethrow(e)
            end
        end
    end

    # --- General API Functions ---

    function get_server_time(client::RESTClient)
        response = make_request(client, "GET", "/api/v3/time")
        return unix2datetime(response.serverTime / 1000)
    end

    function get_exchange_info(client::RESTClient; symbol::String="", symbols::Vector{String}=String[], permissions::Vector{String}=String[])
        params = Dict{String,Any}()
        if !isempty(symbol)
            params["symbol"] = validate_symbol(symbol)
        elseif !isempty(symbols)
            params["symbols"] = JSON3.write(symbols)
        elseif !isempty(permissions)
            params["permissions"] = JSON3.write(permissions)
        end

        response = make_request(client, "GET", "/api/v3/exchangeInfo"; params=params)
        return to_struct(ExchangeInfo, response)
    end

    function ping(client::RESTClient)
        return make_request(client, "GET", "/api/v3/ping")
    end

    # --- Caching and Validation ---

    """
        get_cached_exchange_info!(client::RESTClient)

    Fetches and caches the exchange information if it hasn't been already.
    Also builds a symbol lookup cache for O(1) symbol info retrieval.
    """
    function get_cached_exchange_info!(client::RESTClient)
        if isnothing(client.exchange_info)
            client.exchange_info = get_exchange_info(client)
            # 构建 symbol 缓存用于 O(1) 查找
            empty!(client.symbol_cache)
            for s in client.exchange_info.symbols
                client.symbol_cache[s.symbol] = s
            end
        end
        return client.exchange_info
    end

    """
        get_symbol_info(client::RESTClient, symbol::String) -> Union{SymbolInfo, Nothing}

    Get SymbolInfo for a symbol using cached lookup (O(1) instead of O(n)).
    """
    function get_symbol_info(client::RESTClient, symbol::String)
        get_cached_exchange_info!(client)
        return get(client.symbol_cache, symbol, nothing)
    end

    # --- Trading Functions ---

    function place_order(
        client::RESTClient, symbol::String, side::String, order_type::String;
        quantity::Union{Float64,String,FixedDecimal,Nothing}=nothing,
        quote_order_qty::Union{Float64,String,FixedDecimal,Nothing}=nothing,
        price::Union{Float64,String,FixedDecimal,Nothing}=nothing,
        new_client_order_id::String="",
        stop_price::Union{Float64,String,FixedDecimal,Nothing}=nothing,
        iceberg_qty::Union{Float64,String,FixedDecimal,Nothing}=nothing,
        time_in_force::String="GTC",
        new_order_resp_type::String="ACK"
        )

        # --- Validation (使用 O(1) 缓存查找) ---
        symbol_info = get_symbol_info(client, symbol)
        if isnothing(symbol_info)
            throw(ArgumentError("Symbol $symbol not found in exchange info."))
        end

        # --- Parameter Preparation ---
        side = validate_side(side)
        order_type = validate_order_type(order_type)
        time_in_force = validate_time_in_force(time_in_force)

        params = Dict{String,Any}(
            "symbol" => symbol,
            "side" => side,
            "type" => order_type,
            "newOrderRespType" => new_order_resp_type
        )

        if order_type in ("LIMIT", "STOP_LOSS_LIMIT", "TAKE_PROFIT_LIMIT", "LIMIT_MAKER")
            params["timeInForce"] = time_in_force
            if isnothing(price)
                throw(ArgumentError("Price is required for $(order_type) orders"))
            end
            params["price"] = to_decimal_string(price)
        end

        if order_type in ("STOP_LOSS", "STOP_LOSS_LIMIT", "TAKE_PROFIT", "TAKE_PROFIT_LIMIT")
            if isnothing(stop_price)
                throw(ArgumentError("Stop price is required for $(order_type) orders"))
            end
            params["stopPrice"] = to_decimal_string(stop_price)
        end

        if !isnothing(quantity)
            params["quantity"] = to_decimal_string(quantity)
        elseif !isnothing(quote_order_qty)
            params["quoteOrderQty"] = to_decimal_string(quote_order_qty)
        else
            throw(ArgumentError("Either quantity or quoteOrderQty must be specified"))
        end

        if !isempty(new_client_order_id)
            params["newClientOrderId"] = new_client_order_id
        end

        if !isnothing(iceberg_qty)
            params["icebergQty"] = to_decimal_string(iceberg_qty)
        end

        # --- Perform Validation ---
        validate_order(params, symbol_info.filters)

        response = make_request(client, "POST", "/api/v3/order"; params=params, signed=true)
        # Convert JSON3.Object to Dict to allow modification
        response_dict = Dict{Symbol,Any}(pairs(response))
        if haskey(response_dict, :transactTime)
            response_dict[:transactTime] = unix2datetime(response_dict[:transactTime] / 1000)
        end
        return response_dict
    end

    function test_order(
        client::RESTClient, symbol::String, side::String, order_type::String;
        compute_commission_rates::Bool=false,
        kwargs...
    )
        params = Dict{String,Any}(kwargs)
        params[:symbol] = symbol
        params[:side] = side
        params[:type] = order_type
        params[:computeCommissionRates] = compute_commission_rates

        return make_request(client, "POST", "/api/v3/order/test"; params=params, signed=true)
    end

    function cancel_order(
        client::RESTClient, symbol::String;
        order_id::Union{Int,Nothing}=nothing,
        orig_client_order_id::String="",
        new_client_order_id::String="")

        symbol = validate_symbol(symbol)
        params = Dict{String,Any}("symbol" => symbol)

        if !isnothing(order_id)
            params["orderId"] = order_id
        elseif !isempty(orig_client_order_id)
            params["origClientOrderId"] = orig_client_order_id
        else
            throw(ArgumentError("Either orderId or origClientOrderId must be specified"))
        end

        if !isempty(new_client_order_id)
            params["newClientOrderId"] = new_client_order_id
        end

        response = make_request(client, "DELETE", "/api/v3/order"; params=params, signed=true)
        # Convert JSON3.Object to Dict to allow modification
        response_dict = Dict{Symbol,Any}(pairs(response))
        if haskey(response_dict, :transactTime)
            response_dict[:transactTime] = unix2datetime(response_dict[:transactTime] / 1000)
        end
        return response_dict
    end

    function cancel_all_orders(client::RESTClient, symbol::String)
        symbol = validate_symbol(symbol)
        params = Dict{String,Any}("symbol" => symbol)
        return make_request(client, "DELETE", "/api/v3/openOrders"; params=params, signed=true)
    end

    function cancel_replace_order(
        client::RESTClient, symbol::String, side::String, order_type::String,
        cancel_replace_mode::String; kwargs...
    )

        params = Dict{String,Any}(kwargs)
        params[:symbol] = symbol
        params[:side] = side
        params[:type] = order_type
        params[:cancelReplaceMode] = cancel_replace_mode

        return make_request(client, "POST", "/api/v3/order/cancelReplace"; params=params, signed=true)
    end

    function amend_order(
        client::RESTClient, symbol::String, new_qty::Float64;
        order_id::Union{Int,Nothing}=nothing, orig_client_order_id::String="",
        new_client_order_id::String=""
    )

        params = Dict{String,Any}("symbol" => symbol, "newQty" => new_qty)

        if !isnothing(order_id)
            params["orderId"] = order_id
        elseif !isempty(orig_client_order_id)
            params["origClientOrderId"] = orig_client_order_id
        else
            throw(ArgumentError("Either orderId or origClientOrderId must be specified"))
        end

        if !isempty(new_client_order_id)
            params["newClientOrderId"] = new_client_order_id
        end

        return make_request(client, "PUT", "/api/v3/order/amend/keepPriority"; params=params, signed=true)
    end

    function get_order(
        client::RESTClient, symbol::String;
        order_id::Union{Int,Nothing}=nothing,
        orig_client_order_id::String="")

        symbol = validate_symbol(symbol)
        params = Dict{String,Any}("symbol" => symbol)

        if !isnothing(order_id)
            params["orderId"] = order_id
        elseif !isempty(orig_client_order_id)
            params["origClientOrderId"] = orig_client_order_id
        else
            throw(ArgumentError("Either orderId or origClientOrderId must be specified"))
        end

        response = make_request(client, "GET", "/api/v3/order"; params=params, signed=true)
        return to_struct(Order, response)
    end

    function get_open_orders(client::RESTClient; symbol::String="")
        params = Dict{String,Any}()
        if !isempty(symbol)
            params["symbol"] = validate_symbol(symbol)
        end

        response = make_request(client, "GET", "/api/v3/openOrders"; params=params, signed=true)
        return to_struct(Vector{Order}, response)
    end

    function get_all_orders(
        client::RESTClient, symbol::String;
        order_id::Union{Int,Nothing}=nothing,
        start_time::Int=0,
        end_time::Int=0,
        limit::Int=500)

        symbol = validate_symbol(symbol)
        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000"))
        end

        params = Dict{String,Any}(
            "symbol" => symbol,
            "limit" => limit
        )

        if !isnothing(order_id)
            params["orderId"] = order_id
        end
        if start_time > 0
            params["startTime"] = start_time
        end
        if end_time > 0
            params["endTime"] = end_time
        end

        response = make_request(client, "GET", "/api/v3/allOrders"; params=params, signed=true)
        return to_struct(Vector{Order}, response)
    end

    function get_my_filters(client::RESTClient; symbol::String="")
        params = Dict{String,Any}()
        if !isempty(symbol)
            params["symbol"] = validate_symbol(symbol)
        end

        return make_request(client, "GET", "/api/v3/myFilters"; params=params, signed=true)
    end

    function get_my_trades(
        client::RESTClient, symbol::String;
        start_time::Int=0,
        end_time::Int=0,
        from_id::Int=0,
        limit::Int=500)

        symbol = validate_symbol(symbol)
        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000"))
        end

        params = Dict{String,Any}(
            "symbol" => symbol,
            "limit" => limit
        )

        if start_time > 0
            params["startTime"] = start_time
        end
        if end_time > 0
            params["endTime"] = end_time
        end
        if from_id > 0
            params["fromId"] = from_id
        end

        response = make_request(client, "GET", "/api/v3/myTrades"; params=params, signed=true)
        return to_struct(Vector{Trade}, response)
    end

    function get_order_list(
        client::RESTClient;
        order_list_id::Union{Int,Nothing}=nothing,
        orig_client_order_id::String=""
    )
        params = Dict{String,Any}()
        if !isnothing(order_list_id)
            params["orderListId"] = order_list_id
        elseif !isempty(orig_client_order_id)
            params["origClientOrderId"] = orig_client_order_id
        else
            throw(ArgumentError("Either orderListId or origClientOrderId must be provided"))
        end
        response = make_request(client, "GET", "/api/v3/orderList"; params=params, signed=true)
        # Convert JSON3.Object to Dict to allow modification
        response_dict = Dict{Symbol,Any}(pairs(response))
        response_dict[:transactionTime] = unix2datetime(response_dict[:transactionTime] / 1000)
        return response_dict
    end

    function get_all_order_lists(
        client::RESTClient;
        from_id::Union{Int,Nothing}=nothing,
        start_time::Union{Int,Nothing}=nothing,
        end_time::Union{Int,Nothing}=nothing,
        limit::Int=500
    )
        params = Dict{String,Any}("limit" => limit)
        if !isnothing(from_id)
            params["fromId"] = from_id
        elseif !isnothing(start_time)
            params["startTime"] = start_time
        end
        if !isnothing(end_time)
            params["endTime"] = end_time
        end
        response = make_request(client, "GET", "/api/v3/allOrderList"; params=params, signed=true)
        for order_list in response
            order_list[:transactionTime] = unix2datetime(order_list[:transactionTime] / 1000)
        end
        return response
    end

    function get_open_order_lists(client::RESTClient)
        return make_request(client, "GET", "/api/v3/openOrderList"; signed=true)
    end

    function place_oco_order(
        client::RESTClient, symbol::String, side::String, quantity::Union{Float64,String,FixedDecimal},
        above_type::String, below_type::String; kwargs...
    )
        params = Dict{String,Any}(kwargs)
        params[:symbol] = symbol
        params[:side] = side
        params[:quantity] = quantity
        params[:aboveType] = above_type
        params[:belowType] = below_type

        return make_request(client, "POST", "/api/v3/orderList/oco"; params=params, signed=true)
    end

    function place_oto_order(
        client::RESTClient, symbol::String, working_type::String, working_side::String,
        working_price::Union{Float64,String,FixedDecimal}, working_quantity::Union{Float64,String,FixedDecimal}, pending_type::String,
        pending_side::String, pending_quantity::Union{Float64,String,FixedDecimal}; kwargs...
    )
        params = Dict{String,Any}(kwargs)
        params[:symbol] = symbol
        params[:workingType] = working_type
        params[:workingSide] = working_side
        params[:workingPrice] = working_price
        params[:workingQuantity] = working_quantity
        params[:pendingType] = pending_type
        params[:pendingSide] = pending_side
        params[:pendingQuantity] = pending_quantity

        return make_request(client, "POST", "/api/v3/orderList/oto"; params=params, signed=true)
    end

    function place_otoco_order(
        client::RESTClient, symbol::String, working_type::String, working_side::String,
        working_price::Union{Float64,String,FixedDecimal}, working_quantity::Union{Float64,String,FixedDecimal}, pending_side::String,
        pending_quantity::Union{Float64,String,FixedDecimal}, pending_above_type::String; kwargs...
    )
        params = Dict{String,Any}(kwargs)
        params[:symbol] = symbol
        params[:workingType] = working_type
        params[:workingSide] = working_side
        params[:workingPrice] = working_price
        params[:workingQuantity] = working_quantity
        params[:pendingSide] = pending_side
        params[:pendingQuantity] = pending_quantity
        params[:pendingAboveType] = pending_above_type

        return make_request(client, "POST", "/api/v3/orderList/otoco"; params=params, signed=true)
    end

    """
        place_opo_order(client, symbol, trigger_price, working_type, working_side,
                        working_quantity; kwargs...)

    Place a One-Pays-the-Other (OPO) order list.

    OPO allows you to place a trigger order that, when conditions are met, places a
    working order. If the working order fills, the trigger is canceled.

    # Required Parameters
    - `symbol`: Trading pair symbol (e.g., "BTCUSDT")
    - `trigger_price`: Price at which the pending order will be triggered
    - `working_type`: Type of the working order ("LIMIT" or "LIMIT_MAKER")
    - `working_side`: Side of the working order ("BUY" or "SELL")
    - `working_quantity`: Quantity for the working order

    # Optional Parameters (via kwargs)
    - `listClientOrderId`: Unique id for the order list
    - `workingClientOrderId`: Unique id for the working order
    - `workingPrice`: Price for the working order (required for LIMIT orders)
    - `workingTimeInForce`: Time in force for working order
    - `workingIcebergQty`: Iceberg quantity for working order
    - `workingSelfTradePreventionMode`: STP mode for working order
    - `pendingType`: Type of pending order (default: "LIMIT")
    - `pendingSide`: Side of pending order
    - `pendingQuantity`: Quantity for pending order
    - `pendingPrice`: Price for pending order
    - `pendingStopPrice`: Stop price for pending order
    - `pendingTrailingDelta`: Trailing delta for pending order
    - `pendingTimeInForce`: Time in force for pending order
    - `pendingIcebergQty`: Iceberg quantity for pending order
    - `pendingSelfTradePreventionMode`: STP mode for pending order
    - `triggerPriceDirection`: Direction for trigger price ("UP" or "DOWN")
    - `newOrderRespType`: Response type ("ACK", "RESULT", or "FULL")
    - `selfTradePreventionMode`: STP mode for the order list

    # Returns
    Order list response with details of both orders.

    # Example
    ```julia
    # Place an OPO order: trigger a limit buy when price drops
    place_opo_order(client, "BTCUSDT", 50000.0, "LIMIT", "BUY", 0.001;
        workingPrice=49500.0,
        workingTimeInForce="GTC"
    )
    ```

    # Note
    Available after 2025-12-18. Check `opoAllowed` in exchange info for symbol support.
    """
    function place_opo_order(
        client::RESTClient, symbol::String, trigger_price::Union{Float64,String,FixedDecimal},
        working_type::String, working_side::String,
        working_quantity::Union{Float64,String,FixedDecimal}; kwargs...
    )
        params = Dict{String,Any}(kwargs)
        params[:symbol] = symbol
        params[:triggerPrice] = to_decimal_string(trigger_price)
        params[:workingType] = working_type
        params[:workingSide] = working_side
        params[:workingQuantity] = to_decimal_string(working_quantity)

        return make_request(client, "POST", "/api/v3/orderList/opo"; params=params, signed=true)
    end

    """
        place_opoco_order(client, symbol, trigger_price, working_type, working_side,
                          working_quantity, pending_side, pending_quantity,
                          pending_above_type; kwargs...)

    Place a One-Pays-the-Other-with-Contingent-Order (OPOCO) order list.

    OPOCO combines OPO with OCO: places a trigger order that, when conditions are met,
    places an OCO order pair. This allows for complex order strategies.

    # Required Parameters
    - `symbol`: Trading pair symbol (e.g., "BTCUSDT")
    - `trigger_price`: Price at which the pending orders will be triggered
    - `working_type`: Type of the working order ("LIMIT" or "LIMIT_MAKER")
    - `working_side`: Side of the working order ("BUY" or "SELL")
    - `working_quantity`: Quantity for the working order
    - `pending_side`: Side of pending OCO orders
    - `pending_quantity`: Quantity for pending orders
    - `pending_above_type`: Type of the pending above order

    # Optional Parameters (via kwargs)
    - `listClientOrderId`: Unique id for the order list
    - `workingClientOrderId`: Unique id for working order
    - `workingPrice`: Price for working order
    - `workingTimeInForce`: Time in force for working order
    - `workingIcebergQty`: Iceberg quantity for working order
    - `workingSelfTradePreventionMode`: STP mode for working order
    - `pendingAboveClientOrderId`: Unique id for pending above order
    - `pendingAbovePrice`: Price for pending above order
    - `pendingAboveStopPrice`: Stop price for pending above order
    - `pendingAboveTrailingDelta`: Trailing delta for pending above order
    - `pendingAboveTimeInForce`: Time in force for pending above order
    - `pendingAboveIcebergQty`: Iceberg quantity for pending above order
    - `pendingBelowType`: Type of pending below order
    - `pendingBelowClientOrderId`: Unique id for pending below order
    - `pendingBelowPrice`: Price for pending below order
    - `pendingBelowStopPrice`: Stop price for pending below order
    - `pendingBelowTrailingDelta`: Trailing delta for pending below order
    - `pendingBelowTimeInForce`: Time in force for pending below order
    - `pendingBelowIcebergQty`: Iceberg quantity for pending below order
    - `triggerPriceDirection`: Direction for trigger price ("UP" or "DOWN")
    - `newOrderRespType`: Response type ("ACK", "RESULT", or "FULL")
    - `selfTradePreventionMode`: STP mode for the order list

    # Returns
    Order list response with details of all orders.

    # Example
    ```julia
    # Place OPOCO: when price hits trigger, place an OCO for take-profit/stop-loss
    place_opoco_order(client, "BTCUSDT", 50000.0, "LIMIT", "BUY", 0.001,
        "SELL", 0.001, "TAKE_PROFIT_LIMIT";
        workingPrice=49500.0,
        pendingAbovePrice=52000.0,
        pendingAboveStopPrice=51500.0,
        pendingBelowType="STOP_LOSS_LIMIT",
        pendingBelowPrice=48000.0,
        pendingBelowStopPrice=48500.0
    )
    ```

    # Note
    Available after 2025-12-18. Check `opoAllowed` in exchange info for symbol support.
    """
    function place_opoco_order(
        client::RESTClient, symbol::String, trigger_price::Union{Float64,String,FixedDecimal},
        working_type::String, working_side::String,
        working_quantity::Union{Float64,String,FixedDecimal}, pending_side::String,
        pending_quantity::Union{Float64,String,FixedDecimal}, pending_above_type::String; kwargs...
    )
        params = Dict{String,Any}(kwargs)
        params[:symbol] = symbol
        params[:triggerPrice] = to_decimal_string(trigger_price)
        params[:workingType] = working_type
        params[:workingSide] = working_side
        params[:workingQuantity] = to_decimal_string(working_quantity)
        params[:pendingSide] = pending_side
        params[:pendingQuantity] = to_decimal_string(pending_quantity)
        params[:pendingAboveType] = pending_above_type

        return make_request(client, "POST", "/api/v3/orderList/opoco"; params=params, signed=true)
    end

    function cancel_order_list(
        client::RESTClient, symbol::String; order_list_id::Union{Int,Nothing}=nothing,
        list_client_order_id::String="", new_client_order_id::String=""
    )
        params = Dict{String,Any}("symbol" => symbol)

        if !isnothing(order_list_id)
            params["orderListId"] = order_list_id
        elseif !isempty(list_client_order_id)
            params["listClientOrderId"] = list_client_order_id
        else
            throw(ArgumentError("Either orderListId or listClientOrderId must be provided"))
        end

        if !isempty(new_client_order_id)
            params["newClientOrderId"] = new_client_order_id
        end

        return make_request(client, "DELETE", "/api/v3/orderList"; params=params, signed=true)
    end

    function place_sor_order(
        client::RESTClient, symbol::String, side::String, order_type::String, quantity::Float64;
        kwargs...
    )
        params = Dict{String,Any}(kwargs)
        params[:symbol] = symbol
        params[:side] = side
        params[:type] = order_type
        params[:quantity] = quantity

        return make_request(client, "POST", "/api/v3/sor/order"; params=params, signed=true)
    end

    function test_sor_order(
        client::RESTClient, symbol::String, side::String, order_type::String, quantity::Float64;
        compute_commission_rates::Bool=false, kwargs...
    )
        params = Dict{String,Any}(kwargs)
        params[:symbol] = symbol
        params[:side] = side
        params[:type] = order_type
        params[:quantity] = quantity
        params[:computeCommissionRates] = compute_commission_rates

        return make_request(client, "POST", "/api/v3/sor/order/test"; params=params, signed=true)
    end

    # --- Market Data Functions ---

    function get_orderbook(client::RESTClient, symbol::String; limit::Int=100, symbolStatus::String="")
        symbol = validate_symbol(symbol)
        if !(limit in (5, 10, 20, 50, 100, 500, 1000, 5000))
            throw(ArgumentError("Invalid limit. Valid limits: 5, 10, 20, 50, 100, 500, 1000, 5000"))
        end

        params = Dict{String,Any}(
            "symbol" => symbol,
            "limit" => limit
        )

        if !isempty(symbolStatus)
            params["symbolStatus"] = symbolStatus
        end

        return make_request(client, "GET", "/api/v3/depth"; params=params)
    end

    function get_recent_trades(client::RESTClient, symbol::String; limit::Int=500)
        symbol = validate_symbol(symbol)
        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000"))
        end

        params = Dict{String,Any}(
            "symbol" => symbol,
            "limit" => limit
        )
        response = make_request(client, "GET", "/api/v3/trades"; params=params)
        return to_struct(Vector{Trade}, response)
    end

    function get_historical_trades(client::RESTClient, symbol::String; limit::Int=500, from_id::Int=0)
        symbol = validate_symbol(symbol)
        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000"))
        end

        params = Dict{String,Any}(
            "symbol" => symbol,
            "limit" => limit
        )
        if from_id > 0
            params["fromId"] = from_id
        end

        response = make_request(client, "GET", "/api/v3/historicalTrades"; params=params)
        return to_struct(Vector{Trade}, response)
    end

    function get_agg_trades(client::RESTClient, symbol::String;
        limit::Int=500, from_id::Int=0, start_time::Int=0, end_time::Int=0)
        symbol = validate_symbol(symbol)
        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000"))
        end

        params = Dict{String,Any}(
            "symbol" => symbol,
            "limit" => limit
        )

        if from_id > 0
            params["fromId"] = from_id
        end
        if start_time > 0
            params["startTime"] = start_time
        end
        if end_time > 0
            params["endTime"] = end_time
        end

        response = make_request(client, "GET", "/api/v3/aggTrades"; params=params)
        for trade in response
            trade[:T] = unix2datetime(trade[:T] / 1000)
        end
        return response
    end

    function get_klines(client::RESTClient, symbol::String, interval::String;
        limit::Int=500, start_time::Int=0, end_time::Int=0)
        symbol = validate_symbol(symbol)
        interval = validate_interval(interval)

        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000"))
        end

        params = Dict{String,Any}(
            "symbol" => symbol,
            "interval" => interval,
            "limit" => limit
        )

        if start_time > 0
            params["startTime"] = start_time
        end
        if end_time > 0
            params["endTime"] = end_time
        end

        response = make_request(client, "GET", "/api/v3/klines"; params=params)
        return to_struct(Vector{Kline}, response)
    end

    function get_symbol_ticker(client::RESTClient; symbol::String="", symbols::Vector{String}=String[], symbolStatus::String="")
        params = Dict{String,Any}()
        if !isempty(symbol)
            params["symbol"] = validate_symbol(symbol)
        elseif !isempty(symbols)
            params["symbols"] = JSON3.write(symbols)
        end

        if !isempty(symbolStatus)
            params["symbolStatus"] = symbolStatus
        end

        return make_request(client, "GET", "/api/v3/ticker/price"; params=params)
    end

    function get_ticker_24hr(client::RESTClient; symbol::String="", symbols::Vector{String}=String[], symbolStatus::String="")
        params = Dict{String,Any}()
        if !isempty(symbol)
            params["symbol"] = validate_symbol(symbol)
        elseif !isempty(symbols)
            params["symbols"] = JSON3.write(symbols)
        end

        if !isempty(symbolStatus)
            params["symbolStatus"] = symbolStatus
        end

        response = make_request(client, "GET", "/api/v3/ticker/24hr"; params=params)

        if isa(response, Vector)
            # Convert each element in the vector to Dict and modify
            return map(response) do ticker
                ticker_dict = Dict{Symbol,Any}(pairs(ticker))
                ticker_dict[:openTime] = unix2datetime(ticker_dict[:openTime] / 1000)
                ticker_dict[:closeTime] = unix2datetime(ticker_dict[:closeTime] / 1000)
                ticker_dict
            end
        else
            # Convert single response to Dict
            response_dict = Dict{Symbol,Any}(pairs(response))
            response_dict[:openTime] = unix2datetime(response_dict[:openTime] / 1000)
            response_dict[:closeTime] = unix2datetime(response_dict[:closeTime] / 1000)
            return response_dict
        end
    end

    function get_ticker_book(client::RESTClient; symbol::String="", symbols::Vector{String}=String[], symbolStatus::String="")
        params = Dict{String,Any}()
        if !isempty(symbol)
            params["symbol"] = validate_symbol(symbol)
        elseif !isempty(symbols)
            params["symbols"] = JSON3.write(symbols)
        end

        if !isempty(symbolStatus)
            params["symbolStatus"] = symbolStatus
        end

        return make_request(client, "GET", "/api/v3/ticker/bookTicker"; params=params)
    end

    function get_ui_klines(
        client::RESTClient, symbol::String, interval::String;
        limit::Int=500, start_time::Int=0, end_time::Int=0, time_zone::String=""
    )

        symbol = validate_symbol(symbol)
        interval = validate_interval(interval)

        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000"))
        end

        params = Dict{String,Any}(
            "symbol" => symbol,
            "interval" => interval,
            "limit" => limit
        )

        if start_time > 0
            params["startTime"] = start_time
        end
        if end_time > 0
            params["endTime"] = end_time
        end
        if !isempty(time_zone)
            params["timeZone"] = time_zone
        end

        response = make_request(client, "GET", "/api/v3/uiKlines"; params=params)
        return to_struct(Vector{Kline}, response)
    end

    function get_avg_price(client::RESTClient, symbol::String)
        symbol = validate_symbol(symbol)
        params = Dict{String,Any}("symbol" => symbol)
        response = make_request(client, "GET", "/api/v3/avgPrice"; params=params)
        # Convert JSON3.Object to Dict to allow modification
        response_dict = Dict{Symbol,Any}(pairs(response))
        response_dict[:closeTime] = unix2datetime(response_dict[:closeTime] / 1000)
        return response_dict
    end

    function get_trading_day_ticker(client::RESTClient; symbol::String="", symbols::Vector{String}=[], time_zone::String="", type::String="FULL", symbolStatus::String="")
        params = Dict{String,Any}()
        if !isempty(symbol)
            params["symbol"] = validate_symbol(symbol)
        elseif !isempty(symbols)
            params["symbols"] = JSON3.write(validate_symbol.(symbols))
        else
            throw(ArgumentError("Either symbol or symbols must be provided"))
        end

        if !isempty(time_zone)
            params["timeZone"] = time_zone
        end

        params["type"] = type

        if !isempty(symbolStatus)
            params["symbolStatus"] = symbolStatus
        end

        response = make_request(client, "GET", "/api/v3/ticker/tradingDay"; params=params)

        if isa(response, Vector)
            # Convert each element in the vector to Dict and modify
            return map(response) do ticker
                ticker_dict = Dict{Symbol,Any}(pairs(ticker))
                ticker_dict[:openTime] = unix2datetime(ticker_dict[:openTime] / 1000)
                ticker_dict[:closeTime] = unix2datetime(ticker_dict[:closeTime] / 1000)
                ticker_dict
            end
        else
            # Convert single response to Dict
            response_dict = Dict{Symbol,Any}(pairs(response))
            response_dict[:openTime] = unix2datetime(response_dict[:openTime] / 1000)
            response_dict[:closeTime] = unix2datetime(response_dict[:closeTime] / 1000)
            return response_dict
        end
    end

    function get_ticker(client::RESTClient; symbol::String="", symbols::Vector{String}=[], window_size::String="1d", type::String="FULL", symbolStatus::String="")
        params = Dict{String,Any}()
        if !isempty(symbol)
            params["symbol"] = validate_symbol(symbol)
        elseif !isempty(symbols)
            params["symbols"] = JSON3.write(validate_symbol.(symbols))
        else
            throw(ArgumentError("Either symbol or symbols must be provided"))
        end

        params["windowSize"] = window_size
        params["type"] = type

        if !isempty(symbolStatus)
            params["symbolStatus"] = symbolStatus
        end

        response = make_request(client, "GET", "/api/v3/ticker"; params=params)

        if isa(response, Vector)
            # Convert each element in the vector to Dict and modify
            return map(response) do ticker
                ticker_dict = Dict{Symbol,Any}(pairs(ticker))
                ticker_dict[:openTime] = unix2datetime(ticker_dict[:openTime] / 1000)
                ticker_dict[:closeTime] = unix2datetime(ticker_dict[:closeTime] / 1000)
                ticker_dict
            end
        else
            # Convert single response to Dict
            response_dict = Dict{Symbol,Any}(pairs(response))
            response_dict[:openTime] = unix2datetime(response_dict[:openTime] / 1000)
            response_dict[:closeTime] = unix2datetime(response_dict[:closeTime] / 1000)
            return response_dict
        end
    end

end # module RESTAPI
