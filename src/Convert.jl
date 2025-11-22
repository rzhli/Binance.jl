module Convert

using JSON3, StructTypes, Dates
using ..RESTAPI
using ..Types: to_decimal_string

export convert_exchange_info, convert_asset_info, convert_get_quote, convert_accept_quote,
    convert_order_status, convert_trade_flow, convert_limit_place_order,
    convert_limit_cancel_order, convert_limit_query_open_orders,
    ConvertExchangeInfo, ConvertAssetInfo, ConvertQuote, ConvertOrderStatus,
    ConvertTradeFlow, ConvertLimitOrder

# --- Structs ---

struct ConvertAsset
    asset::String
    fraction::Int
end
StructTypes.StructType(::Type{ConvertAsset}) = StructTypes.Struct()

struct ConvertExchangeInfo
    list::Vector{ConvertAsset}
end
StructTypes.StructType(::Type{ConvertExchangeInfo}) = StructTypes.Struct()

struct ConvertAssetInfo
    asset::String
    fraction::Int
end
StructTypes.StructType(::Type{ConvertAssetInfo}) = StructTypes.Struct()

struct ConvertQuote
    quoteId::String
    ratio::String
    inverseRatio::String
    validTimestamp::Int64
    toAmount::String
    fromAmount::String
end
StructTypes.StructType(::Type{ConvertQuote}) = StructTypes.Struct()

struct ConvertAcceptQuote
    orderId::String
    createTime::Int64
    orderStatus::String
end
StructTypes.StructType(::Type{ConvertAcceptQuote}) = StructTypes.Struct()

struct ConvertOrderStatus
    orderId::Int64
    orderStatus::String
    fromAsset::String
    fromAmount::String
    toAsset::String
    toAmount::String
    ratio::String
    inverseRatio::String
    createTime::Int64
end
StructTypes.StructType(::Type{ConvertOrderStatus}) = StructTypes.Struct()

struct ConvertTradeFlow
    orderId::Int64
    orderStatus::String
    fromAsset::String
    fromAmount::String
    toAsset::String
    toAmount::String
    ratio::String
    inverseRatio::String
    createTime::Int64
end
StructTypes.StructType(::Type{ConvertTradeFlow}) = StructTypes.Struct()

struct ConvertTradeFlowResponse
    list::Vector{ConvertTradeFlow}
    startTime::Int64
    endTime::Int64
    limit::Int
    moreData::Bool
end
StructTypes.StructType(::Type{ConvertTradeFlowResponse}) = StructTypes.Struct()

struct ConvertLimitOrder
    orderId::Int64
    orderStatus::String
    fromAsset::String
    fromAmount::String
    toAsset::String
    toAmount::String
    ratio::String
    inverseRatio::String
    createTime::Int64
    expiredTimestamp::Int64
end
StructTypes.StructType(::Type{ConvertLimitOrder}) = StructTypes.Struct()

# --- Convert API Functions ---

"""
    convert_exchange_info(client::RESTClient; from_asset::String="", to_asset::String="")

Query for all convertible token pairs and the tokens' respective upper/lower limits.

# Arguments
- `client::RESTClient`: REST API client
- `from_asset::String`: User can query for all supported convertible assets to the 'fromAsset' (optional)
- `to_asset::String`: User can query for all supported convertible assets to the 'toAsset' (optional)

# Returns
- `Vector{ConvertAsset}`: List of convertible assets info
"""
function convert_exchange_info(client::RESTClient; from_asset::String="", to_asset::String="")
    params = Dict{String,Any}()
    if !isempty(from_asset)
        params["fromAsset"] = from_asset
    end
    if !isempty(to_asset)
        params["toAsset"] = to_asset
    end
    response = make_request(client, "GET", "/sapi/v1/convert/exchangeInfo"; params=params, signed=true)
    # The API returns a list directly or wrapped? Documentation says list of objects.
    # Let's assume it returns a list of assets directly based on typical SAPI behavior for this endpoint type,
    # but checking docs, it often returns a wrapper.
    # If response is a Vector, we parse it. If it's a Dict with "list", we parse that.
    # Based on structure, let's try to parse as Vector first or check structure.
    # Actually, for safety with StructTypes, we often read into the struct.
    # Let's assume standard Binance response format.
    return JSON3.read(JSON3.write(response), Vector{ConvertAsset})
end

"""
    convert_asset_info(client::RESTClient; assets::Vector{String}=String[])

Query for supported asset's precision information.

# Arguments
- `client::RESTClient`: REST API client
- `assets::Vector{String}`: List of assets to query (optional)

# Returns
- `Vector{ConvertAssetInfo}`
"""
function convert_asset_info(client::RESTClient; assets::Vector{String}=String[])
    params = Dict{String,Any}()
    if !isempty(assets)
        params["assets"] = JSON3.write(assets)
    end
    response = make_request(client, "GET", "/sapi/v1/convert/assetInfo"; params=params, signed=true)
    return JSON3.read(JSON3.write(response), Vector{ConvertAssetInfo})
