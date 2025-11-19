# OrderBookManager - Local Order Book Management

Complete guide for using OrderBookManager to maintain a high-performance local order book.

## Overview

**OrderBookManager** maintains a continuously-synchronized local order book with near-zero latency access. Perfect for:

- **High-frequency trading**: Access order book in < 1ms (vs 20-100ms API calls)
- **Market making**: Monitor depth without API rate limits
- **Arbitrage**: Compare prices across markets with minimal latency
- **Deep analysis**: Access up to 5000 price levels in real-time

## Performance Comparison

| Method | Data | Latency | API Usage | Use Case |
|--------|------|---------|-----------|----------|
| Ticker stream | Latest price | ~10-50ms | None | Simple price triggers |
| Depth stream | 5-20 levels | ~20-100ms | None | Basic order book |
| **OrderBookManager** | **Up to 5000 levels** | **< 1ms** | **None** | **HFT, deep analysis** |

## Quick Start

```julia
using Binance

# Initialize clients
rest_client = RESTClient("config.toml")
stream_client = MarketDataStreamClient("config.toml")

# Create OrderBookManager
orderbook = OrderBookManager("BTCUSDT", rest_client, stream_client;
                              max_depth=5000,        # Up to 5000 levels
                              update_speed="100ms")  # Fast updates

# Start synchronization
start!(orderbook)

# Wait for initialization
while !is_ready(orderbook)
    sleep(0.5)
end

# Access order book with < 1ms latency
best_bid = get_best_bid(orderbook)  # (price=96443.52, quantity=0.5)
best_ask = get_best_ask(orderbook)  # (price=96443.53, quantity=0.3)
spread = get_spread(orderbook)       # 0.01

# Cleanup
stop!(orderbook)
```

## API Reference

### Creation & Lifecycle

#### `OrderBookManager(symbol, rest_client, stream_client; kwargs...)`

Create a new order book manager.

**Parameters:**
- `symbol::String` - Trading pair (e.g., "BTCUSDT")
- `rest_client::RESTClient` - REST API client for snapshots
- `stream_client::MarketDataStreamClient` - WebSocket client for updates
- `max_depth::Int=5000` - Maximum depth to maintain (100-5000)
- `update_speed::String="100ms"` - Update frequency ("100ms" or "1000ms")
- `on_update::Function=nothing` - Callback for each update

**Example:**
```julia
orderbook = OrderBookManager("BTCUSDT", rest_client, stream_client;
                              max_depth=1000,
                              update_speed="100ms",
                              on_update=my_callback)
```

#### `start!(manager)`

Start order book synchronization.

**Process:**
1. Subscribe to WebSocket diff depth stream
2. Buffer incoming events
3. Fetch REST snapshot
4. Validate and apply buffered events
5. Begin real-time updates

**Example:**
```julia
start!(orderbook)
```

#### `stop!(manager)`

Stop synchronization and cleanup resources.

**Example:**
```julia
stop!(orderbook)
```

#### `is_ready(manager) -> Bool`

Check if order book is initialized and ready.

**Returns:** `true` if synchronized and ready

**Example:**
```julia
if is_ready(orderbook)
    println("Order book ready!")
end
```

### Query Methods

#### `get_best_bid(manager) -> Union{PriceQuantity, Nothing}`

Get the best (highest) bid price.

**Returns:** `PriceQuantity(price, quantity)` or `nothing` if empty

**Example:**
```julia
best_bid = get_best_bid(orderbook)
println("Best bid: $(best_bid.price) @ $(best_bid.quantity)")
```

#### `get_best_ask(manager) -> Union{PriceQuantity, Nothing}`

Get the best (lowest) ask price.

**Returns:** `PriceQuantity(price, quantity)` or `nothing` if empty

**Example:**
```julia
best_ask = get_best_ask(orderbook)
println("Best ask: $(best_ask.price) @ $(best_ask.quantity)")
```

#### `get_spread(manager) -> Union{Float64, Nothing}`

Get bid-ask spread.

