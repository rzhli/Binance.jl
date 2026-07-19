"""
FIX SBE Session Module

Manages FIX SBE (Simple Binary Encoding) sessions with Binance.

Ports:
- 9001: FIX text request → SBE response (hybrid mode)
- 9002: SBE request → SBE response (pure SBE mode)

This module provides session management for pure SBE mode (port 9002).
For hybrid mode (port 9001), use the regular FIXAPI module which handles
text FIX requests and can parse SBE responses.
"""
module FIXSBESession

using Sockets
using Dates
using Binance: BinanceConfig, Signature
using ..FIXConstants
using ..FIXSBEEncoder
using ..FIXSBEDecoder

export SBESession, SBESessionType, SBEOrderEntry, SBEDropCopy, SBEMarketData
export connect_sbe, logon_sbe, logout_sbe, close_sbe
export heartbeat_sbe, test_request_sbe
export new_order_single_sbe, order_cancel_request_sbe, order_mass_cancel_request_sbe
export new_order_list_sbe, order_cancel_request_and_new_sbe
export order_amend_keep_priority_sbe, limit_query_sbe
export market_data_request_sbe, instrument_list_request_sbe
export receive_sbe_message, process_sbe_messages
export start_sbe_monitor, stop_sbe_monitor, reconnect_sbe
export SBE_SESSION_LIMITS, get_sbe_session_limits

# =============================================================================
# Session Types
# =============================================================================

@enum SBESessionType begin
    SBEOrderEntry   # fix-oe.binance.com:9002 - Orders, cancels, execution reports
    SBEDropCopy     # fix-dc.binance.com:9002 - Execution reports only (read-only)
    SBEMarketData   # fix-md.binance.com:9002 - Market data streams
end

# Session-specific limits (same as text FIX)
const SBE_SESSION_LIMITS = Dict(
    SBEOrderEntry => (messages=10000, interval_sec=10, max_connections=10, max_streams=nothing),
    SBEDropCopy => (messages=60, interval_sec=60, max_connections=10, max_streams=nothing),
    SBEMarketData => (messages=2000, interval_sec=60, max_connections=100, max_streams=1000)
)

"""
    get_sbe_session_limits(session_type::SBESessionType)

Get the rate limits for a SBE session type.
Returns a NamedTuple with: messages, interval_sec, max_connections, max_streams
"""
function get_sbe_session_limits(session_type::SBESessionType)
    return SBE_SESSION_LIMITS[session_type]
end

# =============================================================================
# SBE Session Structure
# =============================================================================

struct SBESessionCallback{F}
    callback::F
end

@inline (callback::SBESessionCallback{F})(args...) where {F} = callback.callback(args...)

wrap_sbe_session_callback(::Nothing) = nothing
wrap_sbe_session_callback(callback::SBESessionCallback) = callback
wrap_sbe_session_callback(callback) = SBESessionCallback(callback)

mutable struct SBESession
    host::String
    port::Int
    socket::Union{TCPSocket,Nothing}
    seq_num::UInt32
    sender_comp_id::String
    target_comp_id::String
    config::BinanceConfig
    signer::Signature.BinanceSigner
    session_type::SBESessionType
    is_logged_in::Bool
    recv_buffer::Vector{UInt8}

    # Connection lifecycle fields
    heartbeat_interval::UInt32
    last_sent_time::DateTime
    last_recv_time::DateTime
    pending_test_req_id::String
    test_req_sent_time::Union{DateTime,Nothing}
    maintenance_warning::Bool
    monitor_task::Union{Task,Nothing}
    should_stop::Threads.Atomic{Bool}
    read_lock::ReentrantLock
    send_lock::ReentrantLock

    # Callbacks for connection events
    on_maintenance::Union{SBESessionCallback,Nothing}
    on_disconnect::Union{SBESessionCallback,Nothing}
    on_message::Union{SBESessionCallback,Nothing}

    function SBESession(host::String, port::Int, sender_comp_id::String,
        target_comp_id::String, config::BinanceConfig;
        session_type::SBESessionType=SBEOrderEntry,
        on_maintenance=nothing,
        on_disconnect=nothing,
        on_message=nothing)

        # Validate CompIDs (1-8 chars, alphanumeric + hyphen + underscore)
        if isempty(sender_comp_id) || length(sender_comp_id) > 8
            error("SenderCompID must be 1-8 characters")
        end

        signer = Signature.create_signer(config)
        now_time = now(Dates.UTC)
        new(host, port, nothing, UInt32(1), sender_comp_id, target_comp_id, config, signer,
            session_type, false, UInt8[],
            UInt32(30), now_time, now_time, "", nothing, false, nothing,
            Threads.Atomic{Bool}(false), ReentrantLock(), ReentrantLock(),
            wrap_sbe_session_callback(on_maintenance),
            wrap_sbe_session_callback(on_disconnect),
            wrap_sbe_session_callback(on_message))
    end
