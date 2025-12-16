module FIXAPI

using Sockets
using Dates
using Base64
using Random
using Binance: BinanceConfig, Signature
using ..FIXConstants

export FIXSession, FIXSessionType, OrderEntry, DropCopy, MarketData
export connect_fix, logon, logout, close_fix
export heartbeat, test_request
export new_order_single, order_cancel_request, order_amend_keep_priority
export order_mass_cancel_request, limit_query
export new_order_list, order_cancel_and_new_order
export create_oco_sell, create_oco_buy, create_oto, create_otoco_sell, create_otoco_buy
export create_opo_sell, create_opo_buy, create_opoco_sell, create_opoco_buy
export market_data_request, instrument_list_request
export subscribe_book_ticker, subscribe_depth_stream, subscribe_trade_stream
export unsubscribe_market_data
export receive_message, parse_fix_message, process_message, get_msg_type
export parse_list_status, parse_limit_response
export ExecutionReportMsg, ListStatusMsg, LimitResponseMsg, RejectMsg, MiscFee
export OrderCancelRejectMsg, OrderMassCancelReportMsg, OrderAmendRejectMsg, LimitIndicator
export ListTriggerInstruction, ListStatusOrder
export MarketDataSnapshotMsg, MarketDataIncrementalMsg, MarketDataRejectMsg
export parse_market_data_snapshot, parse_market_data_incremental
export InstrumentListMsg, InstrumentInfo, MDEntry
export parse_instrument_list
export NewsMsg, is_maintenance_news
export start_monitor, stop_monitor, reconnect
export SESSION_LIMITS, get_session_limits
export is_error, get_error_info
export validate_client_order_id, generate_client_order_id, validate_comp_id
# ExecutionReport helper functions
export is_new, is_fill, is_partial_fill, is_fully_filled, is_canceled, is_rejected, is_expired
export is_working, is_aggressor, has_stp_prevention, get_fees, get_fill_info, get_stp_info
export is_buy, is_sell, is_limit_order, is_market_order, is_stop_order
export is_trailing_order, is_iceberg_order, is_list_order
# OrderCancelReject helper function
export is_list_cancel_reject
# ListStatus helper functions
export is_list_executing, is_list_all_done, is_list_rejected
export is_list_response, is_list_exec_started, is_list_updated
export is_oco_list, is_oto_list, get_list_error_info, get_list_order_count

# =============================================================================
# Session Types
# =============================================================================
# FIX API Key Permissions:
# - OrderEntry: requires FIX_API permission
# - DropCopy: requires FIX_API or FIX_API_READ_ONLY permission
# - MarketData: requires FIX_API or FIX_API_READ_ONLY permission
#
# IMPORTANT: FIX sessions only support Ed25519 keys (not HMAC)
#
# Message Limits (breaching causes immediate Logout and disconnect):
# - OrderEntry: 10,000 messages / 10 seconds
# - DropCopy: 60 messages / 60 seconds
# - MarketData: 2,000 messages / 60 seconds
#
# Connection Limits:
# - OrderEntry: 15 attempts/30s, max 10 concurrent connections
# - DropCopy: 15 attempts/30s, max 10 concurrent connections
# - MarketData: 300 attempts/300s, max 100 concurrent, max 1000 streams/connection
#
# Use LimitQuery (XLQ) to check current limits and usage.
# =============================================================================

@enum FIXSessionType begin
    OrderEntry   # fix-oe.binance.com:9000 - Orders, cancels, execution reports
    DropCopy     # fix-dc.binance.com:9000 - Execution reports only (read-only)
    MarketData   # fix-md.binance.com:9000 - Market data streams
end

# Session-specific limits
const SESSION_LIMITS = Dict(
    OrderEntry => (messages=10000, interval_sec=10, max_connections=10, max_streams=nothing),
    DropCopy => (messages=60, interval_sec=60, max_connections=10, max_streams=nothing),
    MarketData => (messages=2000, interval_sec=60, max_connections=100, max_streams=1000)
)

"""
    get_session_limits(session_type::FIXSessionType)

Get the rate limits for a session type.
Returns a NamedTuple with: messages, interval_sec, max_connections, max_streams
"""
function get_session_limits(session_type::FIXSessionType)
    return SESSION_LIMITS[session_type]
end

# =============================================================================
# Validation Functions (must be defined before FIXSession struct)
# =============================================================================

# SenderCompID/TargetCompID regex pattern: ^[a-zA-Z0-9-_]{1,8}$
const COMP_ID_REGEX = r"^[a-zA-Z0-9\-_]{1,8}$"

"""
    validate_comp_id(id::String, field_name::String="CompID")

Validate that a SenderCompID or TargetCompID conforms to Binance requirements.
Must match regex: ^[a-zA-Z0-9-_]{1,8}\$

Throws an error if validation fails.
"""
function validate_comp_id(id::String, field_name::String="CompID")
    if isempty(id)
        error("$field_name cannot be empty")
    end
    if !occursin(COMP_ID_REGEX, id)
        error("Invalid $field_name '$id'. Must be 1-8 characters, alphanumeric, hyphen, or underscore only.")
    end
end

# =============================================================================
# Parsed Message Structs
# =============================================================================

# Miscellaneous fee entry (from NoMiscFees repeating group)
struct MiscFee
    amount::String      # MiscFeeAmt (137)
    currency::String    # MiscFeeCurr (138)
    fee_type::String    # MiscFeeType (139) - "4" = EXCHANGE_FEES
end

# Comprehensive ExecutionReport struct with all documented fields
struct ExecutionReportMsg
    # Order identification
    cl_ord_id::String           # ClOrdID (11)
    orig_cl_ord_id::String      # OrigClOrdID (41)
    order_id::String            # OrderID (37)
    exec_id::String             # ExecID (17)
    list_id::String             # ListID (66) - for list orders

    # Order details
    symbol::String              # Symbol (55)
    side::String                # Side (54)
    ord_type::String            # OrdType (40)
    order_qty::String           # OrderQty (38)
    cash_order_qty::String      # CashOrderQty (152)
    price::String               # Price (44)
    time_in_force::String       # TimeInForce (59)
    exec_inst::String           # ExecInst (18)
    max_floor::String           # MaxFloor (111) - iceberg orders

    # Execution status
    exec_type::String           # ExecType (150)
    ord_status::String          # OrdStatus (39)

    # Quantities
    cum_qty::String             # CumQty (14) - total base asset traded
    leaves_qty::String          # LeavesQty (151) - remaining qty
    cum_quote_qty::String       # CumQuoteQty (25017) - total quote asset traded
    last_qty::String            # LastQty (32) - qty of last execution
    last_px::String             # LastPx (31) - price of last execution

    # Timestamps
    transact_time::String       # TransactTime (60)
    order_creation_time::String # OrderCreationTime (25018)
    working_time::String        # WorkingTime (25023) - when order hit book
    trailing_time::String       # TrailingTime (25022) - for trailing orders

    # Trade details
    trade_id::String            # TradeID (1003)
    aggressor_indicator::String # AggressorIndicator (1057) - "Y"/"N"
    alloc_id::String            # AllocID (70)
    match_type::String          # MatchType (574)

    # Working status
    working_indicator::String   # WorkingIndicator (636) - "Y" when on book
    working_floor::String       # WorkingFloor (25021)

    # Strategy
    target_strategy::String     # TargetStrategy (847)
    strategy_id::String         # StrategyID (7940)
    sor::String                 # SOR (25032)

    # Self-trade prevention
    self_trade_prevention::String     # SelfTradePreventionMode (25001)
    prevented_match_id::String        # PreventedMatchID (25024)
    prevented_execution_price::String # PreventedExecutionPrice (25025)
    prevented_execution_qty::String   # PreventedExecutionQty (25026)
    trade_group_id::String            # TradeGroupID (25027)
    counter_symbol::String            # CounterSymbol (25028)
    counter_order_id::String          # CounterOrderID (25029)
    prevented_qty::String             # PreventedQty (25030)
    last_prevented_qty::String        # LastPreventedQty (25031)

    # Trigger/Stop order fields
    trigger_type::String              # TriggerType (1100)
    trigger_action::String            # TriggerAction (1101)
    trigger_price::String             # TriggerPrice (1102)
    trigger_price_type::String        # TriggerPriceType (1107)
    trigger_price_direction::String   # TriggerPriceDirection (1109)
    trigger_trailing_delta_bips::String # TriggerTrailingDeltaBips (25009)

    # Pegged order fields
    peg_offset_value::String    # PegOffsetValue (211)
    peg_price_type::String      # PegPriceType (1094)
    peg_move_type::String       # PegMoveType (835)
    peg_offset_type::String     # PegOffsetType (836)
    pegged_price::String        # PeggedPrice (839) - current pegged price

    # Fees
    fees::Vector{MiscFee}       # NoMiscFees (136) repeating group

    # Error info
    error_code::String          # ErrorCode (25016)
    text::String                # Text (58)

    # Raw fields for anything not explicitly parsed
    raw_fields::Dict{Int,String}
end

struct OrderCancelRejectMsg
    cl_ord_id::String             # ClOrdID (11) - from cancel request
    orig_cl_ord_id::String        # OrigClOrdID (41) - from cancel request
    order_id::String              # OrderID (37) - from cancel request
    orig_cl_list_id::String       # OrigClListID (25015) - from cancel request
    list_id::String               # ListID (66) - from cancel request
    symbol::String                # Symbol (55) - from cancel request
    cancel_restrictions::String   # CancelRestrictions (25002) - from cancel request
    cxl_rej_response_to::String   # CxlRejResponseTo (434) - "1" = ORDER_CANCEL_REQUEST
    error_code::String            # ErrorCode (25016)
    text::String                  # Text (58)
    raw_fields::Dict{Int,String}
end

# List triggering instruction entry
struct ListTriggerInstruction
    trigger_type::String           # ListTriggerType (25011)
    trigger_index::String          # ListTriggerTriggerIndex (25012)
    action::String                 # ListTriggerAction (25013)
end

# Order info within ListStatus
struct ListStatusOrder
    symbol::String                 # Symbol (55)
    order_id::String               # OrderID (37)
    cl_ord_id::String              # ClOrdID (11)
    trigger_instructions::Vector{ListTriggerInstruction}  # NoListTriggeringInstructions (25010)
end

struct ListStatusMsg
    symbol::String                 # Symbol (55)
    list_id::String                # ListID (66)
    cl_list_id::String             # ClListID (25014)
    orig_cl_list_id::String        # OrigClListID (25015)
    contingency_type::String       # ContingencyType (1385)
    list_status_type::String       # ListStatusType (429)
    list_order_status::String      # ListOrderStatus (431)
    list_reject_reason::String     # ListRejectReason (1386)
    ord_rej_reason::String         # OrdRejReason (103)
    transact_time::String          # TransactTime (60)
    error_code::String             # ErrorCode (25016)
    text::String                   # Text (58)
    orders::Vector{ListStatusOrder}  # NoOrders (73)
    raw_fields::Dict{Int,String}
end

struct OrderMassCancelReportMsg
    symbol::String                    # Symbol (55)
    cl_ord_id::String                 # ClOrdID (11)
    mass_cancel_request_type::String  # MassCancelRequestType (530)
    mass_cancel_response::String      # MassCancelResponse (531) - "0"=REJECTED, "1"=ACCEPTED
    mass_cancel_reject_reason::String # MassCancelRejectReason (532) - "99"=OTHER
    total_affected_orders::String     # TotalAffectedOrders (533)
    error_code::String                # ErrorCode (25016)
    text::String                      # Text (58)
    raw_fields::Dict{Int,String}
end

struct OrderAmendRejectMsg
    cl_ord_id::String             # ClOrdID (11) - from amend request
    orig_cl_ord_id::String        # OrigClOrdID (41) - from amend request
    order_id::String              # OrderID (37) - from amend request
    symbol::String                # Symbol (55) - from amend request
    order_qty::String             # OrderQty (38) - from amend request
    error_code::String            # ErrorCode (25016)
    text::String                  # Text (58)
    raw_fields::Dict{Int,String}
end

struct LimitIndicator
    limit_type::String
    limit_count::Int
    limit_max::Int
    limit_reset_interval::Int
    limit_reset_interval_resolution::String
end

struct LimitResponseMsg
    req_id::String
    limits::Vector{LimitIndicator}
    raw_fields::Dict{Int,String}
end

# Reject message (error response)
# Text (58) and ErrorCode (25016) contain the reject reason
# See Binance error codes documentation for full list
struct RejectMsg
    ref_seq_num::String       # RefSeqNum (45) - sequence number of rejected message
    ref_tag_id::String        # RefTagID (371) - tag number that caused rejection
    ref_msg_type::String      # RefMsgType (372) - message type of rejected message
    session_reject_reason::String  # SessionRejectReason (373)
    error_code::String        # ErrorCode (25016) - Binance error code
    text::String              # Text (58) - human-readable error description
    raw_fields::Dict{Int,String}
end

"""
    is_error(msg::RejectMsg) -> Bool

Check if a RejectMsg indicates an error (always true for RejectMsg).
"""
is_error(msg::RejectMsg) = true

"""
    get_error_info(msg::RejectMsg) -> NamedTuple

Extract error information from a RejectMsg.
Returns (error_code, text, ref_msg_type, ref_seq_num).
"""
function get_error_info(msg::RejectMsg)
    return (
        error_code=msg.error_code,
        text=msg.text,
        ref_msg_type=msg.ref_msg_type,
        ref_seq_num=msg.ref_seq_num
    )
end

"""
    get_error_info(msg::ExecutionReportMsg) -> Union{NamedTuple, Nothing}

Extract error information from an ExecutionReport if it's a rejection.
Returns nothing if not a rejection.
"""
function get_error_info(msg::ExecutionReportMsg)
    if msg.exec_type == EXEC_TYPE_REJECTED || msg.ord_status == ORD_STATUS_REJECTED
        return (
            error_code=msg.error_code,
            text=msg.text,
            symbol=msg.symbol,
            cl_ord_id=msg.cl_ord_id
        )
    end
    return nothing
end

# =============================================================================
# ExecutionReport Helper Functions
# =============================================================================

"""
    is_new(msg::ExecutionReportMsg) -> Bool

Check if this is a NEW order acknowledgement (ExecType=0).
"""
is_new(msg::ExecutionReportMsg) = msg.exec_type == EXEC_TYPE_NEW

"""
    is_fill(msg::ExecutionReportMsg) -> Bool

Check if this is a trade execution (ExecType=F).
"""
is_fill(msg::ExecutionReportMsg) = msg.exec_type == EXEC_TYPE_TRADE

"""
    is_partial_fill(msg::ExecutionReportMsg) -> Bool

Check if the order is partially filled (OrdStatus=1).
"""
is_partial_fill(msg::ExecutionReportMsg) = msg.ord_status == ORD_STATUS_PARTIALLY_FILLED

"""
    is_fully_filled(msg::ExecutionReportMsg) -> Bool

Check if the order is fully filled (OrdStatus=2).
"""
is_fully_filled(msg::ExecutionReportMsg) = msg.ord_status == ORD_STATUS_FILLED

"""
    is_canceled(msg::ExecutionReportMsg) -> Bool

Check if this is a cancellation (ExecType=4).
"""
is_canceled(msg::ExecutionReportMsg) = msg.exec_type == EXEC_TYPE_CANCELED

"""
    is_rejected(msg::ExecutionReportMsg) -> Bool

Check if this is a rejection (ExecType=8).
"""
is_rejected(msg::ExecutionReportMsg) = msg.exec_type == EXEC_TYPE_REJECTED

"""
    is_expired(msg::ExecutionReportMsg) -> Bool

Check if this is an expiration (ExecType=C).
"""
is_expired(msg::ExecutionReportMsg) = msg.exec_type == EXEC_TYPE_EXPIRED

"""
    is_working(msg::ExecutionReportMsg) -> Bool

Check if the order is on the order book (WorkingIndicator=Y).
"""
is_working(msg::ExecutionReportMsg) = msg.working_indicator == "Y"

"""
    is_aggressor(msg::ExecutionReportMsg) -> Bool

Check if this order was the aggressor/taker in a trade (AggressorIndicator=Y).
Only meaningful for fill executions.
"""
is_aggressor(msg::ExecutionReportMsg) = msg.aggressor_indicator == "Y"

"""
    has_stp_prevention(msg::ExecutionReportMsg) -> Bool

Check if the order expired due to self-trade prevention.
True if PreventedMatchID is present.
"""
has_stp_prevention(msg::ExecutionReportMsg) = !isempty(msg.prevented_match_id)

"""
    get_fees(msg::ExecutionReportMsg) -> Vector{MiscFee}

Get the fees for this execution.
"""
get_fees(msg::ExecutionReportMsg) = msg.fees

"""
    get_fill_info(msg::ExecutionReportMsg) -> Union{NamedTuple, Nothing}

Get fill details from a trade execution report.
Returns nothing if not a fill.
"""
function get_fill_info(msg::ExecutionReportMsg)
    if !is_fill(msg)
        return nothing
    end

    last_qty = tryparse(Float64, msg.last_qty)
    last_px = tryparse(Float64, msg.last_px)
    cum_qty = tryparse(Float64, msg.cum_qty)
    leaves_qty = tryparse(Float64, msg.leaves_qty)
    cum_quote_qty = tryparse(Float64, msg.cum_quote_qty)

    return (
        trade_id=msg.trade_id,
        last_qty=last_qty,
        last_px=last_px,
        cum_qty=cum_qty,
        leaves_qty=leaves_qty,
        cum_quote_qty=cum_quote_qty,
        is_aggressor=is_aggressor(msg),
        is_fully_filled=is_fully_filled(msg),
        fees=msg.fees,
        transact_time=msg.transact_time
    )
end

"""
    get_stp_info(msg::ExecutionReportMsg) -> Union{NamedTuple, Nothing}

Get self-trade prevention details if order expired due to STP.
Returns nothing if not an STP expiration.
"""
function get_stp_info(msg::ExecutionReportMsg)
    if !has_stp_prevention(msg)
        return nothing
    end

    return (
        prevented_match_id=msg.prevented_match_id,
        prevented_execution_price=tryparse(Float64, msg.prevented_execution_price),
        prevented_execution_qty=tryparse(Float64, msg.prevented_execution_qty),
        prevented_qty=tryparse(Float64, msg.prevented_qty),
        last_prevented_qty=tryparse(Float64, msg.last_prevented_qty),
        trade_group_id=msg.trade_group_id,
        counter_symbol=msg.counter_symbol,
        counter_order_id=msg.counter_order_id,
        self_trade_prevention_mode=msg.self_trade_prevention
    )
