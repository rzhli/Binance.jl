# FIX SBE response decoders and request encoders.
#
# The hex strings in `REAL_MESSAGES` are complete messages (SOFH + header + body)
# received from the Binance Spot testnet FIX SBE gateway on 2026-11-14. They hold
# testnet order ids and timestamps, no credentials. The expected values are the
# ones the test session itself sent (prices, quantities, client order ids) or
# that the gateway documents (error codes), so they check the decoders against
# the gateway rather than against themselves.

using Test
using Dates
using BinanceFIX
using BinanceFIX.FIXConstants
using BinanceFIX.FIXSBEEncoder
const SBED = BinanceFIX.FIXSBEDecoder

const REAL_MESSAGES = Dict{Symbol,String}(
    :list_status =>
        "d300000050eb140066000100020010000000bf5da45d3b6006000000000000000080010507ff00000000000000800d020000000000000080630bfcffff03013201320942617932697a62306c0742544355534454250046696c746572206661696c7572653a2050455243454e545f50524943455f42595f534944450000000000000080630bfcffff0301310032094165746331767067740742544355534454250046696c746572206661696c7572653a2050455243454e545f50524943455f42595f534944450b4f434f666f766b7033783500",
    :execution_report_C =>
        "5801000050eb22016200010002000c00000041814e5d3b600600f8f8e552cf01000000007da6d20000000000a0860100000000003231000028fda0e4040000000000000000000000800000ffffffffffffffffff00ff00000000000000008033827f4e5d3b600600827f4e5d3b6006000000000000000080000000000000008000000000000000800000008000000000000000800033430000000000000000a0860100000000000000000000000000010000000000000080000000000000008000000000000000004300000000000000800000000000000080000000000000008000ffff827f4e5d3b60060000000000000000800000000000000080000000000000008000000000000000800000000000000080000000000000008000000000000000800000000000000080ffff00000080050000000000000080000a00000b4f49442d3366303038626400074254435553445400000000",
    :execution_report_0 =>
        "5901000050eb2201620001000200040000006923b10c35600600f8f8a7deca01000000000991d00000000000a086010000000000323100402ed9f5db040000000000000000000000800000ffffffffffffffffff00ff000000000000000080315c22b10c356006005c22b10c356006000000000000000080000000000000008000000000000000800000008000000000000000800033300000000000000000a0860100000000000000000000000000010000000000000080000000000000008000000000000000003000000000000000800000000000000080000000000000008000ff015c22b10c3560060000000000000000800000000000000080000000000000008000000000000000800000000000000080000000000000008000000000000000800000000000000080ffff00000080ff0000000000000080000a00000c4f49442d656434316262643500074254435553445400000000",
    :execution_report_F =>
        "5901000050eb22016200010002000c000000f4914f0d35600600f8f825dfca01000000004791d0000000000010270000000000003131000000000000000080000000000000000000800000ffffffffffffffffff00ff0000000000000000803153904f0d3560060053904f0d3560060000000000000000800000000000000080000000000000008000000080000000000000008000334610270000000000000000000000000000b070c62700000000011a5329000000000000db91b71106000010270000000000003200000000000000800000000000000080000000000000008000ffff53904f0d3560060000000000000000800000000000000080000000000000008000000000000000800000000000000080000000000000008000000000000000800000000000000080ffff00000080ff0000000000000080000a00000c4f49442d623561646330383800074254435553445400000000",
    :execution_report_5 =>
        "6501000050eb220162000100020006000000482ce90c35600600f8f8b1deca01000000000991d0000000000060ea000000000000323100402ed9f5db040000000000000000000000800000ffffffffffffffffff00ff00000000000000008031e52ae90c356006005c22b10c35600600000000000000008000000000000000800000000000000080000000800000000000000080003335000000000000000060ea0000000000000000000000000000010000000000000080000000000000008000000000000000003000000000000000800000000000000080000000000000008000ffff5c22b10c3560060000000000000000800000000000000080000000000000008000000000000000800000000000000080000000000000008000000000000000800000000000000080ffff00000080ff0000000000000080000a00000c414d442d62616364353466390c4f49442d6564343162626435074254435553445400000000",
    :execution_report_4 =>
        "6501000050eb22016200010002000f000000585bad0d35600600f8f83bdfca01000000000991d0000000000060ea000000000000323100402ed9f5db040000000000000000000000800000ffffffffffffffffff00ff00000000000000008031d859ad0d356006005c22b10c35600600000000000000008000000000000000800000000000000080000000800000000000000080003334000000000000000060ea0000000000000000000000000000010000000000000080000000000000008000000000000000003400000000000000800000000000000080000000000000008000ffff5c22b10c3560060000000000000000800000000000000080000000000000008000000000000000800000000000000080000000000000008000000000000000800000000000000080ffff00000080ff0000000000000080000a00000c4d43582d39313532383130310c414d442d6261636435346639074254435553445400000000",
    :execution_report_8 =>
        "8f01000050eb220162000100020008000000eaf5010d35600600f8f800000000000000800000000000000080a086010000000000323100404acda1d9040000000000000000000000800000ffffffffffffffffff00ff0000000000000000803113f4010d3560060000000000000000800000000000000080000000000000008000000000000000800000008000000000000000800031380000000000000000a0860100000000000000000000000000010000000000000080000000000000008000000000000000003800000000000000800000000000000080000000000000008000ffff000000000000008000000000000000800000000000000080000000000000008000000000000000800000000000000080000000000000008000000000000000800000000000000080ff6326f8ffffff0000000000000080000a00000c4f49442d323066343663643500074254435553445400003600556e61626c6520746f2063616e63656c206f726465722c206f7264657220706c6163656d656e74206e6f7420617474656d707465642e",
    :execution_report_ack =>
        "5000000050eb1f00c600010002000200000034fa1a0e356006008d91d0000000000000000000000000808ff81a0e356006003030ff000000800c4f49442d343630313132313207425443555344540000",
    :order_cancel_reject =>
        "6800000050eb160060000100020007000000e8f5010d3560060000000000000000800000000000000080ff3125f8ffff0c43584c2d36313362303666380c4f49442d65643431626264350007425443555344541300556e6b6e6f776e206f726465722073656e742e",
    :order_amend_reject =>
        "8400000050eb15006a0001000200050000005785d10c356006000000000000000080f8400d0300000000000af8ffff0c414d442d32346233346434330c4f49442d6564343162626435074254435553445431004f7264657220616d656e6420287175616e7469747920696e63726561736529206973206e6f7420737570706f727465642e",
    :order_mass_cancel_report =>
        "4000000050eb0f00680001000200100000008e5bad0d356006003131ff01000000000000000000008007425443555344540c4d43582d39313532383130310000",
    :limit_response =>
        "6b00000050eb000079000100020002000000a0a8800c35600600160332010000000000000010270000000000000a0000007331000000000000000032000000000000000a00000073310000000000000000007102000000000001000000640c4c4d512d3534663462613539",
    :reject =>
        "5f00000050eb0d00234e010002000e000000b833860d356006000d0000003b00000063aefbffff014534004120746167202754696d65496e466f726365202835392927207761732073656e74207768656e206e6f742072657175697265642e",
    :heartbeat =>
        "2000000050eb0000214e010002002e00000071c3250c356006000550494e4731",
    :logout =>
        "3200000050eb0000244e0100020034000000fd523d0c3560060016004c6f676f75742061636b6e6f776c6564676d656e742e",
    :instrument_list =>
        "8100000050eb0000c90001000200020000000c26770b356006004a000100f8f8e80300000000000000282e8cd1000000e803000000000000000000000000000088f1881e03000000000000000000000040420f000000000000407a10f35a000040420f0000000000074254435553445404555344540b494c522d36326238646361",
    :market_data_snapshot =>
        "5200000050eb0a00cc00010002000300000036c69b0b35600600ba3bff0000000000f8f810010080eb5af31206000058dd081c00000000100100c02d6af312060000988da70f000000000742544355534454",
    :market_data_incremental_book_ticker =>
        "4000000050eb0a00ce000100020004000000c652a40b35600600c33bff0000000000f8f810001001c02d6af3120600008866a70f000000000742544355534454",
    :market_data_incremental_depth =>
        "4a00000050eb1200cf000100020007000000cb53d10b35600600cb3bff0000000000cb3bff0000000000f8f810000010010000c016af64060000b0360000000000000742544355534454",
    :market_data_incremental_trade =>
        "4b00000050eb0a00cd00010002000c000000f596db0b356006007092db0b35600600f8f8190001000000135329000000000080eb5af3120600001027000000000000320742544355534454",
    :market_data_reject =>
        "8300000050eb0500cb0001000200170000007cdbfe0b35600600315afbffff04444550315d00274d4452657149442028323632292720636f6e7461696e73206120737562736372697074696f6e2072657175657374206964207468617420697320616c726561647920696e20757365206f6e207468697320636f6e6e656374696f6e2e",
)

