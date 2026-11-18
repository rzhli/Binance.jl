# Offline tests for the FIX connection layer (no network beyond the loopback
# interface; the TLS handshake itself is only exercised against Binance).

using Test
using Sockets
using BinanceFIX
using BinanceFIX.FIXAPI: FIXConnection, take_bytes!
using BinanceFIX.FIXSBEEncoder

@testset "FIX connection" begin

    @testset "received bytes are buffered without an explicit read" begin
        port, server = listenany(Sockets.localhost, 22000)
        conn = FIXConnection(connect(Sockets.localhost, port))
        peer = accept(server)
        try
            @test isopen(conn)
            @test isempty(take_bytes!(conn))

            # A session only polls; the data must arrive on its own. (Polling
            # `bytesavailable` on an idle Julia socket never sees it.)
            write(peer, "8=FIX.4.4\x01"); flush(peer)
            @test timedwait(() -> !isempty(conn.buffer), 5.0) === :ok
            @test String(take_bytes!(conn)) == "8=FIX.4.4\x01"
            @test isempty(take_bytes!(conn))

            # Writes go out.
            write(conn, "ping"); flush(conn)
            @test String(read(peer, 4)) == "ping"

            # What the peer sent just before closing is still readable afterwards.
            write(peer, "bye"); close(peer)
            @test timedwait(() -> !isopen(conn), 5.0) === :ok
            @test String(take_bytes!(conn)) == "bye"
        finally
            close(conn); close(server)
        end
        @test !isopen(conn)
    end

    @testset "sessions receive through the connection" begin
        port, server = listenany(Sockets.localhost, 22000)
        session = FIXSession("127.0.0.1", Int(port), "SENDER", "SPOT", test_binance_config())
        session.socket = FIXConnection(connect(Sockets.localhost, port))
        peer = accept(server)
        try
            first_half = "8=FIX.4.4\x019=5\x0135=0\x01"
            write(peer, first_half); flush(peer)
            @test isempty(receive_message(session; timeout_ms=200))     # incomplete message
            write(peer, "10=000\x01"); flush(peer)
            messages = receive_message(session; timeout_ms=2000)
            @test messages == [first_half * "10=000\x01"]
        finally
            close_fix(session); close(peer); close(server)
        end
    end

    @testset "pump_messages dispatches parsed messages and keeps the session alive" begin
        port, server = listenany(Sockets.localhost, 22000)
        session = FIXSession("127.0.0.1", Int(port), "SENDER", "SPOT", test_binance_config())
        session.socket = FIXConnection(connect(Sockets.localhost, port))
        session.is_logged_in = true
        peer = accept(server)
        try
            # A Heartbeat and a TestRequest arrive; the TestRequest must be answered.
            write(peer, "8=FIX.4.4\x019=5\x0135=0\x0110=000\x01" *
                        "8=FIX.4.4\x019=14\x0135=1\x01112=PING\x0110=000\x01"); flush(peer)
            seen = Symbol[]
            n = pump_messages((type, data) -> push!(seen, type), session, 0.5)
            @test n == 2
            @test seen == [:heartbeat, :test_request]
            reply = String(readavailable(peer))
            @test occursin("\x0135=0\x01", reply) && occursin("\x01112=PING\x01", reply)

            # Recently sent something: no Heartbeat yet.
            session.last_sent_time = now(Dates.UTC) - Dates.Second(2)
            pump_messages((type, data) -> nothing, session, 0.2)
            @test bytesavailable(peer) == 0
            # Silent for longer than the heartbeat interval: a Heartbeat goes out
            # unprompted.
            session.heartbeat_interval = 5
            session.last_sent_time = now(Dates.UTC) - Dates.Second(6)
            @test pump_messages((type, data) -> nothing, session, 0.2) == 0
            @test occursin("\x0135=0\x01", String(readavailable(peer)))
        finally
            close_fix(session); close(peer); close(server)
        end
    end

    @testset "helpers: sender ids and decimal text" begin
        ids = [new_sender_comp_id() for _ in 1:50]
        @test all(id -> occursin(r"^[a-zA-Z0-9]{8}$", id), ids)
        @test length(unique(ids)) > 40
        # Julia prints small floats with an exponent; FIX needs plain decimals.
        @test string(0.00001) == "1.0e-5"
        @test fix_decimal(0.00001) == "0.00001"
        @test fix_decimal(0.001) == "0.001"
        @test fix_decimal(53427.69) == "53427.69"
        @test fix_decimal(100000.0) == "100000"
        @test fix_decimal(0.0) == "0"
        @test fix_decimal(1) == "1"
        @test_throws ArgumentError fix_decimal(NaN)
    end

    @testset "connect fails fast when nothing listens" begin
        port, server = listenany(Sockets.localhost, 22000)
        close(server)
        session = FIXSession("127.0.0.1", Int(port), "SENDER", "SPOT", test_binance_config())
        @test_throws ErrorException connect_fix(session)
    end

    @testset "SBE Logon header carries the caller's SendingTime" begin
        # The logon signature covers SendingTime, so the header must hold exactly
        # the instant that was signed (microseconds).
        micros = Int64(1_770_000_000_123_000)
        buf = encode_logon(sender_comp_id="S", target_comp_id="T", seq_num=UInt32(1),
            heartbeat_interval=UInt32(30), api_key="k", signature="s", sending_time=micros)
        @test reinterpret(Int64, buf[6+13:6+20])[1] == micros
        @test unix_micros(Dates.DateTime(1970, 1, 1, 0, 0, 1, 5)) == 1_005_000
    end

    @testset "SBE LogonAck and Reject decode per schema" begin
        D = BinanceFIX.FIXSBEDecoder
        # LogonAck: 6-byte root block, then UUID as varString8.
        body = vcat(UInt8[0x00, 0x1e, 0x00, 0x00, 0x00, 0x00], UInt8[0x04], codeunits("uuid"))
        header = D.FIXSBEMessageHeader(UInt16(6), UInt16(20009), UInt16(1), UInt16(1), UInt32(1), Int64(0))
        @test D.decode_logon_ack(header, body).uuid == "uuid"

        # Reject: RefSeqNum u32, RefTagID u32, SessionRejectReason u8, ErrorCode i32 (13 bytes),
        # then RefMsgType varString8 and Text varString16.
        body = vcat(reinterpret(UInt8, UInt32[1]), reinterpret(UInt8, UInt32[96]), UInt8[0x08],
            reinterpret(UInt8, Int32[-1022]), UInt8[0x01], codeunits("A"),
            reinterpret(UInt8, UInt16[3]), codeunits("bad"))
        header = D.FIXSBEMessageHeader(UInt16(13), UInt16(20003), UInt16(1), UInt16(1), UInt32(1), Int64(0))
        reject = D.decode_reject(header, collect(body))
        @test reject.ref_seq_num == 1
        @test reject.ref_tag_id == 96
        @test reject.session_reject_reason == 0x08
        @test reject.error_code == -1022
        @test reject.ref_msg_type == "A"
        @test reject.text == "bad"
    end
end
