module Types

using Dates, StructTypes, JSON3, Printf
using JSON, StructUtils
using FixedPointDecimals

# ======================= 代码生成宏 =======================

"""
生成单字段 Filter 类型（filterType + 一个值字段）
"""
macro define_single_filter(name, field_name, field_type, show_label)
    esc(quote
        struct $name <: AbstractFilter
            filterType::String
            $field_name::$field_type
        end
        StructTypes.StructType(::Type{$name}) = StructTypes.Struct()
        Base.show(io::IO, f::$name) = print(io, $show_label, ": ", getfield(f, $(QuoteNode(field_name))))
    end)
end

"""
生成三字段 Filter 类型（filterType + min/max/step 或类似字段）
"""
macro define_triple_filter(name, f1, f2, f3, show_template)
    esc(quote
        struct $name <: AbstractFilter
            filterType::String
            $f1::String
            $f2::String
            $f3::String
        end
        StructTypes.StructType(::Type{$name}) = StructTypes.Struct()
        Base.show(io::IO, f::$name) = print(io, $show_template,
            " min: ", getfield(f, $(QuoteNode(f1))),
            ", max: ", getfield(f, $(QuoteNode(f2))),
            ", step: ", getfield(f, $(QuoteNode(f3))))
    end)
end

"""
生成 Mini Ticker 类型（共12个字段的精简版）
"""
macro define_mini_ticker(name)
    esc(quote
        @binance_struct struct $name
            symbol::String
            openPrice::String
            highPrice::String
            lowPrice::String
            lastPrice::String
            volume::String
            quoteVolume::String
            openTime::DateTime &UNIX_MS
            closeTime::DateTime &UNIX_MS
            firstId::Int64
            lastId::Int64
            count::Int
        end
    end)
end

"""
生成 Full Ticker 类型（共15个字段，含价格变化信息）
"""
macro define_full_ticker(name)
    esc(quote
        @binance_struct struct $name
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
            openTime::DateTime &UNIX_MS
            closeTime::DateTime &UNIX_MS
            firstId::Int64
            lastId::Int64
            count::Int
        end
    end)
end

# ======================= 原有代码 =======================

# Type alias for commonly used decimal precision in cryptocurrency (8 decimal places)
const DecimalPrice = FixedDecimal{Int64, 8}
const DecimalInput = Union{AbstractString,Integer,AbstractFloat,FixedDecimal}

# Export decimal types and conversion utilities
export DecimalPrice, DecimalInput, to_decimal_string, to_struct

"""
    to_struct(T, value)

Construct a `T` instance from an already-parsed JSON value, without
round-tripping through a string.

# Migration bridge (JSON3/StructTypes -> JSON.jl/StructUtils)

Types that still declare `StructTypes.CustomStruct()` keep using their hand
written `StructTypes.construct`. Types that have been migrated no longer
declare a `StructType` at all, so `StructTypes.StructType(T)` falls back to
`UnorderedStruct()` and they route to `StructUtils.make`, which honours
`@tags` field tags, `@defaults`, and `JSON.@choosetype`.

This lets the migration proceed one file at a time with the test suite green
at every step. Once no `CustomStruct` declarations remain, the first branch
and the StructTypes dependency can both be dropped.
"""
@inline function to_struct(::Type{T}, value) where {T}
    st = StructTypes.StructType(T)
    return st isa StructTypes.CustomStruct ?
        StructTypes.construct(T, value) :
        StructUtils.make(T, value)
end

# Vector needs its own method: a `CustomStruct` element type has no
# `constructfrom` method, so the element-wise loop must be explicit.
@inline function to_struct(::Type{Vector{T}}, value) where {T}
    st = StructTypes.StructType(T)
    return st isa StructTypes.CustomStruct ?
        T[StructTypes.construct(T, elem) for elem in value] :
        StructUtils.make(Vector{T}, value)
end

