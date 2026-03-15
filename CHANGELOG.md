# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.0] - 2026-03-15

### Added
- **Price Range Execution Rules** - New endpoints for querying execution rules per symbol
  - REST API: `get_execution_rules`, `get_reference_price`, `get_reference_price_calculation`
  - WebSocket API: `execution_rules`, `reference_price`, `reference_price_calculation`
  - MarketData stream: `subscribe_reference_price` for `<symbol>@referencePrice` stream
  - New types: `ExecutionRule`, `SymbolExecutionRules`, `ExecutionRulesResponse`, `ReferencePrice`, `AbstractReferencePriceCalculation`, `ArithmeticMeanCalculation`, `ExternalCalculation`
- **`serverShutdown` WebSocket event** - `ServerShutdown` event struct with automatic reconnection warning when the server is about to shut down
- **`expiryReason` field** - Added to `ExecutionReport` user data stream event (`eR` field) for order expiry tracking

### Changed
- **SBE schema 3:3** - Updated `SBEDecoder.jl` to support schema version 3 (version 2 now deprecated)
- **FIX SBE schema 1:1** - Updated `FIXSBEDecoder.jl` to decode new `ExpiryReason` field in `SBEExecutionReport`
  - New constant `TAG_EXPIRY_REASON = 25056` in `FIXConstants.jl`
  - New constant `SBE_SCHEMA_VERSION_FIX_V1` for schema version 1:1
  - Added `EXEC_TYPE_EXPIRED_IN_MATCH` exec type
- **stunnel TLS/SNI configuration** - Added SNI directives and `verifyChain=yes` for production FIX connections per Binance TLS connectivity update (effective 2026-06-08)

### BinanceFIX v0.2.0
- `SBEExecutionReport` now includes `expiry_reason::Union{UInt8,Nothing}` field
- Decoder uses `header.blockLength` for forward-compatible field detection
- Updated FIX SBE schema references from 1:0 to 1:1

## [0.7.4] - 2026-02-13

### Fixed
- **SBE decoder resilience** - Unknown SBE template IDs (e.g., `NonRepresentableMessage` id=999 from schema 3:1+) now log a warning instead of crashing the stream connection
  - `SBEDecoder.jl`: `decode_sbe_message` returns `nothing` for unknown template IDs instead of throwing
  - `SBEMarketDataStreams.jl`: `handle_sbe_message` gracefully skips `nothing` decoded messages

## [0.7.3] - 2025-02-07

### Performance Improvements
- **Callback type stability** (P0) - Removed abstract `::Function` type annotations from callback parameters
  - `MarketDataStreams.jl`: Changed `Dict{String,Function}` → `Dict{String,Any}` for callback storage; removed `::Function` from 15 subscribe function signatures
  - `SBEMarketDataStreams.jl`: Same pattern applied to 7 subscribe function signatures
  - Fixed double Dict lookup in `_handle_ws_messages` (single `get` instead of `haskey` + index)
- **Allocation elimination** (P1) - Replaced heap-allocated arrays with stack-allocated tuples for `in` checks
  - `Filters.jl`: Hoisted validation arrays to module-level `const` tuples (`VALID_INTERVALS`, `VALID_ORDER_TYPES`, `VALID_SIDES`, `VALID_TIME_IN_FORCE`)
  - `RESTAPI.jl`: 5 locations converted from `in [...]` to `in (...)`; eliminated per-request `request_kwargs` Dict allocation with direct keyword args
  - `WebSocketAPI.jl`: 12 locations converted; replaced 89-element `valid_window_sizes` array with O(1) `_is_valid_window_size()` function
  - `MarketDataStreams.jl`: 2 locations converted
- **Thread safety** (P1) - `Signature.jl`: Replaced global mutable HMAC buffers with local stack-allocated buffers (thread-safe concurrent signing)
- **Type stability** (P1) - `RateLimiter.jl`: Replaced `Union{DateTime, Nothing}` with `DateTime` sentinel (`typemin(DateTime)`); `interval_to_ms` returns `Int64(0)` sentinel instead of `Nothing`

## [0.7.2] - 2025-01-31

### Added
- **Comprehensive SPOT API Error Codes** - Added 50+ new error codes to `Errors.jl`
  - FIX protocol errors (-1033, -1034, -1035, -1169 to -1191)
  - SBE-related errors (-1152 to -1155, -1161)
  - OCO/OPO order validation errors (-1158, -1160, -1165 to -1168, -1196 to -1199)
  - Parameter and request errors (-1013, -1108, -1122, -1135, -1139, -1145, -1194)
  - Peg order errors (-1210, -1211)
  - OPO/symbol status errors (-1220 to -1225)
  - Subscription and order amend errors (-2035, -2036, -2038, -2039, -2042)
- **New Filter Failure Descriptions** - 5 new entries in `FILTER_FAILURES`
  - `NOTIONAL`, `MAX_NUM_ORDER_AMENDS`, `MAX_NUM_ORDER_LISTS`
  - `EXCHANGE_MAX_NUM_ICEBERG_ORDERS`, `EXCHANGE_MAX_NUM_ORDER_LISTS`

### Performance Improvements
- **Convert.jl** - Julia performance optimization
  - All `show` methods: replaced string interpolation `$()` with direct `print` arguments
  - Validation checks: replaced vector `["BUY", "SELL"]` with tuple `("BUY", "SELL")` for `in` operations (stack-allocated, zero allocation)
