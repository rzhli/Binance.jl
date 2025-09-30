module Types

using Dates, StructTypes, JSON3, DataFrames, Printf

# Enums
export SymbolStatus, AccountPermissions, OrderStatus, OrderListStatus, OrderListOrderStatus,
    ContingencyType, OrderTypes, OrderResponseType, OrderSide, TimeInForce,
    RateLimiters, RateLimitIntervals, STPModes

# Filters
export AbstractFilter, PriceFilter, PercentPriceFilter, PercentPriceBySideFilter, LotSizeFilter,
    MinNotionalFilter, NotionalFilter, IcebergPartsFilter, MarketLotSizeFilter,
    MaxNumOrdersFilter, MaxNumAlgoOrdersFilter, MaxNumIcebergOrdersFilter,
    MaxPositionFilter, TrailingDeltaFilter, MaxNumOrderAmendsFilter,
    MaxNumOrderListsFilter, ExchangeMaxNumOrdersFilter,
    ExchangeMaxNumAlgoOrdersFilter, ExchangeMaxNumIcebergOrdersFilter,
    ExchangeMaxNumOrderListsFilter, MaxAssetsFilter

# Exchange Information
export RateLimit, SymbolInfo, ExchangeInfo

# WebSocket Information
export WebSocketConnection

# Account and Trading Data
export Order, Trade, Kline, Ticker24hr

# Market Data
export OrderBook, PriceLevel, MarketTrade, AggregateTrade, AveragePrice, Ticker24hrRest,
    Ticker24hrMini, TradingDayTicker, TradingDayTickerMini, RollingWindowTicker,
    RollingWindowTickerMini, PriceTicker, BookTicker

# --- ENUM Definitions ---

@enum SymbolStatus TRADING END_OF_DAY HALT BREAK
@enum AccountPermissions SPOT MARGIN LEVERAGED TRD_GRP_002 TRD_GRP_003 TRD_GRP_004 TRD_GRP_005 TRD_GRP_006 TRD_GRP_007 TRD_GRP_008 TRD_GRP_009 TRD_GRP_010 TRD_GRP_011 TRD_GRP_012 TRD_GRP_013 TRD_GRP_014 TRD_GRP_015 TRD_GRP_016 TRD_GRP_017 TRD_GRP_018 TRD_GRP_019 TRD_GRP_020 TRD_GRP_021 TRD_GRP_022 TRD_GRP_023 TRD_GRP_024 TRD_GRP_025 TRD_GRP_236

@enum OrderStatus NEW PENDING_NEW PARTIALLY_FILLED FILLED CANCELED PENDING_CANCEL REJECTED EXPIRED EXPIRED_IN_MATCH
@enum OrderListStatus RESPONSE EXEC_STARTED UPDATED ALL_DONE
@enum OrderListOrderStatus EXECUTING REJECT
@enum ContingencyType OCO OTO
# AllocationType has only one value "SOR", which conflicts with WorkingFloor. Keeping as String.
# @enum AllocationType SOR
@enum OrderTypes LIMIT MARKET STOP_LOSS STOP_LOSS_LIMIT TAKE_PROFIT TAKE_PROFIT_LIMIT LIMIT_MAKER
@enum OrderResponseType ACK RESULT FULL
# WorkingFloor has "SOR" which conflicts with AllocationType. Keeping as String.
# @enum WorkingFloor EXCHANGE SOR
@enum OrderSide BUY SELL
@enum TimeInForce GTC IOC FOK
@enum RateLimiters REQUEST_WEIGHT ORDERS RAW_REQUESTS CONNECTIONS
@enum RateLimitIntervals SECOND MINUTE DAY
@enum STPModes NONE EXPIRE_MAKER EXPIRE_TAKER EXPIRE_BOTH DECREMENT

# StructTypes.StructType(::Type{<:Enum}) = StructTypes.StringType()


# --- Structs for Exchange Information ---

abstract type AbstractFilter end
StructTypes.StructType(::Type{AbstractFilter}) = StructTypes.AbstractType()
StructTypes.subtypekey(::Type{AbstractFilter}) = :filterType
StructTypes.subtypes(::Type{AbstractFilter}) = (
    PRICE_FILTER = PriceFilter,
    PERCENT_PRICE = PercentPriceFilter,
    PERCENT_PRICE_BY_SIDE = PercentPriceBySideFilter,
    LOT_SIZE = LotSizeFilter,
    MIN_NOTIONAL = MinNotionalFilter,
    NOTIONAL = NotionalFilter,
    ICEBERG_PARTS = IcebergPartsFilter,
    MARKET_LOT_SIZE = MarketLotSizeFilter,
    MAX_NUM_ORDERS = MaxNumOrdersFilter,
    MAX_NUM_ALGO_ORDERS = MaxNumAlgoOrdersFilter,
    MAX_NUM_ICEBERG_ORDERS = MaxNumIcebergOrdersFilter,
    MAX_POSITION = MaxPositionFilter,
    TRAILING_DELTA = TrailingDeltaFilter,
    MAX_NUM_ORDER_AMENDS = MaxNumOrderAmendsFilter,
    MAX_NUM_ORDER_LISTS = MaxNumOrderListsFilter,
    EXCHANGE_MAX_NUM_ORDERS = ExchangeMaxNumOrdersFilter,
    EXCHANGE_MAX_NUM_ALGO_ORDERS = ExchangeMaxNumAlgoOrdersFilter,
    EXCHANGE_MAX_NUM_ICEBERG_ORDERS = ExchangeMaxNumIcebergOrdersFilter,
    EXCHANGE_MAX_NUM_ORDER_LISTS = ExchangeMaxNumOrderListsFilter,
    MAX_ASSETS = MaxAssetsFilter
)

