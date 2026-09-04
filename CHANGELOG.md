# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.15.0] - 2026-09-04

Rate-limit accounting rewrite. The limiter tracked requests where the exchange
tracks weight, which made every `REQUEST_WEIGHT` figure wrong — by a factor of 200
for `convert/getQuote`, 250 for a full-depth snapshot, 3000 for
`convert/tradeFlow`. A client could exhaust its real allowance while believing it
had used 0.5% of it, which is how a strategy walks into a 429 and then an IP ban.

### Added
- **`RateLimits` module** — per-endpoint `EndpointCost` (request weight, unfilled
  order count, and whether success is free) transcribed from `rest-api.md`,
  `web-socket-api.md` and the 2026-04-02 changelog. Covers REST, WebSocket API and
  SAPI, including the endpoints whose weight depends on parameters: `depth`
  (5/25/50/250 by limit), the ticker family (by symbol count, capped at 200),
  `openOrders` (6 with a symbol, 80 without), `myTrades` (5 with `orderId`, 20
  without), `myPreventedMatches`, `executionRules`, and `order/test`
  (20 with `computeCommissionRates`). Unknown endpoints charge 20 rather than 1,
  because under-charging is what causes bans.
- **`shared_rate_limiter(config)`** — one limiter per `(testnet, api_key)`.
- **`used_capacity(limiter, type, interval_ms=nothing)`** — current consumption,
  for diagnostics and tests.
- **`reconcile_from_headers!`** — adopts `X-MBX-USED-WEIGHT-*` and
  `X-MBX-ORDER-COUNT-*` from REST responses.
- **`finalize_request!(reservation, succeeded)`** — settles a reservation once the
  response is known.

### Fixed
- **Weight accounting** — `REQUEST_WEIGHT` counts weight units. `APILimit` stores
  `(timestamp, cost)` charges plus an incrementally maintained `used` sum, so a
  200-weight request occupies 200 of the 6000/minute budget.
- **Order endpoint classification** — cost is keyed on `(method, path)` instead of
  a substring test. `GET /api/v3/order` (weight 4, no order count) is no longer
  billed to the 50-per-10s order budget, where 60 status queries used to block for
  ten seconds; `POST /api/v3/order` still is. `order/test` and `sor/order/test` are
  charged weight but no order count, since no order is placed.
- **Success-dependent weight** — the endpoints changed on 2026-04-02 reserve their
  documented weight up front and release it on success; a failed request keeps the
  charge, as documented. Order count and raw requests are never refunded.
- **REST never reconciled with the server** — `update_limits!` was only reachable
  from the WebSocket path. REST responses' usage headers are now read on both the
  success and error paths.
- **Shared limiters** — `RESTClient` and `WebSocketClient` now draw on one budget
  per credential instead of one each.
- **`update_limits!` usage sync** — a server `count` of 5000 pushed 5000 timestamps
  all bearing the same instant (allocation proportional to the count, and the whole
  window expiring in one cliff). It is now a single aggregate charge. The function
  also adopts limiters it was not tracking and mutates ceilings in place, rather
  than replacing the vector element and leaving concurrent readers holding a
  detached object.
- **Window maintenance cost** — `expire_charges!` pops the expired prefix
  (amortized O(1) per entry) instead of `filter!` rescanning the window on every
  request, measured at 6.8 ms with 300k `RAW_REQUESTS` entries. Reservation now
  costs ~2 µs.
- **Oversized costs** — a cost exceeding the whole limit is clamped with a warning
  instead of waiting forever for room that cannot exist.
- **Multi-charge waits** — when a request needs more room than the oldest single
  charge would free, the limiter waits for enough charges to expire rather than
  just the first.

### Changed
- `check_and_wait` returns a `RequestReservation`; it previously returned `nothing`.
  The `String` form (used for `CONNECTIONS`) still charges one unit.
