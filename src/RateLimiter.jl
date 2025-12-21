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
    @inline period_to_ms(p::Second) = Int64(Dates.value(p)) * 1000
    @inline period_to_ms(p::Minute) = Int64(Dates.value(p)) * 60_000
    @inline period_to_ms(p::Hour) = Int64(Dates.value(p)) * 3_600_000
    @inline period_to_ms(p::Day) = Int64(Dates.value(p)) * 86_400_000

    APILimit(limit_type::String, interval::Period, limit::Int) =
        APILimit(limit_type, period_to_ms(interval), limit, DateTime[], ReentrantLock())

    # Main struct to hold all rate limit information
    mutable struct BinanceRateLimit
        limits::Vector{APILimit}
        # Timestamp until which all requests should be paused due to a 429/418 response
        backoff_until::Union{DateTime, Nothing}
        lock::ReentrantLock
    end

    function BinanceRateLimit(config::BinanceConfig)
        limits = Vector{APILimit}()
        sizehint!(limits, 4)  # Pre-allocate for typical number of limits

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
        return BinanceRateLimit(limits, nothing, ReentrantLock())
    end

    """
        set_backoff!(rate_limiter::BinanceRateLimit, retry_after::Int)
    
    Sets a backoff period after receiving a 429 or 418 response.
    
    # Arguments
    - `retry_after`: Either seconds to wait (if < 1000000000) or epoch timestamp in milliseconds
    """
    function set_backoff!(rate_limiter::BinanceRateLimit, retry_after::Int)
        lock(rate_limiter.lock) do
            # Determine if retry_after is seconds or epoch timestamp
            if retry_after < 1000000000  # Likely seconds
                rate_limiter.backoff_until = now(UTC) + Second(retry_after)
            else  # Likely epoch timestamp in milliseconds
                rate_limiter.backoff_until = unix2datetime(retry_after / 1000)
            end
            @warn "Rate limit exceeded. Backing off until $(rate_limiter.backoff_until) UTC."
        end
    end

    """
    Proactively checks if a request would violate a rate limit and waits if necessary.
    Also handles the reactive backoff set by `set_backoff`.
    """
    function check_and_wait(rate_limiter::BinanceRateLimit, request_type::String)
        # 1. Handle reactive backoff from 429/418 errors
        lock(rate_limiter.lock) do
            if !isnothing(rate_limiter.backoff_until) && now(UTC) < rate_limiter.backoff_until
                sleep_duration = (rate_limiter.backoff_until - now(UTC)).value / 1000.0
                if sleep_duration > 0
                    @info "Sleeping for $(round(sleep_duration, digits=2)) seconds due to rate limit backoff."
                    sleep(sleep_duration)
                end
                rate_limiter.backoff_until = nothing # Reset after waiting
            end
        end

        # 2. Handle proactive rate limiting
        for limit in rate_limiter.limits
            if limit.limit_type != request_type
                continue
            end

            lock(limit.lock) do
                current_time = now(UTC)
                # Convert interval_ms to Millisecond for DateTime arithmetic
                window_start = current_time - Millisecond(limit.interval_ms)

                # Remove requests that are outside the current time window
                filter!(t -> t > window_start, limit.requests)

                # If the limit is reached, wait until the oldest request expires
                if length(limit.requests) >= limit.limit
                    oldest_request_time = first(limit.requests)
                    time_to_wait_ms = (oldest_request_time + Millisecond(limit.interval_ms)) - current_time
                    sleep_seconds = time_to_wait_ms.value / 1000.0

                    if sleep_seconds > 0
                        @debug "Approaching $(limit.limit_type) limit. Sleeping for $(round(sleep_seconds, digits=2)) seconds."
                        sleep(sleep_seconds)
                    end
                    # After sleeping, re-filter the requests
                    filter!(t -> t > (now(UTC) - Millisecond(limit.interval_ms)), limit.requests)
                end

                # Add the new request's timestamp
                push!(limit.requests, now(UTC))
            end
        end
    end

"""
    interval_to_ms(interval::String, interval_num::Int) -> Int64

Converts the interval string and number from a Binance rate limit update
into milliseconds (type-stable Int64).
"""
function interval_to_ms(interval::String, interval_num::Int)::Union{Int64, Nothing}
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
        return nothing
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
            # Map WebSocket API names to internal names
            limit_type = new_limit.rateLimitType
            if limit_type == "REQUEST_WEIGHT"
                limit_type = "REQUESTS"
            end

            interval_ms = interval_to_ms(new_limit.interval, new_limit.intervalNum)
            if isnothing(interval_ms)
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