struct PriceFilter <: AbstractFilter
    filterType::String
    minPrice::String
    maxPrice::String
    tickSize::String
end
StructTypes.StructType(::Type{PriceFilter}) = StructTypes.Struct()

function Base.show(io::IO, f::PriceFilter)
    print(io, "Price: min: $(f.minPrice), max: $(f.maxPrice), tick: $(f.tickSize)")
end

struct PercentPriceFilter <: AbstractFilter
    filterType::String
    multiplierUp::String
    multiplierDown::String
    avgPriceMins::Int
end
StructTypes.StructType(::Type{PercentPriceFilter}) = StructTypes.Struct()

function Base.show(io::IO, f::PercentPriceFilter)
    print(io, "PercentPrice: up: × $(f.multiplierUp), down: × $(f.multiplierDown), avg: $(f.avgPriceMins) min")
end

struct PercentPriceBySideFilter <: AbstractFilter
    filterType::String
    bidMultiplierUp::String
    bidMultiplierDown::String
    askMultiplierUp::String
    askMultiplierDown::String
    avgPriceMins::Int
end
StructTypes.StructType(::Type{PercentPriceBySideFilter}) = StructTypes.Struct()

function Base.show(io::IO, f::PercentPriceBySideFilter)
    print(io, "PercentPriceBySide: bid: × $(f.bidMultiplierDown) - $(f.bidMultiplierUp), ask: × $(f.askMultiplierDown) - $(f.askMultiplierUp)")
end

struct LotSizeFilter <: AbstractFilter
    filterType::String
    minQty::String
    maxQty::String
    stepSize::String
end
StructTypes.StructType(::Type{LotSizeFilter}) = StructTypes.Struct()

function Base.show(io::IO, f::LotSizeFilter)
    print(io, "LotSize: min: $(f.minQty), max: $(f.maxQty), step: $(f.stepSize)")
end

struct MinNotionalFilter <: AbstractFilter
    filterType::String
    minNotional::String
    applyToMarket::Bool
    avgPriceMins::Int
end
StructTypes.StructType(::Type{MinNotionalFilter}) = StructTypes.Struct()

function Base.show(io::IO, f::MinNotionalFilter)
    print(io, "minNotional min: $(f.minNotional), market: $(f.applyToMarket)")
end

struct NotionalFilter <: AbstractFilter
    filterType::String
    minNotional::String
    applyMinToMarket::Bool
    maxNotional::String
    applyMaxToMarket::Bool
    avgPriceMins::Int
end
StructTypes.StructType(::Type{NotionalFilter}) = StructTypes.Struct()

function Base.show(io::IO, f::NotionalFilter)
    print(io, "Notional: min: $(f.minNotional), max: $(f.maxNotional)")
end

struct IcebergPartsFilter <: AbstractFilter
    filterType::String
    limit::Int
end
StructTypes.StructType(::Type{IcebergPartsFilter}) = StructTypes.Struct()

function Base.show(io::IO, f::IcebergPartsFilter)
    print(io, "IcebergParts: limit: $(f.limit)")
end

struct MarketLotSizeFilter <: AbstractFilter
    filterType::String
    minQty::String
    maxQty::String
    stepSize::String
end
StructTypes.StructType(::Type{MarketLotSizeFilter}) = StructTypes.Struct()

function Base.show(io::IO, f::MarketLotSizeFilter)
    print(io, "MarketLotSize: min: $(f.minQty), max: $(f.maxQty), step: $(f.stepSize)")
end

struct MaxNumOrdersFilter <: AbstractFilter
    filterType::String
    maxNumOrders::Int
end
StructTypes.StructType(::Type{MaxNumOrdersFilter}) = StructTypes.Struct()

function Base.show(io::IO, f::MaxNumOrdersFilter)
    print(io, "MaxNumOrders: $(f.maxNumOrders)")
end

struct MaxNumAlgoOrdersFilter <: AbstractFilter
    filterType::String
    maxNumAlgoOrders::Int
end
StructTypes.StructType(::Type{MaxNumAlgoOrdersFilter}) = StructTypes.Struct()

function Base.show(io::IO, f::MaxNumAlgoOrdersFilter)
    print(io, "MaxNumAlgoOrders: $(f.maxNumAlgoOrders)")
