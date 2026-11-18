# Offline tests for the Binance Spot API changelog dated 2026-11-11:
# QuoteNotionalLimit (25057), EffectiveSelfTradePreventionMode (25058), the new
# ExpiryReason values, and FIX SBE schema 1:2.

using Test
using Sockets
using BinanceFIX
using BinanceFIX.FIXConstants
using BinanceFIX.FIXAPI
using BinanceFIX.FIXSBEEncoder
using BinanceFIX.FIXSBEDecoder

const CL_SOFH = 6
const CL_HDR = 20

le_u16(buf, pos) = reinterpret(UInt16, buf[pos:pos+1])[1]
le_i64(buf, pos) = reinterpret(Int64, buf[pos:pos+7])[1]
block_length(buf) = le_u16(buf, CL_SOFH + 1)
header_version(buf) = le_u16(buf, CL_SOFH + 7)
# 1-based index of the byte at zero-based `offset` inside the root block.
body_index(offset) = CL_SOFH + CL_HDR + offset + 1

# Runs `f(session)` with the session's socket connected to a local listener and
# returns the fields of the single FIX message it sent.
function capture_fix_fields(f)
    port, server = listenany(Sockets.localhost, 20000)
    session = FIXSession("127.0.0.1", Int(port), "SENDER", "SPOT", test_binance_config())
    client = connect(Sockets.localhost, port)
    peer = accept(server)
    try
        session.socket = BinanceFIX.FIXAPI.FIXConnection(client)
        f(session)
        return parse_fix_message(String(readavailable(peer)))
    finally
        close(client); close(peer); close(server)
    end
end

