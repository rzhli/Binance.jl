# ============================================================================
# OrderBook 策略使用示例  —  Binance.jl v0.13.0
#
# OrderBookManager 相比 ticker / depth 快照的优势：
#   - 本地订单簿访问 < 1ms（ticker ~10-50ms，depth 快照 ~20-100ms）
#   - 最多 5000 档完整深度，难被表层挂单操纵
#   - WebSocket 订阅不消耗 REST 下单配额
#   - 支持 VWAP、深度不平衡等派生指标
#
# 本文件覆盖：
#   示例 1  单币种快速启动（最少参数）
#   示例 2  单币种完整参数说明
#   示例 3  单币种 + 技术分析 + 风险管理 + 威科夫支撑阻力注入（推荐）
#   示例 4  多币种策略（一行调用）
#   示例 5  多币种 + 技术分析（逐币种分析后统一启动）
#
# ⚠️  价位都是占位值，会用真实资金下单。请改成自己的价位后再取消注释。
#
# 前置条件：本文件依赖 `strategy/` 目录，而那个目录在 `.gitignore` 里（个人
# 交易策略，不随包发布）。从仓库新克隆后下面的 `include` 会报
# `SystemError: opening file ...`。本文件归入仓库是为了展示完整的高层
# 入口用法；只需要库本身的示例看 `examples/`。
# ============================================================================

using Binance, Dates

# OrderBook.jl 是最上层，已 include 了 Common / Monitoring / TechnicalAnalysis /
# Wyckoff / AnalysisWorkflow。#
# 只 include 一次，子模块全从它下面取。重复 include 会产生两个同名但不同的
# 模块对象，后果有两种：
#   - 两套不同的 TradeStrategy 类型，跨套传参报 MethodError；
#   - 两个模块导出同名函数，Julia 拒绝隐式解析，调用时报
#     `UndefVarError: ... not defined in Main`（提示 two or more modules export
#     different bindings with this name）。碰到就重启 REPL，或用模块名限定调用。
include("./strategy/OrderBook.jl")
using .OrderBookStrategy
using .OrderBookStrategy.TechnicalAnalysis: analyze_multiple_timeframes,
    generate_comprehensive_signal, print_comprehensive_signal,
    load_historical_data, IncrementalIndicators, initialize_from_history!
using .OrderBookStrategy.StrategyCommon: RiskManager, create_risk_manager
using .OrderBookStrategy.StrategyAnalysisWorkflow: StrategyAnalysisResult,
    prepare_strategy_with_analysis, print_analysis_summary, daily_support_resistance

const CONFIG_FILE = "config.toml"

rest_client = RESTClient(CONFIG_FILE)
stream_client = SBEStreamClient(CONFIG_FILE)
ws_client = WebSocketClient(CONFIG_FILE)

# ============================================================================
# 示例 1: 单币种快速启动
# ============================================================================
#
# buy_quantities 的含义由 is_quote_qty 决定（默认 true = 计价资产金额）。
# sell_percentages 是「当前持仓」的比例，1.0 = 全部卖出。
# 其余参数默认值：depth_levels=1000、max_depth=5000、update_speed="100ms"、
# verbose_diagnostic=false、enable_wyckoff=true。

# run_single_orderbook_strategy(
#     rest_client, stream_client, ws_client;
#     symbol = "BTCUSDT",
#     buy_prices = [70000.0, 50000.0],
#     buy_quantities = [5.0, 5.0],        # 每档 5 USDT
#     sell_prices = [115000.0, 125000.0],
#     sell_percentages = [0.5, 1.0],
# )

# ============================================================================
# 示例 2: 单币种完整参数说明
# ============================================================================

