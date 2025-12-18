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
export SBEInstrumentList, SBEInstrumentInfo, SBEMDEntry, SBEMiscFee

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

# =============================================================================
# Decoded Message Structures
# =============================================================================

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
    ref_seq_num::UInt32
    ref_tag_id::UInt16
    ref_msg_type::String
    session_reject_reason::UInt8
    error_code::Int32
    text::String
end

"""News message (templateId=20100)"""
struct SBENews
    seq_num::UInt32
    sending_time::Int64
    headline::String
    text::String
    urgency::UInt8
end

"""Miscellaneous fee entry"""
struct SBEMiscFee
    amount::Float64      # mantissa with exponent -8
    currency::String
    fee_type::UInt8
end

"""ExecutionReport (templateId=98)"""
struct SBEExecutionReport
    seq_num::UInt32
    sending_time::Int64

    # Order identification
    order_id::UInt64
    cl_ord_id::String
    orig_cl_ord_id::String
    list_id::Union{UInt64,Nothing}
    exec_id::UInt64

    # Order details
    symbol::String
    side::UInt8
    ord_type::UInt8
    order_qty::Float64
    price::Union{Float64,Nothing}
    time_in_force::UInt8

    # Execution status
    exec_type::UInt8
    ord_status::UInt8

    # Quantities
    cum_qty::Float64
    leaves_qty::Float64
    cum_quote_qty::Float64
    last_qty::Union{Float64,Nothing}
    last_px::Union{Float64,Nothing}

    # Timestamps
    transact_time::Int64  # microseconds
    order_creation_time::Union{Int64,Nothing}
    working_time::Union{Int64,Nothing}

    # Trade details
    trade_id::Union{UInt64,Nothing}
    aggressor_indicator::Union{UInt8,Nothing}
    working_indicator::Union{UInt8,Nothing}

    # Self-trade prevention
    self_trade_prevention_mode::Union{UInt8,Nothing}
    prevented_match_id::Union{UInt64,Nothing}
    prevented_qty::Union{Float64,Nothing}

    # Trigger fields
    trigger_price::Union{Float64,Nothing}
    trigger_price_direction::Union{UInt8,Nothing}

    # Fees
    fees::Vector{SBEMiscFee}

    # Error info
    error_code::Union{Int32,Nothing}
    text::String
end

"""ExecutionReportAck (templateId=198) - Mini execution report"""
struct SBEExecutionReportAck
    seq_num::UInt32
    sending_time::Int64
    order_id::UInt64
    cl_ord_id::String
    symbol::String
    exec_type::UInt8
    ord_status::UInt8
    transact_time::Int64
    error_code::Union{Int32,Nothing}
    text::String
end

"""OrderCancelReject (templateId=96)"""
struct SBEOrderCancelReject
    seq_num::UInt32
    sending_time::Int64
    order_id::Union{UInt64,Nothing}
    cl_ord_id::String
    orig_cl_ord_id::String
    symbol::String
    cxl_rej_response_to::UInt8
    error_code::Int32
    text::String
end

"""ListStatus order entry"""
struct SBEListStatusOrder
    symbol::String
    order_id::UInt64
    cl_ord_id::String
end

"""ListStatus (templateId=102)"""
struct SBEListStatus
    seq_num::UInt32
    sending_time::Int64
    list_id::UInt64
    cl_list_id::String
    contingency_type::UInt8
    list_status_type::UInt8
    list_order_status::UInt8
    list_reject_reason::Union{UInt8,Nothing}
    transact_time::Int64
    orders::Vector{SBEListStatusOrder}
    error_code::Union{Int32,Nothing}
    text::String
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
    total_affected_orders::UInt32
    error_code::Union{Int32,Nothing}
    text::String
end

"""OrderAmendReject (templateId=106)"""
struct SBEOrderAmendReject
    seq_num::UInt32
    sending_time::Int64
    order_id::Union{UInt64,Nothing}
    cl_ord_id::String
    orig_cl_ord_id::String
    symbol::String
    order_qty::Float64
    error_code::Int32
    text::String
