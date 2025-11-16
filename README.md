# Binance.jl - Julia SDK for Binance API

A comprehensive Julia SDK for interacting with Binance's Spot Trading APIs, including REST API, WebSocket Market Data Streams, and WebSocket API for real-time trading.

## Recent Updates

### v0.5.0 - OrderBookManager Module (2025-11-16)

Added complete local order book management with automatic synchronization from Binance WebSocket streams.

#### New Feature: OrderBookManager ⭐

**OrderBookManager** provides a powerful way to maintain a local, continuously-synchronized order book with near-zero latency access. This is ideal for:

- **High-frequency trading strategies**: Access order book data in < 1ms (vs 20-100ms for REST/WebSocket calls)
- **Market making**: Monitor best bid/ask and depth continuously without API rate limits
- **Arbitrage**: Compare prices across markets with minimal latency
- **Deep market analysis**: Access up to 5000 price levels with real-time updates

**Why use OrderBookManager instead of ticker/depth streams?**

| Method | Data | Latency | API Consumption | Use Case |
|--------|------|---------|----------------|----------|
| Ticker stream | Latest price only | ~10-50ms | None (WebSocket) | Simple price triggers |
| Depth stream | 5-20 level snapshots | ~20-100ms | None (WebSocket) | Basic order book access |
| **OrderBookManager** ⭐ | **Up to 5000 levels** | **< 1ms** | **None** | **HFT, market making, deep analysis** |

#### Key Features

- ✅ **Automatic Synchronization**: Implements Binance's corrected algorithm (2025-11-12) for maintaining local order books
- ✅ **Near-Zero Latency**: Local order book access in < 1ms vs 20-100ms for REST/WebSocket calls
- ✅ **Complete Depth**: Support for up to 5000 price levels (vs 20 levels in depth stream)
- ✅ **Real-time Updates**: WebSocket diff depth stream with automatic event buffering
- ✅ **Thread-Safe**: Safe concurrent access to order book data
- ✅ **Advanced Analytics**: Built-in VWAP calculation and depth imbalance analysis
- ✅ **Custom Callbacks**: React to order book changes in real-time
- ✅ **Auto-Recovery**: Automatic reconnection and resynchronization on errors

#### Quick Start

```julia
using Binance

# Initialize clients
rest_client = RESTClient("config.toml")
ws_client = MarketDataStreamClient("config.toml")

# Create and start order book manager
orderbook = OrderBookManager("BTCUSDT", rest_client, ws_client;
                              max_depth=5000,        # Up to 5000 levels
                              update_speed="100ms")  # Fast updates

start!(orderbook)

# Wait for initialization
while !is_ready(orderbook)
    sleep(0.5)
end

# Access order book with < 1ms latency
best_bid = get_best_bid(orderbook)  # (price=96443.52, quantity=0.5)
best_ask = get_best_ask(orderbook)  # (price=96443.53, quantity=0.3)
spread = get_spread(orderbook)       # 0.01

# Get top N levels
top_10_bids = get_bids(orderbook, 10)  # Vector of PriceQuantity
top_10_asks = get_asks(orderbook, 10)

# Advanced analysis
vwap_result = calculate_vwap(orderbook, 1.0, :buy)  # Buy 1 BTC at VWAP
# Returns: (vwap=96445.12, total_cost=96445.12)

imbalance = calculate_depth_imbalance(orderbook; levels=20)
# Returns: 0.345 (positive = more bids, negative = more asks)

# Cleanup when done
stop!(orderbook)
```

#### Real-time Trading Strategy Example

```julia
# Define custom callback for real-time updates
function on_update(manager)
    best_bid = get_best_bid(manager)
    best_ask = get_best_ask(manager)
    imbalance = calculate_depth_imbalance(manager; levels=20)

    # Your trading logic here
    if imbalance > 0.3
        println("Strong buying pressure detected!")
    elseif imbalance < -0.3
        println("Strong selling pressure detected!")
    end
end

# Create with callback
orderbook = OrderBookManager("BTCUSDT", rest_client, ws_client;
                              on_update=on_update)
start!(orderbook)

# OrderBookManager will call your callback on every update
# Your strategy runs in real-time with < 1ms latency
```

