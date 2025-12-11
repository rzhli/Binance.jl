"""
SBE Decoder Module

Implements decoding for Binance SBE (Simple Binary Encoding) messages
based on the official SBE schema.

Schema Information:
- Schema ID: 3
- Supported Versions: 1 (deprecated), 2 (current as of 2025-12-18)
- Byte order: Little Endian

Note: Schema version 3:1 is deprecated as of 2025-12-18. Version 3:2 is the current version.
Both versions use the same message structure, so this decoder is compatible with both.

Message Types:
- TradesStreamEvent (10000)
- BestBidAskStreamEvent (10001)
- DepthSnapshotStreamEvent (10002)
- DepthDiffStreamEvent (10003)
"""
module SBEDecoder

using ...Types: PriceLevel
export SBEMessageHeader, TradeEvent, BestBidAskEvent, DepthSnapshotEvent, DepthDiffEvent
export decode_sbe_header, decode_sbe_message, mantissa_to_float
export SCHEMA_ID, SCHEMA_VERSION_DEPRECATED, SCHEMA_VERSION_CURRENT

# ============================================================================
# Schema Version Constants
# ============================================================================

const SCHEMA_ID = UInt16(3)
const SCHEMA_VERSION_DEPRECATED = UInt16(1)  # Deprecated as of 2025-12-18
const SCHEMA_VERSION_CURRENT = UInt16(2)     # Current version as of 2025-12-18

# ============================================================================
# SBE Null Value Constants (for optional fields)
# ============================================================================
# As of 2025-12-09, MDEntrySize fields in incremental book ticker/depth
# are presence="optional" and use null sentinel values when absent.

const INT64_NULL = typemax(Int64)  # 0x7FFFFFFFFFFFFFFF - null value for int64 mantissa

# ============================================================================
# Message Header Structure
# ============================================================================

"""
SBE Message Header (8 bytes)

Fields:
- blockLength: uint16 - Length of message body
- templateId: uint16 - Message type identifier
- schemaId: uint16 - Schema identifier (Binance uses 3)
- version: uint16 - Schema version (1 deprecated, 2 current)
"""
struct SBEMessageHeader
    blockLength::UInt16
    templateId::UInt16
    schemaId::UInt16
    version::UInt16
end

# ============================================================================
# Message Type Constants
# ============================================================================

const TEMPLATE_ID_TRADES = UInt16(10000)
const TEMPLATE_ID_BEST_BID_ASK = UInt16(10001)
const TEMPLATE_ID_DEPTH_SNAPSHOT = UInt16(10002)
const TEMPLATE_ID_DEPTH_DIFF = UInt16(10003)

# ============================================================================
# Data Structures
# ============================================================================

"""Single trade in TradesStreamEvent"""
struct TradeData
    id::Int64
    price::Float64
    qty::Float64
    isBuyerMaker::Bool
    isBestMatch::Bool
end

"""TradesStreamEvent (template ID: 10000)"""
struct TradeEvent
    eventTime::Int64           # Microseconds
    transactTime::Int64        # Microseconds
    symbol::String
    trades::Vector{TradeData}
end


"""BestBidAskStreamEvent (template ID: 10001)"""
struct BestBidAskEvent
    eventTime::Int64       # Microseconds
    bookUpdateId::Int64
    symbol::String
    bidPrice::Float64
    bidQty::Float64
    askPrice::Float64
    askQty::Float64
end

"""DepthSnapshotStreamEvent (template ID: 10002)"""
struct DepthSnapshotEvent
    eventTime::Int64       # Microseconds
    bookUpdateId::Int64
    symbol::String
    bids::Vector{PriceLevel}
    asks::Vector{PriceLevel}
end

"""DepthDiffStreamEvent (template ID: 10003)"""
struct DepthDiffEvent
    eventTime::Int64           # Microseconds
    firstBookUpdateId::Int64
    lastBookUpdateId::Int64
    symbol::String
    bids::Vector{PriceLevel}
    asks::Vector{PriceLevel}
end

# ============================================================================
# Helper Functions
# ============================================================================

"""Read little-endian integer from byte array"""
function read_uint16(data::Vector{UInt8}, offset::Int)
    return reinterpret(UInt16, data[offset:offset+1])[1]
end

function read_uint32(data::Vector{UInt8}, offset::Int)
    return reinterpret(UInt32, data[offset:offset+3])[1]
end

function read_int64(data::Vector{UInt8}, offset::Int)
    return reinterpret(Int64, data[offset:offset+7])[1]
end

function read_int8(data::Vector{UInt8}, offset::Int)
    return reinterpret(Int8, data[offset:offset])[1]
end

function read_uint8(data::Vector{UInt8}, offset::Int)
    return data[offset]
end

"""
    mantissa_to_float(mantissa::Int64, exponent::Int8) -> Float64

Convert SBE mantissa/exponent representation to floating point number.

Formula: value = mantissa × 10^exponent

# Example
```julia
# Price: mantissa=9553554, exponent=-2 → 95535.54
price = mantissa_to_float(9553554, -2)
```
"""
function mantissa_to_float(mantissa::Int64, exponent::Int8)
    return Float64(mantissa) * 10.0^Float64(exponent)
