using Binance
using BinanceFIX

# =============================================================================
# Order List Examples - Matching Binance FIX API Specification
# =============================================================================
#
# This file demonstrates the correct usage of OCO, OTO, and OTOCO order lists
# according to the Binance FIX API specification.
#
# IMPORTANT NOTES:
# 1. Order sequence matters! Orders must be in the specified sequence.
# 2. List triggering instructions are REQUIRED for OCO orders.
# 3. OTOCO uses ContingencyType=2 (same as OTO), distinguished by order count.
# =============================================================================

println("=" ^ 80)
println("Binance FIX API - Order List Examples")
println("=" ^ 80)

# Load configuration
if !isfile("config.toml")
    println("\nError: config.toml not found.")
    println("Please create a config.toml with your Ed25519 API key configuration.")
    exit(1)
end

config = Binance.from_toml("config.toml")
sender_comp_id = config.api_key

println("\nThese examples show how to create order lists using helper functions.")
println("The helper functions ensure correct order sequences and triggering instructions.\n")

# =============================================================================
# Example 1: OCO SELL - Stop Loss + Take Profit
# =============================================================================
println("\n" * "=" ^ 80)
println("Example 1: OCO SELL - Stop Loss Below + Take Profit Above")
println("=" ^ 80)
println("""
Scenario: You hold a long position and want to set both stop loss and take profit.

Current price: 0.22 LTCBNB
- Stop loss at 0.20 (below current price)
- Take profit at 0.25 (above current price)

Order sequence:
1. Below order: SELL STOP_LOSS_LIMIT @ 0.20 (triggers if price drops)
2. Above order: SELL LIMIT_MAKER @ 0.25 (fills if price rises)

When one order activates/fills, the other is automatically canceled.
""")

# Using helper function
oco_sell_orders = create_oco_sell(
    0.20,  # below_price (stop loss)
    0.25,  # above_price (take profit)
    1.0    # quantity
)

println("Code to place this OCO:")
println("""
session = FIXSession(config, sender_comp_id; session_type=OrderEntry)
connect_fix(session)
logon(session)

# Create OCO SELL orders
orders = create_oco_sell(0.20, 0.25, 1.0)

# Place the order list
cl_list_id = new_order_list(
    session,
    "LTCBNB",
    orders;
    contingency_type=CONTINGENCY_OCO
)
println("OCO SELL placed with ClListID: \$cl_list_id")
""")

# =============================================================================
# Example 2: OCO BUY - Stop Loss + Take Profit
# =============================================================================
println("\n" * "=" ^ 80)
println("Example 2: OCO BUY - Take Profit Below + Stop Loss Above")
println("=" ^ 80)
println("""
Scenario: You hold a short position and want to set both take profit and stop loss.

Current price: 0.22 LTCBNB
- Take profit at 0.20 (below current price)
- Stop loss at 0.25 (above current price)

Order sequence:
1. Below order: BUY LIMIT_MAKER @ 0.20 (fills if price drops)
2. Above order: BUY STOP_LOSS_LIMIT @ 0.25 (triggers if price rises)

When one order activates/fills, the other is automatically canceled.
""")

oco_buy_orders = create_oco_buy(
    0.20,  # below_price (take profit)
    0.25,  # above_price (stop loss)
    1.0    # quantity
)

println("Code to place this OCO:")
println("""
orders = create_oco_buy(0.20, 0.25, 1.0)

cl_list_id = new_order_list(
    session,
    "LTCBNB",
    orders;
    contingency_type=CONTINGENCY_OCO
)
println("OCO BUY placed with ClListID: \$cl_list_id")
""")

# =============================================================================
# Example 3: OTO - Entry Triggers Exit
# =============================================================================
println("\n" * "=" ^ 80)
println("Example 3: OTO - Entry Order Triggers Exit Order")
println("=" ^ 80)
println("""
Scenario: Place an entry order that automatically places an exit order when filled.

Strategy: Buy at 0.20, then sell at 0.25 for profit

Order sequence:
1. Working order: BUY LIMIT_MAKER @ 0.20 (entry)
2. Pending order: SELL LIMIT @ 0.25 (exit, released when order 1 fills)

The pending order is only placed after the working order is completely filled.
""")