end

struct MaxNumIcebergOrdersFilter <: AbstractFilter
    filterType::String
    maxNumIcebergOrders::Int
end
StructTypes.StructType(::Type{MaxNumIcebergOrdersFilter}) = StructTypes.Struct()

function Base.show(io::IO, f::MaxNumIcebergOrdersFilter)
    print(io, "MaxNumIcebergOrders: $(f.maxNumIcebergOrders)")
end

struct MaxPositionFilter <: AbstractFilter
    filterType::String
    maxPosition::String
end
StructTypes.StructType(::Type{MaxPositionFilter}) = StructTypes.Struct()

function Base.show(io::IO, f::MaxPositionFilter)
    print(io, "MaxPosition: $(f.maxPosition)")
end

struct TrailingDeltaFilter <: AbstractFilter
    filterType::String
    minTrailingAboveDelta::Int
    maxTrailingAboveDelta::Int
    minTrailingBelowDelta::Int
    maxTrailingBelowDelta::Int
end
StructTypes.StructType(::Type{TrailingDeltaFilter}) = StructTypes.Struct()

function Base.show(io::IO, f::TrailingDeltaFilter)
    print(
        io, "TrailingDelta: min-AboveDelta: $(f.minTrailingAboveDelta), max-AboveDelta:$(f.maxTrailingAboveDelta), min-BelowDelta: $(f.minTrailingBelowDelta), max-BelowDelta: $(f.maxTrailingBelowDelta)"
    )
end

struct MaxNumOrderAmendsFilter <: AbstractFilter
    filterType::String
    maxNumOrderAmends::Int
end
StructTypes.StructType(::Type{MaxNumOrderAmendsFilter}) = StructTypes.Struct()

function Base.show(io::IO, f::MaxNumOrderAmendsFilter)
    print(io, "MaxNumOrderAmends: $(f.maxNumOrderAmends)")
end

struct MaxNumOrderListsFilter <: AbstractFilter
    filterType::String
    maxNumOrderLists::Int
end
StructTypes.StructType(::Type{MaxNumOrderListsFilter}) = StructTypes.Struct()

function Base.show(io::IO, f::MaxNumOrderListsFilter)
    print(io, "MaxNumOrderLists: $(f.maxNumOrderLists)")
end

struct MaxAssetsFilter <: AbstractFilter
    filterType::String
    maxAssets::Int
end
StructTypes.StructType(::Type{MaxAssetsFilter}) = StructTypes.Struct()

function Base.show(io::IO, f::MaxAssetsFilter)
    print(io, "MaxAssets: $(f.maxAssets)")
end

# --- Exchange Filters ---
struct ExchangeMaxNumOrdersFilter <: AbstractFilter
    filterType::String
    maxNumOrders::Int
end
StructTypes.StructType(::Type{ExchangeMaxNumOrdersFilter}) = StructTypes.Struct()

struct ExchangeMaxNumAlgoOrdersFilter <: AbstractFilter
    filterType::String
    maxNumAlgoOrders::Int
end
StructTypes.StructType(::Type{ExchangeMaxNumAlgoOrdersFilter}) = StructTypes.Struct()

struct ExchangeMaxNumIcebergOrdersFilter <: AbstractFilter
    filterType::String
    maxNumIcebergOrders::Int
end
StructTypes.StructType(::Type{ExchangeMaxNumIcebergOrdersFilter}) = StructTypes.Struct()

struct ExchangeMaxNumOrderListsFilter <: AbstractFilter
    filterType::String
    maxNumOrderLists::Int
end
StructTypes.StructType(::Type{ExchangeMaxNumOrderListsFilter}) = StructTypes.Struct()

# --- Symbol and Exchange Info Structs ---
const SymbolFilter = Union{
    PriceFilter,PercentPriceFilter,PercentPriceBySideFilter,LotSizeFilter,MinNotionalFilter,
    NotionalFilter,IcebergPartsFilter,MarketLotSizeFilter,MaxNumOrdersFilter,MaxNumAlgoOrdersFilter,
    MaxNumIcebergOrdersFilter,MaxPositionFilter,TrailingDeltaFilter,MaxNumOrderAmendsFilter,MaxNumOrderListsFilter
}

const ExchangeFilter = Union{ExchangeMaxNumOrdersFilter,ExchangeMaxNumAlgoOrdersFilter,ExchangeMaxNumIcebergOrdersFilter,ExchangeMaxNumOrderListsFilter}

struct RateLimit
    rateLimitType::RateLimiters
    interval::RateLimitIntervals
    intervalNum::Int
    limit::Int
end
StructTypes.StructType(::Type{RateLimit}) = StructTypes.Struct()