# ===================== JSON 字段 tag =====================
#
# Binance sends every timestamp as unix milliseconds, but StructUtils' stock
# `lift` for `DateTime` only accepts ISO strings. Such fields therefore carry an
# explicit lift/lower tag.
#
# `@tags` splices field tags at lowering time and requires a *literal* named
# tuple: a `const` binding parses as a bare `Symbol` and trips
# `FieldExpr`'s `Union{None,Expr}` conversion. `@binance_struct` exists to avoid
# repeating the same closure pair on every timestamp field — it rewrites
# `&UNIX_MS` into the literal tag before handing the definition to `@tags`.
#
# The tag is deliberately *not* namespaced under `json=(...)`: an un-namespaced
# tag is visible to `StructUtils.make` as well as `JSON.parse`, which is what
# lets `to_struct` keep working on already-materialized responses during the
# migration.
#
# Scoping note: this only affects annotated fields. Unannotated `DateTime`
# fields keep the stock ISO-string behaviour, unlike a global
# `StructUtils.lift(::Type{DateTime}, ::Number)` method, which would hijack
# every package's `DateTime` parsing.
const UNIX_MS_TAG = :((lift = x -> unix2datetime(x / 1000),
                       lower = d -> Int64(round(datetime2unix(d) * 1000))))

# `(name="E",)` and `UNIX_MS` on the same field must end up as one literal named
# tuple: `@tags` reads a single tags expression per field, so chained `&` has to
# be flattened rather than nested.
_merge_tag_tuples(a::Expr, b::Expr) = Expr(:tuple, a.args..., b.args...)

_splice_field_tags(x) = x
function _splice_field_tags(ex::Expr)
    # `field::T &UNIX_MS` parses as Expr(:call, :&, :(field::T), :UNIX_MS);
    # `field::T &(name="E",) &UNIX_MS` nests another `&` call on the left.
    if ex.head === :call && length(ex.args) == 3 &&
       ex.args[1] === :& && ex.args[3] === :UNIX_MS
        inner = ex.args[2]
        if inner isa Expr && inner.head === :call && length(inner.args) == 3 &&
           inner.args[1] === :&
            return Expr(:call, :&, _splice_field_tags(inner.args[2]),
                        _merge_tag_tuples(inner.args[3], copy(UNIX_MS_TAG)))
        end
        return Expr(:call, :&, _splice_field_tags(inner), copy(UNIX_MS_TAG))
    end
    return Expr(ex.head, map(_splice_field_tags, ex.args)...)
end

"""
    @binance_struct struct T ... end

`StructUtils.@tags` with `&UNIX_MS` expanded into the unix-milliseconds
timestamp tag. Use it for any response struct with `DateTime` fields.
"""
macro binance_struct(expr)
    return esc(Expr(:macrocall, GlobalRef(StructUtils, Symbol("@tags")),
                    __source__, _splice_field_tags(expr)))
end

"""
    to_decimal_string(value)

Convert a numeric value to its exact string representation for API calls.
Supports Float64, String, and FixedDecimal types.

# Examples
```julia
to_decimal_string(0.001)              # "0.001"
to_decimal_string("0.00100000")       # "0.00100000" (preserved as-is)
to_decimal_string(DecimalPrice(0.001)) # "0.00100000" (exact 8 decimals)
```
"""
# 使用多重派发代替运行时类型检查（类型稳定）
to_decimal_string(::Nothing) = nothing
to_decimal_string(value::AbstractString) = String(value)
to_decimal_string(value::FixedDecimal) = string(value)
to_decimal_string(value::Integer) = string(value)
to_decimal_string(value::AbstractFloat) = string(value)

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
export OrderBook, PriceLevel, MarketTrade, BlockTrade, WebSocketTrade, WebSocketBlockTrade, AggregateTrade, AveragePrice, Ticker24hrRest,
    Ticker24hrMini, TradingDayTicker, TradingDayTickerMini, RollingWindowTicker,
    RollingWindowTickerMini, PriceTicker, BookTicker

# Execution Rules & Reference Price
export ExecutionRule, SymbolExecutionRules, ExecutionRulesResponse, ReferencePrice,
    AbstractReferencePriceCalculation, ArithmeticMeanCalculation, ExternalCalculation

# --- ENUM Definitions ---

