using Test
using Binance
using Base64
using Dates

const RSA_TEST_PRIVATE_KEY = """
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCObTNMvkPPpR6t
V0ovDJtfQ2nGfAaVUg2dCsgDRaEcYBWZRCfs0WF9Sm1xmcDNsUL0PcAIigjFcMJa
db89N84nC6bepublnMyGvKyng/hoIg6T7henx6ys5aMNSCHjvwSgr3Ytx8PGCgxy
gSmL9/LLq88zMbJeJm+Kx9WQfntnOZf2bqZ4YGPu2cg0ly8LBfnf6kZTfEaKYjRM
fAIz9BtG5CQCWam1UCxtRI/7O3JJElQ9Qe/zuYbFVB9MjFH6K75yh78HtLgRpE20
wS8yEO0AopItSXtab3JAzBvG5VKgZNTDuB3mLHFmeQdWzUtU6f9E2rP2PKkVlIqY
/U8xvp05AgMBAAECggEACCZLdyqz6p/CH50NC6AnC85psQfLwKOPT9scEsPbMip1
Ue3KcwyQDYFCvetUUvC/qgYWhOaRFesb091E8hXNYAKUq8zVDXJpaZRGNNeiUSMR
vnkzNVCBmusQ52OnPMbjVuZzVq9FjoFosOyfGfk4FVthYcaINEbyvvgsSjZSjVdy
b0yD0hJXMV/QGJ1atR8aT4rFlVSxanTuHP0vc8nDWBZJgWB1VRKhRw/ZWnf63/yB
qWWpMdVmhMsJZbiAr/Fx7Xy97jT9BlpNB1iVUoAGgQyM3Mfgcqe9yEIhD/H0hgw9
kbkXbawNkrq0H1s/B3/GV3d5pi9ka9voDDKIEo0gOQKBgQDIzZLutERxW3kjoLeg
UItfE6gFTENm3pcQrjDizAh2FWJStycSuLTT3vW4oYjo1ZeSE9u5+KJ8hY9tfHND
V8XG7aaGjFv7dj9Avy+2eqotUWdzkctssOOGujxKDKnyKgMioCALLiiZBI7MB8JQ
LkLwOugtqZ+3O9XjCZ1JdPp+7wKBgQC1k7L0WMhwepioXxKH3oljmCprnp5nToSD
MnrhFI1cKIVlLqolA2+hn0w3/onlETe+nlFq2o3vv5gJAYefDmMbxfXgfVT3XH+3
g3PvSjgfUi4EtjPV9vKzIyvsWK18lo0jvL1Eo0wfdoM6Nl+a+wsmBzqssDYX/pYc
SfoDepomVwKBgBGpIvcjm7FsniboB75t1xQxomF056iwgxDQgTQxRb08/DzSJvma
jSzlOy9V5bi0sHQEkxq0J3ZUON0kSO7vVVG9rRvAVIa1S7LiHcwq1bTOqA6eEAor
NJew4YSRwJCv6T6uXqMdGCz9HaIMPKbYqsJ+K9V4SbfP52vkeJTxWOa5AoGBAJmJ
2EPoIy2BbT7KjcfYNELEM/KmwPlIGqM591AGafYoyYuipvr/adC3++JJWV8abRHB
m8UIJAc78pqC8aRcrQ+aGGyIbmVwkQqjnFAWaViKzCDt1O0zkUxLDGQhJCn6wEQc
38p/buoX86Uwvy005Nt2N3Y41rT5cQNgxolUja6nAoGAGRpSrHXIkDk+VA/Od8Dr
7ZGGJveziXoGOgqmNvEzh26ycronaRISA4oplbiod66dhl5YpnKCVjYUwCBi5YCD
6W3no5vMEoHRLlVlnZc/MslyReW4xfw5kGjSm/u2e+2pFy+lx28iuTTJwicWobd0
JLwmo704BEagxQ+cuZ7GPR0=
-----END PRIVATE KEY-----
"""

function test_binance_config(; signature_method::String=Binance.Signature.HMAC_SHA256,
    api_secret::String="test-secret", private_key_path::String="", private_key_pass::String="")
    endpoint = Binance.Config.FIXEndpoint("127.0.0.1", 9000, 9010, 9020)
    fix = Binance.Config.FIXConfig("127.0.0.1", endpoint, endpoint, endpoint)

    return Binance.BinanceConfig(
        "test-api-key", signature_method, api_secret, private_key_path, private_key_pass,
        false, 30, 60000, "", 5, 5,
        6000, 50, 160000, 300, 300000, true,
        fix,
        false, "",
    )
end