struct SymbolInfo
    symbol::String
    status::SymbolStatus
    baseAsset::String
    baseAssetPrecision::Int
    quoteAsset::String
    quoteAssetPrecision::Int
    baseCommissionPrecision::Int
    quoteCommissionPrecision::Int
    orderTypes::Vector{OrderTypes}
    icebergAllowed::Bool
    ocoAllowed::Bool
    quoteOrderQtyMarketAllowed::Bool
    isSpotTradingAllowed::Bool
    isMarginTradingAllowed::Bool
    filters::Vector{AbstractFilter}
    permissions::Vector{AccountPermissions}
    defaultSelfTradePreventionMode::STPModes
    allowedSelfTradePreventionModes::Vector{STPModes}
end
StructTypes.StructType(::Type{SymbolInfo}) = StructTypes.Struct()

function Base.show(io::IO, ::MIME"text/plain", s::SymbolInfo)
    println(io, "SymbolInfo for ", s.symbol, ":")
    println(io, "  Status: ", s.status)
    println(io, "  Base Asset: ", s.baseAsset, " (Precision: ", s.baseAssetPrecision, ")")
    println(io, "  Quote Asset: ", s.quoteAsset, " (Precision: ", s.quoteAssetPrecision, ")")
    println(io, "  Trading: Spot=", s.isSpotTradingAllowed, ", Margin=", s.isMarginTradingAllowed)
    println(io, "  Order Types: ", join(s.orderTypes, ", "))

    println(io, "\n  Filters:")
    if isempty(s.filters)
        println(io, "    (No filters)")
    else
        for filter in s.filters
            println(io, "    • ", filter)
        end
    end
end

struct ExchangeInfo
    timezone::String
    serverTime::DateTime
    rateLimits::Vector{RateLimit}
    exchangeFilters::Vector{AbstractFilter}
    symbols::Vector{SymbolInfo}
end
StructTypes.StructType(::Type{ExchangeInfo}) = StructTypes.CustomStruct()
StructTypes.lower(e::ExchangeInfo) = (
    timezone=e.timezone,
    serverTime=Int64(round(datetime2unix(e.serverTime) * 1000)),
    rateLimits=e.rateLimits,
    exchangeFilters=e.exchangeFilters,
    symbols=e.symbols
)
StructTypes.construct(::Type{ExchangeInfo}, obj) = ExchangeInfo(
    obj["timezone"],
    unix2datetime(obj["serverTime"] / 1000),
    JSON3.read(JSON3.write(obj["rateLimits"]), Vector{RateLimit}),
    JSON3.read(JSON3.write(obj["exchangeFilters"]), Vector{AbstractFilter}),
    JSON3.read(JSON3.write(obj["symbols"]), Vector{SymbolInfo})
)

function Base.show(io::IO, ::MIME"text/plain", info::ExchangeInfo)
    println(io, "ExchangeInfo:")
    println(io, "  Timezone: ", info.timezone)
    println(io, "  Server Time: ", info.serverTime)

    println(io, "\n  Rate Limits:")
    rate_limits_df = DataFrame(info.rateLimits)
    show(io, rate_limits_df)

    # exchangeFilters为空，filters在symbols字段里

    println(io, "\n\n  Symbols (showing first 10 of ", length(info.symbols), "):")
    symbols_df = DataFrame(
        [(
        symbol=s.symbol,
        status=s.status,
        baseAsset=s.baseAsset,
        quoteAsset=s.quoteAsset,
        spot=s.isSpotTradingAllowed,
        margin=s.isMarginTradingAllowed
    ) for s in info.symbols]
    )
    show(io, first(symbols_df, 10))
end

# --- Structs for WebSocket Information ---

struct WebSocketConnection
    apiKey::String
    authorizedSince::Int64
    connectedSince::Int64
    returnRateLimits::Bool
    serverTime::Int64
    userDataStream::Bool
end
StructTypes.StructType(::Type{WebSocketConnection}) = StructTypes.Struct()

function Base.show(io::IO, ::MIME"text/plain", wsc::WebSocketConnection)
    println(io, "WebSocket Connection Status:")
    println(io, "  API Key: ", wsc.apiKey)
    println(io, "  Connected Since: ", unix2datetime(wsc.connectedSince / 1000))
    println(io, "  Authorized Since: ", unix2datetime(wsc.authorizedSince / 1000))
    println(io, "  Server Time: ", unix2datetime(wsc.serverTime / 1000))
    println(io, "  User Data Stream: ", wsc.userDataStream)
    println(io, "  Return Rate Limits: ", wsc.returnRateLimits)
end

# --- Structs for Account Data ---

struct Order
    symbol::String
    orderId::Int64
    orderListId::Int64
    clientOrderId::String
    price::String
    origQty::String
    executedQty::String
    cummulativeQuoteQty::String
    status::OrderStatus
    timeInForce::TimeInForce
    type::OrderTypes
    side::OrderSide
    stopPrice::String
    icebergQty::String
    time::DateTime
    updateTime::DateTime
    isWorking::Bool
    origQuoteOrderQty::String
