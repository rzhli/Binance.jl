"""
OrderBookManager Advanced Usage Example

This example demonstrates advanced features:
1. Using custom callbacks for real-time updates
2. Implementing a simple trading strategy with order book data
3. Market microstructure analysis
"""

using Binance
using Printf
using Statistics

function advanced_orderbook_example()
    println("="^70)
    println("OrderBookManager Advanced Usage Example")
    println("="^70)
    println()

    rest_client = RESTClient("config.toml")
    ws_client = MarketDataStreamClient("config.toml")

    # Example 1: Custom callback for monitoring
    println("[Example 1] OrderBookManager with Custom Callback")
    println("-"^70)

    update_count = Ref{Int}(0)
    large_spread_count = Ref{Int}(0)

    function my_callback(manager)
        update_count[] += 1

        # Alert on large spreads
        spread = get_spread(manager)
        if !isnothing(spread) && spread > 10.0
            large_spread_count[] += 1
            best_bid = get_best_bid(manager)
            best_ask = get_best_ask(manager)
            @printf("  ⚠️  Large spread detected: \$%.2f (bid: \$%.2f, ask: \$%.2f)\n",
                    spread, best_bid.price, best_ask.price)
        end
    end

    orderbook = OrderBookManager("BTCUSDT", rest_client, ws_client; update_speed="100ms", on_update=my_callback)

    start!(orderbook)

    # Wait for initialization
    while !is_ready(orderbook)
        sleep(0.5)
    end
    println("  ✓ Initialized")

    println("  Monitoring for 20 seconds...")
    sleep(20)

    println("  Total updates: $(update_count[])")
    println("  Large spreads detected: $(large_spread_count[])")
    println()

    # Example 2: Order book imbalance trading signal
    println("[Example 2] Order Book Imbalance Strategy")
    println("-"^70)

    imbalance_history = Float64[]

    for i in 1:30
        imbalance = calculate_depth_imbalance(orderbook; levels=20)

        if !isnothing(imbalance)
            push!(imbalance_history, imbalance)

            if length(imbalance_history) > 10
                popfirst!(imbalance_history)
            end

            avg_imbalance = mean(imbalance_history)

            if i % 5 == 0  # Print every 5 seconds
                mid_price = get_mid_price(orderbook)
                @printf("[%2ds] Price: \$%.2f | Imbalance: %+.3f | Avg(10): %+.3f | ",
                        i, mid_price, imbalance, avg_imbalance)

                # Trading signal
                if avg_imbalance > 0.3
                    println("Signal: STRONG BUY 🟢")
                elseif avg_imbalance > 0.1
                    println("Signal: BUY 🟩")
                elseif avg_imbalance < -0.3
                    println("Signal: STRONG SELL 🔴")
                elseif avg_imbalance < -0.1
                    println("Signal: SELL 🟥")
                else
                    println("Signal: NEUTRAL ⚪")
                end
            end
        end

        sleep(1)
    end
    println()

    # Example 3: Liquidity analysis
    println("[Example 3] Liquidity Analysis")
    println("-"^70)

    sizes_to_test = [0.1, 0.5, 1.0, 5.0, 10.0]

    println("\n  BUY Side Analysis:")
    println("  Size (BTC)  | VWAP (\$)  | Premium (%)")
    println("  " * "-"^45)

    best_ask = get_best_ask(orderbook)
    if !isnothing(best_ask)
        for size in sizes_to_test
            result = calculate_vwap(orderbook, size, :buy)
            if !isnothing(result)
                premium = (result.vwap - best_ask.price) / best_ask.price * 100
                @printf("  %-11.1f | \$%-9.2f | %+.3f%%\n",
                        size, result.vwap, premium)
            else
                @printf("  %-11.1f | Insufficient liquidity\n", size)
            end
        end
    end

    println("\n  SELL Side Analysis:")
    println("  Size (BTC)  | VWAP (\$)  | Discount (%)")
    println("  " * "-"^45)

    best_bid = get_best_bid(orderbook)
    if !isnothing(best_bid)
        for size in sizes_to_test
            result = calculate_vwap(orderbook, size, :sell)
            if !isnothing(result)
                discount = (best_bid.price - result.vwap) / best_bid.price * 100
                @printf("  %-11.1f | \$%-9.2f | %+.3f%%\n",
                        size, result.vwap, discount)
            else
                @printf("  %-11.1f | Insufficient liquidity\n", size)
            end
        end
    end
    println()

    # Example 4: Order book snapshot
    println("[Example 4] Order Book Snapshot")
    println("-"^70)

    snapshot = get_orderbook_snapshot(orderbook; max_levels=10)

    println("  Symbol: $(snapshot.symbol)")
    println("  Update ID: $(snapshot.update_id)")
    println("  Timestamp: $(snapshot.timestamp)")
    println("\n  Top 10 Levels:")
    println()

    @printf("  %-4s %-12s %-12s | %-12s %-12s\n",
            "#", "Bid Qty", "Bid Price", "Ask Price", "Ask Qty")
    println("  " * "-"^60)

    for i in 1:min(10, length(snapshot.bids), length(snapshot.asks))
        bid = snapshot.bids[i]
        ask = snapshot.asks[i]

        @printf("  %-4d %-12.6f \$%-11.2f | \$%-11.2f %-12.6f\n",
                i, bid.quantity, bid.price, ask.price, ask.quantity)
    end
    println()

    # Cleanup
    println("="^70)
    println("Shutting down...")
    println("="^70)
    stop!(orderbook)

    println()
    println("Advanced example completed successfully!")
end

# Run the example
# Uncomment to execute:
advanced_orderbook_example()
