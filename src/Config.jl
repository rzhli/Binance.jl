module Config

    using TOML

    export BinanceConfig, from_toml

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
        max_requests_per_minute::Int
        max_orders_per_second::Int
        ws_return_rate_limits::Bool

        # Logging
        debug::Bool
        log_file::String
    end

    function from_toml(config_path::String="config.toml")
        if !isfile(config_path)
            error("Configuration file not found: $config_path")
        end

        try
            config_data = TOML.parsefile(config_path)

            # Extract API settings
            api = get(config_data, "api", Dict())
            api_key = get(api, "api_key", "")
            signature_method = get(api, "signature_method", "HMAC_SHA256")
            api_secret = get(api, "secret_key", "")
            private_key_path = get(api, "private_key_path", "")
            private_key_pass = get(api, "private_key_pass", "")

            # Extract connection settings
            connection = get(config_data, "connection", Dict())
            testnet = get(connection, "testnet", false)
            timeout = get(connection, "timeout", 30)
            recv_window = get(connection, "recv_window", 60000)
            proxy = get(connection, "proxy", "")
            max_reconnect_attempts = get(connection, "max_reconnect_attempts", 5)
            reconnect_delay = get(connection, "reconnect_delay", 5)

            # Extract rate limiting settings
            rate_limiting = get(config_data, "rate_limiting", Dict())
            max_requests_per_minute = get(rate_limiting, "max_requests_per_minute", 1200)
            max_orders_per_second = get(rate_limiting, "max_orders_per_second", 10)
            ws_return_rate_limits = get(rate_limiting, "ws_return_rate_limits", true)

            # Extract logging settings
            logging = get(config_data, "logging", Dict())
            debug = get(logging, "debug", false)
            log_file = get(logging, "log_file", "")

            # Validate configuration
            if isempty(api_key)
                error("API key is required in configuration")
            end

            if signature_method == "HMAC_SHA256" && isempty(api_secret)
                error("API secret is required for HMAC signature")
            elseif signature_method == "ED25519" && isempty(private_key_path)
                error("Private key path is required for ED25519 signature")
            end

            return BinanceConfig(
                api_key, signature_method, api_secret, private_key_path, private_key_pass,
                testnet, timeout, recv_window, proxy, max_reconnect_attempts, reconnect_delay,
                max_requests_per_minute, max_orders_per_second, ws_return_rate_limits, debug, log_file
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
