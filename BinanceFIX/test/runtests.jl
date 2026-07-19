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

    @testset "Session and SBE optimization regressions" begin
        @test isempty(Symbol[
            name for name in names(BinanceFIX; all=false, imported=false)
            if !isdefined(BinanceFIX, name)
        ])
        fix_callback = BinanceFIX.FIXAPI.SessionCallback(identity)
        sbe_callback = BinanceFIX.FIXSBESession.SBESessionCallback(identity)
        @test fieldtype(typeof(fix_callback), 1) === typeof(identity)
        @test fieldtype(typeof(sbe_callback), 1) === typeof(identity)

        buffer = BinanceFIX.SBEBuffer(32)
        BinanceFIX.write_uint16!(buffer, 0x1234)
        BinanceFIX.write_uint32!(buffer, 0x12345678)
        @test buffer.data[27:32] == UInt8[0x34, 0x12, 0x78, 0x56, 0x34, 0x12]
        @test_throws ArgumentError BinanceFIX.SBEBuffer(0)
        @test_throws ArgumentError BinanceFIX.FIXSBEDecoder.extract_message(zeros(UInt8, 6))
    end
end