- Configured rate-limit values are documented as starting points: the server's
  `rateLimits` array and the usage headers override them. The shipped defaults were
  below the real allowance (50/10s and 160k/day against 100 and 200k) with nothing
  to correct them.

### Tests
- 56 new rate-limit tests (398 → 454), covering weight accounting, method-keyed
  costs, success/failure settlement, every parameter-dependent weight table, header
  reconciliation (including that it never revises downward), server limit
  overrides, limiter sharing, and window expiry.

## [0.14.0] - 2026-09-04

Sync with Binance API changelog 2026-09-02 (FIX API schema update).

### Removed — BinanceFIX
- **`symbol` field on `ListStatusMsg`** — Binance removed the top-level
  `Symbol (55)` from `ListStatus <N>` in the QuickFIX order-entry schema and the
  API documentation; per the earlier announcement, the server had already
  stopped sending it. The documented sample message lost the field too
  (BodyLength 293 → 282).

  `get_list_symbol(msg)` replaces the field. It returns the symbol of the first
  `NoOrders` (73) entry, or `""` when the group is empty (a rejected list may
  have placed nothing). Every leg of an OCO/OTO/OTOCO list trades the same
  symbol, so the first entry is representative. A gateway that still sends the
  legacy field can read it from `raw_fields[TAG_SYMBOL]`.

  `SBEListStatus` (template 102) was unaffected — the binary layout never had a
  top-level symbol.

### Fixed — BinanceFIX
- **`parse_list_status` no longer needs the top-level Symbol to be absent** —
  the parser used tag 55 as the `NoOrders` entry delimiter while also reading it
  as the top-level symbol, distinguished only by group state. Removing the
  top-level read makes the delimiter unambiguous, so both the current and the
  legacy message shape parse to the same order list.

### Tests — BinanceFIX
- `test_list_status.jl` uses the 2026-09-02 sample message, asserts
  `ListStatusMsg` has no `symbol` property, and adds coverage for the legacy
  shape (top-level Symbol present) and for `get_list_symbol` on an empty order
  group. 142 → 152 tests.

### Notes
- **BinanceFIX 0.6.0** — minor bump rather than patch: removing a public struct
  field is a breaking change for callers that read `ListStatusMsg.symbol`.
- No changes to the `Binance` package itself; its 398 tests are unaffected.

## [0.13.0] - 2026-09-02

### Changed
- **Replaced JSON3.jl and StructTypes.jl with JSON.jl 1.x** — JSON3 is marked
  `[deprecated]` upstream. JSON.jl 1.0 absorbed its design and moved struct
  mapping to StructUtils.jl. Both old dependencies are gone; `JSON` and
  `StructUtils` replace them.

  Deserialization now happens through StructUtils field tags instead of
  hand-written `StructTypes.construct` methods. 63 declarations disappeared,
  including all 18 `CustomStruct` types whose `construct` methods did nothing but
  copy fields while lifting a unix-millisecond timestamp:

  | Was | Count | Now |
  |---|---|---|
  | `StructType(T) = Struct()` | 33 | nothing — inferred |
  | `CustomStruct` + timestamp lift | 18 | `@binance_struct` + `&UNIX_MS` |
  | `CustomStruct` + abbreviated keys | 3 | `&(name="E",) &UNIX_MS` |
  | `CustomStruct` + array shape | 3 | `structlike = false` + `lift`/`lower` |
  | `AbstractType` + `subtypekey` | 1 | `JSON.@choosetype` |
  | `Mutable` + `defaults` | 1 | `@noarg` + field defaults |
  | `construct(OrderStatus, str)` | 4 | nothing — enums lift by name |

  A typed parse of an object-shaped response is now **3.7x faster and allocates
  6.2x less** than decode-then-convert (1000 `myTrades`: 0.76 ms / 546 KiB vs
  2.83 ms / 3363 KiB). `exchangeInfo` for 100 symbols is 1.5x faster and
  allocates 2.5x less.

