using Test
using Binance
using BinanceFIX
using BinanceFIX.FIXConstants
using BinanceFIX.FIXAPI
import BinanceFIX.FIXAPI: parse_order_amend_reject

function test_binance_config()
    fix_config = Binance.Config.FIXConfig(
        "127.0.0.1",
        Binance.Config.FIXEndpoint("127.0.0.1", 9000, 9010, 9020),
        Binance.Config.FIXEndpoint("127.0.0.1", 9001, 9011, 9021),
        Binance.Config.FIXEndpoint("127.0.0.1", 9002, 9012, 9022),
    )

    return BinanceConfig(
        "test_api_key", "HMAC_SHA256", "test_secret", "", "",
        false, 30, 60000, "", 5, 5,
        6000, 50, 160000, 300, 300000, true,
        fix_config,
        false, "",
    )
end

@testset "BinanceFIX.jl offline tests" begin
    include("test_fix_logic.jl")
    include("test_list_status.jl")
    include("test_order_amend_reject.jl")
    include("test_sbe_schema11.jl")
end
