"""
FIX SBE Encoder Module

Encodes FIX SBE (Simple Binary Encoding) messages for Binance FIX API.

Schema Information:
- Schema File: spot-fixsbe-1_1.xml
- Schema ID: 1
- Schema Version: 1 (current; v0 deprecated 2026-03-09)
- Byte order: Little Endian

Wire Format:
<SOFH (6 bytes)> <message header (20 bytes)> <message body (N bytes)>

The message header's blockLength field is the size of the root block of
fixed fields ONLY — it does NOT include repeating groups or variable-length
data fields. Each encoder must call `mark_block_end!(buf)` after writing
its fixed fields and before writing any group or var data.

Ports:
- 9001: FIX text request → SBE response
- 9002: SBE request → SBE response
"""
module FIXSBEEncoder

using Dates
using ..FIXConstants

export encode_sofh, encode_message_header
export encode_logon, encode_logout, encode_heartbeat, encode_test_request
export encode_new_order_single, encode_new_order_list, encode_order_cancel_request
export encode_order_cancel_request_and_new
export encode_order_mass_cancel_request, encode_order_amend_keep_priority, encode_limit_query
export encode_market_data_request, encode_instrument_list_request
export SBEBuffer, write_uint8!, write_uint16!, write_uint32!, write_uint64!
export write_int8!, write_int32!, write_int64!, write_fixed_string!
export write_var_string8!, write_var_string16!
export write_mantissa!, finalize_message!, mark_block_end!

# =============================================================================
# SBE Buffer for Building Messages
# =============================================================================

"""
SBE Buffer for building messages incrementally.
Handles SOFH + message header + body encoding.

`block_length` is set by `mark_block_end!` to record the size of the root
block (fixed fields only). If left at 0, `finalize_message!` falls back to
"all bytes after the header" which is incorrect for messages with groups
or var data — encoders must call `mark_block_end!` after fixed fields.
"""
mutable struct SBEBuffer
    data::Vector{UInt8}
    position::Int
    body_start::Int       # Position where body starts (after headers)
    block_length::UInt16  # Size of root block (set by mark_block_end!)

    function SBEBuffer(initial_size::Int=1024)
        buf = new(zeros(UInt8, initial_size), 1, 0, UInt16(0))
        # Reserve space for SOFH (6 bytes) + message header (20 bytes)
        buf.position = SBE_SOFH_SIZE + SBE_MESSAGE_HEADER_SIZE + 1
        buf.body_start = buf.position
        return buf
    end
end

"""Ensure buffer has enough capacity"""
function ensure_capacity!(buf::SBEBuffer, needed::Integer)
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

function write_int32!(buf::SBEBuffer, value::Int32)
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
    # blockLength = size of root block (fixed fields only). Encoders should
    # call mark_block_end! after fixed fields. If they didn't, fall back to
    # "everything after header" which matches the legacy encoder behavior
    # (acceptable for messages with no groups/data).
    block_length = buf.block_length != 0 ? buf.block_length : UInt16(buf.position - buf.body_start)

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

"""
Mark the end of the fixed-field block. Encoders MUST call this after the
last fixed field and before any group/data field, so blockLength in the
message header is the size of the root block per SBE spec.
"""
function mark_block_end!(buf::SBEBuffer)
    buf.block_length = UInt16(buf.position - buf.body_start)
    return buf
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
Encode Logon message (templateId=20008, schema 1.1)

Schema 1.1 fixed-field order (root block):
- EncryptMethod (uint8, optional)
- HeartBtInt (uint32, required)
- ResetSeqNumFlag (boolEnum/uint8, optional) - must be Y for Binance
- MessageHandling (uint8, optional)
- ResponseMode (uint8, optional)
- ExecutionReportType (uint8, optional)
- DropCopyFlag (boolEnum/uint8, optional)
- RecvWindow (durationUs/uint32, optional, microseconds)

Data fields (after the root block, in order):
- SenderCompId (varString8)
- TargetCompId (varString8)
- RawData (varString — uint16 length prefix)
- Username (varString — uint16 length prefix)

