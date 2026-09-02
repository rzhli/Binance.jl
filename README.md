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

### v0.13.0 - JSON.jl 1.x

- **Replaced JSON3.jl and StructTypes.jl with JSON.jl 1.x** — JSON3 is marked
  `[deprecated]` upstream; JSON.jl 1.0 absorbed its design and moved struct
  mapping to StructUtils.jl. All 63 `StructTypes` declarations are gone, replaced
  by field tags on the struct definitions themselves.
- **Faster typed parsing** — filling a struct straight from the bytes is
  **3.7x faster and allocates 6.2x less** than decode-then-convert (1000
  `myTrades`: 0.76 ms / 546 KiB vs 2.83 ms / 3363 KiB). `exchangeInfo` for 100
  symbols is 1.5x faster, 2.5x less memory.
- **`make_request` now returns a `JSON.Object`** instead of a `JSON3.Object`.
  Property access, symbol/string indexing, `haskey`, `get` and
  `isa AbstractDict` all behave the same, so pass-through call sites are
  unaffected. Code that tested `isa JSON3.Object` should test `isa AbstractDict`.
- **Clearer filter errors** — an unrecognised `filterType` raises an
  `ArgumentError` naming the value instead of a `FieldError` about an internal
  NamedTuple. Unknown filters still fail loudly rather than being dropped:
  silently losing a `LOT_SIZE` would let an order violate `stepSize`.
- 285 new deserialization tests (113 → 398), asserting every response type field
  by field in both the lazy and the materialized path.

### v0.12.3 - HTTP.jl 2.x alignment

- **Fixed `depth()` deserialization** — `OrderBook` used the generic
  `StructTypes.Struct()` mapping, which cannot construct its `CustomStruct`
  `PriceLevel` elements; every `depth(ws_client, symbol)` call raised a
  `MethodError`. It now provides explicit `construct`/`lower` methods.
- **Error-safe retries** — Signed REST requests are no longer replayed by the
  HTTP client (a replay reuses the original `timestamp`/`signature`, so it can
  land outside `recvWindow`, and amend/cancel would be re-sent against live
  orders). Rate-limit responses (`429`/`418`/`403`) are never retried on the
  transport level, since retrying them escalates a violation into an IP ban.
- **Single error path** — Non-2xx responses now stay on the normal return path
  (`status_exception = false`), so `handle_error` is the only place that maps
  Binance error payloads to exceptions. `401` maps to `UnauthorizedError`.
  `Retry-After` is read through `HTTP.header` (case-insensitive, canonicalized)
  and an unparseable value warns instead of throwing.
- **Credential safety** — REST requests no longer follow redirects: HTTP.jl only
  strips standard credential headers across origins, so `X-MBX-APIKEY` would
  otherwise be replayed to a redirect target. The API key is now a `Client`
  default header instead of being rebuilt per call.
- **Dead-connection detection** — All WebSocket connections (market streams,
  WebSocket API, SBE streams) set `read_idle_timeout`, so a silently dropped TCP
  connection surfaces as a 1006 close and triggers a reconnect instead of
  blocking the reader forever.
- **Jittered reconnect backoff** — Reconnect loops use exponential backoff with
  jitter (`RateLimiter.backoff_delay`) instead of a fixed delay, and every
  re-dial reserves a connection-limiter slot, so an exchange-side outage cannot
  exhaust the 300-connections-per-5-minutes budget in lockstep.
- **Proxy defaults** — An empty `proxy` in `config.toml` now means "use the
  standard `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`/`NO_PROXY` environment
  variables" (HTTP.jl's default) rather than forcing a direct connection.
- **Idle-connection control** — Added `close_idle_connections!(rest_client)` to
  drop pooled connections that intermediaries may have silently dropped, without
  closing the client.
- **Lower request latency** — WebSocket API response waiting blocks on the
  response channel instead of polling it every 50 ms, and REST JSON is parsed
  straight from the response byte buffer without an intermediate `String` copy.

### v0.12.2 - REST connection pooling

- **Reusable HTTP client** — `RESTClient` now owns a long-lived
  `HTTP.Client` / `HTTP.Transport` (HTTP.jl 2.x) instead of creating a fresh
  transport per request. TCP/TLS connections and ALPN HTTP/2 sessions are
  pooled and reused across calls, cutting latency for rate-limited trading
  loops. Proxy policy from `config.toml` is configured once on the transport.
- **Lifecycle management** — Added `close(rest_client)` / `isopen(rest_client)`
  to release idle connections; requests through a closed client raise
  `ArgumentError` (HTTP.jl closed-client poisoning).

### v0.12.1 - Strategy startup and SBE stream hotfixes

- **Immediate first connection** — Fixed a rate-limiter control-flow bug that
  repeatedly reserved connection slots until the five-minute WebSocket limit
  was exhausted, making strategy startup appear to hang.
- **Regression coverage** — Added a test ensuring one connection attempt
  consumes exactly one limiter slot and returns immediately.
- **SBE market-stream schema** — Corrected the dedicated market-data decoder
  from the WebSocket API schema ID `3` to the official `spot_stream` schema
  `1:0`, restoring Trade, best-bid/ask, and depth stream decoding.

### v0.12.0 - Precision, concurrency, and protocol hardening

- **Exact order validation** — Price and quantity filters accept decimal
  strings and fixed-point values without binary floating-point boundary errors.
- **Thread-safe clients** — REST caches, WebSocket request state,
  subscriptions, callbacks, and `OrderBookManager` state are synchronized;
  callbacks execute outside internal locks.
- **Safer SBE/FIX processing** — Added strict framing and bounds validation,
  allocation-reduced integer codecs, supervised monitor tasks, and timeout
  handling that does not leave orphan readers.
- **Configuration and API fixes** — Corrected testnet endpoints, added the
  exported `load_config` helper, restored missing root exports, and fixed
  `REQUEST_WEIGHT` rate-limit accounting.
- **BinanceFIX 0.5.0** — Includes the corresponding session, framing,
  concurrency, and encoder/decoder improvements. Julia 1.11+ is supported.

---

**Complete version history:** [CHANGELOG.md](CHANGELOG.md)

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
# Leave empty to use the standard HTTP_PROXY / HTTPS_PROXY / ALL_PROXY / NO_PROXY
# environment variables; set explicitly to override them.
proxy = ""  # e.g. "http://127.0.0.1:7890" or "socks5://127.0.0.1:7891"
```

See `config_example.toml` for all options.

Load the configuration explicitly when needed:

```julia
config = load_config("config.toml")
```

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

# RESTClient pools HTTP connections internally; release them when done
close_idle_connections!(rest_client)  # drop idle pooled connections, stay usable
close(rest_client)        # subsequent calls raise ArgumentError
isopen(rest_client)       # false after close
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

The four files below drive a full trading strategy. They `include` the `strategy/`
directory, which is gitignored (personal trading strategies, not shipped with the
package), so a fresh clone will hit `SystemError: opening file .../strategy/...`.
They are here to document the high-level entry points; every order-placing call is
commented out by default.

| File | Description |
|------|-------------|
| `test.jl` | All four client types, plus grid strategies driven by ticker and by depth |
| `single_run_test.jl` | `run_single_orderbook_strategy` / `run_multi_orderbook_strategy`, with technical analysis and support/resistance injection |
| `test_orderbook_strategy.jl` | Assembling an `OrderBookManager` by hand: own monitoring loop, own cleanup |
| `test_convert.jl` | Convert (flash-swap) strategies — no 5 USDT minimum notional |

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
