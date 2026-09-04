module RateLimiter

    using Dates
    using ..Config
    using ..RateLimits: EndpointCost

    export BinanceRateLimit, check_and_wait, set_backoff!, update_limits!, backoff_delay
    export finalize_request!, reconcile_from_headers!, shared_rate_limiter, used_capacity

    # A single dated charge against one limiter. Storing the cost next to the
    # timestamp is what makes weight accounting possible: `REQUEST_WEIGHT` counts
    # weight units, not requests, so one `convert/getQuote` occupies 200 slots of
    # the 6000/minute budget rather than 1.
    struct RequestCharge
        at::DateTime
        cost::Int
    end

    # Store interval as milliseconds for type stability and fast comparison
    # This avoids the abstract Period type which causes type instability
    mutable struct APILimit
        limit_type::String
        interval_ms::Int64  # Interval in milliseconds (concrete type)
        # `limit` and `used` are mutable so a server update does not have to
        # rebuild the struct (the old code replaced the element in the vector,
        # which raced with readers holding the previous object).
        limit::Int
        # Running sum of `charges`, kept incrementally: recomputing `sum` on every
        # request would be O(n) in a window that holds up to 300k entries.
        used::Int
        charges::Vector{RequestCharge}
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
        APILimit(limit_type, period_to_ms(interval), limit, 0, RequestCharge[], ReentrantLock())

    APILimit(limit_type::String, interval_ms::Int64, limit::Int) =
        APILimit(limit_type, interval_ms, limit, 0, RequestCharge[], ReentrantLock())

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

    """
        BinanceRateLimit(config::BinanceConfig)

    Build a limiter from the configured ceilings.

    The values are only a starting point: `REQUEST_WEIGHT`/`ORDERS`/`RAW_REQUESTS`
    get corrected from the server's own `rateLimits` array
    ([`update_limits!`](@ref)) and from the `X-MBX-USED-WEIGHT-*` response headers
    ([`reconcile_from_headers!`](@ref)). Configured values that are *higher* than
    the exchange's are therefore harmless after the first response, but starting
    below the real limit only costs throughput, so the defaults stay conservative.
    """
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

    # ===================== shared limiter registry =====================
    #
    # `REQUEST_WEIGHT` and `RAW_REQUESTS` are counted per IP and `ORDERS` per
    # account, so every client that talks to the same endpoint with the same
    # credentials draws on one shared budget. Giving each `RESTClient` and
    # `WebSocketClient` its own limiter meant a process running REST + WebSocket
    # (the normal shape of a strategy) each believed it had the full allowance.
    #
    # Keyed by (testnet, api_key): different accounts have separate ORDERS
    # budgets, and mainnet/testnet are separate deployments entirely. The API key
    # is only used as a dictionary key and never logged.
    const _SHARED_LIMITERS = Dict{Tuple{Bool,String},BinanceRateLimit}()
    const _SHARED_LOCK = ReentrantLock()

    """
        shared_rate_limiter(config::BinanceConfig) -> BinanceRateLimit

    The limiter shared by every client with the same credentials and network.

    Binance counts `REQUEST_WEIGHT`/`RAW_REQUESTS` per IP and `ORDERS` per account,
    so a process holding both a `RESTClient` and a `WebSocketClient` must charge
    one budget rather than two. Instances are cached per `(testnet, api_key)`.

    Pass a distinct `api_key` (or call `BinanceRateLimit(config)` directly) to get
    an isolated limiter, which is what the tests do.
    """
    function shared_rate_limiter(config::BinanceConfig)
        key = (config.testnet, config.api_key)
        lock(_SHARED_LOCK) do
            get!(() -> BinanceRateLimit(config), _SHARED_LIMITERS, key)
        end
    end

    """
        backoff_delay(base::Real, attempt::Integer; cap::Real=60.0) -> Float64

    Exponentially increasing, jittered delay (in seconds) for reconnect loops.

    `attempt` is 1-based: the first attempt waits roughly `base` seconds and each
    subsequent attempt doubles the ceiling up to `cap`. The returned value is
    randomized within 50–100% of the ceiling so that many streams reconnecting
    after the same network drop do not hit Binance in lockstep and burn through
    the 300-connections-per-5-minutes limit.
    """
    function backoff_delay(base::Real, attempt::Integer; cap::Real=60.0)::Float64
        base_seconds = max(Float64(base), 0.0)
        base_seconds == 0.0 && return 0.0
        # Cap the exponent before it is applied so large attempt counts cannot
        # overflow the shift.
        exponent = min(max(attempt - 1, 0), 16)
        ceiling = min(base_seconds * 2.0^exponent, max(Float64(cap), base_seconds))
        return ceiling * (0.5 + 0.5 * rand())
    end

    """
        set_backoff!(rate_limiter::BinanceRateLimit, retry_after::Int)

    Sets a backoff period after receiving a 429 or 418 response.

    # Arguments
    - `retry_after`: seconds to wait (REST `Retry-After` header) or, when the value
      is large enough to be a millisecond epoch, the instant the ban lifts (the
      WebSocket API's `data.retryAfter`, documented as a timestamp).

    The two wire formats genuinely differ — REST documents `Retry-After` as "the
    number of seconds required to wait" while the WebSocket 418 payload carries
    `"retryAfter": 1659146400000` — so the magnitude test stays. `1e9` seconds is
    ~31 years, far above any real backoff, and `1e9` ms is 1970, far below any
    real timestamp, so the two ranges cannot overlap in practice.
    """
    function set_backoff!(rate_limiter::BinanceRateLimit, retry_after::Int)
        retry_after >= 0 || throw(ArgumentError("retry_after must be non-negative"))

        backoff_until = lock(rate_limiter.lock) do
            if retry_after < 1_000_000_000  # seconds (REST Retry-After)
                rate_limiter.backoff_until = now(UTC) + Second(retry_after)
            else  # millisecond epoch (WebSocket data.retryAfter)
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

    """
        expire_charges!(limit::APILimit, current_time::DateTime)

    Drop charges that fell out of the sliding window, keeping `used` in step.

    `charges` is append-only in timestamp order, so expiry is a prefix removal:
    `popfirst!` amortizes to O(1) per element, whereas the previous `filter!`
    rescanned the whole vector on every single request (measured at 6.8 ms once
    `RAW_REQUESTS` held 300k entries).

    Caller must hold `limit.lock`.
    """
    function expire_charges!(limit::APILimit, current_time::DateTime)
        window_start = current_time - Millisecond(limit.interval_ms)
        @inbounds while !isempty(limit.charges) && limit.charges[1].at <= window_start
            limit.used -= limit.charges[1].cost
            popfirst!(limit.charges)
        end
        # Defensive: a server reconciliation could in principle leave `used`
        # inconsistent with the vector. Never let it go negative.
        isempty(limit.charges) && (limit.used = 0)
        limit.used < 0 && (limit.used = 0)
        return nothing
    end

    """
        reserve!(limit::APILimit, cost::Int) -> DateTime

    Block until `cost` units fit in the window, then charge them.

    Returns the timestamp the charge was recorded at, so a caller that later
    learns the true cost can amend that exact entry
    (see [`finalize_request!`](@ref)).

    A `cost` larger than the whole limit would loop forever waiting for room that
    can never exist, so it is clamped with a warning: the request is going to be
    rejected by the server anyway, and hanging is worse than trying.
    """
    function reserve!(limit::APILimit, cost::Int)
        charge = max(cost, 0)
        if charge > limit.limit
            @warn "Request cost exceeds the whole limit; charging the maximum instead" limit_type=limit.limit_type cost=charge limit=limit.limit maxlog=3
            charge = limit.limit
        end

        while true
            outcome = lock(limit.lock) do
                current_time = now(UTC)
                expire_charges!(limit, current_time)

                if limit.used + charge <= limit.limit
                    push!(limit.charges, RequestCharge(current_time, charge))
                    limit.used += charge
                    return (0.0, current_time)
                end

                # Wait for enough of the oldest charges to expire to make room.
                # Waiting only for the single oldest entry is not enough when the
                # charges are small relative to `cost`.
                needed = limit.used + charge - limit.limit
                freed = 0
                deadline = current_time
                @inbounds for c in limit.charges
                    freed += c.cost
                    deadline = c.at
                    freed >= needed && break
                end
                wait_period = deadline + Millisecond(limit.interval_ms) - current_time
                return (max(Dates.value(wait_period) / 1000, 0.0), current_time)
            end

            sleep_seconds, at = outcome
            sleep_seconds <= 0 && return at
            @debug "Approaching $(limit.limit_type) limit. Sleeping for $(round(sleep_seconds, digits=2)) seconds." cost=charge used=limit.used limit=limit.limit
            sleep(sleep_seconds)
        end
    end

    """
        amend_charge!(limit::APILimit, at::DateTime, new_cost::Int)

    Retroactively change the cost of the charge recorded at `at`.

    Used for the endpoints whose weight became 0 on success (2026-04-02): the cost
    cannot be known before the response arrives, so the limiter reserves the
    documented weight up front and releases it here if the request succeeded.
    Reserving optimistically instead would let a burst of failures blow the budget.
    """
    function amend_charge!(limit::APILimit, at::DateTime, new_cost::Int)
        lock(limit.lock) do
            idx = findlast(c -> c.at == at, limit.charges)
            isnothing(idx) && return nothing  # already expired out of the window
            old = limit.charges[idx]
            limit.charges[idx] = RequestCharge(old.at, new_cost)
            limit.used += new_cost - old.cost
            limit.used < 0 && (limit.used = 0)
            return nothing
        end
    end

    """
        used_capacity(rate_limiter, limit_type, interval_ms=nothing) -> (used, limit)

    Current consumption of a limiter, for diagnostics and tests. With several
    intervals for one type (`ORDERS` has 10s and 1d), `interval_ms` picks one;
    otherwise the first match wins.
    """
    function used_capacity(rate_limiter::BinanceRateLimit, limit_type::AbstractString,
                           interval_ms::Union{Int64,Nothing}=nothing)
        limits = lock(rate_limiter.lock) do
            copy(rate_limiter.limits)
        end
        for limit in limits
            limit.limit_type == limit_type || continue
            isnothing(interval_ms) || limit.interval_ms == interval_ms || continue
            return lock(limit.lock) do
                expire_charges!(limit, now(UTC))
                (limit.used, limit.limit)
            end
        end
        return (0, 0)
    end

    """
        RequestReservation

    Where a request's charges landed, so they can be corrected once the response
    is known. Returned by [`check_and_wait`](@ref) and consumed by
    [`finalize_request!`](@ref).
    """
    struct RequestReservation
        # (limit, timestamp, reserved_cost) per limiter that was charged.
        entries::Vector{Tuple{APILimit,DateTime,Int}}
        zero_weight_on_success::Bool
    end

    RequestReservation() = RequestReservation(Tuple{APILimit,DateTime,Int}[], false)

    """
        check_and_wait(rate_limiter, request_type) -> RequestReservation
        check_and_wait(rate_limiter, cost; is_order_endpoint=false) -> RequestReservation

    Reserve capacity for one request, sleeping until it fits, and honour any
    backoff set by a previous 429/418.

    The `EndpointCost` form is what callers should use: it charges the documented
    weight to `REQUEST_WEIGHT`, the unfilled-order count to `ORDERS`, and one unit
    to `RAW_REQUESTS`, which is how the exchange accounts for a request. The
    `String` form remains for limiters that are not weight-based (`CONNECTIONS`)
    and charges a single unit.

    Pass the returned reservation to [`finalize_request!`](@ref) once the outcome
    is known so the 2026-04-02 "0 weight on success" endpoints can be refunded.
    """
    function check_and_wait(rate_limiter::BinanceRateLimit, request_type::AbstractString)
        wait_for_backoff(rate_limiter)
        entries = Tuple{APILimit,DateTime,Int}[]
        for limit in _matching_limits(rate_limiter, request_type)
            at = reserve!(limit, 1)
            push!(entries, (limit, at, 1))
        end
        return RequestReservation(entries, false)
    end

    function check_and_wait(rate_limiter::BinanceRateLimit, cost::EndpointCost)
        wait_for_backoff(rate_limiter)

        entries = Tuple{APILimit,DateTime,Int}[]

        # Order-count first: it is the scarcest budget (100 per 10s) and the one
        # whose exhaustion must not be preceded by spending weight.
        if cost.orders > 0
            for limit in _matching_limits(rate_limiter, "ORDERS")
                at = reserve!(limit, cost.orders)
                push!(entries, (limit, at, cost.orders))
            end
        end

        if cost.weight > 0
            for limit in _matching_limits(rate_limiter, "REQUEST_WEIGHT")
                at = reserve!(limit, cost.weight)
                push!(entries, (limit, at, cost.weight))
            end
        end

        # Every request counts once against RAW_REQUESTS regardless of weight.
        for limit in _matching_limits(rate_limiter, "RAW_REQUESTS")
            at = reserve!(limit, 1)
            push!(entries, (limit, at, 1))
        end

        return RequestReservation(entries, cost.zero_on_success)
    end

    # Copying at most a handful of small limit objects keeps iteration safe while
    # a server response updates the vector, without holding the global lock during
    # a potentially long wait.
    function _matching_limits(rate_limiter::BinanceRateLimit, limit_type::AbstractString)
        limits = lock(rate_limiter.lock) do
            copy(rate_limiter.limits)
        end
        return Iterators.filter(l -> l.limit_type == limit_type, limits)
    end

    """
        finalize_request!(reservation, succeeded::Bool)

    Settle a reservation now that the response is in.

    For the endpoints changed on 2026-04-02 (order placement, cancellation, and
    their list variants), a successful request costs 0 `REQUEST_WEIGHT`; a failed
    one is still charged the documented weight. The reservation charged the
    documented weight up front — pessimism is the only safe direction — so a
    success refunds it here.

    `ORDERS` and `RAW_REQUESTS` are never refunded: a placed order consumes the
    unfilled-order count whatever the weight rules say, and every request counts
    as a raw request.
    """
    function finalize_request!(reservation::RequestReservation, succeeded::Bool)
        (succeeded && reservation.zero_weight_on_success) || return nothing
        for (limit, at, _) in reservation.entries
            limit.limit_type == "REQUEST_WEIGHT" || continue
            amend_charge!(limit, at, 0)
        end
        return nothing
    end

    """
        reconcile_from_headers!(rate_limiter, headers)

    Adopt the server's own usage counters from `X-MBX-USED-WEIGHT-*` and
    `X-MBX-ORDER-COUNT-*` response headers.

    Every REST response carries `X-MBX-USED-WEIGHT-(intervalNum)(intervalLetter)`,
    and successful order responses add `X-MBX-ORDER-COUNT-*`. Without reading them
    a REST-only client never learns its true consumption: the server reported 697
    used weight while the client's own tally was in the single digits. Since the
    limits are per IP, anything else sharing the address (another process, another
    machine behind the same NAT) is invisible except through these headers.

    Only ever adjusts upward — see [`sync_usage!`](@ref) for why.
    """
    function reconcile_from_headers!(rate_limiter::BinanceRateLimit, headers)
        for (name, value) in headers
            upper = uppercase(String(name))
            limit_type = if startswith(upper, "X-MBX-USED-WEIGHT-")
                "REQUEST_WEIGHT"
            elseif startswith(upper, "X-MBX-ORDER-COUNT-")
                "ORDERS"
            else
                continue
            end

            suffix = upper[(findlast('-', upper)+1):end]
            interval_ms = _parse_header_interval(suffix)
            interval_ms == 0 && continue

            server_used = tryparse(Int, strip(String(value)))
            isnothing(server_used) && continue

            for limit in _matching_limits(rate_limiter, limit_type)
                limit.interval_ms == interval_ms || continue
                sync_usage!(limit, server_used)
            end
        end
        return nothing
    end

    """
        _parse_header_interval(suffix) -> Int64

    `"1M"` → 60000, `"10S"` → 10000, `"1D"` → 86400000. Returns 0 for anything
    unrecognized. The bare `X-MBX-USED-WEIGHT` header (no interval) also lands
    here and is skipped: its interval is unspecified, and the suffixed variant is
    always sent alongside it.
    """
    function _parse_header_interval(suffix::AbstractString)
        isempty(suffix) && return Int64(0)
        letter = last(suffix)
        num = tryparse(Int, suffix[1:prevind(suffix, lastindex(suffix))])
        isnothing(num) && return Int64(0)
        letter == 'S' && return Int64(num) * 1000
        letter == 'M' && return Int64(num) * 60_000
        letter == 'H' && return Int64(num) * 3_600_000
        letter == 'D' && return Int64(num) * 86_400_000
        return Int64(0)
    end

    """
        sync_usage!(limit::APILimit, server_used::Int)

    Align one limiter with the server's usage figure.

    Adjusts upward by appending a single charge for the difference, dated now, so
    it expires with the current window. The previous implementation pushed
    `server_used - local` individual timestamps all bearing the same instant,
    which both allocated proportionally to the count (5000 entries for one
    response) and made the whole window expire in one cliff.

    Never adjusts downward. The server figure is a snapshot from when the response
    was produced; requests issued after that point are legitimately counted
    locally but not there, so trusting a lower number would double-spend them. A
    genuine window rollover is handled by `expire_charges!` instead.
    """
    function sync_usage!(limit::APILimit, server_used::Int)
        lock(limit.lock) do
            current_time = now(UTC)
            expire_charges!(limit, current_time)
            deficit = server_used - limit.used
            if deficit > 0
                push!(limit.charges, RequestCharge(current_time, deficit))
                limit.used += deficit
                @debug "Adjusted $(limit.limit_type) usage up to match server" interval_ms=limit.interval_ms local_used=limit.used-deficit server_used
            end
            return nothing
        end
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

