module RateLimiter

    using Dates
    using ..Config

    export BinanceRateLimit, check_and_wait, set_backoff!, update_limits!

    # Store interval as milliseconds for type stability and fast comparison
    # This avoids the abstract Period type which causes type instability
    struct APILimit
        limit_type::String
        interval_ms::Int64  # Interval in milliseconds (concrete type)
        limit::Int
        requests::Vector{DateTime}
        lock::ReentrantLock
    end

    # Convert Period to milliseconds for type-stable storage
    @inline function period_to_ms(p::Period)::Int64
        return p isa Second ? Int64(Dates.value(p)) * 1000 :
               p isa Minute ? Int64(Dates.value(p)) * 60_000 :
               p isa Hour   ? Int64(Dates.value(p)) * 3_600_000 :
                             Int64(Dates.value(p)) * 86_400_000
    end

    APILimit(limit_type::String, interval::Period, limit::Int) =
        APILimit(limit_type, period_to_ms(interval), limit, DateTime[], ReentrantLock())

    # Main struct to hold all rate limit information
    mutable struct BinanceRateLimit
        limits::Vector{APILimit}
        # Timestamp until which all requests should be paused due to a 429/418 response
        # typemin(DateTime) means no backoff active (sentinel to avoid Union{DateTime,Nothing})
        backoff_until::DateTime
        lock::ReentrantLock
    end

    # Sentinel value for "no backoff"
    const NO_BACKOFF = typemin(DateTime)

    function BinanceRateLimit(config::BinanceConfig)
        limits = Vector{APILimit}()
        sizehint!(limits, 5)  # Pre-allocate for typical number of limits

        if config.max_request_weight_per_minute > 0
            push!(limits, APILimit("REQUEST_WEIGHT", Minute(1), config.max_request_weight_per_minute))
        end
        if config.max_orders_per_10s > 0
            push!(limits, APILimit("ORDERS", Second(10), config.max_orders_per_10s))
        end
        if config.max_orders_per_day > 0
            push!(limits, APILimit("ORDERS", Day(1), config.max_orders_per_day))
        end
        if config.max_connections_per_5m > 0
            push!(limits, APILimit("CONNECTIONS", Minute(5), config.max_connections_per_5m))
        end
        if config.max_raw_requests_per_5m > 0
            push!(limits, APILimit("RAW_REQUESTS", Minute(5), config.max_raw_requests_per_5m))
        end
        return BinanceRateLimit(limits, NO_BACKOFF, ReentrantLock())
    end

    """
        set_backoff!(rate_limiter::BinanceRateLimit, retry_after::Int)
    
    Sets a backoff period after receiving a 429 or 418 response.
    
    # Arguments
    - `retry_after`: Either seconds to wait (if < 1000000000) or epoch timestamp in milliseconds
    """
    function set_backoff!(rate_limiter::BinanceRateLimit, retry_after::Int)
        retry_after >= 0 || throw(ArgumentError("retry_after must be non-negative"))

        backoff_until = lock(rate_limiter.lock) do
            # Determine if retry_after is seconds or epoch timestamp
            if retry_after < 1000000000  # Likely seconds
                rate_limiter.backoff_until = now(UTC) + Second(retry_after)
            else  # Likely epoch timestamp in milliseconds
                rate_limiter.backoff_until = unix2datetime(retry_after / 1000)
            end
            return rate_limiter.backoff_until
        end
        @warn "Rate limit exceeded. Backing off until $backoff_until UTC."
        return backoff_until
    end

    function wait_for_backoff(rate_limiter::BinanceRateLimit)
        while true
            sleep_duration = lock(rate_limiter.lock) do
                current_time = now(UTC)
                if rate_limiter.backoff_until == NO_BACKOFF || current_time >= rate_limiter.backoff_until
                    rate_limiter.backoff_until = NO_BACKOFF
                    return 0.0
                end
                return Dates.value(rate_limiter.backoff_until - current_time) / 1000
            end

            sleep_duration <= 0 && return nothing
            @info "Sleeping for $(round(sleep_duration, digits=2)) seconds due to rate limit backoff."
            sleep(sleep_duration)
        end
    end

    function reserve_request!(limit::APILimit)
        while true
            sleep_seconds = lock(limit.lock) do
                current_time = now(UTC)
                window_start = current_time - Millisecond(limit.interval_ms)
                filter!(>(window_start), limit.requests)

                if length(limit.requests) < limit.limit
                    push!(limit.requests, current_time)
                    return 0.0
                end

                oldest_request_time = first(limit.requests)
                wait_period = oldest_request_time + Millisecond(limit.interval_ms) - current_time
                return max(Dates.value(wait_period) / 1000, 0.0)
            end

            sleep_seconds <= 0 && return nothing
            @debug "Approaching $(limit.limit_type) limit. Sleeping for $(round(sleep_seconds, digits=2)) seconds."
            sleep(sleep_seconds)
        end
    end

    """
    Proactively checks if a request would violate a rate limit and waits if necessary.
    Also handles the reactive backoff set by `set_backoff`.
    """
    function check_and_wait(rate_limiter::BinanceRateLimit, request_type::String)
        wait_for_backoff(rate_limiter)

        # Copying at most five small limit objects keeps iteration safe while a
        # server response updates the vector, without holding the global lock
        # during a potentially long wait.
        limits = lock(rate_limiter.lock) do
            copy(rate_limiter.limits)
        end
        for limit in limits
            limit.limit_type == request_type || continue
            reserve_request!(limit)
        end
        return nothing
    end