# run_single_orderbook_strategy(
#     rest_client, stream_client, ws_client;
#     symbol = "BTCUSDT",
#     buy_prices = [80000.0, 50000.0],
#     buy_quantities = [5.0, 5.0],
#     is_quote_qty = true,                # true = USDT 金额，false = BTC 数量
#     sell_prices = [115000.0, 125000.0],
#     sell_percentages = [0.5, 1.0],
#
#     # 深度配置
#     depth_levels = 5000,                # 用于计算不平衡/VWAP 的档位数
#                                         # 可选 100 / 500 / 1000 / 5000
#                                         # 超过 max_depth 会被自动 clamp 并告警
#     max_depth = 5000,                   # OrderBookManager 维护的最大深度
#                                         # 每个 manager 约占 1-5 MB
#     update_speed = "100ms",             # "100ms" 或 "1000ms"
#
#     # 异常检测（智能诊断：正常运行不输出，仅异常时打印）
#     verbose_diagnostic = false,
#     freeze_threshold = 5.0,             # 价格与 updateId 静止多久算冻结（秒）
#     low_rate_threshold = 0.5,           # 回调速率下限（次/秒）
#     high_rate_threshold = 50.0,         # 回调速率上限（次/秒）
#
#     enable_wyckoff = true,              # 订阅 SBE 成交流做量价（威科夫）分析
#
#     # 可选：技术分析与风险管理（见示例 3 的自动装配方式）
#     # incremental_indicators = ...,
#     # risk_manager = create_risk_manager(max_daily_loss_pct=5.0, cooldown_seconds=60.0),
#     # support_levels = [90000.0, 85000.0],     # 注入给威科夫做 Spring 识别
#     # resistance_levels = [110000.0, 120000.0],# 注入给威科夫做 UTAD 识别
# )

# ============================================================================
# 示例 3: 单币种 + 技术分析 + 风险管理（推荐）
# ============================================================================
#
# prepare_strategy_with_analysis 在启动前完成：
#   1. 多时间框架分析（5m / 1h / 4h / 1d）
#   2. 计算 RSI / MACD / 布林带 / EMA-SMA，识别支撑阻力位
#   3. auto_adjust_levels=true 时按支撑阻力自动定价位
#      （支撑价 ≥ 市价或阻力价 ≤ 市价时回退到 ±5% / ±10%，避免挂单即刻成交）
#   4. 构造 IncrementalIndicators 供运行期零分配增量更新
#   5. 构造 RiskManager 控制日亏损上限与下单冷却期
#
# ⭐ 日线支撑阻力位必须通过 support_levels / resistance_levels 注入，
#    否则威科夫的 Spring / UTAD 只能拿当前窗口高低点当代用品 ——
#    那等于「创新低就报 Spring」的循环论证，敏感度和准确度都差很多。

