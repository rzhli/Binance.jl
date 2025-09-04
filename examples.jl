using Binance

# =================================
#           RESTAPI MODULE EXAMPLES
# =================================

# REST API: Test server connectivity
function rest_ping_test()
    println("=== RESTAPI: Ping Test ===")
    client = RESTClient()
    ping_result = ping(client)
    println("Ping successful: $ping_result")
end

# REST API: Get server time
function rest_server_time_test()
    println("\n=== RESTAPI: Server Time ===")
    client = RESTClient()
    server_time = get_server_time(client)
    println("Server time: $(server_time.serverTime)")
end

# REST API: Get exchange information
function rest_exchange_info_test()
    println("\n=== RESTAPI: Exchange Info ===")
    client = RESTClient()
    exchange_info = get_exchange_info(client)
    println("Exchange supports $(length(exchange_info.symbols)) trading symbols")
end

# REST API: Get ticker price
function rest_ticker_price_test()
    println("\n=== RESTAPI: Symbol Ticker ===")
    client = RESTClient()
    ticker = get_symbol_ticker(client; symbol="BTCUSDT")
    println("BTCUSDT price: $(ticker.lastPrice) USD")
end

# REST API: Get order book
function rest_orderbook_test()
    println("\n=== RESTAPI: Order Book ===")
    client = RESTClient()
    orderbook = get_orderbook(client, "BTCUSDT"; limit=5)
    println("BTCUSDT orderbook: $(length(orderbook.bids)) bids, $(length(orderbook.asks)) asks")
    println("Best bid: $(orderbook.bids[1])")
    println("Best ask: $(orderbook.asks[1])")
end

# REST API: Get recent trades
function rest_recent_trades_test()
    println("\n=== RESTAPI: Recent Trades ===")
    client = RESTClient()
    trades = get_recent_trades(client, "BTCUSDT"; limit=3)
    println("Recent BTCUSDT trades: $(length(trades))")
    for trade in trades
        println("Trade ID $(trade.tradeId): $(trade.quantity) @ $(trade.price)")
    end
end

# REST API: Get historical trades
function rest_historical_trades_test()
    println("\n=== RESTAPI: Historical Trades ===")
    client = RESTClient()
    trades = get_historical_trades(client, "BTCUSDT"; limit=3)
    println("Historical BTCUSDT trades: $(length(trades))")
end

# REST API: Get Klines (candlestick data)
function rest_klines_test()
    println("\n=== RESTAPI: Klines ===")
    client = RESTClient()
    klines = get_klines(client, "BTCUSDT", "1h"; limit=5)
    println("BTCUSDT 1h klines: $(length(klines))")
end

# REST API: Get average price
function rest_avg_price_test()
    println("\n=== RESTAPI: Average Price ===")
    client = RESTClient()
    avg_price = get_avg_price(client, "BTCUSDT")
    println("BTCUSDT average price: $(avg_price.price)")
end

# REST API: Get 24hr ticker
function rest_ticker_24hr_test()
    println("\n=== RESTAPI: 24hr Ticker ===")
    client = RESTClient()
    ticker = get_ticker_24hr(client; symbol="BTCUSDT")
    println("BTCUSDT 24h: Change $(ticker.priceChangePercent)%")
end

# =================================
#           ACCOUNT MODULE EXAMPLES
# =================================

# Account: Get account information
function account_info_test()
    println("\n=== Account: Account Info ===")
    client = RESTClient("config_example.toml")
    account = get_account_info(client)
    println("Account type: $(account.accountType)")
    println("Can trade: $(account.canTrade)")
    println("Account balances: $(length(account.balances))")
    for balance in account.balances
        free = parse(Float64, balance.free)
        if free > 0.0001
            println("  $(balance.asset): Free=$(free), Locked=$(balance.locked)")
        end
    end
end

# Account: Get open orders
function account_open_orders_test()
    println("\n=== Account: Open Orders ===")
    client = RESTClient("config_example.toml")
    open_orders = get_open_orders(client)
    println("Open orders: $(length(open_orders))")
end

# Account: Get my trades
function account_my_trades_test()
    println("\n=== Account: My Trades ===")
    client = RESTClient("config_example.toml")
    trades = get_my_trades(client, "BTCUSDT"; limit=5)
    println("My BTCUSDT trades: $(length(trades))")
end