end

# Convenience constructor using config defaults
function SBESession(config::BinanceConfig, sender_comp_id::String;
    session_type::SBESessionType=SBEOrderEntry,
    on_maintenance=nothing,
    on_disconnect=nothing,
    on_message=nothing)

    target_comp_id = "SPOT"

    # Host and Port based on session type - using SBE full mode ports (remote port 9002)
    (host, port) = if session_type == SBEOrderEntry
        (config.fix.order_entry.host, config.fix.order_entry.sbe_full_port)
    elseif session_type == SBEDropCopy
        (config.fix.drop_copy.host, config.fix.drop_copy.sbe_full_port)
    else  # SBEMarketData
        (config.fix.market_data.host, config.fix.market_data.sbe_full_port)
    end

    return SBESession(host, port, sender_comp_id, target_comp_id, config;
        session_type=session_type,
        on_maintenance=on_maintenance,
        on_disconnect=on_disconnect,
        on_message=on_message)
end

"""
    get_sbe_session_limits(session::SBESession)

Get the rate limits for a SBESession.
"""
function get_sbe_session_limits(session::SBESession)
    return get_sbe_session_limits(session.session_type)
end

# =============================================================================
# Connection Management
# =============================================================================

function connect_sbe(session::SBESession)
    try
        # TCP connection to local stunnel proxy
        # stunnel handles TLS termination to Binance FIX servers
        @debug "Connecting to FIX SBE stunnel proxy" host=session.host port=session.port
        tcp_socket = connect(session.host, session.port)
        session.socket = tcp_socket
        @info "Connected to FIX SBE server via stunnel" host=session.host port=session.port

        # Reset timestamps on new connection
        now_time = now(Dates.UTC)
        session.last_sent_time = now_time
        session.last_recv_time = now_time
        session.pending_test_req_id = ""
        session.test_req_sent_time = nothing
        session.maintenance_warning = false

        return session.socket
    catch e
        error("Failed to connect to FIX SBE server: $e\n" *
              "Make sure stunnel is running with SBE port configuration.")
    end
end

function close_sbe(session::SBESession)
    # Stop monitor if running
    stop_sbe_monitor(session)

    lock(session.read_lock) do
        lock(session.send_lock) do
            if !isnothing(session.socket) && isopen(session.socket)
                close(session.socket)
                @info "FIX SBE connection closed"
            end
            session.socket = nothing
        end
    end

    session.is_logged_in = false
end

# =============================================================================
# Message Sending
# =============================================================================

function send_sbe_message(session::SBESession, msg::Vector{UInt8})
    lock(session.send_lock) do
        socket = session.socket
        if isnothing(socket) || !isopen(socket)
            error("FIX SBE session not connected")
        end
        write(socket, msg)
        flush(socket)
        @debug "Sent SBE message" bytes=length(msg)
        session.seq_num += 1
        session.last_sent_time = now(Dates.UTC)
    end
    return nothing
end

# =============================================================================
# Admin Messages
# =============================================================================

