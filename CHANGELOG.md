# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2025-11-16

### Added
- **OrderBookManager Module** - Complete local order book management with automatic synchronization ⭐
  - Implements Binance's corrected order book synchronization algorithm (2025-11-12)
  - Automatic WebSocket diff depth stream subscription and event buffering
  - REST API snapshot fetching with proper validation
  - Continuous differential updates with error detection and recovery
  - Thread-safe access to order book data with near-zero latency
  - Rich query API: `get_best_bid`, `get_best_ask`, `get_spread`, `get_mid_price`
  - Advanced analysis: `calculate_vwap`, `calculate_depth_imbalance`
  - Custom callback support for real-time updates
  - Automatic reconnection and resynchronization on errors
- **DataStructures.jl Dependency** - Added for efficient OrderedDict implementation
- **Examples**:
  - `examples/orderbook_basic.jl` - Basic usage and data access
  - `examples/orderbook_advanced.jl` - Advanced features and trading strategies

### Deprecated
- **`subscribe_all_tickers()` function** - Uses Binance's deprecated `!ticker@arr` stream (deprecated 2025-11-14)
  - This stream will be removed from Binance systems at a later date
  - **Migration guide:**
    - Use `subscribe_all_mini_tickers()` for all market mini tickers (`!miniTicker@arr`)
    - Use `subscribe_ticker(symbol)` for individual symbol tickers (`<symbol>@ticker`)
  - Function now emits deprecation warning when called

### Changed
- Added deprecation warning to `subscribe_all_tickers()` function in `MarketDataStreams.jl`
- Added comprehensive documentation for migration path from deprecated stream

### Fixed
- **Critical**: Fixed OrderBookManager price sorting bug
  - `get_best_bid()` and `get_best_ask()` now correctly find maximum/minimum prices
  - `get_bids()` and `get_asks()` now properly sort before returning top N levels
  - `calculate_vwap()` and `calculate_depth_imbalance()` now work with sorted data
  - Previous implementation incorrectly assumed OrderedDict maintains sorted order
  - Bug caused incorrect best bid/ask prices (e.g., showing $76799 bid when ask was $96016)

## [0.4.4] - 2025-10-28

### Added
- **symbolStatus Parameter Support** - Implemented across all relevant market data endpoints as per Binance's API CHANGELOG (2025-10-28)
- Support for filtering symbols by trading status (`"TRADING"`, `"HALT"`, `"BREAK"`)
- Error handling for invalid symbol status combinations (error `-1220`)
- **Backward Compatible** - Optional parameter, defaults to no filtering

### Changed
- **Updated REST API Endpoints**:
  - `get_orderbook()` - Order book depth data
  - `get_symbol_ticker()` - Symbol price ticker(s)
  - `get_ticker_24hr()` - 24-hour ticker statistics
  - `get_ticker_book()` - Best bid/ask prices
  - `get_trading_day_ticker()` - Trading day ticker statistics
  - `get_ticker()` - Rolling window ticker statistics

- **Updated WebSocket API Endpoints**:
  - `depth()` - Order book depth data
  - `ticker_price()` - Symbol price ticker(s)
  - `ticker_book()` - Best bid/ask prices
  - `ticker_24hr()` - 24-hour ticker statistics
  - `ticker_trading_day()` - Trading day ticker statistics
  - `ticker()` - Rolling window ticker statistics

### Usage Examples
```julia
# REST API - Get orderbook only for trading symbols
orderbook = get_orderbook(client, "BTCUSDT"; symbolStatus="TRADING")

# Get multiple tickers, filtering by status
tickers = get_symbol_ticker(client; symbols=["BTCUSDT", "ETHUSDT"], symbolStatus="TRADING")

# WebSocket API - Get price with status filter
price = ticker_price(ws_client; symbol="BTCUSDT", symbolStatus="TRADING")
```

### Error Handling
- Returns error `-1220` if single symbol doesn't match status
- Returns empty array if no symbols match status filter

### Documentation
- Added comprehensive usage examples in `test_symbolStatus.jl`
- Updated README.md with symbolStatus parameter documentation

## [0.4.3] - 2025-01-28