#### API Reference

**Core Methods:**
- `OrderBookManager(symbol, rest_client, ws_client; max_depth=5000, update_speed="100ms", on_update=nothing)` - Create manager
- `start!(manager)` - Start synchronization
- `stop!(manager)` - Stop and cleanup
- `is_ready(manager)` - Check if initialized

**Query Methods:**
- `get_best_bid(manager)` - Best (highest) bid price and quantity
- `get_best_ask(manager)` - Best (lowest) ask price and quantity
- `get_spread(manager)` - Bid-ask spread
- `get_mid_price(manager)` - Mid price (average of best bid/ask)
- `get_bids(manager, n)` - Top N bid levels (sorted)
- `get_asks(manager, n)` - Top N ask levels (sorted)
- `get_orderbook_snapshot(manager; max_levels=100)` - Immutable snapshot

**Analysis Methods:**
- `calculate_vwap(manager, size, side)` - Volume-weighted average price for order size
- `calculate_depth_imbalance(manager; levels=5)` - Order book imbalance (-1.0 to 1.0)

#### Examples

See `examples/orderbook_basic.jl` and `examples/orderbook_advanced.jl` for complete examples.

#### Implementation Details

OrderBookManager follows Binance's **corrected guidelines (2025-11-12)** for managing local order books:

1. Subscribe to WebSocket diff depth stream (`@depth@100ms` or `@depth`)
2. Buffer incoming depth update events
3. Fetch REST API depth snapshot (`GET /api/v3/depth?limit=5000`)
4. Validate snapshot is fresh (lastUpdateId >= first buffered event's U)
5. Discard outdated buffered events (where u <= snapshot's lastUpdateId)
6. Verify first remaining event's [U, u] range contains snapshot's lastUpdateId
7. Apply all valid buffered events to complete initial sync
8. Process continuous differential updates from WebSocket stream
9. Automatic error detection and resynchronization on missed events

#### Bug Fixes in v0.5.0

- **Critical**: Fixed price sorting bug in `get_best_bid()` and `get_best_ask()`
  - Previously incorrectly assumed OrderedDict maintains sorted order
  - Now correctly uses `maximum()` and `minimum()` to find best prices
  - Also fixed sorting in `get_bids()`, `get_asks()`, `calculate_vwap()`, and `calculate_depth_imbalance()`

#### Deprecated in v0.5.0

- **`subscribe_all_tickers()`** - Uses Binance's deprecated `!ticker@arr` stream (deprecated 2025-11-14)
  - **Migration**: Use `subscribe_all_mini_tickers()` or individual `subscribe_ticker(symbol)` instead

---

### v0.4.4 - symbolStatus Parameter Support (2025-10-28)

Implemented the `symbolStatus` parameter across all relevant market data endpoints as per Binance's API CHANGELOG (2025-10-28).

#### New Parameter: `symbolStatus`
- **What it does**: Filters symbols by trading status (`"TRADING"`, `"HALT"`, `"BREAK"`)
- **Backward Compatible**: Optional parameter, defaults to no filtering
- **Error Handling**: Returns error `-1220` if single symbol doesn't match status; returns empty array if no symbols match

#### Updated REST API Endpoints
- `get_orderbook()` - Order book depth data
- `get_symbol_ticker()` - Symbol price ticker(s)
- `get_ticker_24hr()` - 24-hour ticker statistics
- `get_ticker_book()` - Best bid/ask prices
- `get_trading_day_ticker()` - Trading day ticker statistics
- `get_ticker()` - Rolling window ticker statistics

#### Updated WebSocket API Endpoints
- `depth()` - Order book depth data
- `ticker_price()` - Symbol price ticker(s)
- `ticker_book()` - Best bid/ask prices
- `ticker_24hr()` - 24-hour ticker statistics
- `ticker_trading_day()` - Trading day ticker statistics
- `ticker()` - Rolling window ticker statistics

#### Usage Example
```julia
# REST API - Get orderbook only for trading symbols
orderbook = get_orderbook(client, "BTCUSDT"; symbolStatus="TRADING")

# Get multiple tickers, filtering by status
tickers = get_symbol_ticker(client; symbols=["BTCUSDT", "ETHUSDT"], symbolStatus="TRADING")

# WebSocket API - Get price with status filter
price = ticker_price(ws_client; symbol="BTCUSDT", symbolStatus="TRADING")
```

See `test_symbolStatus.jl` for comprehensive examples.

### v0.4.3

#### Exact Decimal Precision Support
- **FixedPointDecimals.jl Integration**: Added exact decimal precision for order quantities and prices
- **DecimalPrice Type**: New type alias `FixedDecimal{Int64, 8}` for 8-decimal precision (cryptocurrency standard)
- **Flexible Input Types**: Order functions now accept `String`, `Float64`, or `FixedDecimal` for numeric parameters
- **Precision Guarantees**: Eliminates floating-point precision errors in trading operations

#### Bug Fixes
- **JSON3.Object Immutability**: Fixed `MethodError` when converting timestamps in API responses
- **Date Conversion**: All timestamp conversions now properly handle immutable JSON objects
- **Response Handling**: Functions returning datetime fields now correctly return mutable `Dict` objects

#### API Enhancements
- Updated `place_order()`, `cancel_order()`, and all order list functions
- Enhanced `get_ticker_24hr()`, `get_trading_day_ticker()`, `get_ticker()`, and `get_avg_price()`
- Comprehensive documentation for decimal precision usage

#### WebSocket Enhancements
- **eventStreamTerminated Support**: Added `EventStreamTerminated` struct and automatic handling so user data stream terminations are logged cleanly with timestamps.
- **Graceful Logging**: Default handler surfaces reconnection intent without spurious warnings.

#### Dependency Update
- Added `Crayons.jl` as a project dependency for terminal color output.

## Features

### Core Capabilities

- **REST API**: All Spot Account and Trading endpoints
- **WebSocket Market Data**: Real-time ticker, kline, depth, and trade data
- **Interactive WebSocket API**: Authenticated real-time trading operations with heartbeat
- **Session Management**: Secure connection handling with Ed25519, RSA, and HMAC signatures
- **Rate Limiting**: Built-in compliance with Binance API rate limits (REQUEST_WEIGHT, ORDERS, CONNECTIONS)
- **Error Handling**: Comprehensive error types and recovery mechanisms

### ✅ Currently Implemented

#### REST API Endpoints
- **General**: Ping, Server Time, Exchange Info
- **Market Data**: Order Book, Trades (Recent/Historical/Aggregate), Klines, Tickers, Prices
- **Spot Trading**: Orders (Place/Cancel/Status), OCO Orders, Account Info, Order History, Rate Limits
- **Strategy Helpers**: Real-time trade strategy helpers with colored order book display

#### WebSocket Market Streams
- **Real-time Data**: Tickers, Klines, Depth, Aggregate Trades
- **All Market Symbols**: Support for individual and array streams
- **Connection Management**: Auto-reconnect with heartbeat, ping/pong handling

#### OrderBookManager ⭐ New in v0.5.0
- **Local Order Book**: Continuously-synchronized local order book with automatic WebSocket + REST sync
- **Near-Zero Latency**: Access order book data in < 1ms (vs 20-100ms for REST/WebSocket)
- **Complete Depth**: Support for up to 5000 price levels
- **Advanced Analytics**: Built-in VWAP calculation and depth imbalance analysis
- **Auto-Recovery**: Automatic reconnection and resynchronization on errors

#### WebSocket API (100% Complete)
- **Session Management**: Logon, Status, Logout (no auth required for status/logout)
- **Trading Operations**: Place/Cancel/Modify orders with full validation, Order Lists (OCO/OTO/OTOCO)
- **Account Queries**: Balances, Orders, Execution Reports, Commission Rates, Prevented Matches
- **Smart Order Routing**: SOR orders for optimized execution
- **User Data Streams**: Real-time account updates with signature subscriptions

### 🔄 In Development
- Margin Account and Trading
- Sub-account Management
- Advanced SAPI Endpoints (Savings, Mining, BLVT, BSwap, Fiat, etc.)
- Full WebSocket User Data Event Parsing
- Enhanced Error Handling and Logging

## Installation

```julia
using Pkg
Pkg.add("https://github.com/rzhli/Binance.jl.git")
```

## Quick Start

### Configuration

1. Copy the example configuration file:

```bash
cp config_example.toml config.toml
```

2. Edit `config.toml` with your actual credentials:

```toml
[api]
# Required: Your Binance API credentials
api_key = "YOUR_API_KEY_HERE"
secret_key = "YOUR_SECRET_KEY_HERE"
signature_method = "ED25519"
private_key_path = "key/ed25519-private.pem"
private_key_pass = "YOUR_PRIVATE_KEY_PASS_HERE"

[connection]
testnet = false
timeout = 30
recv_window = 5000
proxy = "http://127.0.0.1:7890"

[rate_limiting]
max_requests_per_minute = 1200
max_orders_per_second = 10

[logging]
debug = false
log_file = ""
```

### Basic Usage

```julia
using Binance

# REST Client for spot trading
rest_client = RESTClient("config.toml")

# Get server time
time = get_server_time(rest_client)

# Get exchange info
exchange_info = get_exchange_info(rest_client)

# Get account info
account_info = get_account_info(rest_client)

# Place a market order with exact decimal precision
# You can use String for exact decimal values
order_result = place_order(
    rest_client,
    "BTCUSDT",
    "BUY",
    "MARKET";
    quantity = "0.001"  # String ensures exact precision
)

# Or use DecimalPrice (FixedDecimal{Int64,8}) for guaranteed exact decimals
order_result = place_order(
    rest_client,
    "BTCUSDT",
    "BUY",
    "LIMIT";
    quantity = DecimalPrice("0.001"),
    price = DecimalPrice("60000.0"),
    timeInForce = "GTC"
)

# Float64 is also supported but may have precision issues
# For exact amounts, prefer String or DecimalPrice
order_result = place_order(
    rest_client,
    "BTCUSDT",
    "BUY",
    "MARKET";
    quantity = 0.001  # May lose precision in edge cases
)
```

### WebSocket Market Data

```julia
using Binance

# WebSocket client for real-time market data
market_client = MarketDataStreamClient("config.toml")

# Subscribe to BTC/USDT ticker
ticker_callback = ticker -> println("$(ticker.symbol): $(ticker.lastPrice)")
stream_id = subscribe_ticker(market_client, "BTCUSDT", ticker_callback)

# Subscribe to 1h kline
kline_callback = kline -> println("Kline: $(kline.symbol) - Close: $(kline.close)")
stream_id = subscribe_kline(market_client, "BTCUSDT", "1h", kline_callback)
```

### WebSocket API (Interactive Trading)

```julia
using Binance

# WebSocket API client
ws_client = WebSocketClient("config.toml")

# Connect and authenticate
connect!(ws_client)
session_logon(ws_client)

# Place order with exact decimal precision using DecimalPrice
order_result = place_order(
    ws_client,
    "BTCUSDT",
    "BUY",
    "LIMIT";
    quantity = DecimalPrice("0.001"),
    price = DecimalPrice("60000.0"),
    timeInForce = "GTC"
)

# Or use String for exact values
order_result = place_order(
    ws_client,
    "BTCUSDT",
    "BUY",
    "LIMIT";
    quantity = "0.001",
    price = "60000.0",
    timeInForce = "GTC"
)

# Query open orders
open_orders = orders_open(ws_client; symbol = "BTCUSDT")

# Get account status
account = account_status(ws_client)

# Cleanup
session_logout(ws_client)
disconnect!(ws_client)
```

## Decimal Precision

This SDK uses **FixedPointDecimals.jl** to provide exact decimal precision for cryptocurrency trading. This is critical because:

- Float64 can have precision errors (e.g., `0.1 + 0.2 != 0.3`)
- Cryptocurrency exchanges require exact decimal values
- Different assets have different precision requirements

### Usage Options

1. **String** (Recommended for simple cases): Pass exact decimal as string
   ```julia
   quantity = "0.00100000"
   ```

2. **DecimalPrice** (Recommended for calculations): Use FixedDecimal with 8 decimal places
   ```julia
   quantity = DecimalPrice("0.001")  # Exact 8-decimal precision
   # Performs arithmetic without precision loss
   total = DecimalPrice("0.001") * DecimalPrice("60000.0")
   ```

3. **Float64** (Caution): May lose precision in edge cases
   ```julia
   quantity = 0.001  # Works but may have precision issues
   ```

### DecimalPrice Type

`DecimalPrice` is a type alias for `FixedDecimal{Int64, 8}`, providing 8 decimal places of precision (standard for most cryptocurrencies like Bitcoin):

```julia
# Create from string (preferred)
price = DecimalPrice("60000.12345678")

# Arithmetic operations maintain precision
total = DecimalPrice("0.001") * DecimalPrice("60000.0")  # Exact result

# Convert to string for display
price_str = string(price)  # "60000.12345678"
```

## Project Status

### Completed Features

#### ✅ Core Foundation
- HTTP client with timeout, proxy support
- Modular architecture (RESTClient, MarketDataStreams, WebSocketAPI)
- HMAC SHA256, RSA, and Ed25519 signature methods
- Unified error handling and rate limiting with connection tracking

#### ✅ REST API (Spot Complete)
- Market data endpoints (100%)
- Spot account and trading (100%)
- Comprehensive error handling (100%)

#### ✅ WebSocket Streams
- Market data streams implementation (100%)
- Connection management with heartbeat and auto-reconnect (100%)

#### ✅ WebSocket API
- Interactive trading endpoints with full validation (100%)
- Session management with proper authentication flow (100%)
- User data stream subscriptions with signature support (100%)
- Account queries with proper weight tracking (100%)

### Remaining Tasks

#### 🔄 Planned Features
- **Margin Trading**: Full support for cross and isolated margin accounts
- **Sub-accounts**: Delegation and management of sub-accounts
- **Advanced SAPI**: Staking, convertible tokens, mining, OTC
- **Futures/Options**: Complete implementation
- **Portfolio Management**: Advanced risk and position management

## Architecture

```
Binance.jl/
├── src/
│   ├── Binance.jl          # Main module with exports
│   ├── RESTAPI.jl          # REST endpoints implementation
│   ├── MarketDataStreams.jl # WebSocket market data streams
│   ├── WebSocketAPI.jl     # Interactive WebSocket API
│   ├── OrderBookManager.jl # Local order book management ⭐ New in v0.5.0
│   ├── Config.jl           # Configuration management
│   ├── Signature.jl        # Authentication and signing
│   ├── Types.jl            # Data models and structs
│   ├── Filters.jl          # Order validation filters
│   ├── Account.jl          # Account-related utilities
│   ├── Errors.jl           # Custom error types
│   ├── Events.jl           # WebSocket event types
│   └── RateLimiter.jl      # API rate limiting logic
├── examples/
│   ├── orderbook_basic.jl   # OrderBookManager basic usage ⭐ New in v0.5.0
│   └── orderbook_advanced.jl # OrderBookManager advanced features ⭐ New in v0.5.0
├── config_example.toml     # Configuration template
├── examples.jl             # Usage examples
├── CHANGELOG.md            # Version history and changes
├── README.md               # This file
└── Project.toml            # Julia project dependencies
```

## Security Notes

- Enable 2FA on your Binance account
- Use IP whitelisting when possible

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Submit a pull request with clear description

## License

This project is released under the MIT License. See LICENSE file for details.

## Disclaimer

This software is for educational and informational purposes only. Use at your own risk. Always test with small amounts and understand the risks involved in cryptocurrency trading.

## Contact

For issues, questions, or contributions, please file an issue.