end
StructTypes.StructType(::Type{Order}) = StructTypes.CustomStruct()
StructTypes.lower(o::Order) = (
    symbol=o.symbol, orderId=o.orderId, orderListId=o.orderListId, clientOrderId=o.clientOrderId,
    price=o.price, origQty=o.origQty, executedQty=o.executedQty, cummulativeQuoteQty=o.cummulativeQuoteQty,
    status=o.status, timeInForce=o.timeInForce, type=o.type, side=o.side, stopPrice=o.stopPrice,
    icebergQty=o.icebergQty, time=Int64(round(datetime2unix(o.time) * 1000)),
    updateTime=Int64(round(datetime2unix(o.updateTime) * 1000)), isWorking=o.isWorking,
    origQuoteOrderQty=o.origQuoteOrderQty
)
StructTypes.construct(::Type{Order}, obj) = Order(
    obj["symbol"], obj["orderId"], obj["orderListId"], obj["clientOrderId"], obj["price"],
    obj["origQty"], obj["executedQty"], obj["cummulativeQuoteQty"],
    StructTypes.construct(OrderStatus, obj["status"]),
    StructTypes.construct(TimeInForce, obj["timeInForce"]),
    StructTypes.construct(OrderTypes, obj["type"]),
    StructTypes.construct(OrderSide, obj["side"]),
    obj["stopPrice"], obj["icebergQty"],
    unix2datetime(obj["time"] / 1000), unix2datetime(obj["updateTime"] / 1000),
    obj["isWorking"], obj["origQuoteOrderQty"]
)

struct Trade
    symbol::String
    id::Int64
    orderId::Int64
    orderListId::Int64
    price::String
    qty::String
    quoteQty::String
    commission::String
    commissionAsset::String
    time::DateTime
    isBuyer::Bool
    isMaker::Bool
    isBestMatch::Bool
end
StructTypes.StructType(::Type{Trade}) = StructTypes.CustomStruct()
StructTypes.lower(t::Trade) = (
    symbol=t.symbol, id=t.id, orderId=t.orderId, orderListId=t.orderListId, price=t.price,
    qty=t.qty, quoteQty=t.quoteQty, commission=t.commission, commissionAsset=t.commissionAsset,
    time=Int64(round(datetime2unix(t.time) * 1000)), isBuyer=t.isBuyer, isMaker=t.isMaker,
    isBestMatch=t.isBestMatch
)
StructTypes.construct(::Type{Trade}, obj) = Trade(
    obj["symbol"], obj["id"], obj["orderId"], obj["orderListId"], obj["price"], obj["qty"],
    obj["quoteQty"], obj["commission"], obj["commissionAsset"], unix2datetime(obj["time"] / 1000),
    obj["isBuyer"], obj["isMaker"], obj["isBestMatch"]
)

struct Kline
    open_time::DateTime
    open::Float64
    high::Float64
    low::Float64
    close::Float64
    base_volume::Float64        # Base asset → 交易对的第一个币，比如 BTC/USDT 里的 BTC
    close_time::DateTime
    quote_volume::Float64       # Quote asset → 交易对的第二个币，比如 BTC/USDT 里的 USDT
    number_of_trades::Int
    taker_base_volume::Float64
    taker_quote_volume::Float64
    ignore::String                              # Unused field, ignore
end
StructTypes.StructType(::Type{Kline}) = StructTypes.CustomStruct()
StructTypes.lower(k::Kline) = [
    Int64(round(datetime2unix(k.open_time) * 1000)), string(k.open), string(k.high), string(k.low), string(k.close), string(k.base_volume),
    Int64(round(datetime2unix(k.close_time) * 1000)), string(k.quote_volume), k.number_of_trades,
    string(k.taker_base_volume), string(k.taker_quote_volume), k.ignore
]
StructTypes.construct(::Type{Kline}, arr::Vector) = Kline(
    unix2datetime(arr[1] / 1000),
    parse(Float64, arr[2]),
    parse(Float64, arr[3]),
    parse(Float64, arr[4]),
    parse(Float64, arr[5]),
    parse(Float64, arr[6]),
    unix2datetime(arr[7] / 1000),
    parse(Float64, arr[8]),
    arr[9],
    parse(Float64, arr[10]),
    parse(Float64, arr[11]),
    arr[12]
)

function Base.show(io::IO, ::MIME"text/plain", k::Kline)
    println(io, "Kline:")
    @printf(io, "  Open Time:  %s\n", k.open_time)
    @printf(io, "  Open:       %8f\n", k.open)
    @printf(io, "  High:       %8f\n", k.high)
    @printf(io, "  Low:        %8f\n", k.low)
    @printf(io, "  Close:      %8f\n", k.close)
    @printf(io, "  Base Vol:   %f\n", k.base_volume)
    @printf(io, "  Close Time: %s\n", k.close_time)
    @printf(io, "  Quote Vol:  %8f\n", k.quote_volume)
    @printf(io, "  Trades:     %d\n", k.number_of_trades)
    @printf(io, "  Taker Base Vol:  %8f\n", k.taker_base_volume)
    @printf(io, "  Taker Quote Vol:%8f\n", k.taker_quote_volume)
end