end

"""
    is_buy(msg::ExecutionReportMsg) -> Bool

Check if this is a buy order.
"""
is_buy(msg::ExecutionReportMsg) = msg.side == SIDE_BUY

"""
    is_sell(msg::ExecutionReportMsg) -> Bool

Check if this is a sell order.
"""
is_sell(msg::ExecutionReportMsg) = msg.side == SIDE_SELL

"""
    is_limit_order(msg::ExecutionReportMsg) -> Bool

Check if this is a limit order.
"""
is_limit_order(msg::ExecutionReportMsg) = msg.ord_type == ORD_TYPE_LIMIT

"""
    is_market_order(msg::ExecutionReportMsg) -> Bool

Check if this is a market order.
"""
is_market_order(msg::ExecutionReportMsg) = msg.ord_type == ORD_TYPE_MARKET

"""
    is_stop_order(msg::ExecutionReportMsg) -> Bool

Check if this is a stop order (STOP_LOSS or STOP_LOSS_LIMIT).
"""
is_stop_order(msg::ExecutionReportMsg) = msg.ord_type == ORD_TYPE_STOP || msg.ord_type == ORD_TYPE_STOP_LIMIT

"""
    is_trailing_order(msg::ExecutionReportMsg) -> Bool

Check if this is a trailing order (has TriggerTrailingDeltaBips set).
"""
is_trailing_order(msg::ExecutionReportMsg) = !isempty(msg.trigger_trailing_delta_bips)

"""
    is_iceberg_order(msg::ExecutionReportMsg) -> Bool

Check if this is an iceberg order (has MaxFloor set).
"""
is_iceberg_order(msg::ExecutionReportMsg) = !isempty(msg.max_floor)

"""
    is_list_order(msg::ExecutionReportMsg) -> Bool

Check if this order is part of an order list (OCO/OTO).
"""
is_list_order(msg::ExecutionReportMsg) = !isempty(msg.list_id)

# =============================================================================
# OrderCancelReject Helper Functions
# =============================================================================

"""
    is_error(msg::OrderCancelRejectMsg) -> Bool

Check if this is an error (always true for OrderCancelReject).
"""
is_error(msg::OrderCancelRejectMsg) = true

"""
    get_error_info(msg::OrderCancelRejectMsg) -> NamedTuple

Extract error information from an OrderCancelReject.
"""
function get_error_info(msg::OrderCancelRejectMsg)
    return (
        error_code=msg.error_code,
        text=msg.text,
        symbol=msg.symbol,
        cl_ord_id=msg.cl_ord_id,
        orig_cl_ord_id=msg.orig_cl_ord_id,
        order_id=msg.order_id
    )
end

"""
    is_list_cancel_reject(msg::OrderCancelRejectMsg) -> Bool

Check if this reject is for a list order cancel.
"""
is_list_cancel_reject(msg::OrderCancelRejectMsg) = !isempty(msg.list_id) || !isempty(msg.orig_cl_list_id)

# =============================================================================
# ListStatus Helper Functions
# =============================================================================

"""
    is_list_executing(msg::ListStatusMsg) -> Bool

Check if the order list is currently executing.
"""
is_list_executing(msg::ListStatusMsg) = msg.list_order_status == LIST_ORDER_STATUS_EXECUTING

"""
    is_list_all_done(msg::ListStatusMsg) -> Bool

Check if the order list is completely done (all orders filled/canceled).
"""
is_list_all_done(msg::ListStatusMsg) = msg.list_order_status == LIST_ORDER_STATUS_ALL_DONE

"""
    is_list_rejected(msg::ListStatusMsg) -> Bool

Check if the order list was rejected.
"""
is_list_rejected(msg::ListStatusMsg) = msg.list_order_status == LIST_ORDER_STATUS_REJECT

"""
    is_list_response(msg::ListStatusMsg) -> Bool

Check if this is a response to an order list request.
"""
is_list_response(msg::ListStatusMsg) = msg.list_status_type == LIST_STATUS_RESPONSE

"""
    is_list_exec_started(msg::ListStatusMsg) -> Bool

Check if order list execution has started.
"""
is_list_exec_started(msg::ListStatusMsg) = msg.list_status_type == LIST_STATUS_EXEC_STARTED

"""
    is_list_updated(msg::ListStatusMsg) -> Bool

Check if this is an update to an existing order list.
"""
is_list_updated(msg::ListStatusMsg) = msg.list_status_type == LIST_STATUS_UPDATED

"""
    is_oco_list(msg::ListStatusMsg) -> Bool

Check if this is an OCO order list.
"""
is_oco_list(msg::ListStatusMsg) = msg.contingency_type == CONTINGENCY_OCO

"""
    is_oto_list(msg::ListStatusMsg) -> Bool

Check if this is an OTO or OTOCO order list.
"""
is_oto_list(msg::ListStatusMsg) = msg.contingency_type == CONTINGENCY_OTO

"""
    get_list_error_info(msg::ListStatusMsg) -> Union{NamedTuple, Nothing}

Extract error information from a ListStatus message if it's a rejection.
Returns nothing if not a rejection.
"""
function get_list_error_info(msg::ListStatusMsg)
    if is_list_rejected(msg)
        return (
            error_code=msg.error_code,
            text=msg.text,
            list_reject_reason=msg.list_reject_reason,
            ord_rej_reason=msg.ord_rej_reason,
            cl_list_id=msg.cl_list_id,
            list_id=msg.list_id
        )
    end
    return nothing
end

"""
    get_list_order_count(msg::ListStatusMsg) -> Int

Get the number of orders in the list.
"""
get_list_order_count(msg::ListStatusMsg) = length(msg.orders)

# =============================================================================
# OrderAmendReject Helper Functions
# =============================================================================

"""
    is_error(msg::OrderAmendRejectMsg) -> Bool

Check if this is an error (always true for OrderAmendReject).
"""
is_error(msg::OrderAmendRejectMsg) = true

"""
    get_error_info(msg::OrderAmendRejectMsg) -> NamedTuple

Extract error information from an OrderAmendReject.
"""
function get_error_info(msg::OrderAmendRejectMsg)
    return (
        error_code=msg.error_code,
        text=msg.text,
        symbol=msg.symbol,
        cl_ord_id=msg.cl_ord_id,
        orig_cl_ord_id=msg.orig_cl_ord_id,
        order_id=msg.order_id,
        order_qty=msg.order_qty
    )
end

# News message (used for maintenance notifications)
struct NewsMsg
    headline::String
    text::String
    urgency::String  # "0"=Normal, "1"=Flash, "2"=Background
    raw_fields::Dict{Int,String}
end

# Market Data Entry (for bids, offers, trades)
struct MDEntry
    entry_type::String           # MDEntryType (269): "0"=Bid, "1"=Offer, "2"=Trade
    price::String                # MDEntryPx (270)
    size::String                 # MDEntrySize (271)
    update_action::String        # MDUpdateAction (279): "0"=New, "1"=Change, "2"=Delete
    symbol::String               # Symbol (55) - may inherit from previous entry
    transact_time::String        # TransactTime (60)
    trade_id::String             # TradeID (1003)
    aggressor_side::String       # AggressorSide (2446): "1"=Buy, "2"=Sell
    first_book_update_id::String # FirstBookUpdateID (25043) - Diff. Depth only
    last_book_update_id::String  # LastBookUpdateID (25044) - Diff. Depth and Book Ticker
end

struct MarketDataSnapshotMsg
    md_req_id::String
    symbol::String
    last_book_update_id::String
    entries::Vector{MDEntry}
    raw_fields::Dict{Int,String}
end

# DEPRECATION NOTICE (2025-12-18):
# The `last_fragment` field (TAG_LAST_FRAGMENT/893) is deprecated and will always be `true`.
# Messages are no longer fragmented; instead, entries are reduced when the message would exceed limits.
# Code should not rely on `last_fragment` for message reassembly.
struct MarketDataIncrementalMsg
    md_req_id::String
    last_fragment::Bool  # DEPRECATED: Always true as of 2025-12-18. See deprecation notice above.
    first_book_update_id::String
    last_book_update_id::String
    entries::Vector{MDEntry}
    raw_fields::Dict{Int,String}
end

struct MarketDataRejectMsg
    md_req_id::String
    reject_reason::String
    error_code::String
    text::String
    raw_fields::Dict{Int,String}
end

# Instrument info for InstrumentList response
struct InstrumentInfo
    symbol::String
    currency::String
    min_trade_vol::String
    max_trade_vol::String
    min_qty_increment::String
    market_min_trade_vol::String
    market_max_trade_vol::String
    market_min_qty_increment::String
    start_price_range::String
    end_price_range::String
    min_price_increment::String
end

struct InstrumentListMsg
    instrument_req_id::String
    instruments::Vector{InstrumentInfo}
    raw_fields::Dict{Int,String}
end

mutable struct FIXSession
    host::String
    port::Int
    socket::Union{IO,Nothing}
    openssl_process::Union{Base.Process,Nothing}  # OpenSSL s_client process for TLS
    seq_num::Int
    sender_comp_id::String
    target_comp_id::String
    config::BinanceConfig
    signer::Any
    session_type::FIXSessionType
    is_logged_in::Bool
    recv_buffer::String

    # Connection lifecycle fields
    heartbeat_interval::Int
    last_sent_time::DateTime
    last_recv_time::DateTime
    pending_test_req_id::String
    test_req_sent_time::Union{DateTime,Nothing}
    maintenance_warning::Bool
    monitor_task::Union{Task,Nothing}
    should_stop::Ref{Bool}

    # Callbacks for connection events
    on_maintenance::Union{Function,Nothing}  # Called when maintenance News received
    on_disconnect::Union{Function,Nothing}   # Called when connection lost/timeout
    on_message::Union{Function,Nothing}      # Called for each received message

    function FIXSession(host::String, port::Int, sender_comp_id::String,
        target_comp_id::String, config::BinanceConfig;
        session_type::FIXSessionType=OrderEntry,
        on_maintenance::Union{Function,Nothing}=nothing,
        on_disconnect::Union{Function,Nothing}=nothing,
        on_message::Union{Function,Nothing}=nothing)
        # Validate CompIDs (must match regex: ^[a-zA-Z0-9-_]{1,8}$)
        validate_comp_id(sender_comp_id, "SenderCompID")
        validate_comp_id(target_comp_id, "TargetCompID")

        signer = Signature.create_signer(config)
        now_time = now(Dates.UTC)
        new(host, port, nothing, nothing, 1, sender_comp_id, target_comp_id, config, signer,
            session_type, false, "",
            30, now_time, now_time, "", nothing, false, nothing, Ref(false),
            on_maintenance, on_disconnect, on_message)
    end
end

# Convenience constructors for each session type
function FIXSession(config::BinanceConfig, sender_comp_id::String;
    session_type::FIXSessionType=OrderEntry,
    on_maintenance::Union{Function,Nothing}=nothing,
    on_disconnect::Union{Function,Nothing}=nothing,
    on_message::Union{Function,Nothing}=nothing)
    # Default target is "SPOT" for all Binance FIX sessions
    target_comp_id = "SPOT"

    # Host and Port based on session type from config
    (host, port) = if session_type == OrderEntry
        (config.fix_order_entry_host, config.fix_order_entry_port)
    elseif session_type == DropCopy
        (config.fix_drop_copy_host, config.fix_drop_copy_port)
    else  # MarketData
        (config.fix_market_data_host, config.fix_market_data_port)
    end

    return FIXSession(host, port, sender_comp_id, target_comp_id, config;
        session_type=session_type,
        on_maintenance=on_maintenance,
        on_disconnect=on_disconnect,
        on_message=on_message)
end

"""
    get_session_limits(session::FIXSession)

Get the rate limits for a FIXSession.
"""
function get_session_limits(session::FIXSession)
    return get_session_limits(session.session_type)
end

function connect_fix(session::FIXSession)
    try
        if session.config.fix_use_tls
            # Use socat to handle TLS connection
            println("DEBUG: Connecting to $(session.host):$(session.port) via TLS...")

            proxy_str = session.config.proxy

            # Check if we should use explicit proxy
            use_explicit_proxy = !isempty(proxy_str) && !startswith(proxy_str, "fake://")

            local cmd
            if use_explicit_proxy
                # Parse proxy URL (http://host:port)
                proxy_match = match(r"https?://([^:]+):(\d+)", proxy_str)
                if !isnothing(proxy_match)
                    proxy_host = proxy_match.captures[1]
                    proxy_port = proxy_match.captures[2]
                    println("DEBUG: Using HTTP CONNECT proxy $(proxy_host):$(proxy_port)")
                    # Two-stage approach:
                    # 1. socat STDIO to PROXY (establishes HTTP CONNECT tunnel)
                    # 2. Pipe through openssl s_client for TLS
                    # Use socat's EXEC to chain openssl after PROXY connection
                    #
                    # socat STDIO PROXY:proxyhost:targethost:targetport,proxyport=X
                    # gives us a plain TCP tunnel through the proxy
                    # Then we need to layer TLS on top - but socat PROXY doesn't support that directly
                    #
                    # Alternative: Use socat to do HTTP CONNECT, then openssl for TLS handshake
                    # This requires a two-process pipeline which Julia doesn't support well
                    #
                    # Best approach for HTTP CONNECT + TLS: use socat OPENSSL with PROXY chained
                    # However, socat OPENSSL doesn't support proxy parameter directly.
                    #
                    # Workaround: Start a background socat PROXY listener, connect via OPENSSL to it
                    # This is complex, so for proxy+TLS we fall back to plain proxy mode (use_tls=false)
                    # and recommend users to run a separate socat proxy process.

                    @warn "HTTP proxy with TLS is complex. For best results, either:\n" *
                          "  1. Set proxy=\"\" in [fix_testnet] config (testnet often accessible directly)\n" *
                          "  2. Use use_tls=false and run a separate socat TLS proxy:\n" *
                          "     socat TCP-LISTEN:19000,fork,reuseaddr \\\n" *
                          "       OPENSSL:$(session.host):$(session.port),verify=0 &\n" *
                          "Attempting direct socat OPENSSL connection (ignoring proxy)..."

                    # Try direct connection (proxy may be transparent/fake-IP mode)
                    cmd = Cmd(["socat", "-T", "30", "STDIO",
                        "OPENSSL:$(session.host):$(session.port),verify=0"])
                else
                    @warn "Invalid proxy format, connecting directly"
                    cmd = Cmd(["socat", "-T", "30", "STDIO", "OPENSSL:$(session.host):$(session.port),verify=0"])
                end
            else
                # Direct TLS connection using socat's native OpenSSL support
                println("DEBUG: Direct TLS connection via socat OPENSSL")
                cmd = Cmd(["socat", "-T", "30", "STDIO", "OPENSSL:$(session.host):$(session.port),verify=0"])
            end

            println("DEBUG: Running command: $cmd")

            # Open bidirectional pipe to process
            # IMPORTANT: Don't sleep here! The server may close the connection
            # if no data is sent within ~1 second after TLS handshake.
            # Proceed directly to logon.
            process = open(cmd, "r+")

            session.openssl_process = process
            session.socket = process

            println("Connected to FIX server at $(session.host):$(session.port) (TLS)")
        else
            # Plain TCP connection
            println("DEBUG: Connecting to $(session.host):$(session.port)...")
            tcp_socket = connect(session.host, session.port)
            session.socket = tcp_socket
            session.openssl_process = nothing
            println("Connected to FIX proxy at $(session.host):$(session.port) (Plain TCP)")
        end

        # Reset timestamps on new connection
        now_time = now(Dates.UTC)
        session.last_sent_time = now_time
        session.last_recv_time = now_time
        session.pending_test_req_id = ""
        session.test_req_sent_time = nothing
        session.maintenance_warning = false

        return session.socket
    catch e
        error("Failed to connect to FIX server: $e")
    end
end

function close_fix(session::FIXSession)
    # Stop monitor if running
    stop_monitor(session)

    if !isnothing(session.socket) && isopen(session.socket)
        close(session.socket)
        println("FIX connection closed")
    end

    # Kill openssl process if running
    if !isnothing(session.openssl_process)
        try
            kill(session.openssl_process)
        catch
            # Process may already be dead
        end
        session.openssl_process = nothing
    end

    session.socket = nothing
    session.is_logged_in = false
end

function get_timestamp()
    return Dates.format(now(Dates.UTC), "yyyymmdd-HH:MM:SS.sss")
end

# Client order ID regex pattern: ^[a-zA-Z0-9-_]{1,36}$
const CLIENT_ORDER_ID_REGEX = r"^[a-zA-Z0-9\-_]{1,36}$"

"""
    validate_client_order_id(id::String)

Validate that a client order ID conforms to Binance requirements.
Must match regex: ^[a-zA-Z0-9-_]{1,36}\$

Throws an error if validation fails.
"""
function validate_client_order_id(id::String)
    if isempty(id)
        return  # Empty is OK, will be auto-generated
    end
    if !occursin(CLIENT_ORDER_ID_REGEX, id)
        error("Invalid client order ID '$id'. Must be 1-36 characters, alphanumeric, hyphen, or underscore only.")
    end
end

"""
    generate_client_order_id(prefix::String="") -> String

Generate a valid client order ID with optional prefix.
Format: {prefix}{random_hex} (max 36 chars total)
"""
function generate_client_order_id(prefix::String="")
    # Leave room for random part
    max_random_len = 36 - length(prefix)
    if max_random_len < 8
        error("Prefix too long, must leave at least 8 characters for random part")
    end
    random_part = string(rand(UInt32), base=16)
    return prefix * random_part
end

function calculate_checksum(msg::String)
    sum_val = sum(UInt8[c for c in msg])
    return lpad(string(sum_val % 256), 3, '0')
end

# Build message with optional timestamp (for signature consistency)
function build_message(session::FIXSession, msg_type::String, fields::Dict{Int,String};
    timestamp::Union{String,Nothing}=nothing)
    if isnothing(timestamp)
        timestamp = get_timestamp()
    end

    header_fields = [
        (35, msg_type),
        (49, session.sender_comp_id),
        (56, session.target_comp_id),
        (34, string(session.seq_num)),
        (52, timestamp)
    ]

    body_str = ""
    for (tag, value) in header_fields
        body_str *= "$tag=$value\x01"
    end

    # Add body fields in sorted order for consistency
    for tag in sort(collect(keys(fields)))
        body_str *= "$tag=$(fields[tag])\x01"
    end

    body_length = length(body_str)
    prefix = "8=FIX.4.4\x019=$body_length\x01"
    full_msg_without_checksum = prefix * body_str

    checksum = calculate_checksum(full_msg_without_checksum)
    return full_msg_without_checksum * "10=$checksum\x01"
