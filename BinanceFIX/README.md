# BinanceFIX.jl

A Julia SDK for Binance FIX 4.4 Protocol trading.

## Overview

BinanceFIX.jl provides complete FIX protocol support for Binance Spot trading:
- **Order Entry** sessions for order placement, cancellation, and amendments
- **Drop Copy** sessions for read-only execution reports
- **Market Data** sessions for FIX-based market data streams
- **FIX SBE** support for high-performance binary encoding (ports 9001/9002)

## Recent Updates

### v0.7.0 - Changelog Sync 2026-11-11 (2026-11-18)

- **`QuoteNotionalLimit (25057)`** — `new_order_single` and
  `order_cancel_and_new_order` take `quote_notional_limit`; `new_order_list`
  orders take `:quote_notional_limit`. BUY orders only; combining it with
  `CashOrderQty`, `SOR` or `ExecInst=6` is rejected before sending.
  `ExecutionReportMsg.quote_notional_limit` returns it. Binance enables the
  feature some time after 2026-11-20 07:00 UTC.
- **`EffectiveSelfTradePreventionMode (25058)`** —
  `ExecutionReportMsg.effective_self_trade_prevention`, and
  `get_stp_info(msg).effective_self_trade_prevention_mode`, which falls back to
  the order's own mode because the tag is only sent when the two differ.
- **`ExpiryReason`** gains `EXPIRY_EXHAUSTED` (`9`) and
  `EXPIRY_INSUFFICIENT_QUOTE_NOTIONAL_LIMIT` (`10`).
