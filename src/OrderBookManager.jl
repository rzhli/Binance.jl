"""
OrderBookManager Module

Provides local order book management with automatic synchronization from Binance WebSocket streams.

Following Binance's corrected guidelines (2025-11-12) for maintaining a local order book:
https://binance-docs.github.io/apidocs/spot/en/#diff-depth-stream

# Key Features
- Automatic WebSocket stream subscription and event buffering
- REST API snapshot fetching with proper validation
- Continuous differential updates application
- Automatic reconnection and resynchronization on errors
- Thread-safe access to order book data
- Customizable callbacks for order book updates

# Example
```julia
using Binance

rest_client = RESTClient("config.toml")
ws_client = MarketDataStreamClient("config.toml")

# Create and start order book manager
manager = OrderBookManager("BTCUSDT", rest_client, ws_client)
start!(manager)

# Access order book data (near-zero latency)
best_bid = get_best_bid(manager)
best_ask = get_best_ask(manager)
spread = get_spread(manager)

# Get top N levels
top_5_bids = get_bids(manager, 5)
top_5_asks = get_asks(manager, 5)

# Stop when done
stop!(manager)
```
"""
module OrderBookManagers

using DataStructures: OrderedDict
using ..Config: BinanceConfig
using ..RESTAPI: get_orderbook
using ..Types: PriceLevel
using ..MarketDataStreams: subscribe_diff_depth, unsubscribe, MarketDataStreamClient
using ..SBEMarketDataStreams: SBEStreamClient, sbe_subscribe_depth, sbe_subscribe_depth20, sbe_unsubscribe_depth, sbe_unsubscribe_depth20, DepthDiffEvent, DepthSnapshotEvent

export OrderBookManager, PriceQuantity, OrderBookSnapshot, start!, stop!, is_ready,
    get_best_bid, get_best_ask, get_spread, get_mid_price,
    get_bids, get_asks, get_orderbook_snapshot,
    calculate_vwap, calculate_depth_imbalance

const DepthEvent = Union{AbstractDict,DepthDiffEvent}

# ============================================================================
# Core Data Structures
# ============================================================================

"""
    PriceQuantity

Represents a single price level in the order book.
"""
struct PriceQuantity
    price::Float64
    quantity::Float64
end

"""
    OrderBookSnapshot

Immutable snapshot of the order book at a point in time.
"""
struct OrderBookSnapshot
    symbol::String
    update_id::Int64
    bids::Vector{PriceQuantity}  # Sorted descending by price
    asks::Vector{PriceQuantity}  # Sorted ascending by price
    timestamp::Float64
end