"""
在 OrderBook 策略中集成综合技术分析的包装函数。

先跑 `prepare_strategy_with_analysis` 做启动前分析，确认置信度后再启动策略。
"""
function run_orderbook_strategy_with_analysis(;
    symbol::String,
    buy_prices::Union{Vector{Float64},Nothing} = nothing,
    buy_quantities::Union{Vector{Float64},Nothing} = nothing,
    sell_prices::Union{Vector{Float64},Nothing} = nothing,
    sell_percentages::Union{Vector{Float64},Nothing} = nothing,
    auto_adjust_levels::Bool = true,            # 是否按技术分析自动定价位
    require_signal_confirmation::Bool = true,   # 是否需要技术分析确认
    min_confidence::Float64 = 0.5,              # 最低置信度
    # 风险管理
    max_daily_loss_pct::Float64 = 5.0,
    cooldown_seconds::Float64 = 60.0,
    min_signal_strength::Float64 = 0.2,
    max_spread_pct::Float64 = 0.5,
    # 运行期参数
    is_quote_qty::Bool = true,
    max_depth::Int = 5000,
    update_speed::String = "100ms",
    verbose_diagnostic::Bool = false,
    freeze_threshold::Float64 = 5.0,
    low_rate_threshold::Float64 = 0.5,
    high_rate_threshold::Float64 = 50.0,
    depth_levels::Int = 1000,
    enable_wyckoff::Bool = true,
    enable_incremental_indicators::Bool = true,
    inject_support_resistance::Bool = true,     # 把日线支撑阻力喂给威科夫
)
    println("="^70)
    println("🚀 启动智能 OrderBook 策略 (集成技术分析): $symbol")
    println("="^70)
    println()

    analysis_result = prepare_strategy_with_analysis(
        rest_client = rest_client,
        symbol = symbol,
        buy_prices = buy_prices,
        buy_quantities = buy_quantities,
        sell_prices = sell_prices,
        sell_percentages = sell_percentages,
        auto_adjust_levels = auto_adjust_levels,
        max_daily_loss_pct = max_daily_loss_pct,
        cooldown_seconds = cooldown_seconds,
        min_signal_strength = min_signal_strength,
        max_spread_pct = max_spread_pct,
        require_signal_confirmation = require_signal_confirmation,
        # 技术分析函数注入（AnalysisWorkflow 不直接依赖 TechnicalAnalysis）
        analyze_multiple_timeframes_fn = analyze_multiple_timeframes,
        generate_comprehensive_signal_fn = generate_comprehensive_signal,
        load_historical_data_fn = load_historical_data,
        IncrementalIndicators_type = IncrementalIndicators,
        initialize_from_history_fn = initialize_from_history!,
        enable_incremental_indicators = enable_incremental_indicators,
        verbose = true,
    )

    println("\n初始技术分析结果:")
    print_comprehensive_signal(analysis_result.initial_signal)

    if require_signal_confirmation
        if analysis_result.confidence < min_confidence
            println("\n⚠️  警告: 技术分析置信度 ($(round(analysis_result.confidence * 100, digits=1))%) 低于要求 ($(round(min_confidence * 100, digits=1))%)")
            println("    建议等待更好的入场时机")
            print("\n是否仍要启动策略? (y/n): ")
            if lowercase(strip(readline())) != "y"
                println("\n❌ 策略启动已取消")
                return nothing
            end
        end

        if analysis_result.initial_signal.action == :sell
            println("\n⚠️  警告: 技术分析建议卖出，当前可能不是买入的好时机")
            print("\n是否仍要启动买入策略? (y/n): ")
            if lowercase(strip(readline())) != "y"
                println("\n❌ 策略启动已取消")
                return nothing
            end
        end
    end

    # 日线支撑阻力位 → 威科夫分析器
    supports, resistances = inject_support_resistance ?
        daily_support_resistance(analysis_result) : (Float64[], Float64[])

    println("\n✅ 启动 OrderBook 策略...")
    println()

    run_single_orderbook_strategy(
        rest_client, stream_client, ws_client;
        symbol = analysis_result.symbol,
        buy_prices = analysis_result.buy_prices,
        buy_quantities = analysis_result.buy_quantities,
        sell_prices = analysis_result.sell_prices,
        sell_percentages = analysis_result.sell_percentages,
        is_quote_qty = is_quote_qty,
        max_depth = max_depth,
        update_speed = update_speed,
        verbose_diagnostic = verbose_diagnostic,
        freeze_threshold = freeze_threshold,
        low_rate_threshold = low_rate_threshold,
        high_rate_threshold = high_rate_threshold,
        depth_levels = depth_levels,
        enable_wyckoff = enable_wyckoff,
        incremental_indicators = analysis_result.incremental_indicators,
        risk_manager = analysis_result.risk_manager,
        support_levels = supports,
        resistance_levels = resistances,
    )
end

# --- 3a: 全自动模式（技术分析决定价位）---
# run_orderbook_strategy_with_analysis(
#     symbol = "BTCUSDT",
#     auto_adjust_levels = true,           # 自动定价位
#     buy_quantities = [10.0, 20.0],       # 买入金额 (USDT)
#     sell_percentages = [0.5, 1.0],
#     require_signal_confirmation = true,
#     min_confidence = 0.5,
#     depth_levels = 5000,
#     enable_wyckoff = true,
#     max_daily_loss_pct = 5.0,
#     cooldown_seconds = 60.0,
#     min_signal_strength = 0.2,
# )

