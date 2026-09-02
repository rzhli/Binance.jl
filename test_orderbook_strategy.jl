"""
手工组装 OrderBookManager 的交易策略示例  —  Binance.jl v0.13.0

本文件走的是**底层手动路径**：自己创建 OrderBookManager、自己写监控循环、
自己做资源清理。适合需要定制监控输出或把订单簿接入其他系统的场景。

若只想直接跑策略，用 `single_run_test.jl` 里的高层入口更省事：
  - `run_single_orderbook_strategy` / `run_multi_orderbook_strategy`
  它们已经封装了连接认证、exchangeInfo、用户数据流、监控循环与清理。

三种行情驱动方式对比：

【方式 1】Ticker 流（最简单，数据最少）
  - 数据：只有最新成交价
  - 延迟：~10-50ms
  - 适用：简单价格触发
    callback = create_on_ticker(rest_client, strategy)
    subscribe_ticker(stream_client, "BTCUSDT", callback)

【方式 2】Depth 快照流（中等）
  - 数据：5-20 档订单簿快照
  - 延迟：~20-100ms（每次解析 JSON）
  - 适用：需要浅层订单簿但访问不频繁
    callback = create_on_depth(rest_client, strategy)
    subscribe_depth(stream_client, "BTCUSDT", callback; levels=5)

【方式 3】OrderBookManager（最强）⭐ 推荐
  - 数据：最多 5000 档完整订单簿 + VWAP / 深度不平衡等派生指标
  - 延迟：< 1ms（本地内存访问）
  - 适用：高频、做市、套利、深度分析
    ob = create_orderbook_with_strategy(rest, stream, ws, strategy)
    start!(ob)

⚠️  价位都是占位值，会用真实资金下单。请改成自己的价位后再运行。

前置条件：本文件依赖 `strategy/` 目录，而那个目录在 `.gitignore` 里（个人交易
策略，不随包发布）。从仓库新克隆后下面的 `include` 会报
`SystemError: opening file ...`。只需要库本身的示例看 `examples/`。
"""

using Binance, Dates

# 只 include 一次：重复 include 会产生两个同名但不同的模块对象，既会让
# TradeStrategy 跨套传参报 MethodError，也会让同名导出无法隐式解析
# （`UndefVarError: ... not defined in Main`）。
include("./strategy/OrderBook.jl")
using .OrderBookStrategy
using .OrderBookStrategy.StrategyCommon: TradeStrategy, create_strategy,
    print_strategy_levels, account_position, execution_report, create_risk_manager,
    format_price
using .OrderBookStrategy.StrategyMonitoring: run_multi_monitoring_loop

const CONFIG_FILE = "config.toml"

# ============================================================================
# 示例 1: 单币种 + OrderBookManager（含诊断监控循环）
# ============================================================================

