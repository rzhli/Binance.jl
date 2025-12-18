"""
FIX SBE Encoder Module

Encodes FIX SBE (Simple Binary Encoding) messages for Binance FIX API.

Schema Information:
- Schema File: spot-fixsbe-1_0.xml
- Schema ID: 1
- Schema Version: 0
- Byte order: Little Endian

Wire Format:
<SOFH (6 bytes)> <message header (20 bytes)> <message (N bytes)>

Ports:
- 9001: FIX text request → SBE response
- 9002: SBE request → SBE response
"""
module FIXSBEEncoder

using Dates
using ..FIXConstants

export encode_sofh, encode_message_header
export encode_logon, encode_logout, encode_heartbeat, encode_test_request
export encode_new_order_single, encode_order_cancel_request, encode_order_mass_cancel_request
export encode_order_amend_keep_priority, encode_limit_query
export encode_market_data_request, encode_instrument_list_request
export SBEBuffer, write_uint8!, write_uint16!, write_uint32!, write_uint64!
export write_int8!, write_int64!, write_fixed_string!, write_var_string8!, write_var_string16!
export write_mantissa!, finalize_message!

# =============================================================================
# SBE Buffer for Building Messages
# =============================================================================

"""
SBE Buffer for building messages incrementally.
Handles SOFH + message header + body encoding.
"""
mutable struct SBEBuffer
    data::Vector{UInt8}
    position::Int
    body_start::Int  # Position where body starts (after headers)

    function SBEBuffer(initial_size::Int=1024)
        buf = new(zeros(UInt8, initial_size), 1, 0)
        # Reserve space for SOFH (6 bytes) + message header (20 bytes)
        buf.position = SBE_SOFH_SIZE + SBE_MESSAGE_HEADER_SIZE + 1
        buf.body_start = buf.position
        return buf
    end
end

"""Ensure buffer has enough capacity"""
function ensure_capacity!(buf::SBEBuffer, needed::Int)
    while buf.position + needed - 1 > length(buf.data)
        resize!(buf.data, length(buf.data) * 2)
    end
end

# =============================================================================
# Low-Level Write Functions (Little Endian)
# =============================================================================

function write_uint8!(buf::SBEBuffer, value::UInt8)
    ensure_capacity!(buf, 1)
    buf.data[buf.position] = value
    buf.position += 1
end

function write_int8!(buf::SBEBuffer, value::Int8)
    ensure_capacity!(buf, 1)
    buf.data[buf.position] = reinterpret(UInt8, value)
    buf.position += 1
end

function write_uint16!(buf::SBEBuffer, value::UInt16)
    ensure_capacity!(buf, 2)
    bytes = reinterpret(UInt8, [value])
    buf.data[buf.position:buf.position+1] = bytes
    buf.position += 2
end

function write_uint32!(buf::SBEBuffer, value::UInt32)
    ensure_capacity!(buf, 4)
    bytes = reinterpret(UInt8, [value])
    buf.data[buf.position:buf.position+3] = bytes
    buf.position += 4
end

function write_uint64!(buf::SBEBuffer, value::UInt64)
    ensure_capacity!(buf, 8)
    bytes = reinterpret(UInt8, [value])
    buf.data[buf.position:buf.position+7] = bytes
    buf.position += 8
end

function write_int64!(buf::SBEBuffer, value::Int64)
    ensure_capacity!(buf, 8)
    bytes = reinterpret(UInt8, [value])
    buf.data[buf.position:buf.position+7] = bytes
    buf.position += 8
end

"""Write fixed-length string, padding with nulls"""
function write_fixed_string!(buf::SBEBuffer, value::String, length::Int)
    ensure_capacity!(buf, length)
    bytes = Vector{UInt8}(value)
    actual_len = min(Base.length(bytes), length)
    buf.data[buf.position:buf.position+actual_len-1] = bytes[1:actual_len]
    # Pad with nulls
    for i in actual_len+1:length
        buf.data[buf.position+i-1] = 0x00
    end
    buf.position += length
end