"""
    logon_sbe(session; kwargs...)

Send SBE Logon message and wait for LogonAck response.

# Keyword Arguments
- `heartbeat_interval::UInt32=30`: Heartbeat interval in seconds (5-60)
- `message_handling::UInt8=1`: 1=UNORDERED, 2=SEQUENTIAL
- `response_mode::Union{UInt8,Nothing}=nothing`: 1=EVERYTHING, 2=ONLY_ACKS (Order Entry only)
- `recv_window::Union{UInt64,Nothing}=nothing`: Request validity window in microseconds
- `timeout_sec::Int=30`: Logon timeout
"""
function logon_sbe(session::SBESession;
    heartbeat_interval::UInt32=UInt32(30),
    message_handling::UInt8=0x01,
    response_mode::Union{UInt8,Nothing}=nothing,
    execution_report_type::Union{UInt8,Nothing}=nothing,
    recv_window::Union{Real,Nothing}=nothing,
    timeout_sec::Int=30)

    # Validate heartbeat interval
    if heartbeat_interval < 5 || heartbeat_interval > 60
        error("HeartBtInt must be between 5 and 60 seconds")
    end

    session.heartbeat_interval = heartbeat_interval

    # Construct payload for signature (same as text FIX)
    # For SBE, signature is computed over: MsgType + SenderCompId + TargetCompId + MsgSeqNum + SendingTime
    timestamp = Dates.format(now(Dates.UTC), "yyyymmdd-HH:MM:SS.sss")
    seq_num = string(session.seq_num)

    payload = join(["A", session.sender_comp_id, session.target_comp_id, seq_num, timestamp], "\x01")
    signature = Signature.sign_message(session.signer, payload)

    # Set drop copy flag if needed (boolEnum True=1)
    drop_copy_flag = session.session_type == SBEDropCopy ? UInt8(1) : nothing

    # Encode Logon message
    msg = encode_logon(
        sender_comp_id=session.sender_comp_id,
        target_comp_id=session.target_comp_id,
        seq_num=session.seq_num,
        heartbeat_interval=heartbeat_interval,
        api_key=session.config.api_key,
        signature=signature,
        message_handling=message_handling,
        response_mode=response_mode,
        execution_report_type=execution_report_type,
        drop_copy_flag=drop_copy_flag,
        recv_window=recv_window
    )

    @info "Sending SBE Logon"
    send_sbe_message(session, msg)

    # Wait for LogonAck response
    start_time = now(Dates.UTC)
    timeout_ms = timeout_sec * 1000

    while !session.is_logged_in
        elapsed_ms = Dates.value(now(Dates.UTC) - start_time)
        if elapsed_ms > timeout_ms
            error("SBE Logon timeout: no response from server within $(timeout_sec) seconds")
        end

        if !isopen(session.socket)
            error("Connection closed by server while waiting for SBE Logon response")
        end

        # Receive and process messages
        messages = receive_sbe_message(session; timeout_ms=500)
        for raw_msg in messages
            msg_type, decoded = decode_sbe_message(raw_msg)

            if msg_type == :logon_ack
                session.is_logged_in = true
                @info "SBE Logon confirmed by server" uuid=decoded.uuid
                break
            elseif msg_type == :logout
                error("SBE Logon rejected by server: $(decoded.text)")
            elseif msg_type == :reject
                error("SBE Logon rejected: [$(decoded.error_code)] $(decoded.text)")
            end
        end

        if !session.is_logged_in
            sleep(0.1)
        end
    end

    return session.is_logged_in
end

function logout_sbe(session::SBESession; text::String="")
    msg = encode_logout(seq_num=session.seq_num, text=text)
    @info "Sending SBE Logout"
    send_sbe_message(session, msg)
    session.is_logged_in = false
end

function heartbeat_sbe(session::SBESession; test_req_id::String="")
    msg = encode_heartbeat(seq_num=session.seq_num, test_req_id=test_req_id)
    send_sbe_message(session, msg)
end