@testset "Binance.jl smoke tests" begin

    @testset "Module loads and exports surface types" begin
        @test isdefined(Binance, :RESTClient)
        @test isdefined(Binance, :BinanceConfig)
        @test isdefined(Binance, :OrderBookManager)
        @test isdefined(Binance, :PriceLevel)
        @test isdefined(Binance, :Signature)
        @test isdefined(Binance, :RsaSigner)
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

    @testset "RSA signer factory and signing" begin
        tmpdir = mktempdir()
        key_path = joinpath(tmpdir, "rsa-private.pem")
        write(key_path, RSA_TEST_PRIVATE_KEY)

        config = test_binance_config(
            signature_method=Binance.Signature.RSA,
            api_secret="",
            private_key_path=key_path,
        )
        signer = Binance.Signature.create_signer(config)
        message = "symbol=BTCUSDT&timestamp=1"
        signature = Binance.Signature.sign_message(signer, message)

        @test signer isa Binance.Signature.RsaSigner
        @test signature == Binance.Signature.sign_message(signer, message)
        @test length(base64decode(signature)) == 256
    end

    @testset "Ed25519 signing uses fixed test vector" begin
        tmpdir = mktempdir()
        key_path = joinpath(tmpdir, "ed25519-private.pem")
        write(key_path, join((
            "-----BEGIN PRIVATE KEY-----",
            "MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g",
            "-----END PRIVATE KEY-----",
        ), "\n") * "\n")

        signer = Binance.Signature.Ed25519Signer(key_path, "")
        @test Binance.Signature.sign_message(signer, "") ==
              "5VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7rMYeOXAc+bRr0lv18FlbviRlUUFDjnoQCw=="
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

    @testset "OrderBookManager best price cache follows updates" begin
        manager = Binance.OrderBookManager("BTCUSDT", nothing, nothing)
        manager.is_initialized[] = true
        manager.update_id[] = 1

        @test Binance.OrderBookManagers.apply_update!(manager, Dict(
            "U" => 2, "u" => 2,
            "b" => [["100.0", "1.0"], ["101.0", "2.0"]],
            "a" => [["102.0", "1.5"], ["103.0", "1.0"]],
        )) == :applied
        @test Binance.get_best_bid(manager) == (price=101.0, quantity=2.0)
        @test Binance.get_best_ask(manager) == (price=102.0, quantity=1.5)

        @test Binance.OrderBookManagers.apply_update!(manager, Dict(
            "U" => 3, "u" => 3,
            "b" => [["101.0", "0.0"]],
            "a" => [],
        )) == :applied
        @test Binance.get_best_bid(manager) == (price=100.0, quantity=1.0)

        @test Binance.OrderBookManagers.apply_update!(manager, Dict(
            "U" => 4, "u" => 4,
            "b" => [],
            "a" => [["102.0", "0.0"]],
        )) == :applied
        @test Binance.get_best_ask(manager) == (price=103.0, quantity=1.0)
    end

    @testset "WebSocket kline rows use NamedTuple format" begin
        kline = Binance.Kline(
            DateTime(2026, 1, 1, 0, 0, 0, 123),
            1.0, 2.0, 0.5, 1.5, 10.0,
            DateTime(2026, 1, 1, 0, 0, 59, 999),
            15.0, 42, 6.0, 9.0, "0",
        )

        rows = Binance.WebSocketAPI.kline_rows([kline])
        @test eltype(rows) <: NamedTuple
        @test rows[1].open_time == DateTime(2026, 1, 1, 0, 0, 0)
        @test rows[1].close_time == DateTime(2026, 1, 1, 0, 0, 59)
        @test rows[1].base_volume == 10.0
        @test !any(pkgid -> pkgid.name == "DataFrames", keys(Base.loaded_modules))
    end

    @testset "BlockTrade construction and parsing" begin
        # Direct construction
        bt = Binance.BlockTrade(582, "0.052", "5838", "303.576",
                                Binance.Types.unix2datetime(1772506983321 / 1000), true)
        @test bt.id == 582
        @test bt.price == "0.052"
        @test bt.isBuyerMaker === true

        # JSON-style construction via to_struct (mirrors REST/WS API response shape)
        json = Dict(
            "id" => 582, "price" => "0.052", "qty" => "5838",
            "quoteQty" => "303.576", "time" => 1772506983321, "isBuyerMaker" => true,
        )
        bt2 = Binance.Types.to_struct(Binance.BlockTrade, json)
        @test bt2.id == 582
        @test bt2.quoteQty == "303.576"
    end

    @testset "Order has expiryReason field (SBE 3:4 / 2026-05-08)" begin
        @test :expiryReason in fieldnames(Binance.Order)
        json = Dict(
            "symbol" => "BTCUSDT", "orderId" => 1, "orderListId" => -1,
            "clientOrderId" => "x", "price" => "100.0", "origQty" => "1",
            "executedQty" => "0", "cummulativeQuoteQty" => "0", "status" => "EXPIRED",
            "timeInForce" => "GTC", "type" => "LIMIT", "side" => "BUY",
            "stopPrice" => "0", "icebergQty" => "0", "time" => 1700000000000,
            "updateTime" => 1700000000000, "isWorking" => false,
            "origQuoteOrderQty" => "0",
            "expiryReason" => "EXECUTION_RULE_PRICE_RANGE_EXCEEDED",
        )
        o = Binance.Types.to_struct(Binance.Order, json)
        @test o.expiryReason == "EXECUTION_RULE_PRICE_RANGE_EXCEEDED"

        # Field is optional — must accept absence
        delete!(json, "expiryReason")
        o2 = Binance.Types.to_struct(Binance.Order, json)
        @test o2.expiryReason === nothing
    end

    @testset "serverShutdown handling on SBE text control frames" begin
        tmpdir = mktempdir()
        key_path = joinpath(tmpdir, "ed25519-private.pem")
        config_path = joinpath(tmpdir, "config.toml")
        write(key_path, "test-key")
        write(config_path, """
        [api]
        api_key = "test-api-key"
        signature_method = "ED25519"
        private_key_path = "$key_path"

        [connection]
        proxy = ""
        """)

        client = Binance.SBEMarketDataStreams.SBEStreamClient(config_path)
        @test client.ws_connection === nothing
        @test_logs (:warn, r"serverShutdown received on SBE stream") begin
            Binance.SBEMarketDataStreams.handle_control_message(
                client,
                "{\"e\":\"serverShutdown\",\"E\":1700000000000}",
            )
        end
        @test client.ws_connection === nothing
    end

    @testset "External reference price calculation ids are extensible" begin
        calc = Binance.ExternalCalculation("BTCUSDT", "EXTERNAL", 42)
        @test calc.externalCalculationId == 42
    end
end