- **FIX SBE schema `1:2`, opt-in** — `SBESession(...; schema_version=SBE_SCHEMA_VERSION_FIX_V2)`.
  Sessions default to `1:1`, see [schema versions](#fix-sbe-schema-versions).
- `SBEExecutionReport.expiry_reason` is now read at its schema offset; it was
  previously read from the wrong position in the block.
- **Direct TLS; stunnel support removed** — sessions connect straight to
  `fix-*.binance.com`, and `stunnel.conf` / `stunnel-binance.service` are gone.
  A `[fix]` section pointing at `127.0.0.1` must be changed or removed. See
  [Connecting](#connecting).
- **FIX SBE decoders rewritten per schema (breaking)** — every response decoder
  now follows `spot-fixsbe-1_2.xml` and is tested against messages captured
  from the testnet gateway. Enum fields hold the wire value (`UInt8('1')` =
  BUY), IDs are `Int64`, and null fields are `nothing`. See
  [decoded values](#sbe-decoded-values).
- **Session helpers** — `with_fix_session`, `pump_messages`,
  `new_sender_comp_id` and the SBE equivalents `with_sbe_session`,
  `pump_sbe_messages`. See [Session Helpers](#session-helpers).
- **Decimal formatting** — order prices and quantities are written as plain
  decimals; small values used to be sent in exponent form (`1.0e-5`).
- **Ctrl-C** — the receive loops no longer swallow `InterruptException`.
- **FIX SBE requests fixed** — char enums are sent as characters, absent fields
  use the SBE null values, and Heartbeat / TestRequest / Logout / LimitQuery
  declare `blockLength` 0 (the gateway answered `-1221` and dropped the
  session before).
- **Receiving works** — incoming data is now read by a background task. The
  previous loop polled `bytesavailable`, which never reports data on an idle
  Julia socket, so `logon` could only time out.
- **FIX SBE logon fixes** — the signature now uses the same instant as the
  header `SendingTime`, with microsecond precision (the gateway answered
  `-1022` otherwise), and `LogonAck` / `Reject` are decoded per schema, so a
  refused logon reports its reason.

### v0.6.1 - ExpiryReason documentation sync (2026-10-30)

Binance added the previously announced `ExpiryReason (25056)` field to its
FIX API documentation. The existing text-FIX and FIX SBE parsers already
expose `expiry_reason`; see [field values and representations](#execution-report-expiry-reason).
No wire-format or parser change is required by this notice.

### v0.6.0 - Changelog Sync 2026-09-02

- **Top-level `Symbol (55)` removed from `ListStatus <N>`** — Binance removed the
  field from the QuickFIX order-entry schema and the API docs; as the earlier
  announcement stated, the server had already stopped sending it. The
  `ListStatusMsg.symbol` field is gone. Use `get_list_symbol(msg)`, which reads
  the symbol from the first `NoOrders` (73) entry — all legs of an
  OCO/OTO/OTOCO list trade the same symbol. The parser no longer treats a
  top-level tag 55 as a group delimiter, so a gateway that still sends it
  parses correctly instead of producing a phantom first order.

### v0.5.0 - Session concurrency and SBE hardening

- **Safe session lifecycle** — Text FIX and FIX SBE sockets, sequence state,
  callbacks, and monitor tasks now use concrete types, synchronization, and
  supervised background tasks.
- **Bounded receives** — Receive timeouts no longer create orphan reader
  tasks, and concurrent reads/writes are serialized around each session.
- **Strict binary framing** — SBE decoders validate message lengths,
  block lengths, group dimensions, and buffer bounds before accessing fields.
- **Lower allocation codecs** — Integer encoding and decoding avoids temporary
  byte arrays in the optimized FIX SBE paths.
- **Public API fixes** — Root exports now include SBE session variants,
  `new_order_list_sbe`, and `order_cancel_request_and_new_sbe`.

### v0.4.1 - FIX SBE incremental depth 20ms rollout

- **`MarketDataIncrementalDepth` cadence** — Binance will change FIX SBE
  incremental depth responses from 25ms to 20ms on 2026-08-04 at
  approximately 07:00 UTC. The template remains `207`; only the delivery
  cadence changes. Applications should budget for roughly 25% more depth
  callbacks. The text FIX incremental depth stream remains 100ms.

### v0.4.0 - Changelog Sync 2026-06-10

- **`LastFragment (893)` removed** — Binance removed the field from the FIX
  API field list and the QuickFIX MD schema. The `last_fragment` field was
  dropped from `MarketDataIncrementalMsg`, tag 893 is no longer parsed, and
  the `TAG_LAST_FRAGMENT` constant was removed.
- **News `<B>` countdown handling** — during maintenance the server sends a
  News message every 10 seconds counting down to disconnection, with
  Headline (148) as the only field. `is_maintenance_news` and the SBE
  session now match all documented countdown headlines (previously the
  final "Your connection is about to be closed. Please reconnect." warning
  was missed), so `on_maintenance` fires for every countdown message.

### v0.3.0 - FIX SBE schema 1:1 encoder support (2026-06-02)

- SBE request encoders now target FIX SBE schema 1:1 and stamp version 1 in
  message headers.
- Added SBE `NewOrderList` support via `new_order_list_sbe` for
  OCO/OTO/OTOCO/OPO order lists.
- Added SBE atomic cancel-replace support via
  `order_cancel_request_and_new_sbe`.
- Text-FIX `ExecutionReportMsg` now carries `expiry_reason`, and multi-fee
  execution reports preserve every fee entry.
- `recv_window` is now available on text-FIX `order_amend_keep_priority` and
  `limit_query`; SBE request `recv_window` is set on `logon_sbe`.

## Installation

BinanceFIX.jl is a sub-package of Binance.jl:

```julia
using Pkg
Pkg.add("https://github.com/rzhli/Binance.jl.git")

# Then in your project
using Binance
using BinanceFIX
```

## Quick Start

### Configuration

Use the same `config.toml` as Binance.jl with Ed25519 keys:

```toml
[api]
api_key = "YOUR_API_KEY"
signature_method = "ED25519"
private_key_path = "key/ed25519-private.pem"
private_key_pass = "YOUR_PASSWORD"
```

### Basic Usage

```julia
using Binance
using BinanceFIX

# Load config
config = Binance.load_config("config.toml")
sender_comp_id = "your_sender_id"

# Create Order Entry session
session = FIXSession(config, sender_comp_id; session_type=OrderEntry)

# Connect and logon
connect_fix(session)
logon(session)

# Start connection monitor (heartbeat)
start_monitor(session)

# Place a limit order
cl_ord_id = new_order_single(session, "BTCUSDT", SIDE_BUY;
    quantity=0.001, price=50000.0, order_type=ORD_TYPE_LIMIT)

# Cancel order
order_cancel_request(session, "BTCUSDT", cl_ord_id)

# Query rate limits
limit_query(session)

# Cleanup
stop_monitor(session)
logout(session)
close_fix(session)
```

### Session Helpers

For scripts and strategies, three helpers cover the connect / logon / receive /
logout cycle:

```julia
import Binance
using BinanceFIX

config = Binance.from_toml("config.toml"; testnet=true)

# Connect + logon, run the block, then logout + close (also on errors)
with_fix_session(config, MarketData) do session
    subscribe_book_ticker(session, ["BTCUSDT"])
    # Receive for 5 seconds; answers TestRequests and sends Heartbeats itself
    pump_messages(session, 5) do type, data
        type == :market_data_incremental && println(data.entries)
    end
end
```

- `new_sender_comp_id()` — random 8-character SenderCompID (the default of
  `with_fix_session`).
- `with_fix_session(f, config, session_type=OrderEntry; ...)` — returns what `f`
  returns; extra keywords go to `logon`.
- `pump_messages(handle, session, seconds)` — calls `handle(type, data)` with
  what `process_message` returns. Call it in a loop to keep a session alive;
  do not also run `start_monitor` on that session, both would read the same
  messages.
- FIX SBE equivalents: `with_sbe_session`, `pump_sbe_messages`.

Use `import Binance`, not `using Binance`, next to `using BinanceFIX`: both
packages export names such as `subscribe_book_ticker`, and with two `using`s
those names become ambiguous.

Prices and quantities are sent as plain decimals with at most 8 places
(`fix_decimal`); Julia's `string(0.00001)` would give `1.0e-5`.

## Session Types

### Order Entry
For placing, canceling, and amending orders:

```julia
session = FIXSession(config, sender_comp_id; session_type=OrderEntry)
```

### Drop Copy
Read-only execution reports for monitoring:

```julia
session = FIXSession(config, sender_comp_id; session_type=DropCopy)
```

### Market Data
FIX-based market data streams:

```julia
session = FIXSession(config, sender_comp_id; session_type=MarketData)

# Subscribe to book ticker
subscribe_book_ticker(session, "BTCUSDT")

# Subscribe to depth stream
subscribe_depth_stream(session, "BTCUSDT"; depth=10)

# Subscribe to trade stream
subscribe_trade_stream(session, "BTCUSDT")
```

## FIX SBE Support

BinanceFIX supports FIX SBE (Simple Binary Encoding) for high-performance trading:

- **Port 9001**: FIX text request → FIX SBE response (Hybrid mode)
- **Port 9002**: FIX SBE request → FIX SBE response (Full SBE mode, lowest latency)

### FIX SBE Full Mode (Pure Binary)

For the lowest latency, use the `SBESession` for pure SBE request/response:

```julia
using Binance
using BinanceFIX

# Load config
config = Binance.load_config("config.toml"; testnet=true)
sender_comp_id = "your_sender_id"

# Create SBE Order Entry session (port 9002)
session = SBESession(config, sender_comp_id; session_type=SBEOrderEntry)

# Connect and logon
connect_sbe(session)
logon_sbe(session)

# Start connection monitor
start_sbe_monitor(session)

# Place a limit order. Enums are the FIX characters: '1' = BUY, '2' = LIMIT, '1' = GTC
cl_ord_id = new_order_single_sbe(session, "BTCUSDT", UInt8('1');
    quantity=0.001, price=50000.0, order_type=UInt8('2'), time_in_force=UInt8('1'))

# Atomic cancel-replace (mode 1 = STOP_ON_FAILURE)
order_cancel_request_and_new_sbe(session, "BTCUSDT", UInt8('1'), UInt8('2'), UInt8(1);
    orig_cl_ord_id=cl_ord_id, quantity=0.001, price=50100.0,
    time_in_force=UInt8('1'))

# Cancel order
order_cancel_request_sbe(session, "BTCUSDT"; orig_cl_ord_id=cl_ord_id)

# Mass cancel all orders for symbol
order_mass_cancel_request_sbe(session, "BTCUSDT")

# Query rate limits
limit_query_sbe(session)

# Process incoming messages
messages = process_sbe_messages(session)
for (msg_type, decoded) in messages
    if msg_type == :execution_report
        println("Order: $(decoded.cl_ord_id) Status: $(Char(decoded.ord_status))")
        decoded.exec_type == UInt8('F') && println("  filled $(decoded.last_qty) @ $(decoded.last_px)")
    elseif msg_type == :execution_report_ack
        println("Ack: $(decoded.cl_ord_id)")
    end
end

# Cleanup
stop_sbe_monitor(session)
logout_sbe(session)
close_sbe(session)
```

### SBE Session Types

```julia
# Order Entry - for placing, canceling, amending orders
session = SBESession(config, sender_comp_id; session_type=SBEOrderEntry)

# Drop Copy - read-only execution reports
session = SBESession(config, sender_comp_id; session_type=SBEDropCopy)

# Market Data - market data streams
session = SBESession(config, sender_comp_id; session_type=SBEMarketData)

# Subscribe to market data
market_data_request_sbe(session, ["BTCUSDT", "ETHUSDT"];
    entry_types=[UInt8('0'), UInt8('1')])  # '0' = Bid, '1' = Offer

# Get instrument list
instrument_list_request_sbe(session)
```

### SBE Order Lists

```julia
# OCO SELL: stop-loss-limit below the market, limit-maker above it.
# The limit-maker leg must not carry TimeInForce (the gateway answers -1106).
orders = [
    OrderListEntry(cl_ord_id="oco-stop", symbol="BTCUSDT", side=UInt8('2'),
        ord_type=UInt8('4'), quantity=0.001, price=47900.0, trigger_price=48000.0,
        trigger_type=UInt8('4'), trigger_action=UInt8('1'), trigger_price_type=UInt8('2'),
        trigger_price_direction=UInt8('D'), time_in_force=UInt8('1'),
        list_triggering_instructions=[(UInt8('2'), UInt8(1), UInt8('2'))]),
    OrderListEntry(cl_ord_id="oco-limit", symbol="BTCUSDT", side=UInt8('2'),
        ord_type=UInt8('2'), quantity=0.001, price=52000.0, exec_inst=UInt8('6'),
        list_triggering_instructions=[(UInt8('1'), UInt8(0), UInt8('2'))]),
]

new_order_list_sbe(session, "list-1", UInt8(1), orders)   # 1 = OCO
```

<a id="sbe-decoded-values"></a>
### SBE Decoded Values

Decoded messages follow the schema (`spot-fixsbe-1_1.xml` / `1_2.xml`):

- **Enums keep their wire value as `UInt8`.** Most are ASCII characters, the
  same ones text FIX uses: `side == UInt8('1')` (BUY), `ord_type == UInt8('2')`
  (LIMIT), `exec_type == UInt8('F')` (TRADE), `ord_status == UInt8('2')`
  (FILLED). A few are small integers: `ord_rej_reason`, `expiry_reason`,
  `working_floor`, `peg_move_type`, list status fields, and the booleans
  (`0`/`1`).
- **Optional fields are `nothing`** when the gateway sent no value.
- **IDs are `Int64`**, timestamps are microseconds since the Unix epoch.
- **Decimals** are converted with the exponent carried in the message.
- **Market data** entries have `entry_type` `SBE_MD_ENTRY_BID`,
  `SBE_MD_ENTRY_OFFER` or `SBE_MD_ENTRY_TRADE`; a depth entry with
  `size === nothing` carries no size.

Request functions accept either the character (`UInt8('1')`) or the bare digit
(`UInt8(1)`) for char enums; `char_enum` converts.

### Decoding Raw FIX SBE Messages

`process_sbe_messages` decodes for you. To work with the raw bytes instead
(`receive_sbe_message` returns one complete message per element):

```julia
for data in receive_sbe_message(session; timeout_ms=500)
    msg_type, decoded = decode_sbe_message(data)
    if msg_type == :execution_report
        println("Order ID: ", decoded.order_id)
        println("ClOrdId: ", decoded.cl_ord_id)
        println("Status: ", Char(decoded.ord_status))
        println("CumQty: ", decoded.cum_qty)
    end
end
```

Hybrid mode (port 9001: FIX text requests, SBE responses) has no session type
in this package; `FIXSession` reads text responses only.

### SBE Message Format

```
<SOFH (6 bytes)> <Message Header (20 bytes)> <Message Body (N bytes)>

SOFH:
- messageLength: uint32 (total length including SOFH)
- encodingType: uint16 (0xEB50 for little-endian)

Message Header:
- blockLength: uint16
- templateId: uint16
- schemaId: uint16 (1 for FIX SBE)
- version: uint16 (the session's schema version: 1 for schema 1:1, 2 for 1:2)
- seqNum: uint32
- sendingTime: int64 (microseconds since epoch)
```

### SBE Decoded Message Types

| Message Type | Template ID | Description |
|--------------|-------------|-------------|
| `SBELogonAck` | 20009 | Logon acknowledgment |
| `SBELogout` | 20004 | Logout message |
| `SBEHeartbeat` | 20001 | Heartbeat message |
| `SBEReject` | 20003 | Session reject |
| `SBEExecutionReport` | 98 | Full execution report |
| `SBEExecutionReportAck` | 198 | Mini execution report (OnlyAcks mode) |
| `SBEOrderCancelReject` | 96 | Cancel reject |
| `SBEListStatus` | 102 | Order list status |
| `SBEOrderMassCancelReport` | 104 | Mass cancel report |
| `SBELimitResponse` | 121 | Rate limit query response |
| `SBEMarketDataSnapshot` | 204 | Market data snapshot |
| `SBEMarketDataIncrementalTrade` | 205 | Incremental trade updates |
| `SBEMarketDataIncrementalBookTicker` | 206 | Incremental book ticker |
| `SBEMarketDataIncrementalDepth` | 207 | Incremental depth updates |
| `SBEInstrumentList` | 201 | Instrument list response |

## Order Types

### Single Orders

```julia
# Market order
new_order_single(session, "BTCUSDT", SIDE_BUY;
    quantity=0.001, order_type=ORD_TYPE_MARKET)

# Limit order
new_order_single(session, "BTCUSDT", SIDE_BUY;
    quantity=0.001, price=50000.0, order_type=ORD_TYPE_LIMIT)

# Stop-limit order
new_order_single(session, "BTCUSDT", SIDE_SELL;
    quantity=0.001, price=49000.0, stop_price=49500.0,
    order_type=ORD_TYPE_STOP_LIMIT)
```

### Order Lists (OCO, OTO, OTOCO)

```julia
# OCO (One-Cancels-Other)
orders = create_oco_sell("BTCUSDT", 0.001, 52000.0, 48000.0, 47900.0)
new_order_list(session, orders; contingency_type=CONTINGENCY_OCO)

# OTO (One-Triggers-Other)
orders = create_oto("BTCUSDT", SIDE_BUY, 0.001, 50000.0, 52000.0)
new_order_list(session, orders; contingency_type=CONTINGENCY_OTO)
```

## Message Processing

```julia
# Receive and process messages
while true
    msg = receive_message(session)
    if !isnothing(msg)
        result = process_message(session, msg)

        msg_type, data = result
        if msg_type == :execution_report
            println("Order: ", data.cl_ord_id, " Status: ", data.ord_status)
        elseif msg_type == :list_status
            println("List: ", data.list_id, " Status: ", data.list_status_type)
        end
    end
    sleep(0.01)
end
```

### Execution Report Expiry Reason

[`ExecutionReport <8>`](https://developers.binance.com/docs/binance-spot-api-docs/fix-api#executionreport-8)
has an optional integer field, `ExpiryReason (25056)`, which appears only for
expired orders. Binance documented it on 2026-10-27 after announcing it on
2026-03-09.

| Value | Exported text-FIX constant |
|-------|---------------------------|
| `1` | `EXPIRY_REJECTED` |
| `2` | `EXPIRY_EXCHANGE_CANCELED` |
| `3` | `EXPIRY_OCO_TRIGGER` |
| `4` | `EXPIRY_OTO_PHASE_ONE_EXPIRED` |
| `5` | `EXPIRY_UNFILLED_IOC_QUANTITY_EXPIRED` |
| `6` | `EXPIRY_UNFILLED_FOK_ORDER_EXPIRED` |
| `7` | `EXPIRY_INSUFFICIENT_LIQUIDITY` |
| `8` | `EXPIRY_EXECUTION_RULE_PRICE_RANGE_EXCEEDED` |

| `9` | `EXPIRY_EXHAUSTED` (since 2026-11-11: amended down to the filled quantity or less) |
| `10` | `EXPIRY_INSUFFICIENT_QUOTE_NOTIONAL_LIMIT` (since 2026-11-11) |

- Text FIX: `ExecutionReportMsg.expiry_reason` preserves the wire value as a
  `String` (`"1"`–`"10"`), or `""` when tag 25056 is absent. The `EXPIRY_*`
  constants are strings, so they can be compared directly with this field.
- FIX SBE: `SBEExecutionReport.expiry_reason` is `Union{UInt8,Nothing}`
  (`UInt8(1)`–`UInt8(10)`, or `nothing` for an absent/null value). For example,
  compare with `UInt8(8)` for `EXECUTION_RULE_PRICE_RANGE_EXCEEDED`. Values `9`
  and `10` are only defined from schema `1:2` on.

### Quote Notional Limit and Effective STP Mode

Added by Binance on 2026-11-11, effective after 2026-11-20 07:00 UTC.

`QuoteNotionalLimit (25057)` caps the quote asset a BUY order may consume while
keeping its quantity. See Binance's
[quoteNotionalLimit FAQ](https://developers.binance.com/docs/binance-spot-api-docs/faqs/quoteNotionalLimit).

```julia
# Buy up to 1 BTC, spending at most 60000 USDT
new_order_single(session, "BTCUSDT", SIDE_BUY;
    order_type=ORD_TYPE_MARKET, quantity=1.0, time_in_force="",
    quote_notional_limit=60000.0)

# In an order list the limit belongs to one order
orders[1][:quote_notional_limit] = 250.0
```

Rules checked before the message is sent: BUY side only; not together with
`CashOrderQty (152)`, `SOR (25032)` or `ExecInst (18) = 6`. The exchange
additionally rejects the tag on OPO/OPOCO pending orders and on symbols without
`marketQuoteNotionalLimitAllowed` / `limitQuoteNotionalLimitAllowed`.

`ExecutionReport <8>` echoes the limit in `quote_notional_limit` (only if the
order was placed with one). On prevented-match reports it may also carry
`EffectiveSelfTradePreventionMode (25058)` — `3` EXPIRE_MAKER, `4` EXPIRE_BOTH
or `5` DECREMENT — when the mode the engine applied differs from the order's
`SelfTradePreventionMode (25001)`.

<a id="fix-sbe-schema-versions"></a>
### FIX SBE Schema Versions

| Schema | Status | Selected with |
|--------|--------|---------------|
| `1:1` (`spot-fixsbe-1_1.xml`) | Deprecated by the 2026-11-11 notice, retired six months later; still the session default | `SBESession(config, id)` |
| `1:2` (`spot-fixsbe-1_2.xml`) | Published 2026-11-11, rolled out gradually | `SBESession(config, id; schema_version=SBE_SCHEMA_VERSION_FIX_V2)` |

The version is fixed per session and written to every request header. `1:1`
stays the default because the rollout takes about two weeks and the
[production lifecycle file](https://github.com/binance/binance-spot-api-docs/blob/master/sbe/schemas/sbe_fix_schema_lifecycle_prod.json)
still listed `1:1` as latest on 2026-11-13; a gateway that does not know `1:2`
rejects it with `-1153`. Switch once that file lists `1:2`, and before `1:1`
is retired.

Schema `1:2` appends `QuoteNotionalLimit` to `NewOrderSingle`,
`OrderCancelRequestAndNewOrderSingle` and the `NewOrderList` orders
(`quote_notional_limit` on `new_order_single_sbe`,
`order_cancel_request_and_new_sbe` and `OrderListEntry`), and
`QuoteNotionalLimit` / `EffectiveSelfTradePreventionMode` to `ExecutionReport`
(`SBEExecutionReport.quote_notional_limit`,
`.effective_self_trade_prevention_mode`). Requesting a quote notional limit on
a `1:1` session throws instead of dropping the field.

## Constants

```julia
# Side
SIDE_BUY, SIDE_SELL

# Order Types
ORD_TYPE_MARKET, ORD_TYPE_LIMIT, ORD_TYPE_STOP, ORD_TYPE_STOP_LIMIT

# Time In Force
TIF_GTC, TIF_IOC, TIF_FOK

# Order Status
ORD_STATUS_NEW, ORD_STATUS_FILLED, ORD_STATUS_CANCELED, ORD_STATUS_REJECTED

# Contingency Types
CONTINGENCY_OCO, CONTINGENCY_OTO
```

## Examples

See `examples/` directory:
- `examples_fixapi.jl` - Comprehensive FIX API examples
- `examples_order_lists.jl` - OCO, OTO, OTOCO order lists
- `fix_api_example.jl` - Complete session lifecycle

## Architecture

```
BinanceFIX/
├── src/
│   ├── BinanceFIX.jl       # Main module with exports
│   ├── FIXAPI.jl           # FIX text session and order entry
│   ├── FIXConstants.jl     # FIX field tags and constants
│   ├── FIXSBEDecoder.jl    # FIX SBE binary decoder
│   ├── FIXSBEEncoder.jl    # FIX SBE binary encoder
│   └── FIXSBESession.jl    # FIX SBE session management
├── test/                   # Test suite
├── examples/               # Usage examples
└── README.md               # This file
```

## Connecting

Binance FIX requires TLS with SNI. BinanceFIX does the handshake itself and
verifies the certificate. The `[fix]` section defaults to the hosts and ports
below, so it only needs to be written out to change them:

```toml
[fix]
order_entry_host = "fix-oe.binance.com"
drop_copy_host = "fix-dc.binance.com"
market_data_host = "fix-md.binance.com"
order_entry_port = 9000              # FIX text
order_entry_sbe_hybrid_port = 9001   # FIX text requests, SBE responses
order_entry_sbe_full_port = 9002     # SBE both ways
# ...the same three ports for drop_copy_* and market_data_*
```

`config_example.toml` has the full section, including `[fix_testnet]`
(`fix-*.testnet.binance.vision`, same ports).

To check reachability from your network:

```bash
openssl s_client -connect fix-oe.binance.com:9000 -servername fix-oe.binance.com -verify_return_error -brief </dev/null
```

### Endpoints

| Service | Host | FIX text | SBE hybrid | SBE full |
|---------|------|----------|------------|----------|
| Order Entry | `fix-oe.binance.com` | 9000 | 9001 | 9002 |
| Drop Copy | `fix-dc.binance.com` | 9000 | 9001 | 9002 |
| Market Data | `fix-md.binance.com` | 9000 | 9001 | 9002 |

Testnet uses `fix-oe` / `fix-dc` / `fix-md.testnet.binance.vision` with the
same ports. `FIXSession` uses the FIX text port and `SBESession` the SBE full
port of its service.

### API Key Setup

FIX needs an Ed25519 API key with the `FIX_API` permission:

```bash
mkdir -p key
openssl genpkey -algorithm ED25519 -out key/ed25519-private.pem
openssl pkey -in key/ed25519-private.pem -pubout -out key/ed25519-public.pem
```

Upload `key/ed25519-public.pem` in Binance API Management, enable `FIX_API`,
and whitelist the public IP you connect from. Then copy `config_example.toml`
to `config.toml` and set the API key and key path.

Binance refuses service from restricted locations: a FIX logon from such an IP
is answered with "You are not authorized to execute this request", and REST
with HTTP 451.

## Requirements

- Julia 1.11+
- Binance.jl (parent package)
- Ed25519 API key with FIX_API permission
- Network access to `fix-*.binance.com` on ports 9000–9002 (TLS is handled by the SDK)

## License

MIT License - See parent Binance.jl package for details.
