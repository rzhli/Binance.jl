using Test
using Binance
using BinanceFIX

# =============================================================================
# ListStatus Message Parsing Tests
# =============================================================================

println("=" ^ 80)
println("ListStatus Message Parsing Tests")
println("=" ^ 80)

@testset "ListStatus Parsing" begin

    @testset "Sample ListStatus Message from Documentation" begin
        # Sample message from Binance FIX API documentation
        raw_msg = "8=FIX.4.4|9=293|35=N|34=2|49=SPOT|52=20240607-02:19:07.837191|56=Eg13pOvN|55=BTCUSDT|60=20240607-02:19:07.836000|66=25|73=2|55=BTCUSDT|37=52|11=w1717726747805308656|55=BTCUSDT|37=53|11=p1717726747805308656|25010=1|25011=3|25012=0|25013=1|429=4|431=3|1385=2|25014=1717726747805308656|25015=1717726747805308656|10=162|"

        # Convert | to SOH character
        fix_msg = replace(raw_msg, "|" => "\x01")

        println("\nParsing sample ListStatus message...")
        println("Raw: ", replace(fix_msg, "\x01" => "|"))

        # Parse using the raw parser
        list_status = parse_list_status_from_raw(fix_msg)

        # Verify basic fields
        @test list_status.symbol == "BTCUSDT"
        @test list_status.list_id == "25"
        @test list_status.cl_list_id == "1717726747805308656"
        @test list_status.orig_cl_list_id == "1717726747805308656"
        @test list_status.contingency_type == "2"  # OTO
        @test list_status.list_status_type == "4"  # EXEC_STARTED
        @test list_status.list_order_status == "3"  # EXECUTING
        @test list_status.transact_time == "20240607-02:19:07.836000"

        println("\n✓ Basic fields parsed correctly")
        println("  Symbol: $(list_status.symbol)")
        println("  ListID: $(list_status.list_id)")
        println("  ClListID: $(list_status.cl_list_id)")
        println("  ContingencyType: $(list_status.contingency_type) (OTO)")
        println("  ListStatusType: $(list_status.list_status_type) (EXEC_STARTED)")
        println("  ListOrderStatus: $(list_status.list_order_status) (EXECUTING)")

        # Verify orders
        @test length(list_status.orders) == 2
        println("\n✓ Orders parsed: $(length(list_status.orders)) orders")

        if length(list_status.orders) >= 2
            println("  Order 1:")
            println("    OrderID: $(list_status.orders[1].order_id)")
            println("    ClOrdID: $(list_status.orders[1].cl_ord_id)")

            println("  Order 2:")
            println("    OrderID: $(list_status.orders[2].order_id)")
            println("    ClOrdID: $(list_status.orders[2].cl_ord_id)")
        end
    end

    @testset "ListStatus Helper Functions" begin
        # Create a test ListStatus message
        test_msg = ListStatusMsg(
            "BTCUSDT",
            "25",
            "test123",
            "",
            CONTINGENCY_OCO,
            LIST_STATUS_EXEC_STARTED,
            LIST_ORDER_STATUS_EXECUTING,
            "",
            "",
            "20240607-02:19:07.836000",
            "",
            "",
            ListStatusOrder[],
            Dict{Int,String}()
        )

        # Test helper functions
        @test is_list_executing(test_msg) == true
        @test is_list_all_done(test_msg) == false
        @test is_list_rejected(test_msg) == false
        @test is_list_exec_started(test_msg) == true
        @test is_oco_list(test_msg) == true
        @test is_oto_list(test_msg) == false
        @test get_list_order_count(test_msg) == 0

        println("\n✓ Helper functions work correctly")
        println("  is_list_executing: $(is_list_executing(test_msg))")
        println("  is_list_exec_started: $(is_list_exec_started(test_msg))")
        println("  is_oco_list: $(is_oco_list(test_msg))")
    end

    @testset "ListStatus Error Handling" begin
        # Create a rejected list status
        rejected_msg = ListStatusMsg(
            "BTCUSDT",
            "",
            "test456",
            "",
            CONTINGENCY_OCO,
            LIST_STATUS_RESPONSE,
            LIST_ORDER_STATUS_REJECT,
            LIST_REJECT_REASON_OTHER,
            "",
            "20240607-02:19:07.836000",
            "-1013",
            "Invalid quantity",
            ListStatusOrder[],
            Dict{Int,String}()
        )

        @test is_list_rejected(rejected_msg) == true

        error_info = get_list_error_info(rejected_msg)
        @test !isnothing(error_info)
        @test error_info.error_code == "-1013"
        @test error_info.text == "Invalid quantity"

        println("\n✓ Error handling works correctly")
        println("  is_list_rejected: $(is_list_rejected(rejected_msg))")
        println("  Error code: $(error_info.error_code)")
        println("  Error text: $(error_info.text)")
    end

    @testset "ListStatus Constants" begin
        # Verify all constants are defined
        @test LIST_STATUS_RESPONSE == "2"
        @test LIST_STATUS_EXEC_STARTED == "4"
        @test LIST_STATUS_ALL_DONE == "5"
        @test LIST_STATUS_UPDATED == "100"

        @test LIST_ORDER_STATUS_EXECUTING == "3"
        @test LIST_ORDER_STATUS_ALL_DONE == "6"
        @test LIST_ORDER_STATUS_REJECT == "7"

        @test LIST_REJECT_REASON_OTHER == "99"

        println("\n✓ All ListStatus constants defined correctly")
    end
end

println("\n" ^ 2)
println("=" ^ 80)
println("Summary")
println("=" ^ 80)
println("""
ListStatus Message Support:

✓ Comprehensive parsing with nested repeating groups
✓ Support for all ListStatusType values (RESPONSE, EXEC_STARTED, ALL_DONE, UPDATED)
✓ Support for all ListOrderStatus values (EXECUTING, ALL_DONE, REJECT)
✓ Helper functions for status checking
✓ Error information extraction
✓ OCO/OTO/OTOCO detection

Helper Functions Available:
- is_list_executing(msg)      - Check if list is executing
- is_list_all_done(msg)        - Check if list is complete
- is_list_rejected(msg)        - Check if list was rejected
- is_list_response(msg)        - Check if this is a response
- is_list_exec_started(msg)    - Check if execution started
- is_list_updated(msg)         - Check if this is an update
- is_oco_list(msg)             - Check if OCO list
- is_oto_list(msg)             - Check if OTO/OTOCO list
- get_list_error_info(msg)     - Extract error information
- get_list_order_count(msg)    - Get number of orders

Usage Example:
```julia
# Receive and process ListStatus messages
messages = receive_message(session)
for msg in messages
    msg_type, data = process_message(session, msg)

    if msg_type == :list_status && data isa ListStatusMsg
        println("List Status Update:")
        println("  ListID: \$(data.list_id)")
        println("  Status: \$(data.list_order_status)")

        if is_list_executing(data)
            println("  Order list is executing...")
        elseif is_list_all_done(data)
            println("  Order list completed!")
        elseif is_list_rejected(data)
            error_info = get_list_error_info(data)
            println("  Order list rejected: \$(error_info.text)")
        end

        println("  Orders in list: \$(get_list_order_count(data))")
    end
end
```

Note: ListStatus messages are sent by default for all order lists on the account,
including those submitted in different connections. Use ResponseMode to control
this behavior.
""")