"""
    OrderBookManager{R,W,F}

Manages a local order book with automatic synchronization from Binance.

# Type Parameters
- `R`: REST client type (e.g., RESTClient)
- `W`: WebSocket client type (e.g., MarketDataStreamClient or SBEStreamClient)
- `F`: Callback function type (for type stability)

# Fields
- `symbol::String`: Trading pair symbol (e.g., "BTCUSDT")
- `rest_client::R`: REST API client for fetching snapshots
- `ws_client::W`: WebSocket client for streaming updates
- `update_id::Ref{Int64}`: Current order book update ID
- `bids::OrderedDict{Float64,Float64}`: Buy orders (price => quantity)
- `asks::OrderedDict{Float64,Float64}`: Sell orders (price => quantity)
- `best_bid_price::Ref{Float64}`: Cached highest bid price
- `best_ask_price::Ref{Float64}`: Cached lowest ask price
- `is_initialized::Ref{Bool}`: Whether order book is ready
- `event_buffer::Vector{DepthEvent}`: Buffer for events before initialization
- `stream_id::Ref{Union{String,Nothing}}`: WebSocket stream ID
- `on_update::F`: Optional callback on updates (parameterized for type stability)
- `max_depth::Int`: Maximum depth for REST snapshot (default: 5000)
- `update_speed::String`: Update speed "100ms" or "1000ms" (default: "100ms")
"""
mutable struct OrderBookManager{R,W,F}
    symbol::String
    rest_client::R
    ws_client::W

    # Order book state
    update_id::Ref{Int64}
    bids::OrderedDict{Float64,Float64}
    asks::OrderedDict{Float64,Float64}
    best_bid_price::Ref{Float64}
    best_ask_price::Ref{Float64}

    # Cached sorted arrays (lazily updated)
    sorted_bids::Vector{Tuple{Float64,Float64}}  # (price, qty) sorted descending
    sorted_asks::Vector{Tuple{Float64,Float64}}  # (price, qty) sorted ascending
    cache_valid::Ref{Bool}  # Invalidated on each update

    # Synchronization state
    is_initialized::Ref{Bool}
    event_buffer::Vector{DepthEvent}

    # WebSocket subscription
    stream_id::Ref{Union{String,Nothing}}

    # Configuration
    on_update::F  # Parameterized for type stability (Nothing or concrete function type)
    max_depth::Int
    update_speed::String

    # When true, subscribe to <symbol>@depth20 (SBE only) which pushes a fresh
    # top-20 snapshot every 50ms. Replaces local state atomically — no diff
    # sync, no phantom levels, no crossings. max_depth is forced to 20.
    use_snapshot_stream::Bool

    # Statistics
    total_updates::Ref{Int64}
    last_update_time::Ref{Float64}

    # Health: counts consecutive events where best_bid >= best_ask. SBE diff
    # events sometimes arrive split (bid-side and ask-side updates in
    # separate messages), causing transient crosses that self-heal on the
    # next event. We only warn / suppress callbacks when the cross persists.
    consecutive_crosses::Ref{Int}
    state_lock::ReentrantLock
end

"""
    OrderBookManager(symbol, rest_client, ws_client; kwargs...)

Create a new OrderBookManager.

# Arguments
- `symbol::String`: Trading pair symbol
- `rest_client::R`: REST API client
- `ws_client::W`: WebSocket market data client

# Keyword Arguments
- `max_depth::Int=5000`: Maximum depth for snapshot (5, 10, 20, 50, 100, 500, 1000, 5000).
  Ignored when `use_snapshot_stream=true` (forced to 20).
- `update_speed::String="100ms"`: Update frequency ("100ms" or "1000ms")
- `on_update::Union{Function,Nothing}=nothing`: Callback function called on each update
- `use_snapshot_stream::Bool=false`: SBE only. When true, subscribe to
  `<symbol>@depth20` push stream (top-20 snapshot every 50ms). Replaces local
  state atomically — no diff sync, no phantom levels, no crossings, no
  REST resync. Recommended when 20 levels of depth is sufficient.

# Callback Signature
If provided, `on_update` will be called as: `on_update(manager::OrderBookManager)`
"""
function OrderBookManager(
    symbol::String,
    rest_client::R,
    ws_client::W;
    max_depth::Int=5000,
    update_speed::String="100ms",
    on_update::F=nothing,
    use_snapshot_stream::Bool=false
) where {R,W,F}
    # Validate parameters
    valid_depths = (5, 10, 20, 50, 100, 500, 1000, 5000)
    if !(max_depth in valid_depths)
        error("max_depth must be one of: $(join(valid_depths, ", "))")
    end

    if !(update_speed in ("100ms", "1000ms"))
        error("update_speed must be '100ms' or '1000ms'")
    end

    if use_snapshot_stream && !(ws_client isa SBEStreamClient)
        error("use_snapshot_stream=true requires an SBEStreamClient (got $(typeof(ws_client)))")
    end

    # Snapshot stream is fixed at top-20 levels by Binance.
    effective_depth = use_snapshot_stream ? 20 : max_depth

    OrderBookManager{R,W,F}(
        symbol,
        rest_client,
        ws_client,
        Ref{Int64}(0),
        OrderedDict{Float64,Float64}(),
        OrderedDict{Float64,Float64}(),
        Ref{Float64}(NaN),
        Ref{Float64}(NaN),
        Vector{Tuple{Float64,Float64}}(),  # sorted_bids
        Vector{Tuple{Float64,Float64}}(),  # sorted_asks
        Ref{Bool}(false),                  # cache_valid
        Ref{Bool}(false),
        Vector{DepthEvent}(),
        Ref{Union{String,Nothing}}(nothing),
        on_update,
        effective_depth,
        update_speed,
        use_snapshot_stream,
        Ref{Int64}(0),
        Ref{Float64}(0.0),
        Ref{Int}(0),                       # consecutive_crosses
        ReentrantLock(),
    )
