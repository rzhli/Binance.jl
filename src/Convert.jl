"""
Binance Convert API Module

This module provides access to Binance's Convert trading API, which allows users to
convert between different cryptocurrencies at quoted prices.

## API Access Requirements
- Convert API access requires approval via questionnaire submission
- Not suitable for: price arbitrage, high frequency trading, or price exploitation
- Binance may restrict or terminate API access at any time

## Rate Limits
- Endpoints use different rate limiting types:
- `exchangeInfo`: Weight 3000 (IP)
- `assetInfo`: Weight 100 (IP)
- `getQuote`: Weight 200 (UID)
- `acceptQuote`: Weight 500 (UID)
- `orderStatus`: Weight 100 (UID)
- `tradeFlow`: Weight 3000 (UID)
- `limitPlaceOrder`: Weight 500 (UID)
- `limitCancelOrder`: Weight 200 (UID)
- `limitQueryOpenOrders`: Weight 3000 (UID)

## Wallet Types
- `SPOT`: Spot wallet (default)
- `FUNDING`: Funding wallet
- `EARN`: Earn wallet
- Combinations supported: `SPOT_FUNDING`, `FUNDING_EARN`, `SPOT_FUNDING_EARN`, `SPOT_EARN`

## Valid Time Options for Quotes
- `10s`: 10 seconds (default)
- `30s`: 30 seconds
- `1m`: 1 minute
- `2m`: 2 minutes

## Expired Type Options for Limit Orders
- `1_D`: 1 day
- `3_D`: 3 days
- `7_D`: 7 days
- `30_D`: 30 days

See: https://developers.binance.com/docs/convert
"""
module Convert

using JSON3, StructTypes, Dates
using ..RESTAPI
using ..Types: to_decimal_string, to_struct

export convert_exchange_info, convert_asset_info, convert_get_quote, convert_accept_quote,
    convert_order_status, convert_trade_flow, convert_limit_place_order,
    convert_limit_cancel_order, convert_limit_query_open_orders,
    ConvertPair, ConvertAssetInfo, ConvertQuote, ConvertAcceptQuote, ConvertOrderStatus,
    ConvertTradeFlow, ConvertTradeFlowResponse, ConvertLimitOrder, ConvertLimitPlaceOrderResponse,
    WALLET_SPOT, WALLET_FUNDING, WALLET_EARN, WALLET_SPOT_FUNDING, WALLET_FUNDING_EARN,
    WALLET_SPOT_EARN, WALLET_SPOT_FUNDING_EARN,
    VALID_TIME_10S, VALID_TIME_30S, VALID_TIME_1M, VALID_TIME_2M,
    EXPIRED_1D, EXPIRED_3D, EXPIRED_7D, EXPIRED_30D

# --- Constants ---

"""Spot wallet type for Convert API"""
const WALLET_SPOT = "SPOT"

"""Funding wallet type for Convert API"""
const WALLET_FUNDING = "FUNDING"

"""Earn wallet type for Convert API"""
const WALLET_EARN = "EARN"

"""Combined: Spot + Funding wallets"""
const WALLET_SPOT_FUNDING = "SPOT_FUNDING"

"""Combined: Funding + Earn wallets"""
const WALLET_FUNDING_EARN = "FUNDING_EARN"

"""Combined: Spot + Earn wallets"""
const WALLET_SPOT_EARN = "SPOT_EARN"

"""Combined: Spot + Funding + Earn wallets"""
const WALLET_SPOT_FUNDING_EARN = "SPOT_FUNDING_EARN"

"""Quote validity time: 10 seconds"""
const VALID_TIME_10S = "10s"

"""Quote validity time: 30 seconds"""
const VALID_TIME_30S = "30s"

"""Quote validity time: 1 minute"""
const VALID_TIME_1M = "1m"

"""Quote validity time: 2 minutes"""
const VALID_TIME_2M = "2m"

"""Limit order expiration: 1 day"""
const EXPIRED_1D = "1_D"

"""Limit order expiration: 3 days"""
const EXPIRED_3D = "3_D"

"""Limit order expiration: 7 days"""
const EXPIRED_7D = "7_D"

"""Limit order expiration: 30 days"""
const EXPIRED_30D = "30_D"

# --- Structs ---

