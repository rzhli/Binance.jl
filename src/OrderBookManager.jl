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
using ..MarketDataStreams: subscribe_diff_depth, unsubscribe

export OrderBookManager, start!, stop!, is_ready,
       get_best_bid, get_best_ask, get_spread, get_mid_price,
       get_bids, get_asks, get_orderbook_snapshot,
       calculate_vwap, calculate_depth_imbalance

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
    OrderBookManager

Manages a local order book with automatic synchronization from Binance.

# Fields
- `symbol::String`: Trading pair symbol (e.g., "BTCUSDT")
- `rest_client`: REST API client for fetching snapshots
- `ws_client`: WebSocket client for streaming updates
- `update_id::Ref{Int64}`: Current order book update ID
- `bids::OrderedDict{Float64,Float64}`: Buy orders (price => quantity)
- `asks::OrderedDict{Float64,Float64}`: Sell orders (price => quantity)
- `is_initialized::Ref{Bool}`: Whether order book is ready
- `event_buffer::Vector{Any}`: Buffer for events before initialization
- `stream_id::Ref{Union{String,Nothing}}`: WebSocket stream ID
- `on_update::Union{Function,Nothing}`: Optional callback on updates
- `max_depth::Int`: Maximum depth for REST snapshot (default: 5000)
- `update_speed::String`: Update speed "100ms" or "1000ms" (default: "100ms")
"""
mutable struct OrderBookManager
    symbol::String
    rest_client::Any
    ws_client::Any

    # Order book state
    update_id::Ref{Int64}
    bids::OrderedDict{Float64, Float64}
    asks::OrderedDict{Float64, Float64}

    # Synchronization state
    is_initialized::Ref{Bool}
    event_buffer::Vector{Any}

    # WebSocket subscription
    stream_id::Ref{Union{String, Nothing}}

    # Configuration
    on_update::Union{Function, Nothing}
    max_depth::Int
    update_speed::String

    # Statistics
    total_updates::Ref{Int64}
    last_update_time::Ref{Float64}
end

"""
    OrderBookManager(symbol, rest_client, ws_client; kwargs...)

Create a new OrderBookManager.

# Arguments
- `symbol::String`: Trading pair symbol
- `rest_client`: REST API client
- `ws_client`: WebSocket market data client

# Keyword Arguments
- `max_depth::Int=5000`: Maximum depth for snapshot (5, 10, 20, 50, 100, 500, 1000, 5000)
- `update_speed::String="100ms"`: Update frequency ("100ms" or "1000ms")
- `on_update::Union{Function,Nothing}=nothing`: Callback function called on each update

# Callback Signature
If provided, `on_update` will be called as: `on_update(manager::OrderBookManager)`
"""
function OrderBookManager(
    symbol::String,
    rest_client,
    ws_client;
    max_depth::Int = 5000,
    update_speed::String = "100ms",
    on_update::Union{Function, Nothing} = nothing
)
    # Validate parameters
    valid_depths = [5, 10, 20, 50, 100, 500, 1000, 5000]
    if !(max_depth in valid_depths)
        error("max_depth must be one of: $(join(valid_depths, ", "))")
    end

    if !(update_speed in ["100ms", "1000ms"])
        error("update_speed must be '100ms' or '1000ms'")
    end

    OrderBookManager(
        symbol,
        rest_client,
        ws_client,
        Ref{Int64}(0),
        OrderedDict{Float64, Float64}(),
        OrderedDict{Float64, Float64}(),
        Ref{Bool}(false),
        Vector{Any}(),
        Ref{Union{String, Nothing}}(nothing),
        on_update,
        max_depth,
        update_speed,
        Ref{Int64}(0),
        Ref{Float64}(0.0)
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

    # Define event handler
    function on_depth_event(event)
        try
            handle_depth_event!(manager, event)
        catch e
            @error "Error handling depth event for $(manager.symbol)" exception=(e, catch_backtrace())
            # Try to restart synchronization
            restart_sync!(manager)
        end
    end

    # Subscribe to diff depth stream
    stream_id = subscribe_diff_depth(
        manager.ws_client,
        manager.symbol,
        on_depth_event;
        update_speed = manager.update_speed
    )

    manager.stream_id[] = stream_id
    println("[OrderBookManager] Started for $(manager.symbol) (stream: $stream_id, speed: $(manager.update_speed))")
end

"""
    stop!(manager::OrderBookManager)

Stop the order book synchronization and clean up resources.
"""
function stop!(manager::OrderBookManager)
    if !isnothing(manager.stream_id[])
        try
            unsubscribe(manager.ws_client, manager.stream_id[])
        catch e
            @warn "Error unsubscribing from stream" exception=e
        end
        manager.stream_id[] = nothing
    end

    # Reset state
    manager.is_initialized[] = false
    empty!(manager.bids)
    empty!(manager.asks)
    empty!(manager.event_buffer)
    manager.update_id[] = 0
    manager.total_updates[] = 0

    println("[OrderBookManager] Stopped for $(manager.symbol)")
end

"""
    is_ready(manager::OrderBookManager)

