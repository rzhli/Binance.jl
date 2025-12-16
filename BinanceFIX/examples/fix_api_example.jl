using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using Binance
using BinanceFIX
using Dates

# =============================================================================
# FIX API Comprehensive Examples
# =============================================================================
#
# This file demonstrates all major features of the Binance FIX API including:
# - Order Entry Sessions (placing, canceling, amending orders)
# - Drop Copy Sessions (read-only execution reports)
# - Market Data Sessions (book ticker, depth, trades)
# - Advanced order types (OCO, OTO, OTOCO)
# - Connection lifecycle management
# - Error handling and reconnection
# =============================================================================

config = Binance.from_toml("/home/rzhli/文档/投资/Binance/config.toml"; testnet=true)
function random_sender_comp_id()
    chars = vcat('a':'z', 'A':'Z', '0':'9')
    return String(rand(chars, 8))
end
sender_comp_id = random_sender_comp_id()

# =============================================================================
# 1. Order Entry Session - Basic Orders
# =============================================================================
println("\n========== Order Entry Session - Basic Orders ==========\n")

oe_session = FIXSession(config, sender_comp_id; session_type=OrderEntry)
connect_fix(oe_session)

# Define comprehensive callback
oe_session.on_message = (session, msg) -> begin
    (type, data) = msg
    if type == :execution_report
        println("ExecutionReport: ClOrdID=$(data.cl_ord_id), OrderID=$(data.order_id)")
        println("  Status: $(data.ord_status), ExecType: $(data.exec_type)")
        if is_fill(data)
            fill_info = get_fill_info(data)
            println("  Fill: $(fill_info.last_qty) @ $(fill_info.last_px), Total: $(fill_info.cum_qty)")
        end
        if is_rejected(data)
            println("  REJECTED: $(data.text) (Code: $(data.error_code))")
        end
    elseif type == :limit_response
        println("Limit Response:")
        for limit in data.limits
            println("  $(limit.limit_type): $(limit.limit_count)/$(limit.limit_max)")
        end
    elseif type == :order_cancel_reject
        println("Cancel REJECTED: $(data.text) (Code: $(data.error_code))")
    elseif type == :list_status
        println("ListStatus: ListID=$(data.list_id), Status=$(data.list_order_status)")
    end
end

# Logon with custom settings
logon(oe_session; heartbeat_interval=30, message_handling=MSG_HANDLING_UNORDERED)
start_monitor(oe_session)

if oe_session.is_logged_in
    println("Logged in successfully!")

    # Query current limits
    limit_query(oe_session)
    sleep(1)

    # Example 1: Limit order (commented to avoid accidental trading)
    # cl_ord_id = new_order_single(oe_session, "BTCUSDT", SIDE_BUY;
    #     quantity=0.001,
    #     price=50000.0,
    #     time_in_force=TIF_GTC
    # )
    # println("Placed limit order: $cl_ord_id")
    # sleep(2)

    # Example 2: Post-only order (maker-only)
    # cl_ord_id = new_order_single(oe_session, "ETHUSDT", SIDE_BUY;
    #     quantity=0.01,
    #     price=3000.0,
    #     exec_inst=EXEC_INST_PARTICIPATE_DONT_INITIATE
    # )

    # Example 3: Iceberg order
    # cl_ord_id = new_order_single(oe_session, "BTCUSDT", SIDE_SELL;
    #     quantity=1.0,
    #     price=60000.0,
    #     max_floor=0.1  # Only 0.1 BTC visible at a time
    # )

    # Example 4: Stop-loss limit order
    # cl_ord_id = new_order_single(oe_session, "BTCUSDT", SIDE_SELL;
    #     quantity=0.1,
    #     price=48000.0,
    #     order_type=ORD_TYPE_STOP_LIMIT,
    #     trigger_price=49000.0,
    #     trigger_price_direction=TRIGGER_DOWN
    # )

    # Example 5: Trailing stop order (500 basis points = 5%)
    # cl_ord_id = new_order_single(oe_session, "BTCUSDT", SIDE_SELL;
    #     quantity=0.1,
    #     order_type=ORD_TYPE_STOP_LIMIT,
    #     price=0.0,  # Will be calculated based on trailing delta
    #     trigger_trailing_delta_bips=500
    # )

    # Example 6: Cancel an order
    # cancel_id = order_cancel_request(oe_session, "BTCUSDT";
    #     orig_cl_ord_id=cl_ord_id
    # )

    # Example 7: Amend order (decrease quantity, keep priority)
    # amend_id = order_amend_keep_priority(oe_session, "BTCUSDT", 0.5;
    #     orig_cl_ord_id=cl_ord_id
    # )

    # Example 8: Mass cancel all orders for a symbol
    # mass_cancel_id = order_mass_cancel_request(oe_session, "BTCUSDT")

    # Example 9: Atomic cancel and replace
    # result = order_cancel_and_new_order(oe_session, "BTCUSDT", SIDE_BUY, ORD_TYPE_LIMIT;
    #     cancel_orig_cl_ord_id=cl_ord_id,
    #     quantity=0.002,
    #     price=51000.0,
    #     mode=XCN_MODE_STOP_ON_FAILURE
    # )
    # println("Cancel+New: $(result.cancel_cl_ord_id) -> $(result.new_cl_ord_id)")