"""
Convert trading pair information from exchangeInfo endpoint.

# Fields
- `fromAsset::String`: Source asset symbol
- `toAsset::String`: Target asset symbol
- `fromAssetMinAmount::String`: Minimum amount for source asset
- `fromAssetMaxAmount::String`: Maximum amount for source asset
- `toAssetMinAmount::String`: Minimum amount for target asset
- `toAssetMaxAmount::String`: Maximum amount for target asset
"""
struct ConvertPair
    fromAsset::String
    toAsset::String
    fromAssetMinAmount::String
    fromAssetMaxAmount::String
    toAssetMinAmount::String
    toAssetMaxAmount::String
end
StructTypes.StructType(::Type{ConvertPair}) = StructTypes.Struct()

function Base.show(io::IO, p::ConvertPair)
    print(io, "ConvertPair: ", p.fromAsset, " → ", p.toAsset,
        " (", p.fromAssetMinAmount, "-", p.fromAssetMaxAmount, " → ", p.toAssetMinAmount, "-", p.toAssetMaxAmount, ")")
end

"""
Asset precision information for Convert API.

# Fields
- `asset::String`: Asset symbol
- `fraction::Int`: Number of decimal places for this asset
"""
struct ConvertAssetInfo
    asset::String
    fraction::Int
end
StructTypes.StructType(::Type{ConvertAssetInfo}) = StructTypes.Struct()

function Base.show(io::IO, a::ConvertAssetInfo)
    print(io, "ConvertAssetInfo: ", a.asset, " (", a.fraction, " decimals)")
end

"""
Quote response from getQuote endpoint.

# Fields
- `quoteId::String`: Unique quote identifier (use with acceptQuote)
- `ratio::String`: Conversion ratio (toAsset/fromAsset)
- `inverseRatio::String`: Inverse conversion ratio (fromAsset/toAsset)
- `validTimestamp::DateTime`: Quote expiration time
- `toAmount::String`: Amount to receive after conversion
- `fromAmount::String`: Amount to be debited for conversion
"""
struct ConvertQuote
    quoteId::String
    ratio::String
    inverseRatio::String
    validTimestamp::DateTime
    toAmount::String
    fromAmount::String
end
StructTypes.StructType(::Type{ConvertQuote}) = StructTypes.CustomStruct()
StructTypes.construct(::Type{ConvertQuote}, obj) = ConvertQuote(
    obj["quoteId"],
    obj["ratio"],
    obj["inverseRatio"],
    unix2datetime(obj["validTimestamp"] / 1000),
    obj["toAmount"],
    obj["fromAmount"]
)

function Base.show(io::IO, q::ConvertQuote)
    println(io, "ConvertQuote:")
    println(io, "  Quote ID: ", q.quoteId)
    println(io, "  Ratio: ", q.ratio, " (inverse: ", q.inverseRatio, ")")
    println(io, "  From: ", q.fromAmount, " → To: ", q.toAmount)
    print(io, "  Valid until: ", q.validTimestamp)
end

"""
Response from acceptQuote endpoint.

# Fields
- `orderId::String`: Order identifier
- `createTime::DateTime`: Order creation time
- `orderStatus::String`: Order status (PROCESS, ACCEPT_SUCCESS, SUCCESS, FAIL)
"""
struct ConvertAcceptQuote
    orderId::String
    createTime::DateTime
    orderStatus::String
end
StructTypes.StructType(::Type{ConvertAcceptQuote}) = StructTypes.CustomStruct()
StructTypes.construct(::Type{ConvertAcceptQuote}, obj) = ConvertAcceptQuote(
    obj["orderId"],
    unix2datetime(obj["createTime"] / 1000),
    obj["orderStatus"]
)

function Base.show(io::IO, a::ConvertAcceptQuote)
    print(io, "ConvertAcceptQuote: Order ", a.orderId, " - ", a.orderStatus, " at ", a.createTime)
end

