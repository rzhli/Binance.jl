module Binance
# Include all submodule files
include("Config.jl")
include("Errors.jl")
include("Types.jl")
include("Filters.jl")
include("Signature.jl")
include("RateLimiter.jl")
include("RESTAPI.jl")
include("MarketDataStreams.jl")
include("SBEMarketDataStreams.jl")
include("Account.jl")
include("Convert.jl")
include("Events.jl")
include("WebSocketAPI.jl")
include("OrderBookManager.jl")

# Import from submodules
using .Config
using .Errors
using .Types
using .Filters
using .RESTAPI
using .MarketDataStreams
using .SBEMarketDataStreams
using .WebSocketAPI
using .RateLimiter
using .Account
using .Convert
using .Signature
using .Events
using .OrderBookManagers

# Export client types and configuration
export RESTClient, MarketDataStreamClient, SBEStreamClient, WebSocketClient, BinanceConfig, BinanceRateLimit

# Export exception types
export BinanceException, BinanceError, MalformedRequestError, UnauthorizedError,
    WAFViolationError, CancelReplacePartialSuccess, RateLimitError,
    IPAutoBannedError, BinanceServerError

# Export data types
export ExchangeInfo, RateLimit, SymbolInfo, Order, Trade, Kline, Ticker24hr
export DecimalPrice, to_decimal_string

# Export Event types
export ExecutionReport, OutboundAccountPosition, BalanceUpdate, ListStatus

# Export RESTAPI functions
export get_server_time, get_exchange_info, ping
export get_symbol_ticker, get_orderbook, get_recent_trades, get_historical_trades
export place_order, test_order, cancel_order, cancel_all_orders, cancel_replace_order, amend_order
export get_open_orders, get_order, get_all_orders, get_my_trades
export place_oco_order, place_oto_order, place_otoco_order, cancel_order_list
export place_sor_order, test_sor_order, get_order_list, get_all_order_lists, get_open_order_lists
export get_agg_trades, get_klines, get_ui_klines, get_avg_price, get_trading_day_ticker, get_ticker

# Export MarketDataStreams functions
export subscribe, subscribe_ticker
export subscribe_depth, subscribe_kline, subscribe_trade, subscribe_agg_trade
export subscribe_user_data, unsubscribe, close_all_connections, list_active_streams
export subscribe_mini_ticker, subscribe_all_tickers, subscribe_all_mini_tickers
export subscribe_book_ticker, subscribe_all_book_tickers, subscribe_diff_depth
export subscribe_rolling_ticker, subscribe_combined, subscribe_avg_price

# Export SBEMarketDataStreams functions
export sbe_subscribe, sbe_unsubscribe, sbe_subscribe_trade, sbe_unsubscribe_trade
export sbe_subscribe_best_bid_ask, sbe_unsubscribe_best_bid_ask, sbe_subscribe_combined
export sbe_subscribe_depth, sbe_unsubscribe_depth, sbe_subscribe_depth20, sbe_unsubscribe_depth20
export sbe_close_all, sbe_list_streams, connect_sbe!

# Export SBE data types
export TradeEvent, BestBidAskEvent, DepthSnapshotEvent, DepthDiffEvent

# Export WebSocket API functions - Authentication
export connect!, session_logon, session_status, exchangeInfo, session_logout, disconnect!

# Export WebSocket API functions - Market Data
export depth, trades_recent, trades_historical, trades_aggregate
export klines, ui_klines, avg_price, ticker_24hr, ticker_trading_day
export ticker, ticker_price, ticker_book

# Export WebSocket API functions - Trading
export test_order, cancel_replace_order, amend_order, cancel_all_orders

# Export WebSocket API functions - Order Lists
export place_oco_order, place_oto_order, place_otoco_order, cancel_order_list

# Export WebSocket API functions - SOR
export place_sor_order, test_sor_order

# Export WebSocket API functions - Account
export account_status, account_rate_limits_orders, orders_open, orders_all, my_trades
export open_orders_status, all_orders, order_list_status, open_order_lists_status
export all_order_lists, my_prevented_matches, my_allocations, account_commission
export order_amendments

# Export WebSocket API functions - User Data Stream
export user_data_stream_start, user_data_stream_ping, user_data_stream_stop, on_event
export userdata_stream_subscribe, userdata_stream_unsubscribe, session_subscriptions
export userdata_stream_subscribe_signature

# Export Account functions
export get_api_key_permission, get_account_info, get_deposit_history, get_deposit_address
export withdraw, get_asset_detail, get_trade_fee, dust_transfer, get_dust_log
export get_account_status, get_api_trading_status, get_withdraw_history

# Export Convert functions
export convert_exchange_info, convert_asset_info, convert_get_quote, convert_accept_quote
export convert_order_status, convert_trade_flow, convert_limit_place_order
export convert_limit_cancel_order, convert_limit_query_open_orders

# Export Signature functions
export HmacSigner, Ed25519Signer

# Export OrderBookManager types and functions
export OrderBookManager, PriceQuantity, OrderBookSnapshot
export start!, stop!, is_ready
export get_best_bid, get_best_ask, get_spread, get_mid_price
export get_bids, get_asks, get_orderbook_snapshot
export calculate_vwap, calculate_depth_imbalance

function __init__()
    ENV["DATAFRAMES_FLOAT_FORMAT"] = "%.0f"
end

end # module Binance