Note: schema 1.1 Logon has no UUID field. UUID appears on LogonAck only.
"""
function encode_logon(;
    sender_comp_id::String,
    target_comp_id::String,
    seq_num::UInt32,
    heartbeat_interval::UInt32,
    api_key::String,
    signature::String,
    message_handling::UInt8=0x01,  # UNORDERED
    response_mode::Union{UInt8,Nothing}=nothing,
    execution_report_type::Union{UInt8,Nothing}=nothing,
    drop_copy_flag::Union{UInt8,Nothing}=nothing,
    recv_window::Union{Real,Nothing}=nothing
)
    buf = SBEBuffer()

    # Fixed fields in schema order
    write_uint8!(buf, 0x00)                          # encryptMethod: NONE (optional, but always set)
    write_uint32!(buf, heartbeat_interval)           # heartBtInt
    write_uint8!(buf, 0x01)                          # resetSeqNumFlag: True (boolEnum True=1)
    write_uint8!(buf, message_handling)              # messageHandling

    # responseMode (optional)
    if isnothing(response_mode)
        write_uint8!(buf, SBE_UINT8_NULL)
    else
        write_uint8!(buf, response_mode)
    end

    # executionReportType (optional)
    if isnothing(execution_report_type)
        write_uint8!(buf, SBE_UINT8_NULL)
    else
        write_uint8!(buf, execution_report_type)
    end

    # dropCopyFlag (optional)
    if isnothing(drop_copy_flag)
        write_uint8!(buf, SBE_UINT8_NULL)
    else
        write_uint8!(buf, drop_copy_flag)
    end

    # recvWindow (uint32 durationUs, optional)
    if isnothing(recv_window)
        write_uint32!(buf, SBE_UINT32_NULL)
    else
        write_uint32!(buf, UInt32(recv_window))
    end

    mark_block_end!(buf)

    # Variable-length data fields (schema order: senderCompId, targetCompId, rawData, username)
    write_var_string8!(buf, sender_comp_id)
    write_var_string8!(buf, target_comp_id)
    write_var_string16!(buf, signature)   # rawData
    write_var_string16!(buf, api_key)     # username

    return finalize_message!(buf, SBE_TEMPLATE_LOGON, seq_num)
end

"""
Encode Logout message (templateId=20004)

No fixed fields. Optional Text data field carries an optional reason.
"""
function encode_logout(; seq_num::UInt32, text::String="")
    buf = SBEBuffer()

    mark_block_end!(buf)
    write_var_string16!(buf, text)

    return finalize_message!(buf, SBE_TEMPLATE_LOGOUT, seq_num)
end

"""
Encode Heartbeat message (templateId=20001)

No fixed fields. Optional TestReqID echoes the request when responding to
a TestRequest.
"""
function encode_heartbeat(; seq_num::UInt32, test_req_id::String="")
    buf = SBEBuffer()

    mark_block_end!(buf)
    write_var_string8!(buf, test_req_id)

    return finalize_message!(buf, SBE_TEMPLATE_HEARTBEAT, seq_num)
end

"""
Encode TestRequest message (templateId=20002)

No fixed fields. TestReqID is required.
"""
function encode_test_request(; seq_num::UInt32, test_req_id::String)
    buf = SBEBuffer()

    mark_block_end!(buf)
    write_var_string8!(buf, test_req_id)

    return finalize_message!(buf, SBE_TEMPLATE_TEST_REQUEST, seq_num)
end

# =============================================================================
# Order Entry Message Encoders
# =============================================================================

"""
Encode NewOrderSingle message (templateId=99, schema 1.1)

Schema 1.1 fixed-field order (root block):
- PriceExponent (int8)
- QtyExponent (int8)
- OrderQty (mantissa64, optional)
- OrdType (uint8, required)
- ExecInst (uint8, optional)
- Price (mantissa64, optional)
- TriggerType, TriggerAction, TriggerPrice, TriggerPriceType,
  TriggerPriceDirection (1+1+8+1+1 bytes, all optional)
- TriggerTrailingDeltaBips (uint64, optional)
- PegOffsetValue (uint8, optional) — uint8 in SBE, not int64!
- PegPriceType, PegMoveType, PegOffsetType (uint8 each, optional)
- Side (uint8, required)
- TimeInForce (uint8, optional)
- MaxFloor (mantissa64, optional)
- CashOrderQty (mantissa64, optional)
- TargetStrategy (int32, optional)
- StrategyID (int64, optional)
- SelfTradePreventionMode (uint8, optional)
- SOR (boolEnum/uint8, optional)

Data fields:
- ClOrdID (varString8)
- Symbol (varString8)

