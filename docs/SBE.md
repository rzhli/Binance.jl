# SBE Market Data Streams

Complete guide for using Binance's Simple Binary Encoding (SBE) market data streams - the most efficient way to consume real-time market data.

## Overview

**SBE (Simple Binary Encoding)** provides binary-encoded market data with significantly reduced bandwidth and latency compared to JSON streams.

### Performance Comparison

| Metric | JSON Streams | SBE Streams | Improvement |
|--------|--------------|-------------|-------------|
| **Bandwidth** | 100% | 30-40% | 60-70% reduction |
| **Parsing Speed** | Baseline | 2-3x faster | Direct memory access |
| **CPU Usage** | Baseline | 40-50% lower | Binary format |
| **Latency** | Baseline | 30-50% lower | No JSON parsing |

## Quick Start

```julia
using Binance

# Create SBE client (requires Ed25519 API Key)
sbe_client = SBEStreamClient("config.toml")

# Connect to SBE endpoint
connect_sbe!(sbe_client)

# Subscribe to real-time trades
sbe_subscribe_trade(sbe_client, "BTCUSDT", trade_event -> begin
    println("Symbol: $(trade_event.symbol)")
    for trade in trade_event.trades
        println("  $(trade.price) @ $(trade.qty)")
    end
end)

# Keep running
try
    while true
        sleep(1)
    end
finally
    sbe_close_all(sbe_client)
end
```

## Supported Streams

| Stream | Message Type | Update Rate | Description |
|--------|-------------|-------------|-------------|
| `<symbol>@trade` | TradesStreamEvent | Real-time | Live trade data |
| `<symbol>@bestBidAsk` | BestBidAskStreamEvent | Real-time | Best bid/ask (auto-culling) |
| `<symbol>@depth` | DepthDiffStreamEvent | 50ms | Incremental order book |
| `<symbol>@depth20` | DepthSnapshotStreamEvent | 50ms | Top 20 levels snapshot |

## Data Structures

### TradeEvent

Real-time trade execution data.

```julia
struct TradeEvent
    eventTime::Int64           # Event time (microseconds)
    transactTime::Int64        # Transaction time (microseconds)
    symbol::String             # Trading pair
    trades::Vector{TradeData}  # One or more trades
end

struct TradeData
    id::Int64                  # Trade ID
    price::Float64             # Execution price
    qty::Float64               # Quantity
    isBuyerMaker::Bool         # Buyer is maker?
    isBestMatch::Bool          # Best price match?
end
```

**Example:**
```julia
sbe_subscribe_trade(sbe_client, "BTCUSDT", event -> begin
    for trade in event.trades
        side = trade.isBuyerMaker ? "SELL" : "BUY"
        println("$side $(trade.price) @ $(trade.qty)")
    end
end)
```

### BestBidAskEvent

Best bid and ask prices with auto-culling support.

```julia
struct BestBidAskEvent
    eventTime::Int64       # Event time (microseconds)
    bookUpdateId::Int64    # Order book update ID
    symbol::String         # Trading pair
    bidPrice::Float64      # Best bid price
    bidQty::Float64        # Best bid quantity
    askPrice::Float64      # Best ask price
    askQty::Float64        # Best ask quantity
end
```

**Auto-culling**: Under high load, outdated events may be dropped to reduce latency.

**Example:**
```julia
sbe_subscribe_best_bid_ask(sbe_client, "BTCUSDT", event -> begin
    spread = event.askPrice - event.bidPrice
    spread_bps = (spread / event.bidPrice) * 10000
    println("Spread: $spread ($(round(spread_bps, digits=2)) bps)")
end)
```

### DepthSnapshotEvent

Top 20 levels order book snapshot.

```julia
struct DepthSnapshotEvent
    eventTime::Int64               # Event time (microseconds)
    bookUpdateId::Int64            # Update ID
    symbol::String                 # Trading pair
    bids::Vector{PriceLevel}       # Up to 20 bid levels
    asks::Vector{PriceLevel}       # Up to 20 ask levels
end

struct PriceLevel
    price::Float64
    qty::Float64
end
```

