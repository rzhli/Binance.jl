using Binance
using BinanceFIX

# =============================================================================
# NewOrderList Examples - OCO, OTO, OTOCO
# =============================================================================

println("=" ^ 60)
println("NewOrderList Examples")
println("=" ^ 60)

# Load config
if !isfile("config.toml")
    println("Error: config.toml not found.")
    exit(1)
end

config = Binance.from_toml("config.toml")
sender_comp_id = config.api_key

# =============================================================================
# Example 1: OCO (One-Cancels-the-Other)
# =============================================================================
println("\n1. OCO Example - Limit order with stop loss")
println("-" ^ 60)

# OCO: Place a limit sell order with a stop loss buy order
# When one fills, the other is automatically canceled
oco_orders = [
    Dict{Symbol,Any}(
        :side => SIDE_SELL,
        :ord_type => ORD_TYPE_LIMIT,
        :quantity => 1.0,
        :price => 0.25,
        :time_in_force => TIF_GTC
    ),
    Dict{Symbol,Any}(
        :side => SIDE_SELL,
        :ord_type => ORD_TYPE_STOP_LIMIT,
        :quantity => 1.0,
        :price => 0.20,
        :trigger_price => 0.20,
        :trigger_price_direction => TRIGGER_DOWN,
        :time_in_force => TIF_GTC
    )
]

println("OCO Orders:")
println("  Order 1: SELL 1.0 @ 0.25 (Limit)")
println("  Order 2: SELL 1.0 @ 0.20 (Stop-Limit, trigger @ 0.20)")
println("\nTo place this OCO:")
println("""
session = FIXSession(config, sender_comp_id; session_type=OrderEntry)
connect_fix(session)
logon(session)

cl_list_id = new_order_list(
    session,
    "LTCBNB",
    oco_orders;
    contingency_type=CONTINGENCY_OCO
)
println("OCO placed with ClListID: \$cl_list_id")
""")

# =============================================================================
# Example 2: OTO (One-Triggers-the-Other)
# =============================================================================
println("\n2. OTO Example - Entry order triggers take profit")
println("-" ^ 60)

# OTO: First order triggers the second order when filled
# Order 1: Buy limit order (entry)
# Order 2: Sell limit order (take profit) - only placed when Order 1 fills
oto_orders = [
    Dict{Symbol,Any}(
        :side => SIDE_BUY,
        :ord_type => ORD_TYPE_LIMIT,
        :quantity => 1.0,
        :price => 0.20,
        :time_in_force => TIF_GTC
    ),
    Dict{Symbol,Any}(
        :side => SIDE_SELL,
        :ord_type => ORD_TYPE_LIMIT,
        :quantity => 1.0,
        :price => 0.25,
        :time_in_force => TIF_GTC,
        # This order is released when Order 1 (index 0) is FILLED
        :list_trigger_instructions => [
            Dict{Symbol,Any}(
                :trigger_type => LIST_TRIGGER_FILLED,
                :trigger_index => 0,
                :action => LIST_TRIGGER_ACTION_RELEASE
            )
        ]
    )
]

println("OTO Orders:")
println("  Order 1: BUY 1.0 @ 0.20 (Limit) - Entry order")
println("  Order 2: SELL 1.0 @ 0.25 (Limit) - Released when Order 1 fills")
println("\nTo place this OTO:")
println("""
cl_list_id = new_order_list(
    session,
    "LTCBNB",
    oto_orders;
    contingency_type=CONTINGENCY_OTO
)
println("OTO placed with ClListID: \$cl_list_id")
""")

# =============================================================================
# Example 3: OTOCO (One-Triggers-OCO)
# =============================================================================
println("\n3. OTOCO Example - Entry triggers take profit + stop loss")
println("-" ^ 60)

# OTOCO: First order triggers an OCO pair
# Order 1: Buy limit order (entry)
# Order 2: Sell limit order (take profit) - released when Order 1 fills
# Order 3: Sell stop-limit order (stop loss) - released when Order 1 fills
# Orders 2 and 3 form an OCO pair
otoco_orders = [
    Dict{Symbol,Any}(
        :side => SIDE_BUY,
        :ord_type => ORD_TYPE_LIMIT,
        :quantity => 1.0,
        :price => 0.20,
        :time_in_force => TIF_GTC
    ),
    Dict{Symbol,Any}(
        :side => SIDE_SELL,
        :ord_type => ORD_TYPE_LIMIT,
        :quantity => 1.0,
        :price => 0.25,
        :time_in_force => TIF_GTC,
        # Released when Order 1 (index 0) is FILLED
        :list_trigger_instructions => [
            Dict{Symbol,Any}(
                :trigger_type => LIST_TRIGGER_FILLED,
                :trigger_index => 0,
                :action => LIST_TRIGGER_ACTION_RELEASE
            )
        ]
    ),
    Dict{Symbol,Any}(
        :side => SIDE_SELL,
        :ord_type => ORD_TYPE_STOP_LIMIT,
        :quantity => 1.0,
        :price => 0.18,
        :trigger_price => 0.18,
        :trigger_price_direction => TRIGGER_DOWN,
        :time_in_force => TIF_GTC,
        # Released when Order 1 (index 0) is FILLED
        :list_trigger_instructions => [
            Dict{Symbol,Any}(
                :trigger_type => LIST_TRIGGER_FILLED,
                :trigger_index => 0,
                :action => LIST_TRIGGER_ACTION_RELEASE
            )
        ]
    )
]