### Added
- **Exact Decimal Precision Support** - Integrated FixedPointDecimals.jl for precise cryptocurrency calculations
- **DecimalPrice Type** - New type alias `FixedDecimal{Int64, 8}` for 8-decimal precision (cryptocurrency standard)
- **Flexible Input Types** - Order functions now accept `String`, `Float64`, or `FixedDecimal` for numeric parameters
- **EventStreamTerminated Struct** - For WebSocket user data stream terminations
- **Crayons.jl Dependency** - Added for terminal color output

### Fixed
- **JSON3.Object Immutability Issues** - Fixed `MethodError` when converting timestamps in API responses
  - Date conversion handling for immutable JSON objects
  - Response handling to return mutable `Dict` objects for datetime fields

### Changed
- **Enhanced Order Functions** - `place_order()`, `cancel_order()`, and all order list functions with decimal precision support
- **Updated Market Data Functions** - `get_ticker_24hr()`, `get_trading_day_ticker()`, `get_ticker()`, `get_avg_price()` with improved response handling
- **Improved WebSocket Event Stream** - Termination logging with timestamps

### Usage Examples

#### Decimal Precision
```julia
# Using String for exact decimal values (recommended for simple cases)
order_result = place_order(
    rest_client,
    "BTCUSDT",
    "BUY",
    "MARKET";
    quantity = "0.001"  # String ensures exact precision
)

# Using DecimalPrice (recommended for calculations)
order_result = place_order(
    rest_client,
    "BTCUSDT",
    "BUY",
    "LIMIT";
    quantity = DecimalPrice("0.001"),
    price = DecimalPrice("60000.0"),
    timeInForce = "GTC"
)

# Arithmetic operations maintain precision
total = DecimalPrice("0.001") * DecimalPrice("60000.0")  # Exact result
```

### Precision Guarantees
- Eliminates floating-point precision errors (e.g., `0.1 + 0.2 != 0.3`)
- Critical for cryptocurrency trading where exchanges require exact decimal values
- Different assets have different precision requirements (8 decimals standard for Bitcoin)

### Documentation
- Added comprehensive decimal precision usage guide in README.md
- Documented precision guarantees and best practices
- Updated all code examples with DecimalPrice usage

## [0.4.2] - 2025-01-28

### Added
- **WebSocket API Trading Complete** (95% functionality)
- Complete order lifecycle management
- Advanced order types: OCO, OTO, OTOCO
- SOR (Smart Order Routing) support
- User data stream management with signature subscriptions

### Documentation
- Created WEBSOCKET_API_STATUS.md for WebSocket API implementation tracking
- Added comprehensive trading examples
- Performance benchmarks and best practices

## Earlier Versions

Earlier changes were not tracked in this changelog. Please refer to git commit history for details.

---

## Document Change History

### 2025-11-16
- **OrderBookManager Implementation**: Added complete local order book management module
- **New Files**:
  - `src/OrderBookManager.jl` - Core implementation
  - `examples/orderbook_basic.jl` - Basic usage example
  - `examples/orderbook_advanced.jl` - Advanced features and strategies
- **SDK Enhancement**: Integrated automatic order book synchronization following Binance's corrected guidelines
- **Project.toml**: Added DataStructures.jl dependency

### 2025-11-14
- **Binance API Update**: All Market Tickers Stream (`!ticker@arr`) deprecated by Binance
- **Code Update**: Added deprecation warning to `subscribe_all_tickers()` function
- **CHANGELOG.md**: Documented deprecation and migration path

### 2025-11-12
- **Binance Documentation Correction**: Updated guidelines for managing local order books correctly
- **Key Changes**:
  - Clarified the correct sequence for buffering events and fetching depth snapshots
  - Fixed the validation logic for `lastUpdateId` comparison with first event's `U`
  - Emphasized proper handling of first buffered event's `[U;u]` range
  - Added important note about 5000 price level limitation in depth snapshots
- **Impact**: Users implementing local order book management should review and update their logic

### 2025-11-10
- **All Documents**: Removed "Last Updated" dates from all documents except CHANGELOG
- **Policy Change**: CHANGELOG is now the single source of reference for document changes

### 2025-01-28
- **WEBSOCKET_API_STATUS.md**: Documented WebSocket API trading completion milestone

### 2025-10-28
- **README.md**: Added v0.4.4 symbolStatus parameter documentation

---

*This CHANGELOG follows the policy update from 2025-11-10: all document change dates are now tracked exclusively in this file.*
