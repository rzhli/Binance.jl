using Binance
using BinanceFIX

# =============================================================================
# Binance FIX API Usage Examples
# =============================================================================
#
# This file demonstrates comprehensive usage of the Binance FIX API including:
# - Session Types: OrderEntry, MarketData, DropCopy
# - Order Management: Single orders, OCO, OTO, OTOCO, cancel, amend
# - Market Data: Book ticker, depth stream, trade stream
# - Rate Limits: Query current limits
#
# REQUIREMENTS:
# - Ed25519 API key with FIX_API permission
# - config.toml with API credentials
# - stunnel configured for TLS connection (default: localhost:14000)
#
# =============================================================================

println("=" ^ 80)
println("Binance FIX API - Comprehensive Examples")
println("=" ^ 80)

# =============================================================================
# Configuration
# =============================================================================

config = Binance.from_toml("config.toml")
sender_comp_id = "abcd1234"

# =============================================================================
# 1. ORDER ENTRY SESSION
# =============================================================================
println("\n" * "=" ^ 80)
println("1. ORDER ENTRY SESSION")
println("=" ^ 80)

println("""
The Order Entry session is used for placing, canceling, and amending orders.

Connection Flow:
1. Create FIXSession with OrderEntry type
2. Connect to server (via stunnel)
3. Send Logon message with signature
4. Start heartbeat monitor
5. Trade!
6. Logout and disconnect

Example:
""")

order_entry_example = """
# Create session
session = FIXSession(config, sender_comp_id; session_type=OrderEntry)

# Connect (default: localhost:14000 via stunnel)
connect_fix(session)

# Logon with Ed25519 signature
logon(session)

# Start heartbeat monitor (recommended)
start_monitor(session)

# --- Place Orders ---

# Market Order
cl_ord_id = new_order_single(session, "BTCUSDT", SIDE_BUY, ORD_TYPE_MARKET;
    quantity=0.001)

# Limit Order
cl_ord_id = new_order_single(session, "BTCUSDT", SIDE_BUY, ORD_TYPE_LIMIT;
    quantity=0.001,
    price=50000.0,
    time_in_force=TIF_GTC)

# Limit Maker (Post-Only)
cl_ord_id = new_order_single(session, "BTCUSDT", SIDE_BUY, ORD_TYPE_LIMIT;
    quantity=0.001,
    price=50000.0,
    time_in_force=TIF_GTC,
    exec_inst=EXEC_INST_PARTICIPATE_DONT_INITIATE)

# Stop-Loss Limit Order
cl_ord_id = new_order_single(session, "BTCUSDT", SIDE_SELL, ORD_TYPE_STOP_LIMIT;
    quantity=0.001,
    price=49000.0,
    trigger_price=49100.0,
    trigger_price_direction=TRIGGER_DOWN,
    time_in_force=TIF_GTC)

# --- Cancel Order ---
order_cancel_request(session, "BTCUSDT";
    orig_cl_ord_id="original-order-id")

# Or cancel by order ID
order_cancel_request(session, "BTCUSDT";
    order_id="12345678")

# --- Mass Cancel ---
order_mass_cancel_request(session, "BTCUSDT")

# --- Amend Order (Keep Priority) ---
order_amend_keep_priority(session, "BTCUSDT";
    orig_cl_ord_id="original-order-id",
    quantity=0.002)  # Only quantity can be reduced

# --- Cancel and New Order (Atomic) ---
order_cancel_and_new_order(session, "BTCUSDT", SIDE_BUY, ORD_TYPE_LIMIT;
    cancel_orig_cl_ord_id="order-to-cancel",
    quantity=0.001,
    price=51000.0,
    time_in_force=TIF_GTC)

# --- Query Limits ---
req_id = limit_query(session)

# --- Process Messages ---
while true
    msg = receive_message(session)
    if isnothing(msg)
        sleep(0.01)
        continue
    end

    result = process_message(session, msg)
    msg_type, data = result

    if msg_type == :execution_report
        println("Order Update: \$(data.cl_ord_id) - \$(data.ord_status)")
    elseif msg_type == :order_cancel_reject
        println("Cancel Rejected: \$(data.text)")
    elseif msg_type == :limit_response
        for limit in data.limits
            println("Limit: \$(limit.limit_type) = \$(limit.limit_count)/\$(limit.limit_max)")
        end
    end
end

# Cleanup
stop_monitor(session)
logout(session)
disconnect(session)
"""
println(order_entry_example)