Schema 1.1 has no RecvWindow on NewOrderSingle (only on Logon).
"""
function encode_new_order_single(;
    seq_num::UInt32,
    symbol::String,
    side::UInt8,
    ord_type::UInt8,
    cl_ord_id::String,
    quantity::Union{Float64,Nothing}=nothing,
    price::Union{Float64,Nothing}=nothing,
    time_in_force::Union{UInt8,Nothing}=nothing,
    cash_order_qty::Union{Float64,Nothing}=nothing,
    max_floor::Union{Float64,Nothing}=nothing,
    trigger_type::Union{UInt8,Nothing}=nothing,
    trigger_action::Union{UInt8,Nothing}=nothing,
    trigger_price::Union{Float64,Nothing}=nothing,
    trigger_price_type::Union{UInt8,Nothing}=nothing,
    trigger_price_direction::Union{UInt8,Nothing}=nothing,
    trigger_trailing_delta_bips::Union{UInt64,Nothing}=nothing,
    peg_offset_value::Union{Integer,Nothing}=nothing,
    peg_price_type::Union{UInt8,Nothing}=nothing,
    peg_move_type::Union{UInt8,Nothing}=nothing,
    peg_offset_type::Union{UInt8,Nothing}=nothing,
    exec_inst::Union{UInt8,Nothing}=nothing,
    self_trade_prevention::Union{UInt8,Nothing}=nothing,
    strategy_id::Union{Int64,Nothing}=nothing,
    target_strategy::Union{Int32,Nothing}=nothing,
    sor::Bool=false,
    price_exponent::Int8=Int8(-8),
    qty_exponent::Int8=Int8(-8)
)
    buf = SBEBuffer()

    # Fixed fields in schema 1.1 order
    write_int8!(buf, price_exponent)                              # PriceExponent
    write_int8!(buf, qty_exponent)                                # QtyExponent

    # OrderQty (optional)
    if isnothing(quantity)
        write_int64!(buf, SBE_INT64_NULL)
    else
        write_mantissa!(buf, quantity, qty_exponent)
    end

    write_uint8!(buf, ord_type)                                   # OrdType (required)

    # ExecInst (optional)
    write_uint8!(buf, isnothing(exec_inst) ? SBE_UINT8_NULL : exec_inst)

    # Price (optional)
    if isnothing(price)
        write_int64!(buf, SBE_INT64_NULL)
    else
        write_mantissa!(buf, price, price_exponent)
    end

    # Trigger block
    write_uint8!(buf, isnothing(trigger_type) ? SBE_UINT8_NULL : trigger_type)
    write_uint8!(buf, isnothing(trigger_action) ? SBE_UINT8_NULL : trigger_action)
    if isnothing(trigger_price)
        write_int64!(buf, SBE_INT64_NULL)
    else
        write_mantissa!(buf, trigger_price, price_exponent)
    end
    write_uint8!(buf, isnothing(trigger_price_type) ? SBE_UINT8_NULL : trigger_price_type)
    write_uint8!(buf, isnothing(trigger_price_direction) ? SBE_UINT8_NULL : trigger_price_direction)
    write_uint64!(buf, isnothing(trigger_trailing_delta_bips) ? SBE_UINT64_NULL : trigger_trailing_delta_bips)

    # Peg block (PegOffsetValue is uint8 in SBE, not int64)
    write_uint8!(buf, isnothing(peg_offset_value) ? SBE_UINT8_NULL : UInt8(peg_offset_value))
    write_uint8!(buf, isnothing(peg_price_type) ? SBE_UINT8_NULL : peg_price_type)
    write_uint8!(buf, isnothing(peg_move_type) ? SBE_UINT8_NULL : peg_move_type)
    write_uint8!(buf, isnothing(peg_offset_type) ? SBE_UINT8_NULL : peg_offset_type)

    write_uint8!(buf, side)                                       # Side (required)
    write_uint8!(buf, isnothing(time_in_force) ? SBE_UINT8_NULL : time_in_force)

    # MaxFloor (optional)
    if isnothing(max_floor)
        write_int64!(buf, SBE_INT64_NULL)
    else
        write_mantissa!(buf, max_floor, qty_exponent)
    end

    # CashOrderQty (optional, scaled with PriceExponent per schema)
    if isnothing(cash_order_qty)
        write_int64!(buf, SBE_INT64_NULL)
    else
        write_mantissa!(buf, cash_order_qty, price_exponent)
    end

    # TargetStrategy (int32, optional)
    write_int32!(buf, isnothing(target_strategy) ? typemax(Int32) : target_strategy)

    # StrategyID (int64, optional)
    write_int64!(buf, isnothing(strategy_id) ? SBE_INT64_NULL : strategy_id)

    # SelfTradePreventionMode (optional)
    write_uint8!(buf, isnothing(self_trade_prevention) ? SBE_UINT8_NULL : self_trade_prevention)

    # SOR (boolEnum: 0=False, 1=True)
    write_uint8!(buf, sor ? UInt8(1) : SBE_UINT8_NULL)

    mark_block_end!(buf)

    # Variable-length fields
    write_var_string8!(buf, cl_ord_id)
    write_var_string8!(buf, symbol)

    return finalize_message!(buf, SBE_TEMPLATE_NEW_ORDER_SINGLE, seq_num)
end

"""
Encode OrderCancelRequest message (templateId=101, schema 1.1)

