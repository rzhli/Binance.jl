module Notifier

# ntfy 推送：把触发信号 / 下单成交等关键日志转发到 ntfy 的某个主题。
# 参照姊妹项目 Monitor 的 src/services/Push.jl：HTTP.post 一段 JSON body 到 ntfy
# 服务，body 里带 :topic。这里额外提供一个 NtfyLogger（AbstractLogger），
# 透传到原 logger 的同时，把满足条件的记录转发到 ntfy。

using HTTP, JSON, TOML, Logging, Dates

export send_to_ntfy, notify_ntfy, NtfyLogger, install_ntfy_logger!, restore_logger!,
    configure_from_toml!

# ======================= 配置 =======================

mutable struct NtfyConfig
    enabled::Bool
    url::String
    token::String
    topic::String
    min_level::LogLevel
end

# 默认关闭；由 configure_from_toml! 或 configure! 填充。
const CONFIG = Ref(NtfyConfig(false, "http://127.0.0.1:2586", "", "Binance", Logging.Warn))

# HTTP 客户端：连接/超时预算挂在 client 上（参照 Monitor）。本地 ntfy 直连，
# 不设 proxy（localhost 天然绕过代理）。
const NTFY_CLIENT = HTTP.Client(
    connect_timeout = 5,
    request_timeout = 10,
    response_header_timeout = 5,
)

_parse_level(s::AbstractString) = begin
    t = lowercase(strip(s))
    t == "debug" ? Logging.Debug :
    t == "info"  ? Logging.Info  :
    t == "warn"  ? Logging.Warn  :
    t == "error" ? Logging.Error : Logging.Warn
end

"""
    configure!(; enabled, url, token, topic, min_level)

直接设置 ntfy 配置。`min_level` 可传字符串（"Debug"/"Info"/"Warn"/"Error"）或 `LogLevel`。
"""
function configure!(; enabled=CONFIG[].enabled, url=CONFIG[].url, token=CONFIG[].token,
                     topic=CONFIG[].topic, min_level=CONFIG[].min_level)
    lvl = min_level isa LogLevel ? min_level : _parse_level(String(min_level))
    CONFIG[] = NtfyConfig(Bool(enabled), String(url), String(token), String(topic), lvl)
    return CONFIG[]
end

"""
    configure_from_toml!(path="config.toml") -> NtfyConfig

读取 config.toml 的 `[ntfy]` 段填充配置。缺段/缺键时保持默认，enabled 默认 false。
"""
function configure_from_toml!(path::AbstractString="config.toml")
    isfile(path) || return CONFIG[]
    data = try
        TOML.parsefile(path)
    catch
        return CONFIG[]
    end
    sec = get(data, "ntfy", nothing)
    sec isa AbstractDict || return CONFIG[]
    return configure!(
        enabled   = get(sec, "enabled", false),
        url       = get(sec, "url", CONFIG[].url),
        token     = get(sec, "token", CONFIG[].token),
        topic     = get(sec, "topic", CONFIG[].topic),
        min_level = get(sec, "min_level", "Warn"),
    )
end

# ======================= 发送 =======================

# 发送期间用它当当前 logger：HTTP.jl 内部的 @debug/@warn 不会再经过 NtfyLogger
# 被二次转发（避免递归/刷屏），只落到 stderr。
const _SEND_GUARD_LOGGER = ConsoleLogger(stderr, Logging.Warn)

"""
    send_to_ntfy(message; title, tags, priority, topic) -> Bool

同步 POST 一条消息到 ntfy。失败只写 stderr 并返回 false，绝不抛出——推送永远
不能影响调用方（交易主流程）。`topic` 缺省用配置里的主题。
"""
function send_to_ntfy(message::AbstractString;
                      title::AbstractString="Binance",
                      tags="",
                      priority::Integer=3,
                      topic::AbstractString=CONFIG[].topic)
    cfg = CONFIG[]
    cfg.enabled || return false

    tags_str = tags isa AbstractString ? tags : join(string.(tags), ",")
    body = Dict{String,Any}(
        "topic"    => topic,
        "title"    => title,
        "message"  => message,
        "priority" => Int(priority),
    )
    isempty(tags_str) || (body["tags"] = split(tags_str, ","))

    headers = ["Content-Type" => "application/json", "Markdown" => "yes"]
    isempty(cfg.token) || push!(headers, "Authorization" => string("Bearer ", cfg.token))

    return Logging.with_logger(_SEND_GUARD_LOGGER) do
        try
            res = HTTP.post(cfg.url, headers; body = JSON.json(body),
                            client = NTFY_CLIENT, status_exception = false)
            res.status == 200 && return true
            println(stderr, "❌ ntfy 推送失败: HTTP ", res.status)
            return false
        catch e
            println(stderr, "🚨 ntfy 推送异常: ", sprint(showerror, e))
            return false
        end
    end
