module Filters

    using ..Types

    export validate_order, validate_symbol, validate_interval, validate_order_type,
           validate_side, validate_time_in_force

    # --- Generic Validation Dispatch ---

    """
        validate_order(params::Dict, filters::Vector{AbstractFilter})

    Iterates through all symbol filters and applies the appropriate validation logic.
    """
    function validate_order(params::Dict, filters::Vector{AbstractFilter})
        for filter in filters
            validate_filter(params, filter)
        end
        return true
    end

    # --- Filter-Specific Validation Functions ---

    function validate_filter(params::Dict, filter::AbstractFilter)
        # Generic fallback for unimplemented filters
        return true
    end

    """
        validate_filter(params::Dict, filter::PriceFilter)

    Validates an order's price against the PRICE_FILTER rules.
    """
    function validate_filter(params::Dict, filter::PriceFilter)
        price = get(params, "price", nothing)
        !isnothing(price) || return true # Only validate if price is present

        price_val = parse(Float64, string(price))
        min_price = parse(Float64, filter.minPrice)
        max_price = parse(Float64, filter.maxPrice)
        tick_size = parse(Float64, filter.tickSize)

        if min_price > 0 && price_val < min_price
            throw(ArgumentError("Price ($price_val) is below the minimum allowed price ($min_price)."))
        end

        if max_price > 0 && price_val > max_price
            throw(ArgumentError("Price ($price_val) is above the maximum allowed price ($max_price)."))
        end

        if tick_size > 0
            # Check if (price - minPrice) is a multiple of tickSize
            # Use rem for floating point modulo, handle potential precision issues with a small epsilon
            if rem(price_val - min_price, tick_size) > 1e-9
                throw(ArgumentError("Price ($price_val) does not meet the tick size ($tick_size) requirement."))
            end
        end

        return true
    end

    """
        validate_filter(params::Dict, filter::LotSizeFilter)

    Validates an order's quantity against the LOT_SIZE filter rules.
    """
    function validate_filter(params::Dict, filter::LotSizeFilter)
        quantity = get(params, "quantity", nothing)
        !isnothing(quantity) || return true # Only validate if quantity is present

        qty_val = parse(Float64, string(quantity))
        min_qty = parse(Float64, filter.minQty)
        max_qty = parse(Float64, filter.maxQty)
        step_size = parse(Float64, filter.stepSize)

        if qty_val < min_qty
            throw(ArgumentError("Quantity ($qty_val) is below the minimum allowed quantity ($min_qty)."))
        end

        if qty_val > max_qty
            throw(ArgumentError("Quantity ($qty_val) is above the maximum allowed quantity ($max_qty)."))
        end

        if step_size > 0
            # Check if (quantity - minQty) is a multiple of stepSize
            if rem(qty_val - min_qty, step_size) > 1e-9
                throw(ArgumentError("Quantity ($qty_val) does not meet the step size ($step_size) requirement."))
            end
        end

        return true
    end

    """
        validate_filter(params::Dict, filter::MinNotionalFilter)

    Validates an order's notional value against the MIN_NOTIONAL filter.
    """
    function validate_filter(params::Dict, filter::MinNotionalFilter)
        price = get(params, "price", nothing)
        quantity = get(params, "quantity", nothing)

        # This filter applies to MARKET orders as well, but we don't have avg price here.
        # For now, we only validate for orders with a specified price.
        (isnothing(price) || isnothing(quantity)) && return true

        price_val = parse(Float64, string(price))
        qty_val = parse(Float64, string(quantity))
        min_notional = parse(Float64, filter.minNotional)

        notional_value = price_val * qty_val
        if notional_value < min_notional
            throw(ArgumentError("Notional value ($notional_value) is below the minimum required ($min_notional)."))
        end

        return true
    end

    # --- Utility Functions (from former Utils.jl) ---

    function validate_symbol(symbol::String)
        if isempty(symbol)
            throw(ArgumentError("Symbol cannot be empty"))
        end
        return uppercase(symbol)
    end

    function validate_interval(interval::String)
        valid_intervals = ["1s", "1m", "3m", "5m", "15m", "30m", "1h", "2h", "4h", "6h", "8h", "12h", "1d", "3d", "1w", "1M"]
        if !(interval in valid_intervals)
            throw(ArgumentError("Invalid interval. Valid intervals: $(join(valid_intervals, ", "))"))
        end
        return interval
    end

    function validate_order_type(order_type::String)
        valid_types = ["LIMIT", "MARKET", "STOP_LOSS", "STOP_LOSS_LIMIT", "TAKE_PROFIT", "TAKE_PROFIT_LIMIT", "LIMIT_MAKER"]
        if !(order_type in valid_types)
            throw(ArgumentError("Invalid order type. Valid types: $(join(valid_types, ", "))"))
        end
        return order_type
    end

    function validate_side(side::String)
        valid_sides = ["BUY", "SELL"]
        if !(side in valid_sides)
            throw(ArgumentError("Invalid side. Valid sides: $(join(valid_sides, ", "))"))
        end
        return side
    end

    function validate_time_in_force(tif::String)
        valid_tifs = ["GTC", "IOC", "FOK"]
        if !(tif in valid_tifs)
            throw(ArgumentError("Invalid time in force. Valid values: $(join(valid_tifs, ", "))"))
        end
        return tif
    end

end # module Filters