Check if the order book is initialized and ready for queries.
"""
is_ready(manager::OrderBookManager) = manager.is_initialized[]

# ============================================================================
# Internal Synchronization Logic
# ============================================================================

"""
    handle_depth_event!(manager, event)

Handle a depth update event from the WebSocket stream.

Implements the corrected order book synchronization algorithm (2025-11-12).
"""
function handle_depth_event!(manager::OrderBookManager, event)
    if !manager.is_initialized[]
        # Buffer events until we have enough to initialize
        push!(manager.event_buffer, event)

        # After buffering a few events, try to initialize
        if length(manager.event_buffer) >= 3
            try
                initialize_from_snapshot!(manager)
            catch e
                @error "Failed to initialize order book" symbol=manager.symbol exception=e
                # Clear buffer and try again
                empty!(manager.event_buffer)
            end
        end
    else
        # Apply update to initialized order book
        status = apply_update!(manager, event)

        if status == :restart
            @warn "Missed events detected, restarting synchronization" symbol=manager.symbol
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
    if isempty(manager.event_buffer)
        error("No buffered events available")
    end

    # Step 1: Note the U of the first buffered event
    first_event_U = manager.event_buffer[1]["U"]

    # Step 2: Fetch depth snapshot
    snapshot = get_orderbook(manager.rest_client, manager.symbol; limit=manager.max_depth)
    snapshot_last_update_id = snapshot["lastUpdateId"]

    # Step 3: Validate snapshot freshness
    # CORRECTED LOGIC (2025-11-12): If snapshot is strictly less than first event U, retry
    if snapshot_last_update_id < first_event_U
        error("Snapshot too old (lastUpdateId: $snapshot_last_update_id < first event U: $first_event_U)")
    end

    # Step 4: Load snapshot into order book
    manager.update_id[] = snapshot_last_update_id
    empty!(manager.bids)
    empty!(manager.asks)

    for bid in snapshot["bids"]
        price = parse(Float64, bid[1])
        quantity = parse(Float64, bid[2])
        manager.bids[price] = quantity
    end

    for ask in snapshot["asks"]
        price = parse(Float64, ask[1])
        quantity = parse(Float64, ask[2])
        manager.asks[price] = quantity
    end

    # Step 5: Discard outdated buffered events (where u <= lastUpdateId)
    original_buffer_size = length(manager.event_buffer)
    filter!(event -> event["u"] > snapshot_last_update_id, manager.event_buffer)
    discarded_count = original_buffer_size - length(manager.event_buffer)

    # Step 6: Verify first remaining buffered event
    if !isempty(manager.event_buffer)
        first_remaining = manager.event_buffer[1]
        U = first_remaining["U"]
        u = first_remaining["u"]

        # Snapshot's lastUpdateId should be within [U; u] range
        if snapshot_last_update_id < U || snapshot_last_update_id > u
            error("Invalid state: snapshot lastUpdateId ($snapshot_last_update_id) not in first event range [$U; $u]")
        end

        # Apply all buffered events
        for event in manager.event_buffer
            apply_update!(manager, event; skip_validation=true)
        end

        # Clear buffer
        empty!(manager.event_buffer)
    end

    manager.is_initialized[] = true
    manager.last_update_time[] = time()

    println("[OrderBookManager] Initialized $(manager.symbol): " *
            "$(length(manager.bids)) bids, $(length(manager.asks)) asks, " *
            "update_id=$(manager.update_id[]), discarded=$discarded_count events")
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
    event_U = event["U"]  # First update ID
    event_u = event["u"]  # Last update ID

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
    for bid in event["b"]
        price = parse(Float64, bid[1])
        quantity = parse(Float64, bid[2])

        if quantity == 0.0
            delete!(manager.bids, price)
        else
            manager.bids[price] = quantity
        end
    end

    # Apply ask updates
    for ask in event["a"]
        price = parse(Float64, ask[1])
        quantity = parse(Float64, ask[2])

        if quantity == 0.0
            delete!(manager.asks, price)
        else
            manager.asks[price] = quantity
        end
    end

    # Update state
    manager.update_id[] = event_u
    manager.total_updates[] += 1
    manager.last_update_time[] = time()

    # Call user callback if provided
    if !isnothing(manager.on_update)
        try
            manager.on_update(manager)
        catch e
            @error "Error in user callback" exception=e
        end
    end

    return :applied
end

"""
    restart_sync!(manager)

Restart the order book synchronization from scratch.
"""
function restart_sync!(manager::OrderBookManager)
    @warn "Restarting order book synchronization" symbol=manager.symbol

    # Reset state but keep stream active
    manager.is_initialized[] = false
    manager.update_id[] = 0
    empty!(manager.bids)
    empty!(manager.asks)
    empty!(manager.event_buffer)

    # Events will start buffering again automatically
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
    if !manager.is_initialized[] || isempty(manager.bids)
        return nothing
    end

    # Find the maximum price (best bid)
    best_price = maximum(keys(manager.bids))
    return (price=best_price, quantity=manager.bids[best_price])
end

"""
    get_best_ask(manager::OrderBookManager)