@enum SymbolStatus TRADING END_OF_DAY HALT BREAK CANCEL_ONLY
@enum AccountPermissions SPOT MARGIN LEVERAGED TRD_GRP_002 TRD_GRP_003 TRD_GRP_004 TRD_GRP_005 TRD_GRP_006 TRD_GRP_007 TRD_GRP_008 TRD_GRP_009 TRD_GRP_010 TRD_GRP_011 TRD_GRP_012 TRD_GRP_013 TRD_GRP_014 TRD_GRP_015 TRD_GRP_016 TRD_GRP_017 TRD_GRP_018 TRD_GRP_019 TRD_GRP_020 TRD_GRP_021 TRD_GRP_022 TRD_GRP_023 TRD_GRP_024 TRD_GRP_025 TRD_GRP_236

@enum OrderStatus NEW PENDING_NEW PARTIALLY_FILLED FILLED CANCELED PENDING_CANCEL REJECTED EXPIRED EXPIRED_IN_MATCH
@enum OrderListStatus RESPONSE EXEC_STARTED UPDATED ALL_DONE
@enum OrderListOrderStatus EXECUTING REJECT
@enum ContingencyType OCO OTO OTOCO OPO
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
@enum STPModes NONE EXPIRE_MAKER EXPIRE_TAKER EXPIRE_BOTH DECREMENT TRANSFER

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

# --- 三字段 Filter（使用宏生成）---
@define_triple_filter(PriceFilter, minPrice, maxPrice, tickSize, "Price:")
@define_triple_filter(LotSizeFilter, minQty, maxQty, stepSize, "LotSize:")
@define_triple_filter(MarketLotSizeFilter, minQty, maxQty, stepSize, "MarketLotSize:")

"""
    PercentPriceFilter

`PERCENT_PRICE`: bounds order price by `multiplierUp/Down` times the recent
`avgPriceMins`-minute average. As of 2026-05-08, the server evaluates this
filter against the symbol's reference price when one exists and is non-null,
falling back to the historical avg-price behavior when it does not.
"""
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

"""
    PercentPriceBySideFilter

`PERCENT_PRICE_BY_SIDE`: like `PERCENT_PRICE` but with separate
bid/ask multipliers. As of 2026-05-08, the server evaluates this filter
against the symbol's reference price when one exists and is non-null,
falling back to the historical avg-price behavior when it does not.
"""
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

# --- 单字段 Filter（使用宏生成）---
@define_single_filter(IcebergPartsFilter, limit, Int, "IcebergParts")
@define_single_filter(MaxNumOrdersFilter, maxNumOrders, Int, "MaxNumOrders")
@define_single_filter(MaxNumAlgoOrdersFilter, maxNumAlgoOrders, Int, "MaxNumAlgoOrders")
@define_single_filter(MaxNumIcebergOrdersFilter, maxNumIcebergOrders, Int, "MaxNumIcebergOrders")
@define_single_filter(MaxPositionFilter, maxPosition, String, "MaxPosition")
@define_single_filter(MaxNumOrderAmendsFilter, maxNumOrderAmends, Int, "MaxNumOrderAmends")
@define_single_filter(MaxNumOrderListsFilter, maxNumOrderLists, Int, "MaxNumOrderLists")
@define_single_filter(MaxAssetsFilter, maxAssets, Int, "MaxAssets")

# TrailingDeltaFilter 有4个字段，保持手动定义
struct TrailingDeltaFilter <: AbstractFilter
    filterType::String
    minTrailingAboveDelta::Int
    maxTrailingAboveDelta::Int
    minTrailingBelowDelta::Int
    maxTrailingBelowDelta::Int
end
StructTypes.StructType(::Type{TrailingDeltaFilter}) = StructTypes.Struct()
Base.show(io::IO, f::TrailingDeltaFilter) = print(io,
    "TrailingDelta: above: $(f.minTrailingAboveDelta)-$(f.maxTrailingAboveDelta), below: $(f.minTrailingBelowDelta)-$(f.maxTrailingBelowDelta)")

