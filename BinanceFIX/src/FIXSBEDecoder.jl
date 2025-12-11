"""
FIX SBE Decoder Module

Decodes FIX SBE (Simple Binary Encoding) responses from Binance FIX API.

Schema Information:
- Schema File: spot-fixsbe-1_0.xml
- Schema ID: 1
- Schema Version: 0
- Byte order: Little Endian

Wire Format:
<SOFH (6 bytes)> <message header (20 bytes)> <message (N bytes)>

Note: This is different from WebSocket SBE (spot_3_2.xml, Schema ID 3).
"""
module FIXSBEDecoder

using ..FIXConstants

export SOFHeader, FIXSBEMessageHeader, FIXSBEMessage
export decode_sofh, decode_message_header, decode_fix_sbe_message
export has_complete_message, extract_message, get_template_name
export mantissa_to_float

# =============================================================================
# Header Structures
# =============================================================================

"""
Simple Open Framing Header (SOFH) - 6 bytes

Fields:
- messageLength: uint32 - Total message length including SOFH
- encodingType: uint16 - Must be 0xEB50 for little-endian SBE
"""
struct SOFHeader
    messageLength::UInt32
    encodingType::UInt16
end

"""
FIX SBE Message Header - 20 bytes

Fields:
- blockLength: uint16 - Length of message body (excluding groups and var data)
- templateId: uint16 - Message type identifier
- schemaId: uint16 - Schema identifier (must be 1 for FIX SBE)
- version: uint16 - Schema version (must be 0 for FIX SBE 1.0)
- seqNum: uint32 - Message sequence number
- sendingTime: int64 - Sending time in microseconds since epoch (utcTimestampUs)
"""
struct FIXSBEMessageHeader
    blockLength::UInt16
    templateId::UInt16
    schemaId::UInt16
    version::UInt16
    seqNum::UInt32
    sendingTime::Int64
end

"""Decoded FIX SBE message wrapper"""
struct FIXSBEMessage
    sofh::SOFHeader
    header::FIXSBEMessageHeader
    body::Vector{UInt8}
end

# =============================================================================
# Helper Functions
# =============================================================================

"""Read little-endian integers from byte array (1-indexed)"""
function read_uint16(data::Vector{UInt8}, offset::Int)
    return reinterpret(UInt16, data[offset:offset+1])[1]
end

function read_uint32(data::Vector{UInt8}, offset::Int)
    return reinterpret(UInt32, data[offset:offset+3])[1]
end

function read_uint64(data::Vector{UInt8}, offset::Int)
    return reinterpret(UInt64, data[offset:offset+7])[1]
end

function read_int8(data::Vector{UInt8}, offset::Int)
    return reinterpret(Int8, data[offset:offset])[1]
end

function read_int64(data::Vector{UInt8}, offset::Int)
    return reinterpret(Int64, data[offset:offset+7])[1]
end

function read_uint8(data::Vector{UInt8}, offset::Int)
    return data[offset]
end

"""
Convert SBE mantissa/exponent to Float64

Formula: value = mantissa × 10^exponent
Returns NaN if mantissa is null value.
"""
function mantissa_to_float(mantissa::Int64, exponent::Int8)
    mantissa == SBE_INT64_NULL && return NaN
    return Float64(mantissa) * 10.0^Float64(exponent)
end

"""Read fixed-length string, trimming null bytes"""
function read_fixed_string(data::Vector{UInt8}, offset::Int, length::Int)
    str_bytes = data[offset:offset+length-1]
    null_pos = findfirst(==(0x00), str_bytes)
    if null_pos !== nothing
        str_bytes = str_bytes[1:null_pos-1]
    end
    return String(str_bytes)
end

"""Read variable-length string (uint8 length prefix + data)"""
function read_var_string8(data::Vector{UInt8}, offset::Int)
    length = read_uint8(data, offset)
    if length == 0
        return "", offset + 1
    end
    str_bytes = data[offset+1:offset+length]
    return String(str_bytes), offset + 1 + length
end

"""Read variable-length string (uint16 length prefix + data)"""
function read_var_string16(data::Vector{UInt8}, offset::Int)
    length = read_uint16(data, offset)
    if length == 0
        return "", offset + 2
    end
    str_bytes = data[offset+2:offset+1+length]
    return String(str_bytes), offset + 2 + length
end

# =============================================================================
# SOFH Decoder
# =============================================================================

"""
    decode_sofh(data::Vector{UInt8}) -> SOFHeader

Decode Simple Open Framing Header (first 6 bytes).

Throws error if:
- Data too short
- Invalid encoding type (must be 0xEB50)
"""
function decode_sofh(data::Vector{UInt8})
    if length(data) < SBE_SOFH_SIZE
        error("Data too short for SOFH: $(length(data)) bytes, need $SBE_SOFH_SIZE")
    end

    messageLength = read_uint32(data, 1)
    encodingType = read_uint16(data, 5)

    if encodingType != SBE_ENCODING_TYPE_LE
        error("Invalid encodingType: 0x$(string(encodingType, base=16)), expected 0xEB50")
    end

    return SOFHeader(messageLength, encodingType)
end

# =============================================================================
# Message Header Decoder
# =============================================================================