function run_single_orderbook_manual(;
    symbol::String = "BTCUSDT",
    buy_prices::Vector{Float64} = [55000.0, 20000.0],
    buy_quantities::Vector{Float64} = [5.0, 5.0],      # USDT 金额
    sell_prices::Vector{Float64} = [115000.0, 125000.0],
    sell_percentages::Vector{Float64} = [0.5, 1.0],    # 持仓比例
    max_depth::Int = 5000,
    update_speed::String = "100ms",
    imbalance_levels::Int = 20,
    poll_interval::Real = 10.0,
    # 诊断阈值
    verbose_mode::Bool = false,          # true = 每轮都打印诊断，false = 仅异常
    freeze_threshold::Float64 = 5.0,     # 价格与 updateId 静止多久算冻结（秒）
    low_rate_threshold::Float64 = 0.5,   # 回调速率下限（次/秒）
    high_rate_threshold::Float64 = 50.0, # 回调速率上限（次/秒）
    config_file::String = CONFIG_FILE,
)
    println("="^70)
    println("示例 1: 使用 OrderBookManager 的单币种策略")
    println("="^70)

    rest_client = RESTClient(config_file)
    stream_client = SBEStreamClient(config_file)
    ws_client = WebSocketClient(config_file)

    orderbook = nothing
    try
        connect!(ws_client)
        session_logon(ws_client)

        # 获取交易对信息。symbol_info 是必需的：
        # execute_trade 缺少它会拒绝下单（没有过滤器就无法校验精度与最小名义金额）。
        exchangeinfo = exchangeInfo(ws_client, symbol=symbol)
        symbol_info = exchangeinfo.symbols[1]

        strategy = create_strategy(
            symbol, buy_prices, buy_quantities, sell_prices;
            sell_percentages = sell_percentages,
            is_quote_qty = true,          # true = buy_quantities 是 USDT 金额
            symbol_info = symbol_info,
        )
        print_strategy_levels(strategy)

        # 用户数据流回调（余额变动 + 成交回报）
        on_event(ws_client, "outboundAccountPosition", account_position(strategy))
        on_event(ws_client, "executionReport", execution_report(strategy))
        userdata_stream_subscribe(ws_client)

        # 风险管理器：下单前查冷却期与日亏损上限，成交后记账。
        # 不传则完全不施加约束。
        risk_manager = create_risk_manager(
            max_daily_loss_pct = 5.0,
            cooldown_seconds = 60.0,
        )

        # 诊断计数器（由 create_orderbook_with_strategy 包装的回调递增）
        callback_count = Ref{Int}(0)
        last_callback_time = Ref{Float64}(time())

        orderbook = create_orderbook_with_strategy(
            rest_client, stream_client, ws_client, strategy;
            max_depth = max_depth,
            update_speed = update_speed,
            callback_count = callback_count,
            last_callback_time = last_callback_time,
            risk_manager = risk_manager,
        )

        println("启动 OrderBookManager...")
        start!(orderbook)

        print("等待订单簿初始化")
        for _ in 1:30
            is_ready(orderbook) && break
            print(".")
            sleep(1)
        end
        println(is_ready(orderbook) ? " ✓" : " ✗")

        if !is_ready(orderbook)
            @error "订单簿初始化失败" symbol
            return nothing
        end

        session_status(ws_client)

        println("="^70)
        println("OrderBookManager 运行中")
        println("="^70)
        println("策略会自动监控订单簿并触发买卖条件")
        println("按 Ctrl+C 停止...")
        println("="^70)
        println()

        # 诊断状态
        prev_bid_price = 0.0
        prev_ask_price = 0.0
        prev_update_id = Int64(0)
        prev_callback_count = 0
        frozen_warnings = 0

        try
            while true
                sleep(poll_interval)

                if !is_ready(orderbook)
                    println("  ⚠️  订单簿未就绪")
                    continue
                end

                best_bid = get_best_bid(orderbook)
                best_ask = get_best_ask(orderbook)
                imbalance = calculate_depth_imbalance(orderbook; levels=imbalance_levels)

                if isnothing(best_bid) || isnothing(best_ask) || isnothing(imbalance)
                    println("  ⚠️  暂无双边报价")
                    continue
                end

                current_update_id = orderbook.update_id[]
                current_callback_count = callback_count[]
                time_since_update = time() - last_callback_time[]
                callback_rate = (current_callback_count - prev_callback_count) / poll_interval

                price_changed = best_bid.price != prev_bid_price || best_ask.price != prev_ask_price
                update_id_changed = current_update_id != prev_update_id
                is_frozen = !price_changed && !update_id_changed && time_since_update > freeze_threshold
                is_rate_low = callback_rate < low_rate_threshold
                is_rate_high = callback_rate > high_rate_threshold
                is_update_slow = time_since_update > 2.0

                signal = if imbalance > 0.3
                    "强买压 🟢"
                elseif imbalance > 0.1
                    "买压 🟩"
                elseif imbalance < -0.3
                    "强卖压 🔴"
                elseif imbalance < -0.1
                    "卖压 🟥"
                else
                    "中性 ⚪"
                end

                # format_price 按价格量级选小数位数：低价币（SHIB 等）不会被打成 0.0
                println("[监控] 买: ", format_price(best_bid.price),
                        " | 卖: ", format_price(best_ask.price),
                        " | 不平衡: ", round(imbalance, digits=3), " | ", signal)

                if verbose_mode || is_frozen || is_rate_low || is_rate_high || is_update_slow
                    println("  [诊断] 更新ID: $current_update_id | 回调: $current_callback_count",
                            " | 速率: $(round(callback_rate, digits=1))/s",
                            " | 延迟: $(round(time_since_update, digits=2))s")

                    if is_frozen
                        frozen_warnings += 1
                        println("  ⚠️  冻结警告: 价格和 updateId 静止超过 $(freeze_threshold)s (第 $frozen_warnings 次)")
                    end
                    is_rate_low && println("  ⚠️  速率过低: $(round(callback_rate, digits=1))/s < $(low_rate_threshold)/s")
                    is_rate_high && println("  ⚠️  速率过高: $(round(callback_rate, digits=1))/s > $(high_rate_threshold)/s")
                    is_update_slow && println("  ⚠️  更新延迟: $(round(time_since_update, digits=2))s")
                end

                if (price_changed || update_id_changed) && frozen_warnings > 0
                    println("  ✓ 价格/updateId 已更新，恢复正常")
                    frozen_warnings = 0
                end

                prev_bid_price = best_bid.price
                prev_ask_price = best_ask.price
                prev_update_id = current_update_id
                prev_callback_count = current_callback_count
            end
        catch e
            isa(e, InterruptException) || rethrow()
            println("\n接收到中断信号，正在清理...")
        end
    finally
        # cleanup_resources 内部自带标题，并逐步 best-effort：
        # 任一步报错不会中断后续清理（否则 SBE / WebSocket 连接会泄漏）。
        isnothing(orderbook) || cleanup_resources(ws_client, stream_client, orderbook)
        try
            close(rest_client)   # v0.13.0：释放 HTTP.jl 连接池的空闲连接
        catch e
            @warn "关闭 REST 连接池失败" exception = e
        end
        println("✓ 完成")
    end