end

logout(oe_session)
close_fix(oe_session)

# =============================================================================
# 2. Order Entry Session - Advanced Order Lists (OCO, OTO, OTOCO)
# =============================================================================
println("\n========== Order Entry Session - Order Lists ==========\n")

oe_session2 = FIXSession(config, sender_comp_id; session_type=OrderEntry)
connect_fix(oe_session2)

oe_session2.on_message = (session, msg) -> begin
    (type, data) = msg
    if type == :list_status
        println("ListStatus: ListID=$(data.list_id)")
        println("  Type: $(data.contingency_type), Status: $(data.list_order_status)")
        println("  Orders in list: $(length(data.orders))")
    elseif type == :execution_report && !isempty(data.list_id)
        println("ExecutionReport for list order: ListID=$(data.list_id)")
        println("  OrderID=$(data.order_id), Status=$(data.ord_status)")
    end
end

logon(oe_session2)
start_monitor(oe_session2)

if oe_session2.is_logged_in
    # Example 1: OCO Sell (take profit above + stop loss below)
    # orders = create_oco_sell(48000.0, 62000.0, 0.1;
    #     below_stop_price=47500.0
    # )
    # list_id = new_order_list(oe_session2, "BTCUSDT", orders;
    #     contingency_type=CONTINGENCY_OCO
    # )
    # println("Placed OCO SELL list: $list_id")

    # Example 2: OCO Buy (limit below + stop above)
    # orders = create_oco_buy(48000.0, 52000.0, 0.1)
    # list_id = new_order_list(oe_session2, "BTCUSDT", orders;
    #     contingency_type=CONTINGENCY_OCO
    # )

    # Example 3: OTO (One-Triggers-Other)
    # Entry order triggers a take profit order when filled
    # orders = create_oto(SIDE_BUY, 49000.0, SIDE_SELL, 51000.0, 0.1)
    # list_id = new_order_list(oe_session2, "BTCUSDT", orders;
    #     contingency_type=CONTINGENCY_OTO
    # )
    # println("Placed OTO list: $list_id")

    # Example 4: OTOCO Sell (Entry + Take Profit + Stop Loss)
    # Working buy order at 48000, when filled triggers OCO: TP at 52000, SL at 47000
    # orders = create_otoco_sell(48000.0, 47000.0, 52000.0, 0.1;
    #     working_side=SIDE_BUY
    # )
    # list_id = new_order_list(oe_session2, "BTCUSDT", orders;
    #     contingency_type=CONTINGENCY_OTO  # OTOCO uses ContingencyType=2
    # )
    # println("Placed OTOCO SELL list: $list_id")

    # Example 5: Cancel an order list
    # cancel_id = order_cancel_request(oe_session2, "BTCUSDT";
    #     orig_cl_list_id=list_id
    # )
end

logout(oe_session2)
close_fix(oe_session2)

# =============================================================================
# 3. Drop Copy Session - Read-Only Execution Reports
# =============================================================================
println("\n========== Drop Copy Session ==========\n")

dc_session = FIXSession(config, sender_comp_id; session_type=DropCopy)
connect_fix(dc_session)

dc_session.on_message = (session, msg) -> begin
    (type, data) = msg
    if type == :execution_report
        println("DropCopy ExecutionReport:")
        println("  Symbol: $(data.symbol), Side: $(data.side)")
        println("  OrderID: $(data.order_id), Status: $(data.ord_status)")
        println("  CumQty: $(data.cum_qty), LeavesQty: $(data.leaves_qty)")
    end
