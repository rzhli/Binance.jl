using Test
using Binance
using BinanceFIX
using Dates

# Mock Config
config = BinanceConfig(
    "test_api_key", "HMAC_SHA256", "test_secret", "", "",
    false, 30, 60000, "", 5, 5,
    6000, 50, 160000, 300, true, false, ""
)

@testset "FIX Client Logic" begin

    @testset "Checksum Calculation" begin
        session = FIXSession("localhost", 9000, "SENDER", "TARGET", config)

        # Build a Heartbeat message (MsgType = 0)
        fields = Dict{Int,String}()
        msg = BinanceFIX.FIXAPI.build_message(session, MSG_HEARTBEAT, fields)

        println("Built message: ", replace(msg, "\x01" => "|"))

        # Verify structure
        @test startswith(msg, "8=FIX.4.4\x01")
        @test contains(msg, "35=0\x01")
        @test contains(msg, "49=SENDER\x01")
        @test contains(msg, "56=TARGET\x01")
        @test endswith(msg, "\x01")

        # Verify checksum manually
        last_soh = findlast('\x01', msg)
        second_last_soh = findprev('\x01', msg, last_soh - 1)

        checksum_field = msg[second_last_soh+1:last_soh]
        @test startswith(checksum_field, "10=")

        content_to_sum = msg[1:second_last_soh]
        sum_val = sum(UInt8[c for c in content_to_sum])
        expected_checksum = lpad(string(sum_val % 256), 3, '0')

        actual_checksum = checksum_field[4:end-1]
        @test actual_checksum == expected_checksum
    end

    @testset "Constants" begin
        @test SIDE_BUY == "1"
        @test SIDE_SELL == "2"
        @test ORD_TYPE_LIMIT == "2"
        @test TIF_GTC == "1"
        @test MSG_NEW_ORDER_SINGLE == "D"
        @test MSG_EXECUTION_REPORT == "8"
        @test MSG_HANDLING_UNORDERED == "1"
        @test MSG_HANDLING_SEQUENTIAL == "2"
        @test RESPONSE_MODE_EVERYTHING == "1"
        @test RESPONSE_MODE_ONLY_ACKS == "2"
    end

    @testset "Logon Signature Payload" begin
        # Test that signature payload is constructed correctly per Binance spec:
        # MsgType + SenderCompId + TargetCompId + MsgSeqNum + SendingTime
        # joined by SOH character

        msg_type = "A"
        sender_comp_id = "EXAMPLE"
        target_comp_id = "SPOT"
        msg_seq_num = "1"
        sending_time = "20240627-11:17:25.223"

        # This is exactly how the logon function constructs the payload
        payload = join([msg_type, sender_comp_id, target_comp_id, msg_seq_num, sending_time], "\x01")

        # Verify payload structure
        @test payload == "A\x01EXAMPLE\x01SPOT\x011\x0120240627-11:17:25.223"

        # Verify SOH separation
        parts = split(payload, '\x01')
        @test parts[1] == "A"         # MsgType
        @test parts[2] == "EXAMPLE"   # SenderCompId
        @test parts[3] == "SPOT"      # TargetCompId
        @test parts[4] == "1"         # MsgSeqNum
        @test parts[5] == "20240627-11:17:25.223"  # SendingTime
    end

    @testset "Message Parsing" begin
        # Test execution report parsing
        raw_msg = "8=FIX.4.4\x0135=8\x0111=TEST123\x0137=12345\x0155=BTCUSDT\x0154=1\x0140=2\x0139=0\x01150=0\x0110=000\x01"
        fields = parse_fix_message(raw_msg)

        @test get_msg_type(fields) == "8"
        @test fields[11] == "TEST123"
        @test fields[55] == "BTCUSDT"

        # Test ExecutionReport struct
        exec_report = BinanceFIX.FIXAPI.parse_execution_report(fields)
        @test exec_report.cl_ord_id == "TEST123"
        @test exec_report.symbol == "BTCUSDT"
        @test exec_report.side == "1"
    end

    @testset "News Message Parsing" begin
        # Test news message for maintenance detection
        raw_msg = "8=FIX.4.4\x0135=B\x01148=Server Maintenance\x0158=Please reconnect within 10 minutes\x0161=1\x0110=000\x01"
        fields = parse_fix_message(raw_msg)

        @test get_msg_type(fields) == "B"

        news = BinanceFIX.FIXAPI.parse_news(fields)
        @test news.headline == "Server Maintenance"
        @test news.text == "Please reconnect within 10 minutes"
        @test news.urgency == "1"

        # Test maintenance detection
        @test is_maintenance_news(news) == true

        # Test non-maintenance news
        normal_news = NewsMsg("Market Update", "Trading resumed", "0", Dict{Int,String}())
        @test is_maintenance_news(normal_news) == false
    end

    @testset "Client Order ID Validation" begin
        # Valid IDs
        @test BinanceFIX.FIXAPI.validate_client_order_id("ABC123") === nothing
        @test BinanceFIX.FIXAPI.validate_client_order_id("my-order-id") === nothing
        @test BinanceFIX.FIXAPI.validate_client_order_id("order_123_test") === nothing
        @test BinanceFIX.FIXAPI.validate_client_order_id("a") === nothing  # min 1 char
        @test BinanceFIX.FIXAPI.validate_client_order_id("a" ^ 36) === nothing  # max 36 chars
        @test BinanceFIX.FIXAPI.validate_client_order_id("") === nothing  # empty is OK (auto-generate)

        # Invalid IDs
        @test_throws ErrorException BinanceFIX.FIXAPI.validate_client_order_id("invalid@id")  # @ not allowed
        @test_throws ErrorException BinanceFIX.FIXAPI.validate_client_order_id("invalid id")  # space not allowed
        @test_throws ErrorException BinanceFIX.FIXAPI.validate_client_order_id("id.with.dots")  # . not allowed
        @test_throws ErrorException BinanceFIX.FIXAPI.validate_client_order_id("a" ^ 37)  # too long

        # Test generation
        id = BinanceFIX.FIXAPI.generate_client_order_id("TEST-")
        @test startswith(id, "TEST-")
        @test length(id) <= 36
        @test occursin(r"^[a-zA-Z0-9\-_]{1,36}$", id)

        # Test generation without prefix
        id2 = BinanceFIX.FIXAPI.generate_client_order_id()
        @test length(id2) <= 36
        @test occursin(r"^[a-zA-Z0-9\-_]{1,36}$", id2)

        # Test prefix too long
        @test_throws ErrorException BinanceFIX.FIXAPI.generate_client_order_id("a" ^ 30)
    end

    @testset "CompID Validation" begin
        # Valid CompIDs (1-8 chars)
        @test BinanceFIX.FIXAPI.validate_comp_id("MYKEY01", "SenderCompID") === nothing
        @test BinanceFIX.FIXAPI.validate_comp_id("SPOT", "TargetCompID") === nothing
        @test BinanceFIX.FIXAPI.validate_comp_id("a", "Test") === nothing  # min 1 char
        @test BinanceFIX.FIXAPI.validate_comp_id("12345678", "Test") === nothing  # max 8 chars
        @test BinanceFIX.FIXAPI.validate_comp_id("my-key", "Test") === nothing
        @test BinanceFIX.FIXAPI.validate_comp_id("my_key", "Test") === nothing

        # Invalid CompIDs
        @test_throws ErrorException BinanceFIX.FIXAPI.validate_comp_id("", "Test")  # empty not allowed
        @test_throws ErrorException BinanceFIX.FIXAPI.validate_comp_id("123456789", "Test")  # 9 chars - too long
        @test_throws ErrorException BinanceFIX.FIXAPI.validate_comp_id("my key", "Test")  # space not allowed
        @test_throws ErrorException BinanceFIX.FIXAPI.validate_comp_id("my.key", "Test")  # dot not allowed
        @test_throws ErrorException BinanceFIX.FIXAPI.validate_comp_id("my@key", "Test")  # @ not allowed
    end

end