function test_request_sbe(session::SBESession; test_req_id::String="")
    if isempty(test_req_id)
        test_req_id = string(rand(UInt32))
    end
    msg = encode_test_request(seq_num=session.seq_num, test_req_id=test_req_id)
    send_sbe_message(session, msg)
    return test_req_id
end

# =============================================================================
# Order Entry Messages
# =============================================================================

"""
    new_order_single_sbe(session, symbol, side; kwargs...)

Send a new order request via SBE (schema 1.1).

Schema 1.1 NewOrderSingle has no RecvWindow — it's only on Logon. To
constrain timing, set `recv_window` on `logon_sbe`.
"""
function new_order_single_sbe(session::SBESession, symbol::String, side::UInt8;
    quantity::Union{Float64,Nothing}=nothing,
    order_type::UInt8=0x02,  # LIMIT
    price::Union{Float64,Nothing}=nothing,
    time_in_force::Union{UInt8,Nothing}=UInt8(0x01),  # GTC
    cl_ord_id::String="",
    kwargs...)

    if session.session_type != SBEOrderEntry
        error("NewOrderSingle is only supported on Order Entry sessions")
    end

    if isempty(cl_ord_id)
        cl_ord_id = "OID-" * string(rand(UInt32), base=16)
    end

    msg = encode_new_order_single(
        seq_num=session.seq_num,
        symbol=symbol,
        side=side,
        ord_type=order_type,
        quantity=quantity,
        cl_ord_id=cl_ord_id,
        price=price,
        time_in_force=time_in_force;
        kwargs...
    )

    send_sbe_message(session, msg)
    return cl_ord_id
end

function order_cancel_request_sbe(session::SBESession, symbol::String;
    cl_ord_id::String="",
    orig_cl_ord_id::String="",
    order_id::Union{Int64,Nothing}=nothing,
    orig_cl_list_id::String="",
    list_id::Union{Int64,Nothing}=nothing,
    cancel_restrictions::Union{UInt8,Nothing}=nothing)

    if session.session_type != SBEOrderEntry
        error("OrderCancelRequest is only supported on Order Entry sessions")
    end

    if isempty(cl_ord_id)
        cl_ord_id = "CXL-" * string(rand(UInt32), base=16)
    end

    msg = encode_order_cancel_request(
        seq_num=session.seq_num,
        symbol=symbol,
        cl_ord_id=cl_ord_id,
        orig_cl_ord_id=orig_cl_ord_id,
        order_id=order_id,
        orig_cl_list_id=orig_cl_list_id,
        list_id=list_id,
        cancel_restrictions=cancel_restrictions
    )

    send_sbe_message(session, msg)
    return cl_ord_id
end

function order_mass_cancel_request_sbe(session::SBESession, symbol::String;
    cl_ord_id::String="")

    if session.session_type != SBEOrderEntry
        error("OrderMassCancelRequest is only supported on Order Entry sessions")
    end

    if isempty(cl_ord_id)
        cl_ord_id = "MCX-" * string(rand(UInt32), base=16)
    end

    msg = encode_order_mass_cancel_request(
        seq_num=session.seq_num,
        symbol=symbol,
        cl_ord_id=cl_ord_id
    )

    send_sbe_message(session, msg)
    return cl_ord_id
end

function order_amend_keep_priority_sbe(session::SBESession, symbol::String, order_qty::Float64;
    cl_ord_id::String="",
    orig_cl_ord_id::String="",
    order_id::Union{Int64,Nothing}=nothing,
    qty_exponent::Int8=Int8(-8))

    if session.session_type != SBEOrderEntry
        error("OrderAmendKeepPriority is only supported on Order Entry sessions")
    end

    if isempty(cl_ord_id)
        cl_ord_id = "AMD-" * string(rand(UInt32), base=16)
    end

    msg = encode_order_amend_keep_priority(
        seq_num=session.seq_num,
        symbol=symbol,
        cl_ord_id=cl_ord_id,
        order_qty=order_qty,
        orig_cl_ord_id=orig_cl_ord_id,
        order_id=order_id,
        qty_exponent=qty_exponent
    )

    send_sbe_message(session, msg)
    return cl_ord_id