end

function send_message(session::FIXSession, msg::String)
    if isnothing(session.socket) || !isopen(session.socket)
        error("FIX session not connected")
    end
    write(session.socket, msg)
    flush(session.socket)
    println("DEBUG: Sent message: $(replace(msg, "\x01" => "|"))")
    session.seq_num += 1
    session.last_sent_time = now(Dates.UTC)
end

function logon(session::FIXSession;
    heartbeat_interval::Int=30,
    message_handling::String=MSG_HANDLING_UNORDERED,
    response_mode::String=RESPONSE_MODE_EVERYTHING,
    recv_window::Union{Float64,Nothing}=nothing,
    uuid::String="",
    sbe_schema_id::Union{Int,Nothing}=nothing,
    sbe_schema_version::Union{Int,Nothing}=nothing,
    timeout_sec::Int=30)
    # Validate heartbeat interval (Binance accepts 5-60 seconds)
    if heartbeat_interval < 5 || heartbeat_interval > 60
        error("HeartBtInt must be between 5 and 60 seconds")
    end

    # Validate message handling mode
    if message_handling ∉ [MSG_HANDLING_UNORDERED, MSG_HANDLING_SEQUENTIAL]
        error("MessageHandling must be UNORDERED(1) or SEQUENTIAL(2)")
    end

    # Validate response mode
    if response_mode ∉ [RESPONSE_MODE_EVERYTHING, RESPONSE_MODE_ONLY_ACKS]
        error("ResponseMode must be EVERYTHING(1) or ONLY_ACKS(2)")
    end

    # Validate recv_window (max 60000ms)
    if !isnothing(recv_window) && (recv_window <= 0 || recv_window > 60000)
        error("RecvWindow must be between 0 and 60000 milliseconds")
    end

    # Store heartbeat interval for monitoring
    session.heartbeat_interval = heartbeat_interval

    # Construct payload for signature
    # MsgType + SenderCompId + TargetCompId + MsgSeqNum + SendingTime
    timestamp = get_timestamp()
    msg_type = MSG_LOGON
    seq_num = string(session.seq_num)

    payload = join([msg_type, session.sender_comp_id, session.target_comp_id, seq_num, timestamp], "\x01")

    # Sign payload
    signature = Signature.sign_message(session.signer, payload)

    fields = Dict{Int,String}()
    fields[98] = "0"                              # EncryptMethod: None / Other
    fields[108] = string(heartbeat_interval)      # HeartBtInt
    fields[TAG_RESET_SEQ_NUM_FLAG] = "Y"          # ResetSeqNumFlag: Required to be Y
    fields[553] = session.config.api_key          # Username
    fields[96] = signature                        # RawData (signature)
    fields[95] = string(length(signature))        # RawDataLength
    # MessageHandling: Required for ALL session types per Binance docs
    fields[TAG_MESSAGE_HANDLING] = message_handling

    # ResponseMode: Only supported in Order Entry sessions
    # Market Data and Drop Copy sessions don't use this field per spotfix-md schema
    if session.session_type == OrderEntry
        fields[TAG_RESPONSE_MODE] = response_mode    # ResponseMode: EVERYTHING or ONLY_ACKS
    end

    # DropCopyFlag: Required for Drop Copy sessions
    if session.session_type == DropCopy
        fields[TAG_DROP_COPY_FLAG] = "Y"
    end

    # RecvWindow: defaults to 5000ms for Logon if not specified
    if !isnothing(recv_window)
        fields[TAG_RECV_WINDOW] = string(recv_window)
    end

    # UUID: Optional unique identifier
    if !isempty(uuid)
        fields[TAG_UUID] = uuid
    end

    # SBE Schema fields: Optional for SBE compatibility
    if !isnothing(sbe_schema_id)
        fields[TAG_SBE_SCHEMA_ID] = string(sbe_schema_id)
    end
    if !isnothing(sbe_schema_version)
        fields[TAG_SBE_SCHEMA_VERSION] = string(sbe_schema_version)
    end

    msg = build_message(session, msg_type, fields; timestamp=timestamp)
    println("Sending Logon...")
    send_message(session, msg)

    # Wait for Logon response from server
    start_time = now(Dates.UTC)
    timeout_ms = timeout_sec * 1000

    while !session.is_logged_in
        elapsed_ms = Dates.value(now(Dates.UTC) - start_time)
        if elapsed_ms > timeout_ms
            error("Logon timeout: no response from server within $(timeout_sec) seconds")
        end

        if !isopen(session.socket)
            error("Connection closed by server while waiting for Logon response")
        end

        # Receive and process messages (with 500ms timeout for each poll)
        messages = receive_message(session; timeout_ms=500)
        for raw_msg in messages
            parsed_fields = parse_fix_message(raw_msg)
            msg_type_recv = get_msg_type(parsed_fields)

            if msg_type_recv == MSG_LOGON
                session.is_logged_in = true
                println("Logon confirmed by server")
                break
            elseif msg_type_recv == MSG_LOGOUT
                logout_text = get(parsed_fields, TAG_TEXT, "Unknown reason")
                error("Logon rejected by server: $logout_text")
            elseif msg_type_recv == MSG_REJECT
                reject_text = get(parsed_fields, TAG_TEXT, "Unknown reason")
                error_code = get(parsed_fields, TAG_ERROR_CODE, "")
                error("Logon rejected: [$error_code] $reject_text")
            end
        end

        if !session.is_logged_in
            sleep(0.1)  # 100ms polling interval
        end
    end

    return session.is_logged_in
end

function logout(session::FIXSession; text::String="")
    fields = Dict{Int,String}()
    if !isempty(text)
        fields[58] = text  # Text
    end

    msg = build_message(session, MSG_LOGOUT, fields)
    println("Sending Logout...")
    send_message(session, msg)
    session.is_logged_in = false
end

function heartbeat(session::FIXSession; test_req_id::String="")
    fields = Dict{Int,String}()
    if !isempty(test_req_id)
        fields[112] = test_req_id  # TestReqID - echo back if responding to TestRequest
    end

    msg = build_message(session, MSG_HEARTBEAT, fields)
    send_message(session, msg)
end

function test_request(session::FIXSession; test_req_id::String="")
    fields = Dict{Int,String}()
    if isempty(test_req_id)
        test_req_id = string(rand(UInt32))
    end
    fields[112] = test_req_id  # TestReqID

    msg = build_message(session, MSG_TEST_REQUEST, fields)
    send_message(session, msg)
    return test_req_id
end

"""
    new_order_single(session, symbol, side; kwargs...)

Send a new order request.

# Arguments
- `symbol::String`: Trading symbol (e.g., "BTCUSDT")
- `side::String`: "1" for Buy, "2" for Sell

# Required Keyword Arguments (depending on order type)
- `order_type::String`: Order type ("1"=Market, "2"=Limit, "3"=Stop, "4"=StopLimit, "P"=Pegged)

# Quantity (one of these is required)
- `quantity::Union{Float64,Nothing}=nothing`: Order quantity
- `cash_order_qty::Union{Float64,Nothing}=nothing`: Quote asset quantity (for reverse market orders)

# Common Keyword Arguments
- `price::Union{Float64,Nothing}=nothing`: Limit price (required for limit orders)
- `time_in_force::String="1"`: "1"=GTC, "3"=IOC, "4"=FOK
- `cl_ord_id::String=""`: Client order ID (auto-generated if empty)
- `recv_window::Union{Float64,Nothing}=nothing`: Request validity window in ms (max 60000)

# Iceberg Order
- `max_floor::Union{Float64,Nothing}=nothing`: Visible quantity for iceberg orders

# Stop/Trigger Orders
- `trigger_price::Union{Float64,Nothing}=nothing`: Activation price
- `trigger_price_direction::String=""`: "U"=Up, "D"=Down (for stop loss vs take profit)
- `trigger_trailing_delta_bips::Union{Int,Nothing}=nothing`: For trailing orders

# Pegged Orders
- `peg_offset_value::Union{Float64,Nothing}=nothing`: Peg offset amount
- `peg_price_type::String=""`: "4"=MARKET_PEG, "5"=PRIMARY_PEG
- `peg_offset_type::String=""`: "3"=PRICE_TIER

# Advanced Options
- `exec_inst::String=""`: "6"=PARTICIPATE_DONT_INITIATE (post-only)
- `self_trade_prevention::String=""`: "1"=NONE, "2"=EXPIRE_TAKER, "3"=EXPIRE_MAKER, "4"=EXPIRE_BOTH, "5"=DECREMENT
- `strategy_id::Union{Int,Nothing}=nothing`: Strategy identifier
- `target_strategy::Union{Int,Nothing}=nothing`: Must be >= 1000000 if specified
- `sor::Bool=false`: Enable Smart Order Routing

Returns the ClOrdID used for the order.
"""
function new_order_single(session::FIXSession, symbol::String, side::String;
    quantity::Union{Float64,Nothing}=nothing,
    cash_order_qty::Union{Float64,Nothing}=nothing,
    price::Union{Float64,Nothing}=nothing,
    order_type::String=ORD_TYPE_LIMIT,
    time_in_force::String=TIF_GTC,
    cl_ord_id::String="",
    recv_window::Union{Float64,Nothing}=nothing,
    # Iceberg
    max_floor::Union{Float64,Nothing}=nothing,
    # Stop/Trigger
    trigger_price::Union{Float64,Nothing}=nothing,
    trigger_price_direction::String="",
    trigger_trailing_delta_bips::Union{Int,Nothing}=nothing,
    # Pegged
    peg_offset_value::Union{Float64,Nothing}=nothing,
    peg_price_type::String="",
    peg_offset_type::String="",
    # Advanced
    exec_inst::String="",
    self_trade_prevention::String="",
    strategy_id::Union{Int,Nothing}=nothing,
    target_strategy::Union{Int,Nothing}=nothing,
    sor::Bool=false)
    if session.session_type != OrderEntry
        error("NewOrderSingle is only supported on Order Entry sessions")
    end

    # Validate quantity - at least one must be specified
    if isnothing(quantity) && isnothing(cash_order_qty)
        error("Either quantity or cash_order_qty must be specified")
    end

    # Validate or generate client order ID
    validate_client_order_id(cl_ord_id)
    if isempty(cl_ord_id)
        cl_ord_id = generate_client_order_id("OID-")
    end

    fields = Dict{Int,String}()
    fields[TAG_CL_ORD_ID] = cl_ord_id
    fields[TAG_SYMBOL] = symbol
    fields[TAG_SIDE] = side
    fields[TAG_ORD_TYPE] = order_type

    # Quantity
    if !isnothing(quantity)
        fields[TAG_ORDER_QTY] = string(quantity)
    end
    if !isnothing(cash_order_qty)
        fields[TAG_CASH_ORDER_QTY] = string(cash_order_qty)
    end

    # Price and time in force
    if !isnothing(price)
        fields[TAG_PRICE] = string(price)
    end
    if !isempty(time_in_force)
        fields[TAG_TIME_IN_FORCE] = time_in_force
    end

    # Iceberg
    if !isnothing(max_floor)
        fields[TAG_MAX_FLOOR] = string(max_floor)
    end

    # Stop/Trigger fields
    if !isnothing(trigger_price)
        fields[TAG_TRIGGER_PRICE] = string(trigger_price)
        fields[TAG_TRIGGER_TYPE] = TRIGGER_TYPE_PRICE_MOVEMENT
        fields[TAG_TRIGGER_ACTION] = TRIGGER_ACTION_ACTIVATE
        fields[TAG_TRIGGER_PRICE_TYPE] = TRIGGER_PRICE_TYPE_LAST_TRADE
    end
    if !isempty(trigger_price_direction)
        fields[TAG_TRIGGER_PRICE_DIRECTION] = trigger_price_direction
    end
    if !isnothing(trigger_trailing_delta_bips)
        fields[TAG_TRIGGER_TRAILING_DELTA_BIPS] = string(trigger_trailing_delta_bips)
    end

    # Pegged order fields
    if !isnothing(peg_offset_value)
        fields[TAG_PEG_OFFSET_VALUE] = string(peg_offset_value)
        fields[TAG_PEG_MOVE_TYPE] = PEG_MOVE_FIXED  # Required for pegged orders
    end
    if !isempty(peg_price_type)
        fields[TAG_PEG_PRICE_TYPE] = peg_price_type
    end
    if !isempty(peg_offset_type)
        fields[TAG_PEG_OFFSET_TYPE] = peg_offset_type
    end

    # Advanced options
    if !isempty(exec_inst)
        fields[TAG_EXEC_INST] = exec_inst
    end
    if !isempty(self_trade_prevention)
        fields[TAG_SELF_TRADE_PREVENTION] = self_trade_prevention
    end
    if !isnothing(strategy_id)
        fields[TAG_STRATEGY_ID] = string(strategy_id)
    end
    if !isnothing(target_strategy)
        if target_strategy < 1000000
            error("TargetStrategy must be >= 1000000")
        end
        fields[TAG_TARGET_STRATEGY] = string(target_strategy)
    end
    if sor
        fields[TAG_SOR] = "Y"
    end

    # RecvWindow
    if !isnothing(recv_window)
        fields[TAG_RECV_WINDOW] = string(recv_window)
    end

    msg = build_message(session, MSG_NEW_ORDER_SINGLE, fields)
    send_message(session, msg)
    return cl_ord_id
end

"""
    order_cancel_request(session, symbol; kwargs...)

Request to cancel an existing order.

# Arguments
- `symbol::String`: Trading symbol (required)

# Keyword Arguments
- `cl_ord_id::String=""`: Client order ID for this cancel request (auto-generated if empty)
- `orig_cl_ord_id::String=""`: Original client order ID to cancel
- `order_id::String=""`: Exchange order ID (alternative to orig_cl_ord_id)
- `orig_cl_list_id::String=""`: Original list ID (for list orders)
- `list_id::String=""`: Exchange list ID
- `cancel_restrictions::String=""`: "1"=ONLY_NEW, "2"=ONLY_PARTIALLY_FILLED
- `recv_window::Union{Float64,Nothing}=nothing`: Request validity window in ms (max 60000)

Returns the ClOrdID used for the cancel request.
"""
function order_cancel_request(session::FIXSession, symbol::String;
    cl_ord_id::String="",
    orig_cl_ord_id::String="",
    order_id::String="",
    orig_cl_list_id::String="",
    list_id::String="",
    cancel_restrictions::String="",
    recv_window::Union{Float64,Nothing}=nothing)
    if session.session_type != OrderEntry
        error("OrderCancelRequest is only supported on Order Entry sessions")
    end

    # Validate client order IDs
    validate_client_order_id(cl_ord_id)
    validate_client_order_id(orig_cl_ord_id)
    validate_client_order_id(orig_cl_list_id)

    if isempty(cl_ord_id)
        cl_ord_id = generate_client_order_id("CXL-")
    end

    fields = Dict{Int,String}()
    fields[TAG_CL_ORD_ID] = cl_ord_id
    fields[TAG_SYMBOL] = symbol

    if !isempty(orig_cl_ord_id)
        fields[TAG_ORIG_CL_ORD_ID] = orig_cl_ord_id
    end
    if !isempty(order_id)
        fields[TAG_ORDER_ID] = order_id
    end
    if !isempty(orig_cl_list_id)
        fields[TAG_ORIG_CL_LIST_ID] = orig_cl_list_id
    end
    if !isempty(list_id)
        fields[TAG_LIST_ID] = list_id
    end
    if !isempty(cancel_restrictions)
        fields[TAG_CANCEL_RESTRICTIONS] = cancel_restrictions
    end
    if !isnothing(recv_window)
        fields[TAG_RECV_WINDOW] = string(recv_window)
    end

    msg = build_message(session, MSG_ORDER_CANCEL_REQUEST, fields)
    send_message(session, msg)
    return cl_ord_id
end

"""
    order_amend_keep_priority(session, symbol, quantity; kwargs...)

Amend order quantity while keeping queue priority (XAK message).
Only quantity can be decreased, not increased.

This adds 0 orders to the EXCHANGE_MAX_ORDERS filter and the MAX_NUM_ORDERS filter.
Unfilled Order Count: 0

# Arguments
- `symbol::String`: Trading symbol (required)
- `quantity::Float64`: New order quantity (must be less than original)

# Keyword Arguments
- `cl_ord_id::String=""`: Client order ID for this request (auto-generated if empty)
  - Note: Can be the same as the order's ClOrdID; if so, ClOrdID remains unchanged
- `orig_cl_ord_id::String=""`: Original client order ID to amend
- `order_id::String=""`: Exchange order ID to amend
  - Either `orig_cl_ord_id` or `order_id` must be specified
  - If both provided, OrderID is searched first, then OrigClOrdID is verified

# Response Messages
- `Reject<3>`: Invalid request (missing fields, invalid symbol, message limit exceeded)
- `OrderAmendReject<XAR>`: Failed (insufficient rate limits, non-existent order, invalid quantity)
- `ExecutionReport<8>`: Success for single order
- `ExecutionReport<8> + ListStatus<N>`: Success for order in an order list

# Important Notes
- New quantity must be smaller than the original OrderQty
- Keeps the order's position in the queue (priority maintained)
- Does not count toward order limits

Returns the ClOrdID used.
"""
function order_amend_keep_priority(session::FIXSession, symbol::String, quantity::Float64;
    cl_ord_id::String="",
    orig_cl_ord_id::String="",
    order_id::String="")
    if session.session_type != OrderEntry
        error("OrderAmendKeepPriority is only supported on Order Entry sessions")
    end

    # Validate client order IDs
    validate_client_order_id(cl_ord_id)
    validate_client_order_id(orig_cl_ord_id)

    if isempty(cl_ord_id)
        cl_ord_id = generate_client_order_id("AMD-")
    end

    fields = Dict{Int,String}()
    fields[TAG_CL_ORD_ID] = cl_ord_id
    fields[TAG_SYMBOL] = symbol
    fields[TAG_ORDER_QTY] = string(quantity)

    if !isempty(orig_cl_ord_id)
        fields[TAG_ORIG_CL_ORD_ID] = orig_cl_ord_id
    end
    if !isempty(order_id)
        fields[TAG_ORDER_ID] = order_id
    end

    msg = build_message(session, MSG_ORDER_AMEND_KEEP_PRIORITY, fields)
    send_message(session, msg)
    return cl_ord_id
end