"""
Order status response from orderStatus endpoint.

# Fields
- `orderId::Int64`: Order identifier
- `orderStatus::String`: Order status (PROCESS, ACCEPT_SUCCESS, SUCCESS, FAIL)
- `fromAsset::String`: Source asset symbol
- `fromAmount::String`: Amount debited
- `toAsset::String`: Target asset symbol
- `toAmount::String`: Amount credited
- `ratio::String`: Conversion ratio
- `inverseRatio::String`: Inverse conversion ratio
- `createTime::DateTime`: Order creation time
"""
struct ConvertOrderStatus
    orderId::Int64
    orderStatus::String
    fromAsset::String
    fromAmount::String
    toAsset::String
    toAmount::String
    ratio::String
    inverseRatio::String
    createTime::DateTime
end
StructTypes.StructType(::Type{ConvertOrderStatus}) = StructTypes.CustomStruct()
StructTypes.construct(::Type{ConvertOrderStatus}, obj) = ConvertOrderStatus(
    obj["orderId"],
    obj["orderStatus"],
    obj["fromAsset"],
    obj["fromAmount"],
    obj["toAsset"],
    obj["toAmount"],
    obj["ratio"],
    obj["inverseRatio"],
    unix2datetime(obj["createTime"] / 1000)
)

function Base.show(io::IO, s::ConvertOrderStatus)
    println(io, "ConvertOrderStatus:")
    println(io, "  Order ID: ", s.orderId, " (", s.orderStatus, ")")
    println(io, "  ", s.fromAsset, " ", s.fromAmount, " → ", s.toAsset, " ", s.toAmount)
    println(io, "  Ratio: ", s.ratio)
    print(io, "  Created: ", s.createTime)
end

"""
Trade flow record from tradeFlow endpoint.

# Fields
- `quoteId::String`: Quote identifier
- `orderId::Int64`: Order identifier
- `orderStatus::String`: Order status
- `fromAsset::String`: Source asset symbol
- `fromAmount::String`: Amount debited
- `toAsset::String`: Target asset symbol
- `toAmount::String`: Amount credited
- `ratio::String`: Conversion ratio
- `inverseRatio::String`: Inverse conversion ratio
- `createTime::DateTime`: Order creation time
"""
struct ConvertTradeFlow
    quoteId::String
    orderId::Int64
    orderStatus::String
    fromAsset::String
    fromAmount::String
    toAsset::String
    toAmount::String
    ratio::String
    inverseRatio::String
    createTime::DateTime
end
StructTypes.StructType(::Type{ConvertTradeFlow}) = StructTypes.CustomStruct()
StructTypes.construct(::Type{ConvertTradeFlow}, obj) = ConvertTradeFlow(
    obj["quoteId"],
    obj["orderId"],
    obj["orderStatus"],
    obj["fromAsset"],
    obj["fromAmount"],
    obj["toAsset"],
    obj["toAmount"],
    obj["ratio"],
    obj["inverseRatio"],
    unix2datetime(obj["createTime"] / 1000)
)

function Base.show(io::IO, t::ConvertTradeFlow)
    print(io, "ConvertTradeFlow: ", t.orderId, " ", t.fromAsset, " ", t.fromAmount, " → ", t.toAsset, " ", t.toAmount, " (", t.orderStatus, ")")
end

"""
Trade flow response containing list of trades and pagination info.

# Fields
- `list::Vector{ConvertTradeFlow}`: List of trade flow records
- `startTime::DateTime`: Query start time
- `endTime::DateTime`: Query end time
- `limit::Int`: Number of records returned
- `moreData::Bool`: Whether more data is available
"""
struct ConvertTradeFlowResponse
    list::Vector{ConvertTradeFlow}
    startTime::DateTime
    endTime::DateTime
    limit::Int
    moreData::Bool
end
StructTypes.StructType(::Type{ConvertTradeFlowResponse}) = StructTypes.CustomStruct()
StructTypes.construct(::Type{ConvertTradeFlowResponse}, obj) = ConvertTradeFlowResponse(
    [StructTypes.construct(ConvertTradeFlow, item) for item in obj["list"]],
    unix2datetime(obj["startTime"] / 1000),
    unix2datetime(obj["endTime"] / 1000),
    obj["limit"],
    obj["moreData"]
)

function Base.show(io::IO, r::ConvertTradeFlowResponse)
    println(io, "ConvertTradeFlowResponse:")
    println(io, "  Time range: ", r.startTime, " → ", r.endTime)
    println(io, "  Records: ", length(r.list), " (limit: ", r.limit, ", more: ", r.moreData, ")")
    for t in r.list
        println(io, "    • ", t)
    end