end

"""
    new_order_list_sbe(session, cl_list_id, contingency_type, orders; opo=false)

Place an order list (OCO/OTO/OTOCO/OPO) via SBE (schema 1.1).

`orders` is a `Vector{OrderListEntry}` (2 or 3 entries depending on list type).
"""
function new_order_list_sbe(session::SBESession, cl_list_id::String,
    contingency_type::UInt8, orders::Vector{OrderListEntry}; opo::Bool=false)

    if session.session_type != SBEOrderEntry
        error("NewOrderList is only supported on Order Entry sessions")
    end

    msg = encode_new_order_list(
        seq_num=session.seq_num,
        cl_list_id=cl_list_id,
        contingency_type=contingency_type,
        orders=orders,
        opo=opo
    )

    send_sbe_message(session, msg)
    return cl_list_id
end

"""
    order_cancel_request_and_new_sbe(session, symbol, side, ord_type, mode; kwargs...)

Atomic cancel-replace via SBE (schema 1.1, XCN, templateId=97).

`mode`: 1=STOP_ON_FAILURE (don't place new order if cancel fails), 2=ALLOW_FAILURE.
"""
function order_cancel_request_and_new_sbe(session::SBESession, symbol::String,
    side::UInt8, ord_type::UInt8, mode::UInt8;
    cl_ord_id::String="", cancel_cl_ord_id::String="",
    orig_cl_ord_id::String="", order_id::Union{Int64,Nothing}=nothing,
    kwargs...)

    if session.session_type != SBEOrderEntry
        error("OrderCancelRequestAndNew is only supported on Order Entry sessions")
    end

    if isempty(cl_ord_id)
        cl_ord_id = "OID-" * string(rand(UInt32), base=16)
    end
    if isempty(cancel_cl_ord_id)
        cancel_cl_ord_id = "CXL-" * string(rand(UInt32), base=16)
    end

    msg = encode_order_cancel_request_and_new(
        seq_num=session.seq_num,
        symbol=symbol,
        cl_ord_id=cl_ord_id,
        side=side,
        ord_type=ord_type,
        mode=mode,
        cancel_cl_ord_id=cancel_cl_ord_id,
        orig_cl_ord_id=orig_cl_ord_id,
        order_id=order_id;
        kwargs...
    )

    send_sbe_message(session, msg)
    return (cl_ord_id, cancel_cl_ord_id)
end

function limit_query_sbe(session::SBESession; req_id::String="")
    if session.session_type != SBEOrderEntry
        error("LimitQuery is only supported on Order Entry sessions")
    end

    if isempty(req_id)
        req_id = "LMQ-" * string(rand(UInt32), base=16)
    end

    msg = encode_limit_query(seq_num=session.seq_num, req_id=req_id)
    send_sbe_message(session, msg)
    return req_id
end

# =============================================================================
# Market Data Messages
# =============================================================================

function market_data_request_sbe(session::SBESession, symbols::Vector{String};
    md_req_id::String="",
    subscription_type::UInt8=0x01,  # Subscribe
    market_depth::Union{Integer,Nothing}=nothing,
    aggregated_book::Union{Bool,Nothing}=nothing,
    entry_types::Vector{UInt8}=[0x00, 0x01])  # Bid, Offer

    if session.session_type != SBEMarketData
        error("MarketDataRequest is only supported on Market Data sessions")
    end

    if isempty(md_req_id)
        md_req_id = "MDR-" * string(rand(UInt32), base=16)
    end

    msg = encode_market_data_request(
        seq_num=session.seq_num,
        md_req_id=md_req_id,
        subscription_request_type=subscription_type,
        symbols=symbols,
        market_depth=isnothing(market_depth) ? nothing : UInt16(market_depth),
        aggregated_book=aggregated_book,
        md_entry_types=entry_types
    )

    send_sbe_message(session, msg)
    return md_req_id
end