"""
    order_mass_cancel_request(session, symbol; kwargs...)

Request to cancel all orders for a symbol.

# Arguments
- `symbol::String`: Trading symbol (required)

# Keyword Arguments
- `cl_ord_id::String=""`: Client order ID for this request

Returns the ClOrdID used.
"""
function order_mass_cancel_request(session::FIXSession, symbol::String;
    cl_ord_id::String="")
    if session.session_type != OrderEntry
        error("OrderMassCancelRequest is only supported on Order Entry sessions")
    end

    # Validate client order ID
    validate_client_order_id(cl_ord_id)

    if isempty(cl_ord_id)
        cl_ord_id = generate_client_order_id("MCX-")
    end

    fields = Dict{Int,String}()
    fields[TAG_CL_ORD_ID] = cl_ord_id
    fields[TAG_SYMBOL] = symbol
    fields[TAG_MASS_CANCEL_REQUEST_TYPE] = MASS_CANCEL_SYMBOL

    msg = build_message(session, MSG_ORDER_MASS_CANCEL_REQUEST, fields)
    send_message(session, msg)
    return cl_ord_id
end

"""
    limit_query(session; kwargs...)

Query current rate limits and unfilled order count (XLQ message).

Sends a LimitQuery<XLQ> message. The server responds with LimitResponse<XLR>
containing:
- Unfilled Order Count: How many orders placed within time interval
- Message Limits: Current message rate limit usage

Note: If orders are consistently filled by trades, you can continuously place
orders. Exceeding unfilled order count results in message rejection.

# Keyword Arguments
- `req_id::String=""`: Request ID (auto-generated if empty)

Returns the ReqID used.
"""
function limit_query(session::FIXSession; req_id::String="")
    if session.session_type != OrderEntry
        error("LimitQuery is only supported on Order Entry sessions")
    end

    # Validate request ID (uses similar pattern)
    validate_client_order_id(req_id)

    if isempty(req_id)
        req_id = generate_client_order_id("LMQ-")
    end

    fields = Dict{Int,String}()
    fields[TAG_REQ_ID] = req_id

    msg = build_message(session, MSG_LIMIT_QUERY, fields)
    send_message(session, msg)
    return req_id
end

"""
    create_oco_sell(below_price, above_price, quantity; kwargs...)

Helper to create OCO SELL order list with proper triggering instructions.

# Arguments
- `below_price::Float64`: Price for below order (STOP_LOSS/STOP_LOSS_LIMIT)
- `above_price::Float64`: Price for above order (LIMIT_MAKER)
- `quantity::Float64`: Order quantity

# Returns
Vector of order dictionaries ready for `new_order_list` with `contingency_type=CONTINGENCY_OCO`
"""
function create_oco_sell(below_price::Float64, above_price::Float64, quantity::Float64;
    below_stop_price::Union{Float64,Nothing}=nothing,
    time_in_force::String=TIF_GTC)
    if isnothing(below_stop_price)
        below_stop_price = below_price
    end

    return [
        # Order 1: Below order (STOP_LOSS_LIMIT)
        Dict{Symbol,Any}(
            :side => SIDE_SELL,
            :ord_type => ORD_TYPE_STOP_LIMIT,
            :quantity => quantity,
            :price => below_price,
            :trigger_price => below_stop_price,
            :trigger_price_direction => TRIGGER_DOWN,
            :time_in_force => time_in_force,
            :list_trigger_instructions => [
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_PARTIALLY_FILLED,
                    :trigger_index => 1,
                    :action => LIST_TRIGGER_ACTION_CANCEL
                )
            ]
        ),
        # Order 2: Above order (LIMIT_MAKER)
        Dict{Symbol,Any}(
            :side => SIDE_SELL,
            :ord_type => ORD_TYPE_LIMIT,
            :quantity => quantity,
            :price => above_price,
            :time_in_force => time_in_force,
            :exec_inst => EXEC_INST_PARTICIPATE_DONT_INITIATE,
            :list_trigger_instructions => [
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_ACTIVATED,
                    :trigger_index => 0,
                    :action => LIST_TRIGGER_ACTION_CANCEL
                )
            ]
        )
    ]
end

"""
    create_oco_buy(below_price, above_price, quantity; kwargs...)

Helper to create OCO BUY order list with proper triggering instructions.

# Arguments
- `below_price::Float64`: Price for below order (LIMIT_MAKER)
- `above_price::Float64`: Price for above order (STOP_LOSS/STOP_LOSS_LIMIT)
- `quantity::Float64`: Order quantity

# Returns
Vector of order dictionaries ready for `new_order_list` with `contingency_type=CONTINGENCY_OCO`
"""
function create_oco_buy(below_price::Float64, above_price::Float64, quantity::Float64;
    above_stop_price::Union{Float64,Nothing}=nothing,
    time_in_force::String=TIF_GTC)
    if isnothing(above_stop_price)
        above_stop_price = above_price
    end

    return [
        # Order 1: Below order (LIMIT_MAKER)
        Dict{Symbol,Any}(
            :side => SIDE_BUY,
            :ord_type => ORD_TYPE_LIMIT,
            :quantity => quantity,
            :price => below_price,
            :time_in_force => time_in_force,
            :exec_inst => EXEC_INST_PARTICIPATE_DONT_INITIATE,
            :list_trigger_instructions => [
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_ACTIVATED,
                    :trigger_index => 1,
                    :action => LIST_TRIGGER_ACTION_CANCEL
                )
            ]
        ),
        # Order 2: Above order (STOP_LOSS_LIMIT)
        Dict{Symbol,Any}(
            :side => SIDE_BUY,
            :ord_type => ORD_TYPE_STOP_LIMIT,
            :quantity => quantity,
            :price => above_price,
            :trigger_price => above_stop_price,
            :trigger_price_direction => TRIGGER_UP,
            :time_in_force => time_in_force,
            :list_trigger_instructions => [
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_PARTIALLY_FILLED,
                    :trigger_index => 0,
                    :action => LIST_TRIGGER_ACTION_CANCEL
                )
            ]
        )
    ]
end

"""
    create_oto(working_side, working_price, pending_side, pending_price, quantity; kwargs...)

Helper to create OTO order list with proper triggering instructions.

# Arguments
- `working_side::String`: Side for working order ("1"=BUY, "2"=SELL)
- `working_price::Float64`: Price for working order (LIMIT/LIMIT_MAKER)
- `pending_side::String`: Side for pending order
- `pending_price::Float64`: Price for pending order
- `quantity::Float64`: Order quantity

# Keyword Arguments
- `pending_ord_type::String`: Order type for pending order (default: LIMIT)
- `working_limit_maker::Bool`: Use LIMIT_MAKER for working order (default: true)

# Returns
Vector of order dictionaries ready for `new_order_list` with `contingency_type=CONTINGENCY_OTO`
"""
function create_oto(working_side::String, working_price::Float64,
    pending_side::String, pending_price::Float64, quantity::Float64;
    pending_ord_type::String=ORD_TYPE_LIMIT,
    working_limit_maker::Bool=true,
    time_in_force::String=TIF_GTC)

    working_order = Dict{Symbol,Any}(
        :side => working_side,
        :ord_type => ORD_TYPE_LIMIT,
        :quantity => quantity,
        :price => working_price,
        :time_in_force => time_in_force
    )

    if working_limit_maker
        working_order[:exec_inst] = EXEC_INST_PARTICIPATE_DONT_INITIATE
    end

    pending_order = Dict{Symbol,Any}(
        :side => pending_side,
        :ord_type => pending_ord_type,
        :quantity => quantity,
        :price => pending_price,
        :time_in_force => time_in_force,
        :list_trigger_instructions => [
            Dict{Symbol,Any}(
                :trigger_type => LIST_TRIGGER_FILLED,
                :trigger_index => 0,
                :action => LIST_TRIGGER_ACTION_RELEASE
            )
        ]
    )

    return [working_order, pending_order]
end

"""
    create_otoco_sell(working_price, below_price, above_price, quantity; kwargs...)

Helper to create OTOCO SELL order list with proper triggering instructions.
Working order triggers an OCO pair (take profit above + stop loss below).

# Arguments
- `working_price::Float64`: Entry price for working order
- `below_price::Float64`: Stop loss price (below current)
- `above_price::Float64`: Take profit price (above current)
- `quantity::Float64`: Order quantity

# Keyword Arguments
- `working_side::String`: Side for working order (default: BUY for long position)

# Returns
Vector of order dictionaries ready for `new_order_list` with `contingency_type=CONTINGENCY_OTO`
"""
function create_otoco_sell(working_price::Float64, below_price::Float64,
    above_price::Float64, quantity::Float64;
    working_side::String=SIDE_BUY,
    below_stop_price::Union{Float64,Nothing}=nothing,
    time_in_force::String=TIF_GTC)
    if isnothing(below_stop_price)
        below_stop_price = below_price
    end

    return [
        # Order 1: Working order (entry)
        Dict{Symbol,Any}(
            :side => working_side,
            :ord_type => ORD_TYPE_LIMIT,
            :quantity => quantity,
            :price => working_price,
            :time_in_force => time_in_force,
            :exec_inst => EXEC_INST_PARTICIPATE_DONT_INITIATE
        ),
        # Order 2: Pending below order (stop loss)
        Dict{Symbol,Any}(
            :side => SIDE_SELL,
            :ord_type => ORD_TYPE_STOP_LIMIT,
            :quantity => quantity,
            :price => below_price,
            :trigger_price => below_stop_price,
            :trigger_price_direction => TRIGGER_DOWN,
            :time_in_force => time_in_force,
            :list_trigger_instructions => [
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_FILLED,
                    :trigger_index => 0,
                    :action => LIST_TRIGGER_ACTION_CANCEL
                ),
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_PARTIALLY_FILLED,
                    :trigger_index => 2,
                    :action => LIST_TRIGGER_ACTION_CANCEL
                )
            ]
        ),
        # Order 3: Pending above order (take profit)
        Dict{Symbol,Any}(
            :side => SIDE_SELL,
            :ord_type => ORD_TYPE_LIMIT,
            :quantity => quantity,
            :price => above_price,
            :time_in_force => time_in_force,
            :exec_inst => EXEC_INST_PARTICIPATE_DONT_INITIATE,
            :list_trigger_instructions => [
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_FILLED,
                    :trigger_index => 0,
                    :action => LIST_TRIGGER_ACTION_CANCEL
                ),
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_ACTIVATED,
                    :trigger_index => 1,
                    :action => LIST_TRIGGER_ACTION_CANCEL
                )
            ]
        )
    ]
end

"""
    create_otoco_buy(working_price, below_price, above_price, quantity; kwargs...)

Helper to create OTOCO BUY order list with proper triggering instructions.
Working order triggers an OCO pair (take profit below + stop loss above).

# Arguments
- `working_price::Float64`: Entry price for working order
- `below_price::Float64`: Take profit price (below current)
- `above_price::Float64`: Stop loss price (above current)
- `quantity::Float64`: Order quantity

# Keyword Arguments
- `working_side::String`: Side for working order (default: SELL for short position)

# Returns
Vector of order dictionaries ready for `new_order_list` with `contingency_type=CONTINGENCY_OTO`
"""
function create_otoco_buy(working_price::Float64, below_price::Float64,
    above_price::Float64, quantity::Float64;
    working_side::String=SIDE_SELL,
    above_stop_price::Union{Float64,Nothing}=nothing,
    time_in_force::String=TIF_GTC)
    if isnothing(above_stop_price)
        above_stop_price = above_price
    end

    return [
        # Order 1: Working order (entry)
        Dict{Symbol,Any}(
            :side => working_side,
            :ord_type => ORD_TYPE_LIMIT,
            :quantity => quantity,
            :price => working_price,
            :time_in_force => time_in_force,
            :exec_inst => EXEC_INST_PARTICIPATE_DONT_INITIATE
        ),
        # Order 2: Pending below order (take profit)
        Dict{Symbol,Any}(
            :side => SIDE_BUY,
            :ord_type => ORD_TYPE_LIMIT,
            :quantity => quantity,
            :price => below_price,
            :time_in_force => time_in_force,
            :exec_inst => EXEC_INST_PARTICIPATE_DONT_INITIATE,
            :list_trigger_instructions => [
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_FILLED,
                    :trigger_index => 0,
                    :action => LIST_TRIGGER_ACTION_CANCEL
                ),
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_ACTIVATED,
                    :trigger_index => 2,
                    :action => LIST_TRIGGER_ACTION_CANCEL
                )
            ]
        ),
        # Order 3: Pending above order (stop loss)
        Dict{Symbol,Any}(
            :side => SIDE_BUY,
            :ord_type => ORD_TYPE_STOP_LIMIT,
            :quantity => quantity,
            :price => above_price,
            :trigger_price => above_stop_price,
            :trigger_price_direction => TRIGGER_UP,
            :time_in_force => time_in_force,
            :list_trigger_instructions => [
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_FILLED,
                    :trigger_index => 0,
                    :action => LIST_TRIGGER_ACTION_CANCEL
                ),
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_PARTIALLY_FILLED,
                    :trigger_index => 1,
                    :action => LIST_TRIGGER_ACTION_CANCEL
                )
            ]
        )
    ]
end

"""
    create_opo_sell(trigger_price, working_price, pending_price, quantity; kwargs...)

Helper to create OPO SELL order list with proper triggering instructions.
One Pays the Other - working order triggers a pending order when filled.

# Arguments
- `trigger_price::Float64`: Price that triggers the working order
- `working_price::Float64`: Price for working order (becomes active when trigger is hit)
- `pending_price::Float64`: Price for pending order (activated when working order fills)
- `quantity::Float64`: Order quantity

# Keyword Arguments
- `time_in_force::String=TIF_GTC`: Time in force for orders

# Returns
Vector of order dictionaries ready for `new_order_list` with `contingency_type=CONTINGENCY_OTO` and `opo=true`

# Note
OPO orders must be placed with `opo=true` in `new_order_list`.
"""
function create_opo_sell(trigger_price::Float64, working_price::Float64,
    pending_price::Float64, quantity::Float64;
    time_in_force::String=TIF_GTC)

    return [
        # Order 1: Working order (triggered by trigger_price, then limit order)
        Dict{Symbol,Any}(
            :side => SIDE_SELL,
            :ord_type => ORD_TYPE_STOP_LIMIT,
            :quantity => quantity,
            :price => working_price,
            :trigger_price => trigger_price,
            :trigger_price_direction => TRIGGER_DOWN,
            :time_in_force => time_in_force
        ),
        # Order 2: Pending order (released when working order fills)
        Dict{Symbol,Any}(
            :side => SIDE_BUY,
            :ord_type => ORD_TYPE_LIMIT,
            :quantity => quantity,
            :price => pending_price,
            :time_in_force => time_in_force,
            :list_trigger_instructions => [
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_FILLED,
                    :trigger_index => 0,
                    :action => LIST_TRIGGER_ACTION_RELEASE
                )
            ]
        )
    ]
end

"""
    create_opo_buy(trigger_price, working_price, pending_price, quantity; kwargs...)

Helper to create OPO BUY order list with proper triggering instructions.
One Pays the Other - working order triggers a pending order when filled.

# Arguments
- `trigger_price::Float64`: Price that triggers the working order
- `working_price::Float64`: Price for working order (becomes active when trigger is hit)
- `pending_price::Float64`: Price for pending order (activated when working order fills)
- `quantity::Float64`: Order quantity

# Keyword Arguments
- `time_in_force::String=TIF_GTC`: Time in force for orders

# Returns
Vector of order dictionaries ready for `new_order_list` with `contingency_type=CONTINGENCY_OTO` and `opo=true`

# Note
OPO orders must be placed with `opo=true` in `new_order_list`.
"""
function create_opo_buy(trigger_price::Float64, working_price::Float64,
    pending_price::Float64, quantity::Float64;
    time_in_force::String=TIF_GTC)

    return [
        # Order 1: Working order (triggered by trigger_price, then limit order)
        Dict{Symbol,Any}(
            :side => SIDE_BUY,
            :ord_type => ORD_TYPE_STOP_LIMIT,
            :quantity => quantity,
            :price => working_price,
            :trigger_price => trigger_price,
            :trigger_price_direction => TRIGGER_UP,
            :time_in_force => time_in_force
        ),
        # Order 2: Pending order (released when working order fills)
        Dict{Symbol,Any}(
            :side => SIDE_SELL,
            :ord_type => ORD_TYPE_LIMIT,
            :quantity => quantity,
            :price => pending_price,
            :time_in_force => time_in_force,
            :list_trigger_instructions => [
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_FILLED,
                    :trigger_index => 0,
                    :action => LIST_TRIGGER_ACTION_RELEASE
                )
            ]
        )
    ]
end

"""
    create_opoco_sell(trigger_price, working_price, below_price, above_price, quantity; kwargs...)

Helper to create OPOCO SELL order list with proper triggering instructions.
Working order triggers an OCO pair (take profit above + stop loss below) when filled.

# Arguments
- `trigger_price::Float64`: Price that triggers the working order
- `working_price::Float64`: Entry price for working order
- `below_price::Float64`: Stop loss price (below current)
- `above_price::Float64`: Take profit price (above current)
- `quantity::Float64`: Order quantity

# Keyword Arguments
- `below_stop_price::Union{Float64,Nothing}=nothing`: Stop trigger price (defaults to below_price)
- `time_in_force::String=TIF_GTC`: Time in force for orders

# Returns
Vector of order dictionaries ready for `new_order_list` with `contingency_type=CONTINGENCY_OTO` and `opo=true`

# Note
OPOCO orders must be placed with `opo=true` in `new_order_list`.
"""
function create_opoco_sell(trigger_price::Float64, working_price::Float64,
    below_price::Float64, above_price::Float64, quantity::Float64;
    below_stop_price::Union{Float64,Nothing}=nothing,
    time_in_force::String=TIF_GTC)
    if isnothing(below_stop_price)
        below_stop_price = below_price
    end

    return [
        # Order 1: Working order (entry - triggered by trigger_price)
        Dict{Symbol,Any}(
            :side => SIDE_SELL,
            :ord_type => ORD_TYPE_STOP_LIMIT,
            :quantity => quantity,
            :price => working_price,
            :trigger_price => trigger_price,
            :trigger_price_direction => TRIGGER_DOWN,
            :time_in_force => time_in_force
        ),
        # Order 2: Pending below order (stop loss - released when working fills)
        Dict{Symbol,Any}(
            :side => SIDE_BUY,
            :ord_type => ORD_TYPE_STOP_LIMIT,
            :quantity => quantity,
            :price => below_price,
            :trigger_price => below_stop_price,
            :trigger_price_direction => TRIGGER_DOWN,
            :time_in_force => time_in_force,
            :list_trigger_instructions => [
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_FILLED,
                    :trigger_index => 0,
                    :action => LIST_TRIGGER_ACTION_RELEASE
                ),
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_PARTIALLY_FILLED,
                    :trigger_index => 2,
                    :action => LIST_TRIGGER_ACTION_CANCEL
                )
            ]
        ),
        # Order 3: Pending above order (take profit - released when working fills)
        Dict{Symbol,Any}(
            :side => SIDE_BUY,
            :ord_type => ORD_TYPE_LIMIT,
            :quantity => quantity,
            :price => above_price,
            :time_in_force => time_in_force,
            :exec_inst => EXEC_INST_PARTICIPATE_DONT_INITIATE,
            :list_trigger_instructions => [
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_FILLED,
                    :trigger_index => 0,
                    :action => LIST_TRIGGER_ACTION_RELEASE
                ),
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_ACTIVATED,
                    :trigger_index => 1,
                    :action => LIST_TRIGGER_ACTION_CANCEL
                )
            ]
        )
    ]