"""
    interval_to_ms(interval::String, interval_num::Int) -> Int64

Converts the interval string and number from a Binance rate limit update
into milliseconds (type-stable Int64).
"""
function interval_to_ms(interval::String, interval_num::Int)::Int64
    if interval == "SECOND"
        return Int64(interval_num) * 1000
    elseif interval == "MINUTE"
        return Int64(interval_num) * 60_000
    elseif interval == "HOUR"
        return Int64(interval_num) * 3_600_000
    elseif interval == "DAY"
        return Int64(interval_num) * 86_400_000
    else
        # Fallback for unknown intervals, though this shouldn't happen with the current API
        @warn "Unknown rate limit interval received: '$interval'. Cannot update this limit."
        return Int64(0)
    end
end

"""
    update_limits!(rate_limiter::BinanceRateLimit, new_limits)

Updates the rate limiter's state based on the `rateLimits` array
received from a WebSocket or REST API response.

This function updates the current count based on server feedback,
helping to keep the client in sync with server-side rate limit tracking.
"""
function update_limits!(rate_limiter::BinanceRateLimit, new_limits)
    lock(rate_limiter.lock) do
        for new_limit in new_limits
            limit_type = string(new_limit.rateLimitType)

            interval_ms = interval_to_ms(string(new_limit.interval), new_limit.intervalNum)
            if interval_ms == 0
                continue # Skip if the interval was unknown
            end

            # Find the corresponding limit in our rate_limiter
            matching_idx = 0
            for (idx, limit) in enumerate(rate_limiter.limits)
                if limit.limit_type == limit_type && limit.interval_ms == interval_ms
                    matching_idx = idx
                    break
                end
            end

            # If we don't have this limit tracked, create it
            if matching_idx == 0
                new_api_limit = APILimit(limit_type, interval_ms, new_limit.limit, DateTime[], ReentrantLock())
                push!(rate_limiter.limits, new_api_limit)
                matching_idx = length(rate_limiter.limits)
            end

            matching_limit = rate_limiter.limits[matching_idx]

            # Update the limit value if it changed (need to recreate since struct is immutable)
            if matching_limit.limit != new_limit.limit
                @debug "Rate limit for $limit_type/$(interval_ms)ms updated: $(matching_limit.limit) -> $(new_limit.limit)"
                rate_limiter.limits[matching_idx] = APILimit(
                    matching_limit.limit_type,
                    matching_limit.interval_ms,
                    new_limit.limit,
                    matching_limit.requests,
                    matching_limit.lock
                )
                matching_limit = rate_limiter.limits[matching_idx]
            end

            # Sync request count with server's count
            # This helps maintain accuracy even if there's drift
            lock(matching_limit.lock) do
                current_time = now(UTC)
                window_start = current_time - Millisecond(matching_limit.interval_ms)

                # Clear old requests
                filter!(t -> t > window_start, matching_limit.requests)

                # Adjust our count to match server's count
                local_count = length(matching_limit.requests)
                server_count = new_limit.count

                if server_count > local_count
                    # Server has more requests than we tracked - add dummy timestamps
                    for _ in 1:(server_count - local_count)
                        push!(matching_limit.requests, current_time)
                    end
                    @debug "Adjusted $limit_type count up: $local_count -> $server_count"
                elseif server_count < local_count && server_count == 0
                    # Server reset, we should reset too
                    empty!(matching_limit.requests)
                    @debug "Reset $limit_type count to 0"
                end
            end
        end
    end
end

end # module RateLimiter
