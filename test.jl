# ============================================================================
# Binance.jl v0.13.0 综合使用示例
#
# 三种客户端的分工：
#   1. RESTClient             - REST API（批量操作、历史数据、账户管理）
#   2. MarketDataStreamClient - WebSocket 市场数据流（价格、深度、K线、成交）
#   3. SBEStreamClient        - SBE 二进制行情流（低延迟，OrderBookManager 首选）
#   4. WebSocketClient        - WebSocket API（实时下单/查询 + 用户数据流）
#
# 几个容易踩的点：
#   - RESTClient 内置 HTTP.jl 2.x 连接池（复用 TCP/TLS + HTTP/2 会话）。
#     用完调用 close(rest_client) 释放空闲连接；isopen(rest_client) 查询状态
#     （关闭后再发请求会抛 ArgumentError）
#   - 签名请求不参与自动重试：HTTP.jl 把 PUT/DELETE 视作幂等会重发，
#     而重放复用原 timestamp/signature，退避后可能超出 recvWindow → -1021
#   - 未类型化的响应（make_request 直接返回的那些）现在是 JSON.Object。
#     .field / [:field] / haskey / isa AbstractDict 都可用；若旧代码写了
#     `isa JSON3.Object` 得改成 `isa AbstractDict`
#
# 本文件覆盖：
#   1  客户端初始化与 REST 基础验证
#   2  多币种网格策略（ticker 驱动）
#   3  单币种策略（depth 驱动）
#   4  多币种 OrderBookManager 策略（一行调用，推荐）
#   5  其他常用查询
#   6  资源清理
#
# ⚠️  文件里的价位都是占位值，会用真实资金下单。请改成自己的价位后再取消注释。
#
# 前置条件：本文件依赖 `strategy/` 目录，而那个目录在 `.gitignore` 里（个人
# 交易策略，不随包发布）。从仓库新克隆后下面的 `include` 会报
# `SystemError: opening file .../strategy/OrderBook.jl`。本文件归入仓库是为了
# 展示完整的高层入口用法；只需要库本身的示例看 `examples/`。
# ============================================================================

using Binance, Dates

# 本地策略模块。OrderBook.jl 是最上层，它已经 include 了 Common / Monitoring /
# TechnicalAnalysis / Wyckoff / AnalysisWorkflow。
#
# 只 include 一次，子模块全从它下面取。重复 include 会产生两个同名但不同的
# 模块对象，后果有两种：
#   - 两套不同的 TradeStrategy 类型，跨套传参报 MethodError；
#   - 两个模块导出同名函数，Julia 拒绝隐式解析，调用时报
#     `UndefVarError: run_multi_orderbook_strategy not defined in Main`（提示
#     two or more modules export different bindings with this name）。
#     碰到这个就重启 REPL，或改用 `OrderBookStrategy.run_...` 限定调用。
include("./strategy/OrderBook.jl")
using .OrderBookStrategy
using .OrderBookStrategy.StrategyCommon: TradeStrategy, create_strategy,
    print_strategy_levels, account_position, execution_report,
    create_on_ticker, create_on_depth, create_risk_manager

const CONFIG_FILE = "config.toml"

# ---------------------- 1. 初始化客户端 ----------------------
rest_client = RESTClient(CONFIG_FILE)          # 内部持有长生命周期 HTTP.Client 连接池
stream_client = MarketDataStreamClient(CONFIG_FILE)   # JSON 市场数据流
ws_client = WebSocketClient(CONFIG_FILE)       # WebSocket API + 用户数据流

# REST 基础验证（无需 API key）
server_time = get_server_time(rest_client)
exchange_info = get_exchange_info(rest_client; symbol="BTCUSDT")
ticker = get_symbol_ticker(rest_client; symbol="BTCUSDT")

# 账户相关（需要有效 API key）
account_info = get_account_info(rest_client)
get_api_key_permission(rest_client)

# 连接并认证 WebSocket API
connect!(ws_client)
session_logon(ws_client)

# ---------------------- 2. 多币种网格策略（ticker 驱动） ----------------------
#
# 各字段含义：
#   buy_prices        每个币种的买入价位向量
#   buy_quantity      单档买入量（标量，内部 fill 成与 buy_prices 等长）
#   is_quote_qty      true → buy_quantity 是计价资产金额（USDT）
#                     false → 是基础资产数量（BTC）
#   sell_percentages  每档卖出「当前持仓」的比例，1.0 = 全部
#
# 注意：is_quote_qty 是每行一个值，需与 symbol 数量等长。