end

"""
    create_opoco_buy(trigger_price, working_price, below_price, above_price, quantity; kwargs...)

Helper to create OPOCO BUY order list with proper triggering instructions.
Working order triggers an OCO pair (take profit below + stop loss above) when filled.

# Arguments
- `trigger_price::Float64`: Price that triggers the working order
- `working_price::Float64`: Entry price for working order
- `below_price::Float64`: Take profit price (below current)
- `above_price::Float64`: Stop loss price (above current)
- `quantity::Float64`: Order quantity

# Keyword Arguments
- `above_stop_price::Union{Float64,Nothing}=nothing`: Stop trigger price (defaults to above_price)
- `time_in_force::String=TIF_GTC`: Time in force for orders

# Returns
Vector of order dictionaries ready for `new_order_list` with `contingency_type=CONTINGENCY_OTO` and `opo=true`

# Note
OPOCO orders must be placed with `opo=true` in `new_order_list`.
"""
function create_opoco_buy(trigger_price::Float64, working_price::Float64,
    below_price::Float64, above_price::Float64, quantity::Float64;
    above_stop_price::Union{Float64,Nothing}=nothing,
    time_in_force::String=TIF_GTC)
    if isnothing(above_stop_price)
        above_stop_price = above_price
    end

    return [
        # Order 1: Working order (entry - triggered by trigger_price)
        Dict{Symbol,Any}(
            :side => SIDE_BUY,
            :ord_type => ORD_TYPE_STOP_LIMIT,
            :quantity => quantity,
            :price => working_price,
            :trigger_price => trigger_price,
            :trigger_price_direction => TRIGGER_UP,
            :time_in_force => time_in_force
        ),
        # Order 2: Pending below order (take profit - released when working fills)
        Dict{Symbol,Any}(
            :side => SIDE_SELL,
            :ord_type => ORD_TYPE_LIMIT,
            :quantity => quantity,
            :price => below_price,
            :time_in_force => time_in_force,
            :exec_inst => EXEC_INST_PARTICIPATE_DONT_INITIATE,
            :list_trigger_instructions => [
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_FILLED,
                    :trigger_index => 0,
                    :action => LIST_TRIGGER_ACTION_RELEASE
                ),
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_ACTIVATED,
                    :trigger_index => 2,
                    :action => LIST_TRIGGER_ACTION_CANCEL
                )
            ]
        ),
        # Order 3: Pending above order (stop loss - released when working fills)
        Dict{Symbol,Any}(
            :side => SIDE_SELL,
            :ord_type => ORD_TYPE_STOP_LIMIT,
            :quantity => quantity,
            :price => above_price,
            :trigger_price => above_stop_price,
            :trigger_price_direction => TRIGGER_UP,
            :time_in_force => time_in_force,
            :list_trigger_instructions => [
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_FILLED,
                    :trigger_index => 0,
                    :action => LIST_TRIGGER_ACTION_RELEASE
                ),
                Dict{Symbol,Any}(
                    :trigger_type => LIST_TRIGGER_PARTIALLY_FILLED,
                    :trigger_index => 1,
                    :action => LIST_TRIGGER_ACTION_CANCEL
                )
            ]
        )
    ]
end

"""
    new_order_list(session, symbol, orders; kwargs...)

Place an order list (OCO, OTO, OTOCO, OPO, OPOCO).

# Arguments
- `symbol::String`: Trading symbol
- `orders::Vector{Dict}`: List of orders (2-3 orders), each with required keys:
  - `:side` - "1"=Buy, "2"=Sell (required)
  - `:ord_type` - Order type (required)
  - `:quantity` or `:cash_order_qty` - Order quantity (one required)

  Optional keys per order:
  - `:cl_ord_id` - Client order ID (auto-generated if not provided)
  - `:price` - Limit price
  - `:time_in_force` - "1"=GTC, "3"=IOC, "4"=FOK
  - `:exec_inst` - "6"=PARTICIPATE_DONT_INITIATE
  - `:max_floor` - For iceberg orders
  - `:target_strategy` - Must be >= 1000000
  - `:strategy_id` - Strategy identifier
  - `:self_trade_prevention` - STP mode

  Trigger/Stop fields:
  - `:trigger_price` - Activation price
  - `:trigger_price_direction` - "U"=Up, "D"=Down
  - `:trigger_trailing_delta_bips` - For trailing orders

  Pegged order fields:
  - `:peg_offset_value` - Peg offset amount
  - `:peg_price_type` - "4"=MARKET_PEG, "5"=PRIMARY_PEG
  - `:peg_offset_type` - "3"=PRICE_TIER

  List triggering instructions (for OTO/OTOCO):
  - `:list_trigger_instructions` - Vector of Dict with:
    - `:trigger_type` - "1"=ACTIVATED, "2"=PARTIALLY_FILLED, "3"=FILLED
    - `:trigger_index` - Index of trigger order (0-indexed)
    - `:action` - "1"=RELEASE, "2"=CANCEL

# Keyword Arguments
- `cl_list_id::String=""`: Client list ID (auto-generated if empty)
- `contingency_type::String`: "1"=OCO, "2"=OTO (also used for OTOCO)
- `opo::Bool=false`: One Party Only flag - if true, order list can only trade with a single counterparty

# Unfilled Order Count
- OCO: 2 orders
- OTO: 2 orders
- OTOCO: 3 orders (uses ContingencyType=2, distinguished by order count and triggering instructions)

# Important Notes
- **Order sequence matters!** Orders must be in the correct sequence (below/above for OCO, working/pending for OTO/OTOCO)
- **List triggering instructions are required** for OCO orders (not optional)
- **OTOCO uses ContingencyType=2** (same as OTO), distinguished by having 3 orders with specific triggering instructions
- Use helper functions (`create_oco_sell`, `create_oco_buy`, `create_oto`, `create_otoco_sell`, `create_otoco_buy`)
  to ensure correct order sequences and triggering instructions

Returns the ClListID used.
"""
function new_order_list(session::FIXSession, symbol::String, orders::Vector{Dict{Symbol,Any}};
    cl_list_id::String="",
    contingency_type::String=CONTINGENCY_OCO,
    opo::Bool=false)
    if session.session_type != OrderEntry
        error("NewOrderList is only supported on Order Entry sessions")
    end

    # Validate number of orders
    num_orders = length(orders)
    if num_orders < 2 || num_orders > 3
        error("NewOrderList requires 2 or 3 orders, got $num_orders")
    end

    # Validate list ID (similar pattern to client order ID)
    validate_client_order_id(cl_list_id)

    if isempty(cl_list_id)
        cl_list_id = generate_client_order_id("LST-")
    end

    # Validate and generate order IDs within the list
    for (i, order) in enumerate(orders)
        if haskey(order, :cl_ord_id)
            validate_client_order_id(order[:cl_ord_id])
        end

        # Validate required fields
        if !haskey(order, :side)
            error("Order $i missing required field :side")
        end
        if !haskey(order, :ord_type)
            error("Order $i missing required field :ord_type")
        end
        if !haskey(order, :quantity) && !haskey(order, :cash_order_qty)
            error("Order $i must have either :quantity or :cash_order_qty")
        end
    end

    # Build message manually for repeating groups
    timestamp = get_timestamp()
    body_str = ""

    # Header fields
    body_str *= "$(TAG_MSG_TYPE)=$(MSG_NEW_ORDER_LIST)\x01"
    body_str *= "$(TAG_SENDER_COMP_ID)=$(session.sender_comp_id)\x01"
    body_str *= "$(TAG_TARGET_COMP_ID)=$(session.target_comp_id)\x01"
    body_str *= "$(TAG_MSG_SEQ_NUM)=$(session.seq_num)\x01"
    body_str *= "$(TAG_SENDING_TIME)=$timestamp\x01"

    # List fields
    body_str *= "$(TAG_CL_LIST_ID)=$cl_list_id\x01"
    body_str *= "$(TAG_CONTINGENCY_TYPE)=$contingency_type\x01"

    # OPO (One Party Only) flag - Optional
    if opo
        body_str *= "$(TAG_OPO)=Y\x01"
    end

    body_str *= "$(TAG_NO_ORDERS)=$num_orders\x01"

    # Add each order with all supported fields
    for (i, order) in enumerate(orders)
        # Generate ClOrdID if not provided
        cl_ord_id = get(order, :cl_ord_id, "")
        if isempty(cl_ord_id)
            cl_ord_id = generate_client_order_id("O$i-")
        end

        # Required fields
        body_str *= "$(TAG_CL_ORD_ID)=$cl_ord_id\x01"
        body_str *= "$(TAG_SYMBOL)=$symbol\x01"
        body_str *= "$(TAG_SIDE)=$(order[:side])\x01"
        body_str *= "$(TAG_ORD_TYPE)=$(order[:ord_type])\x01"

        # Quantity (one of these is required)
        if haskey(order, :quantity)
            body_str *= "$(TAG_ORDER_QTY)=$(order[:quantity])\x01"
        end
        if haskey(order, :cash_order_qty)
            body_str *= "$(TAG_CASH_ORDER_QTY)=$(order[:cash_order_qty])\x01"
        end

        # Price and time in force
        if haskey(order, :price)
            body_str *= "$(TAG_PRICE)=$(order[:price])\x01"
        end
        if haskey(order, :time_in_force)
            body_str *= "$(TAG_TIME_IN_FORCE)=$(order[:time_in_force])\x01"
        end

        # Execution instructions
        if haskey(order, :exec_inst)
            body_str *= "$(TAG_EXEC_INST)=$(order[:exec_inst])\x01"
        end

        # Iceberg
        if haskey(order, :max_floor)
            body_str *= "$(TAG_MAX_FLOOR)=$(order[:max_floor])\x01"
        end

        # Strategy
        if haskey(order, :target_strategy)
            if order[:target_strategy] < 1000000
                error("Order $i: TargetStrategy must be >= 1000000")
            end
            body_str *= "$(TAG_TARGET_STRATEGY)=$(order[:target_strategy])\x01"
        end
        if haskey(order, :strategy_id)
            body_str *= "$(TAG_STRATEGY_ID)=$(order[:strategy_id])\x01"
        end

        # Self-trade prevention
        if haskey(order, :self_trade_prevention)
            body_str *= "$(TAG_SELF_TRADE_PREVENTION)=$(order[:self_trade_prevention])\x01"
        end

        # Pegged order fields
        if haskey(order, :peg_offset_value)
            body_str *= "$(TAG_PEG_OFFSET_VALUE)=$(order[:peg_offset_value])\x01"
            # PegMoveType is required for pegged orders
            body_str *= "$(TAG_PEG_MOVE_TYPE)=$(PEG_MOVE_FIXED)\x01"
        end
        if haskey(order, :peg_price_type)
            body_str *= "$(TAG_PEG_PRICE_TYPE)=$(order[:peg_price_type])\x01"
        end
        if haskey(order, :peg_offset_type)
            body_str *= "$(TAG_PEG_OFFSET_TYPE)=$(order[:peg_offset_type])\x01"
        end

        # Trigger/Stop order fields
        if haskey(order, :trigger_price)
            body_str *= "$(TAG_TRIGGER_PRICE)=$(order[:trigger_price])\x01"
            # Set required trigger fields
            body_str *= "$(TAG_TRIGGER_TYPE)=$(TRIGGER_TYPE_PRICE_MOVEMENT)\x01"
            body_str *= "$(TAG_TRIGGER_ACTION)=$(TRIGGER_ACTION_ACTIVATE)\x01"
            body_str *= "$(TAG_TRIGGER_PRICE_TYPE)=$(TRIGGER_PRICE_TYPE_LAST_TRADE)\x01"
        end
        if haskey(order, :trigger_price_direction)
            body_str *= "$(TAG_TRIGGER_PRICE_DIRECTION)=$(order[:trigger_price_direction])\x01"
        end
        if haskey(order, :trigger_trailing_delta_bips)
            body_str *= "$(TAG_TRIGGER_TRAILING_DELTA_BIPS)=$(order[:trigger_trailing_delta_bips])\x01"
        end

        # List triggering instructions (for OTO/OTOCO)
        if haskey(order, :list_trigger_instructions)
            instructions = order[:list_trigger_instructions]
            body_str *= "$(TAG_NO_LIST_TRIGGERING_INSTRUCTIONS)=$(length(instructions))\x01"

            for instr in instructions
                if haskey(instr, :trigger_type)
                    body_str *= "$(TAG_LIST_TRIGGER_TYPE)=$(instr[:trigger_type])\x01"
                end
                if haskey(instr, :trigger_index)
                    body_str *= "$(TAG_LIST_TRIGGER_TRIGGER_INDEX)=$(instr[:trigger_index])\x01"
                end
                if haskey(instr, :action)
                    body_str *= "$(TAG_LIST_TRIGGER_ACTION)=$(instr[:action])\x01"
                end
            end
        end
    end

    body_length = length(body_str)
    prefix = "8=FIX.4.4\x019=$body_length\x01"
    full_msg = prefix * body_str
    checksum = calculate_checksum(full_msg)
    final_msg = full_msg * "10=$checksum\x01"

    send_message(session, final_msg)
    return cl_list_id
end

"""
    order_cancel_and_new_order(session, symbol, side, ord_type; kwargs...)

Atomically cancel an existing order and place a new one (XCN message).

Cancel is always processed first, then immediately the new order is submitted.
Filters and Order Count are evaluated before the processing occurs.

# Arguments
- `symbol::String`: Trading symbol
- `side::String`: Side of the new order ("1"=Buy, "2"=Sell)
- `ord_type::String`: Order type for the new order

# Cancel Parameters
- `cancel_order_id::String=""`: OrderID of the order to cancel (preferred for performance)
- `cancel_orig_cl_ord_id::String=""`: ClOrdID of the order to cancel
- `cancel_cl_ord_id::String=""`: ClOrdID for the cancel request itself

# Mode Parameters
- `mode::String="1"`: Action if cancel fails - "1"=STOP_ON_FAILURE, "2"=ALLOW_FAILURE
- `rate_limit_exceeded_mode::String=""`: Action if rate limit exceeded - "1"=DO_NOTHING, "2"=CANCEL_ONLY
- `cancel_restrictions::String=""`: "1"=ONLY_NEW, "2"=ONLY_PARTIALLY_FILLED

# New Order Parameters
- `cl_ord_id::String=""`: ClOrdID for the new order (auto-generated if empty)
- `quantity::Union{Float64,Nothing}=nothing`: Order quantity
- `cash_order_qty::Union{Float64,Nothing}=nothing`: Quote asset quantity (for reverse market orders)
- `price::Union{Float64,Nothing}=nothing`: Limit price
- `time_in_force::String=""`: "1"=GTC, "3"=IOC, "4"=FOK
- `max_floor::Union{Float64,Nothing}=nothing`: Visible quantity for iceberg orders

# Stop/Trigger Parameters
- `trigger_price::Union{Float64,Nothing}=nothing`: Activation price
- `trigger_price_direction::String=""`: "U"=Up, "D"=Down
- `trigger_trailing_delta_bips::Union{Int,Nothing}=nothing`: For trailing orders

# Pegged Order Parameters
- `peg_offset_value::Union{Float64,Nothing}=nothing`: Peg offset amount
- `peg_price_type::String=""`: "4"=MARKET_PEG, "5"=PRIMARY_PEG
- `peg_move_type::String=""`: "1"=FIXED (required for pegged orders)
- `peg_offset_type::String=""`: "3"=PRICE_TIER

# Advanced Options
- `exec_inst::String=""`: "6"=PARTICIPATE_DONT_INITIATE (post-only)
- `self_trade_prevention::String=""`: STP mode
- `strategy_id::Union{Int,Nothing}=nothing`: Strategy identifier
- `target_strategy::Union{Int,Nothing}=nothing`: Must be >= 1000000

Returns a NamedTuple with (cancel_cl_ord_id, new_cl_ord_id).
"""
function order_cancel_and_new_order(session::FIXSession, symbol::String, side::String, ord_type::String;
    # Cancel parameters
    cancel_order_id::String="",
    cancel_orig_cl_ord_id::String="",
    cancel_cl_ord_id::String="",
    # Mode parameters
    mode::String=XCN_MODE_STOP_ON_FAILURE,
    rate_limit_exceeded_mode::String="",
    cancel_restrictions::String="",
    # New order identification
    cl_ord_id::String="",
    # Quantity
    quantity::Union{Float64,Nothing}=nothing,
    cash_order_qty::Union{Float64,Nothing}=nothing,
    # Price and time in force
    price::Union{Float64,Nothing}=nothing,
    time_in_force::String="",
    # Iceberg
    max_floor::Union{Float64,Nothing}=nothing,
    # Stop/Trigger
    trigger_price::Union{Float64,Nothing}=nothing,
    trigger_price_direction::String="",
    trigger_trailing_delta_bips::Union{Int,Nothing}=nothing,
    # Pegged
    peg_offset_value::Union{Float64,Nothing}=nothing,
    peg_price_type::String="",
    peg_move_type::String="",
    peg_offset_type::String="",
    # Advanced
    exec_inst::String="",
    self_trade_prevention::String="",
    strategy_id::Union{Int,Nothing}=nothing,
    target_strategy::Union{Int,Nothing}=nothing)
    if session.session_type != OrderEntry
        error("OrderCancelAndNewOrder is only supported on Order Entry sessions")
    end

    # Validate client order IDs
    validate_client_order_id(cancel_orig_cl_ord_id)
    validate_client_order_id(cancel_cl_ord_id)
    validate_client_order_id(cl_ord_id)

    # Generate IDs if not provided
    if isempty(cancel_cl_ord_id)
        cancel_cl_ord_id = generate_client_order_id("CXL-")
    end
    if isempty(cl_ord_id)
        cl_ord_id = generate_client_order_id("NEW-")
    end

    fields = Dict{Int,String}()

    # Mode (required)
    fields[TAG_ORDER_CANCEL_AND_NEW_MODE] = mode

    # Rate limit exceeded mode (optional)
    if !isempty(rate_limit_exceeded_mode)
        fields[TAG_ORDER_RATE_LIMIT_EXCEEDED_MODE] = rate_limit_exceeded_mode
    end

    # Cancel part - OrderID preferred for performance
    if !isempty(cancel_order_id)
        fields[TAG_ORDER_ID] = cancel_order_id
    end
    if !isempty(cancel_orig_cl_ord_id)
        fields[TAG_ORIG_CL_ORD_ID] = cancel_orig_cl_ord_id
    end
    fields[TAG_CANCEL_CL_ORD_ID] = cancel_cl_ord_id

    if !isempty(cancel_restrictions)
        fields[TAG_CANCEL_RESTRICTIONS] = cancel_restrictions
    end

    # New order - required fields
    fields[TAG_CL_ORD_ID] = cl_ord_id
    fields[TAG_SYMBOL] = symbol
    fields[TAG_SIDE] = side
    fields[TAG_ORD_TYPE] = ord_type

    # Quantity
    if !isnothing(quantity)
        fields[TAG_ORDER_QTY] = string(quantity)
    end
    if !isnothing(cash_order_qty)
        fields[TAG_CASH_ORDER_QTY] = string(cash_order_qty)
    end

    # Price and time in force
    if !isnothing(price)
        fields[TAG_PRICE] = string(price)
    end
    if !isempty(time_in_force)
        fields[TAG_TIME_IN_FORCE] = time_in_force
    end

    # Iceberg
    if !isnothing(max_floor)
        fields[TAG_MAX_FLOOR] = string(max_floor)
    end

    # Stop/Trigger fields
    if !isnothing(trigger_price)
        fields[TAG_TRIGGER_PRICE] = string(trigger_price)
        fields[TAG_TRIGGER_TYPE] = TRIGGER_TYPE_PRICE_MOVEMENT
        fields[TAG_TRIGGER_ACTION] = TRIGGER_ACTION_ACTIVATE
        fields[TAG_TRIGGER_PRICE_TYPE] = TRIGGER_PRICE_TYPE_LAST_TRADE
    end
    if !isempty(trigger_price_direction)
        fields[TAG_TRIGGER_PRICE_DIRECTION] = trigger_price_direction
    end
    if !isnothing(trigger_trailing_delta_bips)
        fields[TAG_TRIGGER_TRAILING_DELTA_BIPS] = string(trigger_trailing_delta_bips)
    end

    # Pegged order fields
    if !isnothing(peg_offset_value)
        fields[TAG_PEG_OFFSET_VALUE] = string(peg_offset_value)
    end
    if !isempty(peg_price_type)
        fields[TAG_PEG_PRICE_TYPE] = peg_price_type
    end
    if !isempty(peg_move_type)
        fields[TAG_PEG_MOVE_TYPE] = peg_move_type
    end
    if !isempty(peg_offset_type)
        fields[TAG_PEG_OFFSET_TYPE] = peg_offset_type
    end

    # Advanced options
    if !isempty(exec_inst)
        fields[TAG_EXEC_INST] = exec_inst
    end
    if !isempty(self_trade_prevention)
        fields[TAG_SELF_TRADE_PREVENTION] = self_trade_prevention
    end
    if !isnothing(strategy_id)
        fields[TAG_STRATEGY_ID] = string(strategy_id)
    end
    if !isnothing(target_strategy)
        if target_strategy < 1000000
            error("TargetStrategy must be >= 1000000")
        end
        fields[TAG_TARGET_STRATEGY] = string(target_strategy)
    end

    msg = build_message(session, MSG_ORDER_CANCEL_AND_NEW, fields)
    send_message(session, msg)
    return (cancel_cl_ord_id=cancel_cl_ord_id, new_cl_ord_id=cl_ord_id)