oto_orders = create_oto(
    SIDE_BUY,   # working_side
    0.20,       # working_price
    SIDE_SELL,  # pending_side
    0.25,       # pending_price
    1.0         # quantity
)

println("Code to place this OTO:")
println("""
orders = create_oto(
    SIDE_BUY,   # working_side
    0.20,       # working_price
    SIDE_SELL,  # pending_side
    0.25,       # pending_price
    1.0         # quantity
)

cl_list_id = new_order_list(
    session,
    "LTCBNB",
    orders;
    contingency_type=CONTINGENCY_OTO
)
println("OTO placed with ClListID: \$cl_list_id")
""")

# =============================================================================
# Example 4: OTOCO SELL - Entry Triggers Stop Loss + Take Profit
# =============================================================================
println("\n" * "=" ^ 80)
println("Example 4: OTOCO SELL - Entry Triggers OCO Pair (Stop Loss + Take Profit)")
println("=" ^ 80)
println("""
Scenario: Place an entry order that triggers both stop loss and take profit orders.

Strategy: Buy at 0.20, then set stop loss at 0.18 and take profit at 0.25

Order sequence:
1. Working order: BUY LIMIT_MAKER @ 0.20 (entry)
2. Pending below order: SELL STOP_LOSS_LIMIT @ 0.18 (stop loss, released when order 1 fills)
3. Pending above order: SELL LIMIT_MAKER @ 0.25 (take profit, released when order 1 fills)

After the working order fills, orders 2 and 3 form an OCO pair.
When one of them activates/fills, the other is automatically canceled.
""")

otoco_sell_orders = create_otoco_sell(
    0.20,  # working_price (entry)
    0.18,  # below_price (stop loss)
    0.25,  # above_price (take profit)
    1.0    # quantity
)

println("Code to place this OTOCO:")
println("""
orders = create_otoco_sell(
    0.20,  # working_price (entry)
    0.18,  # below_price (stop loss)
    0.25,  # above_price (take profit)
    1.0    # quantity
)

# Note: OTOCO uses CONTINGENCY_OTO (value "2")
cl_list_id = new_order_list(
    session,
    "LTCBNB",
    orders;
    contingency_type=CONTINGENCY_OTO  # OTOCO uses same type as OTO!
)
println("OTOCO SELL placed with ClListID: \$cl_list_id")
""")

# =============================================================================
# Example 5: OTOCO BUY - Entry Triggers Take Profit + Stop Loss
# =============================================================================
println("\n" * "=" ^ 80)
println("Example 5: OTOCO BUY - Entry Triggers OCO Pair (Take Profit + Stop Loss)")
println("=" ^ 80)
println("""
Scenario: Place a short entry that triggers both take profit and stop loss orders.

Strategy: Sell at 0.22, then set take profit at 0.18 and stop loss at 0.25

Order sequence:
1. Working order: SELL LIMIT_MAKER @ 0.22 (entry)
2. Pending below order: BUY LIMIT_MAKER @ 0.18 (take profit, released when order 1 fills)
3. Pending above order: BUY STOP_LOSS_LIMIT @ 0.25 (stop loss, released when order 1 fills)

After the working order fills, orders 2 and 3 form an OCO pair.
""")

otoco_buy_orders = create_otoco_buy(
    0.22,  # working_price (entry)
    0.18,  # below_price (take profit)
    0.25,  # above_price (stop loss)
    1.0    # quantity
)

println("Code to place this OTOCO:")
println("""
orders = create_otoco_buy(
    0.22,  # working_price (entry)
    0.18,  # below_price (take profit)
    0.25,  # above_price (stop loss)
    1.0    # quantity
)

cl_list_id = new_order_list(
    session,
    "LTCBNB",
    orders;
    contingency_type=CONTINGENCY_OTO  # OTOCO uses same type as OTO!
)
println("OTOCO BUY placed with ClListID: \$cl_list_id")
""")