end

logon(dc_session)
start_monitor(dc_session)

if dc_session.is_logged_in
    println("Drop Copy session logged in - listening for executions...")
    # This session will receive all execution reports from all FIX and REST API orders
    sleep(30)
end

logout(dc_session)
close_fix(dc_session)

# =============================================================================
# 4. Market Data Session - Book Ticker
# =============================================================================
println("\n========== Market Data Session - Book Ticker ==========\n")
using Binance
config = Binance.from_toml("config.toml")
sender_comp_id = "abcd1234"

md_session = FIXSession(config, sender_comp_id; session_type=MarketData)
connect_fix(md_session)

md_session.on_message = (session, msg) -> begin
    (type, data) = msg
    println("DEBUG: Received message type: $type")

    if type == :market_data_snapshot
        println("Book Ticker Snapshot: $(data.symbol)")
        for entry in data.entries
            if entry.entry_type == "0"  # Bid
                println("  Best Bid: $(entry.price) x $(entry.size)")
            elseif entry.entry_type == "1"  # Offer
                println("  Best Ask: $(entry.price) x $(entry.size)")
            end
        end
    elseif type == :market_data_incremental
        println("Book Ticker Update:")
        for entry in data.entries
            entry_name = entry.entry_type == "0" ? "Bid" : "Ask"
            println("  $entry_name: $(entry.price) x $(entry.size)")
        end
    elseif type == :market_data_reject
        println("Market Data Request REJECTED:")
        println("  Reason: $(data.reject_reason)")
        println("  Error: $(data.text) (Code: $(data.error_code))")
    elseif type == :reject
        println("Session REJECT:")
        println("  Reason: $(data.session_reject_reason)")
        println("  Error: $(data.text) (Code: $(data.error_code))")
        println("  RefMsgType: $(data.ref_msg_type), RefTagID: $(data.ref_tag_id)")
    else
        println("Unhandled message type: $type")
        if hasproperty(data, :text)
            println("  Text: $(data.text)")
        end
        if hasproperty(data, :error_code)
            println("  ErrorCode: $(data.error_code)")
        end
    end
end

logon(md_session; timeout_sec=30)
start_monitor(md_session)

if md_session.is_logged_in
    # Subscribe to book ticker (best bid/ask)
    req_id = BinanceFIX.FIXAPI.subscribe_book_ticker(md_session, "BTCUSDT")
    println("Subscribed to BTCUSDT book ticker, ReqID: $req_id")

    while md_session.is_logged_in
        sleep(1)
    end
    # Unsubscribe
    BinanceFIX.FIXAPI.unsubscribe_market_data(md_session, req_id)
    println("Unsubscribed from book ticker")
end

logout(md_session)
close_fix(md_session)

# =============================================================================
# 5. Market Data Session - Depth Stream
# =============================================================================
println("\n========== Market Data Session - Depth Stream ==========\n")

md_session2 = FIXSession(config, sender_comp_id; session_type=MarketData)
connect_fix(md_session2)

md_session2.on_message = (session, msg) -> begin
    (type, data) = msg
    if type == :market_data_snapshot
        println("Depth Snapshot: $(data.symbol) (UpdateID: $(data.last_book_update_id))")
        println("  Entries: $(length(data.entries))")
    elseif type == :market_data_incremental
        println("Depth Update (UpdateID: $(data.first_book_update_id)-$(data.last_book_update_id))")
        for entry in data.entries
            action = entry.update_action == "0" ? "New" :
                     entry.update_action == "1" ? "Change" : "Delete"
            side = entry.entry_type == "0" ? "Bid" : "Ask"
            println("  $action $side: $(entry.price) x $(entry.size)")
        end
    end
end

logon(md_session2)
start_monitor(md_session2)

if md_session2.is_logged_in
    # Subscribe to depth updates (order book)
    # Note: Update speed is fixed at 100ms, depth can be 2-5000
    req_id = BinanceFIX.FIXAPI.subscribe_depth_stream(md_session2, "ETHUSDT"; depth=10)
    println("Subscribed to ETHUSDT depth stream, ReqID: $req_id")

    sleep(15)

    BinanceFIX.FIXAPI.unsubscribe_market_data(md_session2, req_id)
end

logout(md_session2)
close_fix(md_session2)

# =============================================================================
# 6. Market Data Session - Trade Stream
# =============================================================================
println("\n========== Market Data Session - Trade Stream ==========\n")

