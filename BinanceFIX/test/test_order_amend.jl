using Binance
using BinanceFIX

# =============================================================================
# Order Amend Keep Priority Examples
# =============================================================================
#
# OrderAmendKeepPriorityRequest (XAK) allows you to reduce the quantity of an
# existing order while maintaining its position in the order book queue.
#
# Key Features:
# - Unfilled Order Count: 0 (does not count toward order limits)
# - Only quantity can be decreased, not increased
# - Maintains queue priority (order stays in same position)
# - Can use same ClOrdID as original order
# =============================================================================

println("=" ^ 80)
println("Order Amend Keep Priority Examples")
println("=" ^ 80)

# Load configuration
if !isfile("config.toml")
    println("\nError: config.toml not found.")
    println("Please create a config.toml with your Ed25519 API key configuration.")
    exit(1)
end

config = Binance.from_toml("config.toml")
sender_comp_id = config.api_key

println("\nThese examples show how to amend order quantities while keeping queue priority.\n")

# =============================================================================
# Example 1: Basic Order Amend by OrderID
# =============================================================================
println("\n" * "=" ^ 80)
println("Example 1: Amend Order by OrderID")
println("=" ^ 80)
println("""
Scenario: You have an open order and want to reduce its quantity.

Original order:
- Symbol: BTCUSDT
- OrderID: 12345
- Original quantity: 1.0 BTC
- New quantity: 0.9 BTC (reduced by 0.1)

Using OrderID is the preferred method for performance.
""")

println("Code to amend the order:")
println("""
session = FIXSession(config, sender_comp_id; session_type=OrderEntry)
connect_fix(session)
logon(session)

# Amend order by OrderID
cl_ord_id = order_amend_keep_priority(
    session,
    "BTCUSDT",
    0.9;                    # New quantity (must be < original)
    order_id="12345"        # OrderID to amend
)
println("Amend request sent with ClOrdID: \$cl_ord_id")

# Wait for response
sleep(1)
messages = receive_message(session)
for msg in messages
    msg_type, data = process_message(session, msg)

    if msg_type == :execution_report && data isa ExecutionReportMsg
        println("✓ Order amended successfully!")
        println("  OrderID: \$(data.order_id)")
        println("  New quantity: \$(data.order_qty)")
        println("  Leaves quantity: \$(data.leaves_qty)")
    elseif msg_type == :order_amend_reject && data isa OrderAmendRejectMsg
        error_info = get_error_info(data)
        println("✗ Amend rejected: \$(error_info.text)")
        println("  Error code: \$(error_info.error_code)")
    end
end
""")

# =============================================================================
# Example 2: Amend Order by OrigClOrdID
# =============================================================================
println("\n" * "=" ^ 80)
println("Example 2: Amend Order by OrigClOrdID")
println("=" ^ 80)
println("""
Scenario: You know the original ClOrdID but not the OrderID.

Original order:
- Symbol: BTCUSDT
- OrigClOrdID: "my-order-123"
- Original quantity: 2.0 BTC
- New quantity: 1.5 BTC
""")

println("Code to amend the order:")
println("""
cl_ord_id = order_amend_keep_priority(
    session,
    "BTCUSDT",
    1.5;                           # New quantity
    orig_cl_ord_id="my-order-123"  # Original ClOrdID
)
println("Amend request sent with ClOrdID: \$cl_ord_id")
""")

# =============================================================================
# Example 3: Amend with Same ClOrdID
# =============================================================================
println("\n" * "=" ^ 80)
println("Example 3: Amend Using Same ClOrdID")
println("=" ^ 80)
println("""
Scenario: You want to keep the same ClOrdID for the amended order.

Note: If the ClOrdID of the amend request is the same as the order's ClOrdID,
the ClOrdID will remain unchanged after the amend.

Original order:
- Symbol: BTCUSDT
- ClOrdID: "my-order-456"
- Original quantity: 5.0 BTC
- New quantity: 4.0 BTC
""")

println("Code to amend the order:")
println("""
# Use the same ClOrdID as the original order
cl_ord_id = order_amend_keep_priority(
    session,
    "BTCUSDT",
    4.0;
    cl_ord_id="my-order-456",      # Same as original
    orig_cl_ord_id="my-order-456"  # Original ClOrdID
)
# The order will keep ClOrdID "my-order-456" after amend
""")

# =============================================================================
# Example 4: Amend Order in an Order List
# =============================================================================
println("\n" * "=" ^ 80)
println("Example 4: Amend Order in an Order List (OCO/OTO/OTOCO)")
println("=" ^ 80)
println("""
Scenario: You have an order that's part of an order list and want to reduce its quantity.

When amending an order in an order list:
- You'll receive ExecutionReport<8> for the amended order
- You'll also receive ListStatus<N> for the order list update

Original order list:
- Type: OCO
- Order 1: SELL 10.0 @ 0.25 (limit)
- Order 2: SELL 10.0 @ 0.20 (stop loss)

Amending Order 1 to 8.0:
""")