end

# run_single_orderbook_manual(symbol = "BTCUSDT")

# ============================================================================
# 示例 2: 多币种 + OrderBookManager
# ============================================================================
#
# 与示例 1 的差别：
#   - exchangeInfo 一次批量拉取，按 symbol 建 Dict 索引
#     （返回顺序不保证与请求顺序一致，按下标取会把过滤器配错到别的币种上）
#   - 用户数据回调注册的是策略**向量**，回调内部按 symbol 分发，只需注册一次
#   - risk_manager 在所有币种间共享：日亏损额度与冷却期是账户级约束
#   - 监控循环复用 StrategyMonitoring.run_multi_monitoring_loop

# strategy_table 只需支持列访问（NamedTuple of vectors / DataFrame 皆可）。
function run_multi_orderbook_manual(strategy_table;
    is_quote_qty::Bool = true,
    max_depth::Int = 1000,               # 多币种用较小深度：每个 manager 约 1-5 MB
    update_speed::String = "100ms",
    monitor_interval::Real = 30.0,
    config_file::String = CONFIG_FILE,
)
    println("\n" * "="^70)
    println("示例 2: 使用 OrderBookManager 的多币种策略")
    println("="^70)
    println()

    rest_client = RESTClient(config_file)
    stream_client = SBEStreamClient(config_file)
    ws_client = WebSocketClient(config_file)

    orderbooks = Any[]
    try
        connect!(ws_client)
        session_logon(ws_client)

        symbols = collect(strategy_table.symbol)

        exchangeinfo = exchangeInfo(ws_client, symbols=symbols)
        symbol_info_map = Dict(si.symbol => si for si in exchangeinfo.symbols)

        risk_manager = create_risk_manager(
            max_daily_loss_pct = 5.0,
            cooldown_seconds = 60.0,
        )

        strategies = TradeStrategy[]
        active_symbols = String[]

        for i in eachindex(symbols)
            symbol = symbols[i]
            symbol_info = get(symbol_info_map, symbol, nothing)
            if isnothing(symbol_info)
                @warn "exchangeInfo 未返回该交易对，跳过" symbol
                continue
            end

            buy_prices = strategy_table.buy_prices[i]
            buy_quantities = fill(strategy_table.buy_quantity[i], length(buy_prices))

            strategy = create_strategy(
                symbol,
                buy_prices,
                buy_quantities,
                strategy_table.sell_prices[i];
                sell_percentages = strategy_table.sell_percentages[i],
                is_quote_qty = is_quote_qty,
                symbol_info = symbol_info,
            )
            push!(strategies, strategy)
            push!(active_symbols, symbol)

            orderbook = create_orderbook_with_strategy(
                rest_client, stream_client, ws_client, strategy;
                max_depth = max_depth,
                update_speed = update_speed,
                risk_manager = risk_manager,
            )
            push!(orderbooks, orderbook)

            println("✓ 已创建 $symbol 策略和订单簿管理器")
        end

        if isempty(strategies)
            @error "没有可用的交易对"
            return nothing
        end

        # 传策略向量：回调内部按 symbol 分发，无需逐币种注册
        on_event(ws_client, "outboundAccountPosition", account_position(strategies))
        on_event(ws_client, "executionReport", execution_report(strategies))
        userdata_stream_subscribe(ws_client)
        println("\n✓ 用户数据流已订阅\n")

        println("启动所有 OrderBookManager...")
        for (symbol, ob) in zip(active_symbols, orderbooks)
            start!(ob)
            println("✓ $symbol OrderBookManager 已启动")
        end
        println()

        println("等待所有订单簿初始化...")
        all_ready = false
        for _ in 1:30
            all_ready = all(is_ready(ob) for ob in orderbooks)
            all_ready && break
            sleep(1)
        end

        if !all_ready
            not_ready = [s for (s, ob) in zip(active_symbols, orderbooks) if !is_ready(ob)]
            @error "部分订单簿初始化失败" not_ready
            return nothing
        end
        println("✓ 所有订单簿已初始化")

        println()
        println("="^70)
        println("所有策略运行中")
        println("="^70)
        println("监控 $(length(active_symbols)) 个交易对，每 $monitor_interval 秒一次摘要")
        println("按 Ctrl+C 停止...")
        println("="^70)
        println()

        # 共享的多币种监控循环（内部捕获 Ctrl-C 后正常返回）
        run_multi_monitoring_loop(active_symbols, orderbooks; interval=monitor_interval)
    finally
        # cleanup_multi_resources 同样自带标题与 best-effort 逐步清理
        isempty(orderbooks) || cleanup_multi_resources(ws_client, stream_client, orderbooks)
        try
            close(rest_client)
        catch e
            @warn "关闭 REST 连接池失败" exception = e
        end
        println("✓ 完成")
    end
