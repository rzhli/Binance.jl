# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