real(kind::Symbol) = hex2bytes(REAL_MESSAGES[kind])
decoded(kind::Symbol) = decode_sbe_message(real(kind))[2]
ch(c::Char) = UInt8(c)

# Little-endian byte builders for hand-made messages.
le(x::Integer) = collect(reinterpret(UInt8, [x]))
str8(s) = vcat(UInt8(sizeof(s)), codeunits(s))
str16(s) = vcat(le(UInt16(sizeof(s))), codeunits(s))
sbe_header(template, block; version=1) = SBED.FIXSBEMessageHeader(
    UInt16(block), UInt16(template), UInt16(1), UInt16(version), UInt32(7), Int64(1_700_000_000_000_000))

@testset "FIX SBE decoders" begin

    @testset "every real message is consumed exactly" begin
        for (name, hex) in REAL_MESSAGES
            bytes = hex2bytes(hex)
            msg = SBED.decode_fix_sbe_message(bytes)
            kind, decoder = SBED.DECODERS[msg.header.templateId]
            @test decode_sbe_message(bytes)[1] == kind
            # Removing the final byte must break the decode: the decoder read
            # up to the last byte of the message, no less.
            @test_throws Exception decoder(msg.header, msg.body[1:end-1])
        end
    end

    @testset "ExecutionReport: resting limit order" begin
        er = decoded(:execution_report_0)
        @test er.cl_ord_id == "OID-ed41bbd5"
        @test er.symbol == "BTCUSDT"
        @test er.order_id == 13668617
        @test er.exec_id == 30072487
        @test er.side == ch('1')                  # BUY
        @test er.ord_type == ch('2')              # LIMIT
        @test er.time_in_force == ch('1')         # GTC
        @test er.order_qty == 0.001               # as sent
        @test er.price == 53427.69                # as sent
        @test er.exec_type == ch('0')             # NEW
        @test er.ord_status == ch('0')
        @test er.cum_qty == 0.0
        @test er.leaves_qty == 0.001
        @test er.last_qty == 0.0
        @test er.transact_time == 1794630822732380
        @test er.order_creation_time == er.transact_time == er.working_time
        @test er.working_indicator == 0x01
        @test er.self_trade_prevention_mode == ch('3')
        # Null on the wire -> nothing
        @test all(isnothing, (er.list_id, er.last_px, er.trade_id, er.cash_order_qty, er.exec_inst,
            er.max_floor, er.trigger_price, er.trigger_type, er.peg_price_type, er.pegged_price,
            er.target_strategy, er.strategy_id, er.ord_rej_reason, er.error_code, er.expiry_reason,
            er.quote_notional_limit, er.effective_self_trade_prevention_mode, er.prevented_match_id,
            er.alloc_id, er.sor, er.trailing_time))
        @test isempty(er.fees)
        @test er.orig_cl_ord_id == "" && er.text == "" && er.counter_symbol == ""
        @test er.seq_num == 4
    end

    @testset "ExecutionReport: market order fill" begin
        er = decoded(:execution_report_F)
        @test er.exec_type == ch('F')             # TRADE
        @test er.ord_status == ch('2')            # FILLED
        @test er.ord_type == ch('1')              # MARKET
        @test er.price === nothing
        @test er.order_qty == 0.0001
        @test er.cum_qty == 0.0001
        @test er.leaves_qty == 0.0
        @test er.last_qty == 0.0001
        @test er.last_px == 66731.64
        @test er.cum_quote_qty == 6.673164
        @test er.last_px * er.last_qty ≈ er.cum_quote_qty
        @test er.trade_id == 2708250
        @test er.order_id == 13668679
        @test er.aggressor_indicator == 0x01
    end

    @testset "ExecutionReport: replaced, canceled, rejected" begin
        replaced = decoded(:execution_report_5)
        @test replaced.exec_type == ch('5')
        @test replaced.cl_ord_id == "AMD-bacd54f9"
        @test replaced.orig_cl_ord_id == "OID-ed41bbd5"
        @test replaced.order_qty == 0.0006        # amended quantity, as sent
        @test replaced.price == 53427.69

        canceled = decoded(:execution_report_4)
        @test canceled.exec_type == ch('4') && canceled.ord_status == ch('4')
        @test canceled.cl_ord_id == "MCX-91528101"
        @test canceled.orig_cl_ord_id == "AMD-bacd54f9"
        @test canceled.order_id == 13668617

        rejected = decoded(:execution_report_8)
        @test rejected.exec_type == ch('8') && rejected.ord_status == ch('8')
        @test rejected.order_id === nothing
        @test rejected.ord_rej_reason == 99       # OTHER
        @test rejected.error_code == -2010
        @test rejected.text == "Unable to cancel order, order placement not attempted."
        @test rejected.price == 53327.69
    end

    @testset "ExecutionReportAck" begin
        ack = decoded(:execution_report_ack)
        @test ack.order_id == 13668749
        @test ack.list_id === nothing
        @test ack.cl_ord_id == "OID-46011212"
        @test ack.symbol == "BTCUSDT"
        @test ack.exec_type == ch('0') && ack.ord_status == ch('0')
        @test ack.ord_rej_reason === nothing
        @test ack.transact_time == 1794630846445711
        @test ack.error_code === nothing
        @test ack.text == ""
    end

    @testset "OrderCancelReject, OrderAmendReject, OrderMassCancelReport" begin
        r = decoded(:order_cancel_reject)
        @test r.cl_ord_id == "CXL-613b06f8"
        @test r.orig_cl_ord_id == "OID-ed41bbd5"
        @test r.orig_cl_list_id == ""
        @test r.symbol == "BTCUSDT"
        @test r.order_id === nothing && r.list_id === nothing && r.cancel_restrictions === nothing
        @test r.cxl_rej_response_to == ch('1')
        @test r.error_code == -2011
        @test r.text == "Unknown order sent."

        a = decoded(:order_amend_reject)
        @test a.cl_ord_id == "AMD-24b34d43"
        @test a.orig_cl_ord_id == "OID-ed41bbd5"
        @test a.symbol == "BTCUSDT"
        @test a.order_qty == 0.002                # the rejected quantity, as sent
        @test a.error_code == -2038
        @test a.text == "Order amend (quantity increase) is not supported."

        m = decoded(:order_mass_cancel_report)
        @test m.cl_ord_id == "MCX-91528101"
        @test m.symbol == "BTCUSDT"
        @test m.mass_cancel_request_type == ch('1')
        @test m.mass_cancel_response == ch('1')
        @test m.mass_cancel_reject_reason === nothing
        @test m.total_affected_orders == 1
        @test m.error_code === nothing
    end

    @testset "LimitResponse" begin
        l = decoded(:limit_response)
        @test l.req_id == "LMQ-54f4ba59"
        @test [(x.limit_type, Int(x.limit_count), Int(x.limit_max), Int(x.limit_reset_interval),
                x.limit_reset_interval_resolution) for x in l.limits] ==
              [(ch('2'), 1, 10000, 10, ch('s')), (ch('1'), 0, 50, 10, ch('s')), (ch('1'), 0, 160000, 1, ch('d'))]
    end

    @testset "Reject, Heartbeat, Logout" begin
        r = decoded(:reject)
        @test r.ref_seq_num == 13
        @test r.ref_tag_id == 59
        @test r.ref_msg_type == "E"
        @test r.session_reject_reason == 99
        @test r.error_code == -1106
        @test r.text == "A tag 'TimeInForce (59)' was sent when not required."

        @test decoded(:heartbeat).test_req_id == "PING1"
        @test decoded(:heartbeat).seq_num == 46
        @test decoded(:logout).text == "Logout acknowledgment."
    end

    @testset "InstrumentList" begin
        list = decoded(:instrument_list)
        @test list.instrument_req_id == "ILR-62b8dca"
        @test length(list.instruments) == 1
        i = list.instruments[1]
        @test (i.symbol, i.currency) == ("BTCUSDT", "USDT")
        @test (i.price_exponent, i.qty_exponent) == (-8, -8)
        @test i.min_trade_vol == 0.00001
        @test i.max_trade_vol == 9000.0
        @test i.min_qty_increment == 0.00001
        @test i.market_min_trade_vol == 0.0
        @test i.market_max_trade_vol == 133.97193096
        @test i.start_price_range == 0.01
        @test i.end_price_range == 1.0e6
        @test i.min_price_increment == 0.01
    end

    @testset "Market data" begin
        snap = decoded(:market_data_snapshot)
        @test snap.symbol == "BTCUSDT"
        @test snap.last_book_update_id == 16726970
        @test [(e.entry_type, e.price, e.size) for e in snap.entries] ==
              [(SBE_MD_ENTRY_BID, 66784.62, 4.70343), (SBE_MD_ENTRY_OFFER, 66784.63, 2.62639)]
        @test all(e -> e.symbol == "BTCUSDT" && e.last_book_update_id == 16726970, snap.entries)

        ticker = decoded(:market_data_incremental_book_ticker)
        @test ticker.symbol == "BTCUSDT"
        @test ticker.last_book_update_id == 16726979
        @test [(e.entry_type, e.price, e.size) for e in ticker.entries] == [(SBE_MD_ENTRY_OFFER, 66784.63, 2.62629)]

        depth = decoded(:market_data_incremental_depth)
        @test (depth.first_book_update_id, depth.last_book_update_id) == (16726987, 16726987)
        @test [(e.entry_type, e.price, e.size) for e in depth.entries] == [(SBE_MD_ENTRY_OFFER, 70295.04, 0.00014)]

        trade = decoded(:market_data_incremental_trade)
        @test trade.transact_time == 1794630808736368
        @test length(trade.entries) == 1
        t = trade.entries[1]
        @test (t.entry_type, t.price, t.size, t.trade_id, t.aggressor_side) ==
              (SBE_MD_ENTRY_TRADE, 66784.62, 0.0001, 2708243, ch('2'))
        @test t.transact_time == trade.transact_time

        rej = decoded(:market_data_reject)
        @test rej.md_req_id == "DEP1"
        @test rej.reject_reason == ch('1')        # DUPLICATE_MDREQID
        @test rej.error_code == -1190
        @test startswith(rej.text, "'MDReqID (262)' contains a subscription request id")
    end

    @testset "ExecutionReport: expired IOC order carries ExpiryReason" begin
        er = decoded(:execution_report_C)
        @test er.exec_type == ch('C') && er.ord_status == ch('C')
        @test er.time_in_force == ch('3')                 # IOC, as sent
        @test er.expiry_reason == 5                       # UNFILLED_IOC_QUANTITY_EXPIRED
        @test er.cum_qty == 0.0 && er.leaves_qty == 0.001
        @test er.price == 53800.0
    end

    @testset "ListStatus: rejected OCO list" begin
        ls = decoded(:list_status)
        @test ls.cl_list_id == "OCOfovkp3x5"
        @test ls.contingency_type == 1                    # OCO, as sent
        @test ls.list_status_type == 5                    # ALL_DONE
        @test ls.list_order_status == 7                   # REJECT
        @test ls.list_id === nothing
        @test [o.cl_ord_id for o in ls.orders] == ["Bay2izb0l", "Aetc1vpgt"]
        @test all(o -> o.symbol == "BTCUSDT" && o.error_code == -1013 && o.ord_rej_reason == 99 &&
                       o.text == "Filter failure: PERCENT_PRICE_BY_SIDE" && o.order_id === nothing, ls.orders)
        # The triggering instructions are echoed exactly as the request sent them.
        @test ls.orders[1].list_triggering_instructions == [(ch('2'), 0x01, ch('2'))]
        @test ls.orders[2].list_triggering_instructions == [(ch('1'), 0x00, ch('2'))]
    end

    # ---- Layouts no real message was captured for: built from the schema ----

    @testset "ListStatus (from schema)" begin
        order(id, rej, err, instructions, cl, text) = vcat(
            le(Int64(id)), UInt8(rej), le(Int32(err)),
            UInt8[0x03, length(instructions)], reduce(vcat, [collect(UInt8, i) for i in instructions]; init=UInt8[]),
            str8(cl), str8("BTCUSDT"), str16(text))
        body = vcat(
            le(Int64(4242)), UInt8(1), UInt8(2), UInt8(3), UInt8(0xff), le(Int64(1_700_000_000_000_001)),   # root block (20)
            UInt8[13, 2],                                                                                  # Orders: blockLength, numInGroup
            order(101, 0xff, typemin(Int32), [(ch('2'), 0x01, ch('2'))], "below", ""),
            order(typemin(Int64), 99, -2010, [(ch('1'), 0x00, ch('2')), (ch('3'), 0x00, ch('1'))], "above", "rejected"),
            str8("list-1"), str8("orig-list"))
        ls = SBED.decode_list_status(sbe_header(102, 20), body)
        @test ls.list_id == 4242
        @test ls.contingency_type == 1 && ls.list_status_type == 2 && ls.list_order_status == 3
        @test ls.list_reject_reason === nothing
        @test ls.transact_time == 1_700_000_000_000_001
        @test ls.cl_list_id == "list-1" && ls.orig_cl_list_id == "orig-list"
        @test length(ls.orders) == 2
        @test (ls.orders[1].order_id, ls.orders[1].cl_ord_id, ls.orders[1].symbol) == (101, "below", "BTCUSDT")
        @test ls.orders[1].ord_rej_reason === nothing && ls.orders[1].error_code === nothing
        @test ls.orders[1].list_triggering_instructions == [(ch('2'), 0x01, ch('2'))]
        @test ls.orders[2].order_id === nothing
        @test (ls.orders[2].ord_rej_reason, ls.orders[2].error_code, ls.orders[2].text) == (99, -2010, "rejected")
        @test ls.orders[2].list_triggering_instructions == [(ch('1'), 0x00, ch('2')), (ch('3'), 0x00, ch('1'))]
        @test_throws Exception SBED.decode_list_status(sbe_header(102, 20), body[1:end-1])
    end

    @testset "ExecutionReport fees and version-dependent fields (from schema)" begin
        # Start from the real fill and splice two MiscFees entries into its
        # (empty) group: Exponent int8, MiscFeeAmt mantissa64, MiscFeeType uint8,
        # then MiscFeeCurr as var data.
        msg = SBED.decode_fix_sbe_message(real(:execution_report_F))
        block = Int(msg.header.blockLength)
        @test block == 290 && msg.header.version == 2      # testnet answers in schema 1:2
        @test msg.body[block+1:block+3] == UInt8[0x0a, 0x00, 0x00]
        fee(exp, mantissa, cur) = vcat(reinterpret(UInt8, Int8(exp)), le(Int64(mantissa)), UInt8(4), str8(cur))
        body = vcat(msg.body[1:block], UInt8[0x0a, 0x02, 0x00],
            fee(-8, 10, "BTC"), fee(-6, 1500, "BNB"), msg.body[block+4:end])
        er = SBED.decode_execution_report(msg.header, body)
        @test [(f.amount, f.currency, f.fee_type) for f in er.fees] == [(1.0e-7, "BTC", 0x04), (0.0015, "BNB", 0x04)]
        @test er.cl_ord_id == "OID-b5adc088" && er.symbol == "BTCUSDT"      # var data after the group still lines up

        # The same message cut down to the 1:1 and 1:0 block lengths: the fields
        # those versions lack decode as `nothing`, everything else is unchanged.
        for (len, version) in ((281, 1), (280, 0))
            older = vcat(msg.body[1:len], msg.body[block+1:end])
            header = sbe_header(98, len; version=version)
            er = SBED.decode_execution_report(header, older)
            @test er.trade_id == 2708250 && er.last_px == 66731.64 && er.cl_ord_id == "OID-b5adc088"
            @test er.quote_notional_limit === nothing
            @test er.effective_self_trade_prevention_mode === nothing
            @test er.expiry_reason === nothing
        end

        # Values in the 1:1 / 1:2 fields.
        body = copy(msg.body)
        body[281] = 0x0a                                              # ExpiryReason = InsufficientQuoteNotionalLimit
        body[282:289] .= le(Int64(25_000_000_000))                    # QuoteNotionalLimit, PriceExponent -8
        body[290] = ch('5')                                           # EffectiveSelfTradePreventionMode = DECREMENT
        er = SBED.decode_execution_report(msg.header, body)
        @test er.expiry_reason == 10
        @test er.quote_notional_limit == 250.0
        @test er.effective_self_trade_prevention_mode == ch('5')

        # A block shorter than schema 1:0 cannot be an ExecutionReport.
        @test_throws ArgumentError SBED.decode_execution_report(sbe_header(98, 100), msg.body)
    end

    @testset "News and LogonAck (from schema)" begin
        news = SBED.decode_news(sbe_header(20100, 0), str16("You'll be disconnected in 600 seconds. Please reconnect."))
        @test news.headline == "You'll be disconnected in 600 seconds. Please reconnect."
        ack = SBED.decode_logon_ack(sbe_header(20009, 6), vcat(UInt8[0x00], le(UInt32(30)), UInt8[0x00], str8("uuid-1")))
        @test ack.uuid == "uuid-1"
    end

    @testset "malformed groups are rejected before any allocation" begin
        # LimitResponse claiming 200 entries of 22 bytes in a 5-byte body.
        @test_throws ArgumentError SBED.decode_limit_response(sbe_header(121, 0), UInt8[22, 200, 0x00, 0x00, 0x00])
        # A group entry smaller than the schema's fields.
        @test_throws ArgumentError SBED.decode_limit_response(sbe_header(121, 0), vcat(UInt8[4, 1], zeros(UInt8, 4), 0x00))
        # Root block longer than the body.
        @test_throws ArgumentError SBED.decode_execution_report_ack(sbe_header(198, 31), zeros(UInt8, 10))
    end
