# Binance.jl

A comprehensive, high-performance Julia SDK for Binance Spot Trading APIs.

## Overview

Binance.jl provides complete access to Binance's trading infrastructure:
- **REST API** for account management and trading operations
- **WebSocket streams** for real-time market data (JSON and high-performance SBE binary)
- **WebSocket API** for interactive real-time trading
- **OrderBookManager** for local order book with sub-millisecond access

## Table of Contents

- [Recent Updates](#recent-updates)
- [Features](#features)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Documentation](#documentation)
- [Examples](#examples)
- [Architecture](#architecture)
- [Contributing](#contributing)
- [License](#license)

## Recent Updates

### v0.8.0 - Price Range Execution Rules & SBE Schema Updates (2026-03-15)

- **Price Range Execution Rules** - New REST, WebSocket API, and stream endpoints
  - `get_execution_rules` / `get_reference_price` / `get_reference_price_calculation`
  - `subscribe_reference_price` for real-time reference price streams
- **`serverShutdown` WebSocket event** with automatic reconnection warning
- **`expiryReason` field** in `ExecutionReport` user data stream events
- **SBE schema 3:3** and **FIX SBE schema 1:1** support
- **stunnel SNI/TLS hardening** for FIX connections

---

### v0.7.2 - Error Codes & Performance (2025-01-31)

- **50+ new SPOT API error codes** in `Errors.jl` (FIX, SBE, OCO/OPO, parameter errors)
- **5 new filter failure descriptions** (NOTIONAL, MAX_NUM_ORDER_AMENDS, etc.)
- **Convert.jl performance optimization** (show methods, tuple-based `in` checks)

---

### v0.7.0 - SDK Split & BinanceFIX (2025-12-11) 🔧

**Breaking Change**: FIX API separated into standalone `BinanceFIX.jl` package.

**Why?**
- Cleaner separation of concerns (REST/WebSocket vs FIX protocol)
- Independent versioning for FIX features
- Smaller main package for users who don't need FIX

**Migration:**
```julia
# Before (v0.6.x)
using Binance
session = FIXSession(config, sender_comp_id; session_type=OrderEntry)

# After (v0.7.0)
using Binance
using BinanceFIX
session = FIXSession(config, sender_comp_id; session_type=OrderEntry)
```

**BinanceFIX.jl v0.1.0 Features:**
- Complete FIX 4.4 protocol support
- Session types: OrderEntry, DropCopy, MarketData
- FIX SBE support (ports 9001/9002)
- FIX SBE binary decoder

**📖 See:** [BinanceFIX/README.md](BinanceFIX/README.md)

---

### v0.6.0 - SBE Market Data Streams (2025-11-19) ⚡

High-performance **Simple Binary Encoding (SBE)** streams for ultra-low latency trading.

**Performance Benefits:**
- 60-70% less bandwidth vs JSON
- 30-50% lower latency
- 2-3x faster parsing
- Direct binary memory access

**Quick Example:**
```julia
using Binance

sbe_client = SBEStreamClient()
connect_sbe!(sbe_client)

# Subscribe to real-time trades
sbe_subscribe_trade(sbe_client, "BTCUSDT", event -> begin
    for trade in event.trades
        println("$(trade.price) @ $(trade.qty)")
    end
end)

# Unsubscribe when done
sbe_unsubscribe_trade(sbe_client, "BTCUSDT")

# Or close all streams
sbe_close_all(sbe_client)
```

**📖 Full documentation:** [docs/SBE.md](docs/SBE.md)

---

### v0.5.0 - OrderBookManager (2025-11-16) ⭐

Local order book management with **sub-millisecond latency**.

**Key Features:**
- < 1ms latency (vs 20-100ms for API calls)
- Up to 5000 depth levels
- Built-in VWAP and imbalance analysis
- Auto-sync with Binance streams

**Quick Example:**
```julia
using Binance

orderbook = OrderBookManager("BTCUSDT", rest_client, stream_client;
                              max_depth=5000)
start!(orderbook)

# Access instantly
best_bid = get_best_bid(orderbook)
imbalance = calculate_depth_imbalance(orderbook; levels=20)
```

**📖 Full documentation:** [docs/OrderBookManager.md](docs/OrderBookManager.md)

---

**📋 Complete version history:** [CHANGELOG.md](CHANGELOG.md)

## Features

### 🚀 Core Capabilities

| Feature | Description |
|---------|-------------|
| **REST API** | All Spot Account and Trading endpoints |
| **WebSocket Streams** | Real-time market data (ticker, kline, depth, trades) |
| **SBE Streams** | High-performance binary market data (60-70% less bandwidth) |
| **WebSocket API** | Interactive real-time trading with heartbeat |
| **OrderBookManager** | Local order book with < 1ms latency access |
| **Convert API** | Limit orders and quotes for token conversion |
| **Authentication** | Ed25519, RSA, and HMAC-SHA256 signature support |
| **Rate Limiting** | Automatic compliance with Binance limits |
| **Error Handling** | Comprehensive error types and recovery |

### ✅ Currently Implemented

#### REST API Endpoints
- **General**: Ping, Server Time, Exchange Info
- **Market Data**: Order Book, Trades (Recent/Historical/Aggregate), Klines, Tickers, Prices
- **Spot Trading**: Orders (Place/Cancel/Status), OCO Orders, Account Info, Order History, Rate Limits
- **Strategy Helpers**: Real-time trade strategy helpers with colored order book display

#### WebSocket Market Streams
- **Real-time Data**: Tickers, Klines, Depth, Aggregate Trades
- **All Market Symbols**: Support for individual and combined streams
- **Connection Management**: Auto-reconnect with heartbeat, ping/pong handling

#### SBE Market Data Streams ⚡ v0.6.0
- **Binary Encoding**: 60-70% less bandwidth than JSON
- **Complete Decoder**: All 4 message types (Trade, BestBidAsk, Depth, DepthSnapshot)
- **Low Latency**: 30-50% lower latency vs JSON streams
- **Convenience Functions**: Subscribe/unsubscribe for all stream types
- **Auto-Reconnect**: Automatic reconnection with detailed error diagnostics

#### OrderBookManager ⭐ v0.5.0
- **Local Order Book**: Continuously-synchronized with automatic WebSocket + REST sync
- **Near-Zero Latency**: < 1ms access (vs 20-100ms for REST/WebSocket)
- **Deep Market**: Up to 5000 price levels
- **Built-in Analytics**: VWAP calculation and depth imbalance analysis
- **Auto-Recovery**: Automatic reconnection and resynchronization

#### WebSocket API
- **Session Management**: Logon, Status, Logout
- **Trading Operations**: Place/Cancel/Modify orders with full validation
- **Order Lists**: OCO/OTO/OTOCO support
- **Account Queries**: Balances, Orders, Execution Reports, Commission Rates
- **Smart Order Routing**: SOR orders for optimized execution
- **User Data Streams**: Real-time account updates

### 🔄 Roadmap

- Margin Account and Trading
- Futures API support
- Sub-account Management
- Advanced SAPI Endpoints (Savings, Mining, BLVT, BSwap, Fiat)
- Enhanced WebSocket User Data Event parsing
- Performance optimizations and benchmarks

## Installation

```julia
using Pkg
Pkg.add("https://github.com/rzhli/Binance.jl.git")
```

## Quick Start

### Configuration

Create `config.toml` from the example:

```bash
cp config_example.toml config.toml
```

Edit with your credentials:

```toml
[api]
api_key = "YOUR_API_KEY"
secret_key = "YOUR_SECRET_KEY"

# For WebSocket API and SBE streams
signature_method = "ED25519"
private_key_path = "key/ed25519-private.pem"
private_key_pass = "YOUR_PASSWORD"

[connection]
testnet = false
proxy = ""  # Optional: "http://127.0.0.1:7890"
```

See `config_example.toml` for all options.

### Basic Usage

```julia
using Binance

# Create clients
rest_client = RESTClient()
stream_client = MarketDataStreamClient()
ws_client = WebSocketClient()

# Get market data
server_time = get_server_time(rest_client)
account = get_account_info(rest_client)

# Place order (use String or DecimalPrice for exact precision)
order = place_order(rest_client, "BTCUSDT", "BUY", "LIMIT";
                    quantity="0.001", price="60000.0", timeInForce="GTC")
```

**📖 More examples:** [examples/examples.jl](examples/examples.jl)

## Documentation

### Module Guides

| Module | Description | Documentation |
|--------|-------------|---------------|
| **OrderBookManager** | Local order book with < 1ms latency | [docs/OrderBookManager.md](docs/OrderBookManager.md) |
| **SBE Streams** | High-performance binary market data | [docs/SBE.md](docs/SBE.md) |

### Quick Reference

**Decimal Precision:**
```julia
# Use String or DecimalPrice for exact values (avoids floating-point errors)
quantity = "0.001"
price = DecimalPrice("60000.00")
```

**REST API:**
```julia
rest_client = RESTClient()
server_time = get_server_time(rest_client)
account = get_account_info(rest_client)
order = place_order(rest_client, "BTCUSDT", "BUY", "LIMIT";
                    quantity="0.001", price="60000.0", timeInForce="GTC")
```

**WebSocket Market Streams:**
```julia
stream_client = MarketDataStreamClient()
subscribe_ticker(stream_client, "BTCUSDT", data -> println(data))
subscribe_kline(stream_client, "BTCUSDT", "1h", data -> println(data))
```

**WebSocket API (Interactive Trading):**
```julia
ws_client = WebSocketClient()
connect!(ws_client)
session_logon(ws_client)
place_order(ws_client, "BTCUSDT", "BUY", "LIMIT";
            quantity="0.001", price="60000.0")
```

**SBE Streams (High Performance):**
```julia
sbe_client = SBEStreamClient()
connect_sbe!(sbe_client)
sbe_subscribe_trade(sbe_client, "BTCUSDT", event -> println(event))
sbe_close_all(sbe_client)
```

## Examples

| File | Description |
|------|-------------|
| `examples/orderbook_basic.jl` | OrderBookManager basic usage |
| `examples/orderbook_advanced.jl` | Advanced OrderBookManager with analytics |
| `examples/sbe_stream_example.jl` | SBE binary streams usage |
| `examples/examples.jl` | General REST API, WebSocket streams examples |

## Architecture

```
Binance.jl/
├── src/
│   │
│   │  # Core Module
│   ├── Binance.jl              # Main module with exports
│   │
│   │  # Configuration & Authentication
│   ├── Config.jl               # Configuration management (TOML parsing)
│   ├── Signature.jl            # Authentication (Ed25519, RSA, HMAC)
│   │
│   │  # REST API
│   ├── RESTAPI.jl              # REST endpoints implementation
│   ├── Account.jl              # Account-related utilities
│   ├── RateLimiter.jl          # API rate limiting logic
│   │
│   │  # WebSocket Streams (JSON)
│   ├── MarketDataStreams.jl    # WebSocket market data streams
│   ├── WebSocketAPI.jl         # Interactive WebSocket API
│   ├── OrderBookManager.jl     # Local order book management
│   │
│   │  # SBE Streams (Binary)
│   ├── SBEMarketDataStreams.jl # SBE market data streams
│   ├── SBEDecoder.jl           # SBE binary message decoder
│   │
│   │  # Data Types & Utilities
│   ├── Types.jl                # Data models and structs
│   ├── Events.jl               # WebSocket event types
│   ├── Filters.jl              # Order validation filters
│   └── Errors.jl               # Custom error types
│
├── BinanceFIX/                  # FIX Protocol SDK (sub-package)
│   ├── Project.toml
│   ├── src/
│   │   ├── BinanceFIX.jl       # Main FIX module
│   │   ├── FIXAPI.jl           # FIX session and order entry
│   │   ├── FIXConstants.jl     # FIX field tags and constants
│   │   └── FIXSBEDecoder.jl    # FIX SBE binary decoder
│   ├── test/                   # FIX test suite
│   └── examples/               # FIX usage examples
│
├── docs/
│   ├── OrderBookManager.md     # OrderBookManager documentation
│   └── SBE.md                  # SBE streams documentation
│
├── examples/
│   ├── orderbook_basic.jl      # OrderBookManager basic usage
│   ├── orderbook_advanced.jl   # OrderBookManager advanced features
│   ├── sbe_stream_example.jl   # SBE streams usage example
│   └── examples.jl             # General usage examples
│
├── config_example.toml         # Configuration template
├── CHANGELOG.md                # Version history
└── README.md                   # This file
```

## Security Notes

- **Enable 2FA** on your Binance account
- **Use IP whitelisting** when possible
- **Never commit** `config.toml` or private keys to version control
- **Use testnet** for development and testing
- **Limit API permissions** to only what you need

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature`)
3. Add tests for new functionality
4. Update documentation as needed
5. Submit a pull request with clear description

## License

This project is released under the MIT License. See LICENSE file for details.

## Disclaimer

This software is for educational and informational purposes only. Use at your own risk. Always test with small amounts and understand the risks involved in cryptocurrency trading.

## Support

- **Issues**: [GitHub Issues](https://github.com/rzhli/Binance.jl/issues)
- **Documentation**: See [docs/](docs/) directory
