module RateLimiter

    using Dates
    using ..Config

    export BinanceRateLimit, check_and_wait, set_backoff, update_limits!

    # Struct to hold the state of a single rate limit
    mutable struct APILimit
        # e.g., "REQUESTS", "ORDERS"
        limit_type::String
        # The time window for the limit
        interval::Period
        # The maximum number of requests in the interval
        limit::Int
        # A thread-safe vector to store timestamps of recent requests
        requests::Vector{DateTime}
        lock::ReentrantLock
    end

    APILimit(limit_type, interval, limit) = APILimit(limit_type, interval, limit, DateTime[], ReentrantLock())

    # Main struct to hold all rate limit information
    mutable struct BinanceRateLimit
        limits::Vector{APILimit}
        # Timestamp until which all requests should be paused due to a 429/418 response
        backoff_until::Union{DateTime, Nothing}
        lock::ReentrantLock
    end

    function BinanceRateLimit(config::BinanceConfig)
        limits = APILimit[]
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
    Sets a backoff period, typically after receiving a 429 or 418 response.
    """
    function set_backoff(rate_limiter::BinanceRateLimit, retry_after_seconds::Int)
        lock(rate_limiter.lock) do
            rate_limiter.backoff_until = now(UTC) + Second(retry_after_seconds)
            @warn "Rate limit exceeded. Backing off until $(rate_limiter.backoff_until)."
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
                window_start = current_time - limit.interval

                # Remove requests that are outside the current time window
                filter!(t -> t > window_start, limit.requests)

                # If the limit is reached, wait until the oldest request expires
                if length(limit.requests) >= limit.limit
                    oldest_request_time = first(limit.requests)
                    time_to_wait = (oldest_request_time + limit.interval) - current_time
                    sleep_seconds = time_to_wait.value / 1000.0

                    if sleep_seconds > 0
                        @debug "Approaching $(limit.limit_type) limit. Sleeping for $(round(sleep_seconds, digits=2)) seconds."
                        sleep(sleep_seconds)
                    end
                    # After sleeping, re-filter the requests
                    filter!(t -> t > (now(UTC) - limit.interval), limit.requests)
                end

                # Add the new request's timestamp
                push!(limit.requests, now(UTC))
            end
        end
    end

"""
    interval_to_period(interval::String, interval_num::Int) -> Period

Converts the interval string and number from a Binance rate limit update
into a `Dates.Period` object.
"""
function interval_to_period(interval::String, interval_num::Int)
    if interval == "SECOND"
        return Second(interval_num)
    elseif interval == "MINUTE"
        return Minute(interval_num)
    elseif interval == "HOUR"
        return Hour(interval_num)
    elseif interval == "DAY"
        return Day(interval_num)
    else
        # Fallback for unknown intervals, though this shouldn't happen with the current API
        @warn "Unknown rate limit interval received: '$interval'. Cannot update this limit."
        return nothing
    end
end

"""
    update_limits!(rate_limiter::BinanceRateLimit, new_limits)

Updates the rate limiter's limits based on the `rateLimits` array
received from a WebSocket or REST API response.
"""
function update_limits!(rate_limiter::BinanceRateLimit, new_limits)
    lock(rate_limiter.lock) do
        for new_limit in new_limits
            # The WebSocket API uses "REQUEST_WEIGHT", while the config uses "REQUESTS".
            # We align them here for consistency.
            limit_type = new_limit.rateLimitType
            if limit_type == "REQUEST_WEIGHT"
                limit_type = "REQUESTS"
            end

            period = interval_to_period(new_limit.interval, new_limit.intervalNum)
            if isnothing(period)
                continue # Skip if the interval was unknown
            end

            # Check if a limit with the same type and interval already exists
            found_limit = findfirst(l -> l.limit_type == limit_type && l.interval == period, rate_limiter.limits)

            if !isnothing(found_limit)
                # Update existing limit
                existing_limit = rate_limiter.limits[found_limit]
                lock(existing_limit.lock) do
                    if existing_limit.limit != new_limit.limit
                        @info "Updating rate limit for $(limit_type) ($(period)): $(existing_limit.limit) -> $(new_limit.limit)"
                        existing_limit.limit = new_limit.limit
                    end
                end
            else
                # Add new limit
                @info "Adding new rate limit for $(limit_type) ($(period)) with limit $(new_limit.limit)"
                new_api_limit = APILimit(limit_type, period, new_limit.limit)
                push!(rate_limiter.limits, new_api_limit)
            end
        end
    end
end

end # module RateLimiter
