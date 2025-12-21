module WebSocketAPI

    using HTTP, JSON3, Dates, SHA, URIs, StructTypes, DataFrames, UUIDs
    using FixedPointDecimals
    import HTTP.WebSockets

    using ..Config, ..Signature, ..Types, ..RESTAPI, ..RateLimiter, ..Account, ..Events, ..Errors

    # ✨✨ 关键步骤 ✨✨
    # 使用 import 关键字，将 RESTAPI.place_order 函数本身引入当前作用域, 为它添加新方法，
    # 而不是创建一个新函数, 只导出自己的类型，不要导出 place_order，因为它不属于这里
    import ..RESTAPI: place_order, cancel_order

    const EVENT_TYPE_MAP = Dict{String,Type}(
        "outboundAccountPosition" => OutboundAccountPosition,
        "executionReport" => ExecutionReport,
        "balanceUpdate" => BalanceUpdate,
        "listStatus" => ListStatus,
        "eventStreamTerminated" => EventStreamTerminated
        # Add other event types here as they are implemented
    )

    # Client and Connection
    export WebSocketClient, connect!, disconnect!, on_event, ensure_connected!,
           remove_event_handler, clear_event_handlers, get_rate_limit_status, 
           get_order_rate_limits

    # Session Management
    export session_logon, session_status, session_logout

    # General Methods
    export ping, time, exchangeInfo

    # Market Data
    export depth, trades_recent, trades_historical, trades_aggregate, klines, ui_klines,
        avg_price, ticker_24hr, ticker_trading_day, ticker, ticker_price, ticker_book

    # Trading
    export test_order, order_status, cancel_replace_order,
        amend_order, cancel_all_orders

    # Order Lists
    export place_oco_order, place_oto_order, place_otoco_order, place_opo_order, place_opoco_order,
        cancel_order_list, order_list_status, open_order_lists_status, all_order_lists

    # SOR (Smart Order Routing)
    export place_sor_order, test_sor_order

    # Account
    export account_status, account_rate_limits_orders, orders_open, all_orders, my_trades,
        open_orders_status, all_orders, my_prevented_matches, my_allocations,
        account_commission, order_amendments, my_filters

    # User Data Stream
    export user_data_stream_start, user_data_stream_ping, user_data_stream_stop,
        userdata_stream_subscribe, userdata_stream_unsubscribe, session_subscriptions,
        userdata_stream_subscribe_signature

    mutable struct WebSocketClient
        config::BinanceConfig
        signer::CryptoSigner
        base_url::String
        ws_connection::Any # Will hold the WebSocket connection
        rate_limiter::BinanceRateLimit
        responses::Dict{String,Channel} # Changed from Int64 to String for UUID keys
        ws_callbacks::Dict{String,Function} # For user data stream events
        time_offset::Int64
        is_authenticated::Bool
        should_reconnect::Bool
        reconnect_task::Union{Task,Nothing}
        reconnect_lock::ReentrantLock
        heartbeat_task::Union{Task,Nothing}
        heartbeat_interval::Int # Interval in seconds for heartbeat pings

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
            client = new(config, signer, base_url, nothing, rate_limiter, Dict{String,Channel}(), Dict{String,Function}(), 0, false, true, nothing, ReentrantLock(), nothing, 60)

            # Initialize time offset to 0. This will be synchronized with the server after the WebSocket connection is established.
            # We don't assume any timezone offset, letting the synchronization handle the actual difference
            client.time_offset = 0

            return client
        end
    end

    """
        get_rate_limit_status(client::WebSocketClient)
    
    Get current rate limit status from the exchange.
    
    Returns the current usage for all rate limit types.
    """
    function get_rate_limit_status(client::WebSocketClient)
        # Use exchangeInfo to get current limits
        response = send_request(client, "exchangeInfo", Dict{String,Any}(); return_full_response=true)
        
        if haskey(response, :rateLimits)
            return response.rateLimits
        else
            @warn "No rate limit information in response"
            return nothing
        end
    end
    
    """
        get_order_rate_limits(client::WebSocketClient)
    
    Query current order count usage for all rate limiters.
    This is an alias for account_rate_limits_orders for consistency.
    """
    function get_order_rate_limits(client::WebSocketClient)
        return account_rate_limits_orders(client)
    end
    
    # --- Helper Functions ---
    
    """
        get_timestamp(client::WebSocketClient)
    
    Get current timestamp in milliseconds, adjusted for time offset.
    """
    function get_timestamp(client::WebSocketClient)
        # Use UTC time directly
        timestamp = Int(round(datetime2unix(now(Dates.UTC)) * 1000)) + client.time_offset
        return timestamp
    end
    
    """
        add_optional_params!(params::Dict{String,Any}, args::Pair...)
    
    Helper function to add optional parameters to a request dictionary.
    Automatically converts numeric values to strings for price/quantity fields.
    """
    function add_optional_params!(params::Dict{String,Any}, args::Pair...)
        for (key, value) in args
            key_str = string(key)
            if !isnothing(value)
                if isa(value, String) && !isempty(value)
                    params[key_str] = value
                elseif isa(value, Number)
                    # Convert price/quantity related fields to strings
                    if occursin(r"(?i)(price|qty|quantity)", key_str)
                        params[key_str] = string(value)
                    else
                        params[key_str] = value
                    end
                elseif !isa(value, String)  # For non-string, non-number types
                    params[key_str] = value
                end
            end
        end
        return params
    end

    function connect!(client::WebSocketClient)
        # Check connection rate limit (300 connections per 5 minutes per IP)
        check_and_wait(client.rate_limiter, "CONNECTIONS")
        
        client.should_reconnect = true
        client.reconnect_task = @async begin
            for attempt in 1:(client.config.max_reconnect_attempts+1)
                if !client.should_reconnect
                    break
                end

                try
                    WebSockets.open(client.base_url; connect_timeout=30, proxy=client.config.proxy) do ws
                        client.ws_connection = ws
                        @info "Successfully connected to WebSocket API."
                        
                        # Start heartbeat task using WebSocket ping frames
                        client.heartbeat_task = @async begin
                            @info "Starting heartbeat task with $(client.heartbeat_interval) second interval"
                            while !isnothing(client.ws_connection) && !WebSockets.isclosed(client.ws_connection)
                                try
                                    sleep(client.heartbeat_interval)
                                    if !isnothing(client.ws_connection) && !WebSockets.isclosed(client.ws_connection)
                                        # Send WebSocket ping frame (not API ping method)
                                        WebSockets.ping(client.ws_connection)
                                        @debug "WebSocket ping frame sent successfully"
                                    end
                                catch e
                                    @warn "WebSocket ping failed: $e"
                                    # Connection might be broken, the main loop will handle reconnection
                                    break
                                end
                            end
                            @info "Heartbeat task stopped"
                        end

                        # Spawn a setup task that runs in the background, allowing the main loop to listen immediately
                        @async begin
                            # Synchronize time with server with retries
                            max_retries = 3
                            retry_count = 0
                            synchronized = false

                            while retry_count < max_retries && !synchronized
                                try
                                    server_time_response = time(client)
                                    server_time = server_time_response.serverTime
                                    local_time = Int(round(datetime2unix(now(Dates.UTC)) * 1000))
                                    client.time_offset = server_time - local_time
                                    @info "Time synchronized with server. Offset: $(client.time_offset)ms"
                                    synchronized = true
                                catch e
                                    retry_count += 1
                                    if retry_count < max_retries
                                        @warn "Failed to synchronize time (attempt $retry_count/$max_retries): $e. Retrying in 2 seconds..."
                                        sleep(2)
                                    else
                                        @error "Could not synchronize time with Binance server after $max_retries attempts. Using offset: $(client.time_offset)ms. Error: $e"
                                    end
                                end
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
                                # Check if this is a binary frame (SBE format - future support)
                                if isa(msg, Vector{UInt8})
                                    @warn "Received binary frame (SBE format). SBE support not yet implemented."
                                    continue
                                end
                                
                                # Parse JSON message
                                data = JSON3.read(String(msg))

                                # Check if this is a response to a request
                                if haskey(data, :id) && haskey(client.responses, string(data.id))
                                    put!(client.responses[string(data.id)], data)
                                # Check if this is a user data stream event
                                else
                                    event_payload = nothing
                                    # Check for wrapped event format first
                                    if haskey(data, :event) && data.event isa JSON3.Object && haskey(data.event, :e)
                                        event_payload = data.event
                                    # Then check for unwrapped event format (like in user data streams)
                                    elseif haskey(data, :e)
                                        event_payload = data
                                    end

                                    if !isnothing(event_payload)
                                        event_type = string(event_payload[:e])
                                        if haskey(client.ws_callbacks, event_type)
                                            try
                                                event_struct = to_struct(EVENT_TYPE_MAP[event_type], event_payload)
                                                client.ws_callbacks[event_type](event_struct)
                                            catch e
                                                @error "Error in event callback for '$event_type': $e"
                                            end
                                        elseif event_type == "eventStreamTerminated"
                                            event_struct = to_struct(EventStreamTerminated, event_payload)
                                            handle_event_stream_terminated!(client, event_struct)
                                        else
                                            @warn "Received unhandled event of type '$(event_type)'"
                                        end
                                    else
                                        @debug "Received message without handler: $data"
                                    end
                                end
                            catch e
                                if e isa WebSockets.WebSocketError || e isa EOFError
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
                    # Stop heartbeat task if running
                    if !isnothing(client.heartbeat_task) && !istaskdone(client.heartbeat_task)
                        @debug "Stopping heartbeat task"
                    end
                    client.heartbeat_task = nothing
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
        on_event(client::WebSocketClient, event_type::String, callback::Function)
    
    Register a callback function for a specific user data stream event type.
    
    # Arguments
    - `client`: WebSocket client instance
    - `event_type`: Event type string (e.g., "outboundAccountPosition", "executionReport")
    - `callback`: Function to call when event is received. Will receive the event payload.
    
    # Event Format
    Events are sent as JSON with structure:
    ```json
    {
        "event": {
            "e": "eventType",
            "E": eventTime,
            // ... event-specific fields
        }
    }
    ```
    
    The callback receives only the inner event object (data.event).
    
    # Example
    ```julia
    on_event(client, "executionReport") do event
        println("Order update: ", event)
    end
    ```
    
    # Common Event Types
    - "outboundAccountPosition": Account balance update
    - "balanceUpdate": Balance change from deposits/withdrawals
    - "executionReport": Order update
    - "listStatus": Order list update
    
    See Binance documentation for complete list of event types.
    """
    function on_event(client::WebSocketClient, event_type::String, callback::Function)
        client.ws_callbacks[event_type] = callback
        @info "Registered callback for event type '$event_type'."
    end
    
    function handle_event_stream_terminated!(client::WebSocketClient, event::EventStreamTerminated)
        event_time = unix2datetime(event.E / 1000)
        @info "User data stream terminated" event_time event_type=event.e
        @info "Reconnect or resubscribe the user data stream as needed." reconnect_enabled=client.should_reconnect
    end
    
    """
        remove_event_handler(client::WebSocketClient, event_type::String)
    
    Remove a previously registered event handler.
    """
    function remove_event_handler(client::WebSocketClient, event_type::String)
        if haskey(client.ws_callbacks, event_type)
            delete!(client.ws_callbacks, event_type)
            @info "Removed callback for event type '$event_type'."
        else
            @warn "No callback registered for event type '$event_type'."
        end
    end
    
    """
        clear_event_handlers(client::WebSocketClient)
    
    Remove all registered event handlers.
    """
    function clear_event_handlers(client::WebSocketClient)
        empty!(client.ws_callbacks)
        @info "Cleared all event callbacks."
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

    function ensure_connected!(client::WebSocketClient)
        lock(client.reconnect_lock) do
            # If connection is already established, do nothing.
            if !isnothing(client.ws_connection) && !WebSockets.isclosed(client.ws_connection)
                return
            end

            # If no connection task is running, start one.
            if isnothing(client.reconnect_task) || istaskdone(client.reconnect_task)
                connect!(client)
                # Wait for connection to establish
                wait_time = 0
                while isnothing(client.ws_connection) && wait_time < 30
                    sleep(0.5)
                    wait_time += 0.5
                end
                if isnothing(client.ws_connection)
                    error("Failed to establish WebSocket connection after 30 seconds")
                end
            end
        end
    end

    function handle_ws_error(client::WebSocketClient, response)
        status = response.status
        
        # Check if error field exists (it should for all error responses)
        if !haskey(response, :error)
            @error "Invalid error response format: missing 'error' field"
            throw(BinanceError(status, -1, "Invalid error response format"))
        end
        
        error_data = response.error
        code = haskey(error_data, :code) ? error_data.code : -1
        msg = haskey(error_data, :msg) ? error_data.msg : "Unknown error"

        # Handle specific status codes according to Binance spec
        if status == 401 # Unauthorized
            client.is_authenticated = false
            @warn "WebSocket session authentication failed or was revoked (status 401)."
            throw(UnauthorizedError(code, msg))
        elseif status == 403
            # Web Application Firewall block
            throw(WAFViolationError())
        elseif status == 409
            # Partial success/failure
            throw(CancelReplacePartialSuccess(code, msg))
        elseif status == 418
            # Auto-banned for rate limit violations
            if haskey(error_data, :data) && haskey(error_data.data, :retryAfter)
                retry_after = error_data.data.retryAfter
                set_backoff!(client.rate_limiter, retry_after)
            end
            throw(IPAutoBannedError())
        elseif status == 429
            # Rate limit exceeded
            if haskey(error_data, :data) && haskey(error_data.data, :retryAfter)
                retry_after = error_data.data.retryAfter
                set_backoff!(client.rate_limiter, retry_after)
            end
            throw(RateLimitError(code, msg))
        elseif 400 <= status < 500
            # Client error
            throw(MalformedRequestError(code, msg))
        elseif 500 <= status < 600
            # Server error - execution status unknown!
            @warn "Binance Server Error (status=$status, code=$code, msg=\"$msg\"). Execution status is UNKNOWN - request might have succeeded!"
            throw(BinanceServerError(status, code, msg))
        else
            # Unknown status
            throw(BinanceError(status, code, msg))
        end
    end

    """
        send_request(client, method, params; kwargs...)
    
    Send a request to Binance WebSocket API.
    
    # Arguments
    - `client`: WebSocket client instance
    - `method`: API method name (e.g., "order.place", "ping")
    - `params`: Request parameters (will be omitted if empty)
    
    # Keyword Arguments
    - `return_rate_limits`: Include rate limit info in response
    - `return_full_response`: Return full response instead of just result
    - `api_version`: API version prefix (e.g., "v3")
    - `request_id_type`: Type of request ID (:uuid, :timestamp, :sequential)
    """
    function send_request(
        client::WebSocketClient, method::String, params::Dict{String,Any}; 
        return_rate_limits::Union{Bool,Nothing}=nothing, return_full_response::Bool=false, 
        api_version::String="", request_id_type::Symbol=:uuid
        )
        ensure_connected!(client)

        # Proactively check rate limits
        check_and_wait(client.rate_limiter, "REQUEST_WEIGHT")

        # Generate request ID based on specified type
        request_id = if request_id_type == :uuid
            string(uuid4())
        elseif request_id_type == :timestamp
            string(Int(round(datetime2unix(now()) * 1000)))
        elseif request_id_type == :sequential
            string(Int(round(time() * 1000000)))  # Microsecond precision for uniqueness
        else
            throw(ArgumentError("Invalid request_id_type: $request_id_type"))
        end
        
        # Add version prefix if specified
        full_method = isempty(api_version) ? method : "$api_version/$method"

        # Create a channel to wait for the response
        response_channel = Channel(1)
        client.responses[request_id] = response_channel

        # Add returnRateLimits parameter if specified
        if !isnothing(return_rate_limits)
            params["returnRateLimits"] = return_rate_limits
        end

        # Build request - omit params if empty (as per Binance spec)
        request = if isempty(params)
            Dict(
                "id" => request_id,
                "method" => full_method
            )
        else
            Dict(
                "id" => request_id,
                "method" => full_method,
                "params" => params
            )
        end

        try
            # Check connection before sending
            if isnothing(client.ws_connection) || WebSockets.isclosed(client.ws_connection)
                error("WebSocket connection is not available")
            end
            
            WebSockets.send(client.ws_connection, JSON3.write(request))

            # Wait for the response
            response = take!(response_channel) # This will block until a response is received
            
            # Always update rate limits if present
            if haskey(response, :rateLimits)
                update_limits!(client.rate_limiter, response.rateLimits)
            end

            if response.status == 200
                # Success - result field is mandatory according to spec
                if return_full_response
                    return response
                end
                return response.result
            else
                # Error response - handle accordingly
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

    """
        send_signed_request(client, method, params; kwargs...)
    
    Send a signed request to Binance WebSocket API.
    
    If the session is authenticated (via session.logon), only timestamp is required.
    Otherwise, full signature with apiKey and signature parameters is needed.
    
    # Security Types
    - NONE: Public market data (no signature required)
    - TRADE: Trading operations (requires signature)
    - USER_DATA: Account information (requires signature)
    - USER_STREAM: User data stream management (requires API key but no signature for listen key operations)
    
    # Arguments
    - `client`: WebSocket client instance
    - `method`: API method name
    - `params`: Request parameters
    
    # Keyword Arguments
    - `return_full_response`: Return full response instead of just result
    - `api_version`: API version prefix
    - `override_api_key`: Override the authenticated API key for this request
    - `override_signature`: Use explicit signature for this request
    """
    function send_signed_request(
        client::WebSocketClient, method::String, params::Dict{String,Any};
        return_full_response::Bool=false, api_version::String="",
        override_api_key::String="", override_signature::Bool=false
        )
        # Ensure time is synchronized before signed requests
        # If time offset is 0 (not yet synchronized), try to sync now
        if client.time_offset == 0
            try
                # Attempt quick time sync
                server_time_response = time(client)
                server_time = server_time_response.serverTime
                local_time = Int(round(datetime2unix(now(Dates.UTC)) * 1000))
                client.time_offset = server_time - local_time
                @debug "Quick time sync performed. Offset: $(client.time_offset)ms"
            catch e
                @debug "Quick time sync failed, proceeding with offset=0: $e"
            end
        end

        # Session.logon has special parameter handling
        if method == "session.logon"
            params_to_sign = Dict{String,Any}(
                "apiKey" => client.config.api_key,
                "timestamp" => get_timestamp(client),
                "recvWindow" => client.config.recv_window,
            )
            query_string = RESTAPI.build_query_string(params_to_sign)
            signature = Signature.sign_message(client.signer, query_string)

            # Logon requires the full set of parameters
            request_params = params_to_sign
            request_params["signature"] = signature

            return send_request(client, method, request_params; return_full_response=return_full_response, api_version=api_version)
        end
        
        # Always add timestamp and recvWindow
        params["timestamp"] = get_timestamp(client)
        # The recvWindow parameter is used to specify the number of milliseconds after the timestamp that the request is valid for.
        # If the request is received after recvWindow milliseconds from the timestamp, it will be rejected.
        # The value of recvWindow can be up to 60000. It now supports microseconds.
        params["recvWindow"] = client.config.recv_window
        
        # Check if we need to add apiKey and signature
        if client.is_authenticated && !override_signature && isempty(override_api_key)
            # Session is authenticated, only timestamp is needed. No need to add apiKey and signature
            @debug "Using authenticated session, skipping apiKey and signature"
        else
            # Not authenticated or explicit override requested. Add apiKey (use override if provided)
            api_key = isempty(override_api_key) ? client.config.api_key : override_api_key
            params["apiKey"] = api_key
            
            # Add signature
            query_string = RESTAPI.build_query_string(params)
            params["signature"] = Signature.sign_message(client.signer, query_string)
        end

        return send_request(client, method, params; return_full_response=return_full_response, api_version=api_version)
    end

    # --- Session Management ---

    function session_logon(client::WebSocketClient)
        if client.config.signature_method != "ED25519"
            @warn "Session logon is only officially supported for Ed25519 signature method."
        end
        response = send_signed_request(client, "session.logon", Dict{String,Any}())
        client.is_authenticated = true # Assume success if no exception is thrown
        # Response is already parsed, just convert to WebSocketConnection type
        # Handle potential nothing values from response
        return WebSocketConnection(
            something(get(response, "apiKey", nothing), ""),
            something(get(response, "authorizedSince", nothing), 0),
            something(get(response, "connectedSince", nothing), 0),
            something(get(response, "returnRateLimits", nothing), false),
            something(get(response, "serverTime", nothing), 0),
            something(get(response, "userDataStream", nothing), false)
        )
    end

    function session_status(client::WebSocketClient)
        # No authentication required - works on any connection
        response = send_request(client, "session.status", Dict{String,Any}())
        # Response is already parsed, just convert to WebSocketConnection type
        # Handle potential nothing values from response
        return WebSocketConnection(
            something(get(response, "apiKey", nothing), ""),
            something(get(response, "authorizedSince", nothing), 0),
            something(get(response, "connectedSince", nothing), 0),
            something(get(response, "returnRateLimits", nothing), false),
            something(get(response, "serverTime", nothing), 0),
            something(get(response, "userDataStream", nothing), false)
        )
    end

    function session_logout(client::WebSocketClient)
        if !isnothing(client.ws_connection) && !WebSockets.isclosed(client.ws_connection)
            try
                # No authentication required - works on any connection
                response = send_request(client, "session.logout", Dict{String,Any}())
                client.is_authenticated = false
                # Response is already parsed, just convert to WebSocketConnection type
                # Handle potential nothing values from response
                return WebSocketConnection(
                    something(get(response, "apiKey", nothing), ""),
                    something(get(response, "authorizedSince", nothing), 0),
                    something(get(response, "connectedSince", nothing), 0),
                    something(get(response, "returnRateLimits", nothing), false),
                    something(get(response, "serverTime", nothing), 0),
                    something(get(response, "userDataStream", nothing), false)
                )
            catch e
                @warn "Failed to send session.logout, likely because the connection was already closed. Proceeding with disconnection. Error: $e"
            end
        else
            @info "WebSocket connection already closed. Skipping session.logout."
        end
        client.is_authenticated = false
        return nothing # Or some other indicator of a skipped logout
    end

    # --- General Methods ---

    function ping(client::WebSocketClient)
        return send_request(client, "ping", Dict{String,Any}())
    end

    function time(client::WebSocketClient)
        return send_request(client, "time", Dict{String,Any}())
    end

    function exchangeInfo(client::WebSocketClient; 
        symbol::String="",
        symbols::Union{Vector{String},Nothing}=nothing, 
        permissions::Union{Vector{String},Nothing}=nothing,
        showPermissionSets::Union{Bool,Nothing}=nothing,
        symbolStatus::String=""
        )

        params = Dict{String,Any}()
        
        # Only one of symbol, symbols, permissions can be specified
        param_count = 0
        if !isempty(symbol)
            params["symbol"] = symbol
            param_count += 1
        end
        if !isnothing(symbols)
            params["symbols"] = symbols
            param_count += 1
        end
        if !isnothing(permissions)
            params["permissions"] = permissions
            param_count += 1
        end
        
        if param_count > 1
            throw(ArgumentError("Only one of symbol, symbols, or permissions parameters can be specified"))
        end
        
        if !isnothing(showPermissionSets)
            params["showPermissionSets"] = showPermissionSets
        end
        
        if !isempty(symbolStatus)
            if !isempty(symbol) || !isnothing(symbols)
                throw(ArgumentError("symbolStatus cannot be used in combination with symbol or symbols"))
            end
            if !(symbolStatus in ["TRADING", "HALT", "BREAK"])
                throw(ArgumentError("Invalid symbolStatus. Valid values: TRADING, HALT, BREAK"))
            end
            params["symbolStatus"] = symbolStatus
        end
        
        response = send_request(client, "exchangeInfo", params)

        # Convert JSON3.Object to ExchangeInfo type
        return to_struct(ExchangeInfo, response)
    end

    # --- Market Data Requests ---

    function depth(client::WebSocketClient, symbol::String; limit::Int=100, symbolStatus::String="")
        # Validate limit values
        valid_limits = [5, 10, 20, 50, 100, 500, 1000, 5000]
        if !(limit in valid_limits)
            throw(ArgumentError("Invalid limit for depth. Valid values: $(join(valid_limits, ", "))"))
        end

        params = Dict{String,Any}("symbol" => symbol)
        if limit != 100
            params["limit"] = limit
        end

        if !isempty(symbolStatus)
            params["symbolStatus"] = symbolStatus
        end

        response = send_request(client, "depth", params)
        return to_struct(OrderBook, response)
    end

    function trades_recent(client::WebSocketClient, symbol::String; limit::Int=500)
        # Validate limit
        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000 for recent trades"))
        end
        
        params = Dict{String,Any}("symbol" => symbol)
        if limit != 500
            params["limit"] = limit
        end
        response = send_request(client, "trades.recent", params)
        return to_struct(Vector{MarketTrade}, response)
    end

    function trades_historical(client::WebSocketClient, symbol::String; from_id::Union{Int,Nothing}=nothing, limit::Int=500)
        # Validate limit
        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000 for historical trades"))
        end
        
        params = Dict{String,Any}("symbol" => symbol)
        if !isnothing(from_id)
            params["fromId"] = from_id
        end
        if limit != 500
            params["limit"] = limit
        end
        response = send_request(client, "trades.historical", params)
        return to_struct(Vector{MarketTrade}, response)
    end

    function trades_aggregate(client::WebSocketClient, symbol::String; from_id::Union{Int,Nothing}=nothing,
        start_time::Union{Int,Nothing}=nothing, end_time::Union{Int,Nothing}=nothing, limit::Int=500)
        # Validate limit
        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000 for aggregate trades"))
        end
        
        # Validate that fromId cannot be used with time parameters
        if !isnothing(from_id) && (!isnothing(start_time) || !isnothing(end_time))
            throw(ArgumentError("fromId cannot be used together with startTime or endTime"))
        end
        
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
        return to_struct(Vector{AggregateTrade}, response)
    end

    function klines(client::WebSocketClient, symbol::String, interval::String;
        start_time::Union{Int,Nothing}=nothing, end_time::Union{Int,Nothing}=nothing,
        time_zone::String="0", limit::Int=500)
        
        # Validate interval
        valid_intervals = ["1s", "1m", "3m", "5m", "15m", "30m", "1h", "2h", "4h", "6h", "8h", "12h", "1d", "3d", "1w", "1M"]
        if !(interval in valid_intervals)
            throw(ArgumentError("Invalid interval. Valid values: $(join(valid_intervals, ", "))"))
        end
        
        # Validate limit
        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000 for klines"))
        end
        
        # Validate timezone
        if time_zone != "0" && !occursin(r"^[+-]?\d{1,2}(:\d{2})?$", time_zone)
            throw(ArgumentError("Invalid timezone format. Use hours:minutes (e.g., -1:00, 05:45) or hours only (e.g., 0, 8, 4)"))
        end
        
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
        klines_vector = to_struct(Vector{Kline}, response)
        df = DataFrame(klines_vector)
        df.open_time = floor.(df.open_time, Second)
        df.close_time = floor.(df.close_time, Second)
        return df
    end

    function ui_klines(client::WebSocketClient, symbol::String, interval::String;
        start_time::Union{Int,Nothing}=nothing, end_time::Union{Int,Nothing}=nothing,
        time_zone::String="0", limit::Int=500)
        
        # Validate interval (same as klines)
        valid_intervals = ["1s", "1m", "3m", "5m", "15m", "30m", "1h", "2h", "4h", "6h", "8h", "12h", "1d", "3d", "1w", "1M"]
        if !(interval in valid_intervals)
            throw(ArgumentError("Invalid interval. Valid values: $(join(valid_intervals, ", "))"))
        end
        
        # Validate limit
        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000 for uiKlines"))
        end
        
        # Validate timezone
        if time_zone != "0" && !occursin(r"^[+-]?\d{1,2}(:\d{2})?$", time_zone)
            throw(ArgumentError("Invalid timezone format. Use hours:minutes (e.g., -1:00, 05:45) or hours only (e.g., 0, 8, 4)"))
        end
        
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
        klines_vector = to_struct(Vector{Kline}, response)
        df = DataFrame(klines_vector)
        df.open_time = floor.(df.open_time, Second)
        df.close_time = floor.(df.close_time, Second)
        return df
    end

    function avg_price(client::WebSocketClient, symbol::String)
        params = Dict{String,Any}("symbol" => symbol)
        response = send_request(client, "avgPrice", params)
        return to_struct(AveragePrice, response)
    end

    function ticker_24hr(client::WebSocketClient; symbol::String="", symbols::Vector{String}=String[], type::String="FULL", symbolStatus::String="")
        # Validate type
        if !(type in ["FULL", "MINI"])
            throw(ArgumentError("Invalid type. Valid values: FULL, MINI"))
        end

        # symbol and symbols cannot be used together
        if !isempty(symbol) && !isempty(symbols)
            throw(ArgumentError("symbol and symbols cannot be used together"))
        end

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

        if !isempty(symbolStatus)
            params["symbolStatus"] = symbolStatus
        end

        response = send_request(client, "ticker.24hr", params)
        if single_symbol
            return type == "FULL" ? to_struct(Ticker24hrRest, response) : to_struct(Ticker24hrMini, response)
        else
            return type == "FULL" ? to_struct(Vector{Ticker24hrRest}, response) : to_struct(Vector{Ticker24hrMini}, response)
        end
    end

    function ticker_trading_day(client::WebSocketClient; symbol::String="", symbols::Vector{String}=String[],
        time_zone::String="0", type::String="FULL", symbolStatus::String="")

        # Validate timezone
        if time_zone != "0" && !occursin(r"^[+-]?\d{1,2}(:\d{2})?$", time_zone)
            throw(ArgumentError("Invalid timezone format. Use hours:minutes (e.g., -1:00, 05:45) or hours only (e.g., 0, 8, 4)"))
        end

        # Validate type
        if !(type in ["FULL", "MINI"])
            throw(ArgumentError("Invalid type. Valid values: FULL, MINI"))
        end

        # Either symbol or symbols must be specified (or neither for all symbols)
        if !isempty(symbol) && !isempty(symbols)
            throw(ArgumentError("symbol and symbols cannot be used together"))
        end

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

        if !isempty(symbolStatus)
            params["symbolStatus"] = symbolStatus
        end

        response = send_request(client, "ticker.tradingDay", params)
        if single_symbol
            return type == "FULL" ? to_struct(TradingDayTicker, response) : to_struct(TradingDayTickerMini, response)
        else
            return type == "FULL" ? to_struct(Vector{TradingDayTicker}, response) : to_struct(Vector{TradingDayTickerMini}, response)
        end
    end

    function ticker(client::WebSocketClient; symbol::String="", symbols::Vector{String}=String[], window_size::String="1d", type::String="FULL", symbolStatus::String="")

        # Validate window size
        valid_window_sizes = [
            # Minutes: 1m to 59m
            ["$(i)m" for i in 1:59]...,
            # Hours: 1h to 23h
            ["$(i)h" for i in 1:23]...,
            # Days: 1d to 7d
            ["$(i)d" for i in 1:7]...
        ]
        if !(window_size in valid_window_sizes)
            throw(ArgumentError("Invalid window size. Valid formats: 1m-59m, 1h-23h, 1d-7d"))
        end

        # Validate type
        if !(type in ["FULL", "MINI"])
            throw(ArgumentError("Invalid type. Valid values: FULL, MINI"))
        end

        # Either symbol or symbols must be specified
        if isempty(symbol) && isempty(symbols)
            throw(ArgumentError("Either symbol or symbols must be specified"))
        end

        # symbol and symbols cannot be used together
        if !isempty(symbol) && !isempty(symbols)
            throw(ArgumentError("symbol and symbols cannot be used together"))
        end

        # Maximum 200 symbols
        if length(symbols) > 200
            throw(ArgumentError("Maximum 200 symbols allowed in one request"))
        end

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

        if !isempty(symbolStatus)
            params["symbolStatus"] = symbolStatus
        end

        response = send_request(client, "ticker", params)
        if single_symbol
            return type == "FULL" ? to_struct(RollingWindowTicker, response) : to_struct(RollingWindowTickerMini, response)
        else
            return type == "FULL" ? to_struct(Vector{RollingWindowTicker}, response) : to_struct(Vector{RollingWindowTickerMini}, response)
        end
    end

    function ticker_price(client::WebSocketClient; symbol::String="", symbols::Vector{String}=String[], symbolStatus::String="")
        # symbol and symbols cannot be used together
        if !isempty(symbol) && !isempty(symbols)
            throw(ArgumentError("symbol and symbols cannot be used together"))
        end

        params = Dict{String,Any}()
        single_symbol = false
        if !isempty(symbol)
            params["symbol"] = symbol
            single_symbol = true
        elseif !isempty(symbols)
            params["symbols"] = symbols
        end

        if !isempty(symbolStatus)
            params["symbolStatus"] = symbolStatus
        end

        response = send_request(client, "ticker.price", params)
        return single_symbol ? to_struct(PriceTicker, response) : to_struct(Vector{PriceTicker}, response)
    end

    function ticker_book(client::WebSocketClient; symbol::String="", symbols::Vector{String}=String[], symbolStatus::String="")
        # symbol and symbols cannot be used together
        if !isempty(symbol) && !isempty(symbols)
            throw(ArgumentError("symbol and symbols cannot be used together"))
        end

        params = Dict{String,Any}()
        single_symbol = false
        if !isempty(symbol)
            params["symbol"] = symbol
            single_symbol = true
        elseif !isempty(symbols)
            params["symbols"] = symbols
        end

        if !isempty(symbolStatus)
            params["symbolStatus"] = symbolStatus
        end

        response = send_request(client, "ticker.book", params)
        return single_symbol ? to_struct(BookTicker, response) : to_struct(Vector{BookTicker}, response)
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
        timeInForce::String="", price::Union{Float64,String,FixedDecimal,Nothing}=nothing,
        quantity::Union{Float64,String,FixedDecimal,Nothing}=nothing, quoteOrderQty::Union{Float64,String,FixedDecimal,Nothing}=nothing,
        newClientOrderId::String="", stopPrice::Union{Float64,String,FixedDecimal,Nothing}=nothing,
        trailingDelta::Union{Int,Nothing}=nothing, icebergQty::Union{Float64,String,FixedDecimal,Nothing}=nothing,
        newOrderRespType::String="", strategyId::Union{Int,Nothing}=nothing,
        strategyType::Union{Int,Nothing}=nothing, selfTradePreventionMode::String="",
        kwargs...  # Accept any additional parameters
        )
        # Basic validation only
        side in ["BUY", "SELL"] || throw(ArgumentError("Invalid side: $side"))

        # Set defaults
        if type in ["LIMIT", "LIMIT_MAKER"] && isempty(timeInForce)
            timeInForce = "GTC"
        end

        if isempty(newOrderRespType)
            newOrderRespType = (type in ["MARKET", "LIMIT"]) ? "FULL" : "ACK"
        end

        # Build parameters
        params = Dict{String,Any}(
            "symbol" => symbol,
            "side" => side,
            "type" => type
        )

        # Add parameters if provided (simplified)
        !isempty(timeInForce) && (params["timeInForce"] = timeInForce)
        !isnothing(price) && (params["price"] = to_decimal_string(price))
        !isnothing(quantity) && (params["quantity"] = to_decimal_string(quantity))
        !isnothing(quoteOrderQty) && (params["quoteOrderQty"] = to_decimal_string(quoteOrderQty))
        !isempty(newClientOrderId) && (params["newClientOrderId"] = newClientOrderId)
        !isnothing(stopPrice) && (params["stopPrice"] = to_decimal_string(stopPrice))
        !isnothing(trailingDelta) && (params["trailingDelta"] = trailingDelta)
        !isnothing(icebergQty) && (params["icebergQty"] = to_decimal_string(icebergQty))
        !isempty(newOrderRespType) && (params["newOrderRespType"] = newOrderRespType)
        !isnothing(strategyId) && (params["strategyId"] = strategyId)
        !isnothing(strategyType) && (params["strategyType"] = strategyType)
        !isempty(selfTradePreventionMode) && (params["selfTradePreventionMode"] = selfTradePreventionMode)

        # Add any additional kwargs
        for (key, value) in kwargs
            if !isnothing(value)
                params[string(key)] = isa(value, Number) ? value : string(value)
            end
        end

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
        price::Union{Float64,String,Nothing}=nothing, quantity::Union{Float64,String,Nothing}=nothing,
        quoteOrderQty::Union{Float64,String,Nothing}=nothing, timeInForce::String="",
        newClientOrderId::String="", newOrderRespType::String="",
        stopPrice::Union{Float64,String,Nothing}=nothing, trailingDelta::Union{Int,Nothing}=nothing,
        icebergQty::Union{Float64,String,Nothing}=nothing, strategyId::Union{Int,Nothing}=nothing,
        strategyType::Union{Int,Nothing}=nothing, selfTradePreventionMode::String="",
        pegPriceType::String="", pegOffsetValue::Union{Int,Nothing}=nothing, pegOffsetType::String=""
        )
        # Validate cancelReplaceMode
        if !(cancelReplaceMode in ["STOP_ON_FAILURE", "ALLOW_FAILURE"])
            throw(ArgumentError("Invalid cancelReplaceMode. Valid values: STOP_ON_FAILURE, ALLOW_FAILURE"))
        end
        
        # Validate cancelRestrictions if provided
        if !isempty(cancelRestrictions) && !(cancelRestrictions in ["ONLY_NEW", "ONLY_PARTIALLY_FILLED"])
            throw(ArgumentError("Invalid cancelRestrictions. Valid values: ONLY_NEW, ONLY_PARTIALLY_FILLED"))
        end
        
        # Validate orderRateLimitExceededMode
        if !(orderRateLimitExceededMode in ["DO_NOTHING", "CANCEL_ONLY"])
            throw(ArgumentError("Invalid orderRateLimitExceededMode. Valid values: DO_NOTHING, CANCEL_ONLY"))
        end

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
            throw(ArgumentError("Either cancelOrderId or cancelOrigClientOrderId must be provided"))
        end

        !isempty(cancelNewClientOrderId) && (params["cancelNewClientOrderId"] = cancelNewClientOrderId)
        !isempty(cancelRestrictions) && (params["cancelRestrictions"] = cancelRestrictions)
        !isempty(orderRateLimitExceededMode) && (params["orderRateLimitExceededMode"] = orderRateLimitExceededMode)
        
        # New order parameters
        !isnothing(price) && (params["price"] = string(price))
        !isnothing(quantity) && (params["quantity"] = string(quantity))
        !isnothing(quoteOrderQty) && (params["quoteOrderQty"] = string(quoteOrderQty))
        !isempty(timeInForce) && (params["timeInForce"] = timeInForce)
        !isempty(newClientOrderId) && (params["newClientOrderId"] = newClientOrderId)
        !isempty(newOrderRespType) && (params["newOrderRespType"] = newOrderRespType)
        !isnothing(stopPrice) && (params["stopPrice"] = string(stopPrice))
        !isnothing(trailingDelta) && (params["trailingDelta"] = trailingDelta)
        !isnothing(icebergQty) && (params["icebergQty"] = string(icebergQty))
        !isnothing(strategyId) && (params["strategyId"] = strategyId)
        !isnothing(strategyType) && (params["strategyType"] = strategyType)
        !isempty(selfTradePreventionMode) && (params["selfTradePreventionMode"] = selfTradePreventionMode)
        !isempty(pegPriceType) && (params["pegPriceType"] = pegPriceType)
        !isnothing(pegOffsetValue) && (params["pegOffsetValue"] = pegOffsetValue)
        !isempty(pegOffsetType) && (params["pegOffsetType"] = pegOffsetType)

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
        belowPegOffsetValue::Union{Int,Nothing}=nothing, newOrderRespType::String="FULL", selfTradePreventionMode::String=""
        )

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
        place_opo_order(client, symbol, triggerPrice, workingType, workingSide, workingQuantity; kwargs...)

    Place a new One-Pays-the-Other (OPO) order list via WebSocket API.

    OPO allows you to place a trigger order that, when conditions are met, places a
    working order. If the working order fills, the trigger is canceled.

    # Required Parameters
    - `symbol`: Trading pair symbol (e.g., "BTCUSDT")
    - `triggerPrice`: Price at which the pending order will be triggered
    - `workingType`: Type of the working order ("LIMIT" or "LIMIT_MAKER")
    - `workingSide`: Side of the working order ("BUY" or "SELL")
    - `workingQuantity`: Quantity for the working order

    # Optional Parameters (via kwargs)
    - `listClientOrderId`: Unique id for the order list
    - `workingClientOrderId`: Unique id for the working order
    - `workingPrice`: Price for the working order (required for LIMIT orders)
    - `workingTimeInForce`: Time in force for working order
    - `workingIcebergQty`: Iceberg quantity for working order
    - `workingSelfTradePreventionMode`: STP mode for working order
    - `pendingType`: Type of pending order
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

    # Note
    Available after 2025-12-18. Check `opoAllowed` in exchange info for symbol support.
    """
    function place_opo_order(
        client::WebSocketClient, symbol::String, triggerPrice::Union{Float64,String},
        workingType::String, workingSide::String, workingQuantity::Union{Float64,String}; kwargs...
        )

        params = Dict{String,Any}(
            "symbol" => symbol,
            "triggerPrice" => string(triggerPrice),
            "workingType" => workingType,
            "workingSide" => workingSide,
            "workingQuantity" => string(workingQuantity)
        )

        # Add any additional parameters from kwargs
        for (key, value) in kwargs
            if !isnothing(value) && !isempty(string(value))
                params[string(key)] = isa(value, Number) ? value : string(value)
            end
        end

        return send_signed_request(client, "orderList.place.opo", params)
    end

    """
        place_opoco_order(client, symbol, triggerPrice, workingType, workingSide, workingQuantity, pendingSide, pendingQuantity, pendingAboveType; kwargs...)

    Place a new One-Pays-the-Other-with-Contingent-Order (OPOCO) order list via WebSocket API.

    OPOCO combines OPO with OCO: places a trigger order that, when conditions are met,
    places an OCO order pair. This allows for complex order strategies.

    # Required Parameters
    - `symbol`: Trading pair symbol (e.g., "BTCUSDT")
    - `triggerPrice`: Price at which the pending orders will be triggered
    - `workingType`: Type of the working order ("LIMIT" or "LIMIT_MAKER")
    - `workingSide`: Side of the working order ("BUY" or "SELL")
    - `workingQuantity`: Quantity for the working order
    - `pendingSide`: Side of pending OCO orders
    - `pendingQuantity`: Quantity for pending orders
    - `pendingAboveType`: Type of the pending above order

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

    # Note
    Available after 2025-12-18. Check `opoAllowed` in exchange info for symbol support.
    """
    function place_opoco_order(
        client::WebSocketClient, symbol::String, triggerPrice::Union{Float64,String},
        workingType::String, workingSide::String, workingQuantity::Union{Float64,String},
        pendingSide::String, pendingQuantity::Union{Float64,String}, pendingAboveType::String; kwargs...
        )

        params = Dict{String,Any}(
            "symbol" => symbol,
            "triggerPrice" => string(triggerPrice),
            "workingType" => workingType,
            "workingSide" => workingSide,
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

        return send_signed_request(client, "orderList.place.opoco", params)
    end

    """
        order_list_cancel(client, symbol; kwargs...)

    Cancel an active order list.
    """
    function cancel_order_list(client::WebSocketClient, symbol::String;
        orderListId::Union{Int,Nothing}=nothing,
        listClientOrderId::String="",
        newClientOrderId::String=""
        )

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
        account_status(client; omitZeroBalances)

    Query account information.
    """
    function account_status(client::WebSocketClient; omitZeroBalances::Union{Bool,Nothing}=nothing)
        params = Dict{String,Any}()
        if !isnothing(omitZeroBalances)
            params["omitZeroBalances"] = omitZeroBalances
        end
        full_response = send_signed_request(client, "account.status", params; return_full_response=true)
        account_info = to_struct(AccountInfo, full_response.result)
        rate_limits = to_struct(Vector{Account.RateLimit}, full_response.rateLimits)
        return AccountStatusResponse(account_info, rate_limits)
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
        my_trades(client, symbol; kwargs...)

    Query account trade list.
    Weight: 20 without orderId, 5 with orderId
    """
    function my_trades(client::WebSocketClient, symbol::String;
        orderId::Union{Int,Nothing}=nothing,
        startTime::Union{Int,Nothing}=nothing,
        endTime::Union{Int,Nothing}=nothing,
        fromId::Union{Int,Nothing}=nothing,
        limit::Int=500)

        # Validate limit
        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000"))
        end

        params = Dict{String,Any}(
            "symbol" => symbol,
            "limit" => limit
        )

        !isnothing(orderId) && (params["orderId"] = orderId)
        !isnothing(startTime) && (params["startTime"] = startTime)
        !isnothing(endTime) && (params["endTime"] = endTime)
        !isnothing(fromId) && (params["fromId"] = fromId)

        return send_signed_request(client, "myTrades", params)
    end

    """
        my_filters(client; symbol)

    Query account filters.
    """
    function my_filters(client::WebSocketClient; symbol::String="")
        params = Dict{String,Any}()
        !isempty(symbol) && (params["symbol"] = symbol)
        return send_signed_request(client, "myFilters", params)
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
    Weight: 20
    """
    function all_orders(
        client::WebSocketClient, symbol::String;
        orderId::Union{Int,Nothing}=nothing,
        startTime::Union{Int,Nothing}=nothing,
        endTime::Union{Int,Nothing}=nothing,
        limit::Int=500
        )

        # Validate limit
        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000"))
        end

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
    function order_list_status(client::WebSocketClient; orderListId::Union{Int,Nothing}=nothing, origClientOrderId::String="")

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
    Weight: 20
    """
    function all_order_lists(
        client::WebSocketClient;
        fromId::Union{Int,Nothing}=nothing,
        startTime::Union{Int,Nothing}=nothing,
        endTime::Union{Int,Nothing}=nothing,
        limit::Int=500
        )

        # Validate limit
        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000"))
        end

        params = Dict{String,Any}("limit" => limit)

        !isnothing(fromId) && (params["fromId"] = fromId)
        !isnothing(startTime) && (params["startTime"] = startTime)
        !isnothing(endTime) && (params["endTime"] = endTime)

        return send_signed_request(client, "allOrderLists", params)
    end

    """
        my_prevented_matches(client, symbol; kwargs...)

    Displays the list of orders that were expired due to STP.
    Weight: 2 for preventedMatchId, 20 for orderId
    """
    function my_prevented_matches(
        client::WebSocketClient, symbol::String;
        preventedMatchId::Union{Int,Nothing}=nothing,
        orderId::Union{Int,Nothing}=nothing,
        fromPreventedMatchId::Union{Int,Nothing}=nothing,
        limit::Int=500
        )

        # Validate limit
        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000"))
        end

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
    Weight: 20
    """
    function my_allocations(
        client::WebSocketClient, symbol::String;
        startTime::Union{Int,Nothing}=nothing,
        endTime::Union{Int,Nothing}=nothing,
        fromAllocationId::Union{Int,Nothing}=nothing,
        limit::Int=500,
        orderId::Union{Int,Nothing}=nothing
        )

        # Validate limit
        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000"))
        end

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
    Weight: 20
    """
    function account_commission(client::WebSocketClient, symbol::String)
        params = Dict{String,Any}("symbol" => symbol)
        return send_signed_request(client, "account.commission", params)
    end

    """
        order_amendments(client, symbol, orderId; kwargs...)

    Queries all amendments of a single order.
    Weight: 4
    """
    function order_amendments(
        client::WebSocketClient, symbol::String, orderId::Int;
        fromExecutionId::Union{Int,Nothing}=nothing,
        limit::Int=500
        )

        # Validate limit
        if limit < 1 || limit > 1000
            throw(ArgumentError("Limit must be between 1 and 1000"))
        end

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
    User Data Stream events are available in both JSON and SBE sessions.

    Weight: 2

    Returns a result with subscriptionId field.
    """
    function userdata_stream_subscribe(client::WebSocketClient)
        # Check if there's already an active user data stream subscription
        try
            subs_response = session_subscriptions(client)
            if !isnothing(subs_response) && !isempty(subs_response)
                @info "User data stream already has $(length(subs_response)) active subscription(s). Skipping new subscription."
                return subs_response[1]  # Return the existing subscription
            end
        catch e
            # If checking subscriptions fails, proceed with subscription attempt
            @debug "Could not check existing subscriptions: $e"
        end

        return send_request(client, "userDataStream.subscribe", Dict{String,Any}())
    end

    """
        userdata_stream_unsubscribe(client; subscriptionId)

    Stop listening to the User Data Stream in the current WebSocket connection.
    
    When called with no subscriptionId parameter, this will close all subscriptions.
    When called with subscriptionId, this will attempt to close that specific subscription.
    
    Note: session.logout will only close the subscription created with userDataStream.subscribe
    but not subscriptions opened with userDataStream.subscribe.signature.
    
    Weight: 2
    """
    function userdata_stream_unsubscribe(client::WebSocketClient; subscriptionId::Union{Int,Nothing}=nothing)
        if !isnothing(client.ws_connection) && !WebSockets.isclosed(client.ws_connection)
            try
                params = Dict{String,Any}()
                !isnothing(subscriptionId) && (params["subscriptionId"] = subscriptionId)
                return send_request(client, "userDataStream.unsubscribe", params)
            catch e
                @warn "Failed to send userDataStream.unsubscribe, likely because the connection was already closed. Error: $e"
            end
        else
            @info "WebSocket connection already closed. Skipping userDataStream.unsubscribe."
        end
        return nothing
    end

    """
        session_subscriptions(client)

    List all active User Data Stream subscriptions in the current session.
    
    Users are expected to track on their side which subscription corresponds to which account.
    
    Weight: 2
    Data Source: Memory
    
    Returns an array of subscriptions with subscriptionId fields.
    """
    function session_subscriptions(client::WebSocketClient)
        return send_request(client, "session.subscriptions", Dict{String,Any}())
    end

    """
        userdata_stream_subscribe_signature(client, apiKey, timestamp, signature)

    Subscribe to User Data Stream using signature subscription for a specific API key.
    This allows subscribing to User Data Stream for any account with valid API key and signature.
    
    Weight: 2
    Data Source: Memory
    
    # Parameters
    - `apiKey`: API key for the account
    - `timestamp`: Request timestamp
    - `signature`: Request signature
    
    Returns a result with subscriptionId field.
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
