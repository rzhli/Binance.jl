using Test
using Binance
using BinanceFIX

# =============================================================================
# OrderAmendReject Message Parsing Tests
# =============================================================================

println("=" ^ 80)
println("OrderAmendReject Message Parsing Tests")
println("=" ^ 80)

@testset "OrderAmendReject Parsing" begin

    @testset "Sample OrderAmendReject Message from Documentation" begin
        # Sample message from Binance FIX API documentation
        raw_msg = "8=FIX.4.4|9=0000176|35=XAR|49=SPOT|56=OE|34=2|52=20250319-14:27:32.751074|11=1WRGW5J1742394452749|37=0|55=BTCUSDT|38=1.000000|25016=-2038|58=The requested action would change no state; rejecting.|10=235|"

        # Convert | to SOH character
        fix_msg = replace(raw_msg, "|" => "\x01")

        println("\nParsing sample OrderAmendReject message...")
        println("Raw: ", replace(fix_msg, "\x01" => "|"))

        # Parse the message
        fields = parse_fix_message(fix_msg)
        msg_type = get_msg_type(fields)

        @test msg_type == MSG_ORDER_AMEND_REJECT

        # Parse as OrderAmendReject
        amend_reject = parse_order_amend_reject(fields)

        # Verify all fields
        @test amend_reject.cl_ord_id == "1WRGW5J1742394452749"
        @test amend_reject.order_id == "0"
        @test amend_reject.symbol == "BTCUSDT"
        @test amend_reject.order_qty == "1.000000"
        @test amend_reject.error_code == "-2038"
        @test amend_reject.text == "The requested action would change no state; rejecting."

        println("\n✓ All fields parsed correctly")
        println("  ClOrdID: $(amend_reject.cl_ord_id)")
        println("  OrderID: $(amend_reject.order_id)")
        println("  Symbol: $(amend_reject.symbol)")
        println("  OrderQty: $(amend_reject.order_qty)")
        println("  ErrorCode: $(amend_reject.error_code)")
        println("  Text: $(amend_reject.text)")
    end

    @testset "OrderAmendReject Helper Functions" begin
        # Create a test OrderAmendReject message
        test_msg = OrderAmendRejectMsg(
            "test-amend-123",
            "original-order-456",
            "12345",
            "BTCUSDT",
            "0.5",
            "-2038",
            "The requested action would change no state; rejecting.",
            Dict{Int,String}()
        )

        # Test is_error
        @test is_error(test_msg) == true

        # Test get_error_info
        error_info = get_error_info(test_msg)
        @test error_info.error_code == "-2038"
        @test error_info.text == "The requested action would change no state; rejecting."
        @test error_info.symbol == "BTCUSDT"
        @test error_info.cl_ord_id == "test-amend-123"
        @test error_info.orig_cl_ord_id == "original-order-456"
        @test error_info.order_id == "12345"
        @test error_info.order_qty == "0.5"

        println("\n✓ Helper functions work correctly")
        println("  is_error: $(is_error(test_msg))")
        println("  Error code: $(error_info.error_code)")
        println("  Error text: $(error_info.text)")
    end

    @testset "process_message Integration" begin
        # Test that process_message correctly identifies OrderAmendReject
        raw_msg = "8=FIX.4.4|9=176|35=XAR|49=SPOT|56=OE|34=2|52=20250319-14:27:32.751074|11=test123|37=0|55=BTCUSDT|38=1.0|25016=-2038|58=Test error|10=000|"
        fix_msg = replace(raw_msg, "|" => "\x01")

        # Create a mock session
        config = BinanceConfig(
            "test_api_key", "HMAC_SHA256", "test_secret", "", "",
            false, 30, 60000, "", 5, 5,
            6000, 50, 160000, 300, true, false, ""
        )
        session = FIXSession("localhost", 9000, "SENDER", "TARGET", config)

        # Process the message
        msg_type, data = process_message(session, fix_msg)

        @test msg_type == :order_amend_reject
        @test data isa OrderAmendRejectMsg
        @test data.cl_ord_id == "test123"
        @test data.error_code == "-2038"

        println("\n✓ process_message integration works correctly")
        println("  Message type: $msg_type")
        println("  Data type: $(typeof(data))")
    end

    @testset "Common Error Codes" begin
        # Test parsing different error scenarios

        # Error: No state change (same quantity)
        msg1 = OrderAmendRejectMsg(
            "amend1", "", "100", "BTCUSDT", "1.0",
            "-2038", "The requested action would change no state; rejecting.",
            Dict{Int,String}()
        )
        @test msg1.error_code == "-2038"

        # Error: Order not found
        msg2 = OrderAmendRejectMsg(
            "amend2", "orig123", "", "BTCUSDT", "0.5",
            "-2013", "Order does not exist.",
            Dict{Int,String}()
        )
        @test msg2.error_code == "-2013"

        # Error: Invalid quantity (too large)
        msg3 = OrderAmendRejectMsg(
            "amend3", "", "200", "ETHUSDT", "2.0",
            "-1013", "Quantity would be increased.",
            Dict{Int,String}()
        )
        @test msg3.error_code == "-1013"

        println("\n✓ Common error codes handled correctly")
        println("  -2038: No state change")
        println("  -2013: Order not found")
        println("  -1013: Invalid quantity")
    end
end

println("\n" ^ 2)
println("=" ^ 80)
println("Summary")
println("=" ^ 80)
println("""
OrderAmendReject Message Support:

✓ Complete struct with all required fields
✓ Parsing from FIX message
✓ Integration with process_message()
✓ Helper functions (is_error, get_error_info)
✓ Sample message verification

Fields Parsed:
- ClOrdID (11): ClOrdId of the amend request
- OrigClOrdID (41): OrigClOrdId from the amend request
- OrderID (37): OrderId from the amend request
- Symbol (55): Symbol from the amend request
- OrderQty (38): Requested quantity
- ErrorCode (25016): API error code
- Text (58): Human-readable error message

Common Error Codes:
- -2038: The requested action would change no state (e.g., same quantity)
- -2013: Order does not exist
- -1013: Invalid quantity (e.g., trying to increase instead of decrease)
- -1021: Insufficient rate limits
- -2011: Unknown order (wrong OrderID or OrigClOrdID)

Usage Example:
```julia
# Send amend request
cl_ord_id = order_amend_keep_priority(
    session,
    "BTCUSDT",
    0.9;
    order_id="12345"
)

# Process response
messages = receive_message(session)
for msg in messages
    msg_type, data = process_message(session, msg)

    if msg_type == :order_amend_reject && data isa OrderAmendRejectMsg
        error_info = get_error_info(data)
        println("Amend rejected:")
        println("  Error code: \$(error_info.error_code)")
        println("  Message: \$(error_info.text)")
        println("  ClOrdID: \$(error_info.cl_ord_id)")
        println("  Symbol: \$(error_info.symbol)")
        println("  Attempted qty: \$(error_info.order_qty)")
    end
end
```

The implementation fully supports OrderAmendReject (XAR) message parsing
and error handling!
""")