# --- 3b: 半自动模式（手动价位 + 技术分析确认）---
# run_orderbook_strategy_with_analysis(
#     symbol = "BTCUSDT",
#     buy_prices = [80000.0, 75000.0],
#     buy_quantities = [10.0, 20.0],
#     sell_prices = [115000.0, 125000.0],
#     sell_percentages = [0.5, 1.0],
#     auto_adjust_levels = false,          # 用指定价位
#     require_signal_confirmation = true,
#     min_confidence = 0.5,
#     depth_levels = 5000,
# )

# ============================================================================
# 示例 4: 多币种策略（一行调用）
# ============================================================================
#
# run_multi_orderbook_strategy 内部完成：连接认证 → 批量拉 exchangeInfo →
# 建策略与订单簿 → 注册共享用户数据回调 → 启动全部订单簿 → 周期摘要 →
# Ctrl-C 后清理资源。
#
# risk_manager 在所有币种间共享：日亏损额度与下单冷却期是账户级约束。
# 这段是阻塞式的，会运行到 Ctrl-C。

# run_multi_orderbook_strategy 只需要列访问，传 DataFrame 也同样可以。
# 多币种配置用 NamedTuple of vectors，不引入 DataFrames（它不是本包依赖）。
multi_config = (
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

# run_multi_orderbook_strategy(
#     rest_client, stream_client, ws_client, multi_config;
#     is_quote_qty = true,
#     max_depth = 1000,            # 多币种用较小深度节省内存
#     update_speed = "100ms",
#     monitor_interval = 30.0,     # 摘要打印间隔（秒）
#     risk_manager = create_risk_manager(
#         max_daily_loss_pct = 5.0,
#         cooldown_seconds = 60.0,
#     ),
# )

# ============================================================================
# 示例 5: 多币种 + 技术分析
# ============================================================================
#
# run_multi_orderbook_strategy 目前不接受 per-symbol 的技术分析结果，
# 所以这里的做法是：先逐币种跑分析、按置信度筛掉不合格的，
# 再把通过筛选的价位组装成列表格配置交给多币种入口。
#
# 注意：这条路径下 incremental_indicators 与威科夫支撑阻力位不会被注入
# （多币种入口没有这两个 per-symbol 参数）。若需要完整功能，请为每个币种
# 单独跑示例 3 的单币种流程（各自独立 task）。

"""
批量筛选：对每个币种跑技术分析，返回置信度达标的策略配置（NamedTuple of vectors）。
"""
function screen_symbols_with_analysis(symbols::Vector{String};
    buy_quantity::Float64 = 10.0,
    sell_percentages::Vector{Float64} = [0.5, 0.5],
    min_confidence::Float64 = 0.5,
    skip_sell_signals::Bool = true,
)
    out_symbols = String[]
    out_buy_prices = Vector{Float64}[]
    out_buy_quantity = Float64[]
    out_sell_prices = Vector{Float64}[]
    out_sell_percentages = Vector{Float64}[]

    for symbol in symbols
        println("\n" * "-"^70)
        println("分析 $symbol ...")
        println("-"^70)

        analysis = try
            prepare_strategy_with_analysis(
                rest_client = rest_client,
                symbol = symbol,
                buy_quantities = fill(buy_quantity, 2),
                sell_percentages = sell_percentages,
                auto_adjust_levels = true,
                require_signal_confirmation = false,   # 批量模式不做交互式询问
                analyze_multiple_timeframes_fn = analyze_multiple_timeframes,
                generate_comprehensive_signal_fn = generate_comprehensive_signal,
                load_historical_data_fn = load_historical_data,
                IncrementalIndicators_type = IncrementalIndicators,
                initialize_from_history_fn = initialize_from_history!,
                enable_incremental_indicators = false, # 多币种入口用不到
                verbose = false,
            )
        catch e
            e isa InterruptException && rethrow()
            @warn "分析 $symbol 失败，跳过" exception = e
            continue
        end

        conf_pct = round(analysis.confidence * 100, digits = 1)

        if analysis.confidence < min_confidence
            println("⏭️  $symbol 置信度 $conf_pct% < $(round(min_confidence*100, digits=1))%，跳过")
            continue
        end

        if skip_sell_signals && analysis.initial_signal.action == :sell
            println("⏭️  $symbol 技术分析建议卖出，跳过")
            continue
        end

        println("✅ $symbol 通过筛选（置信度 $conf_pct%）")
        println("   买入价位: ", analysis.buy_prices)
        println("   卖出价位: ", analysis.sell_prices)

        push!(out_symbols, symbol)
        push!(out_buy_prices, analysis.buy_prices)
        push!(out_buy_quantity, buy_quantity)
        push!(out_sell_prices, analysis.sell_prices)
        push!(out_sell_percentages, analysis.sell_percentages)
    end

    isempty(out_symbols) && return nothing
    return (symbol = out_symbols,
            buy_prices = out_buy_prices,
            buy_quantity = out_buy_quantity,
            sell_prices = out_sell_prices,
            sell_percentages = out_sell_percentages)
end

# candidates = ["BTCUSDT", "ETHUSDT", "SOLUSDT", "BNBUSDT", "XRPUSDT"]
# screened = screen_symbols_with_analysis(candidates;
#     buy_quantity = 10.0,
#     min_confidence = 0.5,
# )
#
# if isnothing(screened)
#     println("\n没有币种通过筛选，本轮不启动策略")
# else
#     println("\n$(length(screened.symbol)) 个币种通过筛选，启动多币种策略")
#     run_multi_orderbook_strategy(
#         rest_client, stream_client, ws_client, screened;
#         is_quote_qty = true,
#         max_depth = 1000,
#         update_speed = "100ms",
#         monitor_interval = 30.0,
#         risk_manager = create_risk_manager(
#             max_daily_loss_pct = 5.0,
#             cooldown_seconds = 60.0,
#         ),
#     )
# end

# ============================================================================
# 输出示例预览
# ============================================================================
#
# ======================================================================
# [14:35:20] 价格: 95535.55
# ======================================================================
# 📊 瞬时指标 (5000档深度):
#   买价: 95535.54 | 卖价: 95535.56 | 价差: 0.02
#   不平衡: -0.125 | 卖压 🟥
#
# 📈 趋势指标:
#   5分钟:  平均不平衡 -0.098   | 价格变化 -0.15% 🟥
#   30分钟: 平均不平衡 -0.234   | 价格变化 -0.42% 🔴 | 趋势: 持续卖压 ⬇️
#   1小时:  平均不平衡 -0.312   | 价格变化 -0.58% 🔴
#   24小时: 平均不平衡 +0.042   | 价格变化 +2.15% 🟢
#
# ⏱️  运行时长: 2小时15分钟 | 总变化: -0.65% 🔴
#
# 💡 综合判断:
#   总体趋势: 看跌 📉🟥 (综合评分: -0.215)
#   价格下跌趋势 ⬇️
#   💡 建议: 卖出信号较强，订单簿和价格均显示卖压
# ======================================================================
#
# 特性说明：
#
# 1. 📊 深度 levels 可配置
#    depth_levels=1000 适合普通交易；5000 是最大深度，适合低频大单。
#    档位越深越难被表层挂单操纵。
#
# 2. 📈 多窗口趋势指标
#    5 分钟 / 30 分钟 / 1 小时 / 24 小时滑动窗口，过滤短期噪音。
#
# 3. 💡 综合信号
#    深度不平衡 30% + VWAP 偏离 20% + 动量 15% + 威科夫 30%，
#    成交量比作为 ±5% 的乘性修正（在所有加项之后应用，
#    因此对权重最大的威科夫项也生效）。
#
# 4. ⚠️ 智能诊断
#    正常运行时不输出诊断；仅在冻结、回调速率异常、更新延迟时打印。
#
# 5. 🛡️ 风险管理
#    risk_manager 在下单前检查冷却期与日亏损上限，成交后记录。
#    未传入时不施加任何约束（启动横幅会如实显示）。