# Account: Get API key permissions
function account_api_permissions_test()
    println("\n=== Account: API Key Permissions ===")
    client = RESTClient("config_example.toml")
    permissions = get_api_key_permission(client)
    println("API Key permissions: $(permissions)")
end

# Account: Get account status
function account_status_test()
    println("\n=== Account: Account Status ===")
    client = RESTClient("config_example.toml")
    status = get_account_status(client)
    println("Account status: $status")
end

# =================================
#        MARKETDATASTREAM MODULE EXAMPLES
# =================================

# MarketDataStreams: Subscribe to ticker
function marketstreams_ticker_test()
    println("\n=== MarketDataStreams: Ticker Subscription ===")

    global ticker_count = 0
    function on_ticker(ticker)
        global ticker_count
        ticker_count += 1
        if ticker_count <= 5
            println("Ticker update #$ticker_count: $(ticker.symbol) @ $(ticker.lastPrice)")
        end
    end

    stream_client = MarketDataStreamClient()
    stream_id = subscribe_ticker(stream_client, "BTCUSDT", on_ticker)
    println("Subscribed to BTCUSDT ticker: Stream ID $stream_id")

    sleep(10)

    unsubscribe(stream_client, stream_id)
    close_all_connections(stream_client)
    println("Ticker subscription closed")
end

# MarketDataStreams: Subscribe to depth
function marketstreams_depth_test()
    println("\n=== MarketDataStreams: Depth Subscription ===")

    global depth_count = 0
    function on_depth(depth)
        global depth_count
        depth_count += 1
        if depth_count <= 3
            println("Depth update #$depth_count: $(depth.s) - $(length(depth.b)) bids, $(length(depth.a)) asks")
        end
    end

    stream_client = MarketDataStreamClient()
    stream_id = subscribe_depth(stream_client, "BTCUSDT", on_depth; levels=5)
    println("Subscribed to BTCUSDT depth: Stream ID $stream_id")

    sleep(10)

    unsubscribe(stream_client, stream_id)
    close_all_connections(stream_client)
    println("Depth subscription closed")
end

# MarketDataStreams: Subscribe to trade
function marketstreams_trade_test()
    println("\n=== MarketDataStreams: Trade Subscription ===")

    global trade_count = 0
    function on_trade(trade)
        global trade_count
        trade_count += 1
        if trade_count <= 3
            println("Trade #$trade_count: $(trade.symbol) - $(trade.quantity) @ $(trade.price)")
        end
    end

    stream_client = MarketDataStreamClient()
    stream_id = subscribe_trade(stream_client, "BTCUSDT", on_trade)
    println("Subscribed to BTCUSDT trades: Stream ID $stream_id")

    sleep(10)

    unsubscribe(stream_client, stream_id)
    close_all_connections(stream_client)
    println("Trade subscription closed")
end

# MarketDataStreams: Subscribe to multiple symbols
function marketstreams_multi_symbol_test()
    println("\n=== MarketDataStreams: Multiple Symbol Subscription ===")

    symbols = ["BTCUSDT", "ETHUSDT", "BNBUSDT"]
    stream_ids = []

    function on_multi_ticker(ticker)
        println("Multi-ticker: $(ticker.symbol) @ $(ticker.lastPrice)")
    end

    stream_client = MarketDataStreamClient()

    for symbol in symbols
        id = subscribe_ticker(stream_client, symbol, on_multi_ticker)
        push!(stream_ids, id)
        println("Subscribed to $symbol: ID $id")
    end

    active = list_active_streams(stream_client)
    println("Active streams: $(length(active))")

    sleep(10)

    for id in stream_ids
        unsubscribe(stream_client, id)
    end
    close_all_connections(stream_client)
    println("Multi-symbol subscription closed")
end

# =================================
#          WEBSOCKETAPI MODULE EXAMPLES
# =================================

# WebSocketAPI: Session management
function websocketapi_session_test()
    println("\n=== WebSocketAPI: Session Management ===")
    ws_client = WebSocketClient("config_example.toml")
    connect!(ws_client)
    session_logon(ws_client)
    println("WebSocket API session established")

    status = session_status(ws_client)
    println("Session status: $status")

    session_logout(ws_client)
    disconnect!(ws_client)
    println("WebSocket API session closed")
end

