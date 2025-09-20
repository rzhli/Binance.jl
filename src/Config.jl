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
        max_request_weight_per_minute::Int
        max_orders_per_10s::Int
        max_orders_per_day::Int
        max_connections_per_5m::Int
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

            # Extract connection settings first to determine which keys to use
            connection = get(config_data, "connection", Dict())
            testnet = get(connection, "testnet", false)

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
                max_request_weight_per_minute, max_orders_per_10s, max_orders_per_day, max_connections_per_5m, ws_return_rate_limits, debug, log_file
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