# =============================================================================
# 2. ORDER LISTS (OCO, OTO, OTOCO)
# =============================================================================
println("\n" * "=" ^ 80)
println("2. ORDER LISTS (OCO, OTO, OTOCO)")
println("=" ^ 80)

println("""
Order lists allow you to place multiple related orders atomically.

Types:
- OCO (One-Cancels-the-Other): 2 orders, when one fills/activates, other is canceled
- OTO (One-Triggers-the-Other): 2 orders, when first fills, second is released
- OTOCO (One-Triggers-OCO): 3 orders, when first fills, OCO pair is released

Example:
""")

order_list_example = """
# OCO SELL: Stop Loss + Take Profit (for long position)
orders = create_oco_sell(
    49000.0,  # below_price (stop loss)
    55000.0,  # above_price (take profit)
    0.001     # quantity
)
cl_list_id = new_order_list(session, "BTCUSDT", orders;
    contingency_type=CONTINGENCY_OCO)

# OCO BUY: Take Profit + Stop Loss (for short position)
orders = create_oco_buy(
    49000.0,  # below_price (take profit)
    55000.0,  # above_price (stop loss)
    0.001     # quantity
)
cl_list_id = new_order_list(session, "BTCUSDT", orders;
    contingency_type=CONTINGENCY_OCO)

# OTO: Entry triggers Exit
orders = create_oto(
    SIDE_BUY,   # working_side (entry)
    50000.0,    # working_price
    SIDE_SELL,  # pending_side (exit)
    55000.0,    # pending_price
    0.001       # quantity
)
cl_list_id = new_order_list(session, "BTCUSDT", orders;
    contingency_type=CONTINGENCY_OTO)

# OTOCO SELL: Entry triggers Stop Loss + Take Profit
orders = create_otoco_sell(
    50000.0,  # working_price (entry buy)
    48000.0,  # below_price (stop loss)
    55000.0,  # above_price (take profit)
    0.001     # quantity
)
cl_list_id = new_order_list(session, "BTCUSDT", orders;
    contingency_type=CONTINGENCY_OTO)  # OTOCO uses same type as OTO

# OTOCO BUY: Entry triggers Take Profit + Stop Loss
orders = create_otoco_buy(
    50000.0,  # working_price (entry sell)
    45000.0,  # below_price (take profit)
    52000.0,  # above_price (stop loss)
    0.001     # quantity
)
cl_list_id = new_order_list(session, "BTCUSDT", orders;
    contingency_type=CONTINGENCY_OTO)
"""
println(order_list_example)

# =============================================================================
# 3. MARKET DATA SESSION
# =============================================================================
using Binance
config = Binance.from_toml("config.toml")
sender_comp_id = "abcd1234"

# Create Market Data session
md_session = FIXSession(config, sender_comp_id; session_type=MarketData)
connect_fix(md_session)
logon(md_session)
start_monitor(md_session)

# --- Subscribe to Streams ---

# Book Ticker (best bid/offer)
ticker_id = subscribe_book_ticker(md_session, "BTCUSDT")

# Or multiple symbols
ticker_id = subscribe_book_ticker(md_session, ["BTCUSDT", "ETHUSDT"])

# Diff. Depth Stream (for local order book)
depth_id = subscribe_depth_stream(md_session, "BTCUSDT"; depth=100)

# Trade Stream
trade_id = subscribe_trade_stream(md_session, "BTCUSDT")

# --- Query Instruments ---
req_id = instrument_list_request(md_session;
    request_type=INSTRUMENT_LIST_SINGLE,
    symbol="BTCUSDT")

# Or all instruments
req_id = instrument_list_request(md_session;
    request_type=INSTRUMENT_LIST_ALL)

# --- Process Market Data ---
while true
    msg = receive_message(md_session)
    if isnothing(msg)
        sleep(0.001)
        continue
    end

    result = process_message(md_session, msg)
    msg_type, data = result

    if msg_type == :market_data_snapshot
        println("Snapshot for \$(data.symbol): \$(length(data.entries)) entries")
        for entry in data.entries
            side = entry.entry_type == MD_ENTRY_BID ? "BID" : "OFFER"
            println("  \$side: \$(entry.price) x \$(entry.size)")
        end

    elseif msg_type == :market_data_incremental
        for entry in data.entries
            action = entry.update_action == "0" ? "NEW" :
                     entry.update_action == "1" ? "CHANGE" : "DELETE"

            if entry.entry_type == MD_ENTRY_TRADE
                println("Trade: \$(entry.price) x \$(entry.size)")
            else
                side = entry.entry_type == MD_ENTRY_BID ? "BID" : "OFFER"
                println("[\$action] \$side: \$(entry.price) x \$(entry.size)")
            end
        end

    elseif msg_type == :market_data_reject
        println("Subscription rejected: \$(data.text)")

    elseif msg_type == :instrument_list
        for inst in data.instruments
            println("\$(inst.symbol)/\$(inst.currency): " *
                    "min=\$(inst.min_trade_vol), max=\$(inst.max_trade_vol)")
        end
    end