### API changes
- `to_struct(T, value)` no longer consults StructTypes; it forwards to
  `StructUtils.make`. It accepts the same inputs as before (`JSON.Object`,
  `Dict`, `Vector` of either) plus anything `make` accepts. Prefer
  `JSON.parse(bytes, T)` when the bytes are at hand.
- `make_request` returns a `JSON.Object` where it used to return a `JSON3.Object`.
  Both support property access, symbol and string indexing, `haskey`, `get`, and
  `isa AbstractDict`, so call sites that pass the value through are unaffected.
  Code that pattern-matched on `JSON3.Object` explicitly needs updating to
  `AbstractDict`.
- An unknown `filterType` now raises `ArgumentError` naming the value, rather
  than a `FieldError` about an internal NamedTuple. The dispatch table lives in
  `Types.FILTER_TYPES` (unexported).
- `SymbolInfo` is now declared with `@noarg`. `SymbolInfo()` still works.
- `Order.expiryReason` is populated by the Union default rather than a manual
  `haskey` check; behaviour is unchanged.

### Added
- The four strategy example files (`test.jl`, `single_run_test.jl`,
  `test_orderbook_strategy.jl`, `test_convert.jl`) are now tracked. They document
  the high-level entry points; every order-placing call is commented out. They
  still `include` the gitignored `strategy/` directory, so a fresh clone cannot
  run them — `examples/` covers the library itself.
- `@binance_struct` — `StructUtils.@tags` with two field-tag shorthands:
  `&UNIX_MS` for a unix-millisecond timestamp and `&DECIMAL_STR` for a decimal
  carried as a JSON string. Both compose with a `&(name="...",)` rename.
- 285 new deserialization tests (113 → 398). Every migrated type is asserted
  field by field, in both the lazy and materialized paths: a mis-mapped field
  yields a shifted value rather than an error, which the previous suite would not
  have caught.

## [0.12.3] - 2026-09-01

### Fixed
- **`depth()` order-book deserialization** — `OrderBook` was registered as
  `StructTypes.Struct()`, but its `bids`/`asks` elements are `PriceLevel`, which
  is a `CustomStruct`. `StructTypes.constructfrom` has no method for a
  `CustomStruct` element type, so every `depth(ws_client, symbol)` call raised
  `MethodError: no method matching constructfrom(::StructTypes.CustomStruct,
  ::Type{PriceLevel}, ::JSON3.Array{...})`. `OrderBook` now provides explicit
  `construct`/`lower` methods, matching the pattern already used by `Order` and
  `ExchangeInfo`.
- **Signed-request retries** — Signed REST requests are no longer retried by the
  HTTP client. HTTP.jl replays the exact original bytes, so a retry after a
  backoff sleep reuses the original `timestamp`/`signature` and can be rejected
  as `-1021` (outside `recvWindow`); worse, `PUT`/`DELETE` (order amend and
  cancel) are classified as idempotent by the built-in policy and would be
  re-sent against live orders. Public endpoints keep transient-failure retries.
- **Rate-limit escalation** — Added a `retry_if` policy that never retries
  `429`/`418`/`403`. Retrying a rate-limit response escalates the violation
  into an IP ban; the `Retry-After` backoff is recorded on the rate limiter and
  the error is surfaced to the caller instead.
- **Credential leakage on redirect** — REST requests now disable redirect
  following. HTTP.jl only strips the standard credential headers
  (`Authorization`, `Cookie`, ...) across origins, so `X-MBX-APIKEY` would have
  been replayed to whatever host a redirect pointed at.
- **Dead WebSocket connections** — Market streams, the WebSocket API, and SBE
  streams now set `read_idle_timeout`. A silently dropped TCP connection
  previously left the reader blocked forever with no reconnect; it now surfaces
  as a 1006 close and drives the reconnect loop.
- **Reconnect stampede** — Reconnect loops use jittered exponential backoff
  (`RateLimiter.backoff_delay`) instead of a fixed delay, and each WebSocket API
  re-dial reserves a connection-limiter slot. Previously only the first connect
  was accounted for, so a reconnect storm could exceed the 300-connections-per-
  5-minutes limit.