"""Write variable-length string with uint8 length prefix"""
function write_var_string8!(buf::SBEBuffer, value::String)
    bytes = Vector{UInt8}(value)
    len = UInt8(min(Base.length(bytes), 255))
    write_uint8!(buf, len)
    if len > 0
        ensure_capacity!(buf, len)
        buf.data[buf.position:buf.position+len-1] = bytes[1:len]
        buf.position += len
    end
end

"""Write variable-length string with uint16 length prefix"""
function write_var_string16!(buf::SBEBuffer, value::String)
    bytes = Vector{UInt8}(value)
    len = UInt16(min(Base.length(bytes), 65535))
    write_uint16!(buf, len)
    if len > 0
        ensure_capacity!(buf, len)
        buf.data[buf.position:buf.position+len-1] = bytes[1:len]
        buf.position += len
    end
end

"""Write mantissa (int64) for decimal values. Returns NaN representation if value is NaN."""
function write_mantissa!(buf::SBEBuffer, value::Float64, exponent::Int8)
    if isnan(value)
        write_int64!(buf, SBE_INT64_NULL)
    else
        # Convert to mantissa: mantissa = value / 10^exponent
        mantissa = Int64(round(value / (10.0^Float64(exponent))))
        write_int64!(buf, mantissa)
    end
end

# =============================================================================
# Header Encoding
# =============================================================================

"""
Encode SOFH (Simple Open Framing Header) at the beginning of buffer.
Must be called after message body is complete to set correct length.
"""
function encode_sofh!(buf::SBEBuffer)
    # Total message length = current position - 1
    message_length = UInt32(buf.position - 1)

    # Write at position 1
    buf.data[1:4] = reinterpret(UInt8, [message_length])
    buf.data[5:6] = reinterpret(UInt8, [SBE_ENCODING_TYPE_LE])
end

"""
Encode message header at position 7.
"""
function encode_message_header!(buf::SBEBuffer, templateId::UInt16, seqNum::UInt32)
    # Block length = body size (excluding groups and var data, but for simplicity we include all)
    block_length = UInt16(buf.position - buf.body_start)

    # Sending time in microseconds since epoch
    sending_time = Int64(Dates.datetime2unix(now(Dates.UTC)) * 1_000_000)

    pos = SBE_SOFH_SIZE + 1  # Position 7

    # blockLength (2)
    buf.data[pos:pos+1] = reinterpret(UInt8, [block_length])
    # templateId (2)
    buf.data[pos+2:pos+3] = reinterpret(UInt8, [templateId])
    # schemaId (2)
    buf.data[pos+4:pos+5] = reinterpret(UInt8, [SBE_SCHEMA_ID_FIX])
    # version (2)
    buf.data[pos+6:pos+7] = reinterpret(UInt8, [SBE_SCHEMA_VERSION_FIX])
    # seqNum (4)
    buf.data[pos+8:pos+11] = reinterpret(UInt8, [seqNum])
    # sendingTime (8)
    buf.data[pos+12:pos+19] = reinterpret(UInt8, [sending_time])
end

"""Finalize message: encode headers and return complete message bytes"""
function finalize_message!(buf::SBEBuffer, templateId::UInt16, seqNum::UInt32)
    encode_message_header!(buf, templateId, seqNum)
    encode_sofh!(buf)
    return buf.data[1:buf.position-1]
end

# =============================================================================
# Admin Message Encoders
# =============================================================================

