# BinanceFIX.jl

A Julia SDK for Binance FIX 4.4 Protocol trading.

## Overview

BinanceFIX.jl provides complete FIX protocol support for Binance Spot trading:
- **Order Entry** sessions for order placement, cancellation, and amendments
- **Drop Copy** sessions for read-only execution reports
- **Market Data** sessions for FIX-based market data streams
- **FIX SBE** support for high-performance binary encoding (ports 9001/9002)

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
config = Binance.from_toml("config.toml")
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

## Session Types

### Order Entry (Port 9000)
For placing, canceling, and amending orders:

```julia
session = FIXSession(config, sender_comp_id; session_type=OrderEntry)
```

### Drop Copy (Port 9000)
Read-only execution reports for monitoring:

```julia
session = FIXSession(config, sender_comp_id; session_type=DropCopy)
```

### Market Data (Port 9000)
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
config = Binance.from_toml("config.toml"; testnet=true)
sender_comp_id = "your_sender_id"

# Create SBE Order Entry session (port 9002)
session = SBESession(config, sender_comp_id; session_type=SBEOrderEntry)

# Connect and logon
connect_sbe(session)
logon_sbe(session)

# Start connection monitor
start_sbe_monitor(session)

# Place a limit order (using UInt8 enum values)
cl_ord_id = new_order_single_sbe(session, "BTCUSDT", UInt8(1);  # 1=BUY
    quantity=0.001, price=50000.0, order_type=UInt8(2))  # 2=LIMIT

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
        println("Order: $(decoded.cl_ord_id) Status: $(decoded.ord_status)")
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
    entry_types=[UInt8(0), UInt8(1)])  # 0=Bid, 1=Offer

# Get instrument list
instrument_list_request_sbe(session)
```

### FIX SBE Decoder (for Hybrid Mode)

When using standard FIX text requests with SBE responses (port 9001):

```julia
using BinanceFIX

# Decode FIX SBE message from raw bytes
data = receive_raw_data(session)
msg_type, decoded = decode_sbe_message(data)

if msg_type == :execution_report
    println("Order ID: ", decoded.order_id)
    println("ClOrdId: ", decoded.cl_ord_id)
    println("Status: ", decoded.ord_status)
    println("CumQty: ", decoded.cum_qty)
elseif msg_type == :logon_ack
    println("Logged in, UUID: ", decoded.uuid)
end
```

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
- version: uint16 (0 for v1.0)
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
├── stunnel.conf            # Stunnel configuration
└── README.md               # This file
```

## Stunnel Setup (Required)

Binance FIX API requires TLS connections. This SDK uses stunnel for TLS termination.

### Quick Setup

```bash
# Install stunnel
sudo apt install stunnel4   # Ubuntu/Debian
# or
brew install stunnel        # macOS

# Copy configuration
sudo cp stunnel.conf /etc/stunnel/binance-fix.conf

# Start stunnel
sudo systemctl start stunnel4
# or run directly
stunnel stunnel.conf
```

### Cloud VM Deployment (Google Cloud, AWS, etc.)

1. **Create VM** in a region close to Binance servers (Asia recommended for lower latency)

2. **Install dependencies**:
```bash
sudo apt update && sudo apt install -y stunnel4
curl -fsSL https://install.julialang.org | sh
```

3. **Clone and setup**:
```bash
git clone https://github.com/rzhli/Binance.jl.git
cd Binance.jl/BinanceFIX
sudo cp stunnel.conf /etc/stunnel/binance-fix.conf
sudo cp stunnel-binance.service /etc/systemd/system/
sudo systemctl enable stunnel-binance
sudo systemctl start stunnel-binance
```

4. **Generate Ed25519 key** (if not already done):
```bash
mkdir -p key
openssl genpkey -algorithm ED25519 -out key/ed25519-private.pem
openssl pkey -in key/ed25519-private.pem -pubout -out key/ed25519-public.pem
```

5. **Configure Binance API**:
   - Upload `key/ed25519-public.pem` to Binance API Management
   - Enable FIX_API permission
   - Add VM's public IP to whitelist

6. **Create config.toml**:
```bash
cp config_example.toml config.toml
# Edit config.toml with your API key and key path
```

### Port Mapping

#### Production

| Local Port | Remote Server | Description |
|------------|---------------|-------------|
| 9000 | fix-oe.binance.com:9000 | Order Entry (Standard FIX) |
| 9001 | fix-dc.binance.com:9000 | Drop Copy (Standard FIX) |
| 9002 | fix-md.binance.com:9000 | Market Data (Standard FIX) |
| 9010 | fix-oe.binance.com:9001 | Order Entry (SBE Hybrid) |
| 9011 | fix-dc.binance.com:9001 | Drop Copy (SBE Hybrid) |
| 9012 | fix-md.binance.com:9001 | Market Data (SBE Hybrid) |
| 9020 | fix-oe.binance.com:9002 | Order Entry (SBE Full) |
| 9021 | fix-dc.binance.com:9002 | Drop Copy (SBE Full) |
| 9022 | fix-md.binance.com:9002 | Market Data (SBE Full) |

#### Testnet

| Local Port | Remote Server | Description |
|------------|---------------|-------------|
| 19000 | fix-oe.testnet.binance.vision:9000 | Order Entry (Standard FIX) |
| 19001 | fix-dc.testnet.binance.vision:9000 | Drop Copy (Standard FIX) |
| 19002 | fix-md.testnet.binance.vision:9000 | Market Data (Standard FIX) |
| 19010 | fix-oe.testnet.binance.vision:9001 | Order Entry (SBE Hybrid) |
| 19011 | fix-dc.testnet.binance.vision:9001 | Drop Copy (SBE Hybrid) |
| 19012 | fix-md.testnet.binance.vision:9001 | Market Data (SBE Hybrid) |
| 19020 | fix-oe.testnet.binance.vision:9002 | Order Entry (SBE Full) |
| 19021 | fix-dc.testnet.binance.vision:9002 | Drop Copy (SBE Full) |
| 19022 | fix-md.testnet.binance.vision:9002 | Market Data (SBE Full) |

## Requirements

- Julia 1.11+
- Binance.jl (parent package)
- Ed25519 API key with FIX_API permission
- stunnel for TLS connection (Binance FIX requires TLS)

## License

MIT License - See parent Binance.jl package for details.