- **`Retry-After` parsing** — The header is read through `HTTP.header`
  (case-insensitive over canonicalized keys) instead of a manual lowercase scan,
  and a non-numeric value now warns instead of throwing `ArgumentError` from
  inside the error handler.
- **Session re-authentication** — `is_authenticated` is no longer cleared when a
  WebSocket API connection drops, so the post-reconnect setup task can still
  detect that it must replay `session.logon` and re-subscribe the user stream.

### Changed
- **Empty proxy semantics** — An empty `proxy` in `config.toml` now means "use
  the standard `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`/`NO_PROXY` environment
  variables" (HTTP.jl's default) instead of forcing a direct connection.
- **Single error path** — REST requests pass `status_exception = false` so every
  non-2xx response reaches `handle_error`, which is now the only place mapping
  Binance error payloads onto exceptions. `401` maps to `UnauthorizedError`, and
  `handle_error` also accepts a bare `BinanceRateLimit` for testability.
- **API key as a client default header** — `X-MBX-APIKEY` is registered as an
  `HTTP.Client` default header instead of being rebuilt for every request.

### Added
- **`close_idle_connections!(rest_client)`** — Drop pooled connections that are
  currently idle (intermediaries silently discard long-idle keep-alives) without
  closing the client.
- **`RateLimiter.backoff_delay`** — Exported helper computing a jittered
  exponential reconnect delay bounded by a cap.

### Performance
- **WebSocket API latency** — `take_response!` now blocks on the response channel
  (bounded by a timer) instead of polling it every 50 ms, removing up to 50 ms of
  latency from every request round-trip. A reply that races the deadline is still
  delivered, and a reply arriving after the deadline is dropped with a debug log
  instead of crashing the socket reader.
- **REST parsing** — JSON is parsed straight from the response byte buffer,
  removing one full copy of every payload.

### Tests
- Added coverage for the reconnect backoff bounds and jitter, the REST
  status-to-exception mapping including `Retry-After` handling, the retry
  policy's refusal to retry rate-limit responses, and `take_response!` waking on
  a late reply / closing its channel on timeout.

## [0.12.2] - 2026-08-21

### Changed
- **REST connection pooling** — `RESTClient` now owns a long-lived
  `HTTP.Client` / `HTTP.Transport` (HTTP.jl 2.x) instead of creating a fresh
  transport per request. TCP/TLS connections and ALPN HTTP/2 sessions are
  reused across calls, and the proxy policy from `config.toml` lives on the
  Transport. Added `Base.close` / `Base.isopen` for lifecycle management;
  requests through a closed client raise `ArgumentError`.

## [0.12.1] - 2026-07-19

### Fixed
- **WebSocket connection limiter** — A successful connection reservation now
  returns immediately instead of looping until all 300 five-minute connection
  slots are consumed and then sleeping for the remainder of the window. This
  fixes Convert and other WebSocket strategies appearing to hang during
  startup.
- **SBE market-stream schema** — The dedicated SBE market-data endpoint uses
  the official `spot_stream` schema `1:0` (`stream_1_0.xml`). The decoder had
  incorrectly enforced the Spot WebSocket API response schema ID `3`, causing
  every production Trade and depth frame to be rejected.

### Tests
- Added regression coverage ensuring a connection attempt reserves exactly one
  limiter slot.
- Added a binary `TradesStreamEvent` fixture encoded with schema `1:0`.

## [0.12.0] - 2026-07-19

### Added
- **Exact decimal order inputs** — Order validation now accepts `String`,
  `FixedDecimal`, and integer inputs through the public `DecimalInput` type,
  avoiding binary floating-point rounding at Binance tick-size and step-size
  boundaries.
- **Configuration loader** — Added the exported `load_config` convenience
  function and documented testnet/FIX endpoint settings in
  `config_example.toml`.
