"""
Regression tests for the SBE schema 1.1 migration and the seven gaps
fixed in the 2026-05-10 audit. Run with:

    julia --project=BinanceFIX BinanceFIX/test/test_sbe_schema11.jl
"""

using Test
using BinanceFIX
using BinanceFIX.FIXSBEEncoder
using BinanceFIX.FIXAPI

const SOFH = 6
const HDR = 20

@testset "SBE schema 1.1 migration" begin

    @testset "schema version constant" begin
        @test BinanceFIX.SBE_SCHEMA_VERSION_FIX == UInt16(1)
        @test BinanceFIX.SBE_SCHEMA_VERSION_FIX_DEPRECATED == UInt16(0)
    end

    @testset "blockLength matches schema 1.1" begin
        # NewOrderSingle: 1+1+8+1+1+8+1+1+8+1+1+8+1+1+1+1+1+1+8+8+4+8+1+1 = 76
        buf = encode_new_order_single(seq_num=UInt32(1), symbol="BTC",
            side=UInt8(1), ord_type=UInt8(2), cl_ord_id="X",
            quantity=0.01, price=50.0, time_in_force=UInt8(1))
        @test reinterpret(UInt16, buf[SOFH+1:SOFH+2])[1] == 76

        # Logon: 1+4+1+1+1+1+1+4 = 14
        buf = encode_logon(sender_comp_id="S", target_comp_id="T",
            seq_num=UInt32(1), heartbeat_interval=UInt32(30),
            api_key="k", signature="s")
        @test reinterpret(UInt16, buf[SOFH+1:SOFH+2])[1] == 14

        # MarketDataRequest: 1+2+1 = 4
        buf = encode_market_data_request(seq_num=UInt32(1), md_req_id="M",
            subscription_request_type=UInt8(1), symbols=["BTC"],
            md_entry_types=[UInt8(0)])
        @test reinterpret(UInt16, buf[SOFH+1:SOFH+2])[1] == 4

        # XCN: 86 (mode + rateLimitMode + OrderID + CancelRestrictions + 2 exponents
        #          + new-order block of 76 less SOR=1 = 75, total 86)
        buf = encode_order_cancel_request_and_new(seq_num=UInt32(1),
            symbol="BTC", cl_ord_id="N", side=UInt8(1), ord_type=UInt8(2),
            mode=UInt8(1), cancel_cl_ord_id="C", orig_cl_ord_id="O",
            quantity=0.01, price=50.0, time_in_force=UInt8(1))
        @test reinterpret(UInt16, buf[SOFH+1:SOFH+2])[1] == 86
    end

    @testset "NewOrderList Orders group block size" begin
        orders = [
            OrderListEntry(cl_ord_id="L1", symbol="BTC", side=UInt8(2),
                ord_type=UInt8(4), quantity=0.01, price=49.0,
                trigger_price=49.5,
                list_triggering_instructions=[(UInt8(2), UInt8(1), UInt8(2))]),
            OrderListEntry(cl_ord_id="L2", symbol="BTC", side=UInt8(2),
                ord_type=UInt8(2), quantity=0.01, price=51.0,
                exec_inst=UInt8(0x36),
                list_triggering_instructions=[(UInt8(1), UInt8(0), UInt8(2))])
        ]
        buf = encode_new_order_list(seq_num=UInt32(1), cl_list_id="LIST",
            contingency_type=UInt8(1), orders=orders)
        # Root blockLength = 2 (ContingencyType + OPO)
        @test reinterpret(UInt16, buf[SOFH+1:SOFH+2])[1] == 2
        # Orders group header sits right after the 2-byte root block
        group_offset = SOFH + HDR + 2 + 1
        @test reinterpret(UInt16, buf[group_offset:group_offset+1])[1] == 75
        @test buf[group_offset+2] == 2
    end

    @testset "schemaId/version in header" begin
        buf = encode_logon(sender_comp_id="S", target_comp_id="T",
            seq_num=UInt32(1), heartbeat_interval=UInt32(30),
            api_key="k", signature="s")
        # Header layout (after SOFH): blockLength(2) templateId(2) schemaId(2) version(2)
        @test reinterpret(UInt16, buf[SOFH+5:SOFH+6])[1] == 1   # schemaId
        @test reinterpret(UInt16, buf[SOFH+7:SOFH+8])[1] == 1   # version (1.1 now)
    end

    @testset "NewOrderList rejects wrong order count" begin
        @test_throws ErrorException encode_new_order_list(
            seq_num=UInt32(1), cl_list_id="L", contingency_type=UInt8(1),
            orders=OrderListEntry[]
        )
        too_many = [
            OrderListEntry(cl_ord_id="$i", symbol="BTC", side=UInt8(1),
                ord_type=UInt8(2), quantity=0.01, price=50.0)
            for i in 1:4
        ]
        @test_throws ErrorException encode_new_order_list(
            seq_num=UInt32(1), cl_list_id="L", contingency_type=UInt8(1),
            orders=too_many
        )
    end
end

@testset "Text-FIX audit fixes" begin

    @testset "ExecutionReport carries expiry_reason" begin
        msg = "8=FIX.4.4\x019=200\x0135=8\x0134=1\x0149=SPOT\x01" *
              "52=20260510-12:00:00.000\x0156=TEST\x0111=ORD-1\x01" *
              "17=42\x0140=2\x0154=1\x0155=BTCUSDT\x0114=0\x0132=0\x01" *
              "39=C\x0150=C\x0125056=8\x0110=000\x01"
        fields = parse_fix_message(msg)
        er = FIXAPI.parse_execution_report(fields, msg)
        @test er.expiry_reason == "8"
        @test er.expiry_reason == EXPIRY_EXECUTION_RULE_PRICE_RANGE_EXCEEDED
    end

    @testset "parse_misc_fees handles multi-fee groups" begin
        msg = "8=FIX.4.4\x019=200\x0135=8\x0134=1\x0149=SPOT\x0156=T\x01" *
              "40=2\x0154=1\x0155=BTC\x0114=0\x0132=0\x0139=2\x0150=F\x01" *
              "136=2\x01" *
              "137=0.001\x01138=BNB\x01139=4\x01" *
              "137=0.0005\x01138=USDT\x01139=4\x01" *
              "10=000\x01"
        fields = parse_fix_message(msg)
        er = FIXAPI.parse_execution_report(fields, msg)
        @test length(er.fees) == 2
        @test er.fees[1].amount == "0.001"
        @test er.fees[1].currency == "BNB"
        @test er.fees[2].amount == "0.0005"
        @test er.fees[2].currency == "USDT"
    end

    @testset "parse_misc_fees falls back to single fee when no msg" begin
        # When raw msg isn't passed, dict has only the last fee. Old behavior preserved.
        msg = "8=FIX.4.4\x019=200\x0135=8\x0134=1\x0149=SPOT\x0156=T\x01" *
              "40=2\x0154=1\x0155=BTC\x0114=0\x0132=0\x0139=2\x0150=F\x01" *
              "136=1\x01137=0.001\x01138=BNB\x01139=4\x0110=000\x01"
        fields = parse_fix_message(msg)
        er = FIXAPI.parse_execution_report(fields)  # no msg arg
        @test length(er.fees) == 1
        @test er.fees[1].currency == "BNB"
    end
end

println("All BinanceFIX schema 1.1 regression tests passed.")
