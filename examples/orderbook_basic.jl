"""
OrderBookManager Basic Usage Example

This example demonstrates how to use the OrderBookManager to maintain a
synchronized local order book.

Prerequisites:
1. Valid config.toml with API credentials
2. DataStructures package installed (already included in dependencies)
"""

using Binance
using Printf

function basic_orderbook_example()
    println("="^70)
    println("OrderBookManager Basic Usage Example")
    println("="^70)
    println()

    # Create clients
    println("[1] Creating clients...")
    rest_client = RESTClient("config.toml")
    ws_client = MarketDataStreamClient("config.toml")

    # Create OrderBookManager
    println("[2] Creating OrderBookManager for BTCUSDT...")
    orderbook = OrderBookManager("BTCUSDT", rest_client, ws_client;
                                 max_depth=5000,      # Use maximum depth
                                 update_speed="100ms") # Fast updates

    # Start synchronization
    println("[3] Starting order book synchronization...")
    println("    (This will buffer events, fetch snapshot, and synchronize)")
    start!(orderbook)

    # Wait for initialization
    println("[4] Waiting for order book to initialize...")
    max_wait = 30  # Maximum 30 seconds
    for i in 1:max_wait
        if is_ready(orderbook)
            println("    ✓ Order book initialized!")
            break
        end
        if i == max_wait
            error("Order book failed to initialize within $max_wait seconds")
        end
        sleep(1)
    end

    println()
    println("="^70)
    println("Order Book Data Access")
    println("="^70)
    println()

    # Get best bid and ask
    best_bid = get_best_bid(orderbook)
    best_ask = get_best_ask(orderbook)

    if !isnothing(best_bid) && !isnothing(best_ask)
        println("[Best Prices]")
        println("  Best Bid: \$$(best_bid.price) × $(best_bid.quantity) BTC")
        println("  Best Ask: \$$(best_ask.price) × $(best_ask.quantity) BTC")
        println("  Spread:   \$$(get_spread(orderbook))")
        println("  Mid Price: \$$(get_mid_price(orderbook))")
        println()
    end

    # Get top 5 levels
    println("[Top 5 Levels]")
    top_bids = get_bids(orderbook, 5)
    top_asks = get_asks(orderbook, 5)

    println("\n  BIDS (Buy Orders):")
    for (i, level) in enumerate(top_bids)
        @printf("    %d. \$%-10.2f × %-10.6f BTC\n", i, level.price, level.quantity)
    end

    println("\n  ASKS (Sell Orders):")
    for (i, level) in enumerate(top_asks)
        @printf("    %d. \$%-10.2f × %-10.6f BTC\n", i, level.price, level.quantity)
    end
    println()

    # Calculate VWAP
    println("[VWAP Analysis]")
    buy_vwap = calculate_vwap(orderbook, 1.0, :buy)  # VWAP for buying 1 BTC
    sell_vwap = calculate_vwap(orderbook, 1.0, :sell) # VWAP for selling 1 BTC

    if !isnothing(buy_vwap)
        @printf("  To BUY 1.0 BTC:   VWAP = \$%.2f (Total cost: \$%.2f)\n",
                buy_vwap.vwap, buy_vwap.total_cost)
    end

    if !isnothing(sell_vwap)
        @printf("  To SELL 1.0 BTC:  VWAP = \$%.2f (Total proceeds: \$%.2f)\n",
                sell_vwap.vwap, sell_vwap.total_cost)
    end

    if !isnothing(buy_vwap) && !isnothing(sell_vwap)
        slippage = buy_vwap.vwap - sell_vwap.vwap
        @printf("  Market Impact (1 BTC round-trip): \$%.2f\n", slippage)
    end
    println()

    # Calculate depth imbalance
    imbalance = calculate_depth_imbalance(orderbook; levels=10)
    if !isnothing(imbalance)
        println("[Order Book Imbalance]")
        @printf("  Top 10 levels imbalance: %.4f\n", imbalance)
        if imbalance > 0.2
            println("  → Strong buy pressure (bullish)")
        elseif imbalance < -0.2
            println("  → Strong sell pressure (bearish)")
        else
            println("  → Balanced order book (neutral)")
        end
        println()
    end

    # Monitor updates for a while
    println("="^70)
    println("Monitoring Order Book Updates (30 seconds)")
    println("="^70)
    println()

    last_mid_price = get_mid_price(orderbook)
    update_count = 0

    for i in 1:30
        sleep(1)

        current_mid_price = get_mid_price(orderbook)
        if isnothing(current_mid_price)
            continue
        end

        if abs(current_mid_price - last_mid_price) > 0.01
            price_change = current_mid_price - last_mid_price
            direction = price_change > 0 ? "↑" : "↓"

            @printf("[%2ds] Mid Price: \$%.2f %s (Change: %+.2f)\n",
                    i, current_mid_price, direction, price_change)

            last_mid_price = current_mid_price
            update_count += 1
        end
    end

    println()
    println("Total price updates detected: $update_count")
    println()

    # Cleanup
    println("="^70)
    println("Shutting down...")
    println("="^70)
    stop!(orderbook)

    println()
    println("Example completed successfully!")
end

# Run the example
# Uncomment to execute:
# basic_orderbook_example()