struct Ticker24hr
    eventType::String
    eventTime::DateTime
    symbol::String
    priceChange::String
    priceChangePercent::String
    weightedAvgPrice::String
    firstTradePrice::String
    lastPrice::String
    lastQuantity::String
    bestBidPrice::String
    bestBidQuantity::String
    bestAskPrice::String
    bestAskQuantity::String
    openPrice::String
    highPrice::String
    lowPrice::String
    totalTradedBaseAssetVolume::String
    totalTradedQuoteAssetVolume::String
    statisticsOpenTime::DateTime
    statisticsCloseTime::DateTime
    firstTradeId::Int64
    lastTradeId::Int64
    totalNumberOfTrades::Int
end
StructTypes.StructType(::Type{Ticker24hr}) = StructTypes.CustomStruct()
StructTypes.lower(t::Ticker24hr) = (
    e=t.eventType, E=Int64(round(datetime2unix(t.eventTime) * 1000)), s=t.symbol,
    p=t.priceChange, P=t.priceChangePercent, w=t.weightedAvgPrice, x=t.firstTradePrice,
    c=t.lastPrice, Q=t.lastQuantity, b=t.bestBidPrice, B=t.bestBidQuantity,
    a=t.bestAskPrice, A=t.bestAskQuantity, o=t.openPrice, h=t.highPrice, l=t.lowPrice,
    v=t.totalTradedBaseAssetVolume, q=t.totalTradedQuoteAssetVolume,
    O=Int64(round(datetime2unix(t.statisticsOpenTime) * 1000)),
    C=Int64(round(datetime2unix(t.statisticsCloseTime) * 1000)),
    F=t.firstTradeId, L=t.lastTradeId, n=t.totalNumberOfTrades
)
StructTypes.construct(::Type{Ticker24hr}, obj) = Ticker24hr(
    obj["e"], unix2datetime(obj["E"] / 1000), obj["s"], obj["p"], obj["P"], obj["w"], obj["x"],
    obj["c"], obj["Q"], obj["b"], obj["B"], obj["a"], obj["A"], obj["o"], obj["h"], obj["l"],
    obj["v"], obj["q"], unix2datetime(obj["O"] / 1000), unix2datetime(obj["C"] / 1000),
    obj["F"], obj["L"], obj["n"]
)

# --- Structs for Market Data ---

struct PriceLevel
    price::Float64
    quantity::Float64
end
StructTypes.StructType(::Type{PriceLevel}) = StructTypes.CustomStruct()
StructTypes.construct(::Type{PriceLevel}, arr::Vector) = PriceLevel(
    parse(Float64, arr[1]),
    parse(Float64, arr[2])
)
StructTypes.lower(p::PriceLevel) = [string(p.price), string(p.quantity)]

struct OrderBook
    lastUpdateId::Int64
    bids::Vector{PriceLevel}
    asks::Vector{PriceLevel}
end
StructTypes.StructType(::Type{OrderBook}) = StructTypes.Struct()

function Base.show(io::IO, ::MIME"text/plain", ob::OrderBook)
    println(io, "OrderBook (lastUpdateId: ", ob.lastUpdateId, ")")
    
    bids_df = DataFrame(price=[p.price for p in ob.bids], quantity=[p.quantity for p in ob.bids])
    println(io, "\nBids:")
    show(io, bids_df)

    asks_df = DataFrame(price=[p.price for p in ob.asks], quantity=[p.quantity for p in ob.asks])
    println(io, "\n\nAsks:")
    show(io, asks_df)
end

struct MarketTrade
    id::Int64
    price::String
    qty::String
    quoteQty::String
    time::DateTime
    isBuyerMaker::Bool
    isBestMatch::Bool
end
StructTypes.StructType(::Type{MarketTrade}) = StructTypes.CustomStruct()
StructTypes.lower(t::MarketTrade) = (
    id=t.id, price=t.price, qty=t.qty, quoteQty=t.quoteQty,
    time=Int64(round(datetime2unix(t.time) * 1000)), isBuyerMaker=t.isBuyerMaker,
    isBestMatch=t.isBestMatch
)
StructTypes.construct(::Type{MarketTrade}, obj) = MarketTrade(
    obj["id"],
    obj["price"],
    obj["qty"],
    obj["quoteQty"],
    unix2datetime(obj["time"] / 1000),
    obj["isBuyerMaker"],
    obj["isBestMatch"]
)

function Base.show(io::IO, ::MIME"text/plain", t::MarketTrade)
    println(io, "MarketTrade:")
    @printf(io, "  ID:              %d\n", t.id)
    @printf(io, "  Time:            %s\n", t.time)
    @printf(io, "  Price:           %f\n", parse(Float64, t.price))
    @printf(io, "  Quantity:        %f\n", parse(Float64, t.qty))
    @printf(io, "  Quote Quantity:  %f\n", parse(Float64, t.quoteQty))
    @printf(io, "  Buyer was Maker: %s\n", t.isBuyerMaker)
    @printf(io, "  Best Match:      %s\n", t.isBestMatch)