- **Regression coverage** — Added tests for exact filter validation, testnet
  configuration, exported entry points, WebSocket depth events, rate-limit
  accounting, and concurrent order-book access.

### Changed
- **Concurrent client state** — REST caches, WebSocket responses, callbacks,
  subscriptions, and local order-book state are now synchronized. User
  callbacks run outside internal locks to prevent callback code from blocking
  state updates or causing lock re-entry failures.
- **Typed callbacks and sessions** — Replaced dynamically typed callback and
  socket fields with concrete wrappers/types, reducing dispatch overhead and
  making session ownership clearer.
- **FIX/SBE framing performance** — Reduced temporary allocations in integer
  encoding/decoding and tightened message, group, block-length, and buffer
  bounds validation.
- **Task supervision** — FIX and WebSocket monitor tasks are supervised, and
  timed FIX reads no longer leave orphan reader tasks behind.

### Fixed
- **Testnet selection** — Explicit testnet configuration now selects the
  correct REST, WebSocket, market-stream, and FIX endpoints.
- **Public API exports** — Restored all root-module exports that previously
  resolved only in submodules, including FIX SBE session types and order-list
  and cancel-replace helpers.
- **Depth event compatibility** — JSON3 depth events now update
  `OrderBookManager` correctly, with synchronized recovery and snapshot state.
- **Rate-limit accounting** — Corrected `REQUEST_WEIGHT` mapping and ensured
  rate-limit waits do not sleep while holding shared locks.
- **BinanceFIX 0.5.0** — Hardened text FIX and FIX SBE session concurrency,
  receive timeouts, framing checks, monitor lifecycle, and encoder/decoder
  allocation behavior.

### Compatibility
- Julia 1.11 remains the supported runtime for Binance.jl and BinanceFIX.jl.

## [0.11.3] - 2026-07-18

### Changed
- **SBE incremental depth update speed** — Synced with the Binance Spot API
  changelog from 2026-07-17. On 2026-08-04 at approximately 07:00 UTC, the
  SBE WebSocket `<symbol>@depth` stream and FIX SBE
  `MarketDataIncrementalDepth` (templateId `207`) will change from 25ms to
  20ms. Stream names and binary layouts are unchanged. Documentation now
  distinguishes these feeds from the 50ms SBE `@depth20` snapshot stream and
  the 100ms text FIX incremental-depth stream.
- **BinanceFIX 0.4.1** — Updated the FIX SBE incremental-depth documentation
  for the same 20ms rollout; no template or decoder-layout changes are needed.

## [0.11.2] - 2026-07-02

### Changed
- **Spot SBE schema 3:5 / symbolStatus `CANCEL_ONLY`** — Synced with the
  Binance Spot changelog from 2026-07-01. `SymbolStatus` now includes
  `CANCEL_ONLY`, REST and WebSocket API `exchangeInfo` accept it as a
  `symbolStatus` filter, and SBE docs/constants mark schema 3:5 as current for
  the 2026-07-07 rollout.

## [0.11.1] - 2026-06-27

### Changed
- **Network timeout handling** — REST requests now apply the configured
  connection timeout across connect, overall request, and read-idle phases.
  WebSocket API, JSON market-data streams, and SBE market-data streams now use
  the configured timeout for connection handshakes and the configured
  reconnect delay for retry sleeps.
- **Async task supervision** — WebSocket connection, heartbeat, setup, and SBE
  stream tasks are now wrapped with `errormonitor` so background failures are
  surfaced instead of being silently lost. The SBE stream session no longer
  starts a no-op ping/pong task.
- **SBE production lifecycle docs** — Synced with the Binance API changelog
  from 2026-06-22. Production schema 3:1 is now documented as retiring on
  2026-06-29; schema 3:4 remains current. The decoder already targets 3:4 and
  keeps older market-data template layouts tolerant for historical payloads.