**Returns:** Spread (ask - bid) or `nothing` if incomplete

**Example:**
```julia
spread = get_spread(orderbook)
println("Spread: $spread")
```

#### `get_mid_price(manager) -> Union{Float64, Nothing}`

Get mid price (average of best bid and ask).

**Returns:** Mid price or `nothing` if incomplete

**Example:**
```julia
mid = get_mid_price(orderbook)
println("Mid price: $mid")
```

#### `get_bids(manager, n=10) -> Vector{PriceQuantity}`

Get top N bid levels, sorted by price (highest first).

**Parameters:**
- `n::Int=10` - Number of levels to return

**Returns:** Vector of `PriceQuantity` (highest to lowest)

**Example:**
```julia
top_10_bids = get_bids(orderbook, 10)
for (i, bid) in enumerate(top_10_bids)
    println("$i. $(bid.price) @ $(bid.quantity)")
end
```

#### `get_asks(manager, n=10) -> Vector{PriceQuantity}`

Get top N ask levels, sorted by price (lowest first).

**Parameters:**
- `n::Int=10` - Number of levels to return

**Returns:** Vector of `PriceQuantity` (lowest to highest)

**Example:**
```julia
top_10_asks = get_asks(orderbook, 10)
for (i, ask) in enumerate(top_10_asks)
    println("$i. $(ask.price) @ $(ask.quantity)")
end
```

#### `get_orderbook_snapshot(manager; max_levels=100) -> OrderBookSnapshot`

Get immutable snapshot of current state.

**Parameters:**
- `max_levels::Int=100` - Maximum levels per side

**Returns:** `OrderBookSnapshot` with bids, asks, timestamp

**Example:**
```julia
snapshot = get_orderbook_snapshot(orderbook; max_levels=50)
println("Snapshot at: $(snapshot.timestamp)")
println("Bids: $(length(snapshot.bids))")
println("Asks: $(length(snapshot.asks))")
```

### Analysis Methods

#### `calculate_vwap(manager, size, side) -> Union{NamedTuple, Nothing}`

Calculate Volume-Weighted Average Price for an order.

**Parameters:**
- `size::Float64` - Order size (in base currency)
- `side::Symbol` - `:buy` or `:sell`

**Returns:** `(vwap, total_cost, filled_size)` or `nothing` if insufficient liquidity

**Example:**
```julia
# Buy 1.0 BTC
result = calculate_vwap(orderbook, 1.0, :buy)
if !isnothing(result)
    println("VWAP: $(result.vwap)")
    println("Total cost: $(result.total_cost)")
    println("Filled: $(result.filled_size) BTC")
end

# Sell 0.5 BTC
result = calculate_vwap(orderbook, 0.5, :sell)
```

#### `calculate_depth_imbalance(manager; levels=5) -> Union{Float64, Nothing}`

Calculate order book imbalance (-1.0 to 1.0).

**Parameters:**
- `levels::Int=5` - Number of top levels to analyze

**Returns:**
- Positive value = more buy pressure (bids > asks)
- Negative value = more sell pressure (asks > bids)
- `nothing` if incomplete data

**Formula:** `(bid_volume - ask_volume) / (bid_volume + ask_volume)`

**Example:**
```julia
imbalance = calculate_depth_imbalance(orderbook; levels=20)
if !isnothing(imbalance)
    if imbalance > 0.3
        println("Strong buy pressure: $imbalance")
    elseif imbalance < -0.3
        println("Strong sell pressure: $imbalance")
    else
        println("Balanced: $imbalance")
    end
end
```

## Trading Strategy Example

