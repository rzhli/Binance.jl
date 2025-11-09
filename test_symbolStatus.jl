using Binance

# This script demonstrates the new symbolStatus parameter functionality
# added to the Binance SDK as per the 2025-10-28 changelog

println("=" ^ 80)
println("Testing symbolStatus parameter - REST API")
println("=" ^ 80)

# Initialize REST client
rest_client = RESTClient("config.toml")

# Test 1: Get orderbook with symbolStatus (single symbol)
println("\n1. Testing get_orderbook with symbolStatus='TRADING'")
try
    orderbook = get_orderbook(rest_client, "BTCUSDT"; limit=5, symbolStatus="TRADING")
    println("✓ Successfully retrieved orderbook for BTCUSDT with TRADING status")
    println("  Bids: $(length(orderbook[:bids])), Asks: $(length(orderbook[:asks]))")
catch e
    println("✗ Error: $e")
end

# Test 2: Get symbol ticker with symbolStatus (multiple symbols)
println("\n2. Testing get_symbol_ticker with symbolStatus='TRADING'")
try
    tickers = get_symbol_ticker(rest_client; symbols=["BTCUSDT", "ETHUSDT"], symbolStatus="TRADING")
    println("✓ Successfully retrieved $(length(tickers)) ticker(s) with TRADING status")
    for ticker in tickers
        println("  $(ticker[:symbol]): $(ticker[:price])")
    end
catch e
    println("✗ Error: $e")
end

# Test 3: Get 24hr ticker with symbolStatus
println("\n3. Testing get_ticker_24hr with symbolStatus='TRADING'")
try
    ticker_24hr = get_ticker_24hr(rest_client; symbol="BTCUSDT", symbolStatus="TRADING")
    println("✓ Successfully retrieved 24hr ticker for BTCUSDT with TRADING status")
    println("  Price Change: $(ticker_24hr[:priceChange])")
    println("  Price Change %: $(ticker_24hr[:priceChangePercent])")
catch e
    println("✗ Error: $e")
end

# Test 4: Get ticker book with symbolStatus
println("\n4. Testing get_ticker_book with symbolStatus='TRADING'")
try
    book_ticker = get_ticker_book(rest_client; symbol="BTCUSDT", symbolStatus="TRADING")
    println("✓ Successfully retrieved book ticker for BTCUSDT with TRADING status")
    println("  Bid Price: $(book_ticker[:bidPrice]), Ask Price: $(book_ticker[:askPrice])")
catch e
    println("✗ Error: $e")
end

# Test 5: Get trading day ticker with symbolStatus
println("\n5. Testing get_trading_day_ticker with symbolStatus='TRADING'")
try
    trading_day = get_trading_day_ticker(rest_client; symbol="BTCUSDT", symbolStatus="TRADING")
    println("✓ Successfully retrieved trading day ticker for BTCUSDT with TRADING status")
    println("  Open Price: $(trading_day[:openPrice])")
catch e
    println("✗ Error: $e")
end

# Test 6: Get ticker with symbolStatus
println("\n6. Testing get_ticker with symbolStatus='TRADING'")
try
    ticker = get_ticker(rest_client; symbol="BTCUSDT", window_size="1d", symbolStatus="TRADING")
    println("✓ Successfully retrieved ticker for BTCUSDT with TRADING status")
    println("  Last Price: $(ticker[:lastPrice])")
catch e
    println("✗ Error: $e")
end

println("\n" * "=" ^ 80)
println("Testing symbolStatus parameter - WebSocket API")
println("=" ^ 80)

# Initialize WebSocket client
ws_client = WebSocketClient("config.toml")
connect!(ws_client)
session_logon(ws_client)

# Test 7: WebSocket depth with symbolStatus
println("\n7. Testing depth (WebSocket) with symbolStatus='TRADING'")
try
    orderbook_ws = depth(ws_client, "BTCUSDT"; limit=5, symbolStatus="TRADING")
    println("✓ Successfully retrieved WebSocket orderbook for BTCUSDT with TRADING status")
    println("  Bids: $(length(orderbook_ws.bids)), Asks: $(length(orderbook_ws.asks))")
catch e
    println("✗ Error: $e")
end

# Test 8: WebSocket ticker_price with symbolStatus
println("\n8. Testing ticker_price (WebSocket) with symbolStatus='TRADING'")
try
    price_ws = ticker_price(ws_client; symbol="BTCUSDT", symbolStatus="TRADING")
    println("✓ Successfully retrieved WebSocket price ticker for BTCUSDT with TRADING status")
    println("  Symbol: $(price_ws.symbol), Price: $(price_ws.price)")
catch e
    println("✗ Error: $e")
end

# Test 9: WebSocket ticker_book with symbolStatus
println("\n9. Testing ticker_book (WebSocket) with symbolStatus='TRADING'")
try
    book_ws = ticker_book(ws_client; symbol="BTCUSDT", symbolStatus="TRADING")
    println("✓ Successfully retrieved WebSocket book ticker for BTCUSDT with TRADING status")
    println("  Bid Price: $(book_ws.bidPrice), Ask Price: $(book_ws.askPrice)")
catch e
    println("✗ Error: $e")
end

# Test 10: WebSocket ticker_24hr with symbolStatus
println("\n10. Testing ticker_24hr (WebSocket) with symbolStatus='TRADING'")
try
    ticker_24hr_ws = ticker_24hr(ws_client; symbol="BTCUSDT", symbolStatus="TRADING")
    println("✓ Successfully retrieved WebSocket 24hr ticker for BTCUSDT with TRADING status")
    println("  Price Change: $(ticker_24hr_ws.priceChange)")
catch e
    println("✗ Error: $e")
end

# Test 11: WebSocket ticker_trading_day with symbolStatus
println("\n11. Testing ticker_trading_day (WebSocket) with symbolStatus='TRADING'")
try
    trading_day_ws = ticker_trading_day(ws_client; symbol="BTCUSDT", symbolStatus="TRADING")
    println("✓ Successfully retrieved WebSocket trading day ticker for BTCUSDT with TRADING status")
    println("  Open Price: $(trading_day_ws.openPrice)")
catch e
    println("✗ Error: $e")
end

# Test 12: WebSocket ticker with symbolStatus
println("\n12. Testing ticker (WebSocket) with symbolStatus='TRADING'")
try
    ticker_ws = ticker(ws_client; symbol="BTCUSDT", window_size="1d", symbolStatus="TRADING")
    println("✓ Successfully retrieved WebSocket ticker for BTCUSDT with TRADING status")
    println("  Last Price: $(ticker_ws.lastPrice)")
catch e
    println("✗ Error: $e")
end

# Cleanup
println("\n" * "=" ^ 80)
println("Cleaning up...")
session_logout(ws_client)
disconnect!(ws_client)
println("✓ WebSocket connection closed")

println("\n" * "=" ^ 80)
println("All tests completed!")
println("=" ^ 80)