# Convenience for single symbol
market_data_request_sbe(session::SBESession, symbol::String; kwargs...) =
    market_data_request_sbe(session, [symbol]; kwargs...)

function instrument_list_request_sbe(session::SBESession;
    instrument_req_id::String="",
    request_type::UInt8=0x04,  # All instruments
    symbol::String="")

    if session.session_type != SBEMarketData
        error("InstrumentListRequest is only supported on Market Data sessions")
    end

    if isempty(instrument_req_id)
        instrument_req_id = "ILR-" * string(rand(UInt32), base=16)
    end

    msg = encode_instrument_list_request(
        seq_num=session.seq_num,
        instrument_req_id=instrument_req_id,
        request_type=request_type,
        symbol=symbol
    )

    send_sbe_message(session, msg)
    return instrument_req_id
end

# =============================================================================
# Message Receiving
# =============================================================================

"""
    receive_sbe_message(session; timeout_ms=0)

Receive and return raw SBE message(s) from the session.
Returns a vector of raw message byte arrays, or empty vector if no data available.
"""
function receive_sbe_message(session::SBESession; timeout_ms::Int=0)
    timeout_ms >= 0 || throw(ArgumentError("timeout_ms must be non-negative"))
    return lock(session.read_lock) do
        socket = session.socket
        if isnothing(socket) || !isopen(socket)
            return Vector{UInt8}[]
        end
        try
            max_wait_sec = timeout_ms > 0 ? timeout_ms / 1000 : 0.1
            deadline = time() + max_wait_sec
            buf = Vector{UInt8}()
            while isopen(socket) && time() < deadline
                available = bytesavailable(socket)
                if available > 0
                    append!(buf, read(socket, available))
                else
                    sleep(min(0.001, max(deadline - time(), 0.0)))
                end
            end
            if !isempty(buf)
                append!(session.recv_buffer, buf)
            end
        catch e
            if !(e isa EOFError || e isa Base.IOError)
                @warn "Error reading from SBE socket" exception=(e, catch_backtrace())
            end
        end

        messages = Vector{UInt8}[]
        while true
            msg, remaining = extract_message(session.recv_buffer)
            if isnothing(msg)
                break
            end
            push!(messages, msg)
            session.recv_buffer = remaining
            @debug "Extracted SBE message" bytes=length(msg)
        end

        if !isempty(messages)
            session.last_recv_time = now(Dates.UTC)
        end

        return messages
    end
end

"""
    process_sbe_messages(session)

Process pending SBE messages and dispatch to callbacks.
Returns a vector of (message_type, decoded_message) tuples.
"""
function process_sbe_messages(session::SBESession)
    results = Tuple{Symbol,Any}[]

    messages = receive_sbe_message(session)
    for raw_msg in messages
        try
            msg_type, decoded = decode_sbe_message(raw_msg)

            # Handle admin messages
            if msg_type == :heartbeat
                # Clear pending test request if this is a response
                if !isempty(session.pending_test_req_id)
                    if decoded.test_req_id == session.pending_test_req_id
                        session.pending_test_req_id = ""
                        session.test_req_sent_time = nothing
                    end
                end
            elseif msg_type == :test_request
                # Respond with heartbeat
                heartbeat_sbe(session; test_req_id=decoded.test_req_id)
            elseif msg_type == :news
                # Maintenance/disconnection countdown notification. The
                # documented headlines are "You'll be disconnected in %d
                # seconds. Please reconnect." and "Your connection is about
                # to be closed. Please reconnect."
                headline_lower = lowercase(decoded.headline)
                text_lower = lowercase(decoded.text)
                if contains(headline_lower, "maintenance") || contains(text_lower, "maintenance") ||
                   contains(headline_lower, "disconnect") || contains(text_lower, "disconnect") ||
                   contains(headline_lower, "reconnect") || contains(text_lower, "reconnect")
                    session.maintenance_warning = true
                    if !isnothing(session.on_maintenance)
                        session.on_maintenance(session, decoded)
                    end
                end
            elseif msg_type == :logout
                session.is_logged_in = false
            end

            push!(results, (msg_type, decoded))

            # Call message callback
            if !isnothing(session.on_message)
                session.on_message(session, (msg_type, decoded))
            end
        catch e
            @warn "Error decoding SBE message" exception = (e, catch_backtrace())
        end
    end

    return results