Fixed fields: OrderID (int64, optional), ListID (int64, optional),
CancelRestrictions (uint8, optional).

Data: ClOrdID, OrigClOrdID, OrigClListID, Symbol (in that order).
"""
function encode_order_cancel_request(;
    seq_num::UInt32,
    symbol::String,
    cl_ord_id::String,
    orig_cl_ord_id::String="",
    order_id::Union{Int64,Nothing}=nothing,
    orig_cl_list_id::String="",
    list_id::Union{Int64,Nothing}=nothing,
    cancel_restrictions::Union{UInt8,Nothing}=nothing
)
    buf = SBEBuffer()

    # Fixed fields
    write_int64!(buf, isnothing(order_id) ? SBE_INT64_NULL : order_id)
    write_int64!(buf, isnothing(list_id) ? SBE_INT64_NULL : list_id)
    write_uint8!(buf, isnothing(cancel_restrictions) ? SBE_UINT8_NULL : cancel_restrictions)

    mark_block_end!(buf)

    # Variable-length fields (schema order)
    write_var_string8!(buf, cl_ord_id)
    write_var_string8!(buf, orig_cl_ord_id)
    write_var_string8!(buf, orig_cl_list_id)
    write_var_string8!(buf, symbol)

    return finalize_message!(buf, SBE_TEMPLATE_ORDER_CANCEL_REQUEST, seq_num)
end

"""
Encode OrderMassCancelRequest message (templateId=103, schema 1.1)

Fixed fields: MassCancelRequestType (uint8, required, must be 1=CANCEL_SYMBOL_ORDERS).
Data: Symbol, ClOrdID.
"""
function encode_order_mass_cancel_request(;
    seq_num::UInt32,
    symbol::String,
    cl_ord_id::String
)
    buf = SBEBuffer()

    write_uint8!(buf, 0x01)  # massCancelRequestType: CANCEL_SYMBOL_ORDERS

    mark_block_end!(buf)

    write_var_string8!(buf, symbol)
    write_var_string8!(buf, cl_ord_id)

    return finalize_message!(buf, SBE_TEMPLATE_ORDER_MASS_CANCEL_REQUEST, seq_num)
end

"""
Encode OrderAmendKeepPriorityRequest message (templateId=105, schema 1.1)

Fixed fields: OrderID (int64, optional), QtyExponent (int8), OrderQty (mantissa64, required).
Data: ClOrdID, OrigClOrdID, Symbol.

Schema 1.1 has no RecvWindow on this message.
"""
function encode_order_amend_keep_priority(;
    seq_num::UInt32,
    symbol::String,
    cl_ord_id::String,
    order_qty::Float64,
    orig_cl_ord_id::String="",
    order_id::Union{Int64,Nothing}=nothing,
    qty_exponent::Int8=Int8(-8)
)
    buf = SBEBuffer()

    write_int64!(buf, isnothing(order_id) ? SBE_INT64_NULL : order_id)
    write_int8!(buf, qty_exponent)
    write_mantissa!(buf, order_qty, qty_exponent)

    mark_block_end!(buf)

    write_var_string8!(buf, cl_ord_id)
    write_var_string8!(buf, orig_cl_ord_id)
    write_var_string8!(buf, symbol)

    return finalize_message!(buf, SBE_TEMPLATE_ORDER_AMEND_KEEP_PRIORITY, seq_num)
end

"""
Encode LimitQuery message (templateId=120, schema 1.1)

No fixed fields. Data: ReqID (varString8).
"""
function encode_limit_query(; seq_num::UInt32, req_id::String)
    buf = SBEBuffer()

    mark_block_end!(buf)
    write_var_string8!(buf, req_id)

    return finalize_message!(buf, SBE_TEMPLATE_LIMIT_QUERY, seq_num)
end

"""
Encode OrderCancelRequestAndNewOrderSingle message (templateId=97, schema 1.1)

Atomic cancel-replace: cancels an existing order then submits a new one.

