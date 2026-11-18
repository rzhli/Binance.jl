# ============================================================================
# FIX 策略使用示例  —  BinanceFIX.jl v0.7.0
#
# 与 test_convert.jl 的区别：
#   - test_convert.jl 走 REST（Convert 闪兑）+ WebSocket/SBE 行情，不使用 FIX。
#   - 本文件全程只用 FIX：行情来自 FIX Market Data 会话，下单走 FIX Order Entry
#     会话的现货限价 IOC 单。SDK 直连 fix-*.binance.com（TLS 由 SDK 完成）。
#   - FIX 不支持 Convert 闪兑。现货下单受最小名义金额限制（BTCUSDT 为 5 USDT），
#     所以 test_convert.jl 里每档 1 USDT 的小额在这里会被拒单。
#
# 本文件覆盖：
#   示例 1  run_fix_strategy：监控价格、到价自动下单（最少参数）
#   示例 2  dry run：只看会触发什么单，不发送
#   示例 3  直接用会话辅助函数：with_fix_session / pump_messages
#   示例 4  FIX SBE（二进制编码）会话：with_sbe_session / pump_sbe_messages
#
# 运行（在仓库根目录）：
#   julia --project=BinanceFIX test_fix.jl
#
# ⚠️  本文件连接真实账户：示例 1 到价会用真实资金下单。下面的价位都是占位值，
#     运行前请先改成你自己的价位。（环境由 config.toml 的 [connection] testnet
#     决定，未设置即生产网。）示例 2、3、4 不下单。
#
# 前置条件：API key 为 Ed25519 且开启 FIX_API 权限。本文件依赖 `strategy/FIX.jl`，
# `strategy/` 目录在 `.gitignore` 里（个人交易策略，不随包发布）。
# ============================================================================

# 只 `import Binance`（不 `using`）：Binance 和 BinanceFIX 导出了同名函数（如
# subscribe_book_ticker），同时 `using` 会让这些名字产生歧义而无法调用。
import Binance
using BinanceFIX, Dates
include("./strategy/FIX.jl")
using .FIXStrategy

# 以脚本方式运行时，让 Ctrl-C 抛出 InterruptException，策略才能先登出再退出。
Base.exit_on_sigint(false)

const CONFIG_FILE = joinpath(@__DIR__, "config.toml")

# ============================================================================
# 示例 1: 阶梯买卖策略（最少参数）
# ============================================================================
#
# 买入档：卖一价 <= 该档价格时，以该档价格发 LIMIT IOC 买单
# 卖出档：买一价 >= 该档价格时，以该档价格发 LIMIT IOC 卖单
# IOC 单不会挂在盘口上：能成交多少成交多少，剩余立即过期。
#
# buy_quantities 的含义由 is_quote_qty 决定：
#   is_quote_qty=true （默认）→ 计价资产金额，例如 10.0 表示每档买入 10 USDT
#   is_quote_qty=false        → 基础资产数量，例如 0.001 表示每档买入 0.001 BTC
# sell_quantities 始终是基础资产数量（BTC）。
#
# 每档只成交一次；被交易所拒单（余额不足、低于最小名义金额等）的档位会停用并
# 打印原因。返回值里有成交列表和各档最终状态。

result = run_fix_strategy(;
    symbol = "BTCUSDT",
    buy_prices = [60000.0, 50000.0, 40000.0],
    buy_quantities = [10.0, 10.0, 10.0],        # 每档 10 USDT
    sell_prices = [88000.0, 99000.0, 110000.0],
    sell_quantities = [0.0001, 0.0001, 0.0001], # 每档卖 0.0001 BTC
    config_file = CONFIG_FILE,
    status_interval = 10.0,
    on_fill = fill -> println("  >> on_fill: ", fill),
)
println("示例 1 结束：成交 $(length(result.fills)) 笔，最后买一 $(result.last_bid) / 卖一 $(result.last_ask)")

# ============================================================================
# 示例 2: dry run —— 先看会下什么单
# ============================================================================
#
# dry_run=true 时到价只打印将要发送的订单，不发送。这里把买入档设在当前卖一价
# 之上，所以会立刻"触发"，可以看到按数量步长取整后的实际下单量。

run_fix_strategy(;
    symbol = "BTCUSDT",
    buy_prices = [round(result.last_ask * 1.001; digits=2)],
    buy_quantities = [10.0],
    config_file = CONFIG_FILE,
    dry_run = true,
    duration = 10,
)

# ============================================================================
# 示例 3: 直接使用会话辅助函数
# ============================================================================
#
# BinanceFIX 提供三个通用辅助函数（run_fix_strategy 内部用的也是它们）：
#   new_sender_comp_id()                随机 8 位 SenderCompID
#   with_fix_session(f, config, type)   连接 + 登录 → f(session) → 登出 + 断开
#   pump_messages(handle, session, 秒)  收消息并回调 handle(type, data)，同时维持心跳
# 需要自己写监控或下单逻辑时用它们即可。

config = Binance.from_toml(CONFIG_FILE)

# 3a. 行情会话：订阅成交流，统计 5 秒内的成交
with_fix_session(config, MarketData) do session
    subscribe_trade_stream(session, ["BTCUSDT"])
    trades = 0
    last_price = nothing
    pump_messages(session, 5) do type, data
        type == :market_data_incremental || return
        for entry in data.entries
            entry.entry_type == MD_ENTRY_TRADE || continue
            trades += 1
            last_price = entry.price
        end
    end
    println("\n[示例 3a] BTCUSDT 5 秒内成交 $trades 笔，最新成交价 $last_price")
end

# 3b. 下单会话：查询限额（只读）
with_fix_session(config, OrderEntry) do session
    limit_query(session)
    pump_messages(session, 2) do type, data
        type == :limit_response || return
        println("[示例 3b] 限额：")
        for l in data.limits
            kind = l.limit_type == "1" ? "订单数" : "消息数"
            println("  $kind $(l.limit_count)/$(l.limit_max)，窗口 $(l.limit_reset_interval)$(l.limit_reset_interval_resolution)")
        end
    end
end

# ============================================================================
# 示例 4: FIX SBE 会话（二进制编码，端口 9002）
# ============================================================================
#
# 用法与文本 FIX 对应：with_sbe_session / pump_sbe_messages。解码后的枚举字段是
# ASCII 字符的 UInt8，例如 entry_type == SBE_MD_ENTRY_BID、side == UInt8('1')。

with_sbe_session(config, SBEMarketData) do session
    market_data_request_sbe(session, ["BTCUSDT"]; market_depth=1,
        entry_types=[UInt8('0'), UInt8('1')])
    bid = ask = nothing
    updates = 0
    pump_sbe_messages(session, 3) do type, message
        type in (:market_data_snapshot, :market_data_incremental_book_ticker) || return
        updates += 1
        for entry in message.entries
            entry.entry_type == SBE_MD_ENTRY_BID && (bid = entry.price)
            entry.entry_type == SBE_MD_ENTRY_OFFER && (ask = entry.price)
        end
    end
    println("\n[示例 4] FIX SBE：3 秒内 $updates 条行情，买一 $bid / 卖一 $ask（schema 1:$(Int(session.schema_version))）")
end