end

# =============================================================================
# Connection Lifecycle
# =============================================================================

function start_sbe_monitor(session::SBESession)
    if !isnothing(session.monitor_task) && !istaskdone(session.monitor_task)
        @warn "SBE Monitor already running"
        return
    end

    session.should_stop[] = false

    session.monitor_task = errormonitor(@async begin
        try
            sbe_monitor_loop(session)
        catch e
            if !session.should_stop[]
                @error "SBE Monitor task error" exception = (e, catch_backtrace())
                if !isnothing(session.on_disconnect)
                    session.on_disconnect(session, e)
                end
            end
        end
    end)

    @info "SBE connection monitor started" heartbeat_interval=session.heartbeat_interval
end

function stop_sbe_monitor(session::SBESession)
    session.should_stop[] = true

    if !isnothing(session.monitor_task) && !istaskdone(session.monitor_task)
        wait_status = timedwait(() -> istaskdone(session.monitor_task), 2.0)
        wait_status == :timed_out && @warn "Timed out waiting for SBE monitor to stop"
    end

    if isnothing(session.monitor_task) || istaskdone(session.monitor_task)
        session.monitor_task = nothing
    end
end

function sbe_monitor_loop(session::SBESession)
    check_interval = 1.0

    while !session.should_stop[] && session.is_logged_in
        try
            current_time = now(Dates.UTC)
            heartbeat_ms = session.heartbeat_interval * 1000

            # Check socket status
            if isnothing(session.socket) || !isopen(session.socket)
                @warn "SBE Socket closed unexpectedly"
                if !isnothing(session.on_disconnect)
                    session.on_disconnect(session, "Socket closed")
                end
                break
            end

            # Process pending messages
            process_sbe_messages(session)

            # Calculate time since last activity
            ms_since_sent = Dates.value(current_time - session.last_sent_time)
            ms_since_recv = Dates.value(current_time - session.last_recv_time)

            # Check for pending TestRequest timeout
            if !isnothing(session.test_req_sent_time)
                ms_since_test_req = Dates.value(current_time - session.test_req_sent_time)
                if ms_since_test_req > heartbeat_ms
                    @warn "SBE TestRequest timeout - connection appears dead"
                    if !isnothing(session.on_disconnect)
                        session.on_disconnect(session, "TestRequest timeout")
                    end
                    break
                end
            end

            # Send TestRequest if no incoming messages
            if ms_since_recv > heartbeat_ms && isempty(session.pending_test_req_id)
                session.pending_test_req_id = test_request_sbe(session)
                session.test_req_sent_time = current_time
            end

            # Send Heartbeat if no outgoing messages
            if ms_since_sent > heartbeat_ms && isempty(session.pending_test_req_id)
                heartbeat_sbe(session)
            end

        catch e
            if !session.should_stop[]
                @error "Error in SBE monitor loop" exception = (e, catch_backtrace())
            end
        end

        sleep(check_interval)
    end
end

function reconnect_sbe(session::SBESession; heartbeat_interval::UInt32=session.heartbeat_interval)
    stop_sbe_monitor(session)

    if session.is_logged_in
        try
            logout_sbe(session)
            sleep(1)
        catch
            # Ignore logout errors
        end
    end

    close_sbe(session)
    session.seq_num = UInt32(1)

    sleep(2)

    connect_sbe(session)
    logon_sbe(session; heartbeat_interval=heartbeat_interval)

    sleep(2)
    process_sbe_messages(session)

    if session.is_logged_in
        @info "SBE session reconnected successfully"
        start_sbe_monitor(session)
        return true
    else
        @error "SBE Reconnection failed"
        return false
    end
end

end # module FIXSBESession