end

# =============================================================================
# Market Data Session Messages
# =============================================================================

"""
    market_data_request(session, symbols; kwargs...)

Request market data subscription or unsubscription.

# Stream Types

**Trade Stream** - Real-time trade information
- Set `entry_types=[MD_ENTRY_TRADE]`
- Update speed: Real-time

**Book Ticker Stream** - Best bid/offer updates
- Set `market_depth=1` and `entry_types=[MD_ENTRY_BID, MD_ENTRY_OFFER]`
- Update speed: Real-time

**Diff. Depth Stream** - Order book depth updates for local order book management
- Set `market_depth=2-5000` and `entry_types=[MD_ENTRY_BID, MD_ENTRY_OFFER]`
- Update speed: 100ms
- Note: Initial snapshot limited to 5000 levels per side

# Arguments
- `symbols::Vector{String}`: List of symbols to subscribe to (can be empty for unsubscribe)

# Keyword Arguments
- `md_req_id::String=""`: Request ID (auto-generated if empty). Use same ID to unsubscribe.
- `subscription_type::String=MD_SUBSCRIBE`: `MD_SUBSCRIBE` or `MD_UNSUBSCRIBE`
- `market_depth::Int=0`: 1=Book Ticker, 2-5000=Depth Stream levels
- `entry_types::Vector{String}=[MD_ENTRY_BID, MD_ENTRY_OFFER]`: Entry types to subscribe
- `aggregated_book::Bool=true`: One book entry per side per price (Y)

# Examples
```julia
# Book Ticker Stream
market_data_request(session, ["BTCUSDT"];
    md_req_id="BOOK_TICKER",
    market_depth=1,
    entry_types=[MD_ENTRY_BID, MD_ENTRY_OFFER])

# Diff. Depth Stream (10 levels initial snapshot)
market_data_request(session, ["BTCUSDT"];
    md_req_id="DEPTH",
    market_depth=10,
    entry_types=[MD_ENTRY_BID, MD_ENTRY_OFFER])

# Trade Stream
market_data_request(session, ["BTCUSDT"];
    md_req_id="TRADES",
    entry_types=[MD_ENTRY_TRADE])

# Unsubscribe (use same md_req_id)
market_data_request(session, String[];
    md_req_id="TRADES",
    subscription_type=MD_UNSUBSCRIBE)
```

Returns the MDReqID used.
"""
function market_data_request(session::FIXSession, symbols::Vector{String};
    md_req_id::String="",
    subscription_type::String=MD_SUBSCRIBE,
    market_depth::Int=0,
    entry_types::Vector{String}=[MD_ENTRY_BID, MD_ENTRY_OFFER],
    aggregated_book::Bool=true)
    if session.session_type != MarketData
        error("MarketDataRequest is only supported on Market Data sessions")
    end

    # Validate request ID (uses similar pattern)
    validate_client_order_id(md_req_id)

    if isempty(md_req_id)
        md_req_id = generate_client_order_id("MDR-")
    end

    # Build message manually for repeating groups
    timestamp = get_timestamp()
    body_str = ""

    # Header fields
    body_str *= "$(TAG_MSG_TYPE)=$(MSG_MARKET_DATA_REQUEST)\x01"
    body_str *= "$(TAG_SENDER_COMP_ID)=$(session.sender_comp_id)\x01"
    body_str *= "$(TAG_TARGET_COMP_ID)=$(session.target_comp_id)\x01"
    body_str *= "$(TAG_MSG_SEQ_NUM)=$(session.seq_num)\x01"
    body_str *= "$(TAG_SENDING_TIME)=$timestamp\x01"

    # MarketDataRequest fields
    body_str *= "$(TAG_MD_REQ_ID)=$md_req_id\x01"
    body_str *= "$(TAG_SUBSCRIPTION_REQUEST_TYPE)=$subscription_type\x01"

    if market_depth > 0
        body_str *= "$(TAG_MARKET_DEPTH)=$market_depth\x01"
    end

    # For unsubscription, only MDReqID and SubscriptionRequestType are needed
    if subscription_type == MD_SUBSCRIBE
        # AggregatedBook
        if aggregated_book
            body_str *= "$(TAG_AGGREGATED_BOOK)=Y\x01"
        end

        # NoRelatedSym group
        if !isempty(symbols)
            body_str *= "$(TAG_NO_RELATED_SYM)=$(length(symbols))\x01"
            for symbol in symbols
                body_str *= "$(TAG_SYMBOL)=$symbol\x01"
            end
        end

        # NoMDEntryTypes group
        if !isempty(entry_types)
            body_str *= "$(TAG_NO_MD_ENTRY_TYPES)=$(length(entry_types))\x01"
            for et in entry_types
                body_str *= "$(TAG_MD_ENTRY_TYPE)=$et\x01"
            end
        end
    end

    body_length = length(body_str)
    prefix = "8=FIX.4.4\x019=$body_length\x01"
    full_msg = prefix * body_str
    checksum = calculate_checksum(full_msg)
    final_msg = full_msg * "10=$checksum\x01"

    send_message(session, final_msg)
    return md_req_id
end

"""
    subscribe_book_ticker(session, symbols; md_req_id="")

Subscribe to Book Ticker stream for best bid/offer updates in real-time.

# Arguments
- `symbols::Vector{String}`: Symbols to subscribe to (can also pass single String)
- `md_req_id::String=""`: Request ID (auto-generated if empty)

# Example
```julia
req_id = subscribe_book_ticker(session, ["BTCUSDT", "ETHUSDT"])
# or
req_id = subscribe_book_ticker(session, "BTCUSDT")
```

Returns the MDReqID used.
"""
function subscribe_book_ticker(session::FIXSession, symbols::Vector{String};
    md_req_id::String="")
    if isempty(md_req_id)
        md_req_id = generate_client_order_id("BKT-")
    end
    return market_data_request(session, symbols;
        md_req_id=md_req_id,
        market_depth=1,
        entry_types=[MD_ENTRY_BID, MD_ENTRY_OFFER])
end

# Convenience method for single symbol
subscribe_book_ticker(session::FIXSession, symbol::String; md_req_id::String="") =
    subscribe_book_ticker(session, [symbol]; md_req_id=md_req_id)

"""
    subscribe_depth_stream(session, symbols; md_req_id="", depth=100)

Subscribe to Diff. Depth stream for order book updates (100ms update speed).

Use this to maintain a local order book. The initial snapshot is limited to
`depth` levels per side (max 5000).

# Arguments
- `symbols::Vector{String}`: Symbols to subscribe to (can also pass single String)
- `md_req_id::String=""`: Request ID (auto-generated if empty)
- `depth::Int=100`: Initial snapshot depth (2-5000)

# Example
```julia
req_id = subscribe_depth_stream(session, "BTCUSDT"; depth=50)
```

Returns the MDReqID used.
"""
function subscribe_depth_stream(session::FIXSession, symbols::Vector{String};
    md_req_id::String="", depth::Int=100)
    if depth < 2 || depth > 5000
        error("Depth must be between 2 and 5000")
    end
    if isempty(md_req_id)
        md_req_id = generate_client_order_id("DEP-")
    end
    return market_data_request(session, symbols;
        md_req_id=md_req_id,
        market_depth=depth,
        entry_types=[MD_ENTRY_BID, MD_ENTRY_OFFER])
end

# Convenience method for single symbol
subscribe_depth_stream(session::FIXSession, symbol::String;
    md_req_id::String="", depth::Int=100) =
    subscribe_depth_stream(session, [symbol]; md_req_id=md_req_id, depth=depth)

"""
    subscribe_trade_stream(session, symbols; md_req_id="")

Subscribe to Trade stream for real-time trade information.

Each trade has a unique buyer and seller.

# Arguments
- `symbols::Vector{String}`: Symbols to subscribe to (can also pass single String)
- `md_req_id::String=""`: Request ID (auto-generated if empty)

# Example
```julia
req_id = subscribe_trade_stream(session, "BTCUSDT")
```

Returns the MDReqID used.
"""
function subscribe_trade_stream(session::FIXSession, symbols::Vector{String};
    md_req_id::String="")
    if isempty(md_req_id)
        md_req_id = generate_client_order_id("TRD-")
    end
    return market_data_request(session, symbols;
        md_req_id=md_req_id,
        entry_types=[MD_ENTRY_TRADE])
end

# Convenience method for single symbol
subscribe_trade_stream(session::FIXSession, symbol::String; md_req_id::String="") =
    subscribe_trade_stream(session, [symbol]; md_req_id=md_req_id)

"""
    unsubscribe_market_data(session, md_req_id)

Unsubscribe from a market data stream.

# Arguments
- `md_req_id::String`: The MDReqID of the subscription to cancel

# Example
```julia
req_id = subscribe_trade_stream(session, "BTCUSDT")
# ... later ...
unsubscribe_market_data(session, req_id)
```
"""
function unsubscribe_market_data(session::FIXSession, md_req_id::String)
    return market_data_request(session, String[];
        md_req_id=md_req_id,
        subscription_type=MD_UNSUBSCRIBE)
end

"""
    instrument_list_request(session; kwargs...)

Request list of available instruments.

# Keyword Arguments
- `instrument_req_id::String=""`: Request ID (auto-generated if empty)
- `request_type::String="4"`: "0"=Single instrument, "4"=All instruments
- `symbol::String=""`: Symbol (required if request_type="0")

Returns the InstrumentReqID used.
"""
function instrument_list_request(session::FIXSession;
    instrument_req_id::String="",
    request_type::String=INSTRUMENT_LIST_ALL,
    symbol::String="")
    if session.session_type != MarketData
        error("InstrumentListRequest is only supported on Market Data sessions")
    end

    # Validate request ID (uses similar pattern)
    validate_client_order_id(instrument_req_id)

    if isempty(instrument_req_id)
        instrument_req_id = generate_client_order_id("ILR-")
    end

    fields = Dict{Int,String}()
    fields[TAG_INSTRUMENT_REQ_ID] = instrument_req_id
    fields[TAG_INSTRUMENT_LIST_REQUEST_TYPE] = request_type

    if !isempty(symbol)
        fields[TAG_SYMBOL] = symbol
    end

    msg = build_message(session, MSG_INSTRUMENT_LIST_REQUEST, fields)
    send_message(session, msg)
    return instrument_req_id
end

# =============================================================================
# Message Receiving and Parsing
# =============================================================================

"""
    receive_message(session; timeout_ms=0)

Receive and return raw FIX message(s) from the session.

Returns a vector of raw message strings, or empty vector if no data available.
"""
function receive_message(session::FIXSession; timeout_ms::Int=0, verbose::Bool=false)
    if isnothing(session.socket) || !isopen(session.socket)
        return String[]
    end

    # Check if openssl process is still alive
    if !isnothing(session.openssl_process) && !process_running(session.openssl_process)
        @warn "OpenSSL process has terminated"
        return String[]
    end

    # Read data using async task with timeout
    try
        max_wait_sec = timeout_ms > 0 ? timeout_ms / 1000.0 : 0.1

        # Create an async read task
        read_task = @async begin
            buf = IOBuffer()
            start_time = time()
            while isopen(session.socket) && (time() - start_time) < max_wait_sec + 1.0
                # For process pipes, check if data is available
                if bytesavailable(session.socket) > 0
                    byte = read(session.socket, UInt8)
                    write(buf, byte)
                    # Check if we have a complete message (ends with checksum pattern)
                    data = String(take!(copy(buf)))
                    if occursin(r"10=\d{3}\x01", data)
                        return String(take!(buf))
                    end
                else
                    sleep(0.001)  # Small sleep to avoid busy loop
                end
            end
            return String(take!(buf))
        end

        # Wait with timeout
        timer = Timer(max_wait_sec)
        while !istaskdone(read_task) && isopen(timer)
            sleep(0.01)
        end
        close(timer)

        if istaskdone(read_task)
            data = fetch(read_task)
            if !isempty(data)
                session.recv_buffer *= data
            end
        end
    catch e
        if !(e isa EOFError || e isa Base.IOError)
            @warn "Error reading from socket: $e"
        end
    end

    # Extract complete messages from buffer
    messages = String[]
    while true
        # Look for message start
        begin_idx = findfirst("8=FIX", session.recv_buffer)
        if isnothing(begin_idx)
            if !isempty(session.recv_buffer)
                println("DEBUG: Buffer has $(length(session.recv_buffer)) bytes but no start tag found yet")
            end
            session.recv_buffer = ""
            break
        end

        # Look for checksum field (message end)
        checksum_pattern = r"10=\d{3}\x01"
        checksum_match = match(checksum_pattern, session.recv_buffer, begin_idx[1])
        if isnothing(checksum_match)
            # Incomplete message, keep buffer
            println("DEBUG: Found message start but no end tag yet")
            break
        end

        # Extract complete message
        msg_end = checksum_match.offset + length(checksum_match.match) - 1
        msg = session.recv_buffer[begin_idx[1]:msg_end]
        push!(messages, msg)
        println("DEBUG: Extracted full message: $(replace(msg, "\x01" => "|"))")

        # Remove processed message from buffer
        session.recv_buffer = session.recv_buffer[msg_end+1:end]

        if verbose
            readable = replace(msg, "\x01" => "|")
            println("Received: $readable")
        end
    end

    # Update last received time if we got any messages
    if !isempty(messages)
        session.last_recv_time = now(Dates.UTC)
    end

    return messages
end

"""
    parse_fix_message(msg::String)

Parse a raw FIX message into a Dict of tag => value pairs.
"""
function parse_fix_message(msg::String)
    fields = Dict{Int,String}()

    # Split by SOH character
    parts = split(msg, '\x01', keepempty=false)

    for part in parts
        eq_idx = findfirst('=', part)
        if !isnothing(eq_idx)
            tag_str = part[1:eq_idx-1]
            value = part[eq_idx+1:end]
            tag = tryparse(Int, tag_str)
            if !isnothing(tag)
                fields[tag] = value
            end
        end
    end

    return fields
end

"""
    get_msg_type(fields::Dict{Int,String})

Get the message type from parsed fields.
"""
function get_msg_type(fields::Dict{Int,String})
    return get(fields, 35, "")
end