end

# --- Unsubscribe ---
unsubscribe_market_data(md_session, ticker_id)
unsubscribe_market_data(md_session, depth_id)
unsubscribe_market_data(md_session, trade_id)

# Cleanup
stop_monitor(md_session)
logout(md_session)
disconnect(md_session)


# =============================================================================
# 4. DROP COPY SESSION
# =============================================================================

drop_copy_example = """
# Create Drop Copy session
dc_session = FIXSession(config, sender_comp_id; session_type=DropCopy)
connect_fix(dc_session)
logon(dc_session)
start_monitor(dc_session)

# Process execution reports
while true
    msg = receive_message(dc_session)
    if isnothing(msg)
        sleep(0.01)
        continue
    end

    result = process_message(dc_session, msg)
    msg_type, data = result

    if msg_type == :execution_report
        println("=== Execution Report ===")
        println("Symbol: \$(data.symbol)")
        println("OrderID: \$(data.order_id)")
        println("ClOrdID: \$(data.cl_ord_id)")
        println("Side: \$(data.side == SIDE_BUY ? "BUY" : "SELL")")
        println("Status: \$(data.ord_status)")
        println("ExecType: \$(data.exec_type)")
        println("Qty: \$(data.cum_qty) / \$(data.order_qty)")

        if !isempty(data.last_px)
            println("Last Fill: \$(data.last_qty) @ \$(data.last_px)")
        end

        # Check for errors
        if is_error(data)
            code, text = get_error_info(data)
            println("ERROR: [\$code] \$text")
        end

    elseif msg_type == :list_status
        println("=== List Status ===")
        println("ListID: \$(data.list_id)")
        println("Status: \$(data.list_status_type)")
        for order in data.orders
            println("  Order: \$(order.cl_ord_id) - \$(order.order_id)")
        end
    end
end

# Cleanup
stop_monitor(dc_session)
logout(dc_session)
disconnect(dc_session)
"""
println(drop_copy_example)

# =============================================================================
# 5. ERROR HANDLING
# =============================================================================
println("\n" * "=" ^ 80)
println("5. ERROR HANDLING")
println("=" ^ 80)

println("""
The FIX API returns errors through various message types.
Always check for errors in execution reports and rejects.

Example:
""")

error_handling_example = """
result = process_message(session, msg)
msg_type, data = result

if msg_type == :execution_report
    if is_error(data)
        error_code, error_text = get_error_info(data)
        println("Order Error: [\$error_code] \$error_text")
    end

elseif msg_type == :reject
    println("Session Reject: \$(data.text)")
    println("Reason: \$(data.session_reject_reason)")
    println("RefMsgType: \$(data.ref_msg_type)")

elseif msg_type == :order_cancel_reject
    println("Cancel Rejected: \$(data.text)")
    println("ClOrdID: \$(data.cl_ord_id)")

elseif msg_type == :order_amend_reject
    println("Amend Rejected: \$(data.text)")

elseif msg_type == :market_data_reject
    println("Market Data Rejected: \$(data.text)")
    println("Reason: \$(data.reject_reason)")
    # 1 = DUPLICATE_MDREQID
    # 2 = TOO_MANY_SUBSCRIPTIONS
end
"""
println(error_handling_example)

# =============================================================================
# 6. CALLBACKS AND MONITORING
# =============================================================================
println("\n" * "=" ^ 80)
println("6. CALLBACKS AND MONITORING")
println("=" ^ 80)

println("""
You can set up callbacks for various events:

Example:
""")

callbacks_example = """
# Define callbacks
function on_maintenance(session, news)
    println("MAINTENANCE WARNING: \$(news.headline)")
    # Gracefully close positions, stop trading, etc.
end

function on_disconnect(session)
    println("Disconnected! Attempting reconnect...")
    # Implement reconnection logic
end

function on_message(session, msg_type, data)
    println("Received: \$msg_type")
    # Custom message handling
end

# Create session with callbacks
session = FIXSession(config, sender_comp_id;
    session_type=OrderEntry,
    on_maintenance=on_maintenance,
    on_disconnect=on_disconnect,
    on_message=on_message)

# The monitor will automatically:
# - Send heartbeats
# - Respond to TestRequest
# - Call on_disconnect if connection is lost
# - Call on_maintenance for maintenance notifications
start_monitor(session)

# Check session limits
limits = get_session_limits(session)
println("Order limit: \$(limits[:order_count])/\$(limits[:order_max])")
println("Message limit: \$(limits[:message_count])/\$(limits[:message_max])")
"""
println(callbacks_example)