"""
Encode Logon message (templateId=20008)

Fields:
- senderCompId: varString8 (1-8 chars)
- targetCompId: varString8 (1-8 chars)
- msgSeqNum: uint32 (in header)
- sendingTime: utcTimestampUs (in header)
- encryptMethod: encryptMethodEnum (uint8) - must be 0 (None/Other)
- heartBtInt: uint32 (5-60 seconds)
- resetSeqNumFlag: booleanEnum (uint8) - must be Y (89)
- username: varString8 (API key)
- rawDataLength: uint16
- rawData: varString16 (signature)
- messageHandling: messageHandlingEnum (uint8) - 1=UNORDERED, 2=SEQUENTIAL
- recvWindow: uint64 (optional, in microseconds)
- responseMode: responseModeEnum (uint8, optional) - 1=EVERYTHING, 2=ONLY_ACKS
- dropCopyFlag: booleanNullEnum (uint8, optional) - for Drop Copy sessions
- uuid: varString8 (optional)
"""
function encode_logon(;
    sender_comp_id::String,
    target_comp_id::String,
    seq_num::UInt32,
    heartbeat_interval::UInt32,
    api_key::String,
    signature::String,
    message_handling::UInt8=0x01,  # UNORDERED
    recv_window::Union{UInt64,Nothing}=nothing,
    response_mode::Union{UInt8,Nothing}=nothing,
    drop_copy_flag::Union{UInt8,Nothing}=nothing,
    uuid::String=""
)
    buf = SBEBuffer()

    # Fixed fields (blockLength covers these)
    write_uint8!(buf, 0x00)  # encryptMethod: None/Other
    write_uint32!(buf, heartbeat_interval)  # heartBtInt
    write_uint8!(buf, 0x59)  # resetSeqNumFlag: Y (89 = 'Y')
    write_uint8!(buf, message_handling)  # messageHandling

    # recvWindow (optional - use null value if not specified)
    if isnothing(recv_window)
        write_uint64!(buf, SBE_UINT64_NULL)
    else
        write_uint64!(buf, recv_window)
    end

    # responseMode (optional)
    if isnothing(response_mode)
        write_uint8!(buf, SBE_UINT8_NULL)
    else
        write_uint8!(buf, response_mode)
    end

    # dropCopyFlag (optional)
    if isnothing(drop_copy_flag)
        write_uint8!(buf, SBE_UINT8_NULL)
    else
        write_uint8!(buf, drop_copy_flag)
    end

    # Variable-length fields (must be in schema order)
    write_var_string8!(buf, sender_comp_id)  # senderCompId
    write_var_string8!(buf, target_comp_id)  # targetCompId
    write_var_string8!(buf, api_key)         # username
    write_var_string16!(buf, signature)       # rawData (signature)
    write_var_string8!(buf, uuid)            # uuid

    return finalize_message!(buf, SBE_TEMPLATE_LOGON, seq_num)
end

"""
Encode Logout message (templateId=20004)

Fields:
- text: varString16 (optional reason)
"""
function encode_logout(; seq_num::UInt32, text::String="")
    buf = SBEBuffer()

    # Variable-length field
    write_var_string16!(buf, text)

    return finalize_message!(buf, SBE_TEMPLATE_LOGOUT, seq_num)
end

"""
Encode Heartbeat message (templateId=20001)

Fields:
- testReqId: varString8 (echo back if responding to TestRequest)
"""
function encode_heartbeat(; seq_num::UInt32, test_req_id::String="")
    buf = SBEBuffer()

    # Variable-length field
    write_var_string8!(buf, test_req_id)

    return finalize_message!(buf, SBE_TEMPLATE_HEARTBEAT, seq_num)
end

"""
Encode TestRequest message (templateId=20002)

Fields:
- testReqId: varString8
"""
function encode_test_request(; seq_num::UInt32, test_req_id::String)
    buf = SBEBuffer()

    # Variable-length field
    write_var_string8!(buf, test_req_id)

    return finalize_message!(buf, SBE_TEMPLATE_TEST_REQUEST, seq_num)
end

# =============================================================================
# Order Entry Message Encoders
# =============================================================================

