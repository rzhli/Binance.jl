"""
BinanceFIX.jl - Binance FIX Protocol SDK

This package provides FIX 4.4 protocol support for Binance trading.
It depends on the main Binance.jl package for configuration and signature utilities.

## Session Types
- **OrderEntry**: Order placement, cancellation, and execution reports (port 9000)
- **DropCopy**: Read-only execution reports (port 9000)
- **MarketData**: Market data streams via FIX (port 9000)

## FIX SBE Support
- Port 9001: FIX request → FIX SBE response
- Port 9002: FIX SBE request → FIX SBE response

## Usage

```julia
using Binance
using BinanceFIX

# Load config
config = Binance.load_config("config.toml")

# Create FIX session
session = FIXSession(config, "SENDER"; session_type=OrderEntry)

# Connect and logon
connect_fix(session)
logon(session)

# Place order
cl_ord_id = new_order_single(session, "BTCUSDT", SIDE_BUY;
    quantity=0.001, price=50000.0, order_type=ORD_TYPE_LIMIT)

# Start connection monitor
start_monitor(session)

# Cleanup
logout(session)
close_fix(session)
```
"""
module BinanceFIX

# Include submodules
include("FIXConstants.jl")
include("FIXSBEDecoder.jl")
include("FIXAPI.jl")

# Import from submodules
using .FIXConstants
using .FIXSBEDecoder
using .FIXAPI

# =============================================================================
# Re-export FIXConstants (commonly used)
# =============================================================================

# Side Values
export SIDE_BUY, SIDE_SELL

# Order Type Values
export ORD_TYPE_MARKET, ORD_TYPE_LIMIT, ORD_TYPE_STOP, ORD_TYPE_STOP_LIMIT, ORD_TYPE_PEGGED

# Time In Force Values
export TIF_GTC, TIF_IOC, TIF_FOK

# Exec Type Values
export EXEC_TYPE_NEW, EXEC_TYPE_CANCELED, EXEC_TYPE_REPLACED,
    EXEC_TYPE_REJECTED, EXEC_TYPE_TRADE, EXEC_TYPE_EXPIRED

# Order Status Values
export ORD_STATUS_NEW, ORD_STATUS_PARTIALLY_FILLED, ORD_STATUS_FILLED,
    ORD_STATUS_CANCELED, ORD_STATUS_PENDING_CANCEL, ORD_STATUS_REJECTED,
    ORD_STATUS_PENDING_NEW, ORD_STATUS_EXPIRED

# Contingency Type Values
export CONTINGENCY_OCO, CONTINGENCY_OTO

# Self Trade Prevention Values
export STP_NONE, STP_EXPIRE_TAKER, STP_EXPIRE_MAKER, STP_EXPIRE_BOTH, STP_DECREMENT, STP_TRANSFER

# Message Handling Values
export MSG_HANDLING_UNORDERED, MSG_HANDLING_SEQUENTIAL

# Response Mode Values
export RESPONSE_MODE_EVERYTHING, RESPONSE_MODE_ONLY_ACKS

# Trigger Direction Values
export TRIGGER_UP, TRIGGER_DOWN

# ExecInst Values
export EXEC_INST_PARTICIPATE_DONT_INITIATE

# Market Data Entry Types
export MD_ENTRY_BID, MD_ENTRY_OFFER, MD_ENTRY_TRADE

# Market Data Subscription Types
export MD_SUBSCRIBE, MD_UNSUBSCRIBE

# =============================================================================
# Re-export FIXAPI types and functions
# =============================================================================

# Session types
export FIXSession, FIXSessionType, OrderEntry, DropCopy, MarketData

# Connection management
export connect_fix, logon, logout, close_fix
export heartbeat, test_request
export start_monitor, stop_monitor, reconnect

# Order Entry functions
export new_order_single, order_cancel_request, order_amend_keep_priority
export order_mass_cancel_request, limit_query
export new_order_list, order_cancel_and_new_order