# =============================================================================
# 7. COMPLETE TRADING EXAMPLE
# =============================================================================
println("\n" * "=" ^ 80)
println("7. COMPLETE TRADING EXAMPLE")
println("=" ^ 80)

println("""
Here's a complete example putting it all together:
""")

complete_example = """
using Binance
using BinanceFIX.FIXAPI
using BinanceFIX.FIXConstants

# Configuration
config = Binance.from_toml("config.toml")
sender_comp_id = config.api_key

# Callbacks
function handle_maintenance(session, news)
    @warn "Maintenance: \$(news.headline)"
    # Cancel all orders and stop trading
end

# Create and connect session
session = FIXSession(config, sender_comp_id;
    session_type=OrderEntry,
    on_maintenance=handle_maintenance)

try
    connect_fix(session)
    logon(session)
    start_monitor(session)

    # Check limits
    limit_query(session)

    # Place an order
    cl_ord_id = new_order_single(session, "BTCUSDT", SIDE_BUY, ORD_TYPE_LIMIT;
        quantity=0.001,
        price=50000.0,
        time_in_force=TIF_GTC)

    println("Order placed: \$cl_ord_id")

    # Wait for response
    timeout = time() + 5.0
    while time() < timeout
        msg = receive_message(session)
        if !isnothing(msg)
            result = process_message(session, msg)
            msg_type, data = result

            if msg_type == :execution_report && data.cl_ord_id == cl_ord_id
                if data.exec_type == EXEC_TYPE_NEW
                    println("Order accepted! OrderID: \$(data.order_id)")
                elseif data.exec_type == EXEC_TYPE_TRADE
                    println("Order filled: \$(data.last_qty) @ \$(data.last_px)")
                elseif data.exec_type == EXEC_TYPE_REJECTED
                    println("Order rejected: \$(data.text)")
                end
                break
            end
        end
        sleep(0.01)
    end

finally
    # Always cleanup
    stop_monitor(session)
    logout(session)
    disconnect(session)
end
"""
println(complete_example)

# =============================================================================
# Summary
# =============================================================================
println("\n" * "=" ^ 80)
println("SUMMARY")
println("=" ^ 80)
println("""
Session Types:
┌─────────────┬────────────────────────────────────────────────────────┐
│ Type        │ Description                                            │
├─────────────┼────────────────────────────────────────────────────────┤
│ OrderEntry  │ Place, cancel, amend orders                            │
│ MarketData  │ Subscribe to market data streams                       │
│ DropCopy    │ Receive execution reports for all API orders           │
└─────────────┴────────────────────────────────────────────────────────┘

Key Functions:
┌──────────────────────────────────┬────────────────────────────────────┐
│ Function                         │ Description                        │
├──────────────────────────────────┼────────────────────────────────────┤
│ FIXSession(config, id; type)     │ Create session                     │
│ connect_fix(session)             │ Connect to server                  │
│ logon(session)                   │ Authenticate                       │
│ start_monitor(session)           │ Start heartbeat monitor            │
│ new_order_single(...)            │ Place single order                 │
│ new_order_list(...)              │ Place order list (OCO/OTO/OTOCO)   │
│ order_cancel_request(...)        │ Cancel order                       │
│ order_mass_cancel_request(...)   │ Cancel all orders for symbol       │
│ order_amend_keep_priority(...)   │ Amend order quantity               │
│ subscribe_book_ticker(...)       │ Subscribe to book ticker           │
│ subscribe_depth_stream(...)      │ Subscribe to depth updates         │
│ subscribe_trade_stream(...)      │ Subscribe to trades                │
│ limit_query(session)             │ Query rate limits                  │
│ receive_message(session)         │ Receive raw message                │
│ process_message(session, msg)    │ Parse message into typed struct    │
│ logout(session)                  │ Logout                             │
│ disconnect(session)              │ Disconnect                         │
└──────────────────────────────────┴────────────────────────────────────┘

For more details, see the Binance FIX API documentation:
https://developers.binance.com/docs/binance-spot-api-docs/fix-api
""")