"""
Encode NewOrderSingle message (templateId=99)

This is a complex message with many fields. Key fields:
- symbol: varString8
- side: sideEnum (1=BUY, 2=SELL)
- ordType: ordTypeEnum
- timeInForce: timeInForceEnum
- orderQty: mantissa64 (exponent -8)
- price: mantissa64 (exponent -8)
- clOrdId: varString8
- And many optional fields...
"""
function encode_new_order_single(;
    seq_num::UInt32,
    symbol::String,
    side::UInt8,
    ord_type::UInt8,
    quantity::Float64,
    cl_ord_id::String,
    price::Union{Float64,Nothing}=nothing,
    time_in_force::UInt8=0x01,  # GTC
    cash_order_qty::Union{Float64,Nothing}=nothing,
    max_floor::Union{Float64,Nothing}=nothing,
    trigger_price::Union{Float64,Nothing}=nothing,
    trigger_price_direction::Union{UInt8,Nothing}=nothing,
    trigger_trailing_delta_bips::Union{UInt32,Nothing}=nothing,
    peg_offset_value::Union{Int64,Nothing}=nothing,
    peg_price_type::Union{UInt8,Nothing}=nothing,
    exec_inst::Union{UInt8,Nothing}=nothing,
    self_trade_prevention::Union{UInt8,Nothing}=nothing,
    strategy_id::Union{UInt64,Nothing}=nothing,
    target_strategy::Union{UInt32,Nothing}=nothing,
    sor::Bool=false,
    recv_window::Union{UInt64,Nothing}=nothing
)
    buf = SBEBuffer()

    # Exponent for price/qty fields (from schema: exponent=-8)
    QTY_EXPONENT = Int8(-8)

    # Fixed fields in schema order
    write_uint8!(buf, side)  # side
    write_uint8!(buf, ord_type)  # ordType
    write_uint8!(buf, time_in_force)  # timeInForce

    # execInst (optional)
    if isnothing(exec_inst)
        write_uint8!(buf, SBE_UINT8_NULL)
    else
        write_uint8!(buf, exec_inst)
    end

    # orderQty (mantissa64)
    write_mantissa!(buf, quantity, QTY_EXPONENT)

    # price (mantissa64, optional)
    if isnothing(price)
        write_int64!(buf, SBE_INT64_NULL)
    else
        write_mantissa!(buf, price, QTY_EXPONENT)
    end

    # cashOrderQty (optional)
    if isnothing(cash_order_qty)
        write_int64!(buf, SBE_INT64_NULL)
    else
        write_mantissa!(buf, cash_order_qty, QTY_EXPONENT)
    end

    # maxFloor (optional)
    if isnothing(max_floor)
        write_int64!(buf, SBE_INT64_NULL)
    else
        write_mantissa!(buf, max_floor, QTY_EXPONENT)
    end

    # triggerPrice (optional)
    if isnothing(trigger_price)
        write_int64!(buf, SBE_INT64_NULL)
    else
        write_mantissa!(buf, trigger_price, QTY_EXPONENT)
    end

    # triggerType (set if trigger_price is set)
    if !isnothing(trigger_price)
        write_uint8!(buf, 0x04)  # PRICE_MOVEMENT
    else
        write_uint8!(buf, SBE_UINT8_NULL)
    end

    # triggerAction
    if !isnothing(trigger_price)
        write_uint8!(buf, 0x01)  # ACTIVATE
    else
        write_uint8!(buf, SBE_UINT8_NULL)
    end

    # triggerPriceType
    if !isnothing(trigger_price)
        write_uint8!(buf, 0x02)  # LAST_TRADE
    else
        write_uint8!(buf, SBE_UINT8_NULL)
    end

    # triggerPriceDirection (optional)
    if isnothing(trigger_price_direction)
        write_uint8!(buf, SBE_UINT8_NULL)
    else
        write_uint8!(buf, trigger_price_direction)
    end

    # triggerTrailingDeltaBips (optional)
    if isnothing(trigger_trailing_delta_bips)
        write_uint32!(buf, SBE_UINT32_NULL)
    else
        write_uint32!(buf, trigger_trailing_delta_bips)
    end

    # pegOffsetValue (optional)
    if isnothing(peg_offset_value)
        write_int64!(buf, SBE_INT64_NULL)
    else
        write_int64!(buf, peg_offset_value)
    end

    # pegMoveType (set if pegOffsetValue is set)
    if !isnothing(peg_offset_value)
        write_uint8!(buf, 0x01)  # FIXED
    else
        write_uint8!(buf, SBE_UINT8_NULL)
    end

    # pegOffsetType (optional)
    write_uint8!(buf, SBE_UINT8_NULL)  # Not commonly used

    # pegPriceType (optional)
    if isnothing(peg_price_type)
        write_uint8!(buf, SBE_UINT8_NULL)
    else
        write_uint8!(buf, peg_price_type)
    end

    # selfTradePreventionMode (optional)
    if isnothing(self_trade_prevention)
        write_uint8!(buf, SBE_UINT8_NULL)
    else
        write_uint8!(buf, self_trade_prevention)
    end

    # strategyId (optional)
    if isnothing(strategy_id)
        write_uint64!(buf, SBE_UINT64_NULL)
    else
        write_uint64!(buf, strategy_id)
    end

    # targetStrategy (optional)
    if isnothing(target_strategy)
        write_uint32!(buf, SBE_UINT32_NULL)
    else
        write_uint32!(buf, target_strategy)
    end

    # SOR flag
    if sor
        write_uint8!(buf, 0x59)  # Y
    else
        write_uint8!(buf, SBE_UINT8_NULL)
    end

    # recvWindow (optional)
    if isnothing(recv_window)
        write_uint64!(buf, SBE_UINT64_NULL)
    else
        write_uint64!(buf, recv_window)
    end

    # Variable-length fields
    write_var_string8!(buf, cl_ord_id)  # clOrdId
    write_var_string8!(buf, symbol)     # symbol

    return finalize_message!(buf, SBE_TEMPLATE_NEW_ORDER_SINGLE, seq_num)