"""
    parse_execution_report(fields::Dict{Int,String})

Parse an ExecutionReport (MsgType=8) message.
"""
function parse_execution_report(fields::Dict{Int,String})
    # Parse fees repeating group
    fees = parse_misc_fees(fields)

    return ExecutionReportMsg(
        # Order identification
        get(fields, TAG_CL_ORD_ID, ""),
        get(fields, TAG_ORIG_CL_ORD_ID, ""),
        get(fields, TAG_ORDER_ID, ""),
        get(fields, TAG_EXEC_ID, ""),
        get(fields, TAG_LIST_ID, ""),

        # Order details
        get(fields, TAG_SYMBOL, ""),
        get(fields, TAG_SIDE, ""),
        get(fields, TAG_ORD_TYPE, ""),
        get(fields, TAG_ORDER_QTY, ""),
        get(fields, TAG_CASH_ORDER_QTY, ""),
        get(fields, TAG_PRICE, ""),
        get(fields, TAG_TIME_IN_FORCE, ""),
        get(fields, TAG_EXEC_INST, ""),
        get(fields, TAG_MAX_FLOOR, ""),

        # Execution status
        get(fields, TAG_EXEC_TYPE, ""),
        get(fields, TAG_ORD_STATUS, ""),

        # Quantities
        get(fields, TAG_CUM_QTY, ""),
        get(fields, TAG_LEAVES_QTY, ""),
        get(fields, TAG_CUM_QUOTE_QTY, ""),
        get(fields, TAG_LAST_QTY, ""),
        get(fields, TAG_LAST_PX, ""),

        # Timestamps
        get(fields, TAG_TRANSACT_TIME, ""),
        get(fields, TAG_ORDER_CREATION_TIME, ""),
        get(fields, TAG_WORKING_TIME, ""),
        get(fields, TAG_TRAILING_TIME, ""),

        # Trade details
        get(fields, TAG_TRADE_ID, ""),
        get(fields, TAG_AGGRESSOR_INDICATOR, ""),
        get(fields, TAG_ALLOC_ID, ""),
        get(fields, TAG_MATCH_TYPE, ""),

        # Working status
        get(fields, TAG_WORKING_INDICATOR, ""),
        get(fields, TAG_WORKING_FLOOR, ""),

        # Strategy
        get(fields, TAG_TARGET_STRATEGY, ""),
        get(fields, TAG_STRATEGY_ID, ""),
        get(fields, TAG_SOR, ""),

        # Self-trade prevention
        get(fields, TAG_SELF_TRADE_PREVENTION, ""),
        get(fields, TAG_PREVENTED_MATCH_ID, ""),
        get(fields, TAG_PREVENTED_EXECUTION_PRICE, ""),
        get(fields, TAG_PREVENTED_EXECUTION_QTY, ""),
        get(fields, TAG_TRADE_GROUP_ID, ""),
        get(fields, TAG_COUNTER_SYMBOL, ""),
        get(fields, TAG_COUNTER_ORDER_ID, ""),
        get(fields, TAG_PREVENTED_QTY, ""),
        get(fields, TAG_LAST_PREVENTED_QTY, ""),

        # Trigger/Stop order fields
        get(fields, TAG_TRIGGER_TYPE, ""),
        get(fields, TAG_TRIGGER_ACTION, ""),
        get(fields, TAG_TRIGGER_PRICE, ""),
        get(fields, TAG_TRIGGER_PRICE_TYPE, ""),
        get(fields, TAG_TRIGGER_PRICE_DIRECTION, ""),
        get(fields, TAG_TRIGGER_TRAILING_DELTA_BIPS, ""),

        # Pegged order fields
        get(fields, TAG_PEG_OFFSET_VALUE, ""),
        get(fields, TAG_PEG_PRICE_TYPE, ""),
        get(fields, TAG_PEG_MOVE_TYPE, ""),
        get(fields, TAG_PEG_OFFSET_TYPE, ""),
        get(fields, TAG_PEGGED_PRICE, ""),

        # Fees
        fees,

        # Error info
        get(fields, TAG_ERROR_CODE, ""),
        get(fields, TAG_TEXT, ""),

        # Raw fields
        fields
    )
end

"""
    parse_misc_fees(fields::Dict{Int,String}) -> Vector{MiscFee}

Parse the NoMiscFees repeating group from raw FIX fields.
Note: This is a simplified parser that assumes fees appear sequentially.
"""
function parse_misc_fees(fields::Dict{Int,String})
    fees = MiscFee[]
    num_fees_str = get(fields, TAG_NO_MISC_FEES, "")
    if isempty(num_fees_str)
        return fees
    end

    num_fees = tryparse(Int, num_fees_str)
    if isnothing(num_fees) || num_fees == 0
        return fees
    end

    # For a single fee, the fields appear directly
    # For multiple fees, we'd need to parse the raw message more carefully
    # This handles the common case of 1 fee
    if num_fees >= 1
        push!(fees, MiscFee(
            get(fields, TAG_MISC_FEE_AMT, ""),
            get(fields, TAG_MISC_FEE_CURR, ""),
            get(fields, TAG_MISC_FEE_TYPE, "")
        ))
    end

    return fees
end

"""
    parse_order_cancel_reject(fields::Dict{Int,String})

Parse an OrderCancelReject (MsgType=9) message.
"""
function parse_order_cancel_reject(fields::Dict{Int,String})
    return OrderCancelRejectMsg(
        get(fields, TAG_CL_ORD_ID, ""),
        get(fields, TAG_ORIG_CL_ORD_ID, ""),
        get(fields, TAG_ORDER_ID, ""),
        get(fields, TAG_ORIG_CL_LIST_ID, ""),
        get(fields, TAG_LIST_ID, ""),
        get(fields, TAG_SYMBOL, ""),
        get(fields, TAG_CANCEL_RESTRICTIONS, ""),
        get(fields, TAG_CXL_REJ_RESPONSE_TO, ""),
        get(fields, TAG_ERROR_CODE, ""),
        get(fields, TAG_TEXT, ""),
        fields
    )
end

"""
    parse_list_status(msg::String) -> ListStatusMsg

Parse a ListStatus (MsgType=N) message from raw FIX message string.
This properly handles nested repeating groups by parsing the raw message.
"""
function parse_list_status(msg::String)
    # Split message into fields
    parts = split(msg, '\x01', keepempty=false)

    # Basic fields
    fields = Dict{Int,String}()
    symbol = ""
    list_id = ""
    cl_list_id = ""
    orig_cl_list_id = ""
    contingency_type = ""
    list_status_type = ""
    list_order_status = ""
    list_reject_reason = ""
    ord_rej_reason = ""
    transact_time = ""
    error_code = ""
    text = ""

    orders = ListStatusOrder[]
    current_order_symbol = ""
    current_order_id = ""
    current_cl_ord_id = ""
    current_trigger_instructions = ListTriggerInstruction[]

    in_orders_group = false
    in_trigger_group = false
    orders_count = 0
    orders_parsed = 0
    trigger_count = 0
    triggers_parsed = 0

    for part in parts
        eq_idx = findfirst('=', part)
        if isnothing(eq_idx)
            continue
        end

        tag_str = part[1:eq_idx-1]
        value = part[eq_idx+1:end]
        tag = tryparse(Int, tag_str)

        if isnothing(tag)
            continue
        end

        fields[tag] = value

        # Parse top-level fields
        if tag == TAG_SYMBOL && !in_orders_group
            symbol = value
        elseif tag == TAG_LIST_ID
            list_id = value
        elseif tag == TAG_CL_LIST_ID
            cl_list_id = value
        elseif tag == TAG_ORIG_CL_LIST_ID
            orig_cl_list_id = value
        elseif tag == TAG_CONTINGENCY_TYPE
            contingency_type = value
        elseif tag == TAG_LIST_STATUS_TYPE
            list_status_type = value
        elseif tag == TAG_LIST_ORDER_STATUS
            list_order_status = value
        elseif tag == TAG_LIST_REJECT_REASON
            list_reject_reason = value
        elseif tag == TAG_ORD_REJ_REASON
            ord_rej_reason = value
        elseif tag == TAG_TRANSACT_TIME
            transact_time = value
        elseif tag == TAG_ERROR_CODE
            error_code = value
        elseif tag == TAG_TEXT
            text = value
        elseif tag == TAG_NO_ORDERS
            orders_count = something(tryparse(Int, value), 0)
            in_orders_group = true
        elseif in_orders_group
            # Inside orders repeating group
            if tag == TAG_SYMBOL
                # Save previous order if exists
                if !isempty(current_order_id) && orders_parsed < orders_count
                    push!(orders, ListStatusOrder(
                        current_order_symbol,
                        current_order_id,
                        current_cl_ord_id,
                        copy(current_trigger_instructions)
                    ))
                    orders_parsed += 1
                    current_trigger_instructions = ListTriggerInstruction[]
                end
                current_order_symbol = value
            elseif tag == TAG_ORDER_ID
                current_order_id = value
            elseif tag == TAG_CL_ORD_ID
                current_cl_ord_id = value
            elseif tag == TAG_NO_LIST_TRIGGERING_INSTRUCTIONS
                trigger_count = something(tryparse(Int, value), 0)
                in_trigger_group = true
                triggers_parsed = 0
            elseif in_trigger_group
                # Inside trigger instructions repeating group
                if tag == TAG_LIST_TRIGGER_TYPE
                    # Start of new trigger instruction
                    if triggers_parsed < trigger_count
                        # We'll collect the fields and create the instruction
                        # when we have all three fields
                    end
                elseif tag == TAG_LIST_TRIGGER_TRIGGER_INDEX
                    # Continue collecting
                elseif tag == TAG_LIST_TRIGGER_ACTION
                    # Complete the trigger instruction
                    # Look back for the other fields
                    trigger_type = ""
                    trigger_index = ""
                    action = value

                    # Simple approach: assume fields are in order
                    push!(current_trigger_instructions, ListTriggerInstruction(
                        trigger_type,
                        trigger_index,
                        action
                    ))
                    triggers_parsed += 1

                    if triggers_parsed >= trigger_count
                        in_trigger_group = false
                    end
                end
            end
        end
    end

    # Save last order
    if in_orders_group && !isempty(current_order_id) && orders_parsed < orders_count
        push!(orders, ListStatusOrder(
            current_order_symbol,
            current_order_id,
            current_cl_ord_id,
            current_trigger_instructions
        ))
    end

    return ListStatusMsg(
        symbol,
        list_id,
        cl_list_id,
        orig_cl_list_id,
        contingency_type,
        list_status_type,
        list_order_status,
        list_reject_reason,
        ord_rej_reason,
        transact_time,
        error_code,
        text,
        orders,
        fields
    )
end

"""
    parse_order_amend_reject(fields::Dict{Int,String})

Parse an OrderAmendReject (MsgType=XAR) message.
"""
function parse_order_amend_reject(fields::Dict{Int,String})
    return OrderAmendRejectMsg(
        get(fields, TAG_CL_ORD_ID, ""),
        get(fields, TAG_ORIG_CL_ORD_ID, ""),
        get(fields, TAG_ORDER_ID, ""),
        get(fields, TAG_SYMBOL, ""),
        get(fields, TAG_ORDER_QTY, ""),
        get(fields, TAG_ERROR_CODE, ""),
        get(fields, TAG_TEXT, ""),
        fields
    )
end

"""
    parse_order_mass_cancel_report(fields::Dict{Int,String})

Parse an OrderMassCancelReport (MsgType=r) message.
"""
function parse_order_mass_cancel_report(fields::Dict{Int,String})
    return OrderMassCancelReportMsg(
        get(fields, TAG_SYMBOL, ""),
        get(fields, TAG_CL_ORD_ID, ""),
        get(fields, TAG_MASS_CANCEL_REQUEST_TYPE, ""),
        get(fields, TAG_MASS_CANCEL_RESPONSE, ""),
        get(fields, TAG_MASS_CANCEL_REJECT_REASON, ""),
        get(fields, TAG_TOTAL_AFFECTED_ORDERS, ""),
        get(fields, TAG_ERROR_CODE, ""),
        get(fields, TAG_TEXT, ""),
        fields
    )
end

"""
    parse_limit_response(msg::String) -> LimitResponseMsg

Parse a LimitResponse (MsgType=XLR) message from raw FIX message string.
This properly handles the NoLimitIndicators repeating group to extract all limit indicators.

# Example
```julia
msg = "8=FIX.4.4|9=225|35=XLR|..."  # with | replaced by SOH
response = parse_limit_response(msg)
for limit in response.limits
    println("Type: \$(limit.limit_type), Count: \$(limit.limit_count)/\$(limit.limit_max)")
end
```
"""
function parse_limit_response(msg::String)
    # Split message into fields
    parts = split(msg, '\x01', keepempty=false)

    # Basic fields
    fields = Dict{Int,String}()
    req_id = ""
    limits = LimitIndicator[]

    # Track repeating group state
    in_limits_group = false
    limits_count = 0
    limits_parsed = 0

    # Current limit indicator being built
    current_limit_type = ""
    current_limit_count = 0
    current_limit_max = 0
    current_limit_reset_interval = 0
    current_limit_reset_interval_resolution = ""

    for part in parts
        eq_idx = findfirst('=', part)
        if isnothing(eq_idx)
            continue
        end

        tag_str = part[1:eq_idx-1]
        value = part[eq_idx+1:end]
        tag = tryparse(Int, tag_str)

        if isnothing(tag)
            continue
        end

        fields[tag] = value

        # Parse fields
        if tag == TAG_REQ_ID
            req_id = value
        elseif tag == TAG_NO_LIMIT_INDICATORS
            limits_count = something(tryparse(Int, value), 0)
            in_limits_group = true
        elseif in_limits_group
            if tag == TAG_LIMIT_TYPE
                # Save previous limit indicator if exists
                if !isempty(current_limit_type) && limits_parsed < limits_count
                    push!(limits, LimitIndicator(
                        current_limit_type,
                        current_limit_count,
                        current_limit_max,
                        current_limit_reset_interval,
                        current_limit_reset_interval_resolution
                    ))
                    limits_parsed += 1
                end
                # Start new limit indicator
                current_limit_type = value
                current_limit_count = 0
                current_limit_max = 0
                current_limit_reset_interval = 0
                current_limit_reset_interval_resolution = ""
            elseif tag == TAG_LIMIT_COUNT
                current_limit_count = something(tryparse(Int, value), 0)
            elseif tag == TAG_LIMIT_MAX
                current_limit_max = something(tryparse(Int, value), 0)
            elseif tag == TAG_LIMIT_RESET_INTERVAL
                current_limit_reset_interval = something(tryparse(Int, value), 0)
            elseif tag == TAG_LIMIT_RESET_INTERVAL_RESOLUTION
                current_limit_reset_interval_resolution = value
            end
        end
    end

    # Save last limit indicator
    if in_limits_group && !isempty(current_limit_type) && limits_parsed < limits_count
        push!(limits, LimitIndicator(
            current_limit_type,
            current_limit_count,
            current_limit_max,
            current_limit_reset_interval,
            current_limit_reset_interval_resolution
        ))
    end

    return LimitResponseMsg(
        req_id,
        limits,
        fields
    )
end

"""
    parse_reject(fields::Dict{Int,String})

Parse a Reject (MsgType=3) message.
"""
function parse_reject(fields::Dict{Int,String})
    return RejectMsg(
        get(fields, TAG_REF_SEQ_NUM, ""),
        get(fields, TAG_REF_TAG_ID, ""),
        get(fields, TAG_REF_MSG_TYPE, ""),
        get(fields, TAG_SESSION_REJECT_REASON, ""),
        get(fields, TAG_ERROR_CODE, ""),
        get(fields, TAG_TEXT, ""),
        fields
    )
end

"""
    parse_news(fields::Dict{Int,String})

Parse a News (MsgType=B) message. Used for maintenance notifications.
"""
function parse_news(fields::Dict{Int,String})
    return NewsMsg(
        get(fields, TAG_HEADLINE, ""),
        get(fields, TAG_TEXT, ""),
        get(fields, TAG_URGENCY, ""),
        fields
    )
end

"""
    is_maintenance_news(news::NewsMsg)

Check if a News message indicates server maintenance.
"""
function is_maintenance_news(news::NewsMsg)
    headline_lower = lowercase(news.headline)
    text_lower = lowercase(news.text)
    return contains(headline_lower, "maintenance") ||
           contains(text_lower, "maintenance") ||
           contains(headline_lower, "disconnect") ||
           contains(text_lower, "reconnect")
end

"""
    parse_market_data_snapshot(msg::String) -> MarketDataSnapshotMsg

Parse a MarketDataSnapshot (MsgType=W) message from raw FIX message string.
This properly handles the NoMDEntries repeating group.

Sent by the server in response to MarketDataRequest, activating Book Ticker or Diff. Depth subscriptions.

# Example
```julia
response = parse_market_data_snapshot(msg)
println("Symbol: \$(response.symbol), Entries: \$(length(response.entries))")
for entry in response.entries
    println("  \$(entry.entry_type): \$(entry.price) x \$(entry.size)")
end
```
"""
function parse_market_data_snapshot(msg::String)
    parts = split(msg, '\x01', keepempty=false)

    fields = Dict{Int,String}()
    md_req_id = ""
    symbol = ""
    last_book_update_id = ""
    entries = MDEntry[]

    # Track repeating group state
    in_entries_group = false
    entries_count = 0
    entries_parsed = 0

    # Current entry being built
    current_entry_type = ""
    current_price = ""
    current_size = ""

    for part in parts
        eq_idx = findfirst('=', part)
        if isnothing(eq_idx)
            continue
        end

        tag_str = part[1:eq_idx-1]
        value = part[eq_idx+1:end]
        tag = tryparse(Int, tag_str)

        if isnothing(tag)
            continue
        end

        fields[tag] = value

        if tag == TAG_MD_REQ_ID
            md_req_id = value
        elseif tag == TAG_SYMBOL && !in_entries_group
            symbol = value
        elseif tag == TAG_LAST_BOOK_UPDATE_ID && !in_entries_group
            last_book_update_id = value
        elseif tag == TAG_NO_MD_ENTRIES
            entries_count = something(tryparse(Int, value), 0)
            in_entries_group = true
        elseif in_entries_group
            if tag == TAG_MD_ENTRY_TYPE
                # Save previous entry if exists
                if !isempty(current_entry_type) && entries_parsed < entries_count
                    push!(entries, MDEntry(
                        current_entry_type,
                        current_price,
                        current_size,
                        "",  # update_action - not in snapshot
                        symbol,  # symbol - from message level
                        "",  # transact_time - not in snapshot
                        "",  # trade_id - not in snapshot
                        "",  # aggressor_side - not in snapshot
                        "",  # first_book_update_id - not in snapshot
                        last_book_update_id
                    ))
                    entries_parsed += 1
                end
                # Start new entry
                current_entry_type = value
                current_price = ""
                current_size = ""
            elseif tag == TAG_MD_ENTRY_PX
                current_price = value
            elseif tag == TAG_MD_ENTRY_SIZE
                current_size = value
            end
        end
    end

    # Save last entry
    if in_entries_group && !isempty(current_entry_type) && entries_parsed < entries_count
        push!(entries, MDEntry(
            current_entry_type,
            current_price,
            current_size,
            "",
            symbol,
            "",
            "",
            "",
            "",
            last_book_update_id
        ))
    end

    return MarketDataSnapshotMsg(
        md_req_id,
        symbol,
        last_book_update_id,
        entries,
        fields
    )
