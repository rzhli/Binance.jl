"""
    RateLimits

Per-endpoint request weights and unfilled-order-count costs, transcribed from the
Binance Spot API docs (`rest-api.md`, `web-socket-api.md`, changelog 2026-04-02).

Why this module exists: `RateLimiter` used to charge every request 1 unit against
`REQUEST_WEIGHT`, but the exchange charges each endpoint its documented weight.
With a 6000/minute budget, 30 successful `convert/getQuote` calls (weight 200 each)
exhaust the real allowance while the client still believes it has 5970 requests
left — which is how a strategy ends up with a 429 and then an IP ban.

Weights are grouped by the limiter they consume:

* `REQUEST_WEIGHT` — per IP, shared by every connection from that address.
* `ORDERS` (the docs call it *unfilled order count*) — per account. Only the
  endpoints that actually place orders consume it; querying an order does not.
* `RAW_REQUESTS` — per IP, one unit per request regardless of weight.

Order-placement and cancellation endpoints were changed on 2026-04-02 to cost
**0 weight when the request succeeds**; a failed request is still charged the
documented weight. `endpoint_cost` therefore reports both numbers and lets the
caller settle the difference after seeing the response
(see `RateLimiter.finalize_request!`).
"""
module RateLimits

export EndpointCost, endpoint_cost, ws_method_cost, zero_weight_on_success

"""
    EndpointCost

What one call costs against each limiter.

# Fields
- `weight::Int`: `REQUEST_WEIGHT` charged when the request fails, and also when it
  succeeds unless `zero_on_success` is set.
- `orders::Int`: unfilled order count consumed (the `ORDERS` limiter). Only
  order-placing endpoints are non-zero.
- `zero_on_success::Bool`: per the 2026-04-02 change, weight becomes 0 on success.
"""
struct EndpointCost
    weight::Int
    orders::Int
    zero_on_success::Bool
end

EndpointCost(weight::Int) = EndpointCost(weight, 0, false)
EndpointCost(weight::Int, orders::Int) = EndpointCost(weight, orders, false)

"""
    zero_weight_on_success(cost) -> Bool

Whether a successful request costs 0 weight. Kept as a function so call sites read
as intent rather than field access.
"""
zero_weight_on_success(cost::EndpointCost) = cost.zero_on_success