# --- Exchange Filters（使用宏生成）---
@define_single_filter(ExchangeMaxNumOrdersFilter, maxNumOrders, Int, "ExchangeMaxNumOrders")
@define_single_filter(ExchangeMaxNumAlgoOrdersFilter, maxNumAlgoOrders, Int, "ExchangeMaxNumAlgoOrders")
@define_single_filter(ExchangeMaxNumIcebergOrdersFilter, maxNumIcebergOrders, Int, "ExchangeMaxNumIcebergOrders")
@define_single_filter(ExchangeMaxNumOrderListsFilter, maxNumOrderLists, Int, "ExchangeMaxNumOrderLists")

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

mutable struct SymbolInfo
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
    otoAllowed::Bool
    opoAllowed::Bool
    quoteOrderQtyMarketAllowed::Bool
    isSpotTradingAllowed::Bool
    isMarginTradingAllowed::Bool
    # Note: Using Vector{AbstractFilter} is required for JSON3/StructTypes polymorphic deserialization.
    # The abstract type is necessary here as filters come from API responses with varying concrete types.
    # Performance impact is minimal since filter access is infrequent compared to market data processing.
    filters::Vector{AbstractFilter}
    permissions::Vector{AccountPermissions}
    defaultSelfTradePreventionMode::STPModes
    allowedSelfTradePreventionModes::Vector{STPModes}

    # Inner constructor for default values
    function SymbolInfo()
        new()
    end
end
StructTypes.StructType(::Type{SymbolInfo}) = StructTypes.Mutable()
StructTypes.defaults(::Type{SymbolInfo}) = Dict{Symbol,Any}(
    :otoAllowed => false,
    :opoAllowed => false
)

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
    to_struct(Vector{RateLimit}, obj["rateLimits"]),
    to_struct(Vector{AbstractFilter}, obj["exchangeFilters"]),
    to_struct(Vector{SymbolInfo}, obj["symbols"])
)

function Base.show(io::IO, ::MIME"text/plain", info::ExchangeInfo)
    println(io, "ExchangeInfo:")
    println(io, "  Timezone: ", info.timezone)
    println(io, "  Server Time: ", info.serverTime)

    println(io, "\n  Rate Limits:")
    print_rate_limits(io, info.rateLimits)

    # exchangeFilters为空，filters在symbols字段里

    println(io, "\n\n  Symbols (showing first 10 of ", length(info.symbols), "):")
    print_symbol_summary(io, info.symbols, 10)
end

function print_rate_limits(io::IO, rate_limits::Vector{RateLimit})
    if isempty(rate_limits)
        println(io, "    (none)")
        return
    end

    @printf(io, "    %-16s %-10s %8s %8s\n", "type", "interval", "num", "limit")
    for limit in rate_limits
        @printf(io, "    %-16s %-10s %8d %8d\n",
            limit.rateLimitType, limit.interval, limit.intervalNum, limit.limit)
    end
end

function print_symbol_summary(io::IO, symbols::Vector{SymbolInfo}, max_rows::Int)
    if isempty(symbols)
        println(io, "    (none)")
        return
    end

    @printf(io, "    %-14s %-10s %-8s %-8s %-5s %-6s\n",
        "symbol", "status", "base", "quote", "spot", "margin")
    for symbol in Iterators.take(symbols, max_rows)
        @printf(io, "    %-14s %-10s %-8s %-8s %-5s %-6s\n",
            symbol.symbol, string(symbol.status), symbol.baseAsset, symbol.quoteAsset,
            string(symbol.isSpotTradingAllowed), string(symbol.isMarginTradingAllowed))
    end
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
    println(io, "  API Key Configured: ", !isempty(wsc.apiKey))
    println(io, "  Connected Since: ", unix2datetime(wsc.connectedSince / 1000))
    println(io, "  Authorized Since: ", unix2datetime(wsc.authorizedSince / 1000))
    println(io, "  Server Time: ", unix2datetime(wsc.serverTime / 1000))
    println(io, "  User Data Stream: ", wsc.userDataStream)
    println(io, "  Return Rate Limits: ", wsc.returnRateLimits)
end

# --- Structs for Account Data ---