end

"""
Limit order for Convert API (from queryOpenOrders endpoint).

# Fields
- `quoteId::String`: Quote identifier
- `orderId::Int64`: Order identifier
- `orderStatus::String`: Order status
- `fromAsset::String`: Source asset symbol
- `fromAmount::String`: Amount to debit
- `toAsset::String`: Target asset symbol
- `toAmount::String`: Amount to credit
- `ratio::String`: Conversion ratio
- `inverseRatio::String`: Inverse conversion ratio
- `createTime::DateTime`: Order creation time
- `expiredTimestamp::DateTime`: Order expiration time
"""
struct ConvertLimitOrder
    quoteId::String
    orderId::Int64
    orderStatus::String
    fromAsset::String
    fromAmount::String
    toAsset::String
    toAmount::String
    ratio::String
    inverseRatio::String
    createTime::DateTime
    expiredTimestamp::DateTime
end
StructTypes.StructType(::Type{ConvertLimitOrder}) = StructTypes.CustomStruct()
StructTypes.construct(::Type{ConvertLimitOrder}, obj) = ConvertLimitOrder(
    obj["quoteId"],
    obj["orderId"],
    obj["orderStatus"],
    obj["fromAsset"],
    obj["fromAmount"],
    obj["toAsset"],
    obj["toAmount"],
    obj["ratio"],
    obj["inverseRatio"],
    unix2datetime(obj["createTime"] / 1000),
    unix2datetime(obj["expiredTimestamp"] / 1000)
)

function Base.show(io::IO, o::ConvertLimitOrder)
    println(io, "ConvertLimitOrder:")
    println(io, "  Quote ID: ", o.quoteId)
    println(io, "  Order ID: ", o.orderId, " (", o.orderStatus, ")")
    println(io, "  ", o.fromAsset, " ", o.fromAmount, " → ", o.toAsset, " ", o.toAmount)
    println(io, "  Ratio: ", o.ratio)
    println(io, "  Created: ", o.createTime)
    print(io, "  Expires: ", o.expiredTimestamp)
end

"""
Response from limit order placement endpoint.

# Fields
- `orderId::Int64`: Order identifier
- `status::String`: Order status
"""
struct ConvertLimitPlaceOrderResponse
    orderId::Int64
    status::String
end
StructTypes.StructType(::Type{ConvertLimitPlaceOrderResponse}) = StructTypes.Struct()

function Base.show(io::IO, r::ConvertLimitPlaceOrderResponse)
    print(io, "ConvertLimitPlaceOrderResponse: Order ", r.orderId, " - ", r.status)
end

# --- Convert API Functions ---

"""
    convert_exchange_info(client::RESTClient; from_asset::String="", to_asset::String="")

Query for all convertible token pairs and the tokens' respective upper/lower limits.

Weight: 3000 (IP)

# Arguments
- `client::RESTClient`: REST API client
- `from_asset::String`: Filter by source asset (optional)
- `to_asset::String`: Filter by target asset (optional)

Either or both of `from_asset` and `to_asset` should be provided.
If neither is supplied, only partial token pairs will be returned.

# Returns
- `Vector{ConvertPair}`: List of convertible trading pairs with min/max amounts

# Example
```julia
# Get convertible pairs from BTC
pairs = convert_exchange_info(client; from_asset="BTC")

# Get pairs that can convert to USDT
usdt_pairs = convert_exchange_info(client; to_asset="USDT")

# Get a specific pair
pair = convert_exchange_info(client; from_asset="BTC", to_asset="USDT")
```
"""
function convert_exchange_info(client::RESTClient; from_asset::String="", to_asset::String="")
    params = Dict{String,Any}()
    if !isempty(from_asset)
        params["fromAsset"] = from_asset
    end
    if !isempty(to_asset)
        params["toAsset"] = to_asset
    end
    response = make_request(client, "GET", "/sapi/v1/convert/exchangeInfo"; params=params)
    return [StructTypes.constructfrom(ConvertPair, item) for item in response]
end