Adopt the `rateLimits` array from a WebSocket or REST response.

This is the authoritative source for both the ceilings and the current usage: the
configured defaults are only a guess, and they have been wrong in the safe
direction (config said 50 orders/10s and 160k/day where the account actually
allows 100 and 200k) and could just as easily be wrong in the unsafe one.

Usage is synced through [`sync_usage!`](@ref), which only ever revises upward.
"""
function update_limits!(rate_limiter::BinanceRateLimit, new_limits)
    for new_limit in new_limits
        limit_type = string(new_limit.rateLimitType)

        interval_ms = interval_to_ms(string(new_limit.interval), new_limit.intervalNum)
        interval_ms == 0 && continue  # unknown interval

        matching = lock(rate_limiter.lock) do
            idx = findfirst(l -> l.limit_type == limit_type && l.interval_ms == interval_ms,
                            rate_limiter.limits)
            if isnothing(idx)
                # Server reports a limiter we were not tracking (e.g. a new
                # interval). Track it rather than ignoring it.
                limit = APILimit(limit_type, interval_ms, new_limit.limit)
                push!(rate_limiter.limits, limit)
                return limit
            end
            return rate_limiter.limits[idx]
        end

        # `APILimit` is mutable now, so the ceiling is updated in place. The old
        # code replaced the vector element, leaving any concurrent reader holding
        # a detached object whose charges were no longer being updated.
        if matching.limit != new_limit.limit
            @debug "Rate limit for $limit_type/$(interval_ms)ms updated: $(matching.limit) -> $(new_limit.limit)"
            lock(matching.lock) do
                matching.limit = new_limit.limit
            end
        end

        hasproperty(new_limit, :count) && sync_usage!(matching, Int(new_limit.count))
    end
    return nothing
end

end # module RateLimiter