# ===================== REST endpoints =====================
#
# Keys are the paths passed to `make_request`. Endpoints whose weight depends on
# parameters (`depth` limit, symbol count, `computeCommissionRates`) are resolved
# by `endpoint_cost` from the params, with the table holding the single-symbol /
# cheapest case.
#
# `zero_on_success = true` mirrors the 2026-03-27 announcement (effective
# 2026-04-02). `PUT /api/v3/order/amend/keepPriority` is deliberately *not* in
# that set: the 2026-04-02 clarification says its weight only drops to 0 when the
# amendment expires the order, so charging the documented 4 is the safe reading.
const REST_COSTS = Dict{String,EndpointCost}(
    # --- General ---
    "/api/v3/ping"                     => EndpointCost(1),
    "/api/v3/time"                     => EndpointCost(1),
    "/api/v3/exchangeInfo"             => EndpointCost(20),

    # --- Market data ---
    "/api/v3/depth"                    => EndpointCost(5),    # limit-dependent
    "/api/v3/trades"                   => EndpointCost(25),
    "/api/v3/historicalTrades"         => EndpointCost(25),
    "/api/v3/historicalBlockTrades"    => EndpointCost(25),
    "/api/v3/aggTrades"                => EndpointCost(4),
    "/api/v3/klines"                   => EndpointCost(2),
    "/api/v3/uiKlines"                 => EndpointCost(2),
    "/api/v3/avgPrice"                 => EndpointCost(2),
    "/api/v3/ticker/24hr"              => EndpointCost(2),    # symbol-count dependent
    "/api/v3/ticker/tradingDay"        => EndpointCost(4),    # symbol-count dependent
    "/api/v3/ticker/price"             => EndpointCost(2),    # symbol-count dependent
    "/api/v3/ticker/bookTicker"        => EndpointCost(2),    # symbol-count dependent
    "/api/v3/ticker"                   => EndpointCost(4),    # symbol-count dependent
    "/api/v3/executionRules"           => EndpointCost(2),    # symbol-count dependent
    "/api/v3/referencePrice"           => EndpointCost(2),
    "/api/v3/referencePrice/calculation" => EndpointCost(2),

    # --- Trading (weight 0 on success since 2026-04-02) ---
    "/api/v3/order"                    => EndpointCost(1, 1, true),   # POST; GET/DELETE below
    "/api/v3/order/test"               => EndpointCost(1, 0, false),  # never placed, weight always charged
    "/api/v3/order/cancelReplace"      => EndpointCost(1, 1, true),
    "/api/v3/order/amend/keepPriority" => EndpointCost(4, 0, false),
    "/api/v3/openOrders"               => EndpointCost(1, 0, true),   # DELETE; GET below
    "/api/v3/sor/order"                => EndpointCost(1, 1, true),
    "/api/v3/sor/order/test"           => EndpointCost(1, 0, false),

    # --- Order lists (weight 0 on success) ---
    "/api/v3/order/oco"                => EndpointCost(1, 2, true),   # deprecated alias
    "/api/v3/orderList/oco"            => EndpointCost(1, 2, true),
    "/api/v3/orderList/oto"            => EndpointCost(1, 2, true),
    "/api/v3/orderList/otoco"          => EndpointCost(1, 3, true),
    "/api/v3/orderList/opo"            => EndpointCost(1, 2, true),
    "/api/v3/orderList/opoco"          => EndpointCost(1, 3, true),
    "/api/v3/orderList"                => EndpointCost(1, 0, true),   # DELETE; GET below

    # --- Account / queries (no order-count cost) ---
    "/api/v3/account"                  => EndpointCost(20),
    "/api/v3/allOrders"                => EndpointCost(20),
    "/api/v3/allOrderList"             => EndpointCost(20),
    "/api/v3/openOrderList"            => EndpointCost(6),
    "/api/v3/myTrades"                 => EndpointCost(20),   # 5 with orderId
    "/api/v3/rateLimit/order"          => EndpointCost(40),
    "/api/v3/myPreventedMatches"       => EndpointCost(2),    # 20 when querying by orderId
    "/api/v3/myAllocations"            => EndpointCost(20),
    "/api/v3/account/commission"       => EndpointCost(20),
    "/api/v3/order/amendments"         => EndpointCost(4),
    "/api/v3/myFilters"                => EndpointCost(40),
    "/api/v3/userDataStream"           => EndpointCost(2),

    # --- SAPI ---
    #
    # SAPI weights are documented per endpoint and marked (IP) or (UID). They are
    # tracked here so a heavy SAPI call is not charged as 1; the UID/IP
    # distinction is not modelled because the client cannot see the server's UID
    # counters. Convert's separate *daily quotation count* is not a weight limit
    # at all and is invisible until error 345239 comes back.
    "/sapi/v1/convert/exchangeInfo"    => EndpointCost(3000),
    "/sapi/v1/convert/assetInfo"       => EndpointCost(100),
    "/sapi/v1/convert/getQuote"        => EndpointCost(200),
    "/sapi/v1/convert/acceptQuote"     => EndpointCost(500),
    "/sapi/v1/convert/orderStatus"     => EndpointCost(100),
    "/sapi/v1/convert/tradeFlow"       => EndpointCost(3000),
    "/sapi/v1/convert/limit/placeOrder" => EndpointCost(500),
    "/sapi/v1/convert/limit/cancelOrder" => EndpointCost(200),
    "/sapi/v1/convert/limit/queryOpenOrders" => EndpointCost(3000),
    "/sapi/v1/account/status"          => EndpointCost(1),
    "/sapi/v1/account/apiTradingStatus" => EndpointCost(1),
    "/sapi/v1/account/apiRestrictions" => EndpointCost(1),
    "/sapi/v1/capital/withdraw/history" => EndpointCost(1),
    "/sapi/v1/capital/withdraw/apply"  => EndpointCost(1),
    "/sapi/v1/capital/deposit/hisrec"  => EndpointCost(1),
    "/sapi/v1/capital/deposit/address" => EndpointCost(1),
    "/sapi/v1/asset/assetDetail"       => EndpointCost(1),
    "/sapi/v1/asset/tradeFee"          => EndpointCost(1),
    "/sapi/v1/asset/dust"              => EndpointCost(1),
    "/sapi/v1/asset/dribblet"          => EndpointCost(1),
)

