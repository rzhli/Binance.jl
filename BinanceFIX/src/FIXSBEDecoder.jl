"""
FIX SBE Decoder Module

Decodes FIX SBE (Simple Binary Encoding) responses from Binance FIX API.

Schema Information:
- Schema Files: spot-fixsbe-1_1.xml (session default), spot-fixsbe-1_2.xml (published 2026-11-11)
- Schema ID: 1
- Schema Versions: 1 (session default), 2 (published 2026-11-11); version 0 is retired
- Byte order: Little Endian

Wire Format:
<SOFH (6 bytes)> <message header (20 bytes)> <message (N bytes)>

Note: This is different from WebSocket SBE (spot_3_3.xml, Schema ID 3).
"""
module FIXSBEDecoder

using ..FIXConstants
using Dates

export SOFHeader, FIXSBEMessageHeader, FIXSBEMessage
export decode_sofh, decode_message_header, decode_fix_sbe_message
export has_complete_message, extract_message, get_template_name
export mantissa_to_float

# Decoded message types
export SBELogonAck, SBELogout, SBEHeartbeat, SBETestRequest, SBEReject, SBENews
export SBEExecutionReport, SBEExecutionReportAck, SBEOrderCancelReject
export SBEListStatus, SBEOrderMassCancelReport, SBEOrderAmendReject
export SBELimitResponse, SBELimitIndicator
export SBEMarketDataSnapshot, SBEMarketDataReject
export SBEMarketDataIncrementalTrade, SBEMarketDataIncrementalBookTicker, SBEMarketDataIncrementalDepth
export SBEInstrumentList, SBEInstrumentInfo, SBEMDEntry, SBEMiscFee, SBEListStatusOrder
export SBE_MD_ENTRY_BID, SBE_MD_ENTRY_OFFER, SBE_MD_ENTRY_TRADE

# Decoder functions
export decode_logon_ack, decode_logout, decode_heartbeat, decode_test_request
export decode_reject, decode_news
export decode_execution_report, decode_execution_report_ack
export decode_order_cancel_reject, decode_list_status
export decode_order_mass_cancel_report, decode_order_amend_reject
export decode_limit_response
export decode_market_data_snapshot, decode_market_data_reject
export decode_market_data_incremental_trade, decode_market_data_incremental_book_ticker
export decode_market_data_incremental_depth
export decode_instrument_list
export decode_sbe_message

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
- version: uint16 - Schema version (1 for FIX SBE 1:1; 0 for the deprecated 1:0 schema)
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
@inline function read_uint16(data::Vector{UInt8}, offset::Int)
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
end

@inline function read_uint32(data::Vector{UInt8}, offset::Int)
    return UInt32(data[offset]) |
           (UInt32(data[offset + 1]) << 8) |
           (UInt32(data[offset + 2]) << 16) |
           (UInt32(data[offset + 3]) << 24)
end

@inline function read_uint64(data::Vector{UInt8}, offset::Int)
    value = UInt64(0)
    for shift in 0:8:56
        value |= UInt64(data[offset + (shift >>> 3)]) << shift
    end
    return value
end

@inline function read_int8(data::Vector{UInt8}, offset::Int)
    return reinterpret(Int8, data[offset])
end

@inline function read_int64(data::Vector{UInt8}, offset::Int)
    return reinterpret(Int64, read_uint64(data, offset))
end

@inline function read_uint8(data::Vector{UInt8}, offset::Int)
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
    str_bytes = view(data, offset:offset+length-1)
    null_pos = findfirst(==(0x00), str_bytes)
    if null_pos !== nothing
        str_bytes = view(str_bytes, 1:null_pos-1)
    end
    return String(str_bytes)
end

"""Read variable-length string (uint8 length prefix + data)"""
function read_var_string8(data::Vector{UInt8}, offset::Int)
    length = read_uint8(data, offset)
    if length == 0
        return "", offset + 1
    end
    str_bytes = view(data, offset+1:offset+length)
    return String(str_bytes), offset + 1 + length
end

"""Read variable-length string (uint16 length prefix + data)"""
function read_var_string16(data::Vector{UInt8}, offset::Int)
    length = read_uint16(data, offset)
    if length == 0
        return "", offset + 2
    end
    str_bytes = view(data, offset+2:offset+1+length)
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
    message_length = Int(sofh.messageLength)
    minimum_length = SBE_SOFH_SIZE + SBE_MESSAGE_HEADER_SIZE
    message_length >= minimum_length || throw(ArgumentError(
        "Invalid SOFH message length $message_length; minimum is $minimum_length",
    ))
    message_length <= length(data) || throw(ArgumentError(
        "Truncated FIX SBE message: header declares $message_length bytes, received $(length(data))",
    ))
    header = decode_message_header(data, SBE_SOFH_SIZE + 1)

    # Validate schema
    if header.schemaId != SBE_SCHEMA_ID_FIX
        throw(ArgumentError("Unexpected schema ID $(header.schemaId), expected $SBE_SCHEMA_ID_FIX"))
    end

    # Body starts after SOFH + message header
    body_offset = SBE_SOFH_SIZE + SBE_MESSAGE_HEADER_SIZE + 1
    body_end = message_length

    body = body_offset <= body_end ? data[body_offset:body_end] : UInt8[]

    return FIXSBEMessage(sofh, header, body)
end

# =============================================================================
# Utility Functions
# =============================================================================

