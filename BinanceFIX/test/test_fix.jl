using Binance
using BinanceFIX

# Load config
config = Binance.from_toml("config.toml")
sender_comp_id = "liruzhen"

# Create Order Entry session via stunnel
session = FIXSession(config, sender_comp_id; session_type=OrderEntry)

try
    # Connect through stunnel -> Binance
    connect_fix(session)
    println("Connected to FIX server via stunnel")

    # Logon
    logon(session)
    println("Logged in successfully")

    # Start heartbeat monitor
    start_monitor(session)

    # Query limits to verify connection
    limit_query(session)

    # Wait for response
    for _ in 1:50
        msg = receive_message(session)
        if !isnothing(msg)
            result = process_message(session, msg)
            if result[1] == :limit_response
                println("Limits received:")
                for limit in result[2].limits
                    type_name = limit.limit_type == "1" ? "ORDER" : "MESSAGE"
                    println("  $type_name: $(limit.limit_count)/$(limit.limit_max)")
                end
                break
            end
        end
        sleep(0.1)
    end

finally
    stop_monitor(session)
    logout(session)
    disconnect(session)
    println("Disconnected")
end