# WebSocketAPI: Market data
function websocketapi_market_data_test()
    println("\n=== WebSocketAPI: Market Data ===")
    ws_client = WebSocketClient("config_example.toml")
    connect!(ws_client)
    session_logon(ws_client)

    orderbook = depth(ws_client, "BTCUSDT"; limit=5)
    println("WebSocket API orderbook: $(length(orderbook.bids)) bids, $(length(orderbook.asks)) asks")

    trades = trades_recent(ws_client, "BTCUSDT"; limit=3)
    println("WebSocket API recent trades: $(length(trades))")

    avg_price = avg_price(ws_client, "BTCUSDT")
    println("WebSocket API avg price: $(avg_price.price)")

    session_logout(ws_client)
    disconnect!(ws_client)
end

# WebSocketAPI: Account queries
function websocketapi_account_test()
    println("\n=== WebSocketAPI: Account Queries ===")
    ws_client = WebSocketClient("config_example.toml")
    connect!(ws_client)
    session_logon(ws_client)

    account = account_status(ws_client)
    println("WebSocket API account type: $(account.accountType)")

    open_orders = orders_open(ws_client)
    println("WebSocket API open orders: $(length(open_orders))")

    session_logout(ws_client)
    disconnect!(ws_client)
end

# WebSocketAPI: User data streams
function websocketapi_user_data_test()
    println("\n=== WebSocketAPI: User Data Streams ===")
    ws_client = WebSocketClient("config_example.toml")
    connect!(ws_client)
    session_logon(ws_client)

    function on_execution_report(event)
        println("Execution report: $(event.e) - $(event.s)")
    end

    on_event(ws_client, "executionReport", on_execution_report)
    userdata_stream_subscribe(ws_client)
    println("Subscribed to user data streams")

    session_logout(ws_client)
    disconnect!(ws_client)
end

# =================================
# TRADING EXAMPLES (COMMENTED FOR SAFETY)
# =================================

# REST API: Place order (commented for safety)
function rest_place_order_statement()
    println("\n=== REST API: Place Order Statement ===")
    println("# client = RESTClient(\"config_example.toml\")")
    println("# order = place_order(client, \"BTCUSDT\", \"BUY\", \"LIMIT\";")
    println("#                     quantity=\"0.001\", price=\"30000\", timeInForce=\"GTC\")")
    println("# println(\"Order ID: \", order.orderId)")
    println("Place order code shown but NOT executed for safety")
end

# WebSocketAPI: Place order (commented for safety)
function websocketapi_place_order_statement()
    println("\n=== WebSocket API: Place Order Statement ===")
    println("# ws_client = WebSocketClient(\"config_example.toml\")")
    println("# connect!(ws_client)")
    println("# session_logon(ws_client)")
    println("# order = place_order(ws_client, \"BTCUSDT\", \"BUY\", \"LIMIT\";")
    println("#                     quantity=\"0.001\", price=\"30000\", timeInForce=\"GTC\")")
    println("# println(\"Order ID: \", order.orderId)")
    println("# session_logout(ws_client)")
    println("# disconnect!(ws_client)")
    println("Place order code shown but NOT executed for safety")
end

println("=== Binance.jl SDK Module Examples ===")
println("Each function can be called individually for testing:")
println("\nRESTAPI Module Examples:")
println("  rest_ping_test()")
println("  rest_server_time_test()")
println("  rest_exchange_info_test()")
println("  rest_ticker_price_test()")
println("  rest_orderbook_test()")
println("  rest_recent_trades_test()")
println("  rest_historical_trades_test()")
println("  rest_klines_test()")
println("  rest_avg_price_test()")
println("  rest_ticker_24hr_test()")
println("\nAccount Module Examples:")
println("  account_info_test()")
println("  account_open_orders_test()")
println("  account_my_trades_test()")
println("  account_api_permissions_test()")
println("  account_status_test()")
println("\nMarketDataStream Module Examples:")
println("  marketstreams_ticker_test()")
println("  marketstreams_depth_test()")
println("  marketstreams_trade_test()")
println("  marketstreams_multi_symbol_test()")
println("\nWebSocketAPI Module Examples:")
println("  websocketapi_session_test()")
println("  websocketapi_market_data_test()")
println("  websocketapi_account_test()")
println("  websocketapi_user_data_test()")
println("\nTrading Examples (Commented for Safety):")
println("  rest_place_order_statement()")
println("  websocketapi_place_order_statement()")