end

# ============================================================================
# Core Methods
# ============================================================================

"""
    start!(manager::OrderBookManager)

Start the order book synchronization process.

This will:
1. Subscribe to the WebSocket diff depth stream
2. Buffer incoming events
3. Fetch a REST API snapshot
4. Validate and synchronize the order book
5. Begin applying continuous updates
"""
function start!(manager::OrderBookManager)
    if manager.is_initialized[]
        @warn "OrderBookManager already started for $(manager.symbol)"
        return
    end

    if !isnothing(manager.stream_id[])
        @warn "WebSocket stream already active for $(manager.symbol)"
        return
    end

    # Snapshot-stream mode: subscribe to <symbol>@depth20 push stream.
    # Each push is a complete top-20 snapshot — replace local state atomically,
    # skip the buffer/sync/diff path entirely.
    if manager.use_snapshot_stream
        function on_snapshot_event(event)
            try
                handle_snapshot_event!(manager, event)
            catch e
                @error "Error handling snapshot event for $(manager.symbol)" exception = (e, catch_backtrace())
            end
        end

        stream_id = sbe_subscribe_depth20(manager.ws_client, manager.symbol, on_snapshot_event)
        manager.stream_id[] = stream_id
        println("[OrderBookManager] Started for $(manager.symbol) (SBE @depth20 push, top-20 every 50ms)")
        return
    end

    # Diff-stream mode: original buffer + REST snapshot + diff sync.
    function on_depth_event(event)
        try
            handle_depth_event!(manager, event)
        catch e
            @error "Error handling depth event for $(manager.symbol)" exception = (e, catch_backtrace())
            # Try to restart synchronization
            restart_sync!(manager)
        end
    end

    # Subscribe to diff depth stream
    if manager.ws_client isa MarketDataStreamClient
        stream_id = subscribe_diff_depth(
            manager.ws_client,
            manager.symbol,
            on_depth_event;
            update_speed=manager.update_speed
        )
        println("[OrderBookManager] Started for $(manager.symbol) (JSON stream: $stream_id, speed: $(manager.update_speed))")
    elseif manager.ws_client isa SBEStreamClient
        # Binance controls the SBE diff-depth cadence (20ms from
        # 2026-08-04 ~07:00 UTC), so the JSON-only update_speed setting is ignored.
        stream_id = sbe_subscribe_depth(
            manager.ws_client,
            manager.symbol,
            on_depth_event
        )
        println("[OrderBookManager] Started for $(manager.symbol) (SBE stream: $stream_id)")
    else
        error("Unsupported WebSocket client type: $(typeof(manager.ws_client))")
    end

    manager.stream_id[] = stream_id
end

"""
    handle_snapshot_event!(manager, event::DepthSnapshotEvent)

Atomically replace the local order book state with a fresh top-20 snapshot.
Used by the SBE `@depth20` push stream when `use_snapshot_stream=true`.
Bypasses the diff buffer/sync logic — every push is a complete picture.
"""
function handle_snapshot_event!(manager::OrderBookManager, event::DepthSnapshotEvent)
    callback = lock(manager.state_lock) do
        empty!(manager.bids)
        empty!(manager.asks)
        clear_best_prices!(manager)

        @inbounds for level in event.bids
            if level.quantity > 0.0 && !isnan(level.quantity)
                apply_bid_level!(manager, level.price, level.quantity)
            end
        end

        @inbounds for level in event.asks
            if level.quantity > 0.0 && !isnan(level.quantity)
                apply_ask_level!(manager, level.price, level.quantity)
            end
        end

        manager.update_id[] = event.bookUpdateId
        manager.total_updates[] += 1
        manager.last_update_time[] = time()
        manager.cache_valid[] = false
        manager.consecutive_crosses[] = 0
        manager.is_initialized[] = true
        return manager.on_update
    end

    if !isnothing(callback)
        try
            callback(manager)
        catch e
            @error "Error in user callback" exception = e
        end
    end