Fixed-field order matches schema 1.1:
- mode (uint8, required), rateLimitExceededMode (uint8, optional)
- OrderID (int64, optional), CancelRestrictions (uint8, optional)
- PriceExponent (int8), QtyExponent (int8)
- New-order block: OrderQty(opt), OrdType, ExecInst(opt), Price(opt),
  Trigger×5+TrailingDelta, Peg×4, Side, TIF, MaxFloor, CashOrderQty,
  TargetStrategy, StrategyID, STP

Data fields (in order):
- CancelClOrdID (optionalVarString8) — ID of the cancel sub-request
- OrigClOrdID (optionalVarString8)   — ID of the order being cancelled
- ClOrdID (varString8)               — ID of the new order
- Symbol (varString8)
"""
function encode_order_cancel_request_and_new(;
    seq_num::UInt32,
    symbol::String,
    cl_ord_id::String,                                  # new order's ClOrdID
    side::UInt8,
    ord_type::UInt8,
    mode::UInt8,                                        # 1=STOP_ON_FAILURE, 2=ALLOW_FAILURE
    cancel_cl_ord_id::String="",                        # ID assigned to the cancel sub-request
    orig_cl_ord_id::String="",                          # ID of the order to cancel
    order_id::Union{Int64,Nothing}=nothing,             # ID of the order to cancel (alt)
    cancel_restrictions::Union{UInt8,Nothing}=nothing,
    rate_limit_exceeded_mode::Union{UInt8,Nothing}=nothing,
    quantity::Union{Float64,Nothing}=nothing,
    price::Union{Float64,Nothing}=nothing,
    time_in_force::Union{UInt8,Nothing}=nothing,
    cash_order_qty::Union{Float64,Nothing}=nothing,
    max_floor::Union{Float64,Nothing}=nothing,
    trigger_type::Union{UInt8,Nothing}=nothing,
    trigger_action::Union{UInt8,Nothing}=nothing,
    trigger_price::Union{Float64,Nothing}=nothing,
    trigger_price_type::Union{UInt8,Nothing}=nothing,
    trigger_price_direction::Union{UInt8,Nothing}=nothing,
    trigger_trailing_delta_bips::Union{UInt64,Nothing}=nothing,
    peg_offset_value::Union{Integer,Nothing}=nothing,
    peg_price_type::Union{UInt8,Nothing}=nothing,
    peg_move_type::Union{UInt8,Nothing}=nothing,
    peg_offset_type::Union{UInt8,Nothing}=nothing,
    exec_inst::Union{UInt8,Nothing}=nothing,
    self_trade_prevention::Union{UInt8,Nothing}=nothing,
    strategy_id::Union{Int64,Nothing}=nothing,
    target_strategy::Union{Int32,Nothing}=nothing,
    price_exponent::Int8=Int8(-8),
    qty_exponent::Int8=Int8(-8)
)
    buf = SBEBuffer()

    # Cancel-control fields
    write_uint8!(buf, mode)
    write_uint8!(buf, isnothing(rate_limit_exceeded_mode) ? SBE_UINT8_NULL : rate_limit_exceeded_mode)
    write_int64!(buf, isnothing(order_id) ? SBE_INT64_NULL : order_id)
    write_uint8!(buf, isnothing(cancel_restrictions) ? SBE_UINT8_NULL : cancel_restrictions)

    # Exponents for the new order
    write_int8!(buf, price_exponent)
    write_int8!(buf, qty_exponent)

    # New-order fields
    if isnothing(quantity)
        write_int64!(buf, SBE_INT64_NULL)
    else
        write_mantissa!(buf, quantity, qty_exponent)
    end
    write_uint8!(buf, ord_type)
    write_uint8!(buf, isnothing(exec_inst) ? SBE_UINT8_NULL : exec_inst)
    if isnothing(price)
        write_int64!(buf, SBE_INT64_NULL)
    else
        write_mantissa!(buf, price, price_exponent)
    end

    # Trigger block
    write_uint8!(buf, isnothing(trigger_type) ? SBE_UINT8_NULL : trigger_type)
    write_uint8!(buf, isnothing(trigger_action) ? SBE_UINT8_NULL : trigger_action)
    if isnothing(trigger_price)
        write_int64!(buf, SBE_INT64_NULL)
    else
        write_mantissa!(buf, trigger_price, price_exponent)
    end
    write_uint8!(buf, isnothing(trigger_price_type) ? SBE_UINT8_NULL : trigger_price_type)
    write_uint8!(buf, isnothing(trigger_price_direction) ? SBE_UINT8_NULL : trigger_price_direction)
    write_uint64!(buf, isnothing(trigger_trailing_delta_bips) ? SBE_UINT64_NULL : trigger_trailing_delta_bips)

    # Peg block (PegOffsetValue is uint8 in SBE)
    write_uint8!(buf, isnothing(peg_offset_value) ? SBE_UINT8_NULL : UInt8(peg_offset_value))
    write_uint8!(buf, isnothing(peg_price_type) ? SBE_UINT8_NULL : peg_price_type)
    write_uint8!(buf, isnothing(peg_move_type) ? SBE_UINT8_NULL : peg_move_type)
    write_uint8!(buf, isnothing(peg_offset_type) ? SBE_UINT8_NULL : peg_offset_type)

    write_uint8!(buf, side)
    write_uint8!(buf, isnothing(time_in_force) ? SBE_UINT8_NULL : time_in_force)
    if isnothing(max_floor)
        write_int64!(buf, SBE_INT64_NULL)
    else
        write_mantissa!(buf, max_floor, qty_exponent)
    end
    if isnothing(cash_order_qty)
        write_int64!(buf, SBE_INT64_NULL)
    else
        write_mantissa!(buf, cash_order_qty, price_exponent)
    end
    write_int32!(buf, isnothing(target_strategy) ? typemax(Int32) : target_strategy)
    write_int64!(buf, isnothing(strategy_id) ? SBE_INT64_NULL : strategy_id)
    write_uint8!(buf, isnothing(self_trade_prevention) ? SBE_UINT8_NULL : self_trade_prevention)

    mark_block_end!(buf)

    # Variable-length data fields in schema order
    write_var_string8!(buf, cancel_cl_ord_id)
    write_var_string8!(buf, orig_cl_ord_id)
    write_var_string8!(buf, cl_ord_id)
    write_var_string8!(buf, symbol)

    return finalize_message!(buf, SBE_TEMPLATE_ORDER_CANCEL_REQUEST_AND_NEW, seq_num)
end

# =============================================================================
# Order list helpers
# =============================================================================

"""
A single order entry in a NewOrderList. Mirrors the per-order fields plus
optional ListTriggeringInstructions. Construct with `OrderListEntry(side=...,
ord_type=..., ...)`. All non-required fields default to `nothing`.
"""
Base.@kwdef struct OrderListEntry
    cl_ord_id::String
    symbol::String
    side::UInt8
    ord_type::UInt8
    quantity::Union{Float64,Nothing} = nothing
    price::Union{Float64,Nothing} = nothing
    time_in_force::Union{UInt8,Nothing} = nothing
    cash_order_qty::Union{Float64,Nothing} = nothing
    max_floor::Union{Float64,Nothing} = nothing
    exec_inst::Union{UInt8,Nothing} = nothing
    trigger_type::Union{UInt8,Nothing} = nothing
    trigger_action::Union{UInt8,Nothing} = nothing
    trigger_price::Union{Float64,Nothing} = nothing
    trigger_price_type::Union{UInt8,Nothing} = nothing
    trigger_price_direction::Union{UInt8,Nothing} = nothing
    trigger_trailing_delta_bips::Union{UInt64,Nothing} = nothing
    peg_offset_value::Union{Integer,Nothing} = nothing
    peg_price_type::Union{UInt8,Nothing} = nothing
    peg_move_type::Union{UInt8,Nothing} = nothing
    peg_offset_type::Union{UInt8,Nothing} = nothing
    self_trade_prevention::Union{UInt8,Nothing} = nothing
    target_strategy::Union{Int32,Nothing} = nothing
    strategy_id::Union{Int64,Nothing} = nothing
    price_exponent::Int8 = Int8(-8)
    qty_exponent::Int8 = Int8(-8)
    list_triggering_instructions::Vector{NTuple{3,UInt8}} = NTuple{3,UInt8}[]
end

export OrderListEntry

"""
Encode NewOrderList message (templateId=100, schema 1.1)