# The four enum fields need no annotation: StructUtils lifts a JSON string to an
# `Enum` by matching the instance name, which is exactly what the old
# `StructTypes.construct(OrderStatus, ...)` calls did by hand.
@binance_struct struct Order
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
    time::DateTime &UNIX_MS
    updateTime::DateTime &UNIX_MS
    isWorking::Bool
    origQuoteOrderQty::String
    # Conditional: present only for expired orders, including those expired by the
    # price-range execution rule. Added in REST/WS API on 2026-05-08.
    # Absent (not null) in every other response, so the Union default applies.
    expiryReason::Union{String, Nothing}
end

@binance_struct struct Trade
    symbol::String
    id::Int64
    orderId::Int64
    orderListId::Int64
    price::String
    qty::String
    quoteQty::String
    commission::String
    commissionAsset::String
    time::DateTime &UNIX_MS
    isBuyer::Bool
    isMaker::Bool
    isBestMatch::Bool
end

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
StructTypes.construct(::Type{Kline}, arr::AbstractVector) = Kline(
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

# 23 fields, all abbreviated on the wire. Note `p`/`P`, `b`/`B`, `a`/`A` and
# `q`/`Q` are case-sensitive pairs with unrelated meanings, and `l` (lowercase L,
# low price) sits next to `L` (last trade id).
@binance_struct struct Ticker24hr
    eventType::String                  &(name="e",)
    eventTime::DateTime                &(name="E",) &UNIX_MS
    symbol::String                     &(name="s",)
    priceChange::String                &(name="p",)
    priceChangePercent::String         &(name="P",)
    weightedAvgPrice::String           &(name="w",)
    firstTradePrice::String            &(name="x",)
    lastPrice::String                  &(name="c",)
    lastQuantity::String               &(name="Q",)
    bestBidPrice::String               &(name="b",)
    bestBidQuantity::String            &(name="B",)
    bestAskPrice::String               &(name="a",)
    bestAskQuantity::String            &(name="A",)
    openPrice::String                  &(name="o",)
    highPrice::String                  &(name="h",)
    lowPrice::String                   &(name="l",)
    totalTradedBaseAssetVolume::String &(name="v",)
    totalTradedQuoteAssetVolume::String &(name="q",)
    statisticsOpenTime::DateTime       &(name="O",) &UNIX_MS
    statisticsCloseTime::DateTime      &(name="C",) &UNIX_MS
    firstTradeId::Int64                &(name="F",)
    lastTradeId::Int64                 &(name="L",)
    totalNumberOfTrades::Int           &(name="n",)
end

# --- Structs for Market Data ---

struct PriceLevel
    price::Float64
    quantity::Float64
end
# Serialized as a two-element array of decimal strings (`["95000.10","1.5"]`),
# not an object, so it opts out of struct-like treatment and converts through
# lift/lower. Registering `structlike = false` for every `StructStyle` (rather
# than only ours) is what keeps `StructUtils.make` and `JSON.parse` in agreement.
StructUtils.structlike(::StructUtils.StructStyle, ::Type{PriceLevel}) = false
StructUtils.lift(::Type{PriceLevel}, arr) =
    PriceLevel(parse(Float64, arr[1]), parse(Float64, arr[2]))
JSON.lower(p::PriceLevel) = [string(p.price), string(p.quantity)]

struct OrderBook
    lastUpdateId::Int64
    bids::Vector{PriceLevel}
    asks::Vector{PriceLevel}
end
# Nothing to declare: the nested `Vector{PriceLevel}` elements are handled by
# PriceLevel's own lift/lower. This is the case that needed a hand-written
# construct under StructTypes, because `constructfrom` had no method for a
# CustomStruct element type and every `depth()` call raised a MethodError.

function Base.show(io::IO, ::MIME"text/plain", ob::OrderBook)
    println(io, "OrderBook (lastUpdateId: ", ob.lastUpdateId, ")")
    
    println(io, "\nBids:")
    print_price_levels(io, ob.bids)

    println(io, "\n\nAsks:")
    print_price_levels(io, ob.asks)
end

function print_price_levels(io::IO, levels::Vector{PriceLevel})
    if isempty(levels)
        println(io, "  (empty)")
        return
    end

    @printf(io, "  %14s %14s\n", "price", "quantity")
    for level in levels
        @printf(io, "  %14.8f %14.8f\n", level.price, level.quantity)
    end
end

@binance_struct struct MarketTrade
    id::Int64
    price::String
    qty::String
    quoteQty::String
    time::DateTime &UNIX_MS
    isBuyerMaker::Bool
    isBestMatch::Bool
end

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

# Block Trade — large off-book trade matched against a separate liquidity pool.
# Endpoint introduced 2026-05-08 (REST: GET /api/v3/historicalBlockTrades,
# WS API: blockTrades.historical). Response shape differs from MarketTrade:
# no isBestMatch field.
@binance_struct struct BlockTrade
    id::Int64
    price::String
    qty::String
    quoteQty::String
    time::DateTime &UNIX_MS
    isBuyerMaker::Bool
end

function Base.show(io::IO, ::MIME"text/plain", t::BlockTrade)
    println(io, "BlockTrade:")
    @printf(io, "  ID:              %d\n", t.id)
    @printf(io, "  Time:            %s\n", t.time)
    @printf(io, "  Price:           %f\n", parse(Float64, t.price))
    @printf(io, "  Quantity:        %f\n", parse(Float64, t.qty))
    @printf(io, "  Quote Quantity:  %f\n", parse(Float64, t.quoteQty))
    @printf(io, "  Buyer was Maker: %s\n", t.isBuyerMaker)
end

# WebSocket Trade Stream struct (different from REST API MarketTrade)
# Maps the abbreviated field names from Binance WebSocket trade stream
# The stream sends abbreviated keys, so every field needs an explicit `name`
# tag. `UNIX_MS` supplies the timestamp lift/lower; the tags compose.
@binance_struct struct WebSocketTrade
    eventType::String    &(name="e",)        # Event type ("trade")
    eventTime::DateTime  &(name="E",) &UNIX_MS
    symbol::String       &(name="s",)
    tradeId::Int64       &(name="t",)
    price::String        &(name="p",)
    quantity::String     &(name="q",)
    tradeTime::DateTime  &(name="T",) &UNIX_MS
    isBuyerMaker::Bool   &(name="m",)        # Is the buyer the market maker?
    ignore::Bool         &(name="M",)
end

function Base.show(io::IO, ::MIME"text/plain", t::WebSocketTrade)
    println(io, "WebSocketTrade:")
    @printf(io, "  Symbol:          %s\n", t.symbol)
    @printf(io, "  Trade ID:        %d\n", t.tradeId)
    @printf(io, "  Time:            %s\n", t.tradeTime)
    @printf(io, "  Price:           %s\n", t.price)
    @printf(io, "  Quantity:        %s\n", t.quantity)
    @printf(io, "  Buyer was Maker: %s\n", t.isBuyerMaker)
end

# WebSocket Block Trade Stream — <symbol>@blockTrade (rollout 2026-05-12).
# Same shape as WebSocketTrade minus the trailing `M` (best-match) flag.
# Same shape as WebSocketTrade minus the trailing `M` best-match flag.
@binance_struct struct WebSocketBlockTrade
    eventType::String    &(name="e",)        # Event type ("blockTrade")
    eventTime::DateTime  &(name="E",) &UNIX_MS
    symbol::String       &(name="s",)
    tradeId::Int64       &(name="t",)        # Block trade ID
    price::String        &(name="p",)
    quantity::String     &(name="q",)
    tradeTime::DateTime  &(name="T",) &UNIX_MS
    isBuyerMaker::Bool   &(name="m",)
end

function Base.show(io::IO, ::MIME"text/plain", t::WebSocketBlockTrade)
    println(io, "WebSocketBlockTrade:")
    @printf(io, "  Symbol:          %s\n", t.symbol)
    @printf(io, "  Block Trade ID:  %d\n", t.tradeId)
    @printf(io, "  Time:            %s\n", t.tradeTime)
    @printf(io, "  Price:           %s\n", t.price)
    @printf(io, "  Quantity:        %s\n", t.quantity)
    @printf(io, "  Buyer was Maker: %s\n", t.isBuyerMaker)
end

@binance_struct struct AggregateTrade
    a::Int64  # Aggregate trade ID
    p::String # Price
    q::String # Quantity
    f::Int64  # First trade ID
    l::Int64  # Last trade ID
    T::DateTime &UNIX_MS # Timestamp
    m::Bool   # Was the buyer the maker?
    M::Bool   # Was the trade the best price match?
end

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

@binance_struct struct AveragePrice
    mins::Int
    price::String
    closeTime::DateTime &UNIX_MS
end

function Base.show(io::IO, ::MIME"text/plain", ap::AveragePrice)
    println(io, "AveragePrice:")
    @printf(io, "  Interval (mins): %d\n", ap.mins)
    @printf(io, "  Price:           %f\n", parse(Float64, ap.price))
    @printf(io, "  Close Time:      %s\n", ap.closeTime)
end

@binance_struct struct Ticker24hrRest
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
    openTime::DateTime &UNIX_MS
    closeTime::DateTime &UNIX_MS
    firstId::Int64
    lastId::Int64
    count::Int
end

# --- Mini Ticker 类型（使用宏生成，12字段精简版）---
@define_mini_ticker(Ticker24hrMini)
@define_mini_ticker(TradingDayTickerMini)
@define_mini_ticker(RollingWindowTickerMini)

# --- Full Ticker 类型（使用宏生成，15字段含价格变化）---
@define_full_ticker(TradingDayTicker)
@define_full_ticker(RollingWindowTicker)


struct PriceTicker
    symbol::String
    price::String
end

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

function Base.show(io::IO, ::MIME"text/plain", bt::BookTicker)
    println(io, "BookTicker for ", bt.symbol, ":")
    @printf(io, "  Bid: %f @ %f\n", parse(Float64, bt.bidQty), parse(Float64, bt.bidPrice))
    @printf(io, "  Ask: %f @ %f\n", parse(Float64, bt.askQty), parse(Float64, bt.askPrice))
end

# --- Execution Rules & Reference Price ---

struct ExecutionRule
    ruleType::String
    bidLimitMultUp::String
    bidLimitMultDown::String
    askLimitMultUp::String
    askLimitMultDown::String
end
StructTypes.StructType(::Type{ExecutionRule}) = StructTypes.Struct()

struct SymbolExecutionRules
    symbol::String
    rules::Vector{ExecutionRule}
end
StructTypes.StructType(::Type{SymbolExecutionRules}) = StructTypes.Struct()

struct ExecutionRulesResponse
    symbolRules::Vector{SymbolExecutionRules}
end
StructTypes.StructType(::Type{ExecutionRulesResponse}) = StructTypes.Struct()

@binance_struct struct ReferencePrice
    symbol::String
    # Absent (not just null) when the engine has no price yet; `@tags` supplies
    # `nothing` for a missing Union{T,Nothing} field.
    referencePrice::Union{String, Nothing}
    timestamp::DateTime &UNIX_MS
end

abstract type AbstractReferencePriceCalculation end

"""
    ArithmeticMeanCalculation

Reference price is calculated as a simple moving average of trade prices.
The time window is `bucketWidthMs * bucketCount` milliseconds.
"""
struct ArithmeticMeanCalculation <: AbstractReferencePriceCalculation
    symbol::String
    calculationType::String   # "ARITHMETIC_MEAN"
    bucketCount::Int
    bucketWidthMs::Int
end
StructTypes.StructType(::Type{ArithmeticMeanCalculation}) = StructTypes.Struct()

"""
    ExternalCalculation

Reference price is calculated outside the matching engine.
`externalCalculationId` identifies the Binance-defined calculation method.
Treat it as an extensible identifier: Binance may add external methods without
requiring a client schema change.
"""
struct ExternalCalculation <: AbstractReferencePriceCalculation
    symbol::String
    calculationType::String   # "EXTERNAL"
    externalCalculationId::Int
end
StructTypes.StructType(::Type{ExternalCalculation}) = StructTypes.Struct()

end # end of module