end

"""
    stop!(manager::OrderBookManager)

Stop the order book synchronization and clean up resources.
"""
function stop!(manager::OrderBookManager)
    if !isnothing(manager.stream_id[])
        try
            if manager.ws_client isa MarketDataStreamClient
                unsubscribe(manager.ws_client, manager.stream_id[])
            elseif manager.ws_client isa SBEStreamClient
                if manager.use_snapshot_stream
                    sbe_unsubscribe_depth20(manager.ws_client, manager.symbol)
                else
                    sbe_unsubscribe_depth(manager.ws_client, manager.symbol)
                end
            end
        catch e
            @warn "Error unsubscribing from stream" exception = e
        end
        manager.stream_id[] = nothing
    end

    lock(manager.state_lock) do
        manager.is_initialized[] = false
        empty!(manager.bids)
        empty!(manager.asks)
        clear_best_prices!(manager)
        empty!(manager.event_buffer)
        manager.update_id[] = 0
        manager.total_updates[] = 0
    end

    println("[OrderBookManager] Stopped for $(manager.symbol)")
end

"""
    is_ready(manager::OrderBookManager)

Check if the order book is initialized and ready for queries.
"""
is_ready(manager::OrderBookManager) = lock(manager.state_lock) do
    manager.is_initialized[]
end

# ============================================================================
# Internal Synchronization Logic
# ============================================================================

# Helper functions for event access (JSON Dict vs SBE Struct)
get_first_update_id(event::AbstractDict) = event["U"]
get_first_update_id(event::DepthDiffEvent) = event.firstBookUpdateId

get_last_update_id(event::AbstractDict) = event["u"]
get_last_update_id(event::DepthDiffEvent) = event.lastBookUpdateId

get_bids_data(event::AbstractDict) = event["b"]
get_bids_data(event::DepthDiffEvent) = event.bids

get_asks_data(event::AbstractDict) = event["a"]
get_asks_data(event::DepthDiffEvent) = event.asks

# Helper to parse price/qty
parse_price_qty(item::AbstractVector) = (parse(Float64, item[1]), parse(Float64, item[2]))
parse_price_qty(item::PriceLevel) = (item.price, item.quantity)

function clear_best_prices!(manager::OrderBookManager)
    manager.best_bid_price[] = NaN
    manager.best_ask_price[] = NaN
    return nothing
end

function recompute_best_bid!(manager::OrderBookManager)
    best = NaN
    @inbounds for price in keys(manager.bids)
        if isnan(best) || price > best
            best = price
        end
    end
    manager.best_bid_price[] = best
    return best
end

function recompute_best_ask!(manager::OrderBookManager)
    best = NaN
    @inbounds for price in keys(manager.asks)
        if isnan(best) || price < best
            best = price
        end
    end
    manager.best_ask_price[] = best
    return best
end

function apply_bid_level!(manager::OrderBookManager, price::Float64, quantity::Float64)
    if quantity == 0.0 || isnan(quantity)
        had_level = haskey(manager.bids, price)
        delete!(manager.bids, price)
        if had_level && price == manager.best_bid_price[]
            recompute_best_bid!(manager)
        end
    else
        manager.bids[price] = quantity
        best = manager.best_bid_price[]
        if isnan(best) || price > best
            manager.best_bid_price[] = price
        end
    end
    return nothing
end

function apply_ask_level!(manager::OrderBookManager, price::Float64, quantity::Float64)
    if quantity == 0.0 || isnan(quantity)
        had_level = haskey(manager.asks, price)
        delete!(manager.asks, price)
        if had_level && price == manager.best_ask_price[]
            recompute_best_ask!(manager)
        end
    else
        manager.asks[price] = quantity
        best = manager.best_ask_price[]
        if isnan(best) || price < best
            manager.best_ask_price[] = price
        end
    end
    return nothing