@testset "Binance changelog 2026-11-11 (FIX)" begin

    @testset "new tags and ExpiryReason values" begin
        @test TAG_QUOTE_NOTIONAL_LIMIT == 25057
        @test TAG_EFFECTIVE_SELF_TRADE_PREVENTION == 25058
        @test EXPIRY_EXHAUSTED == "9"
        @test EXPIRY_INSUFFICIENT_QUOTE_NOTIONAL_LIMIT == "10"
        @test BinanceFIX.EXPIRY_EXHAUSTED === EXPIRY_EXHAUSTED
    end

    @testset "text FIX ExecutionReport carries 25057 and 25058" begin
        msg = "8=FIX.4.4\x019=200\x0135=8\x0134=1\x0149=SPOT\x0156=T\x0111=ORD-1\x01" *
              "17=42\x0140=2\x0154=1\x0155=BTCUSDT\x0114=0\x0132=0\x0139=C\x01150=C\x01" *
              "25001=2\x0125024=7\x0125056=10\x0125057=250.00000000\x0125058=5\x0110=000\x01"
        fields = parse_fix_message(msg)
        er = FIXAPI.parse_execution_report(fields, msg)
        @test er.quote_notional_limit == "250.00000000"
        @test er.effective_self_trade_prevention == "5"
        @test er.self_trade_prevention == "2"
        @test er.expiry_reason == EXPIRY_INSUFFICIENT_QUOTE_NOTIONAL_LIMIT

        # Both tags are absent on ordinary reports.
        plain = "8=FIX.4.4\x0135=8\x0111=A\x0155=BTCUSDT\x0154=1\x0140=2\x0139=0\x01150=0\x0125001=2\x0110=000\x01"
        er = FIXAPI.parse_execution_report(parse_fix_message(plain), plain)
        @test er.quote_notional_limit == ""
        @test er.effective_self_trade_prevention == ""
    end

    @testset "QuoteNotionalLimit rules checked before sending" begin
        check = FIXAPI.validate_quote_notional_limit
        @test check(SIDE_BUY) === nothing
        @test_throws ArgumentError check(SIDE_SELL)
        @test_throws ArgumentError check(SIDE_BUY; cash_order_qty=100.0)
        @test_throws ArgumentError check(SIDE_BUY; exec_inst=EXEC_INST_PARTICIPATE_DONT_INITIATE)
        @test_throws ArgumentError check(SIDE_BUY; sor=true)
    end

    @testset "text FIX requests send tag 25057" begin
        fields = capture_fix_fields() do session
            new_order_single(session, "BTCUSDT", SIDE_BUY; quantity=10.0, price=30.0,
                quote_notional_limit=250.0)
        end
        @test fields[35] == "D"
        @test fields[TAG_QUOTE_NOTIONAL_LIMIT] == "250"

        # Omitted unless requested.
        fields = capture_fix_fields() do session
            new_order_single(session, "BTCUSDT", SIDE_BUY; quantity=10.0, price=30.0)
        end
        @test !haskey(fields, TAG_QUOTE_NOTIONAL_LIMIT)

        fields = capture_fix_fields() do session
            order_cancel_and_new_order(session, "BTCUSDT", SIDE_BUY, ORD_TYPE_LIMIT;
                cancel_orig_cl_ord_id="OLD", quantity=10.0, price=30.0, time_in_force=TIF_GTC,
                quote_notional_limit=250.0)
        end
        @test fields[35] == "XCN"
        @test fields[TAG_QUOTE_NOTIONAL_LIMIT] == "250"

        # In an order list the tag belongs to its own order, after the trigger
        # fields and before NoListTriggeringInstructions (25010).
        orders = [
            Dict{Symbol,Any}(:side => SIDE_BUY, :ord_type => ORD_TYPE_LIMIT, :quantity => 1.0,
                :price => 30.0, :time_in_force => TIF_GTC, :quote_notional_limit => 25.0,
                :list_trigger_instructions => [Dict(:trigger_type => "3", :trigger_index => 1, :action => "2")]),
            Dict{Symbol,Any}(:side => SIDE_BUY, :ord_type => ORD_TYPE_STOP_LIMIT, :quantity => 1.0,
                :price => 40.0, :trigger_price => 39.0, :trigger_price_direction => TRIGGER_UP,
                :time_in_force => TIF_GTC,
                :list_trigger_instructions => [Dict(:trigger_type => "1", :trigger_index => 0, :action => "2")]),
        ]
        port, server = listenany(Sockets.localhost, 20000)
        session = FIXSession("127.0.0.1", Int(port), "SENDER", "SPOT", test_binance_config())
        client = connect(Sockets.localhost, port)
        peer = accept(server)
        raw = try
            session.socket = BinanceFIX.FIXAPI.FIXConnection(client)
            new_order_list(session, "BTCUSDT", orders; contingency_type=CONTINGENCY_OCO)
            String(readavailable(peer))
        finally
            close(client); close(peer); close(server)
        end
        tags = [parse(Int, first(split(field, '='))) for field in split(raw, '\x01'; keepempty=false)]
        limit_positions = findall(==(TAG_QUOTE_NOTIONAL_LIMIT), tags)
        @test length(limit_positions) == 1                      # only the order that asked for it
        @test occursin("\x0125057=25\x01", raw)
        first_instruction = findfirst(==(25010), tags)
        second_order = findall(==(11), tags)[2]
        @test limit_positions[1] < first_instruction < second_order

        # A SELL order cannot carry the limit; nothing is sent.
        bad = [Dict{Symbol,Any}(:side => SIDE_SELL, :ord_type => ORD_TYPE_LIMIT, :quantity => 1.0,
                   :price => 30.0, :quote_notional_limit => 25.0),
               Dict{Symbol,Any}(:side => SIDE_SELL, :ord_type => ORD_TYPE_LIMIT, :quantity => 1.0, :price => 31.0)]
        @test_throws ArgumentError capture_fix_fields() do session
            new_order_list(session, "BTCUSDT", bad; contingency_type=CONTINGENCY_OCO)
        end
        @test_throws ArgumentError capture_fix_fields() do session
            new_order_single(session, "BTCUSDT", SIDE_SELL; quantity=1.0, price=30.0,
                quote_notional_limit=25.0)
        end
    end

    @testset "get_stp_info reports the applied STP mode" begin
        base = "8=FIX.4.4\x0135=8\x0111=A\x0155=BTCUSDT\x0154=1\x0140=2\x0139=C\x01150=C\x01" *
               "25001=2\x0125024=7\x0125030=1.0\x01"
        differs = base * "25058=5\x0110=000\x01"
        info = get_stp_info(FIXAPI.parse_execution_report(parse_fix_message(differs), differs))
        @test info.self_trade_prevention_mode == "2"
        @test info.effective_self_trade_prevention_mode == "5"
        # Tag 25058 is only sent when the applied mode differs from the order's.
        same = base * "10=000\x01"
        info = get_stp_info(FIXAPI.parse_execution_report(parse_fix_message(same), same))
        @test info.effective_self_trade_prevention_mode == "2"
    end

    @testset "FIX SBE schema version is selected per session" begin
        @test SBE_SCHEMA_VERSION_FIX == UInt16(1)          # default stays 1:1 during the rollout
        @test SBE_SCHEMA_VERSION_FIX_V2 == UInt16(2)
        config = test_binance_config()
        @test SBESession(config, "SENDER").schema_version == UInt16(1)
        @test SBESession(config, "SENDER"; schema_version=SBE_SCHEMA_VERSION_FIX_V2).schema_version == UInt16(2)
        @test_throws ArgumentError SBESession(config, "SENDER"; schema_version=3)

        v1 = encode_heartbeat(seq_num=UInt32(1))
        v2 = encode_heartbeat(seq_num=UInt32(1), schema_version=SBE_SCHEMA_VERSION_FIX_V2)
        @test header_version(v1) == 1
        @test header_version(v2) == 2
        @test_throws ArgumentError encode_heartbeat(seq_num=UInt32(1), schema_version=7)
    end

    @testset "FIX SBE 1:2 request blocks carry QuoteNotionalLimit" begin
        V2 = SBE_SCHEMA_VERSION_FIX_V2
        nos(; kwargs...) = encode_new_order_single(; seq_num=UInt32(1), symbol="BTC", side=UInt8('1'),
            ord_type=UInt8('2'), cl_ord_id="X", quantity=10.0, price=30.0, time_in_force=UInt8('1'), kwargs...)

        # Schema 1:1 layout is unchanged.
        @test block_length(nos()) == 76
        @test header_version(nos()) == 1
        # A limit cannot be expressed in 1:1: refuse instead of dropping it.
        @test_throws ArgumentError nos(quote_notional_limit=250.0)

        # Schema 1:2: 8 more bytes at offset 76, scaled by PriceExponent.
        buf = nos(schema_version=V2, quote_notional_limit=250.0)
        @test block_length(buf) == 84
        @test header_version(buf) == 2
        @test le_i64(buf, body_index(76)) == 25_000_000_000
        # Absent value is the SBE null for int64.
        @test le_i64(nos(schema_version=V2), body_index(76)) == typemin(Int64)
        # The fields before it are byte-identical to the 1:1 encoding.
        @test buf[body_index(0):body_index(75)] == nos()[body_index(0):body_index(75)]
        # Var data follows the longer block.
        @test buf[body_index(84)] == 0x01 && buf[body_index(85)] == UInt8('X')

        @test_throws ArgumentError encode_new_order_single(seq_num=UInt32(1), symbol="BTC",
            side=UInt8('2'), ord_type=UInt8('2'), cl_ord_id="X", quantity=1.0, price=30.0,
            schema_version=V2, quote_notional_limit=25.0)                       # SELL
        @test_throws ArgumentError nos(schema_version=V2, quote_notional_limit=250.0, sor=true)
        @test_throws ArgumentError nos(schema_version=V2, quote_notional_limit=250.0, cash_order_qty=5.0)
        @test_throws ArgumentError nos(schema_version=V2, quote_notional_limit=0.0)

        xcn(; kwargs...) = encode_order_cancel_request_and_new(; seq_num=UInt32(1), symbol="BTC",
            cl_ord_id="N", side=UInt8('1'), ord_type=UInt8('2'), mode=UInt8(1), cancel_cl_ord_id="C",
            orig_cl_ord_id="O", quantity=10.0, price=30.0, time_in_force=UInt8('1'), kwargs...)
        @test block_length(xcn()) == 86
        buf = xcn(schema_version=V2, quote_notional_limit=250.0)
        @test block_length(buf) == 94
        @test le_i64(buf, body_index(86)) == 25_000_000_000
        @test_throws ArgumentError xcn(quote_notional_limit=250.0)

        entries(limit) = [
            OrderListEntry(cl_ord_id="L1", symbol="BTC", side=UInt8('1'), ord_type=UInt8('2'),
                quantity=1.0, price=30.0, quote_notional_limit=limit),
            OrderListEntry(cl_ord_id="L2", symbol="BTC", side=UInt8('1'), ord_type=UInt8('4'),
                quantity=1.0, price=40.0, trigger_price=39.0),
        ]
        list(orders; kwargs...) = encode_new_order_list(; seq_num=UInt32(1), cl_list_id="LIST",
            contingency_type=UInt8(1), orders=orders, kwargs...)
        group = body_index(2)                      # Orders group header after the 2-byte root block
        @test le_u16(list(entries(nothing)), group) == 75
        buf = list(entries(25.0); schema_version=V2)
        @test block_length(buf) == 2
        @test le_u16(buf, group) == 83
        first_order = group + 3                    # blockLength(2) + numInGroup(1)
        @test le_i64(buf, first_order + 75) == 2_500_000_000
        # Second order: after the first block, its empty instruction group (2) and "L1"/"BTC" (3 + 4).
        second_order = first_order + 83 + 2 + 3 + 4
        @test le_i64(buf, second_order + 75) == typemin(Int64)
        @test_throws ArgumentError list(entries(25.0))                          # needs 1:2
    end

    @testset "FIX SBE ExecutionReport decodes the 1:2 fields" begin
        # Root block per spot-fixsbe-1_2.xml: 290 bytes, ExpiryReason at 280,
        # QuoteNotionalLimit at 281, EffectiveSelfTradePreventionMode at 289.
        function report(block_len; expiry=0xff, limit=typemin(Int64), effective=0x00)
            body = zeros(UInt8, block_len + 10)    # empty MiscFees group (3) + six empty var-data fields (7)
            body[1] = reinterpret(UInt8, Int8(-8)) # PriceExponent
            body[2] = reinterpret(UInt8, Int8(-8)) # QtyExponent
            block_len > 280 && (body[281] = expiry)
            if block_len >= 290
                body[282:289] .= reinterpret(UInt8, [limit])
                body[290] = effective
            end
            header = FIXSBEDecoder.FIXSBEMessageHeader(UInt16(block_len), UInt16(98), UInt16(1),
                UInt16(block_len >= 290 ? 2 : 1), UInt32(1), Int64(0))
            return decode_execution_report(header, body)
        end

        er = report(290; expiry=UInt8(10), limit=25_000_000_000, effective=UInt8('5'))
        @test er.expiry_reason == UInt8(10)                    # InsufficientQuoteNotionalLimit
        @test er.quote_notional_limit ≈ 250.0
        @test er.effective_self_trade_prevention_mode == UInt8('5')   # DECREMENT

        # Null values in a 1:2 message.
        er = report(290)
        @test er.expiry_reason === nothing
        @test er.quote_notional_limit === nothing
        @test er.effective_self_trade_prevention_mode === nothing

        # A 1:1 message (block 281) has ExpiryReason but neither new field.
        er = report(281; expiry=UInt8(9))
        @test er.expiry_reason == UInt8(9)                     # Exhausted
        @test er.quote_notional_limit === nothing
        @test er.effective_self_trade_prevention_mode === nothing
    end
end
