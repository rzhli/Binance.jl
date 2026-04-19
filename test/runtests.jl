using Test
using Binance

@testset "Binance.jl smoke tests" begin

    @testset "Module loads and exports surface types" begin
        @test isdefined(Binance, :RESTClient)
        @test isdefined(Binance, :BinanceConfig)
        @test isdefined(Binance, :OrderBookManager)
        @test isdefined(Binance, :PriceLevel)
        @test isdefined(Binance, :Signature)
    end

    @testset "HMAC signing is deterministic" begin
        signer = Binance.Signature.HmacSigner("test-secret")
        sig1 = Binance.Signature.sign_message(signer, "hello")
        sig2 = Binance.Signature.sign_message(signer, "hello")
        @test sig1 == sig2
        @test length(sig1) == 64  # SHA-256 hex digest length
        @test all(c -> c in "0123456789abcdef", sig1)
    end

    @testset "HMAC signing differs per input" begin
        signer = Binance.Signature.HmacSigner("test-secret")
        @test Binance.Signature.sign_message(signer, "a") !=
              Binance.Signature.sign_message(signer, "b")
    end

    @testset "PriceLevel construction" begin
        lvl = Binance.Types.PriceLevel(100.5, 2.0)
        @test lvl.price == 100.5
        @test lvl.quantity == 2.0
    end

    @testset "OrderBookManager helper types" begin
        pq = Binance.OrderBookManagers.PriceQuantity(100.0, 1.0)
        @test pq.price == 100.0
        @test pq.quantity == 1.0
    end
end