### Fixed
- **WebSocket API response waits** — Request/response calls now use a bounded
  wait based on the configured timeout instead of blocking forever if a response
  is lost. Sequential request ID generation now explicitly calls `Base.time()`
  to avoid the module's `time(client)` API method shadowing the Base function.

### Tests
- Added regression coverage for ready WebSocket API response handling and the
  positive timeout floor used by WebSocket clients.

## [0.11.0] - 2026-06-11

Sync with Binance API changelog 2026-06-10 (FIX API documentation updates).

### Removed — BinanceFIX
- **`last_fragment` field on `MarketDataIncrementalMsg`** — Binance removed
  LastFragment (893) from the FIX API field list and the QuickFIX MD schema.
  MarketDataIncrementalRefresh `<X>` messages stopped being fragmented on
  2025-12-18 and the server no longer sends the field (the struct field had
  been marked deprecated since then). The parser no longer reads tag 893 and
  the `TAG_LAST_FRAGMENT` constant was removed.

### Fixed — BinanceFIX
- **News `<B>` maintenance detection** — per the updated News `<B>`
  documentation (2026-06-09 announcement), the server sends countdown
  headlines "You'll be disconnected in %d seconds. Please reconnect." and,
  at 10 seconds remaining, "Your connection is about to be closed. Please
  reconnect.", with Headline (148) as the only field. `is_maintenance_news`
  previously missed the final warning (it only matched "reconnect" in
  Text (58), which is not sent), and the SBE session only matched
  "maintenance", missing both countdown messages. Both now match
  maintenance/disconnect/reconnect in either Headline or Text, so
  `on_maintenance` fires for every documented countdown message.
- **News `<B>` docs** — `parse_news` docstring and `NewsMsg` comments now
  describe the 10-second countdown semantics and note that Text (58) and
  Urgency (61) are parsed defensively and may be empty.

## [0.10.1] - 2026-06-09

### Changed
- **`serverShutdown` reconnect behavior** — WebSocket API, JSON market-data
  streams, and SBE market-data streams now close the current socket when
  `serverShutdown` is received, allowing existing reconnect loops to open a new
  connection promptly. Documentation treats the event as an immediate reconnect
  signal.
- **SBE market-data stream docs** — Documented that `serverShutdown` arrives as
  JSON in WebSocket text frames even on SBE connections.
- **Reference-price calculation docs** — `ExternalCalculation` now treats
  `externalCalculationId` as an extensible Binance-defined method identifier so
  newly documented external calculation methods do not imply a client schema
  change.
- **Package dependencies** — Removed the unused `DataFrames` dependency from
  the main package and added regression coverage to ensure WebSocket kline rows
  use plain `NamedTuple` values without loading DataFrames.

## [0.10.0] - 2026-06-02

### Added
- **Block Trade WebSocket Stream** (2026-05-12 rollout) — New
  `<symbol>@blockTrade` market data stream pushing one event per off-book
  block trade. Public entry point:
  `subscribe_block_trade(client, symbol, callback)`; payload deserialized
  to a new `WebSocketBlockTrade` struct (same fields as `WebSocketTrade`
  minus the `M` best-match flag).

### Added — BinanceFIX
- **SBE encoder NewOrderList (templateId=100)** — was previously decode-only;
  OCO/OTO/OTOCO/OPO order lists can now be placed over an SBE Order Entry
  session. New `OrderListEntry` keyword struct mirrors the per-order fields
  including nested `ListTriggeringInstructions`. Public entry point:
  `new_order_list_sbe(session, cl_list_id, contingency_type, orders; opo)`.
- **SBE encoder OrderCancelRequestAndNew/XCN (templateId=97)** — atomic
  cancel-replace at SBE latency; previously only available on the text-FIX
  path. Public entry point: `order_cancel_request_and_new_sbe(...)`.