# Order List helpers
export create_oco_sell, create_oco_buy, create_oto
export create_otoco_sell, create_otoco_buy
export create_opo_sell, create_opo_buy, create_opoco_sell, create_opoco_buy

# Market Data functions
export market_data_request, instrument_list_request
export subscribe_book_ticker, subscribe_depth_stream, subscribe_trade_stream
export unsubscribe_market_data

# Message processing
export receive_message, parse_fix_message, process_message, get_msg_type
export parse_list_status, parse_limit_response
export parse_market_data_snapshot, parse_market_data_incremental
export parse_instrument_list

# Message types (structs)
export ExecutionReportMsg, ListStatusMsg, LimitResponseMsg, RejectMsg, MiscFee
export OrderCancelRejectMsg, OrderMassCancelReportMsg, OrderAmendRejectMsg, LimitIndicator
export ListTriggerInstruction, ListStatusOrder
export MarketDataSnapshotMsg, MarketDataIncrementalMsg, MarketDataRejectMsg
export InstrumentListMsg, InstrumentInfo, MDEntry
export NewsMsg, is_maintenance_news

# Session limits
export SESSION_LIMITS, get_session_limits

# Error handling
export is_error, get_error_info

# Validation helpers
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
# Re-export FIXSBEDecoder types and functions
# =============================================================================

# SBE Constants
export SBE_SCHEMA_ID_FIX, SBE_SCHEMA_VERSION_FIX, SBE_ENCODING_TYPE_LE
export SBE_SOFH_SIZE, SBE_MESSAGE_HEADER_SIZE
export SBE_INT64_NULL, SBE_UINT64_NULL

# SBE Template IDs - Admin
export SBE_TEMPLATE_LOGON, SBE_TEMPLATE_LOGON_ACK, SBE_TEMPLATE_LOGOUT
export SBE_TEMPLATE_HEARTBEAT, SBE_TEMPLATE_TEST_REQUEST
export SBE_TEMPLATE_REJECT, SBE_TEMPLATE_NEWS

# SBE Template IDs - Order Entry
export SBE_TEMPLATE_NEW_ORDER_SINGLE, SBE_TEMPLATE_EXECUTION_REPORT
export SBE_TEMPLATE_EXECUTION_REPORT_ACK, SBE_TEMPLATE_ORDER_CANCEL_REQUEST
export SBE_TEMPLATE_ORDER_CANCEL_REJECT, SBE_TEMPLATE_ORDER_CANCEL_REQUEST_AND_NEW
export SBE_TEMPLATE_NEW_ORDER_LIST, SBE_TEMPLATE_LIST_STATUS
export SBE_TEMPLATE_ORDER_AMEND_KEEP_PRIORITY, SBE_TEMPLATE_ORDER_AMEND_REJECT
export SBE_TEMPLATE_LIMIT_QUERY, SBE_TEMPLATE_LIMIT_RESPONSE

# SBE Template IDs - Market Data
export SBE_TEMPLATE_MARKET_DATA_REQUEST, SBE_TEMPLATE_MARKET_DATA_REQUEST_REJECT
export SBE_TEMPLATE_MARKET_DATA_SNAPSHOT, SBE_TEMPLATE_MARKET_DATA_INCREMENTAL_TRADE
export SBE_TEMPLATE_MARKET_DATA_INCREMENTAL_BOOK_TICKER, SBE_TEMPLATE_MARKET_DATA_INCREMENTAL_DEPTH
export SBE_TEMPLATE_INSTRUMENT_LIST_REQUEST, SBE_TEMPLATE_INSTRUMENT_LIST

# SBE Decoder types
export SOFHeader, FIXSBEMessageHeader, FIXSBEMessage

# SBE Decoder functions
export decode_sofh, decode_message_header, decode_fix_sbe_message
export has_complete_message, extract_message
export mantissa_to_float

end # module BinanceFIX