Used to submit OCO/OTO/OTOCO/OPO order lists.

Layout:
- ContingencyType (uint8, required, 1=OCO, 2=OTO/OTOCO)
- OPO (boolEnum/uint8, optional) — set true for OPO/OPOCO lists
- groupHeader Orders (groupSize8Encoding: blockLength uint16 + numInGroup uint8)
- For each Order:
    - 75 bytes of fixed fields (PriceExp, QtyExp, OrderQty, OrdType, ExecInst,
      Price, Trigger×5+TrailingDelta, Peg×4, Side, TIF, MaxFloor, CashOrderQty,
      TargetStrategy, StrategyID, STP). Breakdown:
      1+1+8+1+1+8+1+1+8+1+1+8+1+1+1+1+1+1+8+8+4+8+1 = 75
    - inner groupHeader ListTriggeringInstructions (smallGroupSize8Encoding:
      blockLength uint8 + numInGroup uint8)
    - inner entries (3 bytes each: trigger_type, trigger_index, action)
    - ClOrdID (varString8)
    - Symbol (varString8)
- ClListID (varString8)

`list_triggering_instructions` on each `OrderListEntry` is a vector of
`(list_trigger_type, trigger_index, list_trigger_action)` UInt8 triples.
"""
function encode_new_order_list(;
    seq_num::UInt32,
    cl_list_id::String,
    contingency_type::UInt8,
    orders::Vector{OrderListEntry},
    opo::Bool=false
)
    if isempty(orders) || length(orders) > 3
        error("NewOrderList must contain 2 or 3 orders, got $(length(orders))")
    end

    buf = SBEBuffer()

    # Root fixed fields
    write_uint8!(buf, contingency_type)
    write_uint8!(buf, opo ? UInt8(1) : SBE_UINT8_NULL)

    mark_block_end!(buf)

    # Orders group header (groupSize8Encoding: blockLength uint16, numInGroup uint8)
    # Fixed-field block per Order entry = 75 bytes (see schema breakdown in docstring).
    const_orders_block_len = UInt16(75)
    write_uint16!(buf, const_orders_block_len)
    write_uint8!(buf, UInt8(length(orders)))

    for o in orders
        # Per-order fixed fields (must total 73 bytes to match block length)
        write_int8!(buf, o.price_exponent)                                          # 1
        write_int8!(buf, o.qty_exponent)                                            # 1
        if isnothing(o.quantity)                                                    # 8
            write_int64!(buf, SBE_INT64_NULL)
        else
            write_mantissa!(buf, o.quantity, o.qty_exponent)
        end
        write_uint8!(buf, o.ord_type)                                               # 1
        write_uint8!(buf, isnothing(o.exec_inst) ? SBE_UINT8_NULL : o.exec_inst)    # 1
        if isnothing(o.price)                                                       # 8
            write_int64!(buf, SBE_INT64_NULL)
        else
            write_mantissa!(buf, o.price, o.price_exponent)
        end
        write_uint8!(buf, isnothing(o.trigger_type) ? SBE_UINT8_NULL : o.trigger_type)               # 1
        write_uint8!(buf, isnothing(o.trigger_action) ? SBE_UINT8_NULL : o.trigger_action)           # 1
        if isnothing(o.trigger_price)                                                                # 8
            write_int64!(buf, SBE_INT64_NULL)
        else
            write_mantissa!(buf, o.trigger_price, o.price_exponent)
        end
        write_uint8!(buf, isnothing(o.trigger_price_type) ? SBE_UINT8_NULL : o.trigger_price_type)               # 1
        write_uint8!(buf, isnothing(o.trigger_price_direction) ? SBE_UINT8_NULL : o.trigger_price_direction)     # 1
        write_uint64!(buf, isnothing(o.trigger_trailing_delta_bips) ? SBE_UINT64_NULL : o.trigger_trailing_delta_bips)  # 8
        write_uint8!(buf, isnothing(o.peg_offset_value) ? SBE_UINT8_NULL : UInt8(o.peg_offset_value))            # 1
        write_uint8!(buf, isnothing(o.peg_price_type) ? SBE_UINT8_NULL : o.peg_price_type)                       # 1
        write_uint8!(buf, isnothing(o.peg_move_type) ? SBE_UINT8_NULL : o.peg_move_type)                         # 1
        write_uint8!(buf, isnothing(o.peg_offset_type) ? SBE_UINT8_NULL : o.peg_offset_type)                     # 1
        write_uint8!(buf, o.side)                                                                                # 1
        write_uint8!(buf, isnothing(o.time_in_force) ? SBE_UINT8_NULL : o.time_in_force)                         # 1
        if isnothing(o.max_floor)                                                                                # 8
            write_int64!(buf, SBE_INT64_NULL)
        else
            write_mantissa!(buf, o.max_floor, o.qty_exponent)
        end
        if isnothing(o.cash_order_qty)                                                                           # 8
            write_int64!(buf, SBE_INT64_NULL)
        else
            write_mantissa!(buf, o.cash_order_qty, o.price_exponent)
        end
        write_int32!(buf, isnothing(o.target_strategy) ? typemax(Int32) : o.target_strategy)                     # 4
        write_int64!(buf, isnothing(o.strategy_id) ? SBE_INT64_NULL : o.strategy_id)                             # 8
        write_uint8!(buf, isnothing(o.self_trade_prevention) ? SBE_UINT8_NULL : o.self_trade_prevention)         # 1
        # Total: 1+1+8+1+1+8+1+1+8+1+1+8+1+1+1+1+1+1+8+8+4+8+1 = 75 bytes

        # Inner ListTriggeringInstructions group (smallGroupSize8Encoding: blockLength uint8, numInGroup uint8)
        write_uint8!(buf, UInt8(3))                                # blockLength per entry (3 bytes)
        write_uint8!(buf, UInt8(length(o.list_triggering_instructions)))
        for (lt_type, lt_idx, lt_action) in o.list_triggering_instructions
            write_uint8!(buf, lt_type)
            write_uint8!(buf, lt_idx)
            write_uint8!(buf, lt_action)
        end

        # Per-order data fields
        write_var_string8!(buf, o.cl_ord_id)
        write_var_string8!(buf, o.symbol)
    end

    # Root data field
    write_var_string8!(buf, cl_list_id)

    return finalize_message!(buf, SBE_TEMPLATE_NEW_ORDER_LIST, seq_num)
end

# =============================================================================
# Market Data Message Encoders
# =============================================================================

"""
Encode MarketDataRequest message (templateId=202, schema 1.1)