end

"""
    handle_depth_event!(manager, event)

Handle a depth update event from the WebSocket stream.

Implements the corrected order book synchronization algorithm (2025-11-12).
"""
function handle_depth_event!(manager::OrderBookManager, event)
    initialized, should_initialize = lock(manager.state_lock) do
        if manager.is_initialized[]
            return true, false
        end
        push!(manager.event_buffer, event)
        return false, length(manager.event_buffer) >= 3
    end

    if !initialized
        if should_initialize
            try
                initialize_from_snapshot!(manager)
            catch e
                @error "Failed to initialize order book" symbol = manager.symbol exception = e
                lock(manager.state_lock) do
                    empty!(manager.event_buffer)
                end
            end
        end
    else
        # Apply update to initialized order book
        status = apply_update!(manager, event)

        if status == :restart
            @warn "Missed events detected, restarting synchronization" symbol = manager.symbol
            restart_sync!(manager)
        end
    end
end

"""
    initialize_from_snapshot!(manager)

Initialize the order book from a REST API snapshot.

Follows Binance's corrected algorithm (2025-11-12):
1. Note the U of the first buffered event
2. Fetch depth snapshot
3. Validate snapshot's lastUpdateId >= first event's U
4. Discard buffered events where u <= snapshot's lastUpdateId
5. Verify first remaining event's [U; u] range contains snapshot's lastUpdateId
6. Apply all buffered events
"""
function initialize_from_snapshot!(manager::OrderBookManager)
    first_event_U = lock(manager.state_lock) do
        isempty(manager.event_buffer) && error("No buffered events available")
        return get_first_update_id(first(manager.event_buffer))
    end

    snapshot = get_orderbook(manager.rest_client, manager.symbol; limit=manager.max_depth)
    snapshot_last_update_id = snapshot["lastUpdateId"]

    # Step 3: Validate snapshot freshness
    # CORRECTED LOGIC (2025-11-12): If snapshot is strictly less than first event U, retry
    if snapshot_last_update_id < first_event_U
        error("Snapshot too old (lastUpdateId: $snapshot_last_update_id < first event U: $first_event_U)")
    end

    callback, bid_count, ask_count, update_id, discarded_count = lock(manager.state_lock) do
        manager.update_id[] = snapshot_last_update_id
        empty!(manager.bids)
        empty!(manager.asks)
        clear_best_prices!(manager)

        for bid in snapshot["bids"]
            price, quantity = parse_price_qty(bid)
            apply_bid_level!(manager, price, quantity)
        end

        for ask in snapshot["asks"]
            price, quantity = parse_price_qty(ask)
            apply_ask_level!(manager, price, quantity)
        end

        original_buffer_size = length(manager.event_buffer)
        filter!(event -> get_last_update_id(event) > snapshot_last_update_id, manager.event_buffer)
        discarded_count = original_buffer_size - length(manager.event_buffer)

        if !isempty(manager.event_buffer)
            first_remaining = first(manager.event_buffer)
            U = get_first_update_id(first_remaining)
            u = get_last_update_id(first_remaining)

            if snapshot_last_update_id < U || snapshot_last_update_id > u
                error("Invalid state: snapshot lastUpdateId ($snapshot_last_update_id) not in first event range [$U; $u]")
            end

            for event in manager.event_buffer
                status = _apply_update_locked!(manager, event; skip_validation=true)
                status == :restart && error("Buffered updates produced a crossed order book")
            end
            empty!(manager.event_buffer)
        end

        manager.is_initialized[] = true
        manager.last_update_time[] = time()
        callback = manager.consecutive_crosses[] == 0 ? manager.on_update : nothing
        return callback, length(manager.bids), length(manager.asks), manager.update_id[], discarded_count
    end

    if !isnothing(callback)
        try
            callback(manager)
        catch e
            @error "Error in user callback" exception = (e, catch_backtrace())
        end
    end

    @info "Order book initialized" symbol=manager.symbol bids=bid_count asks=ask_count update_id discarded_events=discarded_count