end

"""Read variable-length UTF-8 string (varString8)"""
function read_var_string(data::Vector{UInt8}, offset::Int)
    length = read_uint8(data, offset)
    if length == 0
        return "", offset + 1
    end
    str_bytes = data[offset+1:offset+length]
    str = String(str_bytes)
    return str, offset + 1 + length
end

# ============================================================================
# Message Header Decoder
# ============================================================================

"""
    decode_sbe_header(data::Vector{UInt8}) -> SBEMessageHeader

Decode SBE message header (first 8 bytes).
"""
function decode_sbe_header(data::Vector{UInt8})
    if length(data) < 8
        error("Data too short for SBE header: $(length(data)) bytes")
    end

    blockLength = read_uint16(data, 1)
    templateId = read_uint16(data, 3)
    schemaId = read_uint16(data, 5)
    version = read_uint16(data, 7)

    return SBEMessageHeader(blockLength, templateId, schemaId, version)
end

# ============================================================================
# Message Decoders
# ============================================================================

"""
    decode_sbe_message(data::Vector{UInt8}) -> Union{TradeEvent, BestBidAskEvent, DepthSnapshotEvent, DepthDiffEvent}

Decode complete SBE message including header and body.
"""
function decode_sbe_message(data::Vector{UInt8})
    header = decode_sbe_header(data)

    # Route to appropriate decoder based on template ID
    if header.templateId == TEMPLATE_ID_TRADES
        return decode_trades_event(data, header)
    elseif header.templateId == TEMPLATE_ID_BEST_BID_ASK
        return decode_best_bid_ask_event(data, header)
    elseif header.templateId == TEMPLATE_ID_DEPTH_SNAPSHOT
        return decode_depth_snapshot_event(data, header)
    elseif header.templateId == TEMPLATE_ID_DEPTH_DIFF
        return decode_depth_diff_event(data, header)
    else
        error("Unknown template ID: $(header.templateId)")
    end
end

"""Decode TradesStreamEvent (template ID: 10000)"""
function decode_trades_event(data::Vector{UInt8}, ::SBEMessageHeader)
    offset = 9  # After header

    # Read fixed fields
    eventTime = read_int64(data, offset)
    offset += 8

    transactTime = read_int64(data, offset)
    offset += 8

    priceExponent = read_int8(data, offset)
    offset += 1

    qtyExponent = read_int8(data, offset)
    offset += 1

    # Read trades group
    # Group header: blockLength (uint16) + numInGroup (uint32)
    # Note: blockLength is read but not used as we know the fixed structure
    _ = read_uint16(data, offset)  # blockLength
    offset += 2

    numInGroup = read_uint32(data, offset)
    offset += 4

    trades = TradeData[]
    for _ in 1:numInGroup
        trade_offset = offset

        # Each trade: id (8) + price (8) + qty (8) + isBuyerMaker (1)
        # Note: isBestMatch is presence="constant", NOT encoded in message
        tradeId = read_int64(data, trade_offset)
        trade_offset += 8

        priceMantissa = read_int64(data, trade_offset)
        trade_offset += 8

        qtyMantissa = read_int64(data, trade_offset)
        trade_offset += 8

        isBuyerMaker = read_uint8(data, trade_offset) != 0
        trade_offset += 1

        # isBestMatch is always true (constant field, not in message)
        isBestMatch = true

        price = mantissa_to_float(priceMantissa, priceExponent)
        qty = mantissa_to_float(qtyMantissa, qtyExponent)

        push!(trades, TradeData(tradeId, price, qty, isBuyerMaker, isBestMatch))

        offset = trade_offset
    end

    # Read symbol (varString8)
    symbol, _ = read_var_string(data, offset)

    return TradeEvent(eventTime, transactTime, symbol, trades)
end

"""Decode BestBidAskStreamEvent (template ID: 10001)

Note: As of 2025-12-09 schema update, MDEntrySize fields (bidQty, askQty) are presence="optional".
When quantity is null (INT64_NULL), it is converted to NaN.
"""
function decode_best_bid_ask_event(data::Vector{UInt8}, ::SBEMessageHeader)
    offset = 9  # After header

    # Read all fixed fields
    eventTime = read_int64(data, offset)
    offset += 8

    bookUpdateId = read_int64(data, offset)
    offset += 8

    priceExponent = read_int8(data, offset)
    offset += 1

    qtyExponent = read_int8(data, offset)
    offset += 1

    bidPriceMantissa = read_int64(data, offset)
    offset += 8

    bidQtyMantissa = read_int64(data, offset)
    offset += 8

    askPriceMantissa = read_int64(data, offset)
    offset += 8

    askQtyMantissa = read_int64(data, offset)
    offset += 8

    # Convert to floats
    bidPrice = mantissa_to_float(bidPriceMantissa, priceExponent)
    # Handle optional MDEntrySize: null value means quantity is not present
    bidQty = bidQtyMantissa == INT64_NULL ? NaN : mantissa_to_float(bidQtyMantissa, qtyExponent)
    askPrice = mantissa_to_float(askPriceMantissa, priceExponent)
    # Handle optional MDEntrySize: null value means quantity is not present
    askQty = askQtyMantissa == INT64_NULL ? NaN : mantissa_to_float(askQtyMantissa, qtyExponent)

    # Read symbol
    symbol, _ = read_var_string(data, offset)

    return BestBidAskEvent(eventTime, bookUpdateId, symbol, bidPrice, bidQty, askPrice, askQty)