const TEMPLATE_NAMES = Dict{UInt16,String}(
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

"""Get template name from template ID"""
function get_template_name(templateId::UInt16)
    return get(TEMPLATE_NAMES, templateId, "Unknown($templateId)")
end

"""Check if data contains a complete FIX SBE message"""
function has_complete_message(data::Vector{UInt8})
    length(data) < SBE_SOFH_SIZE && return false
    message_length = Int(read_uint32(data, 1))
    minimum_length = SBE_SOFH_SIZE + SBE_MESSAGE_HEADER_SIZE
    message_length >= minimum_length || throw(ArgumentError(
        "Invalid SOFH message length $message_length; minimum is $minimum_length",
    ))
    return length(data) >= message_length
end

"""Extract a complete message from buffer, returns (message, remaining)"""
function extract_message(data::Vector{UInt8})
    if !has_complete_message(data)
        return nothing, data
    end
    message_length = Int(read_uint32(data, 1))
    message = data[1:message_length]
    remaining = data[message_length+1:end]
    return message, remaining
end

# =============================================================================
# Decoded Message Structures
# =============================================================================
#
# Conventions for every decoded message:
# - Field layouts follow spot-fixsbe-1_1.xml / 1_2.xml exactly; offsets below are
#   the zero-based offsets of the schema's root or group block.
# - Optional fields are `nothing` when the wire carries the SBE null value.
# - Enumerations keep their wire value as `UInt8`. Most are ASCII characters
#   (e.g. Side `UInt8('1')` = BUY, ExecType `UInt8('F')` = TRADE), matching the
#   text-FIX constants; a few are small integers (see the schema).
# - IDs are `Int64`, timestamps are microseconds since the Unix epoch.
# - Decimals are converted with the exponent carried in the same message.

"""LogonAck response (templateId=20009)"""
struct SBELogonAck
    seq_num::UInt32
    sending_time::Int64  # microseconds since epoch
    uuid::String
end

"""Logout message (templateId=20004)"""
struct SBELogout
    seq_num::UInt32
    sending_time::Int64
    text::String
end

"""Heartbeat message (templateId=20001)"""
struct SBEHeartbeat
    seq_num::UInt32
    sending_time::Int64
    test_req_id::String
end

"""TestRequest message (templateId=20002)"""
struct SBETestRequest
    seq_num::UInt32
    sending_time::Int64
    test_req_id::String
end

"""Reject message (templateId=20003)"""
struct SBEReject
    seq_num::UInt32
    sending_time::Int64
    ref_seq_num::Union{UInt32,Nothing}
    ref_tag_id::Union{UInt32,Nothing}
    ref_msg_type::String
    session_reject_reason::Union{UInt8,Nothing}
    error_code::Union{Int32,Nothing}
    text::String
end

"""News message (templateId=20100). FIX SBE carries only the headline."""
struct SBENews
    seq_num::UInt32
    sending_time::Int64
    headline::String
end

"""Miscellaneous fee entry (ExecutionReport MiscFees group)"""
struct SBEMiscFee
    amount::Float64
    currency::String
    fee_type::UInt8
end

"""ExecutionReport (templateId=98)"""
Base.@kwdef struct SBEExecutionReport
    seq_num::UInt32
    sending_time::Int64

    # Order identification
    order_id::Union{Int64,Nothing}
    cl_ord_id::String
    orig_cl_ord_id::String
    list_id::Union{Int64,Nothing}
    exec_id::Union{Int64,Nothing}

    # Order details
    symbol::String
    side::UInt8
    ord_type::UInt8
    order_qty::Union{Float64,Nothing}
    cash_order_qty::Union{Float64,Nothing}
    price::Union{Float64,Nothing}
    time_in_force::Union{UInt8,Nothing}
    exec_inst::Union{UInt8,Nothing}
    max_floor::Union{Float64,Nothing}

    # Execution status
    exec_type::UInt8
    ord_status::UInt8
    ord_rej_reason::Union{UInt8,Nothing}

    # Quantities
    cum_qty::Float64
    leaves_qty::Union{Float64,Nothing}
    cum_quote_qty::Union{Float64,Nothing}
    last_qty::Float64
    last_px::Union{Float64,Nothing}

    # Timestamps (microseconds)
    transact_time::Union{Int64,Nothing}
    order_creation_time::Union{Int64,Nothing}
    working_time::Union{Int64,Nothing}
    trailing_time::Union{Int64,Nothing}

    # Trade details
    trade_id::Union{Int64,Nothing}
    aggressor_indicator::Union{UInt8,Nothing}   # boolEnum: 0=false, 1=true
    alloc_id::Union{Int64,Nothing}
    match_type::Union{UInt8,Nothing}

    # Working status
    working_indicator::Union{UInt8,Nothing}     # boolEnum
    working_floor::Union{UInt8,Nothing}

    # Strategy
    target_strategy::Union{Int32,Nothing}
    strategy_id::Union{Int64,Nothing}
    sor::Union{UInt8,Nothing}                   # boolEnum
    order_capacity::Union{UInt8,Nothing}

    # Self-trade prevention
    self_trade_prevention_mode::Union{UInt8,Nothing}
    prevented_match_id::Union{Int64,Nothing}
    prevented_execution_price::Union{Float64,Nothing}
    prevented_execution_qty::Union{Float64,Nothing}
    trade_group_id::Union{Int64,Nothing}
    counter_symbol::String
    counter_order_id::Union{Int64,Nothing}
    prevented_qty::Union{Float64,Nothing}
    last_prevented_qty::Union{Float64,Nothing}

    # Secondary (SOR / allocation) identification
    secondary_order_id::Union{Int64,Nothing}
    secondary_external_account_id::Union{Int64,Nothing}
    secondary_symbol::String

    # Trigger fields
    trigger_type::Union{UInt8,Nothing}
    trigger_action::Union{UInt8,Nothing}
    trigger_price::Union{Float64,Nothing}
    trigger_price_type::Union{UInt8,Nothing}
    trigger_price_direction::Union{UInt8,Nothing}
    trigger_trailing_delta_bips::Union{UInt64,Nothing}

    # Pegged order fields
    peg_offset_value::Union{UInt8,Nothing}
    peg_price_type::Union{UInt8,Nothing}
    peg_move_type::Union{UInt8,Nothing}
    peg_offset_type::Union{UInt8,Nothing}
    pegged_price::Union{Float64,Nothing}

    # Fees
    fees::Vector{SBEMiscFee}

    # Error info
    error_code::Union{Int32,Nothing}
    text::String

    # Schema 1:1 field (`nothing` on older messages)
    expiry_reason::Union{UInt8,Nothing}  # ExpiryReason (25056); 1:2 adds 9=Exhausted, 10=InsufficientQuoteNotionalLimit

    # Schema 1:2 fields (`nothing` on 1:1 sessions)
    quote_notional_limit::Union{Float64,Nothing}                 # QuoteNotionalLimit (25057)
    effective_self_trade_prevention_mode::Union{UInt8,Nothing}   # EffectiveSelfTradePreventionMode (25058)
end

"""ExecutionReportAck (templateId=198) - Mini execution report"""
struct SBEExecutionReportAck
    seq_num::UInt32
    sending_time::Int64
    order_id::Union{Int64,Nothing}
    list_id::Union{Int64,Nothing}
    cl_ord_id::String
    symbol::String
    exec_type::UInt8
    ord_status::UInt8
    ord_rej_reason::Union{UInt8,Nothing}
    transact_time::Union{Int64,Nothing}
    error_code::Union{Int32,Nothing}
    text::String
end

"""OrderCancelReject (templateId=96)"""
struct SBEOrderCancelReject
    seq_num::UInt32
    sending_time::Int64
    order_id::Union{Int64,Nothing}
    list_id::Union{Int64,Nothing}
    cl_ord_id::String
    orig_cl_ord_id::String
    orig_cl_list_id::String
    symbol::String
    cancel_restrictions::Union{UInt8,Nothing}
    cxl_rej_response_to::UInt8
    error_code::Int32
    text::String
end

"""One order of a ListStatus message"""
struct SBEListStatusOrder
    symbol::String
    order_id::Union{Int64,Nothing}
    cl_ord_id::String
    ord_rej_reason::Union{UInt8,Nothing}
    error_code::Union{Int32,Nothing}
    text::String
    # (ListTriggerType, ListTriggerTriggerIndex, ListTriggerAction)
    list_triggering_instructions::Vector{NTuple{3,UInt8}}
end

"""ListStatus (templateId=102)"""
struct SBEListStatus
    seq_num::UInt32
    sending_time::Int64
    list_id::Union{Int64,Nothing}
    cl_list_id::String
    orig_cl_list_id::String
    contingency_type::Union{UInt8,Nothing}
    list_status_type::UInt8
    list_order_status::UInt8
    list_reject_reason::Union{UInt8,Nothing}
    transact_time::Union{Int64,Nothing}
    orders::Vector{SBEListStatusOrder}
end

"""OrderMassCancelReport (templateId=104)"""
struct SBEOrderMassCancelReport
    seq_num::UInt32
    sending_time::Int64
    cl_ord_id::String
    symbol::String
    mass_cancel_request_type::UInt8
    mass_cancel_response::UInt8
    mass_cancel_reject_reason::Union{UInt8,Nothing}
    total_affected_orders::Union{Int64,Nothing}
    error_code::Union{Int32,Nothing}
    text::String
end

"""OrderAmendReject (templateId=106)"""
struct SBEOrderAmendReject
    seq_num::UInt32
    sending_time::Int64
    order_id::Union{Int64,Nothing}
    cl_ord_id::String
    orig_cl_ord_id::String
    symbol::String
    order_qty::Float64
    error_code::Int32
    text::String
end

"""Limit indicator entry"""
struct SBELimitIndicator
    limit_type::UInt8                                        # '1'=ORDER_LIMIT, '2'=MESSAGE_LIMIT
    limit_count::UInt64
    limit_max::UInt64
    limit_reset_interval::Union{UInt32,Nothing}
    limit_reset_interval_resolution::Union{UInt8,Nothing}    # 's','m','h','d'
end

"""LimitResponse (templateId=121)"""
struct SBELimitResponse
    seq_num::UInt32
    sending_time::Int64
    req_id::String
    limits::Vector{SBELimitIndicator}
end

const SBE_MD_ENTRY_BID = UInt8('0')
const SBE_MD_ENTRY_OFFER = UInt8('1')
const SBE_MD_ENTRY_TRADE = UInt8('2')

"""
Market data entry. `entry_type` is `SBE_MD_ENTRY_BID`, `SBE_MD_ENTRY_OFFER` or
`SBE_MD_ENTRY_TRADE` (the FIX SBE messages use separate bid/ask groups; the type
is filled in from the group). `size === nothing` means the wire carried no size.
"""
struct SBEMDEntry
    entry_type::UInt8
    price::Float64
    size::Union{Float64,Nothing}
    symbol::String
    transact_time::Union{Int64,Nothing}
    trade_id::Union{Int64,Nothing}
    aggressor_side::Union{UInt8,Nothing}
    first_book_update_id::Union{Int64,Nothing}
    last_book_update_id::Union{Int64,Nothing}
end

"""MarketDataSnapshot (templateId=204)"""
struct SBEMarketDataSnapshot
    seq_num::UInt32
    sending_time::Int64
    symbol::String
    last_book_update_id::Union{Int64,Nothing}
    entries::Vector{SBEMDEntry}
end

"""MarketDataRequestReject (templateId=203)"""
struct SBEMarketDataReject
    seq_num::UInt32
    sending_time::Int64
    md_req_id::String
    reject_reason::Union{UInt8,Nothing}
    error_code::Union{Int32,Nothing}
    text::String
end

"""MarketDataIncrementalTrade (templateId=205)"""
struct SBEMarketDataIncrementalTrade
    seq_num::UInt32
    sending_time::Int64
    symbol::String
    transact_time::Int64
    entries::Vector{SBEMDEntry}
end

"""MarketDataIncrementalBookTicker (templateId=206)"""
struct SBEMarketDataIncrementalBookTicker
    seq_num::UInt32
    sending_time::Int64
    symbol::String
    last_book_update_id::Int64
    entries::Vector{SBEMDEntry}
end

"""MarketDataIncrementalDepth (templateId=207)

Update Speed: 20ms from 2026-08-04 ~07:00 UTC (25ms before rollout)
"""
struct SBEMarketDataIncrementalDepth
    seq_num::UInt32
    sending_time::Int64
    symbol::String
    first_book_update_id::Int64
    last_book_update_id::Int64
    entries::Vector{SBEMDEntry}
end

"""Instrument info"""
struct SBEInstrumentInfo
    symbol::String
    currency::String
    min_trade_vol::Union{Float64,Nothing}
    max_trade_vol::Union{Float64,Nothing}
    min_qty_increment::Union{Float64,Nothing}
    market_min_trade_vol::Union{Float64,Nothing}
    market_max_trade_vol::Union{Float64,Nothing}
    market_min_qty_increment::Union{Float64,Nothing}
    start_price_range::Union{Float64,Nothing}
    end_price_range::Union{Float64,Nothing}
    min_price_increment::Union{Float64,Nothing}
    price_exponent::Int8
    qty_exponent::Int8
end

"""InstrumentList (templateId=201)"""
struct SBEInstrumentList
    seq_num::UInt32
    sending_time::Int64
    instrument_req_id::String
    instruments::Vector{SBEInstrumentInfo}
end

# =============================================================================
# Field readers
# =============================================================================
#
# `base` is the 1-based index of the first byte of a block; `off` is the field's
# zero-based offset inside that block, as listed in the schema.

"""Helper to read int32 (little-endian)"""
@inline function read_int32(data::Vector{UInt8}, offset::Int)
    return reinterpret(Int32, read_uint32(data, offset))
end

@inline f_u8(b, base, off) = b[base+off]
@inline f_i8(b, base, off) = reinterpret(Int8, b[base+off])
@inline f_u32(b, base, off) = read_uint32(b, base + off)
@inline f_i32(b, base, off) = read_int32(b, base + off)
@inline f_u64(b, base, off) = read_uint64(b, base + off)
@inline f_i64(b, base, off) = read_int64(b, base + off)

@inline f_opt_u8(b, base, off) = (v = f_u8(b, base, off); v == SBE_UINT8_NULL ? nothing : v)
@inline f_opt_char(b, base, off) = (v = f_u8(b, base, off); v == SBE_CHAR_NULL ? nothing : v)
@inline f_opt_u32(b, base, off) = (v = f_u32(b, base, off); v == SBE_UINT32_NULL ? nothing : v)
@inline f_opt_i32(b, base, off) = (v = f_i32(b, base, off); v == SBE_INT32_NULL ? nothing : v)
@inline f_opt_u64(b, base, off) = (v = f_u64(b, base, off); v == SBE_UINT64_NULL ? nothing : v)
@inline f_opt_i64(b, base, off) = (v = f_i64(b, base, off); v == SBE_INT64_NULL ? nothing : v)

"""Decimal value of a mantissa: `mantissa × 10^exponent`."""
@inline function decimal_value(mantissa::Int64, exponent::Int8)
    return exponent < 0 ? mantissa / 10.0^(-Int(exponent)) : mantissa * 10.0^Int(exponent)
end

@inline f_dec(b, base, off, exponent::Int8) = decimal_value(f_i64(b, base, off), exponent)
@inline function f_opt_dec(b, base, off, exponent::Int8)
    m = f_i64(b, base, off)
    return m == SBE_INT64_NULL ? nothing : decimal_value(m, exponent)
end

# The root block must be fully present before any field is read.
function require_block(body::Vector{UInt8}, header::FIXSBEMessageHeader, minimum::Int, name::String)
    block = Int(header.blockLength)
    block >= minimum || throw(ArgumentError(
        "$name root block is $block bytes; schema requires at least $minimum"))
    length(body) >= block || throw(ArgumentError(
        "Truncated $name: root block is $block bytes, body has $(length(body))"))
    return block
end

# Repeating-group dimensions. Each returns (entry block length, entry count,
# index of the first entry). The four encodings differ only in field widths.
function group_dims(body::Vector{UInt8}, pos::Int, block_bytes::Int, count_bytes::Int, name::String)
    header_size = block_bytes + count_bytes
    pos + header_size - 1 <= length(body) || throw(ArgumentError("Truncated $name group header"))
    block = block_bytes == 1 ? Int(body[pos]) : Int(read_uint16(body, pos))
    cpos = pos + block_bytes
    count = count_bytes == 1 ? Int(body[cpos]) :
            count_bytes == 2 ? Int(read_uint16(body, cpos)) : Int(read_uint32(body, cpos))
    first = pos + header_size
    # Entries without var data occupy exactly count × block bytes; with var data
    # they occupy more. Either way this is a lower bound, checked before looping.
    first + count * block - 1 <= length(body) || throw(ArgumentError(
        "Invalid $name group: $count entries of $block bytes exceed the message body"))
    return block, count, first
end

function require_entry(block::Int, minimum::Int, name::String)
    block >= minimum || throw(ArgumentError(
        "$name group entry is $block bytes; schema requires at least $minimum"))
    return nothing
end

# =============================================================================
# Message Decoder Functions
# =============================================================================

"""Decode LogonAck message"""
function decode_logon_ack(header::FIXSBEMessageHeader, body::Vector{UInt8})
    # Root block (6 bytes): EncryptMethod uint8, HeartBtInt uint32,
    # SbeSchemaIdVersionDeprecated boolEnum. Var data starts after it.
    offset = require_block(body, header, 0, "LogonAck") + 1
    uuid, offset = read_var_string8(body, offset)
    return SBELogonAck(header.seqNum, header.sendingTime, uuid)
end

"""Decode Logout message"""
function decode_logout(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = require_block(body, header, 0, "Logout") + 1
    text, offset = read_var_string16(body, offset)
    return SBELogout(header.seqNum, header.sendingTime, text)
end

"""Decode Heartbeat message"""
function decode_heartbeat(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = require_block(body, header, 0, "Heartbeat") + 1
    test_req_id, offset = read_var_string8(body, offset)
    return SBEHeartbeat(header.seqNum, header.sendingTime, test_req_id)
end

"""Decode TestRequest message"""
function decode_test_request(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = require_block(body, header, 0, "TestRequest") + 1
    test_req_id, offset = read_var_string8(body, offset)
    return SBETestRequest(header.seqNum, header.sendingTime, test_req_id)
end

"""Decode Reject message"""
function decode_reject(header::FIXSBEMessageHeader, body::Vector{UInt8})
    # RefSeqNum u32 (0), RefTagID u32 (4), SessionRejectReason u8 (8), ErrorCode i32 (9)
    block = require_block(body, header, 13, "Reject")
    ref_seq_num = f_opt_u32(body, 1, 0)
    ref_tag_id = f_opt_u32(body, 1, 4)
    session_reject_reason = f_opt_u8(body, 1, 8)
    error_code = f_opt_i32(body, 1, 9)

    offset = block + 1
    ref_msg_type, offset = read_var_string8(body, offset)
    text, offset = read_var_string16(body, offset)

    return SBEReject(
        header.seqNum, header.sendingTime,
        ref_seq_num, ref_tag_id, ref_msg_type,
        session_reject_reason, error_code, text
    )
end

"""Decode News message"""
function decode_news(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = require_block(body, header, 0, "News") + 1
    headline, offset = read_var_string16(body, offset)
    return SBENews(header.seqNum, header.sendingTime, headline)
end

# Zero-based offsets of the fields that later schema versions appended to the
# ExecutionReport root block. `blockLength` tells whether a message has them.
const ER_BLOCK_LENGTH_V0 = 280                # schema 1:0
const ER_EXPIRY_REASON_OFFSET = 280           # uint8 enum, since 1:1 (block = 281)
const ER_QUOTE_NOTIONAL_LIMIT_OFFSET = 281    # mantissa64 with PriceExponent, since 1:2
const ER_EFFECTIVE_STP_OFFSET = 289           # char enum, since 1:2 (block = 290)

"""Decode ExecutionReport message"""
function decode_execution_report(header::FIXSBEMessageHeader, body::Vector{UInt8})
    block = require_block(body, header, ER_BLOCK_LENGTH_V0, "ExecutionReport")
    b = body
    px = f_i8(b, 1, 0)        # PriceExponent
    qty = f_i8(b, 1, 1)       # QtyExponent
    has(off, size) = block >= off + size

    # MiscFees group: smallGroupSize16Encoding (blockLength uint8, numInGroup uint16)
    fee_block, fee_count, offset = group_dims(b, block + 1, 1, 2, "MiscFees")
    fees = SBEMiscFee[]
    if fee_count > 0
        require_entry(fee_block, 10, "MiscFees")
        sizehint!(fees, fee_count)
        for _ in 1:fee_count
            fee_exponent = f_i8(b, offset, 0)
            amount = f_dec(b, offset, 1, fee_exponent)
            fee_type = f_u8(b, offset, 9)
            currency, offset = read_var_string8(b, offset + fee_block)
            push!(fees, SBEMiscFee(amount, currency, fee_type))
        end
    end

    cl_ord_id, offset = read_var_string8(b, offset)
    orig_cl_ord_id, offset = read_var_string8(b, offset)
    symbol, offset = read_var_string8(b, offset)
    secondary_symbol, offset = read_var_string8(b, offset)
    counter_symbol, offset = read_var_string8(b, offset)
    text, offset = read_var_string16(b, offset)

    return SBEExecutionReport(;
        seq_num=header.seqNum,
        sending_time=header.sendingTime,
        exec_id=f_opt_i64(b, 1, 2),
        order_id=f_opt_i64(b, 1, 10),
        order_qty=f_opt_dec(b, 1, 18, qty),
        ord_type=f_u8(b, 1, 26),
        side=f_u8(b, 1, 27),
        exec_inst=f_opt_char(b, 1, 28),
        price=f_opt_dec(b, 1, 29, px),
        trigger_type=f_opt_char(b, 1, 37),
        trigger_action=f_opt_char(b, 1, 38),
        trigger_price=f_opt_dec(b, 1, 39, px),
        trigger_price_type=f_opt_char(b, 1, 47),
        trigger_price_direction=f_opt_char(b, 1, 48),
        trigger_trailing_delta_bips=f_opt_u64(b, 1, 49),
        peg_offset_value=f_opt_u8(b, 1, 57),
        peg_price_type=f_opt_char(b, 1, 58),
        peg_move_type=f_opt_u8(b, 1, 59),
        peg_offset_type=f_opt_char(b, 1, 60),
        pegged_price=f_opt_dec(b, 1, 61, px),
        time_in_force=f_opt_char(b, 1, 69),
        transact_time=f_opt_i64(b, 1, 70),
        order_creation_time=f_opt_i64(b, 1, 78),
        max_floor=f_opt_dec(b, 1, 86, qty),
        list_id=f_opt_i64(b, 1, 94),
        cash_order_qty=f_opt_dec(b, 1, 102, px),
        target_strategy=f_opt_i32(b, 1, 110),
        strategy_id=f_opt_i64(b, 1, 114),
        order_capacity=f_opt_char(b, 1, 122),
        self_trade_prevention_mode=f_opt_char(b, 1, 123),
        exec_type=f_u8(b, 1, 124),
        cum_qty=f_dec(b, 1, 125, qty),
        leaves_qty=f_opt_dec(b, 1, 133, qty),
        cum_quote_qty=f_opt_dec(b, 1, 141, px),
        aggressor_indicator=f_opt_u8(b, 1, 149),
        trade_id=f_opt_i64(b, 1, 150),
        last_px=f_opt_dec(b, 1, 158, px),
        last_qty=f_dec(b, 1, 166, qty),
        ord_status=f_u8(b, 1, 174),
        secondary_order_id=f_opt_i64(b, 1, 175),
        secondary_external_account_id=f_opt_i64(b, 1, 183),
        alloc_id=f_opt_i64(b, 1, 191),
        match_type=f_opt_char(b, 1, 199),
        working_floor=f_opt_u8(b, 1, 200),
        working_indicator=f_opt_u8(b, 1, 201),
        working_time=f_opt_i64(b, 1, 202),
        trailing_time=f_opt_i64(b, 1, 210),
        prevented_match_id=f_opt_i64(b, 1, 218),
        prevented_execution_price=f_opt_dec(b, 1, 226, px),
        prevented_execution_qty=f_opt_dec(b, 1, 234, qty),
        trade_group_id=f_opt_i64(b, 1, 242),
        counter_order_id=f_opt_i64(b, 1, 250),
        prevented_qty=f_opt_dec(b, 1, 258, qty),
        last_prevented_qty=f_opt_dec(b, 1, 266, qty),
        sor=f_opt_u8(b, 1, 274),
        ord_rej_reason=f_opt_u8(b, 1, 275),
        error_code=f_opt_i32(b, 1, 276),
        expiry_reason=has(ER_EXPIRY_REASON_OFFSET, 1) ? f_opt_u8(b, 1, ER_EXPIRY_REASON_OFFSET) : nothing,
        quote_notional_limit=has(ER_QUOTE_NOTIONAL_LIMIT_OFFSET, 8) ?
            f_opt_dec(b, 1, ER_QUOTE_NOTIONAL_LIMIT_OFFSET, px) : nothing,
        effective_self_trade_prevention_mode=has(ER_EFFECTIVE_STP_OFFSET, 1) ?
            f_opt_char(b, 1, ER_EFFECTIVE_STP_OFFSET) : nothing,
        fees=fees,
        cl_ord_id=cl_ord_id,
        orig_cl_ord_id=orig_cl_ord_id,
        symbol=symbol,
        secondary_symbol=secondary_symbol,
        counter_symbol=counter_symbol,
        text=text,
    )
end

"""Decode ExecutionReportAck message (mini report)"""
function decode_execution_report_ack(header::FIXSBEMessageHeader, body::Vector{UInt8})
    # OrderID i64 (0), ListID i64 (8), TransactTime i64 (16), ExecType char (24),
    # OrdStatus char (25), OrdRejReason u8 (26), ErrorCode i32 (27)
    block = require_block(body, header, 31, "ExecutionReportAck")
    offset = block + 1
    cl_ord_id, offset = read_var_string8(body, offset)
    symbol, offset = read_var_string8(body, offset)
    text, offset = read_var_string16(body, offset)

    return SBEExecutionReportAck(
        header.seqNum, header.sendingTime,
        f_opt_i64(body, 1, 0), f_opt_i64(body, 1, 8), cl_ord_id, symbol,
        f_u8(body, 1, 24), f_u8(body, 1, 25), f_opt_u8(body, 1, 26),
        f_opt_i64(body, 1, 16), f_opt_i32(body, 1, 27), text
    )
end

"""Decode OrderCancelReject message"""
function decode_order_cancel_reject(header::FIXSBEMessageHeader, body::Vector{UInt8})
    # OrderID i64 (0), ListID i64 (8), CancelRestrictions u8 (16),
    # CxlRejResponseTo char (17), ErrorCode i32 (18)
    block = require_block(body, header, 22, "OrderCancelReject")
    offset = block + 1
    cl_ord_id, offset = read_var_string8(body, offset)
    orig_cl_ord_id, offset = read_var_string8(body, offset)
    orig_cl_list_id, offset = read_var_string8(body, offset)
    symbol, offset = read_var_string8(body, offset)
    text, offset = read_var_string16(body, offset)

    return SBEOrderCancelReject(
        header.seqNum, header.sendingTime,
        f_opt_i64(body, 1, 0), f_opt_i64(body, 1, 8),
        cl_ord_id, orig_cl_ord_id, orig_cl_list_id, symbol,
        f_opt_u8(body, 1, 16), f_u8(body, 1, 17), f_i32(body, 1, 18), text
    )
end

"""Decode ListStatus message"""
function decode_list_status(header::FIXSBEMessageHeader, body::Vector{UInt8})
    # ListID i64 (0), ContingencyType u8 (8), ListStatusType u8 (9),
    # ListOrderStatus u8 (10), ListRejectReason u8 (11), TransactTime i64 (12)
    block = require_block(body, header, 20, "ListStatus")

    # Orders group: smallGroupSize8Encoding. Entry: OrderID i64 (0),
    # OrdRejReason u8 (8), ErrorCode i32 (9); then a nested
    # ListTriggeringInstructions group and three var-data fields.
    order_block, order_count, offset = group_dims(body, block + 1, 1, 1, "ListStatus Orders")
    orders = SBEListStatusOrder[]
    if order_count > 0
        require_entry(order_block, 13, "ListStatus Orders")
        for _ in 1:order_count
            order_id = f_opt_i64(body, offset, 0)
            ord_rej_reason = f_opt_u8(body, offset, 8)
            error_code = f_opt_i32(body, offset, 9)

            instr_block, instr_count, pos = group_dims(body, offset + order_block, 1, 1,
                "ListTriggeringInstructions")
            instructions = NTuple{3,UInt8}[]
            if instr_count > 0
                require_entry(instr_block, 3, "ListTriggeringInstructions")
                for _ in 1:instr_count
                    push!(instructions, (f_u8(body, pos, 0), f_u8(body, pos, 1), f_u8(body, pos, 2)))
                    pos += instr_block
                end
            end

            cl_ord_id, pos = read_var_string8(body, pos)
            symbol, pos = read_var_string8(body, pos)
            text, pos = read_var_string16(body, pos)
            push!(orders, SBEListStatusOrder(symbol, order_id, cl_ord_id,
                ord_rej_reason, error_code, text, instructions))
            offset = pos
        end
    end

    cl_list_id, offset = read_var_string8(body, offset)
    orig_cl_list_id, offset = read_var_string8(body, offset)

    return SBEListStatus(
        header.seqNum, header.sendingTime,
        f_opt_i64(body, 1, 0), cl_list_id, orig_cl_list_id,
        f_opt_u8(body, 1, 8), f_u8(body, 1, 9), f_u8(body, 1, 10), f_opt_u8(body, 1, 11),
        f_opt_i64(body, 1, 12), orders
    )
end

"""Decode OrderMassCancelReport message"""
function decode_order_mass_cancel_report(header::FIXSBEMessageHeader, body::Vector{UInt8})
    # MassCancelRequestType char (0), MassCancelResponse char (1),
    # MassCancelRejectReason u8 (2), TotalAffectedOrders i64 (3), ErrorCode i32 (11)
    block = require_block(body, header, 15, "OrderMassCancelReport")
    offset = block + 1
    symbol, offset = read_var_string8(body, offset)
    cl_ord_id, offset = read_var_string8(body, offset)
    text, offset = read_var_string16(body, offset)

    return SBEOrderMassCancelReport(
        header.seqNum, header.sendingTime,
        cl_ord_id, symbol,
        f_u8(body, 1, 0), f_u8(body, 1, 1), f_opt_u8(body, 1, 2),
        f_opt_i64(body, 1, 3), f_opt_i32(body, 1, 11), text
    )
end

"""Decode OrderAmendReject message"""
function decode_order_amend_reject(header::FIXSBEMessageHeader, body::Vector{UInt8})
    # OrderID i64 (0), QtyExponent i8 (8), OrderQty mantissa (9), ErrorCode i32 (17)
    block = require_block(body, header, 21, "OrderAmendReject")
    offset = block + 1
    cl_ord_id, offset = read_var_string8(body, offset)
    orig_cl_ord_id, offset = read_var_string8(body, offset)
    symbol, offset = read_var_string8(body, offset)
    text, offset = read_var_string16(body, offset)

    return SBEOrderAmendReject(
        header.seqNum, header.sendingTime,
        f_opt_i64(body, 1, 0), cl_ord_id, orig_cl_ord_id, symbol,
        f_dec(body, 1, 9, f_i8(body, 1, 8)), f_i32(body, 1, 17), text
    )
end

"""Decode LimitResponse message"""
function decode_limit_response(header::FIXSBEMessageHeader, body::Vector{UInt8})
    block = require_block(body, header, 0, "LimitResponse")

    # LimitIndicators group: smallGroupSize8Encoding. Entry: LimitType char (0),
    # LimitCount u64 (1), LimitMax u64 (9), LimitResetInterval u32 (17),
    # LimitResetIntervalResolution char (21)
    entry_block, count, offset = group_dims(body, block + 1, 1, 1, "LimitIndicators")
    limits = SBELimitIndicator[]
    if count > 0
        require_entry(entry_block, 22, "LimitIndicators")
        for _ in 1:count
            push!(limits, SBELimitIndicator(
                f_u8(body, offset, 0), f_u64(body, offset, 1), f_u64(body, offset, 9),
                f_opt_u32(body, offset, 17), f_opt_char(body, offset, 21)
            ))
            offset += entry_block
        end
    end

    req_id, offset = read_var_string8(body, offset)
    return SBELimitResponse(header.seqNum, header.sendingTime, req_id, limits)
end

# One side of a book: entries of MDEntryPx mantissa (0), MDEntrySize mantissa (8).
# Returns the (price, size) pairs and the index after the group.
function read_book_side(body::Vector{UInt8}, pos::Int, block_bytes::Int, count_bytes::Int,
    px::Int8, qty::Int8, name::String)
    entry_block, count, offset = group_dims(body, pos, block_bytes, count_bytes, name)
    levels = Tuple{Float64,Union{Float64,Nothing}}[]
    if count > 0
        require_entry(entry_block, 16, name)
        sizehint!(levels, count)
        for _ in 1:count
            push!(levels, (f_dec(body, offset, 0, px), f_opt_dec(body, offset, 8, qty)))
            offset += entry_block
        end
    end
    return levels, offset
end

function book_entries(bids, asks, symbol::String, first_id, last_id)
    entries = SBEMDEntry[]
    sizehint!(entries, length(bids) + length(asks))
    for (price, size) in bids
        push!(entries, SBEMDEntry(SBE_MD_ENTRY_BID, price, size, symbol, nothing, nothing, nothing, first_id, last_id))
    end
    for (price, size) in asks
        push!(entries, SBEMDEntry(SBE_MD_ENTRY_OFFER, price, size, symbol, nothing, nothing, nothing, first_id, last_id))
    end
    return entries
end

"""Decode MarketDataSnapshot message"""
function decode_market_data_snapshot(header::FIXSBEMessageHeader, body::Vector{UInt8})
    # LastBookUpdateID i64 (0), PriceExponent i8 (8), QtyExponent i8 (9);
    # bid and ask groups use smallGroupSize16Encoding
    block = require_block(body, header, 10, "MarketDataSnapshot")
    last_id = f_opt_i64(body, 1, 0)
    px, qty = f_i8(body, 1, 8), f_i8(body, 1, 9)

    bids, offset = read_book_side(body, block + 1, 1, 2, px, qty, "MDEntriesBids")
    asks, offset = read_book_side(body, offset, 1, 2, px, qty, "MDEntriesAsks")
    symbol, offset = read_var_string8(body, offset)

    return SBEMarketDataSnapshot(header.seqNum, header.sendingTime, symbol, last_id,
        book_entries(bids, asks, symbol, nothing, last_id))
end

"""Decode MarketDataRequestReject message"""
function decode_market_data_reject(header::FIXSBEMessageHeader, body::Vector{UInt8})
    # MDReqRejReason char (0), ErrorCode i32 (1)
    block = require_block(body, header, 5, "MarketDataRequestReject")
    offset = block + 1
    md_req_id, offset = read_var_string8(body, offset)
    text, offset = read_var_string16(body, offset)

    return SBEMarketDataReject(
        header.seqNum, header.sendingTime,
        md_req_id, f_opt_char(body, 1, 0), f_opt_i32(body, 1, 1), text
    )
end

"""Decode MarketDataIncrementalTrade message"""
function decode_market_data_incremental_trade(header::FIXSBEMessageHeader, body::Vector{UInt8})
    # TransactTime i64 (0), PriceExponent i8 (8), QtyExponent i8 (9)
    block = require_block(body, header, 10, "MarketDataIncrementalTrade")
    transact_time = f_i64(body, 1, 0)
    px, qty = f_i8(body, 1, 8), f_i8(body, 1, 9)

    # MDEntries group: groupSize32Encoding (blockLength uint16, numInGroup uint32).
    # Entry: TradeID i64 (0), MDEntryPx (8), MDEntrySize (16), AggressorSide char (24)
    entry_block, count, offset = group_dims(body, block + 1, 2, 4, "MDEntries")
    trades = Tuple{Int64,Float64,Float64,Union{UInt8,Nothing}}[]
    if count > 0
        require_entry(entry_block, 25, "MDEntries")
        sizehint!(trades, count)
        for _ in 1:count
            push!(trades, (f_i64(body, offset, 0), f_dec(body, offset, 8, px),
                f_dec(body, offset, 16, qty), f_opt_char(body, offset, 24)))
            offset += entry_block
        end
    end
    symbol, offset = read_var_string8(body, offset)

    entries = SBEMDEntry[
        SBEMDEntry(SBE_MD_ENTRY_TRADE, price, size, symbol, transact_time, trade_id, side, nothing, nothing)
        for (trade_id, price, size, side) in trades
    ]
    return SBEMarketDataIncrementalTrade(header.seqNum, header.sendingTime, symbol, transact_time, entries)
end

"""Decode MarketDataIncrementalBookTicker message"""
function decode_market_data_incremental_book_ticker(header::FIXSBEMessageHeader, body::Vector{UInt8})
    # LastBookUpdateID i64 (0), PriceExponent i8 (8), QtyExponent i8 (9);
    # bid and ask groups use smallGroupSize8Encoding
    block = require_block(body, header, 10, "MarketDataIncrementalBookTicker")
    last_id = f_i64(body, 1, 0)
    px, qty = f_i8(body, 1, 8), f_i8(body, 1, 9)

    bids, offset = read_book_side(body, block + 1, 1, 1, px, qty, "MDEntriesBids")
    asks, offset = read_book_side(body, offset, 1, 1, px, qty, "MDEntriesAsks")
    symbol, offset = read_var_string8(body, offset)

    return SBEMarketDataIncrementalBookTicker(header.seqNum, header.sendingTime, symbol, last_id,
        book_entries(bids, asks, symbol, nothing, last_id))
end

"""Decode MarketDataIncrementalDepth message"""
function decode_market_data_incremental_depth(header::FIXSBEMessageHeader, body::Vector{UInt8})
    # FirstBookUpdateID i64 (0), LastBookUpdateID i64 (8), PriceExponent i8 (16),
    # QtyExponent i8 (17); bid and ask groups use smallGroupSize16Encoding
    block = require_block(body, header, 18, "MarketDataIncrementalDepth")
    first_id, last_id = f_i64(body, 1, 0), f_i64(body, 1, 8)
    px, qty = f_i8(body, 1, 16), f_i8(body, 1, 17)

    bids, offset = read_book_side(body, block + 1, 1, 2, px, qty, "MDEntriesBids")
    asks, offset = read_book_side(body, offset, 1, 2, px, qty, "MDEntriesAsks")
    symbol, offset = read_var_string8(body, offset)

    return SBEMarketDataIncrementalDepth(header.seqNum, header.sendingTime, symbol,
        first_id, last_id, book_entries(bids, asks, symbol, first_id, last_id))
end

"""Decode InstrumentList message"""
function decode_instrument_list(header::FIXSBEMessageHeader, body::Vector{UInt8})
    block = require_block(body, header, 0, "InstrumentList")

    # RelatedSym group: groupSize16Encoding (blockLength uint16, numInGroup uint16).
    # Entry: PriceExponent i8 (0), QtyExponent i8 (1), then nine optional mantissas.
    entry_block, count, offset = group_dims(body, block + 1, 2, 2, "RelatedSym")
    instruments = SBEInstrumentInfo[]
    if count > 0
        require_entry(entry_block, 74, "RelatedSym")
        sizehint!(instruments, count)
        for _ in 1:count
            px, qty = f_i8(body, offset, 0), f_i8(body, offset, 1)
            fixed = offset
            symbol, offset = read_var_string8(body, offset + entry_block)
            currency, offset = read_var_string8(body, offset)
            push!(instruments, SBEInstrumentInfo(
                symbol, currency,
                f_opt_dec(body, fixed, 2, qty),    # MinTradeVol
                f_opt_dec(body, fixed, 10, qty),   # MaxTradeVol
                f_opt_dec(body, fixed, 18, qty),   # MinQtyIncrement
                f_opt_dec(body, fixed, 26, qty),   # MarketMinTradeVol
                f_opt_dec(body, fixed, 34, qty),   # MarketMaxTradeVol
                f_opt_dec(body, fixed, 42, qty),   # MarketMinQtyIncrement
                f_opt_dec(body, fixed, 50, px),    # StartPriceRange
                f_opt_dec(body, fixed, 58, px),    # EndPriceRange
                f_opt_dec(body, fixed, 66, px),    # MinPriceIncrement
                px, qty
            ))
        end
    end

    instrument_req_id, offset = read_var_string8(body, offset)
    return SBEInstrumentList(header.seqNum, header.sendingTime, instrument_req_id, instruments)
end

# =============================================================================
# Main Decoder Dispatch
# =============================================================================

# templateId => (message kind, decoder). `decode_sbe_message` dispatches through
# this table; it is also what the tests iterate over.
const DECODERS = Dict{UInt16,Tuple{Symbol,Function}}(
    SBE_TEMPLATE_LOGON_ACK => (:logon_ack, decode_logon_ack),
    SBE_TEMPLATE_LOGOUT => (:logout, decode_logout),
    SBE_TEMPLATE_HEARTBEAT => (:heartbeat, decode_heartbeat),
    SBE_TEMPLATE_TEST_REQUEST => (:test_request, decode_test_request),
    SBE_TEMPLATE_REJECT => (:reject, decode_reject),
    SBE_TEMPLATE_NEWS => (:news, decode_news),
    SBE_TEMPLATE_EXECUTION_REPORT => (:execution_report, decode_execution_report),
    SBE_TEMPLATE_EXECUTION_REPORT_ACK => (:execution_report_ack, decode_execution_report_ack),
    SBE_TEMPLATE_ORDER_CANCEL_REJECT => (:order_cancel_reject, decode_order_cancel_reject),
    SBE_TEMPLATE_LIST_STATUS => (:list_status, decode_list_status),
    SBE_TEMPLATE_ORDER_MASS_CANCEL_REPORT => (:order_mass_cancel_report, decode_order_mass_cancel_report),
    SBE_TEMPLATE_ORDER_AMEND_REJECT => (:order_amend_reject, decode_order_amend_reject),
    SBE_TEMPLATE_LIMIT_RESPONSE => (:limit_response, decode_limit_response),
    SBE_TEMPLATE_MARKET_DATA_SNAPSHOT => (:market_data_snapshot, decode_market_data_snapshot),
    SBE_TEMPLATE_MARKET_DATA_REQUEST_REJECT => (:market_data_reject, decode_market_data_reject),
    SBE_TEMPLATE_MARKET_DATA_INCREMENTAL_TRADE => (:market_data_incremental_trade, decode_market_data_incremental_trade),
    SBE_TEMPLATE_MARKET_DATA_INCREMENTAL_BOOK_TICKER => (:market_data_incremental_book_ticker, decode_market_data_incremental_book_ticker),
    SBE_TEMPLATE_MARKET_DATA_INCREMENTAL_DEPTH => (:market_data_incremental_depth, decode_market_data_incremental_depth),
    SBE_TEMPLATE_INSTRUMENT_LIST => (:instrument_list, decode_instrument_list),
)

"""
    decode_sbe_message(data::Vector{UInt8}) -> (Symbol, Any)

Decode a complete FIX SBE message and return (message_type_symbol, decoded_struct).
An unknown template yields `(:unknown, FIXSBEMessage)`.
"""
function decode_sbe_message(data::Vector{UInt8})
    msg = decode_fix_sbe_message(data)
    entry = get(DECODERS, msg.header.templateId, nothing)
    isnothing(entry) && return (:unknown, msg)
    kind, decoder = entry
    return (kind, decoder(msg.header, msg.body))
end

end # module FIXSBEDecoder