end

"""
    apply_update!(manager, event; skip_validation=false)

Apply a depth update event to the order book.

Returns:
- `:applied` - Event was successfully applied
- `:ignored` - Event was outdated and ignored
- `:restart` - Events were missed, need to restart synchronization
"""
function apply_update!(manager::OrderBookManager, event; skip_validation::Bool=false)
    status, callback = lock(manager.state_lock) do
        status = _apply_update_locked!(manager, event; skip_validation=skip_validation)
        callback = status == :applied && manager.consecutive_crosses[] == 0 ? manager.on_update : nothing
        return status, callback
    end

    if !isnothing(callback)
        try
            callback(manager)
        catch e
            @error "Error in user callback" exception = (e, catch_backtrace())
        end
    end
    return status
end

function _apply_update_locked!(manager::OrderBookManager, event; skip_validation::Bool=false)
    event_U = get_first_update_id(event)  # First update ID
    event_u = get_last_update_id(event)   # Last update ID

    if !skip_validation
        # Check if event is outdated
        if event_u <= manager.update_id[]
            return :ignored
        end

        # Check if we missed events
        if event_U > manager.update_id[] + 1
            return :restart
        end
    end

    # Apply bid updates
    # NULL-qty (decoded as NaN by SBEDecoder) signals level deletion per the
    # 2025-12-09 schema change that made MDEntrySize optional. Treat both
    # qty == 0.0 and NaN as deletes to avoid phantom levels accumulating.
    bids_data = get_bids_data(event)
    @inbounds for bid in bids_data
        price, quantity = parse_price_qty(bid)
        apply_bid_level!(manager, price, quantity)
    end

    # Apply ask updates
    asks_data = get_asks_data(event)
    @inbounds for ask in asks_data
        price, quantity = parse_price_qty(ask)
        apply_ask_level!(manager, price, quantity)
    end

    # Update state
    manager.update_id[] = event_u
    manager.total_updates[] += 1
    manager.last_update_time[] = time()
    manager.cache_valid[] = false  # Invalidate cache

    # Health check: a healthy book has best_bid < best_ask. SBE diffs may
    # arrive split across messages, so a single-event cross is usually
    # transient and self-heals on the next event. We suppress the user
    # callback while crossed (so the strategy doesn't trade on bad data),
    # and only warn / restart if the cross persists across many events.
    max_bid = manager.best_bid_price[]
    min_ask = manager.best_ask_price[]
    if !isnan(max_bid) && !isnan(min_ask)
        if max_bid >= min_ask
            manager.consecutive_crosses[] += 1
            # Persistent cross: warn periodically and request resync.
            if manager.consecutive_crosses[] == 20
                @warn "Order book persistently crossed; restarting sync" symbol = manager.symbol max_bid min_ask consecutive = manager.consecutive_crosses[]
                return :restart
            end
        else
            manager.consecutive_crosses[] = 0
        end
    else
        manager.consecutive_crosses[] = 0
    end

    return :applied
end

"""
    restart_sync!(manager)

Restart the order book synchronization from scratch.
"""
function restart_sync!(manager::OrderBookManager)
    @warn "Restarting order book synchronization" symbol = manager.symbol

    lock(manager.state_lock) do
        manager.is_initialized[] = false
        manager.update_id[] = 0
        empty!(manager.bids)
        empty!(manager.asks)
        clear_best_prices!(manager)
        empty!(manager.event_buffer)
        empty!(manager.sorted_bids)
        empty!(manager.sorted_asks)
        manager.cache_valid[] = false
        manager.consecutive_crosses[] = 0
    end

    # Events will start buffering again automatically
end

# ============================================================================
# Cache Management
# ============================================================================

"""
    rebuild_cache!(manager::OrderBookManager)

Rebuild the sorted cache arrays. Called lazily when cache is invalid.
"""
function rebuild_cache!(manager::OrderBookManager)
    return lock(manager.state_lock) do
        _rebuild_cache_locked!(manager)
    end
