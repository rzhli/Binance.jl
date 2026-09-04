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
        # 2026-09-02 的文档样例：顶层 Symbol (55) 已从 QuickFIX schema 和字段表中移除
        # （服务器早已停发）。BodyLength 也从 293 降到 282。每个 tag 55 都属于
        # NoOrders (73) 组内的条目。
        raw_msg = "8=FIX.4.4|9=282|35=N|34=2|49=SPOT|52=20240607-02:19:07.837191|56=Eg13pOvN|60=20240607-02:19:07.836000|66=25|73=2|55=BTCUSDT|37=52|11=w1717726747805308656|55=BTCUSDT|37=53|11=p1717726747805308656|25010=1|25011=3|25012=0|25013=1|429=4|431=3|1385=2|25014=1717726747805308656|25015=1717726747805308656|10=223|"

        # Convert | to SOH character
        fix_msg = replace(raw_msg, "|" => "\x01")

        println("\nParsing sample ListStatus message...")
        println("Raw: ", replace(fix_msg, "\x01" => "|"))

        # Parse using the raw parser
        list_status = parse_list_status(fix_msg)

        # Verify basic fields
        @test list_status.list_id == "25"
        @test list_status.cl_list_id == "1717726747805308656"
        @test list_status.orig_cl_list_id == "1717726747805308656"
        @test list_status.contingency_type == "2"  # OTO
        @test list_status.list_status_type == "4"  # EXEC_STARTED
        @test list_status.list_order_status == "3"  # EXECUTING
        @test list_status.transact_time == "20240607-02:19:07.836000"

        # 顶层 symbol 字段已移除，改从首个订单条目取。
        @test !hasproperty(list_status, :symbol)
        @test get_list_symbol(list_status) == "BTCUSDT"

        println("\n✓ Basic fields parsed correctly")
        println("  Symbol (from first order): $(get_list_symbol(list_status))")
        println("  ListID: $(list_status.list_id)")
        println("  ClListID: $(list_status.cl_list_id)")
        println("  ContingencyType: $(list_status.contingency_type) (OTO)")
        println("  ListStatusType: $(list_status.list_status_type) (EXEC_STARTED)")
        println("  ListOrderStatus: $(list_status.list_order_status) (EXECUTING)")

        # Verify orders
        @test length(list_status.orders) == 2
        @test all(o -> o.symbol == "BTCUSDT", list_status.orders)
        @test [o.order_id for o in list_status.orders] == ["52", "53"]
        @test [o.cl_ord_id for o in list_status.orders] ==
              ["w1717726747805308656", "p1717726747805308656"]
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

    @testset "Legacy top-level Symbol is tolerated" begin
        # 假如某个网关仍发顶层 Symbol（旧文档样例就是这个形态），解析器不能因此
        # 把它误当成第一个 NoOrders 条目的分隔符：那会多出一个空单或错位。
        legacy = replace(
            "8=FIX.4.4|9=293|35=N|34=2|49=SPOT|52=20240607-02:19:07.837191|56=Eg13pOvN|55=BTCUSDT|60=20240607-02:19:07.836000|66=25|73=2|55=BTCUSDT|37=52|11=w1717726747805308656|55=BTCUSDT|37=53|11=p1717726747805308656|25010=1|25011=3|25012=0|25013=1|429=4|431=3|1385=2|25014=1717726747805308656|25015=1717726747805308656|10=162|",
            "|" => "\x01")

        parsed = parse_list_status(legacy)

        @test length(parsed.orders) == 2
        @test [o.order_id for o in parsed.orders] == ["52", "53"]
        @test get_list_symbol(parsed) == "BTCUSDT"
        # 旧字段仍能从 raw_fields 里取到，不会因为结构体字段消失而丢数据。
        @test parsed.raw_fields[TAG_SYMBOL] == "BTCUSDT"

        println("\n✓ Legacy message with top-level Symbol still parses to 2 orders")
    end

    @testset "get_list_symbol with no orders" begin
        # 被拒的列表可能根本没下单，NoOrders 组为空——这时返回 "" 而不是报错。
        empty_list = ListStatusMsg(
            "25", "test", "", CONTINGENCY_OCO,
            LIST_STATUS_RESPONSE, LIST_ORDER_STATUS_REJECT,
            LIST_REJECT_REASON_OTHER, "", "20240607-02:19:07.836000",
            "-1013", "Invalid quantity",
            ListStatusOrder[], Dict{Int,String}()
        )
        @test get_list_symbol(empty_list) == ""
        @test get_list_order_count(empty_list) == 0
    end

    @testset "ListStatus Helper Functions" begin
        # Create a test ListStatus message
        test_msg = ListStatusMsg(
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