end

"""
Encode OrderCancelRequest message (templateId=101)
"""
function encode_order_cancel_request(;
    seq_num::UInt32,
    symbol::String,
    cl_ord_id::String,
    orig_cl_ord_id::String="",
    order_id::Union{UInt64,Nothing}=nothing,
    orig_cl_list_id::String="",
    list_id::Union{UInt64,Nothing}=nothing,
    cancel_restrictions::Union{UInt8,Nothing}=nothing,
    recv_window::Union{UInt64,Nothing}=nothing
)
    buf = SBEBuffer()

    # Fixed fields
    # orderId (optional)
    if isnothing(order_id)
        write_uint64!(buf, SBE_UINT64_NULL)
    else
        write_uint64!(buf, order_id)
    end

    # listId (optional)
    if isnothing(list_id)
        write_uint64!(buf, SBE_UINT64_NULL)
    else
        write_uint64!(buf, list_id)
    end

    # cancelRestrictions (optional)
    if isnothing(cancel_restrictions)
        write_uint8!(buf, SBE_UINT8_NULL)
    else
        write_uint8!(buf, cancel_restrictions)
    end

    # recvWindow (optional)
    if isnothing(recv_window)
        write_uint64!(buf, SBE_UINT64_NULL)
    else
        write_uint64!(buf, recv_window)
    end

    # Variable-length fields
    write_var_string8!(buf, cl_ord_id)       # clOrdId
    write_var_string8!(buf, orig_cl_ord_id)  # origClOrdId
    write_var_string8!(buf, symbol)          # symbol
    write_var_string8!(buf, orig_cl_list_id) # origClListId

    return finalize_message!(buf, SBE_TEMPLATE_ORDER_CANCEL_REQUEST, seq_num)
end

"""
Encode OrderMassCancelRequest message (templateId=103)
"""
function encode_order_mass_cancel_request(;
    seq_num::UInt32,
    symbol::String,
    cl_ord_id::String,
    recv_window::Union{UInt64,Nothing}=nothing
)
    buf = SBEBuffer()

    # Fixed fields
    write_uint8!(buf, 0x01)  # massCancelRequestType: CANCEL_SYMBOL_ORDERS

    # recvWindow (optional)
    if isnothing(recv_window)
        write_uint64!(buf, SBE_UINT64_NULL)
    else
        write_uint64!(buf, recv_window)
    end

    # Variable-length fields
    write_var_string8!(buf, cl_ord_id)  # clOrdId
    write_var_string8!(buf, symbol)     # symbol

    return finalize_message!(buf, SBE_TEMPLATE_ORDER_MASS_CANCEL_REQUEST, seq_num)
