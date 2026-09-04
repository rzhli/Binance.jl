"""
    RateLimiter

Binance rate-limit compliance: what each request costs, and whether it fits right
now.

The two halves meet at [`EndpointCost`](@ref):

1. **Cost** — the per-endpoint weight tables at the bottom of this file,
   transcribed from the Spot API docs (`rest-api.md`, `web-socket-api.md`,
   changelog 2026-04-02). They are data, they are long, and they move whenever
   Binance publishes a changelog entry.
2. **Capacity** — the sliding-window limiter that follows this docstring. It does
   not change when a weight does.

Both are needed to answer one question, so they share a module. `EndpointCost` is
defined before the limiter because `check_and_wait` dispatches on it.

Why the cost tables exist at all: this limiter used to charge every request 1 unit
against `REQUEST_WEIGHT`, but the exchange charges each endpoint its documented
weight. With a 6000/minute budget, 30 successful `convert/getQuote` calls (weight
200 each) exhaust the real allowance while the client still believes it has 5970
requests left — which is how a strategy ends up with a 429 and then an IP ban.

The limiters, and how a request is charged against them:

* `REQUEST_WEIGHT` — per IP, shared by every connection from that address.
* `ORDERS` (the docs call it *unfilled order count*) — per account. Only the
  endpoints that actually place orders consume it; querying an order does not.
* `RAW_REQUESTS` — per IP, one unit per request regardless of weight.
* `CONNECTIONS` — per IP, one unit per WebSocket dial. Not weight-based, which is
  why `check_and_wait` keeps a `String` form alongside the `EndpointCost` one.

Order-placement and cancellation endpoints were changed on 2026-04-02 to cost
**0 weight when the request succeeds**; a failed request is still charged the
documented weight. The cost therefore carries both numbers and
[`finalize_request!`](@ref) settles the difference once the response is in.
"""
module RateLimiter

    using Dates
    using ..Config

    export BinanceRateLimit, check_and_wait, set_backoff!, update_limits!, backoff_delay
    export finalize_request!, reconcile_from_headers!, shared_rate_limiter, used_capacity
    export EndpointCost, endpoint_cost, ws_method_cost

    """
        EndpointCost

    What one API call costs against each limiter.

    # Fields
    - `weight::Int`: `REQUEST_WEIGHT` charged when the request fails, and also when
      it succeeds unless `zero_on_success` is set.
    - `orders::Int`: unfilled order count consumed (the `ORDERS` limiter). Only
      order-placing endpoints are non-zero — querying an order costs nothing here.
    - `zero_on_success::Bool`: per the 2026-04-02 change, weight becomes 0 when the
      request succeeds. The outcome is unknowable before sending, so the limiter
      reserves the documented weight and [`finalize_request!`](@ref) releases it.

    Built by [`endpoint_cost`](@ref) for REST and [`ws_method_cost`](@ref) for the
    WebSocket API.
    """
    struct EndpointCost
        weight::Int
        orders::Int
        zero_on_success::Bool
    end

    EndpointCost(weight::Int) = EndpointCost(weight, 0, false)
    EndpointCost(weight::Int, orders::Int) = EndpointCost(weight, orders, false)

    # ===================== sliding-window limiter =====================

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

    """
        check_and_wait(rate_limiter, cost::EndpointCost) -> RequestReservation
        check_and_wait(rate_limiter, limit_type::AbstractString) -> RequestReservation

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

    # ===================== REST endpoints =====================
    #
    # Keys are the paths passed to `make_request`. Endpoints whose weight depends on
    # parameters (`depth` limit, symbol count, `computeCommissionRates`) are resolved
    # by `endpoint_cost` from the params, with the table holding the single-symbol /
    # cheapest case.
    #
    # `zero_on_success = true` mirrors the 2026-03-27 announcement (effective
    # 2026-04-02). `PUT /api/v3/order/amend/keepPriority` is deliberately *not* in
    # that set: the 2026-04-02 clarification says its weight only drops to 0 when the
    # amendment expires the order, so charging the documented 4 is the safe reading.
    const REST_COSTS = Dict{String,EndpointCost}(
        # --- General ---
        "/api/v3/ping"                     => EndpointCost(1),
        "/api/v3/time"                     => EndpointCost(1),
        "/api/v3/exchangeInfo"             => EndpointCost(20),

        # --- Market data ---
        "/api/v3/depth"                    => EndpointCost(5),    # limit-dependent
        "/api/v3/trades"                   => EndpointCost(25),
        "/api/v3/historicalTrades"         => EndpointCost(25),
        "/api/v3/historicalBlockTrades"    => EndpointCost(25),
        "/api/v3/aggTrades"                => EndpointCost(4),
        "/api/v3/klines"                   => EndpointCost(2),
        "/api/v3/uiKlines"                 => EndpointCost(2),
        "/api/v3/avgPrice"                 => EndpointCost(2),
        "/api/v3/ticker/24hr"              => EndpointCost(2),    # symbol-count dependent
        "/api/v3/ticker/tradingDay"        => EndpointCost(4),    # symbol-count dependent
        "/api/v3/ticker/price"             => EndpointCost(2),    # symbol-count dependent
        "/api/v3/ticker/bookTicker"        => EndpointCost(2),    # symbol-count dependent
        "/api/v3/ticker"                   => EndpointCost(4),    # symbol-count dependent
        "/api/v3/executionRules"           => EndpointCost(2),    # symbol-count dependent
        "/api/v3/referencePrice"           => EndpointCost(2),
        "/api/v3/referencePrice/calculation" => EndpointCost(2),

        # --- Trading (weight 0 on success since 2026-04-02) ---
        "/api/v3/order"                    => EndpointCost(1, 1, true),   # POST; GET/DELETE below
        "/api/v3/order/test"               => EndpointCost(1, 0, false),  # never placed, weight always charged
        "/api/v3/order/cancelReplace"      => EndpointCost(1, 1, true),
        "/api/v3/order/amend/keepPriority" => EndpointCost(4, 0, false),
        "/api/v3/openOrders"               => EndpointCost(1, 0, true),   # DELETE; GET below
        "/api/v3/sor/order"                => EndpointCost(1, 1, true),
        "/api/v3/sor/order/test"           => EndpointCost(1, 0, false),

        # --- Order lists (weight 0 on success) ---
        "/api/v3/order/oco"                => EndpointCost(1, 2, true),   # deprecated alias
        "/api/v3/orderList/oco"            => EndpointCost(1, 2, true),
        "/api/v3/orderList/oto"            => EndpointCost(1, 2, true),
        "/api/v3/orderList/otoco"          => EndpointCost(1, 3, true),
        "/api/v3/orderList/opo"            => EndpointCost(1, 2, true),
        "/api/v3/orderList/opoco"          => EndpointCost(1, 3, true),
        "/api/v3/orderList"                => EndpointCost(1, 0, true),   # DELETE; GET below

        # --- Account / queries (no order-count cost) ---
        "/api/v3/account"                  => EndpointCost(20),
        "/api/v3/allOrders"                => EndpointCost(20),
        "/api/v3/allOrderList"             => EndpointCost(20),
        "/api/v3/openOrderList"            => EndpointCost(6),
        "/api/v3/myTrades"                 => EndpointCost(20),   # 5 with orderId
        "/api/v3/rateLimit/order"          => EndpointCost(40),
        "/api/v3/myPreventedMatches"       => EndpointCost(2),    # 20 when querying by orderId
        "/api/v3/myAllocations"            => EndpointCost(20),
        "/api/v3/account/commission"       => EndpointCost(20),
        "/api/v3/order/amendments"         => EndpointCost(4),
        "/api/v3/myFilters"                => EndpointCost(40),
        "/api/v3/userDataStream"           => EndpointCost(2),

        # --- SAPI ---
        #
        # SAPI weights are documented per endpoint and marked (IP) or (UID). They are
        # tracked here so a heavy SAPI call is not charged as 1; the UID/IP
        # distinction is not modelled because the client cannot see the server's UID
        # counters. Convert's separate *daily quotation count* is not a weight limit
        # at all and is invisible until error 345239 comes back.
        "/sapi/v1/convert/exchangeInfo"    => EndpointCost(3000),
        "/sapi/v1/convert/assetInfo"       => EndpointCost(100),
        "/sapi/v1/convert/getQuote"        => EndpointCost(200),
        "/sapi/v1/convert/acceptQuote"     => EndpointCost(500),
        "/sapi/v1/convert/orderStatus"     => EndpointCost(100),
        "/sapi/v1/convert/tradeFlow"       => EndpointCost(3000),
        "/sapi/v1/convert/limit/placeOrder" => EndpointCost(500),
        "/sapi/v1/convert/limit/cancelOrder" => EndpointCost(200),
        "/sapi/v1/convert/limit/queryOpenOrders" => EndpointCost(3000),
        "/sapi/v1/account/status"          => EndpointCost(1),
        "/sapi/v1/account/apiTradingStatus" => EndpointCost(1),
        "/sapi/v1/account/apiRestrictions" => EndpointCost(1),
        "/sapi/v1/capital/withdraw/history" => EndpointCost(1),
        "/sapi/v1/capital/withdraw/apply"  => EndpointCost(1),
        "/sapi/v1/capital/deposit/hisrec"  => EndpointCost(1),
        "/sapi/v1/capital/deposit/address" => EndpointCost(1),
        "/sapi/v1/asset/assetDetail"       => EndpointCost(1),
        "/sapi/v1/asset/tradeFee"          => EndpointCost(1),
        "/sapi/v1/asset/dust"              => EndpointCost(1),
        "/sapi/v1/asset/dribblet"          => EndpointCost(1),
    )

    # `GET`/`DELETE` on a path that also accepts `POST` cost differently: querying an
    # order is a plain weighted read, placing one is order-count-bearing and free on
    # success. Keyed by `(method, path)` and consulted before `REST_COSTS`.
    const REST_COSTS_BY_METHOD = Dict{Tuple{String,String},EndpointCost}(
        ("GET", "/api/v3/order")        => EndpointCost(4),   # query order: no order-count cost
        ("DELETE", "/api/v3/order")     => EndpointCost(1, 0, true),
        ("GET", "/api/v3/openOrders")   => EndpointCost(6),   # 80 without symbol
        ("GET", "/api/v3/orderList")    => EndpointCost(4),
        ("GET", "/api/v3/userDataStream")    => EndpointCost(2),
        ("PUT", "/api/v3/userDataStream")    => EndpointCost(2),
        ("DELETE", "/api/v3/userDataStream") => EndpointCost(2),
    )

    # Fallback for an endpoint missing from both tables. Deliberately not 1: an
    # unknown endpoint is more likely to be a heavy account/market query than a ping,
    # and under-charging is what causes bans.
    const DEFAULT_REST_COST = EndpointCost(20)

    """
        endpoint_cost(method, endpoint, params) -> EndpointCost

    The cost of one REST call. `params` resolves the endpoints whose documented weight
    depends on arguments rather than on the path alone.

    Unknown endpoints fall back to `DEFAULT_REST_COST` (20) and emit a `@debug`,
    because silently charging 1 is what let the old limiter drift.
    """
    function endpoint_cost(method::AbstractString, endpoint::AbstractString,
                           params::AbstractDict=Dict{String,Any}())
        key = (String(method), String(endpoint))
        base = get(REST_COSTS_BY_METHOD, key) do
            get(REST_COSTS, String(endpoint)) do
                @debug "No documented weight for endpoint; assuming $(DEFAULT_REST_COST.weight)" method endpoint
                DEFAULT_REST_COST
            end
        end
        return _adjust_for_params(base, String(endpoint), String(method), params)
    end

    # Symbol-count and limit-dependent weights. Each branch mirrors one weight table
    # in the docs; the tables are small enough to inline and change rarely.
    function _adjust_for_params(base::EndpointCost, endpoint::String, method::String,
                                params::AbstractDict)
        if endpoint == "/api/v3/depth"
            limit = _int_param(params, "limit", 100)
            w = limit <= 100 ? 5 : limit <= 500 ? 25 : limit <= 1000 ? 50 : 250
            return EndpointCost(w, base.orders, base.zero_on_success)

        elseif endpoint == "/api/v3/ticker/24hr"
            n = _symbol_count(params)
            # 1 symbol: 2 | 1-20 symbols: 2 | 21-100: 40 | 101+ or omitted: 80
            w = n == 0 ? 80 : n <= 20 ? 2 : n <= 100 ? 40 : 80
            return EndpointCost(w, base.orders, base.zero_on_success)

        elseif endpoint in ("/api/v3/ticker/price", "/api/v3/ticker/bookTicker")
            n = _symbol_count(params)
            return EndpointCost(n == 1 ? 2 : 4, base.orders, base.zero_on_success)

        elseif endpoint in ("/api/v3/ticker", "/api/v3/ticker/tradingDay")
            # 4 per symbol, capped at 200 beyond 50 symbols.
            n = max(_symbol_count(params), 1)
            return EndpointCost(min(4 * n, 200), base.orders, base.zero_on_success)

        elseif endpoint == "/api/v3/executionRules"
            # 2 per symbol capped at 40; 40 for symbolStatus or no params.
            n = _symbol_count(params)
            w = n == 0 ? 40 : haskey(params, "symbolStatus") ? 40 : min(2 * n, 40)
            return EndpointCost(w, base.orders, base.zero_on_success)

        elseif endpoint == "/api/v3/openOrders" && method == "GET"
            return EndpointCost(_symbol_count(params) == 0 ? 80 : 6,
                                base.orders, base.zero_on_success)

        elseif endpoint == "/api/v3/myTrades"
            return EndpointCost(haskey(params, "orderId") ? 5 : 20,
                                base.orders, base.zero_on_success)

        elseif endpoint == "/api/v3/myPreventedMatches"
            return EndpointCost(haskey(params, "orderId") ? 20 : 2,
                                base.orders, base.zero_on_success)

        elseif endpoint in ("/api/v3/order/test", "/api/v3/sor/order/test")
            return EndpointCost(_bool_param(params, "computeCommissionRates") ? 20 : 1,
                                base.orders, base.zero_on_success)
        end
        return base
    end

    # ===================== WebSocket API methods =====================
    #
    # Same weights as the REST equivalents; keyed by method name because that is what
    # `send_request` has. Order-placing methods are the `zero_on_success` set from the
    # 2026-03-27 announcement.
    const WS_COSTS = Dict{String,EndpointCost}(
        "ping"                        => EndpointCost(1),
        "time"                        => EndpointCost(1),
        "exchangeInfo"                => EndpointCost(20),
        "executionRules"              => EndpointCost(2),
        "depth"                       => EndpointCost(5),
        "trades.recent"               => EndpointCost(25),
        "trades.historical"           => EndpointCost(25),
        "blockTrades.historical"      => EndpointCost(25),
        "trades.aggregate"            => EndpointCost(4),
        "klines"                      => EndpointCost(2),
        "uiKlines"                    => EndpointCost(2),
        "avgPrice"                    => EndpointCost(2),
        "ticker.24hr"                 => EndpointCost(2),
        "ticker.tradingDay"           => EndpointCost(4),
        "ticker"                      => EndpointCost(4),
        "ticker.price"                => EndpointCost(2),
        "ticker.book"                 => EndpointCost(2),
        "referencePrice"              => EndpointCost(2),
        "referencePrice.calculation"  => EndpointCost(2),

        "session.logon"               => EndpointCost(2),
        "session.status"              => EndpointCost(2),
        "session.logout"              => EndpointCost(2),

        # Trading: 0 weight on success, documented weight on failure.
        "order.place"                 => EndpointCost(1, 1, true),
        "order.test"                  => EndpointCost(1, 0, false),
        "order.cancel"                => EndpointCost(1, 0, true),
        "order.cancelReplace"         => EndpointCost(1, 1, true),
        "order.amend.keepPriority"    => EndpointCost(4, 0, false),
        "openOrders.cancelAll"        => EndpointCost(1, 0, true),
        "orderList.place"             => EndpointCost(1, 2, true),
        "orderList.place.oco"         => EndpointCost(1, 2, true),
        "orderList.place.oto"         => EndpointCost(1, 2, true),
        "orderList.place.otoco"       => EndpointCost(1, 3, true),
        "orderList.place.opo"         => EndpointCost(1, 2, true),
        "orderList.place.opoco"       => EndpointCost(1, 3, true),
        "orderList.cancel"            => EndpointCost(1, 0, true),
        "sor.order.place"             => EndpointCost(1, 1, true),
        "sor.order.test"              => EndpointCost(1, 0, false),

        # Account queries.
        "account.status"              => EndpointCost(20),
        "order.status"                => EndpointCost(4),
        "openOrders.status"           => EndpointCost(6),
        "allOrders"                   => EndpointCost(20),
        "orderList.status"            => EndpointCost(4),
        "openOrderLists.status"       => EndpointCost(6),
        "allOrderLists"               => EndpointCost(20),
        "myTrades"                    => EndpointCost(20),
        "account.rateLimits.orders"   => EndpointCost(40),
        "myPreventedMatches"          => EndpointCost(2),
        "myAllocations"               => EndpointCost(20),
        "account.commission"          => EndpointCost(20),
        "order.amendments"            => EndpointCost(4),
        "myFilters"                   => EndpointCost(40),

        "userDataStream.subscribe"    => EndpointCost(2),
        "userDataStream.unsubscribe"  => EndpointCost(2),
        "userDataStream.start"        => EndpointCost(2),
        "userDataStream.ping"         => EndpointCost(2),
        "userDataStream.stop"         => EndpointCost(2),
        "session.subscriptions"       => EndpointCost(2),
        "userDataStream.subscribe.signature" => EndpointCost(2),
    )

    """
        ws_method_cost(method, params) -> EndpointCost

    The cost of one WebSocket API request. Mirrors [`endpoint_cost`](@ref); the
    parameter-dependent adjustments reuse the REST tables via the equivalent path.
    """
    function ws_method_cost(method::AbstractString, params::AbstractDict=Dict{String,Any}())
        base = get(WS_COSTS, String(method)) do
            @debug "No documented weight for WS method; assuming $(DEFAULT_REST_COST.weight)" method
            DEFAULT_REST_COST
        end
        equivalent = get(WS_TO_REST_PATH, String(method), "")
        isempty(equivalent) && return base
        return _adjust_for_params(base, equivalent, "GET", params)
    end

    # WS methods whose weight varies with parameters, mapped onto the REST path whose
    # weight table they share.
    const WS_TO_REST_PATH = Dict{String,String}(
        "depth"               => "/api/v3/depth",
        "ticker.24hr"         => "/api/v3/ticker/24hr",
        "ticker.price"        => "/api/v3/ticker/price",
        "ticker.book"         => "/api/v3/ticker/bookTicker",
        "ticker"              => "/api/v3/ticker",
        "ticker.tradingDay"   => "/api/v3/ticker/tradingDay",
        "executionRules"      => "/api/v3/executionRules",
        "openOrders.status"   => "/api/v3/openOrders",
        "myTrades"            => "/api/v3/myTrades",
        "myPreventedMatches"  => "/api/v3/myPreventedMatches",
        "order.test"          => "/api/v3/order/test",
        "sor.order.test"      => "/api/v3/sor/order/test",
    )

    # ===================== param helpers =====================
    #
    # Params arrive as `Dict{String,Any}` with values already stringified for the
    # query builder, so `"limit" => 500` and `"limit" => "500"` both occur.

    function _int_param(params::AbstractDict, key::String, default::Int)
        haskey(params, key) || return default
        v = params[key]
        v isa Integer && return Int(v)
        v isa AbstractString && return something(tryparse(Int, v), default)
        return default
    end

    function _bool_param(params::AbstractDict, key::String)
        haskey(params, key) || return false
        v = params[key]
        v isa Bool && return v
        v isa AbstractString && return lowercase(v) == "true"
        return false
    end

    """
        _symbol_count(params) -> Int

    How many symbols a request covers: 1 for `symbol`, `n` for a `symbols` JSON array,
    0 when neither is present (which the docs price as "all symbols").
    """
    function _symbol_count(params::AbstractDict)
        haskey(params, "symbol") && return 1
        haskey(params, "symbols") || return 0
        v = params["symbols"]
        v isa AbstractVector && return length(v)
        if v isa AbstractString
            # Serialized as `["BTCUSDT","ETHUSDT"]`; counting commas avoids a JSON
            # parse on a hot path and is exact for the shapes the client produces.
            isempty(strip(v, ['[', ']', ' '])) && return 0
            return count(==(','), v) + 1
        end
        return 0
    end

end # module RateLimiter