symbols = ["BTCUSDT", "ETHUSDT", "ZECUSDT", "HYPERUSDT", "SOLUSDT"]
# 配置用 NamedTuple of vectors，不引入 DataFrames（它不是本包的依赖）。
# 多币种入口只需要列访问，传 DataFrame 也同样可以。
strategy_table = (
    symbol = symbols,
    buy_prices = [[95000.0, 90000.0], [2500.0, 1500.0], [150.0, 50.0],
                  [0.1, 0.05], [120.0, 70.0]],
    buy_quantity = fill(5.0, length(symbols)),      # 每档 5 USDT
    is_quote_qty = trues(length(symbols)),
    sell_prices = [[130000.0, 150000.0], [4500.0, 5500.0], [300.0, 500.0],
                   [0.3, 0.6], [200.0, 280.0]],
    sell_percentages = [[0.5, 1.0] for _ in symbols],
)

exchangeinfo = exchangeInfo(ws_client, symbols=symbols)
# 按 symbol 建索引：exchangeInfo 返回顺序不保证与请求顺序一致，
# 按下标取会把 symbol_info 配错到别的币种上（过滤器、精度全错）。
symbol_info_map = Dict(si.symbol => si for si in exchangeinfo.symbols)

# 风险管理器在所有币种间共享：日亏损额度和下单冷却期是账户级约束。
risk_manager = create_risk_manager(
    max_daily_loss_pct = 5.0,
    cooldown_seconds = 60.0,
    min_signal_strength = 0.2,
)

strategies = TradeStrategy[]
for i in eachindex(symbols)
    symbol = strategy_table.symbol[i]
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
        is_quote_qty = strategy_table.is_quote_qty[i],
        symbol_info = symbol_info,     # 必传：没有它 execute_trade 会拒绍下单
    )
    push!(strategies, strategy)
end

# 为所有策略注册共享的用户数据回调（回调内部按 symbol 分发）
on_event(ws_client, "outboundAccountPosition", account_position(strategies))
on_event(ws_client, "executionReport", execution_report(strategies))

userdata_stream_subscribe(ws_client)
session_status(ws_client)

# 启动每个策略的 ticker 流
active_streams = Dict{String,String}()          # symbol => stream_id
for strategy in strategies
    try
        callback = create_on_ticker(rest_client, strategy;
                                    print_interval = 600.0,
                                    risk_manager = risk_manager)
        stream_id = subscribe_ticker(stream_client, strategy.symbol, callback)
        active_streams[strategy.symbol] = stream_id
    catch e
        @error "订阅 $(strategy.symbol) 失败" exception = e
    end
end

println("\n📈 所有策略已启动，活跃流数量: $(length(active_streams))")

# ---------------------- 3. 单币种策略（depth 驱动） ----------------------
BTC_buy_prices = [79000.0, 70000.0]
BTC_buy_quantities = [5.0, 5.0]                 # USDT
BTC_sell_prices = [115000.0, 125000.0]
BTC_sell_percentages = [0.5, 1.0]

btc_info = exchangeInfo(ws_client, symbol="BTCUSDT").symbols[1]
BTC = create_strategy(
    "BTCUSDT", BTC_buy_prices, BTC_buy_quantities, BTC_sell_prices;
    sell_percentages = BTC_sell_percentages,
    is_quote_qty = true,
    symbol_info = btc_info,
)
print_strategy_levels(BTC)

on_event(ws_client, "outboundAccountPosition", account_position(BTC))
on_event(ws_client, "executionReport", execution_report(BTC))
account_status(ws_client)

# create_on_depth 的第一个参数是用于查询余额/下单的客户端（REST 或 WS API 均可）
on_depth_callback = create_on_depth(rest_client, BTC;
                                    print_interval = 600.0,
                                    max_rows = 5,
                                    risk_manager = risk_manager)
BTC_stream = subscribe_depth(stream_client, "BTCUSDT", on_depth_callback;
                             levels = 5, update_speed = "100ms")

# ---------------------- 4. 多币种 OrderBookManager 策略（推荐） ----------------------
#
# 相比 ticker / depth 快照：本地订单簿访问 < 1ms、最多 5000 档、
# WebSocket 订阅不消耗 REST 配额。一行调用即可跑完整流程
# （连接 → 认证 → 建策略 → 订阅用户流 → 启动订单簿 → 周期摘要 → Ctrl-C 清理）。
#
# 这段是阻塞式的，会一直运行到 Ctrl-C，因此默认注释掉。