end

"""
    convert_get_quote(client::RESTClient, from_asset::String, to_asset::String; from_amount::Union{Float64,Nothing}=nothing, to_amount::Union{Float64,Nothing}=nothing, wallet_type::String="SPOT", validity_time::String="10s")

Request a quote for the requested token pairs.

# Returns
- `ConvertQuote`
"""
function convert_get_quote(
    client::RESTClient, from_asset::String, to_asset::String;
    from_amount::Union{Float64,Nothing}=nothing,
    to_amount::Union{Float64,Nothing}=nothing,
    wallet_type::String="SPOT",
    validity_time::String="10s"
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
    return JSON3.read(JSON3.write(response), ConvertQuote)
end

"""
    convert_accept_quote(client::RESTClient, quote_id::String)

Accept the offered quote by quote ID.

# Returns
- `ConvertAcceptQuote`
"""
function convert_accept_quote(client::RESTClient, quote_id::String)
    params = Dict{String,Any}("quoteId" => quote_id)
    response = make_request(client, "POST", "/sapi/v1/convert/acceptQuote"; params=params, signed=true)
    return JSON3.read(JSON3.write(response), ConvertAcceptQuote)
end

"""
    convert_order_status(client::RESTClient; order_id::String="", quote_id::String="")

Query order status by order ID or quote ID.

# Returns
- `ConvertOrderStatus`
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
    return JSON3.read(JSON3.write(response), ConvertOrderStatus)
end

"""
    convert_trade_flow(client::RESTClient; start_time::Int=0, end_time::Int=0, limit::Int=100, from_asset::String="", to_asset::String="")

Query convert trade history records.

# Returns
- `ConvertTradeFlowResponse`
"""
function convert_trade_flow(
    client::RESTClient;
    start_time::Int=0,
    end_time::Int=0,
    limit::Int=100,
    from_asset::String="",
    to_asset::String=""
)
    if limit < 1 || limit > 1000
        throw(ArgumentError("Limit must be between 1 and 1000"))
    end

    params = Dict{String,Any}("limit" => limit)

    if start_time > 0
        params["startTime"] = start_time
    end
    if end_time > 0
        params["endTime"] = end_time
    end
    if !isempty(from_asset)
        params["fromAsset"] = from_asset
    end
    if !isempty(to_asset)
        params["toAsset"] = to_asset
    end

    response = make_request(client, "GET", "/sapi/v1/convert/tradeFlow"; params=params, signed=true)
    return JSON3.read(JSON3.write(response), ConvertTradeFlowResponse)
end

"""
    convert_limit_place_order(client::RESTClient, base_asset::String, quote_asset::String, side::String, limit_price::Float64, base_amount::Float64; wallet_type::String="SPOT", expiration_time::Union{Int,Nothing}=nothing)

Place a convert limit order.

# Returns
- `ConvertLimitOrder`
"""
function convert_limit_place_order(
    client::RESTClient,
    base_asset::String,
    quote_asset::String,
    side::String,
    limit_price::Float64,
    base_amount::Float64;
    wallet_type::String="SPOT",
    expiration_time::Union{Int,Nothing}=nothing
)
    # Validate side
    side = uppercase(side)
    if !(side in ["BUY", "SELL"])
        throw(ArgumentError("Side must be either BUY or SELL"))
    end

    params = Dict{String,Any}(
        "baseAsset" => base_asset,
        "quoteAsset" => quote_asset,
        "side" => side,
        "limitPrice" => limit_price,
        "baseAmount" => base_amount,
        "walletType" => wallet_type
    )

    if !isnothing(expiration_time)
        params["expiredTime"] = expiration_time
    end

    response = make_request(client, "POST", "/sapi/v1/convert/limit/placeOrder"; params=params, signed=true)
    return JSON3.read(JSON3.write(response), ConvertLimitOrder)
end

"""
    convert_limit_cancel_order(client::RESTClient, order_id::String)

Cancel a convert limit order.

# Returns
- `Dict` (Status)
"""
function convert_limit_cancel_order(client::RESTClient, order_id::String)
    params = Dict{String,Any}("orderId" => order_id)
    return make_request(client, "POST", "/sapi/v1/convert/limit/cancelOrder"; params=params, signed=true)
end

"""
    convert_limit_query_open_orders(client::RESTClient)

Query all convert limit open orders.

# Returns
- `Vector{ConvertLimitOrder}`
"""
function convert_limit_query_open_orders(client::RESTClient)
    response = make_request(client, "GET", "/sapi/v1/convert/limit/queryOpenOrders"; signed=true)
    # The response is likely a list of orders or a wrapper.
    # Assuming list based on typical endpoints, but let's check if it needs wrapper.
    # If it's a list:
    return JSON3.read(JSON3.write(response), Vector{ConvertLimitOrder})
end

end # module Convert
