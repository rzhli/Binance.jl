# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.0] - 2026-05-09

### Added
- **Historical Block Trades** (2026-05-08 deployment) — New endpoint for block
  trade history. Block trades are large off-book trades matched against a
  separate liquidity pool.
  - REST API: `get_historical_block_trades(client, symbol, from_id; limit=500)`
    → `GET /api/v3/historicalBlockTrades` (weight 25, `fromId` mandatory)
  - WebSocket API: `block_trades_historical(client, symbol, from_id; limit=500)`
    → `blockTrades.historical` (weight 25)
  - New type `BlockTrade` in `Types.jl`: `(id, price, qty, quoteQty, time,
    isBuyerMaker)` — note absence of `isBestMatch` (differs from `MarketTrade`)
- **`expiryReason` field on order query responses** — Added `expiryReason ::
  Union{String, Nothing}` to the `Order` struct. Returned only for expired
  orders, including those expired by the price-range execution rule. Affects
  `get_order`, `get_open_orders`, `get_all_orders` (REST) and `order.status`,
  `openOrders.status`, `allOrders` (WS API). Order-list responses pass through
  raw JSON3 objects so users see the new field automatically.
- **`serverShutdown` event handling on WebSocket Streams** —
  `MarketDataStreams.jl` now detects `serverShutdown` control events on stream
  connections (sent ~10 minutes before disconnection per 2026-05-08 deployment),
  logs a warning, and lets the existing reconnect loop handle the drop. The
  WebSocket API path already had this handler.

### Changed
- **SBE schema 3:3 → 3:4** — Bumped current schema version constants in
  `SBEDecoder.jl` (`SCHEMA_VERSION_CURRENT = 4`); 3:3 marked deprecated as of
  2026-05-08, retiring ~6 months later. Market-data template IDs (10000–10003)
  used by this decoder are unchanged across 3:3 and 3:4. Schema 3:4 adds:
  - new message `BlockTradesResponse` (template 219)
  - new type `blockTradeId`
  - new optional field `expiryReason` on `OrderResponse` (304) and
    `OrdersResponse` (308) — note this was already present on order-placement
    responses (`NewOrderResultResponse`, `NewOrderFullResponse`, list variants)
    since 3:3
- **Filter docstrings** — `PERCENT_PRICE`, `PERCENT_PRICE_BY_SIDE`,
  `MIN_NOTIONAL`, `NOTIONAL` now document the 2026-05-08 server behavior:
  evaluated against the symbol's reference price when one exists and is
  non-null, falling back to historical avg-price behavior otherwise. Client-side
  validators here use the explicit request price/qty, so the server is
  authoritative when the two diverge.

### Fixed (carried from prior unreleased)
- **Config.jl** — `SystemError` exception handling: `SystemError` in Julia
  does not expose a `.msg` field; replaced `$(e.msg)` with a static string
  literal so the error message is always descriptive regardless of Julia
  version
- **RateLimiter.jl** — Replaced four separate `@inline` single-dispatch
  methods for `period_to_ms(p::Period)` with a single typed function
  `period_to_ms(p::Period)::Int64` using `isa` checks, giving the inner
  constructor of `APILimit` a concrete return type to call
- **Errors.jl** — Added `Base.show(io::IO, ::BinanceException)` fallback so
  the abstract parent type renders its name instead of a blank line when
  printed in exception chains
- **Price Range Execution Rule FAQ** (2026-04-28) — Clarified that the price
  range rule applies symmetrically to both BUY and SELL orders. Updated
  docstrings on `get_execution_rules` and `execution_rules` to state
  explicitly: BUY orders are bounded by ``bidLimitMultUp/Down × referencePrice``;
  SELL orders by ``askLimitMultUp/Down × referencePrice``, with multipliers
  potentially differing between sides per symbol configuration.

## [0.8.3] - 2026-04-19

### Changed
- **Type-stability fixes per Julia performance guide** - Tightened
  not-fully-parameterized types to concrete parameters:
  - `src/OrderBookManager.jl`: `event::Dict` → `event::Dict{String,Any}`
    on all 4 dispatch helpers; `item::Vector` → `item::AbstractVector` in
    `parse_price_qty` (hot path called on every depth update)
  - `src/Filters.jl`: all 13 `params::Dict` signatures → `params::Dict{String,Any}`
    to match existing caller usage