println("OTOCO Orders:")
println("  Order 1: BUY 1.0 @ 0.20 (Limit) - Entry order")
println("  Order 2: SELL 1.0 @ 0.25 (Limit) - Take profit, released when Order 1 fills")
println("  Order 3: SELL 1.0 @ 0.18 (Stop-Limit @ 0.18) - Stop loss, released when Order 1 fills")
println("  Orders 2 and 3 form an OCO pair")
println("\nTo place this OTOCO:")
println("""
cl_list_id = new_order_list(
    session,
    "LTCBNB",
    otoco_orders;
    contingency_type=CONTINGENCY_OTOCO
)
println("OTOCO placed with ClListID: \$cl_list_id")
""")

# =============================================================================
# Example 4: Advanced - OTO with Trailing Stop
# =============================================================================
println("\n4. Advanced OTO Example - Entry triggers trailing stop")
println("-" ^ 60)

oto_trailing_orders = [
    Dict{Symbol,Any}(
        :side => SIDE_BUY,
        :ord_type => ORD_TYPE_MARKET,
        :quantity => 1.0
    ),
    Dict{Symbol,Any}(
        :side => SIDE_SELL,
        :ord_type => ORD_TYPE_STOP_LIMIT,
        :quantity => 1.0,
        :price => 0.18,
        :trigger_price => 0.18,
        :trigger_price_direction => TRIGGER_DOWN,
        :trigger_trailing_delta_bips => 100,  # 1% trailing
        :time_in_force => TIF_GTC,
        :list_trigger_instructions => [
            Dict{Symbol,Any}(
                :trigger_type => LIST_TRIGGER_FILLED,
                :trigger_index => 0,
                :action => LIST_TRIGGER_ACTION_RELEASE
            )
        ]
    )
]

println("OTO with Trailing Stop:")
println("  Order 1: BUY 1.0 (Market) - Entry order")
println("  Order 2: SELL 1.0 (Trailing Stop @ 1%) - Released when Order 1 fills")
println("\nTo place this OTO:")
println("""
cl_list_id = new_order_list(
    session,
    "LTCBNB",
    oto_trailing_orders;
    contingency_type=CONTINGENCY_OTO
)
println("OTO with trailing stop placed with ClListID: \$cl_list_id")
""")

# =============================================================================
# Example 5: Advanced - OCO with Iceberg Orders
# =============================================================================
println("\n5. Advanced OCO Example - Iceberg orders")
println("-" ^ 60)

oco_iceberg_orders = [
    Dict{Symbol,Any}(
        :side => SIDE_SELL,
        :ord_type => ORD_TYPE_LIMIT,
        :quantity => 10.0,
        :price => 0.25,
        :max_floor => 2.0,  # Show only 2.0 at a time
        :time_in_force => TIF_GTC
    ),
    Dict{Symbol,Any}(
        :side => SIDE_SELL,
        :ord_type => ORD_TYPE_STOP_LIMIT,
        :quantity => 10.0,
        :price => 0.20,
        :trigger_price => 0.20,
        :trigger_price_direction => TRIGGER_DOWN,
        :max_floor => 2.0,
        :time_in_force => TIF_GTC
    )
]

println("OCO with Iceberg Orders:")
println("  Order 1: SELL 10.0 @ 0.25 (Limit, iceberg 2.0)")
println("  Order 2: SELL 10.0 @ 0.20 (Stop-Limit, iceberg 2.0)")
println("\nTo place this OCO:")
println("""
cl_list_id = new_order_list(
    session,
    "LTCBNB",
    oco_iceberg_orders;
    contingency_type=CONTINGENCY_OCO
)
println("OCO with iceberg orders placed with ClListID: \$cl_list_id")
""")

# =============================================================================
# Summary
# =============================================================================
println("\n" ^ 2)
println("=" ^ 60)
println("Summary")
println("=" ^ 60)
println("""
Order List Types:
- OCO (One-Cancels-the-Other): 2 orders, when one fills/cancels, the other is canceled
- OTO (One-Triggers-the-Other): 2 orders, first order triggers the second
- OTOCO (One-Triggers-OCO): 3 orders, first order triggers an OCO pair

Unfilled Order Count:
- OCO: 2 orders
- OTO: 2 orders
- OTOCO: 3 orders

Key Features Supported:
✓ All order types (Market, Limit, Stop, Stop-Limit, Pegged)
✓ Trigger/Stop orders with direction (Up/Down)
✓ Trailing stops (TriggerTrailingDeltaBips)
✓ Iceberg orders (MaxFloor)
✓ Pegged orders (PegOffsetValue, PegPriceType, etc.)
✓ Self-trade prevention modes
✓ Strategy IDs and Target Strategy
✓ List triggering instructions for OTO/OTOCO

For more details, see the Binance FIX API documentation.
""")