```julia
using Binance

rest_client = RESTClient("config.toml")
stream_client = MarketDataStreamClient("config.toml")

# Define strategy callback
function trading_strategy(manager)
    best_bid = get_best_bid(manager)
    best_ask = get_best_ask(manager)
    imbalance = calculate_depth_imbalance(manager; levels=20)

    if isnothing(best_bid) || isnothing(best_ask) || isnothing(imbalance)
        return
    end

    # Strategy logic
    if imbalance > 0.3
        println("[BUY SIGNAL] Strong buying pressure: $imbalance")
        println("  Bid: $(best_bid.price) @ $(best_bid.quantity)")
        # Place buy order here

    elseif imbalance < -0.3
        println("[SELL SIGNAL] Strong selling pressure: $imbalance")
        println("  Ask: $(best_ask.price) @ $(best_ask.quantity)")
        # Place sell order here
    end
end

# Create manager with callback
orderbook = OrderBookManager("BTCUSDT", rest_client, stream_client;
                              max_depth=5000,
                              on_update=trading_strategy)

start!(orderbook)

# Wait for initialization
while !is_ready(orderbook)
    sleep(0.5)
end

println("Strategy running... Press Ctrl+C to stop")

try
    while true
        sleep(1)
    end
catch e
    if isa(e, InterruptException)
        println("\nStopping strategy...")
    else
        rethrow(e)
    end
finally
    stop!(orderbook)
end
```

## Implementation Details

OrderBookManager follows Binance's **corrected guidelines (2025-11-12)**:

1. ✅ Subscribe to WebSocket diff depth stream
2. ✅ Buffer incoming events
3. ✅ Fetch REST snapshot
4. ✅ Validate snapshot freshness
5. ✅ Discard outdated events
6. ✅ Verify event continuity
7. ✅ Apply buffered events
8. ✅ Process real-time updates
9. ✅ Auto-recovery on errors

### Thread Safety

All methods are thread-safe using `ReentrantLock`:
```julia
# Safe concurrent access
@async begin
    while true
        best_bid = get_best_bid(orderbook)
        sleep(0.1)
    end
end

@async begin
    while true
        imbalance = calculate_depth_imbalance(orderbook)
        sleep(0.5)
    end
end
```

## Examples

See complete examples:
- `examples/orderbook_basic.jl` - Basic usage
- `examples/orderbook_advanced.jl` - Advanced features with callbacks

## Troubleshooting

### Issue: Order book not ready after 30 seconds

**Cause:** Network issues or WebSocket connection problems

**Solution:**
```julia
# Check WebSocket connection
println("Stream client connections: ", length(stream_client.ws_connections))

# Restart with debug
ENV["JULIA_DEBUG"] = "Main"
start!(orderbook)
```

### Issue: Incorrect best bid/ask prices

**Cause:** Bug fixed in v0.5.0 - now correctly uses max/min

**Solution:** Update to v0.5.0 or later

### Issue: High memory usage

**Cause:** Large `max_depth` value

**Solution:** Reduce `max_depth` if not needed
```julia
# For most strategies, 1000 levels is sufficient
orderbook = OrderBookManager("BTCUSDT", rest_client, stream_client;
                              max_depth=1000)
```

## Best Practices

1. **Always check `is_ready()` before querying**
   ```julia
   if is_ready(orderbook)
       best_bid = get_best_bid(orderbook)
   end
   ```

2. **Handle `nothing` returns gracefully**
   ```julia
   best_bid = get_best_bid(orderbook)
   if !isnothing(best_bid)
       # Use best_bid.price
   end
   ```

3. **Use appropriate `max_depth` for your needs**
   - HFT: 100-500 levels
   - Market making: 500-1000 levels
   - Deep analysis: 1000-5000 levels

4. **Always cleanup with `stop!()`**
   ```julia
   try
       # Your code
   finally
       stop!(orderbook)
   end
   ```

## Performance Tips

1. **Minimize callback complexity** - Keep `on_update` fast
2. **Batch operations** - Don't query on every update
3. **Use snapshots** for analysis - Avoid repeated queries
4. **Choose appropriate update_speed** - "1000ms" for less frequent strategies

## Reference

- [Binance Order Book Documentation](https://binance-docs.github.io/apidocs/spot/en/#how-to-manage-a-local-order-book-correctly)
- [Implementation Guidelines (2025-11-12)](https://binance-docs.github.io/apidocs/spot/en/#diff-depth-stream)