end

"""Limit indicator entry"""
struct SBELimitIndicator
    limit_type::UInt8
    limit_count::UInt32
    limit_max::UInt32
    limit_reset_interval::UInt32
    limit_reset_interval_resolution::UInt8
end

"""LimitResponse (templateId=121)"""
struct SBELimitResponse
    seq_num::UInt32
    sending_time::Int64
    req_id::String
    limits::Vector{SBELimitIndicator}
end

"""Market data entry"""
struct SBEMDEntry
    entry_type::UInt8       # 0=Bid, 1=Offer, 2=Trade
    price::Float64
    size::Float64
    update_action::Union{UInt8,Nothing}  # 0=New, 1=Change, 2=Delete
    symbol::String
    transact_time::Union{Int64,Nothing}
    trade_id::Union{UInt64,Nothing}
    aggressor_side::Union{UInt8,Nothing}
    first_book_update_id::Union{UInt64,Nothing}
    last_book_update_id::Union{UInt64,Nothing}
end

"""MarketDataSnapshot (templateId=204)"""
struct SBEMarketDataSnapshot
    seq_num::UInt32
    sending_time::Int64
    md_req_id::String
    symbol::String
    last_book_update_id::UInt64
    entries::Vector{SBEMDEntry}
end

"""MarketDataRequestReject (templateId=203)"""
struct SBEMarketDataReject
    seq_num::UInt32
    sending_time::Int64
    md_req_id::String
    reject_reason::UInt8
    error_code::Int32
    text::String
end

"""MarketDataIncrementalTrade (templateId=205)"""
struct SBEMarketDataIncrementalTrade
    seq_num::UInt32
    sending_time::Int64
    md_req_id::String
    entries::Vector{SBEMDEntry}
end

"""MarketDataIncrementalBookTicker (templateId=206)"""
struct SBEMarketDataIncrementalBookTicker
    seq_num::UInt32
    sending_time::Int64
    md_req_id::String
    entries::Vector{SBEMDEntry}
end

"""MarketDataIncrementalDepth (templateId=207)"""
struct SBEMarketDataIncrementalDepth
    seq_num::UInt32
    sending_time::Int64
    md_req_id::String
    first_book_update_id::UInt64
    last_book_update_id::UInt64
    entries::Vector{SBEMDEntry}
end

"""Instrument info"""
struct SBEInstrumentInfo
    symbol::String
    currency::String
    min_trade_vol::Float64
    max_trade_vol::Float64
    min_qty_increment::Float64
    market_min_trade_vol::Float64
    market_max_trade_vol::Float64
    market_min_qty_increment::Float64
    min_price_increment::Float64
end

"""InstrumentList (templateId=201)"""
struct SBEInstrumentList
    seq_num::UInt32
    sending_time::Int64
    instrument_req_id::String
    instruments::Vector{SBEInstrumentInfo}
end

# =============================================================================
# Message Decoder Functions
# =============================================================================