# =============================================================================
# Example 6: Manual Order List Construction (Advanced)
# =============================================================================
println("\n" * "=" ^ 80)
println("Example 6: Manual Order List Construction (Advanced)")
println("=" ^ 80)
println("""
For advanced use cases, you can manually construct order lists.
This gives you full control over all order parameters.

IMPORTANT: You must ensure:
1. Correct order sequence (below/above for OCO, working/pending for OTO/OTOCO)
2. Correct list triggering instructions for each order
3. Correct ContingencyType (1 for OCO, 2 for OTO/OTOCO)
""")

println("Example: Manual OCO SELL construction")
println("""
manual_oco_orders = [
    # Order 1: Below order (STOP_LOSS_LIMIT)
    Dict{Symbol,Any}(
        :side => SIDE_SELL,
        :ord_type => ORD_TYPE_STOP_LIMIT,
        :quantity => 1.0,
        :price => 0.20,
        :trigger_price => 0.20,
        :trigger_price_direction => TRIGGER_DOWN,
        :time_in_force => TIF_GTC,
        :list_trigger_instructions => [
            Dict{Symbol,Any}(
                :trigger_type => LIST_TRIGGER_PARTIALLY_FILLED,
                :trigger_index => 1,
                :action => LIST_TRIGGER_ACTION_CANCEL
            )
        ]
    ),
    # Order 2: Above order (LIMIT_MAKER)
    Dict{Symbol,Any}(
        :side => SIDE_SELL,
        :ord_type => ORD_TYPE_LIMIT,
        :quantity => 1.0,
        :price => 0.25,
        :time_in_force => TIF_GTC,
        :exec_inst => EXEC_INST_PARTICIPATE_DONT_INITIATE,
        :list_trigger_instructions => [
            Dict{Symbol,Any}(
                :trigger_type => LIST_TRIGGER_ACTIVATED,
                :trigger_index => 0,
                :action => LIST_TRIGGER_ACTION_CANCEL
            )
        ]
    )
]

cl_list_id = new_order_list(
    session,
    "LTCBNB",
    manual_oco_orders;
    contingency_type=CONTINGENCY_OCO
)
""")

# =============================================================================
# Summary
# =============================================================================
println("\n" * "=" ^ 80)
println("Summary")
println("=" ^ 80)
println("""
Order List Types:
┌──────────┬─────────────────┬────────────┬──────────────────────────────────┐
│ Type     │ ContingencyType │ # Orders   │ Description                      │
├──────────┼─────────────────┼────────────┼──────────────────────────────────┤
│ OCO      │ 1               │ 2          │ One-Cancels-the-Other            │
│ OTO      │ 2               │ 2          │ One-Triggers-the-Other           │
│ OTOCO    │ 2               │ 3          │ One-Triggers-OCO                 │
└──────────┴─────────────────┴────────────┴──────────────────────────────────┘

Helper Functions:
- create_oco_sell(below_price, above_price, quantity)
  → Stop loss below + take profit above (for long positions)

- create_oco_buy(below_price, above_price, quantity)
  → Take profit below + stop loss above (for short positions)

- create_oto(working_side, working_price, pending_side, pending_price, quantity)
  → Entry order triggers exit order

- create_otoco_sell(working_price, below_price, above_price, quantity)
  → Entry triggers stop loss + take profit (for long positions)

- create_otoco_buy(working_price, below_price, above_price, quantity)
  → Entry triggers take profit + stop loss (for short positions)

Key Points:
✓ Order sequence is critical - use helper functions to ensure correctness
✓ List triggering instructions are REQUIRED for OCO orders
✓ OTOCO uses ContingencyType=2 (same as OTO)
✓ All helper functions return properly structured order vectors
✓ Helper functions automatically set correct triggering instructions

For more details, see the Binance FIX API documentation.
""")