**Example:**
```julia
sbe_subscribe_depth20(sbe_client, "BTCUSDT", event -> begin
    println("Top 5 bids:")
    for (i, bid) in enumerate(event.bids[1:min(5, end)])
        println("  $i. $(bid.price) @ $(bid.qty)")
    end
end)
```

### DepthDiffEvent

Incremental order book updates (50ms).

```julia
struct DepthDiffEvent
    eventTime::Int64               # Event time (microseconds)
    firstBookUpdateId::Int64       # First update ID in event
    lastBookUpdateId::Int64        # Last update ID in event
    symbol::String                 # Trading pair
    bids::Vector{PriceLevel}       # Changed bid levels
    asks::Vector{PriceLevel}       # Changed ask levels
end
```

**Note**: Quantity of 0 means the price level was removed.

**Example:**
```julia
sbe_subscribe_depth(sbe_client, "BTCUSDT", event -> begin
    println("Update: $(event.firstBookUpdateId) → $(event.lastBookUpdateId)")

    # Process bid changes
    for bid in event.bids
        if bid.qty == 0.0
            println("  Removed bid: $(bid.price)")
        else
            println("  Updated bid: $(bid.price) @ $(bid.qty)")
        end
    end
end)
```

## API Reference

### Connection Management

#### `SBEStreamClient(config_path="config.toml")`

Create SBE stream client.

**Requirements:**
- Ed25519 API Key
- No special permissions needed (public data)
- Connection valid for 24 hours

**Example:**
```julia
sbe_client = SBEStreamClient("config.toml")
```

#### `connect_sbe!(client)`

Establish WebSocket connection with API key authentication.

**Example:**
```julia
connect_sbe!(sbe_client)

# Wait for connection
sleep(2)
```

### Subscriptions

#### `sbe_subscribe_trade(client, symbol, callback)`

Subscribe to real-time trade stream.

**Parameters:**
- `symbol::String` - Trading pair (e.g., "BTCUSDT")
- `callback::Function` - Function receiving `TradeEvent`

**Stream:** `<symbol>@trade`

**Example:**
```julia
sbe_subscribe_trade(sbe_client, "BTCUSDT", trade_event -> begin
    println("$(length(trade_event.trades)) trades at $(trade_event.eventTime)")
end)
```

#### `sbe_subscribe_best_bid_ask(client, symbol, callback)`

Subscribe to best bid/ask stream with auto-culling.

**Parameters:**
- `symbol::String` - Trading pair
- `callback::Function` - Function receiving `BestBidAskEvent`

**Stream:** `<symbol>@bestBidAsk`

**Example:**
```julia
sbe_subscribe_best_bid_ask(sbe_client, "BTCUSDT", event -> begin
    println("Bid: $(event.bidPrice), Ask: $(event.askPrice)")
end)
```

#### `sbe_subscribe_depth(client, symbol, callback)`

Subscribe to incremental order book updates (50ms).

**Parameters:**
- `symbol::String` - Trading pair
- `callback::Function` - Function receiving `DepthDiffEvent`

**Stream:** `<symbol>@depth`

**Example:**
```julia
sbe_subscribe_depth(sbe_client, "BTCUSDT", event -> begin
    println("$(length(event.bids)) bid updates, $(length(event.asks)) ask updates")
end)
```

#### `sbe_subscribe_depth20(client, symbol, callback)`

Subscribe to top 20 levels snapshot (50ms).

**Parameters:**
- `symbol::String` - Trading pair
- `callback::Function` - Function receiving `DepthSnapshotEvent`

**Stream:** `<symbol>@depth20`

**Example:**
```julia
sbe_subscribe_depth20(sbe_client, "BTCUSDT", event -> begin
    println("Snapshot: $(length(event.bids)) bids, $(length(event.asks)) asks")
end)
```

#### `sbe_unsubscribe_trade(client, symbol)`

Unsubscribe from real-time trade stream.

**Parameters:**
- `symbol::String` - Trading pair (e.g., "BTCUSDT")

**Example:**
```julia
sbe_unsubscribe_trade(sbe_client, "BTCUSDT")
```