end

"""
    parse_market_data_incremental(msg::String) -> MarketDataIncrementalMsg

Parse a MarketDataIncrementalRefresh (MsgType=X) message from raw FIX message string.
This properly handles the NoMDEntries repeating group with field inheritance.

Fields like Symbol, FirstBookUpdateID, and LastBookUpdateID can inherit from
the previous entry in the same message if not specified.

# Notes
- **DEPRECATED (2025-12-18)**: LastFragment field is deprecated and will always be true.
  Messages are no longer fragmented; instead, entries are reduced when the message would exceed limits.
  Code should not rely on `last_fragment` for message reassembly.

# Example
```julia
response = parse_market_data_incremental(msg)
for entry in response.entries
    action = entry.update_action == "0" ? "NEW" : entry.update_action == "1" ? "CHANGE" : "DELETE"
    println("[\$action] \$(entry.entry_type): \$(entry.price) x \$(entry.size)")
end
```
"""
function parse_market_data_incremental(msg::String)
    parts = split(msg, '\x01', keepempty=false)

    fields = Dict{Int,String}()
    md_req_id = ""
    last_fragment = false
    entries = MDEntry[]

    # Track repeating group state
    in_entries_group = false
    entries_count = 0
    entries_parsed = 0

    # Current entry being built
    current_update_action = ""
    current_entry_type = ""
    current_price = ""
    current_size = ""
    current_symbol = ""
    current_transact_time = ""
    current_trade_id = ""
    current_aggressor_side = ""
    current_first_book_update_id = ""
    current_last_book_update_id = ""

    # Previous entry values for inheritance
    prev_symbol = ""
    prev_first_book_update_id = ""
    prev_last_book_update_id = ""

    for part in parts
        eq_idx = findfirst('=', part)
        if isnothing(eq_idx)
            continue
        end

        tag_str = part[1:eq_idx-1]
        value = part[eq_idx+1:end]
        tag = tryparse(Int, tag_str)

        if isnothing(tag)
            continue
        end

        fields[tag] = value

        if tag == TAG_MD_REQ_ID
            md_req_id = value
        elseif tag == TAG_LAST_FRAGMENT
            last_fragment = value == "Y"
        elseif tag == TAG_NO_MD_ENTRIES
            entries_count = something(tryparse(Int, value), 0)
            in_entries_group = true
        elseif in_entries_group
            if tag == TAG_MD_UPDATE_ACTION
                # Save previous entry if exists
                if !isempty(current_update_action) && entries_parsed < entries_count
                    # Apply inheritance for missing fields
                    final_symbol = isempty(current_symbol) ? prev_symbol : current_symbol
                    final_first = isempty(current_first_book_update_id) ? prev_first_book_update_id : current_first_book_update_id
                    final_last = isempty(current_last_book_update_id) ? prev_last_book_update_id : current_last_book_update_id

                    push!(entries, MDEntry(
                        current_entry_type,
                        current_price,
                        current_size,
                        current_update_action,
                        final_symbol,
                        current_transact_time,
                        current_trade_id,
                        current_aggressor_side,
                        final_first,
                        final_last
                    ))
                    entries_parsed += 1

                    # Update previous values for next entry
                    prev_symbol = final_symbol
                    prev_first_book_update_id = final_first
                    prev_last_book_update_id = final_last
                end
                # Start new entry
                current_update_action = value
                current_entry_type = ""
                current_price = ""
                current_size = ""
                current_symbol = ""
                current_transact_time = ""
                current_trade_id = ""
                current_aggressor_side = ""
                current_first_book_update_id = ""
                current_last_book_update_id = ""
            elseif tag == TAG_MD_ENTRY_TYPE
                current_entry_type = value
            elseif tag == TAG_MD_ENTRY_PX
                current_price = value
            elseif tag == TAG_MD_ENTRY_SIZE
                current_size = value
            elseif tag == TAG_SYMBOL
                current_symbol = value
            elseif tag == TAG_TRANSACT_TIME
                current_transact_time = value
            elseif tag == TAG_TRADE_ID
                current_trade_id = value
            elseif tag == TAG_AGGRESSOR_SIDE
                current_aggressor_side = value
            elseif tag == TAG_FIRST_BOOK_UPDATE_ID
                current_first_book_update_id = value
            elseif tag == TAG_LAST_BOOK_UPDATE_ID
                current_last_book_update_id = value
            end
        end
    end

    # Save last entry
    if in_entries_group && !isempty(current_update_action) && entries_parsed < entries_count
        final_symbol = isempty(current_symbol) ? prev_symbol : current_symbol
        final_first = isempty(current_first_book_update_id) ? prev_first_book_update_id : current_first_book_update_id
        final_last = isempty(current_last_book_update_id) ? prev_last_book_update_id : current_last_book_update_id

        push!(entries, MDEntry(
            current_entry_type,
            current_price,
            current_size,
            current_update_action,
            final_symbol,
            current_transact_time,
            current_trade_id,
            current_aggressor_side,
            final_first,
            final_last
        ))
    end

    # Get first/last book update IDs from message level if present (for backward compat)
    msg_first_book_id = get(fields, TAG_FIRST_BOOK_UPDATE_ID, "")
    msg_last_book_id = get(fields, TAG_LAST_BOOK_UPDATE_ID, "")

    # Use entry-level IDs if message-level not present
    if isempty(msg_first_book_id) && !isempty(entries)
        msg_first_book_id = entries[1].first_book_update_id
    end
    if isempty(msg_last_book_id) && !isempty(entries)
        msg_last_book_id = entries[end].last_book_update_id
    end

    return MarketDataIncrementalMsg(
        md_req_id,
        last_fragment,
        msg_first_book_id,
        msg_last_book_id,
        entries,
        fields
    )
end

"""
    parse_market_data_reject(fields::Dict{Int,String})

Parse a MarketDataRequestReject (MsgType=Y) message.
"""
function parse_market_data_reject(fields::Dict{Int,String})
    return MarketDataRejectMsg(
        get(fields, TAG_MD_REQ_ID, ""),
        get(fields, TAG_MD_REQ_REJ_REASON, ""),
        get(fields, TAG_ERROR_CODE, ""),
        get(fields, TAG_TEXT, ""),
        fields
    )
end

"""
    parse_instrument_list(msg::String) -> InstrumentListMsg

Parse an InstrumentList (MsgType=y) message from raw FIX message string.
This properly handles the NoRelatedSym repeating group to extract all instruments.

# Example
```julia
msg = "8=FIX.4.4|9=218|35=y|..."  # with | replaced by SOH
response = parse_instrument_list(msg)
for inst in response.instruments
    println("\$(inst.symbol): min=\$(inst.min_trade_vol), max=\$(inst.max_trade_vol)")
end
```
"""
function parse_instrument_list(msg::String)
    # Split message into fields
    parts = split(msg, '\x01', keepempty=false)

    # Basic fields
    fields = Dict{Int,String}()
    instrument_req_id = ""
    instruments = InstrumentInfo[]

    # Track repeating group state
    in_symbols_group = false
    symbols_count = 0
    symbols_parsed = 0

    # Current instrument being built
    current_symbol = ""
    current_currency = ""
    current_min_trade_vol = ""
    current_max_trade_vol = ""
    current_min_qty_increment = ""
    current_market_min_trade_vol = ""
    current_market_max_trade_vol = ""
    current_market_min_qty_increment = ""
    current_start_price_range = ""
    current_end_price_range = ""
    current_min_price_increment = ""

    for part in parts
        eq_idx = findfirst('=', part)
        if isnothing(eq_idx)
            continue
        end

        tag_str = part[1:eq_idx-1]
        value = part[eq_idx+1:end]
        tag = tryparse(Int, tag_str)

        if isnothing(tag)
            continue
        end

        fields[tag] = value

        # Parse fields
        if tag == TAG_INSTRUMENT_REQ_ID
            instrument_req_id = value
        elseif tag == TAG_NO_RELATED_SYM
            symbols_count = something(tryparse(Int, value), 0)
            in_symbols_group = true
        elseif in_symbols_group
            if tag == TAG_SYMBOL
                # Save previous instrument if exists
                if !isempty(current_symbol) && symbols_parsed < symbols_count
                    push!(instruments, InstrumentInfo(
                        current_symbol,
                        current_currency,
                        current_min_trade_vol,
                        current_max_trade_vol,
                        current_min_qty_increment,
                        current_market_min_trade_vol,
                        current_market_max_trade_vol,
                        current_market_min_qty_increment,
                        current_start_price_range,
                        current_end_price_range,
                        current_min_price_increment
                    ))
                    symbols_parsed += 1
                end
                # Start new instrument
                current_symbol = value
                current_currency = ""
                current_min_trade_vol = ""
                current_max_trade_vol = ""
                current_min_qty_increment = ""
                current_market_min_trade_vol = ""
                current_market_max_trade_vol = ""
                current_market_min_qty_increment = ""
                current_start_price_range = ""
                current_end_price_range = ""
                current_min_price_increment = ""
            elseif tag == TAG_CURRENCY
                current_currency = value
            elseif tag == TAG_MIN_TRADE_VOL
                current_min_trade_vol = value
            elseif tag == TAG_MAX_TRADE_VOL
                current_max_trade_vol = value
            elseif tag == TAG_MIN_QTY_INCREMENT
                current_min_qty_increment = value
            elseif tag == TAG_MARKET_MIN_TRADE_VOL
                current_market_min_trade_vol = value
            elseif tag == TAG_MARKET_MAX_TRADE_VOL
                current_market_max_trade_vol = value
            elseif tag == TAG_MARKET_MIN_QTY_INCREMENT
                current_market_min_qty_increment = value
            elseif tag == TAG_START_PRICE_RANGE
                current_start_price_range = value
            elseif tag == TAG_END_PRICE_RANGE
                current_end_price_range = value
            elseif tag == TAG_MIN_PRICE_INCREMENT
                current_min_price_increment = value
            end
        end
    end

    # Save last instrument
    if in_symbols_group && !isempty(current_symbol) && symbols_parsed < symbols_count
        push!(instruments, InstrumentInfo(
            current_symbol,
            current_currency,
            current_min_trade_vol,
            current_max_trade_vol,
            current_min_qty_increment,
            current_market_min_trade_vol,
            current_market_max_trade_vol,
            current_market_min_qty_increment,
            current_start_price_range,
            current_end_price_range,
            current_min_price_increment
        ))
    end

    return InstrumentListMsg(
        instrument_req_id,
        instruments,
        fields
    )
end

"""
    process_message(session::FIXSession, msg::String)

Process a received FIX message and return appropriate typed struct.
Returns a tuple of (message_type_symbol, parsed_data).
"""
function process_message(session::FIXSession, msg::String)
    fields = parse_fix_message(msg)
    msg_type = get_msg_type(fields)

    if msg_type == MSG_HEARTBEAT
        return (:heartbeat, fields)
    elseif msg_type == MSG_TEST_REQUEST
        # Respond with Heartbeat
        test_req_id = get(fields, TAG_TEST_REQ_ID, "")
        heartbeat(session; test_req_id=test_req_id)
        return (:test_request, fields)
    elseif msg_type == MSG_REJECT
        return (:reject, parse_reject(fields))
    elseif msg_type == MSG_LOGON
        session.is_logged_in = true
        return (:logon, fields)
    elseif msg_type == MSG_LOGOUT
        session.is_logged_in = false
        return (:logout, fields)
    elseif msg_type == MSG_NEWS
        news = parse_news(fields)
        # Check for maintenance notification
        if is_maintenance_news(news)
            session.maintenance_warning = true
            if !isnothing(session.on_maintenance)
                session.on_maintenance(session, news)
            end
        end
        return (:news, news)
    elseif msg_type == MSG_EXECUTION_REPORT
        return (:execution_report, parse_execution_report(fields))
    elseif msg_type == MSG_ORDER_CANCEL_REJECT
        return (:order_cancel_reject, parse_order_cancel_reject(fields))
    elseif msg_type == MSG_LIST_STATUS
        return (:list_status, parse_list_status(msg))
    elseif msg_type == MSG_ORDER_MASS_CANCEL_REPORT
        return (:order_mass_cancel_report, parse_order_mass_cancel_report(fields))
    elseif msg_type == MSG_ORDER_AMEND_REJECT
        return (:order_amend_reject, parse_order_amend_reject(fields))
    elseif msg_type == MSG_LIMIT_RESPONSE
        return (:limit_response, parse_limit_response(msg))
    elseif msg_type == MSG_MARKET_DATA_SNAPSHOT
        return (:market_data_snapshot, parse_market_data_snapshot(msg))
    elseif msg_type == MSG_MARKET_DATA_INCREMENTAL
        return (:market_data_incremental, parse_market_data_incremental(msg))
    elseif msg_type == MSG_MARKET_DATA_REQUEST_REJECT
        return (:market_data_reject, parse_market_data_reject(fields))
    elseif msg_type == MSG_INSTRUMENT_LIST
        return (:instrument_list, parse_instrument_list(msg))
    else
        return (:unknown, fields)
    end
end

# =============================================================================
# Connection Lifecycle Management
# =============================================================================

"""
    start_monitor(session::FIXSession)

Start the background heartbeat/connection monitor.
This monitors the connection and:
- Sends heartbeats if no outgoing messages within HeartBtInt
- Sends TestRequest if no incoming messages within HeartBtInt
- Detects connection timeout if TestRequest response not received
- Processes incoming messages and calls on_message callback
"""
function start_monitor(session::FIXSession)
    if !isnothing(session.monitor_task) && !istaskdone(session.monitor_task)
        @warn "Monitor already running"
        return
    end

    session.should_stop[] = false

    session.monitor_task = @async begin
        try
            monitor_loop(session)
        catch e
            if !session.should_stop[]
                @error "Monitor task error" exception = (e, catch_backtrace())
                if !isnothing(session.on_disconnect)
                    session.on_disconnect(session, e)
                end
            end
        end
    end

    println("Connection monitor started (HeartBtInt=$(session.heartbeat_interval)s)")
end

"""
    stop_monitor(session::FIXSession)

Stop the background heartbeat/connection monitor.
"""
function stop_monitor(session::FIXSession)
    session.should_stop[] = true

    if !isnothing(session.monitor_task) && !istaskdone(session.monitor_task)
        # Give it a moment to stop gracefully
        for _ in 1:10
            if istaskdone(session.monitor_task)
                break
            end
            sleep(0.1)
        end
    end

    session.monitor_task = nothing
end

"""
    monitor_loop(session::FIXSession)

Internal monitor loop that handles heartbeat/connection lifecycle.
"""
function monitor_loop(session::FIXSession)
    check_interval = 1.0  # Check every second

    while !session.should_stop[] && session.is_logged_in
        try
            current_time = now(Dates.UTC)
            heartbeat_ms = session.heartbeat_interval * 1000

            # Check if socket is still open
            if isnothing(session.socket) || !isopen(session.socket)
                @warn "Socket closed unexpectedly"
                if !isnothing(session.on_disconnect)
                    session.on_disconnect(session, "Socket closed")
                end
                break
            end

            # Receive and process any pending messages
            messages = receive_message(session)
            for msg in messages
                result = process_message(session, msg)

                # Clear pending test request if we got a heartbeat response
                if result[1] == :heartbeat && !isempty(session.pending_test_req_id)
                    fields = result[2]
                    if isa(fields, Dict) && get(fields, TAG_TEST_REQ_ID, "") == session.pending_test_req_id
                        session.pending_test_req_id = ""
                        session.test_req_sent_time = nothing
                    end
                end

                # Call message callback if set
                if !isnothing(session.on_message)
                    session.on_message(session, result)
                end
            end

            # Calculate time since last sent/received
            ms_since_sent = Dates.value(current_time - session.last_sent_time)
            ms_since_recv = Dates.value(current_time - session.last_recv_time)

            # Check for pending TestRequest timeout
            if !isnothing(session.test_req_sent_time)
                ms_since_test_req = Dates.value(current_time - session.test_req_sent_time)
                if ms_since_test_req > heartbeat_ms
                    # TestRequest timeout - connection is dead
                    @warn "TestRequest timeout - connection appears dead"
                    if !isnothing(session.on_disconnect)
                        session.on_disconnect(session, "TestRequest timeout")
                    end
                    break
                end
            end

            # Send TestRequest if no incoming messages for HeartBtInt
            if ms_since_recv > heartbeat_ms && isempty(session.pending_test_req_id)
                session.pending_test_req_id = test_request(session)
                session.test_req_sent_time = current_time
                @debug "Sent TestRequest (no messages for $(ms_since_recv)ms)"
            end

            # Send Heartbeat if no outgoing messages for HeartBtInt
            # (Only if we haven't just sent a TestRequest)
            if ms_since_sent > heartbeat_ms && isempty(session.pending_test_req_id)
                heartbeat(session)
                @debug "Sent Heartbeat (no outgoing for $(ms_since_sent)ms)"
            end

        catch e
            if !session.should_stop[]
                @error "Error in monitor loop" exception = (e, catch_backtrace())
            end
        end

        sleep(check_interval)
    end
end

"""
    reconnect(session::FIXSession; heartbeat_interval::Int=30)

Close the current session and establish a new one.
This should be called when maintenance is detected or connection is lost.
"""
function reconnect(session::FIXSession; heartbeat_interval::Int=session.heartbeat_interval)
    # Stop monitor and close existing connection
    stop_monitor(session)

    if session.is_logged_in
        try
            logout(session)
            sleep(1)
        catch
            # Ignore logout errors
        end
    end

    close_fix(session)

    # Reset sequence number for new session
    session.seq_num = 1

    # Wait a moment before reconnecting
    sleep(2)

    # Establish new connection
    connect_fix(session)
    logon(session; heartbeat_interval=heartbeat_interval)

    # Wait for logon response
    sleep(2)
    messages = receive_message(session)
    for msg in messages
        process_message(session, msg)
    end

    if session.is_logged_in
        println("Reconnected successfully")
        start_monitor(session)
        return true
    else
        @error "Reconnection failed"
        return false
    end
end

end # module