end

"""
    notify_ntfy(message; kwargs...)

`send_to_ntfy` 的异步版本：派发到独立任务，不阻塞调用方。返回该 `Task`。
"""
function notify_ntfy(message::AbstractString; kwargs...)
    return @async try
        send_to_ntfy(message; kwargs...)
    catch e
        println(stderr, "🚨 ntfy 异步推送异常: ", sprint(showerror, e))
    end
end

# ======================= NtfyLogger =======================

# level → (priority, tags)
function _level_style(level::LogLevel)
    level >= Logging.Error && return (5, "rotating_light")
    level >= Logging.Warn  && return (4, "warning")
    level >= Logging.Info  && return (3, "bell")
    return (2, "information_source")
end

function _format_body(message, kwargs)
    parts = String[]
    for (k, v) in kwargs
        (k === :ntfy || k === :maxlog || k === :_group) && continue
        if k === :exception
            err = v isa Tuple ? first(v) : v
            push!(parts, string("**exception**: ", sprint(showerror, err)))
        else
            push!(parts, string("**", k, "**: ", v))
        end
    end
    isempty(parts) && return string(message)
    return string(message, "\n", join(parts, "\n"))
end

"""
    NtfyLogger(base; ntfy_min_level=CONFIG[].min_level)

包裹 `base` logger：所有记录照常交给 `base`（终端/文件行为不变），并把满足
`level >= ntfy_min_level` 或带 `ntfy=true` 标记的记录额外转发到 ntfy。
"""
struct NtfyLogger <: AbstractLogger
    base::AbstractLogger
    ntfy_min_level::LogLevel
end
NtfyLogger(base::AbstractLogger) = NtfyLogger(base, CONFIG[].min_level)

Logging.shouldlog(l::NtfyLogger, level, _module, group, id) =
    Logging.shouldlog(l.base, level, _module, group, id)
Logging.min_enabled_level(l::NtfyLogger) =
    min(Logging.min_enabled_level(l.base), l.ntfy_min_level)
Logging.catch_exceptions(l::NtfyLogger) = Logging.catch_exceptions(l.base)

function Logging.handle_message(l::NtfyLogger, level, message, _module, group, id,
                                file, line; kwargs...)
    # 先照常交给底层 logger（保持终端/文件输出）。底层可能因自身 min level 丢弃，
    # 这里按其 min level 判断，避免把它本不该显示的记录硬塞进去。
    if level >= Logging.min_enabled_level(l.base) &&
       Logging.shouldlog(l.base, level, _module, group, id)
        Logging.handle_message(l.base, level, message, _module, group, id, file, line; kwargs...)
    end

    # 转发判定：达到阈值，或显式 ntfy=true。
    tagged = get(kwargs, :ntfy, false) == true
    (tagged || level >= l.ntfy_min_level) || return nothing
    CONFIG[].enabled || return nothing

    prio, tags = _level_style(level)
    title = String(first(split(string(message), '\n')))
    notify_ntfy(_format_body(message, kwargs); title = title, tags = tags, priority = prio)
    return nothing
end

# ======================= 安装 / 还原 =======================

"""
    install_ntfy_logger!(; base=Logging.global_logger()) -> 旧 global logger（或 nothing）

用 `NtfyLogger` 包裹当前 global logger 并安装。ntfy 未启用时不安装、返回 `nothing`。
返回值传给 `restore_logger!` 可还原。
"""
function install_ntfy_logger!(; base::AbstractLogger=Logging.global_logger())
    CONFIG[].enabled || return nothing
    base isa NtfyLogger && return nothing   # 已安装，避免重复包裹
    old = Logging.global_logger(NtfyLogger(base, CONFIG[].min_level))
    return old
end

"""还原 `install_ntfy_logger!` 之前的 global logger。传 `nothing` 时无操作。"""
restore_logger!(::Nothing) = nothing
restore_logger!(old::AbstractLogger) = (Logging.global_logger(old); nothing)

end # module Notifier