end

struct AggregateTrade
    a::Int64  # Aggregate trade ID
    p::String # Price
    q::String # Quantity
    f::Int64  # First trade ID
    l::Int64  # Last trade ID
    T::DateTime # Timestamp
    m::Bool   # Was the buyer the maker?
    M::Bool   # Was the trade the best price match?
end
StructTypes.StructType(::Type{AggregateTrade}) = StructTypes.CustomStruct()
StructTypes.lower(t::AggregateTrade) = (
    a=t.a, p=t.p, q=t.q, f=t.f, l=t.l,
    T=Int64(round(datetime2unix(t.T) * 1000)), m=t.m, M=t.M
)
StructTypes.construct(::Type{AggregateTrade}, obj) = AggregateTrade(
    obj["a"],
    obj["p"],
    obj["q"],
    obj["f"], obj["l"],
    unix2datetime(obj["T"] / 1000),
    obj["m"],
    obj["M"]
)

function Base.show(io::IO, ::MIME"text/plain", t::AggregateTrade)
    println(io, "AggregateTrade:")
    @printf(io, "  ID:               %d\n", t.a)
    @printf(io, "  Timestamp:        %s\n", t.T)
    @printf(io, "  Price:            %f\n", parse(Float64, t.p))
    @printf(io, "  Quantity:         %f\n", parse(Float64, t.q))
    @printf(io, "  First Trade ID:   %d\n", t.f)
    @printf(io, "  Last Trade ID:    %d\n", t.l)
    @printf(io, "  Buyer was Maker:  %s\n", t.m)
end

struct AveragePrice
    mins::Int
    price::String
    closeTime::DateTime
end
StructTypes.StructType(::Type{AveragePrice}) = StructTypes.CustomStruct()
StructTypes.lower(ap::AveragePrice) = (
    mins=ap.mins,
    price=ap.price,
    closeTime=Int64(round(datetime2unix(ap.closeTime) * 1000))
)
StructTypes.construct(::Type{AveragePrice}, obj) = AveragePrice(
    obj["mins"],
    obj["price"],
    unix2datetime(obj["closeTime"] / 1000)
)

function Base.show(io::IO, ::MIME"text/plain", ap::AveragePrice)
    println(io, "AveragePrice:")
    @printf(io, "  Interval (mins): %d\n", ap.mins)
    @printf(io, "  Price:           %f\n", parse(Float64, ap.price))
    @printf(io, "  Close Time:      %s\n", ap.closeTime)
end

struct Ticker24hrRest
    symbol::String
    priceChange::String
    priceChangePercent::String
    weightedAvgPrice::String
    prevClosePrice::String
    lastPrice::String
    lastQty::String
    bidPrice::String
    bidQty::String
    askPrice::String
    askQty::String
    openPrice::String
    highPrice::String
    lowPrice::String
    volume::String
    quoteVolume::String
    openTime::DateTime
    closeTime::DateTime
    firstId::Int64
    lastId::Int64
    count::Int
end
StructTypes.StructType(::Type{Ticker24hrRest}) = StructTypes.CustomStruct()
StructTypes.construct(::Type{Ticker24hrRest}, obj) = Ticker24hrRest(
    obj["symbol"],
    obj["priceChange"],
    obj["priceChangePercent"],
    obj["weightedAvgPrice"],
    obj["prevClosePrice"],
    obj["lastPrice"],
    obj["lastQty"],
    obj["bidPrice"],
    obj["bidQty"],
    obj["askPrice"],
    obj["askQty"],
    obj["openPrice"],
    obj["highPrice"],
    obj["lowPrice"],
    obj["volume"],
    obj["quoteVolume"],
    unix2datetime(obj["openTime"] / 1000),
    unix2datetime(obj["closeTime"] / 1000),
    obj["firstId"],
    obj["lastId"],
    obj["count"]
)

struct Ticker24hrMini
    symbol::String
    openPrice::String
    highPrice::String
    lowPrice::String
    lastPrice::String
    volume::String
    quoteVolume::String
    openTime::DateTime
    closeTime::DateTime
    firstId::Int64
    lastId::Int64
    count::Int
end
StructTypes.StructType(::Type{Ticker24hrMini}) = StructTypes.CustomStruct()
StructTypes.construct(::Type{Ticker24hrMini}, obj) = Ticker24hrMini(
    obj["symbol"],
    obj["openPrice"],
    obj["highPrice"],
    obj["lowPrice"],
    obj["lastPrice"],
    obj["volume"],
    obj["quoteVolume"],
    unix2datetime(obj["openTime"] / 1000),
    unix2datetime(obj["closeTime"] / 1000),
    obj["firstId"],
    obj["lastId"],
    obj["count"]
)

struct TradingDayTicker
    symbol::String
    priceChange::String
    priceChangePercent::String
    weightedAvgPrice::String
    openPrice::String
    highPrice::String
    lowPrice::String
    lastPrice::String
    volume::String
    quoteVolume::String
    openTime::DateTime
    closeTime::DateTime
    firstId::Int64
    lastId::Int64
    count::Int
