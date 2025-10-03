# Binance.jl - Julia SDK for Binance API

A comprehensive Julia SDK for interacting with Binance's Spot Trading APIs, including REST API, WebSocket Market Data Streams, and WebSocket API for real-time trading.

## 🎉 Recent Updates (v0.5.0)

### WebSocket Enhancements
- **eventStreamTerminated Support**: Added `EventStreamTerminated` struct and automatic handling so user data stream terminations are logged cleanly with timestamps.
- **Graceful Logging**: Default handler surfaces reconnection intent without spurious warnings.

### Dependency Update
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

# Place a market order (example - MARKET order)
order_result = place_order(
    rest_client,
    "BTCUSDT",
    "BUY",
    "MARKET";
    quantity = "0.001"
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

# Place order
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
│   ├── Config.jl           # Configuration management
│   ├── Signature.jl        # Authentication and signing
│   ├── Types.jl            # Data models and structs
│   ├── Filters.jl          # Order validation filters
│   ├── Account.jl          # Account-related utilities
│   ├── Errors.jl           # Custom error types
│   ├── Events.jl           # WebSocket event types
│   └── RateLimiter.jl      # API rate limiting logic
├── config_example.toml     # Configuration template
├── examples.jl             # Usage examples
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