end

"""
Encode OrderAmendKeepPriorityRequest message (templateId=105)
"""
function encode_order_amend_keep_priority(;
    seq_num::UInt32,
    symbol::String,
    cl_ord_id::String,
    order_qty::Float64,
    orig_cl_ord_id::String="",
    order_id::Union{UInt64,Nothing}=nothing,
    recv_window::Union{UInt64,Nothing}=nothing
)
    buf = SBEBuffer()

    QTY_EXPONENT = Int8(-8)

    # Fixed fields
    # orderId (optional)
    if isnothing(order_id)
        write_uint64!(buf, SBE_UINT64_NULL)
    else
        write_uint64!(buf, order_id)
    end

    # orderQty
    write_mantissa!(buf, order_qty, QTY_EXPONENT)

    # recvWindow (optional)
    if isnothing(recv_window)
        write_uint64!(buf, SBE_UINT64_NULL)
    else
        write_uint64!(buf, recv_window)
    end

    # Variable-length fields
    write_var_string8!(buf, cl_ord_id)       # clOrdId
    write_var_string8!(buf, orig_cl_ord_id)  # origClOrdId
    write_var_string8!(buf, symbol)          # symbol

    return finalize_message!(buf, SBE_TEMPLATE_ORDER_AMEND_KEEP_PRIORITY, seq_num)
end

"""
Encode LimitQuery message (templateId=120)
"""
function encode_limit_query(; seq_num::UInt32, req_id::String)
    buf = SBEBuffer()

    # Variable-length field
    write_var_string8!(buf, req_id)

    return finalize_message!(buf, SBE_TEMPLATE_LIMIT_QUERY, seq_num)
end

# =============================================================================
# Market Data Message Encoders
# =============================================================================

"""
Encode MarketDataRequest message (templateId=202)

Used to subscribe/unsubscribe to market data streams.
"""
function encode_market_data_request(;
    seq_num::UInt32,
    md_req_id::String,
    subscription_request_type::UInt8,  # 1=Subscribe, 2=Unsubscribe
    symbols::Vector{String}=String[],
    market_depth::UInt32=0,
    md_entry_types::Vector{UInt8}=UInt8[]  # 0=Bid, 1=Offer, 2=Trade
)
    buf = SBEBuffer()

    # Fixed fields
    write_uint8!(buf, subscription_request_type)
    write_uint32!(buf, market_depth)

    # NoRelatedSym group header
    write_uint16!(buf, UInt16(8))  # blockLength per entry (symbol is var, but groupHeader size)
    write_uint8!(buf, UInt8(length(symbols)))  # numInGroup

    # NoRelatedSym entries (each has varString for symbol)
    # Note: In SBE groups, varString comes after all fixed fields in the group

    # NoMDEntryTypes group header
    write_uint16!(buf, UInt16(1))  # blockLength per entry (just mdEntryType)
    write_uint8!(buf, UInt8(length(md_entry_types)))  # numInGroup

    # NoMDEntryTypes entries
    for et in md_entry_types
        write_uint8!(buf, et)
    end

    # Variable-length fields
    write_var_string8!(buf, md_req_id)

    # Symbols (var strings for each entry)
    for sym in symbols
        write_var_string8!(buf, sym)
    end

    return finalize_message!(buf, SBE_TEMPLATE_MARKET_DATA_REQUEST, seq_num)
end

"""
Encode InstrumentListRequest message (templateId=200)
"""
function encode_instrument_list_request(;
    seq_num::UInt32,
    instrument_req_id::String,
    request_type::UInt8=0x04,  # 4=All instruments
    symbol::String=""
)
    buf = SBEBuffer()

    # Fixed fields
    write_uint8!(buf, request_type)

    # Variable-length fields
    write_var_string8!(buf, instrument_req_id)
    write_var_string8!(buf, symbol)

    return finalize_message!(buf, SBE_TEMPLATE_INSTRUMENT_LIST_REQUEST, seq_num)
end

end # module FIXSBEEncoder