#### `sbe_unsubscribe_best_bid_ask(client, symbol)`

Unsubscribe from best bid/ask stream.

**Parameters:**
- `symbol::String` - Trading pair

**Example:**
```julia
sbe_unsubscribe_best_bid_ask(sbe_client, "BTCUSDT")
```

#### `sbe_unsubscribe_depth(client, symbol)`

Unsubscribe from incremental order book updates.

**Parameters:**
- `symbol::String` - Trading pair

**Example:**
```julia
sbe_unsubscribe_depth(sbe_client, "BTCUSDT")
```

#### `sbe_unsubscribe_depth20(client, symbol)`

Unsubscribe from partial order book snapshots.

**Parameters:**
- `symbol::String` - Trading pair

**Example:**
```julia
sbe_unsubscribe_depth20(sbe_client, "BTCUSDT")
```

#### `sbe_subscribe_combined(client, streams, callback)`

Subscribe to multiple streams with one callback.

**Parameters:**
- `streams::Vector{String}` - Stream names
- `callback::Function` - Unified callback

**Example:**
```julia
streams = ["btcusdt@trade", "ethusdt@trade", "solusdt@trade"]
sbe_subscribe_combined(sbe_client, streams, event -> begin
    println("Event from: $(event.symbol)")
end)
```

### Management

#### `sbe_list_streams(client) -> Vector{String}`

List all active subscriptions.

**Example:**
```julia
streams = sbe_list_streams(sbe_client)
println("Active: $(join(streams, ", "))")
```

#### `sbe_unsubscribe(client, stream_name)`

Cancel specific subscription.

**Parameters:**
- `stream_name::String` - Stream to unsubscribe

**Example:**
```julia
sbe_unsubscribe(sbe_client, "btcusdt@trade")
```

#### `sbe_close_all(client)`

Close all subscriptions and disconnect.

**Example:**
```julia
try
    # Your code
finally
    sbe_close_all(sbe_client)
end
```

## When to Use SBE

### ✅ Recommended For

- **High-frequency trading** - Minimum latency required
- **Cross-exchange arbitrage** - Every millisecond counts
- **Massive subscriptions** - 10+ symbols simultaneously
- **Bandwidth constraints** - Limited network capacity
- **CPU optimization** - Reduce parsing overhead

### ⚪ JSON Sufficient For

- Regular trading strategies
- Low-frequency monitoring (> 1 second intervals)
- Learning and development
- Single symbol monitoring

## Requirements

### API Key

SBE streams require **Ed25519 API keys** for authentication.

**Generate Ed25519 key:**
```bash
# Generate private key
openssl genpkey -algorithm ed25519 -out ed25519-private.pem

# Extract public key
openssl pkey -in ed25519-private.pem -pubout -out ed25519-public.pem

# Get public key text for Binance
cat ed25519-public.pem
```

Then add the public key to your Binance API key settings.

### Configuration

```toml
[api]
api_key = "YOUR_API_KEY"
signature_method = "ED25519"
private_key_path = "key/ed25519-private.pem"
private_key_pass = "your_password"

[connection]
proxy = "http://127.0.0.1:7890"  # Optional
```

### Network

- **Connection validity**: 24 hours (auto-reconnects)
- **Ping/Pong**: Server sends ping every 20s, client must respond within 60s
- **Rate limits**: 5 requests/second, 300 connections per 5 minutes
- **Max streams**: 1024 per connection

## Advanced Usage

### Multi-Symbol Strategy

```julia
using Binance

sbe_client = SBEStreamClient()
connect_sbe!(sbe_client)

# Track multiple symbols
symbols = ["BTCUSDT", "ETHUSDT", "SOLUSDT", "BNBUSDT"]

for symbol in symbols
    sbe_subscribe_best_bid_ask(sbe_client, symbol, event -> begin
        spread = event.askPrice - event.bidPrice
        spread_pct = (spread / event.bidPrice) * 100

        # Alert on wide spreads
        if spread_pct > 0.1
            println("[$(event.symbol)] Wide spread: $(round(spread_pct, digits=4))%")
        end
    end)
end

println("Monitoring $(length(symbols)) symbols...")
```