"""
    decode_message_header(data::Vector{UInt8}, offset::Int=7) -> FIXSBEMessageHeader

Decode FIX SBE message header (20 bytes after SOFH).

Default offset is 7 (1-indexed), assuming SOFH is at bytes 1-6.
"""
function decode_message_header(data::Vector{UInt8}, offset::Int=7)
    if length(data) < offset + SBE_MESSAGE_HEADER_SIZE - 1
        error("Data too short for message header at offset $offset")
    end

    blockLength = read_uint16(data, offset)
    templateId = read_uint16(data, offset + 2)
    schemaId = read_uint16(data, offset + 4)
    version = read_uint16(data, offset + 6)
    seqNum = read_uint32(data, offset + 8)
    sendingTime = read_int64(data, offset + 12)

    return FIXSBEMessageHeader(blockLength, templateId, schemaId, version, seqNum, sendingTime)
end

# =============================================================================
# Main Decoder
# =============================================================================

"""
    decode_fix_sbe_message(data::Vector{UInt8}) -> FIXSBEMessage

Decode a complete FIX SBE message including SOFH, header, and body.
"""
function decode_fix_sbe_message(data::Vector{UInt8})
    sofh = decode_sofh(data)
    header = decode_message_header(data, SBE_SOFH_SIZE + 1)

    # Validate schema
    if header.schemaId != SBE_SCHEMA_ID_FIX
        @warn "Unexpected schema ID: $(header.schemaId), expected $SBE_SCHEMA_ID_FIX"
    end

    # Body starts after SOFH + message header
    body_offset = SBE_SOFH_SIZE + SBE_MESSAGE_HEADER_SIZE + 1
    body_end = min(sofh.messageLength, length(data))

    body = body_offset <= body_end ? data[body_offset:body_end] : UInt8[]

    return FIXSBEMessage(sofh, header, body)
end

# =============================================================================
# Utility Functions
# =============================================================================

"""Get template name from template ID"""
function get_template_name(templateId::UInt16)
    names = Dict(
        # Admin Messages
        SBE_TEMPLATE_HEARTBEAT => "Heartbeat",
        SBE_TEMPLATE_TEST_REQUEST => "TestRequest",
        SBE_TEMPLATE_REJECT => "Reject",
        SBE_TEMPLATE_LOGOUT => "Logout",
        SBE_TEMPLATE_LOGON => "Logon",
        SBE_TEMPLATE_LOGON_ACK => "LogonAck",
        SBE_TEMPLATE_NEWS => "News",
        # Order Entry Messages
        SBE_TEMPLATE_ORDER_CANCEL_REJECT => "OrderCancelReject",
        SBE_TEMPLATE_ORDER_CANCEL_REQUEST_AND_NEW => "OrderCancelRequestAndNewOrderSingle",
        SBE_TEMPLATE_EXECUTION_REPORT => "ExecutionReport",
        SBE_TEMPLATE_NEW_ORDER_SINGLE => "NewOrderSingle",
        SBE_TEMPLATE_NEW_ORDER_LIST => "NewOrderList",
        SBE_TEMPLATE_ORDER_CANCEL_REQUEST => "OrderCancelRequest",
        SBE_TEMPLATE_LIST_STATUS => "ListStatus",
        SBE_TEMPLATE_ORDER_MASS_CANCEL_REQUEST => "OrderMassCancelRequest",
        SBE_TEMPLATE_ORDER_MASS_CANCEL_REPORT => "OrderMassCancelReport",
        SBE_TEMPLATE_ORDER_AMEND_KEEP_PRIORITY => "OrderAmendKeepPriorityRequest",
        SBE_TEMPLATE_ORDER_AMEND_REJECT => "OrderAmendReject",
        SBE_TEMPLATE_LIMIT_QUERY => "LimitQuery",
        SBE_TEMPLATE_LIMIT_RESPONSE => "LimitResponse",
        SBE_TEMPLATE_EXECUTION_REPORT_ACK => "ExecutionReportAck",
        # Market Data Messages
        SBE_TEMPLATE_INSTRUMENT_LIST_REQUEST => "InstrumentListRequest",
        SBE_TEMPLATE_INSTRUMENT_LIST => "InstrumentList",
        SBE_TEMPLATE_MARKET_DATA_REQUEST => "MarketDataRequest",
        SBE_TEMPLATE_MARKET_DATA_REQUEST_REJECT => "MarketDataRequestReject",
        SBE_TEMPLATE_MARKET_DATA_SNAPSHOT => "MarketDataSnapshot",
        SBE_TEMPLATE_MARKET_DATA_INCREMENTAL_TRADE => "MarketDataIncrementalTrade",
        SBE_TEMPLATE_MARKET_DATA_INCREMENTAL_BOOK_TICKER => "MarketDataIncrementalBookTicker",
        SBE_TEMPLATE_MARKET_DATA_INCREMENTAL_DEPTH => "MarketDataIncrementalDepth",
    )
    return get(names, templateId, "Unknown($templateId)")
end

"""Check if data contains a complete FIX SBE message"""
function has_complete_message(data::Vector{UInt8})
    length(data) < SBE_SOFH_SIZE && return false
    messageLength = read_uint32(data, 1)
    return length(data) >= messageLength
end

"""Extract a complete message from buffer, returns (message, remaining)"""
function extract_message(data::Vector{UInt8})
    if !has_complete_message(data)
        return nothing, data
    end
    messageLength = read_uint32(data, 1)
    message = data[1:messageLength]
    remaining = data[messageLength+1:end]
    return message, remaining
end

end # module FIXSBEDecoder
