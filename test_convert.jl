# ============================================================================
# Convert（闪兑）策略使用示例  —  Binance.jl v0.13.0
#
# Convert API 与普通限价单的区别：
#   - 无最低 5 USDT 名义金额限制（适合小额定投 / 碎股清仓）
#   - 报价—接受两步式（convert_get_quote → convert_accept_quote），有报价有效期
#   - 走 RESTClient，不占用现货撮合的下单频率配额
#
# 本文件覆盖：
#   示例 1  单币种闪兑策略（最少参数）
#   示例 2  单币种 + 技术分析 + 风险管理 + 威科夫支撑阻力注入（推荐）
#   示例 3  多币种闪兑策略
#   示例 4  查询历史闪兑订单
#
# ⚠️  下面的价位都是占位值。直接运行会用真实资金交易，请先改成你自己的价位，
#     并从注释中取消需要的那一段。
#
# 前置条件：本文件依赖 `strategy/` 目录，而那个目录在 `.gitignore` 里（个人
# 交易策略，不随包发布）。从仓库新克隆后下面的 `include` 会报
# `SystemError: opening file ...`。本文件归入仓库是为了展示完整的高层
# 入口用法；只需要库本身的示例看 `examples/`。
# ============================================================================

using Binance, Dates

include("./strategy/Convert.jl")
using .ConvertStrategy
# Convert.jl 已经 include 了下面这些子模块，直接从它里面取即可。#
# 只 include 一次，子模块全从它下面取。重复 include 会产生两个同名但不同的
# 模块对象，后果有两种：
#   - 两套不同的 TradeStrategy 类型，跨套传参报 MethodError；
#   - 两个模块导出同名函数，Julia 拒绝隐式解析，调用时报
#     `UndefVarError: ... not defined in Main`（提示 two or more modules export
#     different bindings with this name）。碰到就重启 REPL，或用模块名限定调用。
using .ConvertStrategy.StrategyCommon: create_risk_manager
using .ConvertStrategy.StrategyAnalysisWorkflow: prepare_strategy_with_analysis,
    print_analysis_summary, daily_support_resistance
using .ConvertStrategy.TechnicalAnalysis: analyze_multiple_timeframes,
    generate_comprehensive_signal, print_comprehensive_signal,
    load_historical_data, IncrementalIndicators, initialize_from_history!

const CONFIG_FILE = "config.toml"

# ============================================================================
# 示例 1: 单币种闪兑策略（最少参数）
# ============================================================================
#
# buy_quantities 的含义由 is_quote_qty 决定：
#   is_quote_qty=true   #（默认）→ 计价资产金额，例如 5.0 表示每档买入 5 USDT
#   is_quote_qty=false        → 基础资产数量，例如 0.001 表示每档买入 0.001 BTC
#
# 卖出侧三种模式互斥，只能选一种：
#   sell_percentages  = [0.5, 1.0]      每档卖出「当前持仓」的 50% / 100%
#   sell_quantities   = [0.001, 0.002]  每档卖出固定数量的基础资产（BTC）
#   sell_quote_amounts= [10.0, 20.0]    每档换出固定金额的计价资产（USDT）—— Convert API 专用

run_convert_strategy(;
    symbol = "BTCUSDT",
    buy_prices = [55000.0, 50000.0, 45000.0],
    buy_quantities = [1.0, 1.0, 1.0],       # USDT 金额（is_quote_qty=true）
    sell_prices = [82000.0, 87000.0, 97000.0],
    sell_quote_amounts= [1.0, 1.0, 1.0],
    config_file = CONFIG_FILE,
)

# ============================================================================
# 示例 2: 单币种 + 技术分析 + 风险管理（推荐）
# ============================================================================
#
# prepare_strategy_with_analysis 会在启动前完成：
#   1. 多时间框架分析（5m / 1h / 4h / 1d）
#   2. 计算 RSI / MACD / 布林带 / EMA-SMA、识别支撑阻力位
#   3. auto_adjust_levels=true 时按支撑阻力自动生成买卖价位
#      （若支撑价 ≥ 市价或阻力价 ≤ 市价，会回退到 ±5% / ±10%，避免挂单即刻成交）
#   4. 构造 IncrementalIndicators 供运行期实时增量更新
#   5. 构造 RiskManager 控制日亏损上限与下单冷却期
#
# 返回的日线支撑阻力位要通过 support_levels / resistance_levels 注入给威科夫分析器，
# 否则 Spring / UTAD 只能拿当前窗口的高低点当代用品（等于「创新低就报 Spring」的循环论证）。

