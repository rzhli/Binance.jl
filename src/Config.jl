module Config

using TOML

export BinanceConfig, FIXConfig, FIXEndpoint, from_toml

# ======================= FIX 配置结构 =======================

"""FIX 端点配置（一个服务的三种编码模式端口）"""
struct FIXEndpoint
    host::String
    standard_port::Int    # 标准 FIX 编码 (远程端口 9000)
    sbe_hybrid_port::Int  # SBE Hybrid: FIX请求 → SBE响应 (远程端口 9001)
    sbe_full_port::Int    # SBE Full: SBE请求 → SBE响应 (远程端口 9002)
end

"""FIX API 完整配置"""
struct FIXConfig
    legacy_host::String   # 兼容旧版的默认 host
    order_entry::FIXEndpoint
    drop_copy::FIXEndpoint
    market_data::FIXEndpoint
end

# ======================= 主配置结构 =======================

struct BinanceConfig
    api_key::String
    signature_method::String
    api_secret::String
    private_key_path::String
    private_key_pass::String

    # Connection settings
    testnet::Bool
    timeout::Int
    recv_window::Int
    proxy::String
    max_reconnect_attempts::Int
    reconnect_delay::Int

    # Rate limiting
    max_request_weight_per_minute::Int
    max_orders_per_10s::Int
    max_orders_per_day::Int
    max_connections_per_5m::Int
    ws_return_rate_limits::Bool

    # FIX API settings (嵌套结构)
    fix::FIXConfig

    # Logging
    debug::Bool
    log_file::String
end

function from_toml(config_path::String="config.toml"; testnet::Bool=false)
    if !isfile(config_path)
        error("Configuration file not found: $config_path")
    end

    try
        config_data = TOML.parsefile(config_path)

        # Extract connection settings
        connection = get(config_data, "connection", Dict())

        # Extract API settings
        api = get(config_data, "api", Dict())
        signature_method = get(api, "signature_method", "HMAC_SHA256")
        private_key_path = get(api, "private_key_path", "")
        private_key_pass = get(api, "private_key_pass", "")

        api_key = ""
        api_secret = ""
        if testnet
            api_key = get(api, "testnet_api_key", "")
            private_key_path = get(api, "testnet_private_key_path", "")
            private_key_pass = get(api, "testnet_private_key_pass", "")
        else
            api_key = get(api, "api_key", "")
            api_secret = get(api, "secret_key", "")
        end

        timeout = get(connection, "timeout", 30)
        recv_window = get(connection, "recv_window", 60000)
        proxy = get(connection, "proxy", "")
        max_reconnect_attempts = get(connection, "max_reconnect_attempts", 5)
        reconnect_delay = get(connection, "reconnect_delay", 5)

        # Extract rate limiting settings
        rate_limiting = get(config_data, "rate_limiting", Dict())
        max_request_weight_per_minute = get(rate_limiting, "max_request_weight_per_minute", 6000)
        max_orders_per_10s = get(rate_limiting, "max_orders_per_10s", 50)
        max_orders_per_day = get(rate_limiting, "max_orders_per_day", 160000)
        max_connections_per_5m = get(rate_limiting, "max_connections_per_5m", 300)
        ws_return_rate_limits = get(rate_limiting, "ws_return_rate_limits", true)

        # Extract FIX API settings - use testnet section if testnet=true
        fix_section = testnet ? "fix_testnet" : "fix"
        fix_data = get(config_data, fix_section, Dict())
        # Fallback to [fix] section if testnet section doesn't exist
        if isempty(fix_data) && testnet
            fix_data = get(config_data, "fix", Dict())
        end
        fix_host = get(fix_data, "host", "127.0.0.1")
        # Allow FIX section to override proxy (for testnet which may not need proxy)
        if haskey(fix_data, "proxy")
            proxy = fix_data["proxy"]
        end

        # 定义默认端口（testnet 使用 19xxx 系列）
        base_oe, base_dc, base_md = testnet ? (19000, 19001, 19002) : (9000, 9001, 9002)
        hybrid_oe, hybrid_dc, hybrid_md = testnet ? (19010, 19011, 19012) : (9010, 9011, 9012)
        full_oe, full_dc, full_md = testnet ? (19020, 19021, 19022) : (9020, 9021, 9022)

        # 构建 FIX 端点配置
        fix_config = FIXConfig(
            fix_host,
            FIXEndpoint(
                get(fix_data, "order_entry_host", fix_host),
                get(fix_data, "order_entry_port", base_oe),
                get(fix_data, "order_entry_sbe_hybrid_port", hybrid_oe),
                get(fix_data, "order_entry_sbe_full_port", full_oe)
            ),
            FIXEndpoint(
                get(fix_data, "drop_copy_host", fix_host),
                get(fix_data, "drop_copy_port", base_dc),
                get(fix_data, "drop_copy_sbe_hybrid_port", hybrid_dc),
                get(fix_data, "drop_copy_sbe_full_port", full_dc)
            ),
            FIXEndpoint(
                get(fix_data, "market_data_host", fix_host),
                get(fix_data, "market_data_port", base_md),
                get(fix_data, "market_data_sbe_hybrid_port", hybrid_md),
                get(fix_data, "market_data_sbe_full_port", full_md)
            )
        )

        # Extract logging settings
        logging = get(config_data, "logging", Dict())
        debug = get(logging, "debug", false)
        log_file = get(logging, "log_file", "")

        # Validate configuration
        if isempty(api_key)
            error("API key is required in configuration")
        end

        if signature_method == "HMAC_SHA256"
            if isempty(api_secret)
                error("API secret is required for HMAC_SHA256 signature")
            end
        elseif signature_method == "ED25519"
            if isempty(private_key_path)
                error("Private key path is required for ED25519 signature")
            end
            if !isempty(private_key_path) && !isfile(private_key_path)
                error("ED25519 private key file not found: $private_key_path")
            end
        elseif signature_method == "RSA"
            if isempty(private_key_path)
                error("Private key path is required for RSA signature")
            end
            if !isempty(private_key_path) && !isfile(private_key_path)
                error("RSA private key file not found: $private_key_path")
            end
        elseif signature_method != "NONE"
            error("Unsupported signature method: $signature_method. Supported methods: HMAC_SHA256, ED25519, RSA")
        end

        return BinanceConfig(
            api_key, signature_method, api_secret, private_key_path, private_key_pass,
            testnet, timeout, recv_window, proxy, max_reconnect_attempts, reconnect_delay,
            max_request_weight_per_minute, max_orders_per_10s, max_orders_per_day, max_connections_per_5m, ws_return_rate_limits,
            fix_config,
            debug, log_file
        )

    catch e
        if e isa SystemError
            error("Failed to read configuration file: $config_path - $(e.msg)")
        else
            error("Failed to parse configuration file: $e")
        end
    end
end

end # end of module