# `GET`/`DELETE` on a path that also accepts `POST` cost differently: querying an
# order is a plain weighted read, placing one is order-count-bearing and free on
# success. Keyed by `(method, path)` and consulted before `REST_COSTS`.
const REST_COSTS_BY_METHOD = Dict{Tuple{String,String},EndpointCost}(
    ("GET", "/api/v3/order")        => EndpointCost(4),   # query order: no order-count cost
    ("DELETE", "/api/v3/order")     => EndpointCost(1, 0, true),
    ("GET", "/api/v3/openOrders")   => EndpointCost(6),   # 80 without symbol
    ("GET", "/api/v3/orderList")    => EndpointCost(4),
    ("GET", "/api/v3/userDataStream")    => EndpointCost(2),
    ("PUT", "/api/v3/userDataStream")    => EndpointCost(2),
    ("DELETE", "/api/v3/userDataStream") => EndpointCost(2),
)

# Fallback for an endpoint missing from both tables. Deliberately not 1: an
# unknown endpoint is more likely to be a heavy account/market query than a ping,
# and under-charging is what causes bans.
const DEFAULT_REST_COST = EndpointCost(20)

"""
    endpoint_cost(method, endpoint, params) -> EndpointCost

The cost of one REST call. `params` resolves the endpoints whose documented weight
depends on arguments rather than on the path alone.

Unknown endpoints fall back to `DEFAULT_REST_COST` (20) and emit a `@debug`,
because silently charging 1 is what let the old limiter drift.
"""
function endpoint_cost(method::AbstractString, endpoint::AbstractString,
                       params::AbstractDict=Dict{String,Any}())
    key = (String(method), String(endpoint))
    base = get(REST_COSTS_BY_METHOD, key) do
        get(REST_COSTS, String(endpoint)) do
            @debug "No documented weight for endpoint; assuming $(DEFAULT_REST_COST.weight)" method endpoint
            DEFAULT_REST_COST
        end
    end
    return _adjust_for_params(base, String(endpoint), String(method), params)
end