end

function _rebuild_cache_locked!(manager::OrderBookManager)
    if manager.cache_valid[]
        return
    end

    # Rebuild sorted bids (descending by price)
    resize!(manager.sorted_bids, length(manager.bids))
    idx = 1
    @inbounds for (price, qty) in manager.bids
        manager.sorted_bids[idx] = (price, qty)
        idx += 1
    end
    sort!(manager.sorted_bids, by=first, rev=true)

    # Rebuild sorted asks (ascending by price)
    resize!(manager.sorted_asks, length(manager.asks))
    idx = 1
    @inbounds for (price, qty) in manager.asks
        manager.sorted_asks[idx] = (price, qty)
        idx += 1
    end
    sort!(manager.sorted_asks, by=first)

    manager.cache_valid[] = true
end

# ============================================================================
# Query Methods
# ============================================================================

"""
    get_best_bid(manager::OrderBookManager)

Get the best (highest) bid price and quantity.

Returns `nothing` if order book is not ready or has no bids.
Returns `(price=Float64, quantity=Float64)` otherwise.
"""
function get_best_bid(manager::OrderBookManager)
    return lock(manager.state_lock) do
        if !manager.is_initialized[]
            return nothing
        end

        price = manager.best_bid_price[]
        if isnan(price)
            return nothing
        end

        quantity = get(manager.bids, price, NaN)
        if isnan(quantity)
            price = recompute_best_bid!(manager)
            isnan(price) && return nothing
            quantity = manager.bids[price]
        end

        return (price=price, quantity=quantity)
    end
end

"""
    get_best_ask(manager::OrderBookManager)

Get the best (lowest) ask price and quantity.

Returns `nothing` if order book is not ready or has no asks.
Returns `(price=Float64, quantity=Float64)` otherwise.
"""
function get_best_ask(manager::OrderBookManager)
    return lock(manager.state_lock) do
        if !manager.is_initialized[]
            return nothing
        end

        price = manager.best_ask_price[]
        if isnan(price)
            return nothing
        end

        quantity = get(manager.asks, price, NaN)
        if isnan(quantity)
            price = recompute_best_ask!(manager)
            isnan(price) && return nothing
            quantity = manager.asks[price]
        end

        return (price=price, quantity=quantity)
    end
end

"""
    get_spread(manager::OrderBookManager)

Calculate the bid-ask spread.

Returns `nothing` if order book is not ready or missing data.
"""
function get_spread(manager::OrderBookManager)
    return lock(manager.state_lock) do
        best_bid = get_best_bid(manager)
        best_ask = get_best_ask(manager)

        if isnothing(best_bid) || isnothing(best_ask)
            return nothing
        end

        return best_ask.price - best_bid.price
    end
end

"""
    get_mid_price(manager::OrderBookManager)

Calculate the mid price (average of best bid and best ask).

Returns `nothing` if order book is not ready or missing data.
"""
function get_mid_price(manager::OrderBookManager)
    return lock(manager.state_lock) do
        best_bid = get_best_bid(manager)
        best_ask = get_best_ask(manager)

        if isnothing(best_bid) || isnothing(best_ask)
            return nothing
        end

        return (best_bid.price + best_ask.price) / 2.0
    end
end

"""
    get_bids(manager::OrderBookManager, n::Int=10)

Get the top N bid levels.

Returns a vector of `PriceQuantity`, sorted by price descending (best first).
"""
function get_bids(manager::OrderBookManager, n::Int=10)
    n >= 0 || throw(ArgumentError("n must be non-negative"))
    return lock(manager.state_lock) do
        if !manager.is_initialized[]
            return PriceQuantity[]
        end

        _rebuild_cache_locked!(manager)

        count = min(n, length(manager.sorted_bids))
        result = Vector{PriceQuantity}(undef, count)

        @inbounds for i in 1:count
            price, quantity = manager.sorted_bids[i]
            result[i] = PriceQuantity(price, quantity)
        end

        return result
    end
end