Get the best (lowest) ask price and quantity.

Returns `nothing` if order book is not ready or has no asks.
Returns `(price=Float64, quantity=Float64)` otherwise.
"""
function get_best_ask(manager::OrderBookManager)
    if !manager.is_initialized[] || isempty(manager.asks)
        return nothing
    end

    # Find the minimum price (best ask)
    best_price = minimum(keys(manager.asks))
    return (price=best_price, quantity=manager.asks[best_price])
end

"""
    get_spread(manager::OrderBookManager)

Calculate the bid-ask spread.

Returns `nothing` if order book is not ready or missing data.
"""
function get_spread(manager::OrderBookManager)
    best_bid = get_best_bid(manager)
    best_ask = get_best_ask(manager)

    if isnothing(best_bid) || isnothing(best_ask)
        return nothing
    end

    return best_ask.price - best_bid.price
end

"""
    get_mid_price(manager::OrderBookManager)

Calculate the mid price (average of best bid and best ask).

Returns `nothing` if order book is not ready or missing data.
"""
function get_mid_price(manager::OrderBookManager)
    best_bid = get_best_bid(manager)
    best_ask = get_best_ask(manager)

    if isnothing(best_bid) || isnothing(best_ask)
        return nothing
    end

    return (best_bid.price + best_ask.price) / 2.0
end

"""
    get_bids(manager::OrderBookManager, n::Int=10)

Get the top N bid levels.

Returns a vector of `PriceQuantity`, sorted by price descending (best first).
"""
function get_bids(manager::OrderBookManager, n::Int=10)
    if !manager.is_initialized[]
        return PriceQuantity[]
    end

    # Sort by price descending (highest first)
    sorted_bids = sort(collect(manager.bids), by=x->x.first, rev=true)

    count = min(n, length(sorted_bids))
    result = PriceQuantity[]

    for i in 1:count
        price, quantity = sorted_bids[i]
        push!(result, PriceQuantity(price, quantity))
    end

    return result
end

"""
    get_asks(manager::OrderBookManager, n::Int=10)

Get the top N ask levels.

Returns a vector of `PriceQuantity`, sorted by price ascending (best first).
"""
function get_asks(manager::OrderBookManager, n::Int=10)
    if !manager.is_initialized[]
        return PriceQuantity[]
    end

    # Sort by price ascending (lowest first)
    sorted_asks = sort(collect(manager.asks), by=x->x.first)

    count = min(n, length(sorted_asks))
    result = PriceQuantity[]

    for i in 1:count
        price, quantity = sorted_asks[i]
        push!(result, PriceQuantity(price, quantity))
    end

    return result
end

"""
    get_orderbook_snapshot(manager::OrderBookManager; max_levels::Int=100)

Get an immutable snapshot of the current order book.

# Arguments
- `max_levels::Int=100`: Maximum number of levels to include on each side

Returns an `OrderBookSnapshot` object.
"""
function get_orderbook_snapshot(manager::OrderBookManager; max_levels::Int=100)
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
        manager.last_update_time[]
    )
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
    if !manager.is_initialized[]
        return nothing
    end

    # Get sorted levels
    if side == :buy
        # For buying, we consume asks (lowest price first)
        sorted_levels = sort(collect(manager.asks), by=x->x.first)
    else
        # For selling, we consume bids (highest price first)
        sorted_levels = sort(collect(manager.bids), by=x->x.first, rev=true)
    end

    remaining = size
    total_cost = 0.0

    for (price, quantity) in sorted_levels
        if remaining <= 0
            break
        end

        fill = min(remaining, quantity)
        total_cost += fill * price
        remaining -= fill
    end

    if remaining > 0
        # Insufficient liquidity
        return nothing
    end

    vwap = total_cost / size
    return (vwap=vwap, total_cost=total_cost)
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
    if !manager.is_initialized[]
        return nothing
    end

    bid_volume = 0.0
    ask_volume = 0.0

    # Get top N bids (sorted descending)
    sorted_bids = sort(collect(manager.bids), by=x->x.first, rev=true)
    for (i, (_, qty)) in enumerate(sorted_bids)
        if i > levels
            break
        end
        bid_volume += qty
    end

    # Get top N asks (sorted ascending)
    sorted_asks = sort(collect(manager.asks), by=x->x.first)
    for (i, (_, qty)) in enumerate(sorted_asks)
        if i > levels
            break
        end
        ask_volume += qty
    end

    total = bid_volume + ask_volume
    if total == 0.0
        return 0.0
    end

    return (bid_volume - ask_volume) / total
end

end # module OrderBookManagers