function run_convert_with_analysis(;
    symbol::String = "BTCUSDT",
    buy_quantities::Vector{Float64} = [5.0, 5.0],
    sell_percentages::Vector{Float64} = [0.5, 1.0],
    min_confidence::Float64 = 0.5,
    config_file::String = CONFIG_FILE,
)
    rest_client = RESTClient(config_file)

    try
        analysis = prepare_strategy_with_analysis(
            rest_client = rest_client,
            symbol = symbol,
            buy_quantities = buy_quantities,
            sell_percentages = sell_percentages,
            auto_adjust_levels = true,        # 按支撑阻力自动定价位
            require_signal_confirmation = true,
            # 风险管理
            max_daily_loss_pct = 5.0,
            cooldown_seconds = 60.0,
            min_signal_strength = 0.2,
            max_spread_pct = 0.5,
            # 技术分析函数注入（AnalysisWorkflow 不直接依赖 TechnicalAnalysis）
            analyze_multiple_timeframes_fn = analyze_multiple_timeframes,
            generate_comprehensive_signal_fn = generate_comprehensive_signal,
            load_historical_data_fn = load_historical_data,
            IncrementalIndicators_type = IncrementalIndicators,
            initialize_from_history_fn = initialize_from_history!,
            enable_incremental_indicators = true,
            verbose = true,
        )

        print_analysis_summary(analysis)
        print_comprehensive_signal(analysis.initial_signal)

        if analysis.confidence < min_confidence
            println("\n⚠️  置信度 $(round(analysis.confidence * 100, digits=1))% 低于要求 $(round(min_confidence * 100, digits=1))%，已放弃启动")
            return nothing
        end

        # 日线支撑阻力位 → 威科夫分析器
        supports, resistances = daily_support_resistance(analysis)

        run_convert_strategy(;
            symbol = analysis.symbol,
            buy_prices = analysis.buy_prices,
            buy_quantities = analysis.buy_quantities,
            sell_prices = analysis.sell_prices,
            sell_percentages = analysis.sell_percentages,
            incremental_indicators = analysis.incremental_indicators,
            risk_manager = analysis.risk_manager,
            support_levels = supports,
            resistance_levels = resistances,
            enable_wyckoff = true,
            depth_levels = 20,
            config_file = config_file,
        )
    finally
        # v0.13.0：RESTClient 内置 HTTP.jl 连接池，用完要释放空闲连接
        close(rest_client)
    end
end

# run_convert_with_analysis(symbol = "BTCUSDT")

# ============================================================================
# 示例 3: 多币种闪兑策略
# ============================================================================
#
# strategy_configs 只要求每个元素能取到 symbol / buy_prices / buy_quantity /
# sell_prices / sell_percentages 五个属性，NamedTuple 向量最省事（无需 DataFrames）。
# 注意 buy_quantity 是标量：内部会 fill 成与 buy_prices 等长的向量。
#
# risk_manager 在所有币种之间共享 —— 日亏损额度和下单冷却期是账户级约束，
# 不是币种级约束。

convert_multi_config = [
    (symbol = "BTCUSDT",
     buy_prices = [95000.0, 90000.0],
     buy_quantity = 5.0,                     # 每档 5 USDT
     sell_prices = [115000.0, 125000.0],
     sell_percentages = [0.5, 0.5]),

    (symbol = "ETHUSDT",
     buy_prices = [3000.0, 2800.0],
     buy_quantity = 5.0,
     sell_prices = [3500.0, 3800.0],
     sell_percentages = [0.5, 0.5]),

    (symbol = "SOLUSDT",
     buy_prices = [180.0, 160.0],
     buy_quantity = 5.0,
     sell_prices = [220.0, 250.0],
     sell_percentages = [0.5, 0.5]),
]

# run_multi_convert_strategy(convert_multi_config;
#     is_quote_qty = true,
#     max_depth = 1000,                       # 多币种用较小深度节省内存
#     update_speed = "100ms",
#     monitor_interval = 30.0,                # 摘要打印间隔（秒）
#     risk_manager = create_risk_manager(
#         max_daily_loss_pct = 5.0,
#         cooldown_seconds = 60.0,
#     ),
#     config_file = CONFIG_FILE,
# )

# ============================================================================
# 示例 4: 查询历史闪兑订单
# ============================================================================
#
# convert_trade_flow 的时间区间上限是 30 天，超出会抛 ArgumentError。

function query_convert_history(; days::Int = 30, config_file::String = CONFIG_FILE)
    days in 1:30 || throw(ArgumentError("days must be within 1:30 (API limit)"))

    rest_client = RESTClient(config_file)
    try
        end_time = round(Int, datetime2unix(now(UTC)) * 1000)
        start_time = round(Int, datetime2unix(now(UTC) - Day(days)) * 1000)
        history = convert_trade_flow(rest_client, start_time, end_time)
        println("近 $days 天闪兑记录: ", length(history.list), " 条")
        return history
    finally
        close(rest_client)
    end
end

# history = query_convert_history(days = 30)
