module Account

    using JSON3, StructTypes, DataFrames, Dates
    using ..RESTAPI
    
    export get_account_info, get_account_status, get_api_trading_status,
        get_api_key_permission, get_withdraw_history, get_deposit_history,
        get_deposit_address, withdraw, get_asset_detail, get_trade_fee,
        dust_transfer, get_dust_log, AccountInfo, Balance, CommissionRates,
        get_my_trades, get_rate_limit_order, get_my_prevented_matches,
        get_my_allocations, get_account_commission_rates, get_order_amendments,
        Trade, RateLimit, PreventedMatch, Allocation, CommissionRatesDetails,
        Discount, OrderAmendment

    # Existing Structs
    struct CommissionRates
        maker::String
        taker::String
        buyer::String
        seller::String
    end
    StructTypes.StructType(::Type{CommissionRates}) = StructTypes.Struct()

    struct Balance
        asset::String
        free::Float64
        locked::Float64
    end
    StructTypes.StructType(::Type{Balance}) = StructTypes.CustomStruct()
    StructTypes.lower(b::Balance) = (asset=b.asset, free=string(b.free), locked=string(b.locked))
    StructTypes.construct(::Type{Balance}, obj) = Balance(obj["asset"], parse(Float64, obj["free"]), parse(Float64, obj["locked"]))

    struct AccountInfo
        makerCommission::Int
        takerCommission::Int
        buyerCommission::Int
        sellerCommission::Int
        commissionRates::CommissionRates
        canTrade::Bool
        canWithdraw::Bool
        canDeposit::Bool
        brokered::Bool
        requireSelfTradePrevention::Bool
        preventSor::Bool
        updateTime::Int64
        accountType::String
        balances::Vector{Balance}
        permissions::Vector{String}
        uid::Int64
    end
    StructTypes.StructType(::Type{AccountInfo}) = StructTypes.Struct()

    # New Structs
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
        time::Int64
        isBuyer::Bool
        isMaker::Bool
        isBestMatch::Bool
    end
    StructTypes.StructType(::Type{Trade}) = StructTypes.Struct()

    struct RateLimit
        rateLimitType::String
        interval::String
        intervalNum::Int
        limit::Int
        count::Int
    end
    StructTypes.StructType(::Type{RateLimit}) = StructTypes.Struct()

    struct PreventedMatch
        symbol::String
        preventedMatchId::Int64
        takerOrderId::Int64
        makerOrderId::Int64
        tradeGroupId::Int64
        selfTradePreventionMode::String
        price::String
        makerPreventedQuantity::String
        transactTime::Int64
    end
    StructTypes.StructType(::Type{PreventedMatch}) = StructTypes.Struct()

    struct Allocation
        symbol::String
        allocationId::Int64
        allocationType::String
        orderId::Int64
        orderListId::Int64
        price::String
        qty::String
        quoteQty::String
        commission::String
        commissionAsset::String
        time::Int64
        isBuyer::Bool
        isMaker::Bool
        isAllocator::Bool
    end
    StructTypes.StructType(::Type{Allocation}) = StructTypes.Struct()

    struct Discount
        enabledForAccount::Bool
        enabledForSymbol::Bool
        discountAsset::String
        discount::String
    end
    StructTypes.StructType(::Type{Discount}) = StructTypes.Struct()

    struct CommissionRatesDetails
        symbol::String
        standardCommission::CommissionRates
        specialCommission::CommissionRates
        taxCommission::CommissionRates
        discount::Discount
    end
    StructTypes.StructType(::Type{CommissionRatesDetails}) = StructTypes.Struct()

    struct OrderAmendment
        symbol::String
        orderId::Int64
        executionId::Int64
        origClientOrderId::String
        newClientOrderId::String
        origQty::String
        newQty::String
        time::Int64
    end
    StructTypes.StructType(::Type{OrderAmendment}) = StructTypes.Struct()

    # Show method for AccountInfo
    function Base.show(io::IO, ::MIME"text/plain", info::AccountInfo)
        println(io, "AccountInfo:")
        println(io, "  UID: ", info.uid)
        println(io, "  Account Type: ", info.accountType)
        println(io, "  Update Time: ", unix2datetime(info.updateTime / 1000) + Hour(8))
        println(io, "  Brokered: ", info.brokered)
        println(io, "\nPermissions: ", join(info.permissions, ", "))

        println(io, "\nTrading Status:")
        println(io, "  Can Trade: ", info.canTrade)
        println(io, "  Can Withdraw: ", info.canWithdraw)
        println(io, "  Can Deposit: ", info.canDeposit)

        println(io, "\nCommission Rates:")
        println(io, "  Maker: ", info.commissionRates.maker)
        println(io, "  Taker: ", info.commissionRates.taker)
        println(io, "  Buyer: ", info.commissionRates.buyer)
        println(io, "  Seller: ", info.commissionRates.seller)

        balances_df = DataFrame(info.balances)
        non_zero_balances = filter(row -> row.free > 0 || row.locked > 0, balances_df)

        if !isempty(non_zero_balances)
            println(io, "\nBalances:")
            show(io, non_zero_balances)
        else
            println(io, "\nNo non-zero balances.")
        end
    end

    # Existing Functions
    function get_account_info(client::RESTClient)
        response = make_request(client, "GET", "/api/v3/account"; signed=true)
        return JSON3.read(JSON3.write(response), AccountInfo)
    end

    function get_account_status(client::RESTClient)
        return make_request(client, "GET", "/sapi/v1/account/status"; signed=true)
    end

    function get_api_trading_status(client::RESTClient)
        return make_request(client, "GET", "/sapi/v1/account/apiTradingStatus"; signed=true)
    end

    function get_api_key_permission(client::RESTClient)
        return make_request(client, "GET", "/sapi/v1/account/apiRestrictions"; signed=true)
    end

    function get_withdraw_history(
        client::RESTClient;
        coin::String="",
        withdraw_order_id::String="",
        status::Union{Int,Nothing}=nothing,
        offset::Int=0,
        limit::Int=1000,
        start_time::Int=0,
        end_time::Int=0
    )

        params = Dict{String,Any}(
            "offset" => offset,
            "limit" => limit
        )

        if !isempty(coin)
            params["coin"] = coin
        end
        if !isempty(withdraw_order_id)
            params["withdrawOrderId"] = withdraw_order_id
        end
        if !isnothing(status)
            params["status"] = status
        end
        if start_time > 0
            params["startTime"] = start_time
        end
        if end_time > 0
            params["endTime"] = end_time
        end

        return make_request(client, "GET", "/sapi/v1/capital/withdraw/history"; params=params, signed=true)
    end

    function get_deposit_history(
        client::RESTClient;
        coin::String="",
        status::Union{Int,Nothing}=nothing,
        offset::Int=0,
        limit::Int=1000,
        start_time::Int=0,
        end_time::Int=0)

        params = Dict{String,Any}(
            "offset" => offset,
            "limit" => limit
        )

        if !isempty(coin)
            params["coin"] = coin
        end
        if !isnothing(status)
            params["status"] = status
        end
        if start_time > 0
            params["startTime"] = start_time
        end
        if end_time > 0
            params["endTime"] = end_time
        end

        return make_request(client, "GET", "/sapi/v1/capital/deposit/hisrec"; params=params, signed=true)
    end

    function get_deposit_address(client::RESTClient, coin::String; network::String="")
        params = Dict{String,Any}("coin" => coin)
        if !isempty(network)
            params["network"] = network
        end
        return make_request(client, "GET", "/sapi/v1/capital/deposit/address"; params=params, signed=true)
    end

    function withdraw(
        client::RESTClient, coin::String, address::String, amount::Float64;
        address_tag::String="", network::String="", name::String="",
        wallet_type::Union{Int,Nothing}=nothing)

        params = Dict{String,Any}(
            "coin" => coin,
            "address" => address,
            "amount" => amount
        )

        if !isempty(address_tag)
            params["addressTag"] = address_tag
        end
        if !isempty(network)
            params["network"] = network
        end
        if !isempty(name)
            params["name"] = name
        end
        if !isnothing(wallet_type)
            params["walletType"] = wallet_type
        end

        return make_request(client, "POST", "/sapi/v1/capital/withdraw/apply"; params=params, signed=true)
    end

    function get_asset_detail(client::RESTClient; asset::String="")
        params = Dict{String,Any}()
        if !isempty(asset)
            params["asset"] = asset
        end
        return make_request(client, "GET", "/sapi/v1/asset/assetDetail"; params=params, signed=true)
    end

    function get_trade_fee(client::RESTClient; symbol::String="")
        params = Dict{String,Any}()
        if !isempty(symbol)
            params["symbol"] = symbol
        end
        return make_request(client, "GET", "/sapi/v1/asset/tradeFee"; params=params, signed=true)
    end

    function dust_transfer(client::RESTClient, assets::Vector{String})
        if isempty(assets)
            throw(ArgumentError("Assets list cannot be empty"))
        end

        params = Dict{String,Any}("asset" => join(assets, ","))
        return make_request(client, "POST", "/sapi/v1/asset/dust"; params=params, signed=true)
    end

    function get_dust_log(client::RESTClient; start_time::Int=0, end_time::Int=0)

        params = Dict{String,Any}()
        if start_time > 0
            params["startTime"] = start_time
        end
        if end_time > 0
            params["endTime"] = end_time
        end

        return make_request(client, "GET", "/sapi/v1/asset/dribblet"; params=params, signed=true)
    end

    # New Functions
    function get_my_trades(
        client::RESTClient, symbol::String;
        orderId::Union{Int,Nothing}=nothing,
        startTime::Union{Int,Nothing}=nothing,
        endTime::Union{Int,Nothing}=nothing,
        fromId::Union{Int,Nothing}=nothing,
        limit::Union{Int,Nothing}=nothing
    )
        params = Dict{String,Any}("symbol" => symbol)
        if !isnothing(orderId)
            params["orderId"] = orderId
        end
        if !isnothing(startTime)
            params["startTime"] = startTime
        end
        if !isnothing(endTime)
            params["endTime"] = endTime
        end
        if !isnothing(fromId)
            params["fromId"] = fromId
        end
        if !isnothing(limit)
            params["limit"] = limit
        end
        response = make_request(client, "GET", "/api/v3/myTrades"; params=params, signed=true)
        return JSON3.read(JSON3.write(response), Vector{Trade})
    end

    function get_rate_limit_order(client::RESTClient)
        response = make_request(client, "GET", "/api/v3/rateLimit/order"; signed=true)
        return JSON3.read(JSON3.write(response), Vector{RateLimit})
    end

    function get_my_prevented_matches(client::RESTClient; symbol::String, preventedMatchId::Union{Int,Nothing}=nothing, orderId::Union{Int,Nothing}=nothing, fromPreventedMatchId::Union{Int,Nothing}=nothing, limit::Union{Int,Nothing}=nothing)
        params = Dict{String,Any}("symbol" => symbol)
        if !isnothing(preventedMatchId)
            params["preventedMatchId"] = preventedMatchId
        end
        if !isnothing(orderId)
            params["orderId"] = orderId
        end
        if !isnothing(fromPreventedMatchId)
            params["fromPreventedMatchId"] = fromPreventedMatchId
        end
        if !isnothing(limit)
            params["limit"] = limit
        end
        response = make_request(client, "GET", "/api/v3/myPreventedMatches"; params=params, signed=true)
        return JSON3.read(JSON3.write(response), Vector{PreventedMatch})
    end

    function get_my_allocations(client::RESTClient; symbol::String, startTime::Union{Int,Nothing}=nothing, endTime::Union{Int,Nothing}=nothing, fromAllocationId::Union{Int,Nothing}=nothing, limit::Union{Int,Nothing}=nothing, orderId::Union{Int,Nothing}=nothing)
        params = Dict{String,Any}("symbol" => symbol)
        if !isnothing(startTime)
            params["startTime"] = startTime
        end
        if !isnothing(endTime)
            params["endTime"] = endTime
        end
        if !isnothing(fromAllocationId)
            params["fromAllocationId"] = fromAllocationId
        end
        if !isnothing(limit)
            params["limit"] = limit
        end
        if !isnothing(orderId)
            params["orderId"] = orderId
        end
        response = make_request(client, "GET", "/api/v3/myAllocations"; params=params, signed=true)
        return JSON3.read(JSON3.write(response), Vector{Allocation})
    end

    function get_account_commission_rates(client::RESTClient; symbol::String)
        params = Dict{String,Any}("symbol" => symbol)
        response = make_request(client, "GET", "/api/v3/account/commission"; params=params, signed=true)
        return JSON3.read(JSON3.write(response), CommissionRatesDetails)
    end

    function get_order_amendments(
        client::RESTClient, symbol::String, orderId::Int;
        fromExecutionId::Union{Int,Nothing}=nothing,
        limit::Union{Int,Nothing}=nothing
    )
        params = Dict{String,Any}(
            "symbol" => symbol,
            "orderId" => orderId
        )
        if !isnothing(fromExecutionId)
            params["fromExecutionId"] = fromExecutionId
        end
        if !isnothing(limit)
            params["limit"] = limit
        end
        response = make_request(client, "GET", "/api/v3/order/amendments"; params=params, signed=true)
        return JSON3.read(JSON3.write(response), Vector{OrderAmendment})
    end
end # module Account