end

"""Decode DepthSnapshotStreamEvent (template ID: 10002)

Note: Uses smallGroupSize16Encoding (blockLength uint16 + numInGroup uint16) for bid/ask groups
as per 2025-12-09 schema update.
"""
function decode_depth_snapshot_event(data::Vector{UInt8}, ::SBEMessageHeader)
    offset = 9  # After header

    # Read fixed fields
    eventTime = read_int64(data, offset)
    offset += 8

    bookUpdateId = read_int64(data, offset)
    offset += 8

    priceExponent = read_int8(data, offset)
    offset += 1

    qtyExponent = read_int8(data, offset)
    offset += 1

    # Read bids group (smallGroupSize16Encoding: blockLength uint16 + numInGroup uint16)
    # Note: blockLength is read but not used as we know the fixed structure
    _ = read_uint16(data, offset)  # bids_blockLength
    offset += 2

    bids_numInGroup = read_uint16(data, offset)
    offset += 2

    bids = PriceLevel[]
    for _ in 1:bids_numInGroup
        priceMantissa = read_int64(data, offset)
        offset += 8

        qtyMantissa = read_int64(data, offset)
        offset += 8

        price = mantissa_to_float(priceMantissa, priceExponent)
        qty = mantissa_to_float(qtyMantissa, qtyExponent)

        push!(bids, PriceLevel(price, qty))
    end

    # Read asks group
    _ = read_uint16(data, offset)  # asks_blockLength
    offset += 2

    asks_numInGroup = read_uint16(data, offset)
    offset += 2

    asks = PriceLevel[]
    for _ in 1:asks_numInGroup
        priceMantissa = read_int64(data, offset)
        offset += 8

        qtyMantissa = read_int64(data, offset)
        offset += 8

        price = mantissa_to_float(priceMantissa, priceExponent)
        qty = mantissa_to_float(qtyMantissa, qtyExponent)

        push!(asks, PriceLevel(price, qty))
    end

    # Read symbol
    symbol, _ = read_var_string(data, offset)

    return DepthSnapshotEvent(eventTime, bookUpdateId, symbol, bids, asks)
end

"""Decode DepthDiffStreamEvent (template ID: 10003)

Note: As of 2025-12-09 schema update, MDEntrySize fields are presence="optional".
When quantity is null (INT64_NULL), it is converted to NaN.
"""
function decode_depth_diff_event(data::Vector{UInt8}, ::SBEMessageHeader)
    offset = 9  # After header

    # Read fixed fields
    eventTime = read_int64(data, offset)
    offset += 8

    firstBookUpdateId = read_int64(data, offset)
    offset += 8

    lastBookUpdateId = read_int64(data, offset)
    offset += 8

    priceExponent = read_int8(data, offset)
    offset += 1

    qtyExponent = read_int8(data, offset)
    offset += 1

    # Read bids group
    # Note: blockLength is read but not used as we know the fixed structure
    _ = read_uint16(data, offset)  # bids_blockLength
    offset += 2

    bids_numInGroup = read_uint16(data, offset)
    offset += 2

    bids = PriceLevel[]
    for _ in 1:bids_numInGroup
        priceMantissa = read_int64(data, offset)
        offset += 8

        qtyMantissa = read_int64(data, offset)
        offset += 8

        price = mantissa_to_float(priceMantissa, priceExponent)
        # Handle optional MDEntrySize: null value means quantity is not present
        qty = qtyMantissa == INT64_NULL ? NaN : mantissa_to_float(qtyMantissa, qtyExponent)

        push!(bids, PriceLevel(price, qty))
    end

    # Read asks group
    _ = read_uint16(data, offset)  # asks_blockLength
    offset += 2

    asks_numInGroup = read_uint16(data, offset)
    offset += 2

    asks = PriceLevel[]
    for _ in 1:asks_numInGroup
        priceMantissa = read_int64(data, offset)
        offset += 8

        qtyMantissa = read_int64(data, offset)
        offset += 8

        price = mantissa_to_float(priceMantissa, priceExponent)
        # Handle optional MDEntrySize: null value means quantity is not present
        qty = qtyMantissa == INT64_NULL ? NaN : mantissa_to_float(qtyMantissa, qtyExponent)

        push!(asks, PriceLevel(price, qty))
    end

    # Read symbol
    symbol, _ = read_var_string(data, offset)

    return DepthDiffEvent(eventTime, firstBookUpdateId, lastBookUpdateId, symbol, bids, asks)
end

end # module SBEDecoder
