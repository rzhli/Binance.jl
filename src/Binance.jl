module Binance
# Include all submodule files
include("Config.jl")
include("Types.jl")
include("Filters.jl")
include("Signature.jl")
include("RateLimiter.jl")
include("RESTAPI.jl")
include("MarketDataStreams.jl")
include("Account.jl")
include("WebSocketAPI.jl")

# Import from submodules
using .Config
using .Types
using .Filters
using .RESTAPI
using .MarketDataStreams
using .WebSocketAPI
using .RateLimiter
using .Account
using .Signature

# Export client types and configuration
export RESTClient, MarketDataStreamClient, WebSocketClient, BinanceConfig, BinanceRateLimit

# Export data types
export ExchangeInfo, RateLimit, SymbolInfo, Order, Trade, Kline, Ticker24hr

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

# Export WebSocket API functions - Authentication
export connect!, session_logon, session_status, session_logout, disconnect!

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

# Export Signature functions
export HmacSigner, Ed25519Signer

function __init__()
    ENV["DATAFRAMES_FLOAT_FORMAT"] = "%.0f"
end

end # module Binance