"""
    convert_asset_info(client::RESTClient; assets::Vector{String}=String[])

Query for supported asset's precision information. (USER_DATA)

Weight: 100 (IP)

# Arguments
- `client::RESTClient`: REST API client
- `assets::Vector{String}`: List of assets to query (optional, returns all if empty)

# Returns
- `Vector{ConvertAssetInfo}`: List of asset precision information

# Example
```julia
# Get precision info for all assets
all_info = convert_asset_info(client)

# Get precision info for specific assets
info = convert_asset_info(client; assets=["BTC", "ETH", "USDT"])
```
"""
function convert_asset_info(client::RESTClient; assets::Vector{String}=String[])
    params = Dict{String,Any}()
    if !isempty(assets)
        params["assets"] = JSON3.write(assets)
    end
    response = make_request(client, "GET", "/sapi/v1/convert/assetInfo"; params=params, signed=true)
    return to_struct(Vector{ConvertAssetInfo}, response)
end

"""
    convert_get_quote(client::RESTClient, from_asset::String, to_asset::String;
                      from_amount=nothing, to_amount=nothing,
                      wallet_type::String=WALLET_SPOT, validity_time::String=VALID_TIME_10S)

Request a quote for the requested token pairs. (USER_DATA)

Weight: 200 (UID)

# Arguments
- `client::RESTClient`: REST API client
- `from_asset::String`: Source asset symbol (e.g., "BTC")
- `to_asset::String`: Target asset symbol (e.g., "USDT")
- `from_amount::Union{Float64,Nothing}`: Amount to convert FROM (mutually exclusive with `to_amount`)
- `to_amount::Union{Float64,Nothing}`: Amount to receive TO (mutually exclusive with `from_amount`)
- `wallet_type::String`: Wallet type. Options:
  - Single: `WALLET_SPOT` (default), `WALLET_FUNDING`, `WALLET_EARN`
  - Combined: `WALLET_SPOT_FUNDING`, `WALLET_FUNDING_EARN`, `WALLET_SPOT_EARN`, `WALLET_SPOT_FUNDING_EARN`
- `validity_time::String`: Quote validity time - `VALID_TIME_10S` (default), `VALID_TIME_30S`,
  `VALID_TIME_1M`, or `VALID_TIME_2M`

# Returns
- `ConvertQuote`: Quote with conversion rates and amounts. The `quoteId` is only returned
  if you have sufficient funds to complete the conversion.

# Example
```julia
# Get quote to convert 0.1 BTC to USDT
quote = convert_get_quote(client, "BTC", "USDT"; from_amount=0.1)

# Get quote to receive exactly 1000 USDT from BTC
quote = convert_get_quote(client, "BTC", "USDT"; to_amount=1000.0)

# Get quote with longer validity
quote = convert_get_quote(client, "BTC", "USDT"; from_amount=0.1, validity_time=VALID_TIME_1M)

# Use combined spot + funding wallet
quote = convert_get_quote(client, "BTC", "USDT"; from_amount=0.1, wallet_type=WALLET_SPOT_FUNDING)
```

# Note
Either `from_amount` or `to_amount` must be specified, but not both.
"""
function convert_get_quote(
    client::RESTClient, from_asset::String, to_asset::String;
    from_amount::Union{Float64,Nothing}=nothing,
    to_amount::Union{Float64,Nothing}=nothing,
    wallet_type::String=WALLET_SPOT,
    validity_time::String=VALID_TIME_10S
)
    params = Dict{String,Any}(
        "fromAsset" => from_asset,
        "toAsset" => to_asset,
        "walletType" => wallet_type,
        "validTime" => validity_time
    )

    if !isnothing(from_amount)
        params["fromAmount"] = from_amount
    elseif !isnothing(to_amount)
        params["toAmount"] = to_amount
    else
        throw(ArgumentError("Either from_amount or to_amount must be specified"))
    end

    response = make_request(client, "POST", "/sapi/v1/convert/getQuote"; params=params, signed=true)
    return to_struct(ConvertQuote, response)
end