end
StructTypes.StructType(::Type{TradingDayTicker}) = StructTypes.CustomStruct()
StructTypes.construct(::Type{TradingDayTicker}, obj) = TradingDayTicker(
    obj["symbol"],
    obj["priceChange"],
    obj["priceChangePercent"],
    obj["weightedAvgPrice"],
    obj["openPrice"],
    obj["highPrice"],
    obj["lowPrice"],
    obj["lastPrice"],
    obj["volume"],
    obj["quoteVolume"],
    unix2datetime(obj["openTime"] / 1000),
    unix2datetime(obj["closeTime"] / 1000),
    obj["firstId"],
    obj["lastId"],
    obj["count"]
)

struct TradingDayTickerMini
    symbol::String
    openPrice::String
    highPrice::String
    lowPrice::String
    lastPrice::String
    volume::String
    quoteVolume::String
    openTime::DateTime
    closeTime::DateTime
    firstId::Int64
    lastId::Int64
    count::Int
end
StructTypes.StructType(::Type{TradingDayTickerMini}) = StructTypes.CustomStruct()
StructTypes.construct(::Type{TradingDayTickerMini}, obj) = TradingDayTickerMini(
    obj["symbol"],
    obj["openPrice"],
    obj["highPrice"],
    obj["lowPrice"],
    obj["lastPrice"],
    obj["volume"],
    obj["quoteVolume"],
    unix2datetime(obj["openTime"] / 1000),
    unix2datetime(obj["closeTime"] / 1000),
    obj["firstId"],
    obj["lastId"],
    obj["count"]
)

struct RollingWindowTicker
    symbol::String
    priceChange::String
    priceChangePercent::String
    weightedAvgPrice::String
    openPrice::String
    highPrice::String
    lowPrice::String
    lastPrice::String
    volume::String
    quoteVolume::String
    openTime::DateTime
    closeTime::DateTime
    firstId::Int64
    lastId::Int64
    count::Int
end
StructTypes.StructType(::Type{RollingWindowTicker}) = StructTypes.CustomStruct()
StructTypes.construct(::Type{RollingWindowTicker}, obj) = RollingWindowTicker(
    obj["symbol"],
    obj["priceChange"],
    obj["priceChangePercent"],
    obj["weightedAvgPrice"],
    obj["openPrice"],
    obj["highPrice"],
    obj["lowPrice"],
    obj["lastPrice"],
    obj["volume"],
    obj["quoteVolume"],
    unix2datetime(obj["openTime"] / 1000),
    unix2datetime(obj["closeTime"] / 1000),
    obj["firstId"],
    obj["lastId"],
    obj["count"]
)

struct RollingWindowTickerMini
    symbol::String
    openPrice::String
    highPrice::String
    lowPrice::String
    lastPrice::String
    volume::String
    quoteVolume::String
    openTime::DateTime
    closeTime::DateTime
    firstId::Int64
    lastId::Int64
    count::Int
end
StructTypes.StructType(::Type{RollingWindowTickerMini}) = StructTypes.CustomStruct()
StructTypes.construct(::Type{RollingWindowTickerMini}, obj) = RollingWindowTickerMini(
    obj["symbol"],
    obj["openPrice"],
    obj["highPrice"],
    obj["lowPrice"],
    obj["lastPrice"],
    obj["volume"],
    obj["quoteVolume"],
    unix2datetime(obj["openTime"] / 1000),
    unix2datetime(obj["closeTime"] / 1000),
    obj["firstId"],
    obj["lastId"],
    obj["count"]
)

struct PriceTicker
    symbol::String
    price::String
end
StructTypes.StructType(::Type{PriceTicker}) = StructTypes.CustomStruct()
StructTypes.construct(::Type{PriceTicker}, obj) = PriceTicker(
    obj["symbol"],
    obj["price"]
)

function Base.show(io::IO, ::MIME"text/plain", pt::PriceTicker)
    @printf(io, "PriceTicker for %s: %f\n", pt.symbol, parse(Float64, pt.price))
end

struct BookTicker
    symbol::String
    bidPrice::String
    bidQty::String
    askPrice::String
    askQty::String
end
StructTypes.StructType(::Type{BookTicker}) = StructTypes.CustomStruct()
StructTypes.construct(::Type{BookTicker}, obj) = BookTicker(
    obj["symbol"],
    obj["bidPrice"],
    obj["bidQty"],
    obj["askPrice"],
    obj["askQty"]
)

function Base.show(io::IO, ::MIME"text/plain", bt::BookTicker)
    println(io, "BookTicker for ", bt.symbol, ":")
    @printf(io, "  Bid: %f @ %f\n", parse(Float64, bt.bidQty), parse(Float64, bt.bidPrice))
    @printf(io, "  Ask: %f @ %f\n", parse(Float64, bt.askQty), parse(Float64, bt.askPrice))
end

end # end of module