md_session3 = FIXSession(config, sender_comp_id; session_type=MarketData)
connect_fix(md_session3)

md_session3.on_message = (session, msg) -> begin
    (type, data) = msg
    if type == :market_data_incremental
        # Trade updates
        for entry in data.entries
            if entry.entry_type == "2"  # Trade
                side = entry.aggressor_side == "1" ? "BUY" : "SELL"
                println("Trade: $(entry.size) @ $(entry.price) [$side] (ID: $(entry.trade_id))")
            end
        end
    end
end

logon(md_session3)
start_monitor(md_session3)

if md_session3.is_logged_in
    # Subscribe to trade stream
    req_id = BinanceFIX.FIXAPI.subscribe_trade_stream(md_session3, "BTCUSDT")
    println("Subscribed to BTCUSDT trade stream, ReqID: $req_id")

    sleep(15)

    BinanceFIX.FIXAPI.unsubscribe_market_data(md_session3, req_id)
end

logout(md_session3)
close_fix(md_session3)

# =============================================================================
# 7. Connection Lifecycle - Heartbeat and Maintenance Detection
# =============================================================================
println("\n========== Connection Lifecycle Management ==========\n")

lifecycle_session = FIXSession(config, sender_comp_id; session_type=OrderEntry)

# Set up maintenance callback
# Set up maintenance callback
lifecycle_session.on_maintenance = (session, news) -> begin
    println("⚠️  MAINTENANCE WARNING received!")
    println("Headline: $(news)")
    println("Server is entering maintenance. Should establish new session.")
    # In production: create new session, migrate state, close old session
end

# Set up disconnect callback
lifecycle_session.on_disconnect = (session, reason) -> begin
    println("❌ Connection lost or timeout! Reason: $reason")
    # In production: attempt reconnection with exponential backoff
end

connect_fix(lifecycle_session)
logon(lifecycle_session; heartbeat_interval=10)  # Shorter interval for demo
start_monitor(lifecycle_session)

if lifecycle_session.is_logged_in
    println("Session active with HeartBtInt=10s")
    println("Monitoring for heartbeats and maintenance warnings...")

    # The monitor task automatically:
    # - Sends Heartbeat when no message sent within interval
    # - Sends TestRequest when no message received within interval
    # - Detects News<B> maintenance warnings
    # - Handles session timeout

    sleep(30)

    # Manual test request (usually handled automatically by monitor)
    # test_req_id = test_request(lifecycle_session)
    # println("Sent TestRequest: $test_req_id")
end

logout(lifecycle_session)
close_fix(lifecycle_session)

# =============================================================================
# 8. Error Handling Examples
# =============================================================================
println("\n========== Error Handling ==========\n")

error_session = FIXSession(config, sender_comp_id; session_type=OrderEntry)
connect_fix(error_session)

received_reject = Ref(false)

error_session.on_message = (session, msg) -> begin
    (type, data) = msg
    if type == :reject
        println("Session Reject:")
        error_info = get_error_info(data)
        println("  Error: $(error_info.text)")
        println("  Code: $(error_info.error_code)")
        println("  RefMsgType: $(error_info.ref_msg_type)")
        received_reject[] = true
    elseif type == :execution_report && is_rejected(data)
        println("Order Rejected:")
        error_info = get_error_info(data)
        println("  Error: $(error_info.text)")
        println("  Code: $(error_info.error_code)")
        println("  Symbol: $(error_info.symbol)")
    elseif type == :order_cancel_reject
        println("Cancel Rejected:")
        error_info = get_error_info(data)
        println("  Error: $(error_info.text)")
        println("  OrderID: $(error_info.order_id)")
    end
end

logon(error_session)
start_monitor(error_session)

if error_session.is_logged_in
    # Example: Invalid order (should be rejected)
    try
        cl_ord_id = new_order_single(error_session, "INVALID", SIDE_BUY;
            quantity=0.001,
            price=1.0
        )
    catch e
        println("Exception: $e")
    end

    # Example: Cancel non-existent order (should be rejected)
    try
        cancel_id = order_cancel_request(error_session, "BTCUSDT";
            order_id="99999999"
        )
    catch e
        println("Exception: $e")
    end

    println("Error handling examples ready (uncomment to test)")
end

logout(error_session)
close_fix(error_session)

println("\n========== All Examples Complete ==========\n")