- **`expiry_reason` field on text-FIX `ExecutionReportMsg`** — new struct
  field plus parser extraction for tag 25056 (was already present in the SBE
  decoder since 0.9.0). Eight enum constants exported:
  `EXPIRY_REJECTED` … `EXPIRY_EXECUTION_RULE_PRICE_RANGE_EXCEEDED`.
- **`recv_window` keyword on text-FIX `order_amend_keep_priority` and
  `limit_query`** — parity with the SBE encoders.
- **`aggregated_book` keyword on `encode_market_data_request`** — exposes the
  optional AggregatedBook field (tag 266) defined by the spec but missing
  from the previous encoder.
- **Regression tests** — `BinanceFIX/test/test_sbe_schema11.jl` covers
  blockLength values, schema-version stamping, multi-fee parsing, and the
  expiry_reason extraction path.

### Changed — BinanceFIX
- **SBE encoder migrated from schema 1:0 to 1:1 (current)**.
  `SBE_SCHEMA_VERSION_FIX` bumped from 0 → 1; messages now advertise version 1
  in the header. Schema 1:0 was deprecated 2026-03-09 and is expected to
  retire ~6 months later. All encoders rewritten to match the 1:1 layout:
  - `encode_new_order_single` (id=99): root block now leads with
    `PriceExponent`/`QtyExponent`, `OrderQty` is optional, `Side` and
    `TimeInForce` move past the trigger/peg blocks, `PegOffsetValue` is
    `uint8` (was `int64`), `RecvWindow` removed (it's only on Logon in 1:1).
    New keywords for full peg coverage: `peg_move_type`, `peg_offset_type`,
    `trigger_type`, `trigger_action`, `trigger_price_type`.
  - `encode_logon` (id=20008): added `execution_report_type`, `RecvWindow`
    moved last and changed to `uint32 durationUs`, `Username`/`RawData`
    promoted to `varString` (uint16 prefix), data field order corrected,
    `UUID` removed (it's on `LogonAck` in the schema).
  - `encode_order_amend_keep_priority` (id=105): now writes the `QtyExponent`
    that 1:1 requires; `RecvWindow` removed.
  - `encode_order_cancel_request` / `encode_order_mass_cancel_request`:
    `RecvWindow` removed (not in 1:1).
  - `encode_market_data_request`: `MarketDepth` is `uint16` (was `uint32`),
    `RelatedSym` group entries no longer interleaved with `MDEntryTypes`.
- **`SBEBuffer.block_length`** — explicit field set by `mark_block_end!(buf)`
  after writing fixed fields. `encode_message_header!` writes that as the
  root `blockLength`. The previous encoder reported the entire body as
  `blockLength`, which would misalign a strict SBE decoder on every message
  with groups or var data.
- **`parse_misc_fees(fields, msg)`** — now takes the raw FIX message string
  and recovers every entry in the NoMiscFees group (tag 136). Previously a
  message with N>1 fees collapsed into a single dict slot and the parser
  emitted only one fee. The 1-arg call still works as a single-fee fallback.

### Migration notes
- Callers of `encode_*_sbe` should drop the `recv_window` keyword on
  `order_cancel_request_sbe`, `order_mass_cancel_request_sbe`,
  `order_amend_keep_priority_sbe`, and `new_order_single_sbe` — it has been
  removed (set `recv_window` on `logon_sbe` once per session instead).
- `quantity` on `new_order_single_sbe` is now `Union{Float64,Nothing}` so
  callers can pass `cash_order_qty=...` for reverse-quote market orders.
- `OrderID`-shaped keywords on cancel/amend/XCN encoders are now `Int64`
  (was `UInt64`) to match the schema's `ordId` type.

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
  connections, logs a warning, and lets reconnect handling refresh the
  connection. The WebSocket API path already had this event type.

### Changed
- **SBE schema 3:3 → 3:4** — Bumped current schema version constants in
  `SBEDecoder.jl` (`SCHEMA_VERSION_CURRENT = 4`); 3:3 marked deprecated as of
  2026-05-08. Market-data template IDs (10000–10003)
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