# Symbol-count and limit-dependent weights. Each branch mirrors one weight table
# in the docs; the tables are small enough to inline and change rarely.
function _adjust_for_params(base::EndpointCost, endpoint::String, method::String,
                            params::AbstractDict)
    if endpoint == "/api/v3/depth"
        limit = _int_param(params, "limit", 100)
        w = limit <= 100 ? 5 : limit <= 500 ? 25 : limit <= 1000 ? 50 : 250
        return EndpointCost(w, base.orders, base.zero_on_success)

    elseif endpoint == "/api/v3/ticker/24hr"
        n = _symbol_count(params)
        # 1 symbol: 2 | 1-20 symbols: 2 | 21-100: 40 | 101+ or omitted: 80
        w = n == 0 ? 80 : n <= 20 ? 2 : n <= 100 ? 40 : 80
        return EndpointCost(w, base.orders, base.zero_on_success)

    elseif endpoint in ("/api/v3/ticker/price", "/api/v3/ticker/bookTicker")
        n = _symbol_count(params)
        return EndpointCost(n == 1 ? 2 : 4, base.orders, base.zero_on_success)

    elseif endpoint in ("/api/v3/ticker", "/api/v3/ticker/tradingDay")
        # 4 per symbol, capped at 200 beyond 50 symbols.
        n = max(_symbol_count(params), 1)
        return EndpointCost(min(4 * n, 200), base.orders, base.zero_on_success)

    elseif endpoint == "/api/v3/executionRules"
        # 2 per symbol capped at 40; 40 for symbolStatus or no params.
        n = _symbol_count(params)
        w = n == 0 ? 40 : haskey(params, "symbolStatus") ? 40 : min(2 * n, 40)
        return EndpointCost(w, base.orders, base.zero_on_success)

    elseif endpoint == "/api/v3/openOrders" && method == "GET"
        return EndpointCost(_symbol_count(params) == 0 ? 80 : 6,
                            base.orders, base.zero_on_success)

    elseif endpoint == "/api/v3/myTrades"
        return EndpointCost(haskey(params, "orderId") ? 5 : 20,
                            base.orders, base.zero_on_success)

    elseif endpoint == "/api/v3/myPreventedMatches"
        return EndpointCost(haskey(params, "orderId") ? 20 : 2,
                            base.orders, base.zero_on_success)

    elseif endpoint in ("/api/v3/order/test", "/api/v3/sor/order/test")
        return EndpointCost(_bool_param(params, "computeCommissionRates") ? 20 : 1,
                            base.orders, base.zero_on_success)
    end
    return base
end

# ===================== WebSocket API methods =====================
#
# Same weights as the REST equivalents; keyed by method name because that is what
# `send_request` has. Order-placing methods are the `zero_on_success` set from the
# 2026-03-27 announcement.
const WS_COSTS = Dict{String,EndpointCost}(
    "ping"                        => EndpointCost(1),
    "time"                        => EndpointCost(1),
    "exchangeInfo"                => EndpointCost(20),
    "executionRules"              => EndpointCost(2),
    "depth"                       => EndpointCost(5),
    "trades.recent"               => EndpointCost(25),
    "trades.historical"           => EndpointCost(25),
    "blockTrades.historical"      => EndpointCost(25),
    "trades.aggregate"            => EndpointCost(4),
    "klines"                      => EndpointCost(2),
    "uiKlines"                    => EndpointCost(2),
    "avgPrice"                    => EndpointCost(2),
    "ticker.24hr"                 => EndpointCost(2),
    "ticker.tradingDay"           => EndpointCost(4),
    "ticker"                      => EndpointCost(4),
    "ticker.price"                => EndpointCost(2),
    "ticker.book"                 => EndpointCost(2),
    "referencePrice"              => EndpointCost(2),
    "referencePrice.calculation"  => EndpointCost(2),

    "session.logon"               => EndpointCost(2),
    "session.status"              => EndpointCost(2),
    "session.logout"              => EndpointCost(2),

    # Trading: 0 weight on success, documented weight on failure.
    "order.place"                 => EndpointCost(1, 1, true),
    "order.test"                  => EndpointCost(1, 0, false),
    "order.cancel"                => EndpointCost(1, 0, true),
    "order.cancelReplace"         => EndpointCost(1, 1, true),
    "order.amend.keepPriority"    => EndpointCost(4, 0, false),
    "openOrders.cancelAll"        => EndpointCost(1, 0, true),
    "orderList.place"             => EndpointCost(1, 2, true),
    "orderList.place.oco"         => EndpointCost(1, 2, true),
    "orderList.place.oto"         => EndpointCost(1, 2, true),
    "orderList.place.otoco"       => EndpointCost(1, 3, true),
    "orderList.place.opo"         => EndpointCost(1, 2, true),
    "orderList.place.opoco"       => EndpointCost(1, 3, true),
    "orderList.cancel"            => EndpointCost(1, 0, true),
    "sor.order.place"             => EndpointCost(1, 1, true),
    "sor.order.test"              => EndpointCost(1, 0, false),

    # Account queries.
    "account.status"              => EndpointCost(20),
    "order.status"                => EndpointCost(4),
    "openOrders.status"           => EndpointCost(6),
    "allOrders"                   => EndpointCost(20),
    "orderList.status"            => EndpointCost(4),
    "openOrderLists.status"       => EndpointCost(6),
    "allOrderLists"               => EndpointCost(20),
    "myTrades"                    => EndpointCost(20),
    "account.rateLimits.orders"   => EndpointCost(40),
    "myPreventedMatches"          => EndpointCost(2),
    "myAllocations"               => EndpointCost(20),
    "account.commission"          => EndpointCost(20),
    "order.amendments"            => EndpointCost(4),
    "myFilters"                   => EndpointCost(40),

    "userDataStream.subscribe"    => EndpointCost(2),
    "userDataStream.unsubscribe"  => EndpointCost(2),
    "userDataStream.start"        => EndpointCost(2),
    "userDataStream.ping"         => EndpointCost(2),
    "userDataStream.stop"         => EndpointCost(2),
    "session.subscriptions"       => EndpointCost(2),
    "userDataStream.subscribe.signature" => EndpointCost(2),
)