- **Drop `::Function` annotations** - Per the Julia style guide ("Julia
  doesn't auto-specialize on `Function`"), removed `::Function` from
  docstring signatures of the SBE subscribe family in
  `src/SBEMarketDataStreams.jl` (`sbe_subscribe`, `sbe_subscribe_trade`,
  `sbe_subscribe_best_bid_ask`, `sbe_subscribe_depth`, `sbe_subscribe_depth20`,
  `sbe_subscribe_combined`). Function bodies were already untyped; docstrings
  now match.

### Added
- **Test suite infrastructure** - `test/runtests.jl` with smoke tests for
  module loading, HMAC signing determinism, and core type construction.
  `Project.toml` now declares `[extras]` / `[targets]` so `pkg> test Binance`
  works end-to-end.

### Fixed
- **Project UUID** - Replaced placeholder UUID
  `12345678-1234-5678-9012-123456789012` with a real v4 UUID
  (`cea3082c-a500-42ba-b008-7fc426d310bc`). `BinanceFIX/Project.toml`
  updated in lockstep to preserve the path-dep reference.

## [0.8.2] - 2026-04-19

### Added
- **Error code -2043** - `NO_REFERENCE_PRICE` added to `Errors.jl`. Returned
  when querying the reference price of a symbol that has never had one set
  (documented 2026-04-16). Applies to:
  - REST API: `GET /api/v3/referencePrice`
  - WebSocket API: `referencePrice`

### Changed
- **SBE Diff Depth stream update speed** - Documentation updated: update speed
  will change from 50ms → 25ms on 2026-05-05 (announced 2026-04-17). Affects:
  - `src/SBEMarketDataStreams.jl`: `sbe_subscribe_depth` (`<symbol>@depth`)
  - `BinanceFIX/src/FIXSBEDecoder.jl`: `SBEMarketDataIncrementalDepth`
    (templateId=207)
- **`amend_order` weight semantics** - Docstrings clarified (per 2026-04-02
  announcement): the weight-0 optimization applies ONLY when the amendment
  causes the order to expire. Successful requests that do not cause expiry —
  and failed requests — are still charged the documented weight. Affects:
  - REST API: `PUT /api/v3/order/amend/keepPriority`
  - WebSocket API: `order.amend.keepPriority`
- **Price Range Execution Rule enforcement** - Docstrings on
  `get_execution_rules` / `execution_rules` expanded to describe when the rule
  is enforced (placement, amend, trigger activations) per the 2026-04-06
  update.

## [0.8.1] - 2026-04-13

### Added
- **STP Transfer on all symbols** - Self-trade prevention mode `TRANSFER` is now allowed on all symbols (effective 2026-04-02)
- **Request weight optimization** - Successful requests to the following order endpoints now have weight=0 (failed requests still charged):
  - REST API: `POST /api/v3/order`, `POST /api/v3/sor/order`, `DELETE /api/v3/order`, `DELETE /api/v3/openOrders`, `POST /api/v3/order/cancelReplace`, `POST /api/v3/order/oco`, `POST /api/v3/orderList/oco`, `POST /api/v3/orderList/oto`, `POST /api/v3/orderList/otoco`, `POST /api/v3/orderList/opo`, `POST /api/v3/orderList/opoco`, `DELETE /api/v3/orderList`, `PUT /api/v3/order/amend/keepPriority`
  - WebSocket API: `order.place`, `sor.order.place`, `order.cancel`, `openOrders.cancelAll`, `order.cancelReplace`, `orderList.place`, `orderList.place.oco`, `orderList.place.oto`, `orderList.place.otoco`, `orderList.place.opo`, `orderList.place.opoco`, `orderList.cancel`, `order.amend.keepPriority`
- **RAW_REQUESTS limit increase** - Rate limit increased to 300,000 requests per 5 minutes (previously 120,000)
- **Price Range Execution Rules** - Updated documentation for execution price limits on orders

### Changed
- **Config.jl** - Updated default `max_raw_requests_per_5m` from 120000 to 300000 to match new API limits

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