end

@testset "FIX SBE request encoding" begin
    body_of(buf) = buf[27:end]                      # after SOFH (6) + header (20)
    block_length(buf) = reinterpret(UInt16, buf[7:8])[1]
    i64(b, off) = reinterpret(Int64, b[off+1:off+8])[1]

    @testset "char enums are sent as ASCII characters" begin
        @test char_enum(UInt8(1)) == ch('1')        # bare digit
        @test char_enum(ch('1')) == ch('1')         # already a character code
        @test char_enum('2') == ch('2')
        @test char_enum(ch('P')) == ch('P')         # Pegged
        @test char_enum(ch('D')) == ch('D')

        by_digit = encode_new_order_single(seq_num=UInt32(1), symbol="BTCUSDT", side=UInt8(1),
            ord_type=UInt8(2), cl_ord_id="X", quantity=0.001, price=50000.0, time_in_force=UInt8(1))
        by_char = encode_new_order_single(seq_num=UInt32(1), symbol="BTCUSDT", side=ch('1'),
            ord_type=ch('2'), cl_ord_id="X", quantity=0.001, price=50000.0, time_in_force=ch('1'))
        b = body_of(by_digit)
        @test b == body_of(by_char)
        @test b[11] == ch('2')                      # OrdType at offset 10
        @test b[45] == ch('1')                      # Side at offset 44
        @test b[46] == ch('1')                      # TimeInForce at offset 45
        @test i64(b, 2) == 100_000                  # OrderQty 0.001 at exponent -8
        @test i64(b, 12) == 5_000_000_000_000       # Price 50000 at exponent -8
    end

    @testset "absent optional fields carry the SBE null of their type" begin
        b = body_of(encode_new_order_single(seq_num=UInt32(1), symbol="BTCUSDT", side=ch('1'),
            ord_type=ch('1'), cl_ord_id="X", quantity=0.001))
        @test b[12] == 0x00                          # ExecInst (char)
        @test i64(b, 12) == typemin(Int64)           # Price
        @test b[21] == 0x00 && b[22] == 0x00         # TriggerType, TriggerAction (char)
        @test i64(b, 22) == typemin(Int64)           # TriggerPrice
        @test b[31] == 0x00 && b[32] == 0x00         # TriggerPriceType, TriggerPriceDirection (char)
        @test reinterpret(UInt64, b[33:40])[1] == typemax(UInt64)   # TriggerTrailingDeltaBips (uint64)
        @test b[41] == 0xff                          # PegOffsetValue (uint8)
        @test b[42] == 0x00                          # PegPriceType (char)
        @test b[43] == 0xff                          # PegMoveType (uint8 enum)
        @test b[44] == 0x00                          # PegOffsetType (char)
        @test b[46] == 0x00                          # TimeInForce (char)
        @test i64(b, 46) == typemin(Int64)           # MaxFloor
        @test i64(b, 54) == typemin(Int64)           # CashOrderQty
        @test reinterpret(Int32, b[63:66])[1] == typemin(Int32)     # TargetStrategy
        @test i64(b, 66) == typemin(Int64)           # StrategyID
        @test b[75] == 0x00                          # SelfTradePreventionMode (char)
        @test b[76] == 0xff                          # SOR (boolEnum, uint8)

        cancel = body_of(encode_order_cancel_request(seq_num=UInt32(1), symbol="BTCUSDT", cl_ord_id="C",
            orig_cl_ord_id="O"))
        @test i64(cancel, 0) == typemin(Int64)       # OrderID
        @test i64(cancel, 8) == typemin(Int64)       # ListID
        @test cancel[17] == 0xff                     # CancelRestrictions (uint8 enum)
    end

    @testset "messages with an empty root block declare blockLength 0" begin
        # Their body starts with var data; a non-zero blockLength makes the
        # gateway skip into it and answer -1221.
        for buf in (encode_heartbeat(seq_num=UInt32(1), test_req_id="T"),
                    encode_test_request(seq_num=UInt32(1), test_req_id="T"),
                    encode_logout(seq_num=UInt32(1), text="bye"),
                    encode_limit_query(seq_num=UInt32(1), req_id="R"))
            @test block_length(buf) == 0
        end
        @test body_of(encode_limit_query(seq_num=UInt32(1), req_id="R")) == UInt8[0x01, ch('R')]
    end

    @testset "other char-encoded request fields" begin
        mass = body_of(encode_order_mass_cancel_request(seq_num=UInt32(1), symbol="BTCUSDT", cl_ord_id="M"))
        @test mass[1] == ch('1')                     # MassCancelRequestType = CANCEL_SYMBOL_ORDERS

        md = encode_market_data_request(seq_num=UInt32(1), md_req_id="M", subscription_request_type=UInt8(1),
            symbols=["BTCUSDT"], market_depth=UInt16(1), md_entry_types=[UInt8(0), UInt8(1)])
        b = body_of(md)
        @test b[1] == ch('1')                        # SubscriptionRequestType = SUBSCRIBE
        @test b[end-3:end-2] == UInt8[ch('0'), ch('1')]   # MDEntryTypes just before MDReqID ("\x01M")
    end

    @testset "Logon matches the sample message in the Binance FIX SBE documentation" begin
        # https://developers.binance.com/docs/binance-spot-api-docs/fix-api#sample-fix-sbe-logon-request-message
        # The sample uses schema version 0; the encoder writes 1. Everything else
        # must match byte for byte.
        documented = hex2bytes(
            "d100000050eb" *                                  # SOFH: messageLength 209, encodingType 0xEB50
            "0e00" * "284e" * "0100" * "0000" *               # blockLength 14, templateId 20008, schemaId 1, version 0
            "01000000" * "587a5f99db1b0600" *                 # seqNum 1, sendingTime
            "00" * "1e000000" * "01" * "02" * "ff" * "ff" * "ff" * "ffffffff" *   # fixed block
            "07" * bytes2hex(codeunits("EXAMPLE")) *
            "04" * bytes2hex(codeunits("SPOT")) *
            "5800" * bytes2hex(codeunits("4MHXelVVcpkdwuLbl6n73HQUXUf1dse2PCgT1DYqW9w8AVZ1RACFGM+5UdlGPrQHrgtS3CvsRURC1oj73j8gCA==")) *
            "4000" * bytes2hex(codeunits("sBRXrJx2DsOraMXOaUovEhgVRcjOvCtQwnWj8VxkOh1xqboS02SPGfKi2h8spZJb")))
        @test length(documented) == 209
        ours = encode_logon(sender_comp_id="EXAMPLE", target_comp_id="SPOT", seq_num=UInt32(1),
            heartbeat_interval=UInt32(30), message_handling=UInt8(2),
            api_key="sBRXrJx2DsOraMXOaUovEhgVRcjOvCtQwnWj8VxkOh1xqboS02SPGfKi2h8spZJb",
            signature="4MHXelVVcpkdwuLbl6n73HQUXUf1dse2PCgT1DYqW9w8AVZ1RACFGM+5UdlGPrQHrgtS3CvsRURC1oj73j8gCA==",
            sending_time=reinterpret(Int64, documented[19:26])[1])
        @test ours[13:14] == UInt8[0x01, 0x00]       # our schema version
        expected = copy(documented); expected[13:14] .= ours[13:14]
        @test ours == expected
    end
end