println("Code to amend the order:")
println("""
# Amend the first order in the list
cl_ord_id = order_amend_keep_priority(
    session,
    "LTCBNB",
    8.0;
    order_id="12345"  # OrderID of the first order
)

# Wait for responses
sleep(1)
messages = receive_message(session)
for msg in messages
    msg_type, data = process_message(session, msg)

    if msg_type == :execution_report && data isa ExecutionReportMsg
        println("✓ Order amended: \$(data.order_id)")
        println("  New quantity: \$(data.order_qty)")
    elseif msg_type == :list_status && data isa ListStatusMsg
        println("✓ Order list updated: \$(data.list_id)")
        println("  List status: \$(data.list_order_status)")
    end
end
""")

# =============================================================================
# Example 5: Error Handling
# =============================================================================
println("\n" * "=" ^ 80)
println("Example 5: Error Handling")
println("=" ^ 80)
println("""
Common reasons for OrderAmendReject:

1. Insufficient order rate limits
2. Order doesn't exist (wrong OrderID or OrigClOrdID)
3. Invalid quantity (greater than or equal to original)
4. Order already filled or canceled
5. Symbol mismatch
""")

println("Code with error handling:")
println("""
cl_ord_id = order_amend_keep_priority(
    session,
    "BTCUSDT",
    0.5;
    order_id="12345"
)

sleep(1)
messages = receive_message(session)
for msg in messages
    msg_type, data = process_message(session, msg)

    if msg_type == :execution_report && data isa ExecutionReportMsg
        if is_rejected(data)
            # Order amend was rejected
            error_info = get_error_info(data)
            println("✗ Amend rejected in ExecutionReport")
            println("  Error: \$(error_info.text)")
        else
            println("✓ Order amended successfully")
        end
    elseif msg_type == :order_amend_reject && data isa OrderAmendRejectMsg
        # Dedicated amend reject message
        error_info = get_error_info(data)
        println("✗ OrderAmendReject received")
        println("  Error code: \$(error_info.error_code)")
        println("  Error text: \$(error_info.text)")
        println("  Symbol: \$(error_info.symbol)")
        println("  OrderID: \$(error_info.order_id)")
        println("  Attempted quantity: \$(error_info.order_qty)")
    elseif msg_type == :reject && data isa RejectMsg
        # Session-level reject
        error_info = get_error_info(data)
        println("✗ Session Reject")
        println("  Error: \$(error_info.text)")
    end
end
""")

# =============================================================================
# Example 6: Both OrderID and OrigClOrdID
# =============================================================================
println("\n" * "=" ^ 80)
println("Example 6: Providing Both OrderID and OrigClOrdID")
println("=" ^ 80)
println("""
Scenario: You provide both OrderID and OrigClOrdID for verification.

Behavior:
1. OrderID is searched first
2. Then OrigClOrdID from that result is checked
3. If both conditions are not met, the request is rejected

This provides an extra layer of verification to ensure you're amending
the correct order.
""")

println("Code:")
println("""
cl_ord_id = order_amend_keep_priority(
    session,
    "BTCUSDT",
    0.8;
    order_id="12345",              # Search by this first
    orig_cl_ord_id="my-order-123"  # Then verify this matches
)
# Request will be rejected if OrderID 12345 doesn't have OrigClOrdID "my-order-123"
""")

# =============================================================================
# Summary
# =============================================================================
println("\n" * "=" ^ 80)
println("Summary")
println("=" ^ 80)
println("""
Order Amend Keep Priority (XAK):

Key Features:
✓ Reduces order quantity while maintaining queue priority
✓ Does not count toward order limits (Unfilled Order Count: 0)
✓ Can use same ClOrdID as original order
✓ Works with orders in order lists (OCO/OTO/OTOCO)

Requirements:
- New quantity must be smaller than original
- Either OrderID or OrigClOrdID must be provided
- OrderID is preferred for better performance

Response Messages:
- Reject<3>: Invalid request (missing fields, invalid symbol, message limit)
- OrderAmendReject<XAR>: Failed (rate limits, non-existent order, invalid quantity)
- ExecutionReport<8>: Success for single order
- ExecutionReport<8> + ListStatus<N>: Success for order in list

Common Use Cases:
1. Reduce position size without losing queue priority
2. Adjust order quantity based on market conditions
3. Risk management (reduce exposure)
4. Partial order cancellation while staying in queue

Helper Functions:
- is_error(msg::OrderAmendRejectMsg) -> Bool
- get_error_info(msg::OrderAmendRejectMsg) -> NamedTuple

For more details, see the Binance FIX API documentation and
Order Amend Keep Priority FAQ.
""")