# ob_config = (
#     symbol = ["BTCUSDT", "ETHUSDT", "SOLUSDT"],
#     buy_prices = [[95000.0, 90000.0], [3000.0, 2800.0], [180.0, 160.0]],
#     buy_quantity = [10.0, 10.0, 10.0],           # 单档 USDT 金额
#     sell_prices = [[105000.0, 110000.0], [3500.0, 3800.0], [220.0, 250.0]],
#     sell_percentages = [[0.5, 0.5], [0.5, 0.5], [0.5, 0.5]],
# )
#
# run_multi_orderbook_strategy(
#     RESTClient(CONFIG_FILE), SBEStreamClient(CONFIG_FILE), WebSocketClient(CONFIG_FILE),
#     ob_config;
#     is_quote_qty = true,
#     max_depth = 1000,              # 多币种用较小深度节省内存（每个 ~1-5 MB）
#     update_speed = "100ms",
#     monitor_interval = 30.0,       # 摘要打印间隔（秒）
#     risk_manager = create_risk_manager(max_daily_loss_pct = 5.0, cooldown_seconds = 60.0),
# )

# ---------------------- 5. 其他常用查询 ----------------------
# WebSocket API 路径（低延迟，走已认证的会话）
orderbook = depth(ws_client, "BTCUSDT"; limit=10)
price = ticker_price(ws_client; symbol="BTCUSDT")
klines_data = klines(ws_client, "BTCUSDT", "1h"; limit=10)
open_orders = orders_all(ws_client, "BTCUSDT")
all_orders(ws_client, "BTCUSDT")
subs_list = session_subscriptions(ws_client)

# 下单示例（注释以避免意外交易）
# order_result = place_order(
#     ws_client, "BTCUSDT", "BUY", "LIMIT";
#     quantity=0.001, price=50000.0, timeInForce="GTC"
# )
# cancel_order(ws_client, "BTCUSDT"; orderId=4495036196)

# REST 路径（适合批量操作与历史数据）
# rolling_24h = get_ticker(rest_client; symbol="BTCUSDT", window_size="1d")
# orderbook_rest = get_orderbook(rest_client, "BTCUSDT"; limit=10)

# 其他行情流示例
# kline_cb(k) = println("K线 $(k[:s]): 开 $(k[:k][:o]) 收 $(k[:k][:c])")
# kline_stream = subscribe_kline(stream_client, "BTCUSDT", "1m", kline_cb)
#
# combined_cb(d) = println("组合流: ", d[:stream], " - ", d[:data][:s])
# combined_stream = subscribe_combined(stream_client,
#     ["btcusdt@ticker", "ethusdt@ticker", "bnbusdt@ticker"], combined_cb)
#
# println("活跃数据流: ", list_active_streams(stream_client))

# ---------------------- 6. 清理和关闭连接 ----------------------
println("\n=== 清理与关闭 ===")

# 每一步都独立 try：任一步抛错也不能中断后面的清理，否则会泄漏连接。
for (symbol, stream_id) in active_streams
    try
        unsubscribe(stream_client, stream_id)
        println("✅ 已取消 $(symbol) 的订阅")
    catch e
        @warn "取消 $(symbol) 订阅失败" exception = e
    end
end

try
    unsubscribe(stream_client, BTC_stream)
    println("✅ 已取消 BTCUSDT 深度订阅")
catch e
    @warn "取消 BTCUSDT 深度订阅失败" exception = e
end

try
    userdata_stream_unsubscribe(ws_client)
    println("✅ 已取消用户数据流订阅")
catch e
    @warn "取消用户数据流订阅失败" exception = e
end

try
    session_logout(ws_client)
    disconnect!(ws_client)
    println("✅ 已登出并断开 WebSocket 连接")
catch e
    @warn "登出或断开连接失败" exception = e
end

try
    close_all_connections(stream_client)
    println("✅ 已关闭所有市场数据流连接")
catch e
    @warn "关闭市场数据流连接失败" exception = e
end

try
    close(rest_client)
    println("✅ 已关闭 REST 连接池，isopen = ", isopen(rest_client))
catch e
    @warn "关闭 REST 连接池失败" exception = e
end

println("\n🏁 示例脚本执行完毕")
