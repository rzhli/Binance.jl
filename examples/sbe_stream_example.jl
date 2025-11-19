"""
SBE Market Data Streams Example

Demonstrates how to use Binance SBE (Simple Binary Encoding) market data streams.

# Features
- Binary encoding, more efficient than JSON
- Lower latency
- Reduced bandwidth consumption
- Suitable for high-frequency trading scenarios

# Important Notes
- Requires Ed25519 API Key
- Connection valid for 24 hours

# Available Streams
- <symbol>@trade          - Real-time trade data
- <symbol>@bestBidAsk     - Best bid/ask (supports auto-culling)
- <symbol>@depth          - Incremental order book updates (50ms)
- <symbol>@depth20        - Top 20 levels snapshot (50ms)
"""

using Binance
using Dates

# ============================================================================
# Example 1: Subscribe to Real-time Trade Stream
# ============================================================================

# Create SBE client
sbe_client = SBEStreamClient()

# Connect to SBE stream endpoint
connect_sbe!(sbe_client)

# Define trade event callback function
function handle_trade_event(trade_event::TradeEvent)
    println("\nTrade Event:")
    println("  Symbol: $(trade_event.symbol)")
    println("  Event Time: $(unix2datetime(trade_event.eventTime / 1_000_000))")
    println("  Trade Count: $(length(trade_event.trades))")

    # Only show first 3 trades
    for (i, trade) in enumerate(trade_event.trades[1:min(3, end)])
        side = trade.isBuyerMaker ? "SELL" : "BUY"
        println("  [$i] $side $(trade.price) @ $(trade.qty)")
    end

    if length(trade_event.trades) > 3
        println("  ... and $(length(trade_event.trades) - 3) more trades")
    end
end

# Subscribe to BTCUSDT trade stream
sbe_subscribe_trade(sbe_client, "BTCUSDT", handle_trade_event)

# Unsubscribe
sbe_unsubscribe(sbe_client, "btcusdt@trade")

# ============================================================================
# Example 2: Subscribe to Best Bid/Ask Stream
# ============================================================================

# Define best bid/ask callback function
function handle_best_bid_ask(bid_ask_event::BestBidAskEvent)
    println("\nBest Bid/Ask:")
    println("  Symbol: $(bid_ask_event.symbol)")
    println("  Update ID: $(bid_ask_event.bookUpdateId)")
    println("  Event Time: $(unix2datetime(bid_ask_event.eventTime / 1_000_000))")
    println("  Best Bid: $(bid_ask_event.bidPrice) @ $(bid_ask_event.bidQty)")
    println("  Best Ask: $(bid_ask_event.askPrice) @ $(bid_ask_event.askQty)")
    spread = bid_ask_event.askPrice - bid_ask_event.bidPrice
    spread_bps = (spread / bid_ask_event.bidPrice) * 10000
    println("  Spread: $spread ($(round(spread_bps, digits=2)) bps)")
end

sbe_subscribe_best_bid_ask(sbe_client, "BTCUSDT", handle_best_bid_ask)

# Unsubscribe
sbe_unsubscribe(sbe_client, "btcusdt@bestBidAsk")

# ============================================================================
# Example 3: Subscribe to Incremental Order Book Updates
# ============================================================================

# Define depth diff callback function
function handle_depth_diff(depth_diff_event::DepthDiffEvent)
    println("\nOrder Book Incremental Update:")
    println("  Symbol: $(depth_diff_event.symbol)")
    println("  First Update ID: $(depth_diff_event.firstBookUpdateId)")
    println("  Last Update ID: $(depth_diff_event.lastBookUpdateId)")
    println("  Event Time: $(unix2datetime(depth_diff_event.eventTime / 1_000_000))")
    println("  Bid Updates: $(length(depth_diff_event.bids)) levels")
    println("  Ask Updates: $(length(depth_diff_event.asks)) levels")

    if !isempty(depth_diff_event.bids)
        println("  Top 3 Bid Updates:")
        for (i, bid) in enumerate(depth_diff_event.bids[1:min(3, end)])
            println("    $i. $(bid.price) @ $(bid.qty)")
        end
    end

    if !isempty(depth_diff_event.asks)
        println("  Top 3 Ask Updates:")
        for (i, ask) in enumerate(depth_diff_event.asks[1:min(3, end)])
            println("    $i. $(ask.price) @ $(ask.qty)")
        end
    end
end

sbe_subscribe_depth(sbe_client, "BTCUSDT", handle_depth_diff)

# Unsubscribe
sbe_unsubscribe(sbe_client, "btcusdt@depth")

# ============================================================================
# Example 4: Subscribe to Top 20 Levels Snapshot
# ============================================================================

# Define depth snapshot callback function
function handle_depth_snapshot(depth_snapshot_event::DepthSnapshotEvent)
    println("\nOrder Book Snapshot:")
    println("  Symbol: $(depth_snapshot_event.symbol)")
    println("  Update ID: $(depth_snapshot_event.bookUpdateId)")
    println("  Event Time: $(unix2datetime(depth_snapshot_event.eventTime / 1_000_000))")
    println("  Bid Levels: $(length(depth_snapshot_event.bids))")
    println("  Ask Levels: $(length(depth_snapshot_event.asks))")

    # Show top 5 levels
    println("\n  Top 5 Bids:")
    for (i, bid) in enumerate(depth_snapshot_event.bids[1:min(5, end)])
        println("    $i. $(bid.price) @ $(bid.qty)")
    end

    println("\n  Top 5 Asks:")
    for (i, ask) in enumerate(depth_snapshot_event.asks[1:min(5, end)])
        println("    $i. $(ask.price) @ $(ask.qty)")
    end

    # Calculate spread
    if !isempty(depth_snapshot_event.bids) && !isempty(depth_snapshot_event.asks)
        best_bid = depth_snapshot_event.bids[1].price
        best_ask = depth_snapshot_event.asks[1].price
        spread = best_ask - best_bid
        println("\n  Spread: $spread ($(round(spread/best_bid * 100, digits=4))%)")
    end
end

sbe_subscribe_depth20(sbe_client, "BTCUSDT", handle_depth_snapshot)

# Unsubscribe
sbe_unsubscribe(sbe_client, "btcusdt@depth20")

# ============================================================================
# Example 5: Multi-Symbol Subscription
# ============================================================================

# Define multi-symbol trade callback function
function handle_multi_symbol_trade(trade_event::TradeEvent)
    # Only show first trade
    if !isempty(trade_event.trades)
        trade = trade_event.trades[1]
        side = trade.isBuyerMaker ? "SELL" : "BUY"
        println("[$side $(trade_event.symbol)] $(trade.price) @ $(trade.qty)")
    end
end

symbols = ["ETHUSDT", "SOLUSDT"]

for symbol in symbols
    sbe_subscribe_trade(sbe_client, symbol, handle_multi_symbol_trade)
end

# Unsubscribe
for symbol in symbols
    sbe_unsubscribe(sbe_client, "$(lowercase(symbol))@trade")
end

# ============================================================================
# Run Monitor
# ============================================================================

println("Active subscriptions: $(join(sbe_list_streams(sbe_client), ", "))")

try
    # Keep running
    while true
        sleep(10)

        # Show active stream count
        active_count = length(sbe_list_streams(sbe_client))
        println("[$(Dates.format(now(), "HH:MM:SS"))] Active SBE streams: $active_count")
    end
catch e
    if isa(e, InterruptException)
        println("\nInterrupt signal received...")
    else
        rethrow(e)
    end
finally
    # Cleanup resources
    println("\nCleaning up SBE connections...")
    sbe_close_all(sbe_client)
    println("Done")
end