"""
    get_asks(manager::OrderBookManager, n::Int=10)

Get the top N ask levels.

Returns a vector of `PriceQuantity`, sorted by price ascending (best first).
"""
function get_asks(manager::OrderBookManager, n::Int=10)
    n >= 0 || throw(ArgumentError("n must be non-negative"))
    return lock(manager.state_lock) do
        if !manager.is_initialized[]
            return PriceQuantity[]
        end

        _rebuild_cache_locked!(manager)

        count = min(n, length(manager.sorted_asks))
        result = Vector{PriceQuantity}(undef, count)

        @inbounds for i in 1:count
            price, quantity = manager.sorted_asks[i]
            result[i] = PriceQuantity(price, quantity)
        end

        return result
    end
end

"""
    get_orderbook_snapshot(manager::OrderBookManager; max_levels::Int=100)

Get an immutable snapshot of the current order book.

# Arguments
- `max_levels::Int=100`: Maximum number of levels to include on each side

Returns an `OrderBookSnapshot` object.
"""
function get_orderbook_snapshot(manager::OrderBookManager; max_levels::Int=100)
    max_levels >= 0 || throw(ArgumentError("max_levels must be non-negative"))
    return lock(manager.state_lock) do
        if !manager.is_initialized[]
            error("Order book not initialized")
        end

        bids = get_bids(manager, max_levels)
        asks = get_asks(manager, max_levels)

        return OrderBookSnapshot(
            manager.symbol,
            manager.update_id[],
            bids,
            asks,
            manager.last_update_time[],
        )
    end
end

# ============================================================================
# Analysis Methods
# ============================================================================

"""
    calculate_vwap(manager::OrderBookManager, size::Float64, side::Symbol)

Calculate Volume-Weighted Average Price (VWAP) for a given order size.

# Arguments
- `size::Float64`: Order size (in base asset quantity)
- `side::Symbol`: `:buy` or `:sell`

Returns `nothing` if insufficient liquidity or not ready.
Returns `(vwap=Float64, total_cost=Float64)` otherwise.
"""
function calculate_vwap(manager::OrderBookManager, size::Float64, side::Symbol)
    size > 0 || throw(ArgumentError("size must be positive"))
    side in (:buy, :sell) || throw(ArgumentError("side must be :buy or :sell"))
    return lock(manager.state_lock) do
        if !manager.is_initialized[]
            return nothing
        end

        _rebuild_cache_locked!(manager)
        sorted_levels = side == :buy ? manager.sorted_asks : manager.sorted_bids

        remaining = size
        total_cost = 0.0

        @inbounds for (price, quantity) in sorted_levels
            if remaining <= 0
                break
            end

            fill = min(remaining, quantity)
            total_cost += fill * price
            remaining -= fill
        end

        if remaining > 0
            return nothing
        end

        vwap = total_cost / size
        return (vwap=vwap, total_cost=total_cost)
    end
end

"""
    calculate_depth_imbalance(manager::OrderBookManager; levels::Int=5)

Calculate order book depth imbalance.

Returns a value between -1.0 and 1.0:
- Positive values indicate more bid volume (bullish)
- Negative values indicate more ask volume (bearish)
- 0.0 indicates balanced order book

Returns `nothing` if not ready.
"""
function calculate_depth_imbalance(manager::OrderBookManager; levels::Int=5)
    levels >= 0 || throw(ArgumentError("levels must be non-negative"))
    return lock(manager.state_lock) do
        if !manager.is_initialized[]
            return nothing
        end

        _rebuild_cache_locked!(manager)

        bid_volume = 0.0
        count = min(levels, length(manager.sorted_bids))
        @inbounds @simd for i in 1:count
            _, qty = manager.sorted_bids[i]
            bid_volume += qty
        end

        ask_volume = 0.0
        count = min(levels, length(manager.sorted_asks))
        @inbounds @simd for i in 1:count
            _, qty = manager.sorted_asks[i]
            ask_volume += qty
        end

        total = bid_volume + ask_volume
        if total == 0.0
            return 0.0
        end

        return (bid_volume - ask_volume) / total
    end
end

end # module OrderBookManagers