"""
    convert_accept_quote(client::RESTClient, quote_id::String)

Accept the offered quote by quote ID to execute the conversion.

Weight: 500 (UID)

# Arguments
- `client::RESTClient`: REST API client
- `quote_id::String`: Quote ID from `convert_get_quote` response

# Returns
- `ConvertAcceptQuote`: Contains order ID, creation time, and status

# Order Status Values
- `PROCESS`: Order is being processed
- `ACCEPT_SUCCESS`: Quote accepted successfully
- `SUCCESS`: Conversion completed
- `FAIL`: Conversion failed

# Example
```julia
# Get a quote first
quote = convert_get_quote(client, "BTC", "USDT"; from_amount=0.1)

# Accept the quote to execute conversion
result = convert_accept_quote(client, quote.quoteId)
println("Order ID: ", result.orderId)
println("Status: ", result.orderStatus)
```

# Note
The quote must be accepted before it expires (check `validTimestamp` in the quote).
"""
function convert_accept_quote(client::RESTClient, quote_id::String)
    params = Dict{String,Any}("quoteId" => quote_id)
    response = make_request(client, "POST", "/sapi/v1/convert/acceptQuote"; params=params, signed=true)
    return to_struct(ConvertAcceptQuote, response)
end

"""
    convert_order_status(client::RESTClient; order_id::String="", quote_id::String="")

Query order status by order ID or quote ID. (USER_DATA)

Weight: 100 (UID)

# Arguments
- `client::RESTClient`: REST API client
- `order_id::String`: Order ID (optional, mutually exclusive with `quote_id`)
- `quote_id::String`: Quote ID (optional, mutually exclusive with `order_id`)

# Returns
- `ConvertOrderStatus`: Full order details including amounts and conversion ratio

# Example
```julia
# Query by order ID
status = convert_order_status(client; order_id="933256278426274426")

# Query by quote ID
status = convert_order_status(client; quote_id="f3b91c525b2644c7bc1e1cd31b6e1aa6")
```

# Note
Either `order_id` or `quote_id` must be provided, but not both.
"""
function convert_order_status(client::RESTClient; order_id::String="", quote_id::String="")
    params = Dict{String,Any}()

    if !isempty(order_id)
        params["orderId"] = order_id
    elseif !isempty(quote_id)
        params["quoteId"] = quote_id
    else
        throw(ArgumentError("Either order_id or quote_id must be specified"))
    end

    response = make_request(client, "GET", "/sapi/v1/convert/orderStatus"; params=params, signed=true)
    return to_struct(ConvertOrderStatus, response)
end

"""
    convert_trade_flow(client::RESTClient, start_time::Int, end_time::Int;
                       limit::Int=100)

Query convert trade history records. (USER_DATA)

Weight: 3000 (UID)

# Arguments
- `client::RESTClient`: REST API client
- `start_time::Int`: Start time in milliseconds (required)
- `end_time::Int`: End time in milliseconds (required)
- `limit::Int`: Number of records to return (1-1000, default 100)

# Returns
- `ConvertTradeFlowResponse`: Contains list of trades and pagination info

# Constraints
- The max interval between `start_time` and `end_time` is **30 days**

# Example
```julia
using Dates

# Get trade history for the last 7 days
end_time = Int(datetime2unix(now(UTC)) * 1000)
start_time = Int(datetime2unix(now(UTC) - Day(7)) * 1000)
history = convert_trade_flow(client, start_time, end_time)

# Get trade history with larger limit
history = convert_trade_flow(client, start_time, end_time; limit=500)

# Check for more data
if history.moreData
    # Query next page with adjusted time range
end
```
"""
function convert_trade_flow(
    client::RESTClient,
    start_time::Int,
    end_time::Int;
    limit::Int=100
)
    if limit < 1 || limit > 1000
        throw(ArgumentError("Limit must be between 1 and 1000"))
    end

    params = Dict{String,Any}(
        "startTime" => start_time,
        "endTime" => end_time,
        "limit" => limit
    )

    response = make_request(client, "GET", "/sapi/v1/convert/tradeFlow"; params=params, signed=true)
    return to_struct(ConvertTradeFlowResponse, response)
end