### Arbitrage Detection

```julia
using Binance

sbe_client = SBEStreamClient()
connect_sbe!(sbe_client)

# Track prices
prices = Dict{String, Float64}()

for symbol in ["BTCUSDT", "ETHUSDT"]
    sbe_subscribe_best_bid_ask(sbe_client, symbol, event -> begin
        mid = (event.bidPrice + event.askPrice) / 2
        prices[event.symbol] = mid

        # Check for arbitrage opportunities
        if haskey(prices, "BTCUSDT") && haskey(prices, "ETHUSDT")
            ratio = prices["BTCUSDT"] / prices["ETHUSDT"]
            println("BTC/ETH ratio: $(round(ratio, digits=2))")
        end
    end)
end
```

## Technical Details

### SBE Message Format

#### Message Header (8 bytes)
```
[blockLength:2][templateId:2][schemaId:2][version:2]
```

#### Template IDs
- `10000` - TradesStreamEvent
- `10001` - BestBidAskStreamEvent
- `10002` - DepthSnapshotStreamEvent
- `10003` - DepthDiffStreamEvent

#### Decimal Encoding

Prices and quantities use mantissa/exponent encoding:

**Formula:** `value = mantissa × 10^exponent`

**Example:**
- mantissa = 9553554, exponent = -2
- value = 9553554 × 10^(-2) = 95535.54

### Binary vs JSON Example

**JSON (87 bytes):**
```json
{"e":"trade","E":1234567890,"s":"BTCUSDT","t":12345,"p":"95535.54","q":"0.001","b":123,"a":456,"T":1234567890,"m":true,"M":true}
```

**SBE (32 bytes):**
```
[header:8][eventTime:8][transactTime:8][exponent:1][id:8][price:8][qty:8][flags:1][symbol:4]
```

**Savings:** 63% smaller, no parsing overhead

## Troubleshooting

### Connection fails with "authentication required"

**Cause:** Missing or invalid Ed25519 API key

**Solution:**
1. Verify `signature_method = "ED25519"` in config
2. Check API key has Ed25519 public key added
3. Verify private key path is correct

### Data seems delayed or missing

**Cause:** Auto-culling under high load (bestBidAsk stream)

**Solution:** This is expected behavior - outdated events are dropped to maintain low latency

### Connection drops after 24 hours

**Cause:** Maximum connection validity

**Solution:** SDK auto-reconnects - no action needed

### "Too many requests" error

**Cause:** Exceeded 5 requests/second rate limit

**Solution:** Reduce subscription/unsubscription frequency

## Best Practices

1. **Reuse client for multiple symbols**
   ```julia
   # Good
   for symbol in symbols
       sbe_subscribe_trade(sbe_client, symbol, callback)
   end

   # Bad - creates multiple connections
   for symbol in symbols
       client = SBEStreamClient()
       sbe_subscribe_trade(client, symbol, callback)
   end
   ```

2. **Handle binary data errors gracefully**
   ```julia
   sbe_subscribe_trade(sbe_client, "BTCUSDT", event -> begin
       try
           # Process event
       catch e
           @error "Processing error: $e"
       end
   end)
   ```

3. **Monitor connection health**
   ```julia
   @async begin
       while true
           streams = sbe_list_streams(sbe_client)
           println("$(length(streams)) active streams")
           sleep(60)
       end
   end
   ```

4. **Cleanup on exit**
   ```julia
   try
       # Your strategy
   finally
       sbe_close_all(sbe_client)
   end
   ```

## Examples

Complete examples in `examples/sbe_stream_example.jl`:
- Basic trade subscription
- Best bid/ask monitoring
- Order book updates
- Multi-symbol strategies

## References

- [Binance SBE Documentation](https://binance-docs.github.io/apidocs/spot/en/#sbe-market-data-streams)
- [SBE Schema XML](https://github.com/binance/binance-spot-api-docs/blob/master/sbe/schemas/spot_sbe.xml)
- [Simple Binary Encoding Spec](https://github.com/real-logic/simple-binary-encoding)
