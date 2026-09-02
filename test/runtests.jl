using Test
using Binance
using Base64
using Dates
using HTTP
using StructUtils
import JSON

# Plain struct with an unannotated DateTime, used to prove the unix-millis
# timestamp tag does not leak into unrelated types.
struct UnannotatedStamp
    t::DateTime
end

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
        @test isempty(Symbol[
            name for name in names(Binance; all=false, imported=false)
            if !isdefined(Binance, name)
        ])
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

    @testset "Response types deserialize lazily and materialized" begin
        # Both entry points must agree: `JSON.parse(raw, T)` fills the struct
        # straight from the bytes, while `to_struct` works on an already-decoded
        # object (what the WebSocket paths have). Each case is asserted
        # field-by-field: a wrong tag silently yields a default or shifted value
        # rather than an error.
        T = Binance.Types
        cases = (
            (T.AveragePrice,
             """{"mins":5,"price":"42000.50","closeTime":1704067200000}""",
             ap -> (ap.mins == 5, ap.price == "42000.50",
                    ap.closeTime == DateTime(2024, 1, 1))),
            (T.MarketTrade,
             """{"id":9,"price":"42000.5","qty":"0.5","quoteQty":"21000.25","time":1704067200000,"isBuyerMaker":true,"isBestMatch":false}""",
             t -> (t.id == 9, t.price == "42000.5", t.qty == "0.5",
                   t.quoteQty == "21000.25", t.time == DateTime(2024, 1, 1),
                   t.isBuyerMaker === true, t.isBestMatch === false)),
            (T.BlockTrade,
             """{"id":11,"price":"1.5","qty":"2.5","quoteQty":"3.75","time":1704067260000,"isBuyerMaker":false}""",
             t -> (t.id == 11, t.price == "1.5", t.qty == "2.5", t.quoteQty == "3.75",
                   t.time == DateTime(2024, 1, 1, 0, 1), t.isBuyerMaker === false)),
            (T.PriceTicker,
             """{"symbol":"BTCUSDT","price":"95000.10"}""",
             p -> (p.symbol == "BTCUSDT", p.price == "95000.10")),
            (T.BookTicker,
             """{"symbol":"ETHUSDT","bidPrice":"1","bidQty":"2","askPrice":"3","askQty":"4"}""",
             b -> (b.symbol == "ETHUSDT", b.bidPrice == "1", b.bidQty == "2",
                   b.askPrice == "3", b.askQty == "4")),
            (T.ReferencePrice,
             """{"symbol":"BTCUSDT","referencePrice":"42000.0","timestamp":1704067200000}""",
             r -> (r.symbol == "BTCUSDT", r.referencePrice == "42000.0",
                   r.timestamp == DateTime(2024, 1, 1))),
        )

        for (Ty, raw, check) in cases
            @test all(check(T.to_struct(Ty, JSON.parse(raw))))
            @test all(check(JSON.parse(raw, Ty)))
        end

        # A missing (not null) optional field must land as `nothing`.
        absent = JSON.parse("""{"symbol":"X","timestamp":1704067200000}""", T.ReferencePrice)
        @test absent.referencePrice === nothing

        # The tag's `lower` half must put milliseconds back on the wire.
        trade = JSON.parse(cases[2][2], T.MarketTrade)
        encoded = JSON.json(trade)
        @test occursin("\"time\":1704067200000", encoded)
        @test JSON.parse(encoded, T.MarketTrade) == trade
    end

    @testset "Macro-generated ticker types carry the timestamp tag" begin
        # The five ticker types come from @define_mini_ticker / @define_full_ticker.
        # Those macros now emit @binance_struct, so &UNIX_MS has to survive one
        # extra layer of macro expansion — verify the timestamps actually lift.
        T = Binance.Types
        mini = """{"symbol":"BTCUSDT","openPrice":"1","highPrice":"2","lowPrice":"3","lastPrice":"4","volume":"5","quoteVolume":"6","openTime":1704067200000,"closeTime":1704153600000,"firstId":10,"lastId":20,"count":42}"""
        full = """{"symbol":"ETHUSDT","priceChange":"1","priceChangePercent":"2","weightedAvgPrice":"3","openPrice":"4","highPrice":"5","lowPrice":"6","lastPrice":"7","volume":"8","quoteVolume":"9","openTime":1704067200000,"closeTime":1704153600000,"firstId":1,"lastId":2,"count":3}"""

        for (Ty, raw) in ((T.Ticker24hrMini, mini), (T.TradingDayTickerMini, mini),
                          (T.RollingWindowTickerMini, mini),
                          (T.TradingDayTicker, full), (T.RollingWindowTicker, full))
            ticker = JSON.parse(raw, Ty)
            @test ticker == T.to_struct(Ty, JSON.parse(raw))
            @test ticker.openTime == DateTime(2024, 1, 1)
            @test ticker.closeTime == DateTime(2024, 1, 2)
        end
    end

    @testset "Account and market history types deserialize field-by-field" begin
        T = Binance.Types

        trade_json = """{"symbol":"BTCUSDT","id":1,"orderId":2,"orderListId":-1,"price":"42000.5","qty":"0.5","quoteQty":"21000.25","commission":"0.001","commissionAsset":"BNB","time":1704067200000,"isBuyer":true,"isMaker":false,"isBestMatch":true}"""
        trade = JSON.parse(trade_json, T.Trade)
        @test trade == T.to_struct(T.Trade, JSON.parse(trade_json))
        @test trade.orderListId == -1          # sentinel for "not part of a list"
        @test trade.commissionAsset == "BNB"
        @test trade.time == DateTime(2024, 1, 1)
        @test occursin("\"time\":1704067200000", JSON.json(trade))

        # Single-letter field names must not be reordered: `a`/`f`/`l` are ids,
        # `T` is the timestamp, `m`/`M` are distinct flags.
        agg_json = """{"a":100,"p":"42000","q":"1.5","f":10,"l":20,"T":1704067200000,"m":true,"M":false}"""
        agg = JSON.parse(agg_json, T.AggregateTrade)
        @test agg == T.to_struct(T.AggregateTrade, JSON.parse(agg_json))
        @test (agg.a, agg.f, agg.l) == (100, 10, 20)
        @test agg.T == DateTime(2024, 1, 1)
        @test agg.m === true && agg.M === false

        # 21 fields, all strings but for the two timestamps and three counters —
        # a shifted mapping would be silent, so check both ends and the middle.
        rest_json = """{"symbol":"BTCUSDT","priceChange":"1","priceChangePercent":"2","weightedAvgPrice":"3","prevClosePrice":"4","lastPrice":"5","lastQty":"6","bidPrice":"7","bidQty":"8","askPrice":"9","askQty":"10","openPrice":"11","highPrice":"12","lowPrice":"13","volume":"14","quoteVolume":"15","openTime":1704067200000,"closeTime":1704153600000,"firstId":1,"lastId":2,"count":3}"""
        rest = JSON.parse(rest_json, T.Ticker24hrRest)
        @test rest == T.to_struct(T.Ticker24hrRest, JSON.parse(rest_json))
        @test rest.symbol == "BTCUSDT"
        @test rest.prevClosePrice == "4"
        @test rest.askQty == "10"
        @test rest.quoteVolume == "15"
        @test rest.openTime == DateTime(2024, 1, 1)
        @test rest.closeTime == DateTime(2024, 1, 2)
        @test rest.count == 3
    end

    @testset "Abbreviated stream keys map to the right fields" begin
        # These types name every field via a `name` tag. The wire format uses
        # case-sensitive pairs with unrelated meanings (p/P, b/B, a/A, q/Q) and
        # puts `l` (low price) next to `L` (last trade id), so a case slip would
        # silently swap values instead of erroring. Distinct sentinel strings make
        # any such swap visible.
        T = Binance.Types

        ws_json = """{"e":"trade","E":1704067200000,"s":"BTCUSDT","t":9,"p":"42000.5","q":"0.5","T":1704067260000,"m":true,"M":false}"""
        ws = JSON.parse(ws_json, T.WebSocketTrade)
        @test ws == T.to_struct(T.WebSocketTrade, JSON.parse(ws_json))
        @test (ws.eventType, ws.symbol, ws.tradeId) == ("trade", "BTCUSDT", 9)
        @test (ws.price, ws.quantity) == ("42000.5", "0.5")
        @test ws.eventTime == DateTime(2024, 1, 1)
        @test ws.tradeTime == DateTime(2024, 1, 1, 0, 1)
        @test ws.isBuyerMaker === true && ws.ignore === false
        ws_out = JSON.json(ws)
        @test occursin("\"E\":1704067200000", ws_out)
        @test occursin("\"T\":1704067260000", ws_out)
        @test JSON.parse(ws_out, T.WebSocketTrade) == ws

        blk_json = """{"e":"blockTrade","E":1704067200000,"s":"BTCUSDT","t":5,"p":"1","q":"2","T":1704067260000,"m":false}"""
        blk = JSON.parse(blk_json, T.WebSocketBlockTrade)
        @test blk == T.to_struct(T.WebSocketBlockTrade, JSON.parse(blk_json))
        @test blk.eventType == "blockTrade" && blk.tradeId == 5
        @test blk.eventTime == DateTime(2024, 1, 1)
        @test blk.tradeTime == DateTime(2024, 1, 1, 0, 1)
        @test blk.isBuyerMaker === false

        tick_json = """{"e":"24hrTicker","E":1704067200000,"s":"BTCUSDT","p":"P1","P":"P2","w":"W","x":"X","c":"C","Q":"Q","b":"B_low","B":"B_up","a":"A_low","A":"A_up","o":"O","h":"H","l":"L_low","v":"V","q":"Q_low","O":1704067200000,"C":1704153600000,"F":11,"L":22,"n":33}"""
        tick = JSON.parse(tick_json, T.Ticker24hr)
        @test tick == T.to_struct(T.Ticker24hr, JSON.parse(tick_json))
        @test tick.priceChange == "P1" && tick.priceChangePercent == "P2"
        @test tick.bestBidPrice == "B_low" && tick.bestBidQuantity == "B_up"
        @test tick.bestAskPrice == "A_low" && tick.bestAskQuantity == "A_up"
        @test tick.lastQuantity == "Q" && tick.totalTradedQuoteAssetVolume == "Q_low"
        @test tick.lowPrice == "L_low" && tick.lastTradeId == 22
        @test tick.weightedAvgPrice == "W" && tick.firstTradePrice == "X"
        @test tick.lastPrice == "C" && tick.openPrice == "O" && tick.highPrice == "H"
        @test tick.totalTradedBaseAssetVolume == "V"
        @test tick.firstTradeId == 11 && tick.totalNumberOfTrades == 33
        @test tick.eventTime == DateTime(2024, 1, 1)
        @test tick.statisticsOpenTime == DateTime(2024, 1, 1)
        @test tick.statisticsCloseTime == DateTime(2024, 1, 2)
        @test JSON.parse(JSON.json(tick), T.Ticker24hr) == tick
    end

    @testset "Timestamp tags stay scoped to annotated fields" begin
        # The unix-milliseconds lift is attached per field rather than as a global
        # `StructUtils.lift(::Type{DateTime}, ::Number)` method, which would
        # hijack DateTime parsing for every other package. Verify an unannotated
        # struct keeps the stock ISO-string behaviour and still rejects millis.
        @test JSON.parse("""{"t":"2024-01-01T00:00:00"}""", UnannotatedStamp).t ==
              DateTime(2024, 1, 1)
        @test_throws MethodError JSON.parse("""{"t":1704067200000}""", UnannotatedStamp)
    end

    @testset "Kline maps its 12 positional slots" begin
        # A kline is an unnamed 12-element array mixing raw numbers (the two
        # timestamps, the trade count) with decimal strings. Nothing in the payload
        # identifies a slot, so an off-by-one in the mapping would silently shift
        # every price. Distinct values per slot make that visible.
        T = Binance.Types
        raw = """[[1704067200000,"42000.5","43000.1","41000.0","42500.0","123.456",1704070800000,"5000000.0",1234,"60.0","2500000.0","0"]]"""

        bars = JSON.parse(raw, Vector{T.Kline})
        @test bars == T.to_struct(Vector{T.Kline}, JSON.parse(raw))
        @test length(bars) == 1

        bar = bars[1]
        @test bar.open_time == DateTime(2024, 1, 1)
        @test bar.open == 42000.5
        @test bar.high == 43000.1
        @test bar.low == 41000.0
        @test bar.close == 42500.0
        @test bar.base_volume == 123.456
        @test bar.close_time == DateTime(2024, 1, 1, 1)
        @test bar.quote_volume == 5.0e6
        @test bar.number_of_trades == 1234
        @test bar.taker_base_volume == 60.0
        @test bar.taker_quote_volume == 2.5e6
        @test bar.ignore == "0"

        # A single bar outside an enclosing array must work too.
        single = JSON.parse("""[1704067200000,"1","2","3","4","5",1704070800000,"6",7,"8","9",""]""",
                            T.Kline)
        @test single.open == 1.0
        @test single.number_of_trades == 7
        @test single.ignore == ""

        @test JSON.parse(JSON.json(bar), T.Kline) == bar
    end

    @testset "OrderBook deserializes nested array-shaped levels" begin
        # `PriceLevel` arrives as a
        # two-element array of decimal strings, and `constructfrom` had no method
        # for a CustomStruct element type, so every `depth()` call raised a
        # MethodError. PriceLevel now opts out of struct-like treatment and
        # converts via lift/lower, which the nested vectors pick up automatically.
        T = Binance.Types
        @test StructUtils.structlike(StructUtils.DefaultStyle(), T.PriceLevel) == false

        raw = """{"lastUpdateId":123456,"bids":[["95000.10","1.5"],["94999.00","2.0"]],"asks":[["95001.00","0.8"]]}"""

        # OrderBook holds Vectors, so `==` compares them by identity; compare the
        # contents instead of the wrapper.
        same(x, y) = x.lastUpdateId == y.lastUpdateId && x.bids == y.bids && x.asks == y.asks

        book = JSON.parse(raw, T.OrderBook)
        @test same(book, T.to_struct(T.OrderBook, JSON.parse(raw)))
        @test book.lastUpdateId == 123456
        @test length(book.bids) == 2
        @test length(book.asks) == 1
        @test book.bids[1] == T.PriceLevel(95000.10, 1.5)
        @test book.bids[2] == T.PriceLevel(94999.00, 2.0)
        @test book.asks[1] == T.PriceLevel(95001.00, 0.8)

        # A level parsed on its own must work too — SBE and depth-diff paths build
        # levels without a surrounding book.
        @test JSON.parse("""["1.25","3.5"]""", T.PriceLevel) == T.PriceLevel(1.25, 3.5)

        # `lower` must put the array-of-strings shape back on the wire.
        encoded = JSON.json(book)
        @test occursin("""["95000.1","1.5"]""", encoded)
        @test same(JSON.parse(encoded, T.OrderBook), book)

        # An empty book is valid (illiquid or freshly listed symbol).
        empty_book = JSON.parse("""{"lastUpdateId":1,"bids":[],"asks":[]}""", T.OrderBook)
        @test empty_book.lastUpdateId == 1
        @test isempty(empty_book.bids) && isempty(empty_book.asks)
    end

    @testset "Filters dispatch on filterType" begin
        # A symbol's filter list is heterogeneous and the concrete type is only
        # known from the `filterType` string. Both entry paths must agree: the lazy
        # `JSON.parse(raw, T)` and the materialized one `to_struct` sees.
        T = Binance.Types
        raw = """[{"filterType":"LOT_SIZE","minQty":"0.001","maxQty":"9000","stepSize":"0.001"},
                  {"filterType":"ICEBERG_PARTS","limit":10},
                  {"filterType":"TRAILING_DELTA","minTrailingAboveDelta":10,"maxTrailingAboveDelta":2000,"minTrailingBelowDelta":11,"maxTrailingBelowDelta":2001},
                  {"filterType":"NOTIONAL","minNotional":"5.0","applyMinToMarket":true,"maxNotional":"9000000","applyMaxToMarket":false,"avgPriceMins":5}]"""

        filters = JSON.parse(raw, Vector{T.AbstractFilter})
        @test filters == T.to_struct(Vector{T.AbstractFilter}, JSON.parse(raw))
        @test map(typeof, filters) == [T.LotSizeFilter, T.IcebergPartsFilter,
                                       T.TrailingDeltaFilter, T.NotionalFilter]

        # Field-level assertions: the macro-generated filters share a shape, so a
        # mixed-up mapping would still produce the right type.
        lot = filters[1]
        @test (lot.minQty, lot.maxQty, lot.stepSize) == ("0.001", "9000", "0.001")
        @test filters[2].limit === 10
        trailing = filters[3]
        @test (trailing.minTrailingAboveDelta, trailing.maxTrailingAboveDelta) == (10, 2000)
        @test (trailing.minTrailingBelowDelta, trailing.maxTrailingBelowDelta) == (11, 2001)
        notional = filters[4]
        @test notional.minNotional == "5.0"
        @test notional.applyMinToMarket
        @test !notional.applyMaxToMarket
        @test notional.avgPriceMins == 5

        @test JSON.parse(JSON.json(filters), Vector{T.AbstractFilter}) == filters

        # A single filter outside a list, as `exchangeFilters` entries arrive.
        @test JSON.parse("""{"filterType":"EXCHANGE_MAX_NUM_ORDERS","maxNumOrders":1000}""",
                         T.AbstractFilter) === T.ExchangeMaxNumOrdersFilter("EXCHANGE_MAX_NUM_ORDERS", 1000)

        # Both failure modes must throw rather than silently drop the filter:
        # dropping a LOT_SIZE would let an order violate stepSize.
        @test_throws ArgumentError JSON.parse("""[{"filterType":"NOT_A_FILTER","x":1}]""",
                                              Vector{T.AbstractFilter})
        @test_throws ArgumentError JSON.parse("""[{"x":1}]""", Vector{T.AbstractFilter})
    end

    @testset "ExchangeInfo nests filters, symbols and rate limits" begin
        # serverTime arrives as millis and the three vectors nest further types,
        # so this exercises the deepest conversion in the package.
        T = Binance.Types
        raw = """{"timezone":"UTC","serverTime":1704067200000,
                  "rateLimits":[{"rateLimitType":"REQUEST_WEIGHT","interval":"MINUTE","intervalNum":1,"limit":6000}],
                  "exchangeFilters":[{"filterType":"EXCHANGE_MAX_NUM_ORDERS","maxNumOrders":1000}],
                  "symbols":[{"symbol":"BTCUSDT","status":"TRADING","baseAsset":"BTC","baseAssetPrecision":8,
                  "quoteAsset":"USDT","quoteAssetPrecision":8,"baseCommissionPrecision":8,"quoteCommissionPrecision":8,
                  "orderTypes":["LIMIT","MARKET"],"icebergAllowed":true,"ocoAllowed":true,
                  "quoteOrderQtyMarketAllowed":true,"isSpotTradingAllowed":true,"isMarginTradingAllowed":true,
                  "filters":[{"filterType":"LOT_SIZE","minQty":"0.001","maxQty":"9000","stepSize":"0.001"}],
                  "permissions":["SPOT"],"defaultSelfTradePreventionMode":"NONE",
                  "allowedSelfTradePreventionModes":["NONE","EXPIRE_MAKER"]}]}"""

        for info in (JSON.parse(raw, T.ExchangeInfo),
                     T.to_struct(T.ExchangeInfo, JSON.parse(raw)))
            @test info.timezone == "UTC"
            @test info.serverTime == DateTime(2024, 1, 1)

            @test length(info.rateLimits) == 1
            limit = info.rateLimits[1]
            @test limit.rateLimitType == T.REQUEST_WEIGHT
            @test limit.interval == T.MINUTE
            @test (limit.intervalNum, limit.limit) == (1, 6000)

            @test info.exchangeFilters == [T.ExchangeMaxNumOrdersFilter("EXCHANGE_MAX_NUM_ORDERS", 1000)]

            @test length(info.symbols) == 1
            sym = info.symbols[1]
            @test sym.symbol == "BTCUSDT"
            @test sym.status == T.TRADING
            @test (sym.baseAsset, sym.quoteAsset) == ("BTC", "USDT")
            @test sym.orderTypes == [T.LIMIT, T.MARKET]
            @test sym.permissions == [T.SPOT]
            @test sym.defaultSelfTradePreventionMode == T.NONE
            @test sym.allowedSelfTradePreventionModes == [T.NONE, T.EXPIRE_MAKER]
            @test sym.filters == [T.LotSizeFilter("LOT_SIZE", "0.001", "9000", "0.001")]

            # Absent from this payload: the field defaults stand in. Endpoints that
            # omit them must not leave the field undefined.
            @test sym.otoAllowed === false
            @test sym.opoAllowed === false
        end

        # An explicit value still wins over the default.
        with_oto = replace(raw, "\"icebergAllowed\":true" => "\"icebergAllowed\":true,\"otoAllowed\":true")
        @test JSON.parse(with_oto, T.ExchangeInfo).symbols[1].otoAllowed === true

        # SymbolInfo() must stay callable: RESTClient seeds its symbol cache with it.
        blank = T.SymbolInfo()
        @test blank.otoAllowed === false
        @test blank.opoAllowed === false
    end

    @testset "User data stream events parse from both sources" begin
        # Every user-data event uses single-letter keys, so a shifted mapping still
        # type-checks. The strategy layer reads these to track fills and balances.
        E = Binance.Events
        T = Binance.Types

        raw = """{"e":"outboundAccountPosition","E":1704067200000,"u":1704067200001,
                  "B":[{"a":"BTC","f":"1.5","l":"0.2"},{"a":"USDT","f":"1000","l":"0"}]}"""
        for pos in (JSON.parse(raw, E.OutboundAccountPosition),
                    T.to_struct(E.OutboundAccountPosition, JSON.parse(raw)))
            @test pos.e == "outboundAccountPosition"
            @test pos.E == 1704067200000
            @test pos.u == 1704067200001
            @test pos.B == [E.Balance("BTC", "1.5", "0.2"), E.Balance("USDT", "1000", "0")]
        end

        raw = """{"e":"balanceUpdate","E":1704067200000,"a":"BTC","d":"-0.5","T":1704067200002}"""
        update = JSON.parse(raw, E.BalanceUpdate)
        @test update == T.to_struct(E.BalanceUpdate, JSON.parse(raw))
        @test (update.a, update.d, update.T) == ("BTC", "-0.5", 1704067200002)

        raw = """{"e":"listStatus","E":1704067200000,"s":"BTCUSDT","g":9,"c":"OCO","l":"ALL_DONE",
                  "L":"ALL_DONE","r":"NONE","C":"cid","T":1704067200003,
                  "O":[{"s":"BTCUSDT","i":11,"c":"c1"},{"s":"BTCUSDT","i":12,"c":"c2"}]}"""
        status = JSON.parse(raw, E.ListStatus)
        @test (status.s, status.g, status.c, status.l, status.L, status.r, status.C) ==
              ("BTCUSDT", 9, "OCO", "ALL_DONE", "ALL_DONE", "NONE", "cid")
        @test status.O == [E.OrderInListStatus("BTCUSDT", 11, "c1"),
                           E.OrderInListStatus("BTCUSDT", 12, "c2")]
        @test status.O == T.to_struct(E.ListStatus, JSON.parse(raw)).O

        # `@depth20` snapshots reuse PriceLevel.
        raw = """{"lastUpdateId":123,"bids":[["95000.1","1.5"],["94999.0","2.0"]],"asks":[["95001.0","0.8"]]}"""
        for book in (JSON.parse(raw, E.PartialBookDepth),
                     T.to_struct(E.PartialBookDepth, JSON.parse(raw)))
            @test book.lastUpdateId == 123
            @test book.bids == [T.PriceLevel(95000.10, 1.5), T.PriceLevel(94999.00, 2.0)]
            @test book.asks == [T.PriceLevel(95001.00, 0.8)]
        end

        # ExecutionReport has 33 required fields and 23 conditional ones. A fill
        # report that omits the conditional block must leave them `nothing`
        # rather than error, and a report that carries them must not drop values.
        minimal = """{"e":"executionReport","E":1704067200000,"s":"BTCUSDT","c":"cid","S":"BUY",
                      "o":"LIMIT","f":"GTC","q":"1.0","p":"95000.0","P":"0","F":"0","g":-1,"C":"",
                      "x":"NEW","X":"NEW","r":"NONE","i":42,"l":"0","z":"0","L":"0","n":"0","N":null,
                      "T":1704067200001,"t":-1,"I":8,"w":true,"m":false,"M":false,"O":1704067200000,
                      "Z":"0","Y":"0","Q":"0","V":"NONE"}"""
        report = JSON.parse(minimal, E.ExecutionReport)
        @test report == T.to_struct(E.ExecutionReport, JSON.parse(minimal))
        @test (report.s, report.S, report.o, report.X, report.i) ==
              ("BTCUSDT", "BUY", "LIMIT", "NEW", 42)
        @test report.w && !report.m
        @test report.N === nothing        # explicit JSON null
        @test report.W === nothing        # key absent entirely
        @test report.eR === nothing
        @test report.uS === nothing

        # Ordered so the fragment ends on a bare `true`: a triple-quoted string
        # cannot end with a quote character.
        conditional = """"V":"NONE","W":1704067200004,"d":13,"eR":"PRICE_RANGE","Cs":"ETHUSDT","uS":true"""
        full = replace(minimal, "\"V\":\"NONE\"" => conditional)
        report = JSON.parse(full, E.ExecutionReport)
        @test report == T.to_struct(E.ExecutionReport, JSON.parse(full))
        @test report.W == 1704067200004
        @test report.d == 13
        @test report.eR == "PRICE_RANGE"
        @test report.uS === true
        @test report.Cs == "ETHUSDT"
    end

    @testset "Account balances parse decimal strings into Float64" begin
        # Balance is the one type where a wire decimal becomes a Float64: the
        # strategy layer compares balances against order sizes. Everything else
        # keeps the exact string the exchange sent.
        A = Binance.Account
        T = Binance.Types
        raw = """{"makerCommission":15,"takerCommission":15,"buyerCommission":0,"sellerCommission":0,
                  "commissionRates":{"maker":"0.00150000","taker":"0.00150000","buyer":"0.00000000","seller":"0.00000000"},
                  "canTrade":true,"canWithdraw":true,"canDeposit":true,"brokered":false,
                  "requireSelfTradePrevention":false,"preventSor":false,"updateTime":1704067200000,
                  "accountType":"SPOT",
                  "balances":[{"asset":"BTC","free":"1.50000000","locked":"0.20000000"},
                              {"asset":"USDT","free":"1000.00000000","locked":"0.00000000"}],
                  "permissions":["SPOT"],"uid":123456}"""

        for info in (JSON.parse(raw, A.AccountInfo),
                     T.to_struct(A.AccountInfo, JSON.parse(raw)))
            @test info.balances == [A.Balance("BTC", 1.5, 0.2), A.Balance("USDT", 1000.0, 0.0)]
            @test info.balances[1].free isa Float64
            # Commission rates stay strings: callers echo them, never add them.
            @test info.commissionRates == A.CommissionRates("0.00150000", "0.00150000",
                                                            "0.00000000", "0.00000000")
            @test (info.makerCommission, info.takerCommission) == (15, 15)
            @test info.canTrade && info.canWithdraw && info.canDeposit
            @test !info.brokered && !info.requireSelfTradePrevention && !info.preventSor
            # An Int64, not a DateTime: callers pass it straight back to the API.
            @test info.updateTime === 1704067200000
            @test info.accountType == "SPOT"
            @test info.permissions == ["SPOT"]
            @test info.uid == 123456
        end

        # `lower` must put the decimal string back, not a bare number.
        encoded = JSON.json(A.Balance("BTC", 1.5, 0.2))
        @test encoded == """{"asset":"BTC","free":"1.5","locked":"0.2"}"""
        @test JSON.parse(encoded, A.Balance) == A.Balance("BTC", 1.5, 0.2)
    end

    @testset "Convert responses lift millisecond timestamps" begin
        # Every Convert response carries at least one unix-millisecond timestamp
        # and these all dropped a hand-written construct.
        C = Binance.Convert
        T = Binance.Types

        raw = """{"quoteId":"q1","ratio":"95000.5","inverseRatio":"0.0000105",
                  "validTimestamp":1704067200000,"toAmount":"95000.5","fromAmount":"1.0"}"""
        quote_ = JSON.parse(raw, C.ConvertQuote)
        @test quote_ == T.to_struct(C.ConvertQuote, JSON.parse(raw))
        @test quote_.quoteId == "q1"
        @test quote_.ratio == "95000.5"
        @test quote_.inverseRatio == "0.0000105"
        @test quote_.validTimestamp == DateTime(2024, 1, 1)
        @test (quote_.toAmount, quote_.fromAmount) == ("95000.5", "1.0")
        # Ratios and amounts stay strings: the strategy layer feeds fromAmount
        # back to acceptQuote and a Float64 round-trip could shift the last digit.
        @test quote_.ratio isa String
        @test occursin("\"validTimestamp\":1704067200000", JSON.json(quote_))

        raw = """{"orderId":"o1","createTime":1704067200000,"orderStatus":"PROCESS"}"""
        accepted = JSON.parse(raw, C.ConvertAcceptQuote)
        @test accepted == T.to_struct(C.ConvertAcceptQuote, JSON.parse(raw))
        @test (accepted.orderId, accepted.orderStatus) == ("o1", "PROCESS")
        @test accepted.createTime == DateTime(2024, 1, 1)

        # A nested list plus two timestamps of its own.
        raw = """{"list":[{"quoteId":"q1","orderId":42,"orderStatus":"SUCCESS","fromAsset":"BTC",
                  "fromAmount":"1.0","toAsset":"USDT","toAmount":"95000.5","ratio":"95000.5",
                  "inverseRatio":"0.0000105","createTime":1704067200000}],
                  "startTime":1704067200000,"endTime":1704153600000,"limit":100,"moreData":false}"""
        for flow in (JSON.parse(raw, C.ConvertTradeFlowResponse),
                     T.to_struct(C.ConvertTradeFlowResponse, JSON.parse(raw)))
            @test flow.startTime == DateTime(2024, 1, 1)
            @test flow.endTime == DateTime(2024, 1, 2)
            @test flow.limit == 100
            @test !flow.moreData
            @test length(flow.list) == 1
            trade = flow.list[1]
            @test trade.orderId == 42
            @test trade.orderStatus == "SUCCESS"
            @test (trade.fromAsset, trade.toAsset) == ("BTC", "USDT")
            @test trade.createTime == DateTime(2024, 1, 1)
        end

        raw = """{"quoteId":"q1","orderId":42,"orderStatus":"OPEN","fromAsset":"BTC",
                  "fromAmount":"1.0","toAsset":"USDT","toAmount":"100000","ratio":"100000",
                  "inverseRatio":"0.00001","createTime":1704067200000,
                  "expiredTimestamp":1704153600000}"""
        order = JSON.parse(raw, C.ConvertLimitOrder)
        @test order == T.to_struct(C.ConvertLimitOrder, JSON.parse(raw))
        @test order.createTime == DateTime(2024, 1, 1)
        @test order.expiredTimestamp == DateTime(2024, 1, 2)
    end

    @testset "Untyped responses support the accessors call sites use" begin
        # `make_request` and the WebSocket reader hand decoded-but-untyped payloads
        # to callers and to internal branches. 30 REST call sites return one
        # directly, so every accessor those sites rely on must work: property
        # access, symbol and string indexing, haskey, and `isa AbstractDict` to
        # tell an object from an array.
        payload = JSON.parse("""{"id":"a","status":200,"result":{"symbol":"BTCUSDT"},
                                 "rateLimits":[{"rateLimitType":"REQUEST_WEIGHT"}]}""")

        @test payload.status == 200
        @test payload[:status] == 200
        @test payload["status"] == 200
        @test haskey(payload, :result) && haskey(payload, "result")
        @test !haskey(payload, :missing)
        @test get(payload, :missing, "fallback") == "fallback"
        @test payload isa AbstractDict
        @test payload.result.symbol == "BTCUSDT"
        @test payload.result isa AbstractDict
        @test payload.rateLimits[1].rateLimitType == "REQUEST_WEIGHT"
        @test Set(Symbol.(keys(payload))) == Set([:id, :status, :result, :rateLimits])

        # A top-level array must not look like an object: the ticker endpoints
        # branch on `isa Vector` to decide whether to map over the response.
        @test JSON.parse("""[{"a":1}]""") isa Vector
        @test !(JSON.parse("""[{"a":1}]""") isa AbstractDict)

        # The reader loop's request/event discrimination.
        @test !haskey(JSON.parse("""{"e":"executionReport"}"""), :id)
        @test string(JSON.parse("""{"id":42}""").id) == "42"

        # The response channel's element type must accept what the parser produces.
        channel = Channel{JSON.Object{String,Any}}(1)
        put!(channel, payload)
        @test take!(channel).status == 200

        # Endpoints that lift a timestamp publish `Dict{Symbol,Any}`. The helper
        # must convert the string keys and leave the source untouched.
        raw = JSON.parse("""{"symbol":"BTCUSDT","closeTime":1704067200000}""")
        converted = Binance.RESTAPI.symbol_dict(raw)
        @test converted isa Dict{Symbol,Any}
        @test converted[:symbol] == "BTCUSDT"
        converted[:closeTime] = unix2datetime(converted[:closeTime] / 1000)
        @test converted[:closeTime] == DateTime(2024, 1, 1)
        @test raw[:closeTime] == 1704067200000

        # Outbound request bodies: the WebSocket API and the `symbols=[...]` query
        # parameter both serialize through JSON.json now.
        @test JSON.json(["BTCUSDT", "ETHUSDT"]) == """["BTCUSDT","ETHUSDT"]"""
        request = JSON.parse(JSON.json(Dict("id" => "1", "method" => "depth",
                                            "params" => Dict("symbol" => "BTCUSDT"))))
        @test request.method == "depth"
        @test request.params.symbol == "BTCUSDT"
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

    @testset "WebSocket response helper returns ready messages" begin
        response_channel = Channel{Any}(1)
        put!(response_channel, JSON.parse("{\"status\":200,\"result\":{\"ok\":true}}"))
        response = Binance.WebSocketAPI.take_response!(response_channel, 1, "ping", "test-request-id")
        @test response.status == 200
        @test response.result.ok === true
    end

    @testset "WebSocket response helper wakes on a late-arriving reply" begin
        take_response! = Binance.WebSocketAPI.take_response!

        # A reply that arrives after the call started must be delivered by the
        # blocking `take!` rather than waited out on a polling interval.
        channel = Channel{Any}(1)
        @async begin
            sleep(0.05)
            put!(channel, JSON.parse("{\"status\":200,\"result\":1}"))
        end
        @test take_response!(channel, 5, "ping", "late-reply").result == 1

        # Exhausting the deadline raises, and the channel is left closed so the
        # socket reader can detect that nobody is waiting anymore.
        timed_out = Channel{Any}(1)
        @test_throws ErrorException take_response!(timed_out, 0.05, "ping", "timeout")
        @test !isopen(timed_out)
        @test_throws InvalidStateException put!(timed_out, JSON.parse("{}"))

        @test_throws ArgumentError take_response!(Channel{Any}(1), -1, "ping", "negative")
    end

    @testset "WebSocket network timeout has a positive floor" begin
        tmpdir = mktempdir()
        config_path = joinpath(tmpdir, "config.toml")
        write(config_path, """
        [api]
        api_key = "test-api-key"
        secret_key = "test-secret"
        signature_method = "HMAC_SHA256"

        [connection]
        timeout = 0
        proxy = ""
        """)

        client = Binance.WebSocketAPI.WebSocketClient(config_path)
        @test Binance.WebSocketAPI.network_timeout(client) == 1
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

    @testset "Order maps enums, timestamps and the optional expiry reason" begin
        # Order carries four enum fields, lifted from JSON strings by instance
        # name with no annotation. Assert each one: a mismatch would produce the
        # wrong side or status rather than an error.
        T = Binance.Types
        raw = """{"symbol":"BTCUSDT","orderId":123,"orderListId":-1,"clientOrderId":"abc","price":"42000.5","origQty":"1.0","executedQty":"0.5","cummulativeQuoteQty":"21000","status":"PARTIALLY_FILLED","timeInForce":"GTC","type":"LIMIT","side":"BUY","stopPrice":"0","icebergQty":"0","time":1704067200000,"updateTime":1704067260000,"isWorking":true,"origQuoteOrderQty":"0"}"""

        order = JSON.parse(raw, T.Order)
        @test order == T.to_struct(T.Order, JSON.parse(raw))
        @test order.status == T.PARTIALLY_FILLED
        @test order.timeInForce == T.GTC
        @test order.type == T.LIMIT
        @test order.side == T.BUY
        @test order.time == DateTime(2024, 1, 1)
        @test order.updateTime == DateTime(2024, 1, 1, 0, 1)
        @test order.orderListId == -1        # sentinel for "not in an order list"
        @test order.expiryReason === nothing

        expired = JSON.parse(
            replace(raw,
                    "\"status\":\"PARTIALLY_FILLED\"" => "\"status\":\"EXPIRED\"",
                    "\"isWorking\":true" => "\"isWorking\":false,\"expiryReason\":\"PRICE_RANGE\""),
            T.Order)
        @test expired.status == T.EXPIRED
        @test expired.expiryReason == "PRICE_RANGE"

        # Enums must go back out as strings, timestamps as milliseconds.
        encoded = JSON.json(order)
        @test occursin("\"status\":\"PARTIALLY_FILLED\"", encoded)
        @test occursin("\"side\":\"BUY\"", encoded)
        @test occursin("\"time\":1704067200000", encoded)
        @test JSON.parse(encoded, T.Order) == order
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

    @testset "Spot WebSocket API symbolStatus CANCEL_ONLY is supported" begin
        @test Binance.Types.to_struct(Binance.Types.SymbolStatus, "CANCEL_ONLY") ==
              Binance.Types.CANCEL_ONLY
    end

    @testset "Exact decimal filters avoid floating-point rejection" begin
        price_filter = Binance.Types.PriceFilter(
            "PRICE_FILTER", "0.0", "1000.0", "0.1",
        )
        parsed_price = Binance.Filters.parse_filter(price_filter)
        @test Binance.Filters.validate_price(0.3, parsed_price)
        @test_throws ArgumentError Binance.Filters.validate_price("0.31", parsed_price)

        lot_filter = Binance.Types.LotSizeFilter(
            "LOT_SIZE", "0.0", "1000.0", "0.01",
        )
        parsed_lot = Binance.Filters.parse_filter(lot_filter)
        @test Binance.Filters.validate_quantity("0.03", parsed_lot)
        @test_throws ArgumentError Binance.Filters.validate_quantity("0.031", parsed_lot)
    end

    @testset "OrderBookManager accepts decoded depth objects" begin
        manager = Binance.OrderBookManager("BTCUSDT", nothing, nothing)
        manager.is_initialized[] = true
        manager.update_id[] = 1
        event = JSON.parse("""
        {"U":2,"u":2,"b":[["100.0","1.0"]],"a":[["101.0","2.0"]]}
        """)
        @test Binance.OrderBookManagers.apply_update!(manager, event) == :applied
        @test Binance.get_best_bid(manager) == (price=100.0, quantity=1.0)
        @test Binance.get_best_ask(manager) == (price=101.0, quantity=2.0)
    end

    @testset "Rate limit updates reuse REQUEST_WEIGHT limit" begin
        limiter = Binance.BinanceRateLimit(test_binance_config())
        updates = JSON.parse("""
        [{"rateLimitType":"REQUEST_WEIGHT","interval":"MINUTE",
          "intervalNum":1,"limit":7000,"count":12}]
        """)
        Binance.RateLimiter.update_limits!(limiter, updates)
        matching = filter(
            limit -> limit.limit_type == "REQUEST_WEIGHT" && limit.interval_ms == 60_000,
            limiter.limits,
        )
        @test length(matching) == 1
        @test only(matching).limit == 7000
    end

    @testset "Rate limiter returns after reserving one request" begin
        limiter = Binance.BinanceRateLimit(test_binance_config())
        connection_limit = only(filter(
            limit -> limit.limit_type == "CONNECTIONS",
            limiter.limits,
        ))

        @test isempty(connection_limit.requests)
        @test isnothing(Binance.check_and_wait(limiter, "CONNECTIONS"))
        @test length(connection_limit.requests) == 1
    end

    @testset "Reconnect backoff grows and stays jittered within bounds" begin
        backoff_delay = Binance.RateLimiter.backoff_delay

        # base == 0 disables waiting entirely.
        @test backoff_delay(0, 1) == 0.0

        # attempt 1 => [0.5*base, base]; attempt n doubles the ceiling, bounded by `cap`.
        for attempt in 1:6
            ceiling = min(5.0 * 2.0^(attempt - 1), 60.0)
            delay = backoff_delay(5, attempt)
            @test 0.5 * ceiling <= delay <= ceiling
        end

        # The cap bounds the ceiling, and a huge attempt count must not overflow.
        @test backoff_delay(5, 30; cap=60.0) <= 60.0
        @test backoff_delay(5, 10_000; cap=60.0) <= 60.0

        # A base above the cap is still honoured rather than shrinking below it.
        @test 60.0 <= backoff_delay(120, 1; cap=60.0) <= 120.0

        # Jitter: repeated calls must not all return the same value.
        @test length(unique(backoff_delay(5, 4) for _ in 1:32)) > 1
    end

    @testset "REST error mapping records Retry-After backoff" begin
        limiter = Binance.BinanceRateLimit(test_binance_config())
        handle_error = Binance.RESTAPI.handle_error

        rate_limited = HTTP.Response(
            429;
            headers = ["Retry-After" => "7"],
            body = "{\"code\":-1003,\"msg\":\"Too many requests\"}",
        )
        @test_throws Binance.RateLimitError handle_error(limiter, rate_limited)
        # `set_backoff!` moved the sentinel forward, so a backoff is now armed.
        @test limiter.backoff_until != typemin(DateTime)

        # Header lookup must be case-insensitive (HTTP.jl canonicalizes keys) and
        # an unparseable value must warn rather than throw a bare ArgumentError.
        limiter2 = Binance.BinanceRateLimit(test_binance_config())
        banned = HTTP.Response(418; headers = ["retry-after" => "120"], body = "{}")
        @test_throws Binance.IPAutoBannedError handle_error(limiter2, banned)
        @test limiter2.backoff_until != typemin(DateTime)

        limiter3 = Binance.BinanceRateLimit(test_binance_config())
        malformed = HTTP.Response(429; headers = ["Retry-After" => "soon"], body = "{}")
        @test_logs (:warn, r"unparseable Retry-After") match_mode=:any begin
            @test_throws Binance.RateLimitError handle_error(limiter3, malformed)
        end
        @test limiter3.backoff_until == typemin(DateTime)

        # Status-to-exception mapping for the remaining documented codes.
        @test_throws Binance.WAFViolationError handle_error(limiter, HTTP.Response(403; body="{}"))
        @test_throws Binance.UnauthorizedError handle_error(limiter, HTTP.Response(401; body="{}"))
        @test_throws Binance.CancelReplacePartialSuccess handle_error(limiter, HTTP.Response(409; body="{}"))
        @test_throws Binance.MalformedRequestError handle_error(limiter, HTTP.Response(400; body="{}"))
        @test_logs (:warn, r"Binance Server Error") match_mode=:any begin
            @test_throws Binance.BinanceServerError handle_error(limiter, HTTP.Response(503; body="{}"))
        end
    end

    @testset "REST retry policy never retries rate-limit responses" begin
        retry_if = Binance.RESTAPI.binance_retry_if
        request = HTTP.Request("GET", "/api/v3/time")

        # 429/418/403 must be surfaced immediately: HTTP.jl retrying them would
        # escalate a rate-limit violation into an IP ban.
        for status in (429, 418, 403)
            @test retry_if(1, nothing, request, HTTP.Response(status)) === false
        end

        # Everything else defers to HTTP.jl's built-in classification.
        @test retry_if(1, nothing, request, HTTP.Response(503)) === nothing
        @test retry_if(1, nothing, request, HTTP.Response(200)) === nothing
        @test retry_if(1, HTTP.RequestRetryError(EOFError()), request, nothing) === nothing
    end

    @testset "Configuration reads testnet credentials from TOML" begin
        tmpdir = mktempdir()
        config_path = joinpath(tmpdir, "config.toml")
        write(config_path, """
        [api]
        api_key = "prod-key"
        secret_key = "prod-secret"
        testnet_api_key = "test-key"
        testnet_secret_key = "test-secret"
        signature_method = "HMAC_SHA256"

        [connection]
        testnet = true
        """)
        config = Binance.Config.from_toml(config_path)
        @test config.testnet
        @test config.api_key == "test-key"
        @test config.api_secret == "test-secret"
        @test Binance.load_config(config_path).testnet
    end

    @testset "NONE configuration creates an explicit no-op signer" begin
        signer = Binance.create_signer(test_binance_config(
            signature_method="NONE", api_secret="",
        ))
        @test signer isa Binance.NoSigner
        @test_throws ArgumentError Binance.Signature.sign_message(signer, "payload")
    end

    @testset "Callback wrappers retain concrete function types" begin
        stream_callback = Binance.MarketDataStreams.StreamCallback(identity)
        sbe_callback = Binance.SBEMarketDataStreams.SBEStreamCallback(identity)
        event_callback = Binance.WebSocketAPI.EventCallback(identity)
        @test fieldtype(typeof(stream_callback), 1) === typeof(identity)
        @test fieldtype(typeof(sbe_callback), 1) === typeof(identity)
        @test fieldtype(typeof(event_callback), 1) === typeof(identity)
    end

    @testset "SBE market stream uses official schema 1:0" begin
        decoder = Binance.SBEMarketDataStreams.SBEDecoder
        @test decoder.SCHEMA_ID == UInt16(1)
        @test decoder.SCHEMA_VERSION_CURRENT == UInt16(0)

        append_u16!(data, value) = append!(data, UInt8[
            value & 0xff, (value >> 8) & 0xff,
        ])
        append_u32!(data, value) = append!(data, UInt8[
            value & 0xff, (value >> 8) & 0xff,
            (value >> 16) & 0xff, (value >> 24) & 0xff,
        ])
        function append_i64!(data, value::Int64)
            bits = reinterpret(UInt64, value)
            for shift in 0:8:56
                push!(data, UInt8((bits >> shift) & 0xff))
            end
            return data
        end

        data = UInt8[]
        append_u16!(data, UInt16(18))     # root blockLength
        append_u16!(data, UInt16(10000))  # TradesStreamEvent
        append_u16!(data, UInt16(1))      # spot_stream schemaId
        append_u16!(data, UInt16(0))      # schema version
        append_i64!(data, Int64(1_700_000_000_000_000))
        append_i64!(data, Int64(1_700_000_000_000_001))
        push!(data, reinterpret(UInt8, Int8(-2)))
        push!(data, reinterpret(UInt8, Int8(-8)))
        append_u16!(data, UInt16(25))
        append_u32!(data, UInt32(1))
        append_i64!(data, Int64(42))
        append_i64!(data, Int64(6_000_000))
        append_i64!(data, Int64(100_000))
        push!(data, UInt8(1))
        symbol = codeunits("BTCUSDT")
        push!(data, UInt8(length(symbol)))
        append!(data, symbol)

        event = decoder.decode_sbe_message(data)
        @test event isa Binance.TradeEvent
        @test event.symbol == "BTCUSDT"
        @test length(event.trades) == 1
        @test event.trades[1].id == 42
        @test event.trades[1].price ≈ 60_000.0
        @test event.trades[1].qty ≈ 0.001
        @test event.trades[1].isBuyerMaker
    end

    @testset "SBE decoder rejects impossible group sizes before allocation" begin
        data = zeros(UInt8, 32)
        data[3:4] .= (0x10, 0x27)  # templateId 10000
        data[5:6] .= (0x01, 0x00)  # schemaId 1
        data[7:8] .= (0x00, 0x00)  # version 0
        data[29:32] .= 0xff
        @test_throws ArgumentError Binance.SBEMarketDataStreams.SBEDecoder.decode_sbe_message(data)
    end
end