Used to subscribe/unsubscribe to market data streams.

Fixed fields:
- SubscriptionRequestType (uint8, required, 1=Subscribe, 2=Unsubscribe)
- MarketDepth (uint16, optional) — note: uint16, not uint32
- AggregatedBook (boolEnum/uint8, optional)

Then two repeating groups (in schema order):
- RelatedSym (groupSize16Encoding: blockLength uint16, numInGroup uint16)
  - Each entry: Symbol (varString8) — no fixed fields, so blockLength=0
- MDEntryTypes (smallGroupSize8Encoding: blockLength uint8, numInGroup uint8)
  - Each entry: MDEntryType (uint8, 1 byte)

Then root data:
- MDReqID (varString8)
"""
function encode_market_data_request(;
    seq_num::UInt32,
    md_req_id::String,
    subscription_request_type::UInt8,           # 1=Subscribe, 2=Unsubscribe
    symbols::Vector{String}=String[],
    market_depth::Union{UInt16,Nothing}=nothing,
    aggregated_book::Union{Bool,Nothing}=nothing,
    md_entry_types::Vector{UInt8}=UInt8[]       # 0=Bid, 1=Offer, 2=Trade
)
    buf = SBEBuffer()

    # Fixed fields
    write_uint8!(buf, subscription_request_type)
    write_uint16!(buf, isnothing(market_depth) ? SBE_UINT16_NULL : market_depth)
    if isnothing(aggregated_book)
        write_uint8!(buf, SBE_UINT8_NULL)
    else
        write_uint8!(buf, aggregated_book ? UInt8(1) : UInt8(0))
    end

    mark_block_end!(buf)

    # RelatedSym group: blockLength=0 (entries have only var data), numInGroup uint16
    write_uint16!(buf, UInt16(0))
    write_uint16!(buf, UInt16(length(symbols)))
    for sym in symbols
        write_var_string8!(buf, sym)
    end

    # MDEntryTypes group: smallGroupSize8Encoding (blockLength uint8, numInGroup uint8)
    write_uint8!(buf, UInt8(1))                                # 1 byte per entry
    write_uint8!(buf, UInt8(length(md_entry_types)))
    for et in md_entry_types
        write_uint8!(buf, et)
    end

    # Root data
    write_var_string8!(buf, md_req_id)

    return finalize_message!(buf, SBE_TEMPLATE_MARKET_DATA_REQUEST, seq_num)
end

"""
Encode InstrumentListRequest message (templateId=200, schema 1.1)

Fixed: InstrumentListRequestType (uint8).
Data: InstrumentReqID (varString8), Symbol (optionalVarString8).
"""
function encode_instrument_list_request(;
    seq_num::UInt32,
    instrument_req_id::String,
    request_type::UInt8=UInt8(4),  # 4=All instruments, 0=Single instrument
    symbol::String=""
)
    buf = SBEBuffer()

    write_uint8!(buf, request_type)

    mark_block_end!(buf)

    write_var_string8!(buf, instrument_req_id)
    write_var_string8!(buf, symbol)

    return finalize_message!(buf, SBE_TEMPLATE_INSTRUMENT_LIST_REQUEST, seq_num)
end

end # module FIXSBEEncoder