"""
    ws_method_cost(method, params) -> EndpointCost

The cost of one WebSocket API request. Mirrors [`endpoint_cost`](@ref); the
parameter-dependent adjustments reuse the REST tables via the equivalent path.
"""
function ws_method_cost(method::AbstractString, params::AbstractDict=Dict{String,Any}())
    base = get(WS_COSTS, String(method)) do
        @debug "No documented weight for WS method; assuming $(DEFAULT_REST_COST.weight)" method
        DEFAULT_REST_COST
    end
    equivalent = get(WS_TO_REST_PATH, String(method), "")
    isempty(equivalent) && return base
    return _adjust_for_params(base, equivalent, "GET", params)
end

# WS methods whose weight varies with parameters, mapped onto the REST path whose
# weight table they share.
const WS_TO_REST_PATH = Dict{String,String}(
    "depth"               => "/api/v3/depth",
    "ticker.24hr"         => "/api/v3/ticker/24hr",
    "ticker.price"        => "/api/v3/ticker/price",
    "ticker.book"         => "/api/v3/ticker/bookTicker",
    "ticker"              => "/api/v3/ticker",
    "ticker.tradingDay"   => "/api/v3/ticker/tradingDay",
    "executionRules"      => "/api/v3/executionRules",
    "openOrders.status"   => "/api/v3/openOrders",
    "myTrades"            => "/api/v3/myTrades",
    "myPreventedMatches"  => "/api/v3/myPreventedMatches",
    "order.test"          => "/api/v3/order/test",
    "sor.order.test"      => "/api/v3/sor/order/test",
)

# ===================== param helpers =====================
#
# Params arrive as `Dict{String,Any}` with values already stringified for the
# query builder, so `"limit" => 500` and `"limit" => "500"` both occur.

function _int_param(params::AbstractDict, key::String, default::Int)
    haskey(params, key) || return default
    v = params[key]
    v isa Integer && return Int(v)
    v isa AbstractString && return something(tryparse(Int, v), default)
    return default
end

function _bool_param(params::AbstractDict, key::String)
    haskey(params, key) || return false
    v = params[key]
    v isa Bool && return v
    v isa AbstractString && return lowercase(v) == "true"
    return false
end

"""
    _symbol_count(params) -> Int

How many symbols a request covers: 1 for `symbol`, `n` for a `symbols` JSON array,
0 when neither is present (which the docs price as "all symbols").
"""
function _symbol_count(params::AbstractDict)
    haskey(params, "symbol") && return 1
    haskey(params, "symbols") || return 0
    v = params["symbols"]
    v isa AbstractVector && return length(v)
    if v isa AbstractString
        # Serialized as `["BTCUSDT","ETHUSDT"]`; counting commas avoids a JSON
        # parse on a hot path and is exact for the shapes the client produces.
        isempty(strip(v, ['[', ']', ' '])) && return 0
        return count(==(','), v) + 1
    end
    return 0
end

end # module RateLimits