"""Decode LogonAck message"""
function decode_logon_ack(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1

    # Variable-length field: uuid
    uuid, offset = read_var_string8(body, offset)

    return SBELogonAck(header.seqNum, header.sendingTime, uuid)
end

"""Decode Logout message"""
function decode_logout(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1

    # Variable-length field: text
    text, offset = read_var_string16(body, offset)

    return SBELogout(header.seqNum, header.sendingTime, text)
end

"""Decode Heartbeat message"""
function decode_heartbeat(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1

    # Variable-length field: testReqId
    test_req_id, offset = read_var_string8(body, offset)

    return SBEHeartbeat(header.seqNum, header.sendingTime, test_req_id)
end

"""Decode TestRequest message"""
function decode_test_request(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1

    # Variable-length field: testReqId
    test_req_id, offset = read_var_string8(body, offset)

    return SBETestRequest(header.seqNum, header.sendingTime, test_req_id)
end

"""Decode Reject message"""
function decode_reject(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1

    # Fixed fields
    ref_seq_num = read_uint32(body, offset); offset += 4
    ref_tag_id = read_uint16(body, offset); offset += 2
    session_reject_reason = read_uint8(body, offset); offset += 1
    error_code = read_int32(body, offset); offset += 4

    # Variable-length fields
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
    offset = 1

    # Fixed fields
    urgency = read_uint8(body, offset); offset += 1

    # Variable-length fields
    headline, offset = read_var_string8(body, offset)
    text, offset = read_var_string16(body, offset)

    return SBENews(header.seqNum, header.sendingTime, headline, text, urgency)
end

"""Helper to read int32 (little-endian)"""
function read_int32(data::Vector{UInt8}, offset::Int)
    return reinterpret(Int32, data[offset:offset+3])[1]
end

"""Decode ExecutionReport message"""
function decode_execution_report(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1
    QTY_EXP = Int8(-8)

    # Fixed fields
    order_id = read_uint64(body, offset); offset += 8
    list_id_raw = read_uint64(body, offset); offset += 8
    list_id = list_id_raw == SBE_UINT64_NULL ? nothing : list_id_raw
    exec_id = read_uint64(body, offset); offset += 8

    side = read_uint8(body, offset); offset += 1
    ord_type = read_uint8(body, offset); offset += 1
    time_in_force = read_uint8(body, offset); offset += 1
    exec_type = read_uint8(body, offset); offset += 1
    ord_status = read_uint8(body, offset); offset += 1

    # Quantities (mantissa64)
    order_qty_m = read_int64(body, offset); offset += 8
    order_qty = mantissa_to_float(order_qty_m, QTY_EXP)

    price_m = read_int64(body, offset); offset += 8
    price = price_m == SBE_INT64_NULL ? nothing : mantissa_to_float(price_m, QTY_EXP)

    cum_qty_m = read_int64(body, offset); offset += 8
    cum_qty = mantissa_to_float(cum_qty_m, QTY_EXP)

    leaves_qty_m = read_int64(body, offset); offset += 8
    leaves_qty = mantissa_to_float(leaves_qty_m, QTY_EXP)

    cum_quote_qty_m = read_int64(body, offset); offset += 8
    cum_quote_qty = mantissa_to_float(cum_quote_qty_m, QTY_EXP)

    last_qty_m = read_int64(body, offset); offset += 8
    last_qty = last_qty_m == SBE_INT64_NULL ? nothing : mantissa_to_float(last_qty_m, QTY_EXP)

    last_px_m = read_int64(body, offset); offset += 8
    last_px = last_px_m == SBE_INT64_NULL ? nothing : mantissa_to_float(last_px_m, QTY_EXP)

    transact_time = read_int64(body, offset); offset += 8

    order_creation_time_raw = read_int64(body, offset); offset += 8
    order_creation_time = order_creation_time_raw == SBE_INT64_NULL ? nothing : order_creation_time_raw

    working_time_raw = read_int64(body, offset); offset += 8
    working_time = working_time_raw == SBE_INT64_NULL ? nothing : working_time_raw

    trade_id_raw = read_uint64(body, offset); offset += 8
    trade_id = trade_id_raw == SBE_UINT64_NULL ? nothing : trade_id_raw

    aggressor_raw = read_uint8(body, offset); offset += 1
    aggressor_indicator = aggressor_raw == SBE_UINT8_NULL ? nothing : aggressor_raw

    working_raw = read_uint8(body, offset); offset += 1
    working_indicator = working_raw == SBE_UINT8_NULL ? nothing : working_raw

    stp_raw = read_uint8(body, offset); offset += 1
    self_trade_prevention_mode = stp_raw == SBE_UINT8_NULL ? nothing : stp_raw

    prevented_match_id_raw = read_uint64(body, offset); offset += 8
    prevented_match_id = prevented_match_id_raw == SBE_UINT64_NULL ? nothing : prevented_match_id_raw

    prevented_qty_m = read_int64(body, offset); offset += 8
    prevented_qty = prevented_qty_m == SBE_INT64_NULL ? nothing : mantissa_to_float(prevented_qty_m, QTY_EXP)

    trigger_price_m = read_int64(body, offset); offset += 8
    trigger_price = trigger_price_m == SBE_INT64_NULL ? nothing : mantissa_to_float(trigger_price_m, QTY_EXP)

    trigger_dir_raw = read_uint8(body, offset); offset += 1
    trigger_price_direction = trigger_dir_raw == SBE_UINT8_NULL ? nothing : trigger_dir_raw

    error_code_raw = read_int32(body, offset); offset += 4
    error_code = error_code_raw == typemax(Int32) ? nothing : error_code_raw

    # Skip any remaining fixed fields to reach groups
    # Read NoMiscFees group
    fees = SBEMiscFee[]
    if offset + 2 < length(body)
        group_block_length = read_uint16(body, offset); offset += 2
        num_fees = read_uint8(body, offset); offset += 1
        for _ in 1:num_fees
            fee_amt_m = read_int64(body, offset); offset += 8
            fee_type = read_uint8(body, offset); offset += 1
            # Skip to var data for currency
            fee_currency, offset = read_var_string8(body, offset)
            push!(fees, SBEMiscFee(
                mantissa_to_float(fee_amt_m, QTY_EXP),
                fee_currency,
                fee_type
            ))
        end
    end

    # Variable-length fields
    cl_ord_id, offset = read_var_string8(body, offset)
    orig_cl_ord_id, offset = read_var_string8(body, offset)
    symbol, offset = read_var_string8(body, offset)
    text, offset = read_var_string16(body, offset)

    return SBEExecutionReport(
        header.seqNum, header.sendingTime,
        order_id, cl_ord_id, orig_cl_ord_id, list_id, exec_id,
        symbol, side, ord_type, order_qty, price, time_in_force,
        exec_type, ord_status,
        cum_qty, leaves_qty, cum_quote_qty, last_qty, last_px,
        transact_time, order_creation_time, working_time,
        trade_id, aggressor_indicator, working_indicator,
        self_trade_prevention_mode, prevented_match_id, prevented_qty,
        trigger_price, trigger_price_direction,
        fees, error_code, text
    )
end

"""Decode ExecutionReportAck message (mini report)"""
function decode_execution_report_ack(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1

    # Fixed fields
    order_id = read_uint64(body, offset); offset += 8
    exec_type = read_uint8(body, offset); offset += 1
    ord_status = read_uint8(body, offset); offset += 1
    transact_time = read_int64(body, offset); offset += 8

    error_code_raw = read_int32(body, offset); offset += 4
    error_code = error_code_raw == typemax(Int32) ? nothing : error_code_raw

    # Variable-length fields
    cl_ord_id, offset = read_var_string8(body, offset)
    symbol, offset = read_var_string8(body, offset)
    text, offset = read_var_string16(body, offset)

    return SBEExecutionReportAck(
        header.seqNum, header.sendingTime,
        order_id, cl_ord_id, symbol,
        exec_type, ord_status, transact_time,
        error_code, text
    )
end

"""Decode OrderCancelReject message"""
function decode_order_cancel_reject(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1

    # Fixed fields
    order_id_raw = read_uint64(body, offset); offset += 8
    order_id = order_id_raw == SBE_UINT64_NULL ? nothing : order_id_raw

    cxl_rej_response_to = read_uint8(body, offset); offset += 1
    error_code = read_int32(body, offset); offset += 4

    # Variable-length fields
    cl_ord_id, offset = read_var_string8(body, offset)
    orig_cl_ord_id, offset = read_var_string8(body, offset)
    symbol, offset = read_var_string8(body, offset)
    text, offset = read_var_string16(body, offset)

    return SBEOrderCancelReject(
        header.seqNum, header.sendingTime,
        order_id, cl_ord_id, orig_cl_ord_id, symbol,
        cxl_rej_response_to, error_code, text
    )
end

"""Decode ListStatus message"""
function decode_list_status(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1

    # Fixed fields
    list_id = read_uint64(body, offset); offset += 8
    contingency_type = read_uint8(body, offset); offset += 1
    list_status_type = read_uint8(body, offset); offset += 1
    list_order_status = read_uint8(body, offset); offset += 1

    list_rej_raw = read_uint8(body, offset); offset += 1
    list_reject_reason = list_rej_raw == SBE_UINT8_NULL ? nothing : list_rej_raw

    transact_time = read_int64(body, offset); offset += 8

    error_code_raw = read_int32(body, offset); offset += 4
    error_code = error_code_raw == typemax(Int32) ? nothing : error_code_raw

    # Read NoOrders group
    orders = SBEListStatusOrder[]
    if offset + 2 < length(body)
        group_block_length = read_uint16(body, offset); offset += 2
        num_orders = read_uint8(body, offset); offset += 1

        for _ in 1:num_orders
            o_order_id = read_uint64(body, offset); offset += 8
            # Variable fields for this order
            o_symbol, offset = read_var_string8(body, offset)
            o_cl_ord_id, offset = read_var_string8(body, offset)
            push!(orders, SBEListStatusOrder(o_symbol, o_order_id, o_cl_ord_id))
        end
    end

    # Variable-length fields
    cl_list_id, offset = read_var_string8(body, offset)
    text, offset = read_var_string16(body, offset)

    return SBEListStatus(
        header.seqNum, header.sendingTime,
        list_id, cl_list_id, contingency_type,
        list_status_type, list_order_status, list_reject_reason,
        transact_time, orders, error_code, text
    )
end

"""Decode OrderMassCancelReport message"""
function decode_order_mass_cancel_report(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1

    # Fixed fields
    mass_cancel_request_type = read_uint8(body, offset); offset += 1
    mass_cancel_response = read_uint8(body, offset); offset += 1

    mass_cancel_rej_raw = read_uint8(body, offset); offset += 1
    mass_cancel_reject_reason = mass_cancel_rej_raw == SBE_UINT8_NULL ? nothing : mass_cancel_rej_raw

    total_affected_orders = read_uint32(body, offset); offset += 4

    error_code_raw = read_int32(body, offset); offset += 4
    error_code = error_code_raw == typemax(Int32) ? nothing : error_code_raw

    # Variable-length fields
    cl_ord_id, offset = read_var_string8(body, offset)
    symbol, offset = read_var_string8(body, offset)
    text, offset = read_var_string16(body, offset)

    return SBEOrderMassCancelReport(
        header.seqNum, header.sendingTime,
        cl_ord_id, symbol,
        mass_cancel_request_type, mass_cancel_response, mass_cancel_reject_reason,
        total_affected_orders, error_code, text
    )
end

"""Decode OrderAmendReject message"""
function decode_order_amend_reject(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1
    QTY_EXP = Int8(-8)

    # Fixed fields
    order_id_raw = read_uint64(body, offset); offset += 8
    order_id = order_id_raw == SBE_UINT64_NULL ? nothing : order_id_raw

    order_qty_m = read_int64(body, offset); offset += 8
    order_qty = mantissa_to_float(order_qty_m, QTY_EXP)

    error_code = read_int32(body, offset); offset += 4

    # Variable-length fields
    cl_ord_id, offset = read_var_string8(body, offset)
    orig_cl_ord_id, offset = read_var_string8(body, offset)
    symbol, offset = read_var_string8(body, offset)
    text, offset = read_var_string16(body, offset)

    return SBEOrderAmendReject(
        header.seqNum, header.sendingTime,
        order_id, cl_ord_id, orig_cl_ord_id, symbol,
        order_qty, error_code, text
    )
end

"""Decode LimitResponse message"""
function decode_limit_response(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1

    # Read NoLimitIndicators group
    limits = SBELimitIndicator[]
    if offset + 2 < length(body)
        group_block_length = read_uint16(body, offset); offset += 2
        num_limits = read_uint8(body, offset); offset += 1

        for _ in 1:num_limits
            limit_type = read_uint8(body, offset); offset += 1
            limit_count = read_uint32(body, offset); offset += 4
            limit_max = read_uint32(body, offset); offset += 4
            limit_reset_interval = read_uint32(body, offset); offset += 4
            limit_reset_interval_res = read_uint8(body, offset); offset += 1

            push!(limits, SBELimitIndicator(
                limit_type, limit_count, limit_max,
                limit_reset_interval, limit_reset_interval_res
            ))
        end
    end

    # Variable-length field
    req_id, offset = read_var_string8(body, offset)

    return SBELimitResponse(header.seqNum, header.sendingTime, req_id, limits)
end

"""Decode MarketDataSnapshot message"""
function decode_market_data_snapshot(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1
    PRICE_EXP = Int8(-8)

    # Fixed fields
    last_book_update_id = read_uint64(body, offset); offset += 8

    # Read NoMDEntries group
    entries = SBEMDEntry[]
    if offset + 2 < length(body)
        group_block_length = read_uint16(body, offset); offset += 2
        num_entries = read_uint8(body, offset); offset += 1

        for _ in 1:num_entries
            entry_type = read_uint8(body, offset); offset += 1
            price_m = read_int64(body, offset); offset += 8
            size_m = read_int64(body, offset); offset += 8

            push!(entries, SBEMDEntry(
                entry_type,
                mantissa_to_float(price_m, PRICE_EXP),
                mantissa_to_float(size_m, PRICE_EXP),
                nothing, "", nothing, nothing, nothing, nothing,
                last_book_update_id
            ))
        end
    end

    # Variable-length fields
    md_req_id, offset = read_var_string8(body, offset)
    symbol, offset = read_var_string8(body, offset)

    # Update entries with symbol
    for i in eachindex(entries)
        entries[i] = SBEMDEntry(
            entries[i].entry_type, entries[i].price, entries[i].size,
            entries[i].update_action, symbol,
            entries[i].transact_time, entries[i].trade_id, entries[i].aggressor_side,
            entries[i].first_book_update_id, entries[i].last_book_update_id
        )
    end

    return SBEMarketDataSnapshot(
        header.seqNum, header.sendingTime,
        md_req_id, symbol, last_book_update_id, entries
    )
end

"""Decode MarketDataRequestReject message"""
function decode_market_data_reject(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1

    # Fixed fields
    reject_reason = read_uint8(body, offset); offset += 1
    error_code = read_int32(body, offset); offset += 4

    # Variable-length fields
    md_req_id, offset = read_var_string8(body, offset)
    text, offset = read_var_string16(body, offset)

    return SBEMarketDataReject(
        header.seqNum, header.sendingTime,
        md_req_id, reject_reason, error_code, text
    )
end

"""Decode MarketDataIncrementalTrade message"""
function decode_market_data_incremental_trade(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1
    PRICE_EXP = Int8(-8)

    # Read NoMDEntries group
    entries = SBEMDEntry[]
    if offset + 2 < length(body)
        group_block_length = read_uint16(body, offset); offset += 2
        num_entries = read_uint8(body, offset); offset += 1

        for _ in 1:num_entries
            price_m = read_int64(body, offset); offset += 8
            size_m = read_int64(body, offset); offset += 8
            transact_time = read_int64(body, offset); offset += 8
            trade_id = read_uint64(body, offset); offset += 8
            aggressor_side = read_uint8(body, offset); offset += 1

            # Variable field for symbol
            symbol, offset = read_var_string8(body, offset)

            push!(entries, SBEMDEntry(
                UInt8(2),  # Trade
                mantissa_to_float(price_m, PRICE_EXP),
                mantissa_to_float(size_m, PRICE_EXP),
                UInt8(0),  # New
                symbol,
                transact_time, trade_id, aggressor_side,
                nothing, nothing
            ))
        end
    end

    # Variable-length field
    md_req_id, offset = read_var_string8(body, offset)

    return SBEMarketDataIncrementalTrade(
        header.seqNum, header.sendingTime,
        md_req_id, entries
    )
end

"""Decode MarketDataIncrementalBookTicker message"""
function decode_market_data_incremental_book_ticker(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1
    PRICE_EXP = Int8(-8)

    # Read NoMDEntries group
    entries = SBEMDEntry[]
    if offset + 2 < length(body)
        group_block_length = read_uint16(body, offset); offset += 2
        num_entries = read_uint8(body, offset); offset += 1

        for _ in 1:num_entries
            entry_type = read_uint8(body, offset); offset += 1
            price_m = read_int64(body, offset); offset += 8
            size_m = read_int64(body, offset); offset += 8
            last_book_update_id = read_uint64(body, offset); offset += 8

            # Variable field for symbol
            symbol, offset = read_var_string8(body, offset)

            push!(entries, SBEMDEntry(
                entry_type,
                mantissa_to_float(price_m, PRICE_EXP),
                mantissa_to_float(size_m, PRICE_EXP),
                UInt8(1),  # Change
                symbol,
                nothing, nothing, nothing,
                nothing, last_book_update_id
            ))
        end
    end

    # Variable-length field
    md_req_id, offset = read_var_string8(body, offset)

    return SBEMarketDataIncrementalBookTicker(
        header.seqNum, header.sendingTime,
        md_req_id, entries
    )
end

"""Decode MarketDataIncrementalDepth message"""
function decode_market_data_incremental_depth(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1
    PRICE_EXP = Int8(-8)

    # Fixed fields at message level
    first_book_update_id = read_uint64(body, offset); offset += 8
    last_book_update_id = read_uint64(body, offset); offset += 8

    # Read NoMDEntries group
    entries = SBEMDEntry[]
    if offset + 2 < length(body)
        group_block_length = read_uint16(body, offset); offset += 2
        num_entries = read_uint8(body, offset); offset += 1

        for _ in 1:num_entries
            update_action = read_uint8(body, offset); offset += 1
            entry_type = read_uint8(body, offset); offset += 1
            price_m = read_int64(body, offset); offset += 8
            size_m = read_int64(body, offset); offset += 8

            # Variable field for symbol
            symbol, offset = read_var_string8(body, offset)

            push!(entries, SBEMDEntry(
                entry_type,
                mantissa_to_float(price_m, PRICE_EXP),
                mantissa_to_float(size_m, PRICE_EXP),
                update_action,
                symbol,
                nothing, nothing, nothing,
                first_book_update_id, last_book_update_id
            ))
        end
    end

    # Variable-length field
    md_req_id, offset = read_var_string8(body, offset)

    return SBEMarketDataIncrementalDepth(
        header.seqNum, header.sendingTime,
        md_req_id, first_book_update_id, last_book_update_id, entries
    )
end

"""Decode InstrumentList message"""
function decode_instrument_list(header::FIXSBEMessageHeader, body::Vector{UInt8})
    offset = 1
    QTY_EXP = Int8(-8)

    # Read NoRelatedSym group
    instruments = SBEInstrumentInfo[]
    if offset + 2 < length(body)
        group_block_length = read_uint16(body, offset); offset += 2
        num_instruments = read_uint8(body, offset); offset += 1

        for _ in 1:num_instruments
            min_trade_vol_m = read_int64(body, offset); offset += 8
            max_trade_vol_m = read_int64(body, offset); offset += 8
            min_qty_increment_m = read_int64(body, offset); offset += 8
            market_min_trade_vol_m = read_int64(body, offset); offset += 8
            market_max_trade_vol_m = read_int64(body, offset); offset += 8
            market_min_qty_increment_m = read_int64(body, offset); offset += 8
            min_price_increment_m = read_int64(body, offset); offset += 8

            # Variable fields
            symbol, offset = read_var_string8(body, offset)
            currency, offset = read_var_string8(body, offset)

            push!(instruments, SBEInstrumentInfo(
                symbol, currency,
                mantissa_to_float(min_trade_vol_m, QTY_EXP),
                mantissa_to_float(max_trade_vol_m, QTY_EXP),
                mantissa_to_float(min_qty_increment_m, QTY_EXP),
                mantissa_to_float(market_min_trade_vol_m, QTY_EXP),
                mantissa_to_float(market_max_trade_vol_m, QTY_EXP),
                mantissa_to_float(market_min_qty_increment_m, QTY_EXP),
                mantissa_to_float(min_price_increment_m, QTY_EXP)
            ))
        end
    end

    # Variable-length field
    instrument_req_id, offset = read_var_string8(body, offset)

    return SBEInstrumentList(header.seqNum, header.sendingTime, instrument_req_id, instruments)
end

# =============================================================================
# Main Decoder Dispatch
# =============================================================================

"""
    decode_sbe_message(data::Vector{UInt8}) -> (Symbol, Any)

Decode a complete FIX SBE message and return (message_type_symbol, decoded_struct).
"""
function decode_sbe_message(data::Vector{UInt8})
    msg = decode_fix_sbe_message(data)
    header = msg.header
    body = msg.body

    if header.templateId == SBE_TEMPLATE_LOGON_ACK
        return (:logon_ack, decode_logon_ack(header, body))
    elseif header.templateId == SBE_TEMPLATE_LOGOUT
        return (:logout, decode_logout(header, body))
    elseif header.templateId == SBE_TEMPLATE_HEARTBEAT
        return (:heartbeat, decode_heartbeat(header, body))
    elseif header.templateId == SBE_TEMPLATE_TEST_REQUEST
        return (:test_request, decode_test_request(header, body))
    elseif header.templateId == SBE_TEMPLATE_REJECT
        return (:reject, decode_reject(header, body))
    elseif header.templateId == SBE_TEMPLATE_NEWS
        return (:news, decode_news(header, body))
    elseif header.templateId == SBE_TEMPLATE_EXECUTION_REPORT
        return (:execution_report, decode_execution_report(header, body))
    elseif header.templateId == SBE_TEMPLATE_EXECUTION_REPORT_ACK
        return (:execution_report_ack, decode_execution_report_ack(header, body))
    elseif header.templateId == SBE_TEMPLATE_ORDER_CANCEL_REJECT
        return (:order_cancel_reject, decode_order_cancel_reject(header, body))
    elseif header.templateId == SBE_TEMPLATE_LIST_STATUS
        return (:list_status, decode_list_status(header, body))
    elseif header.templateId == SBE_TEMPLATE_ORDER_MASS_CANCEL_REPORT
        return (:order_mass_cancel_report, decode_order_mass_cancel_report(header, body))
    elseif header.templateId == SBE_TEMPLATE_ORDER_AMEND_REJECT
        return (:order_amend_reject, decode_order_amend_reject(header, body))
    elseif header.templateId == SBE_TEMPLATE_LIMIT_RESPONSE
        return (:limit_response, decode_limit_response(header, body))
    elseif header.templateId == SBE_TEMPLATE_MARKET_DATA_SNAPSHOT
        return (:market_data_snapshot, decode_market_data_snapshot(header, body))
    elseif header.templateId == SBE_TEMPLATE_MARKET_DATA_REQUEST_REJECT
        return (:market_data_reject, decode_market_data_reject(header, body))
    elseif header.templateId == SBE_TEMPLATE_MARKET_DATA_INCREMENTAL_TRADE
        return (:market_data_incremental_trade, decode_market_data_incremental_trade(header, body))
    elseif header.templateId == SBE_TEMPLATE_MARKET_DATA_INCREMENTAL_BOOK_TICKER
        return (:market_data_incremental_book_ticker, decode_market_data_incremental_book_ticker(header, body))
    elseif header.templateId == SBE_TEMPLATE_MARKET_DATA_INCREMENTAL_DEPTH
        return (:market_data_incremental_depth, decode_market_data_incremental_depth(header, body))
    elseif header.templateId == SBE_TEMPLATE_INSTRUMENT_LIST
        return (:instrument_list, decode_instrument_list(header, body))
    else
        return (:unknown, msg)
    end
end

end # module FIXSBEDecoder