end

multi_strategy_table = (
    symbol = ["BTCUSDT", "ETHUSDT", "SOLUSDT"],
    buy_prices = [
        [95000.0, 90000.0],
        [3000.0, 2800.0],
        [180.0, 160.0],
    ],
    buy_quantity = [10.0, 10.0, 10.0],       # 单档买入金额（USDT）
    sell_prices = [
        [105000.0, 110000.0],
        [3500.0, 3800.0],
        [220.0, 250.0],
    ],
    sell_percentages = [
        [0.5, 0.5],
        [0.5, 0.5],
        [0.5, 0.5],
    ],
)

# run_multi_orderbook_manual(multi_strategy_table)

# ============================================================================
# 注意事项
# ============================================================================
#
# 1. 资源管理
#    - 每个 OrderBookManager 约占 1-5 MB 内存（取决于 max_depth）
#    - 建议同时运行不超过 10 个
#    - 清理必须逐步 try：cleanup_resources / cleanup_multi_resources 内部
#      已做 best-effort，单步失败不会阻断后续（否则 SBE 连接会泄漏）
#
# 2. 错误处理
#    - OrderBookManager 会自动重连并重新同步
#    - 频繁出错时检查网络与 API 配额
#    - 回调里的 catch 都会透传 InterruptException，Ctrl-C 不会被吞掉
#
# 3. 性能取舍
#    - 只需最优买卖价时用 update_speed="1000ms"
#    - 需要完整深度分析时用 max_depth=5000
#    - depth_levels 超过 max_depth 会被自动 clamp 并告警
#
# 4. 与其他方式共存
#    - create_on_ticker() / create_on_depth() 仍然可用
#    - 可以混合：主策略走 OrderBookManager，辅助监控走 ticker