"""
    convert_limit_place_order(client::RESTClient, base_asset::String, quote_asset::String,
                              side::String, limit_price::Float64, expired_type::String;
                              base_amount::Union{Float64,Nothing}=nothing,
                              quote_amount::Union{Float64,Nothing}=nothing,
                              wallet_type::String=WALLET_SPOT)

Place a convert limit order. (TRADE)

Weight: 500 (UID)

# Arguments
- `client::RESTClient`: REST API client
- `base_asset::String`: Base asset symbol (e.g., "BTC")
- `quote_asset::String`: Quote asset symbol (e.g., "USDT")
- `side::String`: Order side ("BUY" or "SELL")
- `limit_price::Float64`: Target conversion price
- `expired_type::String`: Order expiration type - `EXPIRED_1D`, `EXPIRED_3D`, `EXPIRED_7D`, or `EXPIRED_30D`
- `base_amount::Union{Float64,Nothing}`: Amount of base asset (mutually exclusive with `quote_amount`)
- `quote_amount::Union{Float64,Nothing}`: Amount of quote asset (mutually exclusive with `base_amount`)
- `wallet_type::String`: Wallet type - `WALLET_SPOT` (default) or `WALLET_FUNDING`

# Returns
- `ConvertLimitPlaceOrderResponse`: Contains order ID and status

# Example
```julia
# Place a limit order to buy 0.1 BTC at 40000 USDT, expires in 7 days
order = convert_limit_place_order(client, "BTC", "USDT", "BUY", 40000.0, EXPIRED_7D;
    base_amount=0.1)

# Place a limit order with quote amount
order = convert_limit_place_order(client, "BTC", "USDT", "BUY", 40000.0, EXPIRED_1D;
    quote_amount=4000.0)
```

# Note
Either `base_amount` or `quote_amount` must be specified, but not both.
"""
function convert_limit_place_order(
    client::RESTClient,
    base_asset::String,
    quote_asset::String,
    side::String,
    limit_price::Float64,
    expired_type::String;
    base_amount::Union{Float64,Nothing}=nothing,
    quote_amount::Union{Float64,Nothing}=nothing,
    wallet_type::String=WALLET_SPOT
)
    # Validate side
    side = uppercase(side)
    if !(side in ("BUY", "SELL"))
        throw(ArgumentError("Side must be either BUY or SELL"))
    end

    # Validate expired type
    if !(expired_type in (EXPIRED_1D, EXPIRED_3D, EXPIRED_7D, EXPIRED_30D))
        throw(ArgumentError("expiredType must be one of: 1_D, 3_D, 7_D, 30_D"))
    end

    params = Dict{String,Any}(
        "baseAsset" => base_asset,
        "quoteAsset" => quote_asset,
        "side" => side,
        "limitPrice" => limit_price,
        "expiredType" => expired_type,
        "walletType" => wallet_type
    )

    if !isnothing(base_amount)
        params["baseAmount"] = base_amount
    elseif !isnothing(quote_amount)
        params["quoteAmount"] = quote_amount
    else
        throw(ArgumentError("Either base_amount or quote_amount must be specified"))
    end

    response = make_request(client, "POST", "/sapi/v1/convert/limit/placeOrder"; params=params, signed=true)
    return to_struct(ConvertLimitPlaceOrderResponse, response)
end

"""
    convert_limit_cancel_order(client::RESTClient, order_id::Int64)

Cancel a convert limit order. (TRADE)

Weight: 200 (UID)

# Arguments
- `client::RESTClient`: REST API client
- `order_id::Int64`: Order ID to cancel

# Returns
- Response indicating cancellation status

# Example
```julia
# Cancel a limit order
result = convert_limit_cancel_order(client, 933256278426274426)
```
"""
function convert_limit_cancel_order(client::RESTClient, order_id::Int64)
    params = Dict{String,Any}("orderId" => order_id)
    return make_request(client, "POST", "/sapi/v1/convert/limit/cancelOrder"; params=params, signed=true)
end

"""
    convert_limit_query_open_orders(client::RESTClient)

Query all convert limit open orders. (USER_DATA)

Weight: 3000 (UID)

# Arguments
- `client::RESTClient`: REST API client

# Returns
- `Vector{ConvertLimitOrder}`: List of open limit orders

# Example
```julia
# Get all open limit orders
orders = convert_limit_query_open_orders(client)
for o in orders
    println("Order \$(o.orderId): \$(o.fromAsset) -> \$(o.toAsset) at \$(o.ratio)")
end
```
"""
function convert_limit_query_open_orders(client::RESTClient)
    response = make_request(client, "GET", "/sapi/v1/convert/limit/queryOpenOrders"; signed=true)
    return [StructTypes.construct(ConvertLimitOrder, item) for item in response]
end

end # module Convert
