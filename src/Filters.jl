module Filters

    using ..Types

    export validate_order, validate_symbol, validate_interval, validate_order_type,
           validate_side, validate_time_in_force, ParsedPriceFilter, ParsedLotSizeFilter,
           ParsedNotionalFilter, parse_filter

    # --- Parsed Filter Structs (pre-parsed Float64 values for performance) ---

    """
    Parsed version of PriceFilter with Float64 values for fast validation.
    """
    struct ParsedPriceFilter
        min_price::Float64
        max_price::Float64
        tick_size::Float64
        tick_precision::Int
    end

    """
    Parsed version of LotSizeFilter with Float64 values for fast validation.
    """
    struct ParsedLotSizeFilter
        min_qty::Float64
        max_qty::Float64
        step_size::Float64
    end

    """
    Parsed version of NotionalFilter with Float64 values for fast validation.
    """
    struct ParsedNotionalFilter
        min_notional::Float64
        max_notional::Float64
    end

    # --- Filter Parsing Functions ---

    """
    Parse a PriceFilter into a ParsedPriceFilter with Float64 values.
    Call this once when loading symbol info, then reuse for all validations.
    """
    function parse_filter(filter::PriceFilter)
        min_price = parse(Float64, filter.minPrice)
        max_price = parse(Float64, filter.maxPrice)
        tick_size = parse(Float64, filter.tickSize)
        tick_precision = tick_size > 0 ? max(0, -Int(floor(log10(tick_size)))) : 0
        return ParsedPriceFilter(min_price, max_price, tick_size, tick_precision)
    end

    """
    Parse a LotSizeFilter into a ParsedLotSizeFilter with Float64 values.
    """
    function parse_filter(filter::LotSizeFilter)
        return ParsedLotSizeFilter(
            parse(Float64, filter.minQty),
            parse(Float64, filter.maxQty),
            parse(Float64, filter.stepSize)
        )
    end

    """
    Parse a NotionalFilter into a ParsedNotionalFilter with Float64 values.
    """
    function parse_filter(filter::NotionalFilter)
        return ParsedNotionalFilter(
            parse(Float64, filter.minNotional),
            parse(Float64, filter.maxNotional)
        )
    end

    """
    Parse a MinNotionalFilter into a ParsedNotionalFilter with Float64 values.
    """
    function parse_filter(filter::MinNotionalFilter)
        return ParsedNotionalFilter(
            parse(Float64, filter.minNotional),
            Inf  # No max for MinNotionalFilter
        )
    end

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

    # --- Fast validation using parsed filters ---

    """
    Validate price using pre-parsed filter (faster than parsing each time).
    """
    @inline function validate_price(price::Float64, pf::ParsedPriceFilter)
        if pf.min_price > 0 && price < pf.min_price
            throw(ArgumentError("Price ($price) is below the minimum allowed price ($(pf.min_price))."))
        end

        if pf.max_price > 0 && price > pf.max_price
            throw(ArgumentError("Price ($price) is above the maximum allowed price ($(pf.max_price))."))
        end

        if pf.tick_size > 0
            val_to_check = round(price - pf.min_price, digits=pf.tick_precision)
            if rem(val_to_check, pf.tick_size) > 1e-9
                throw(ArgumentError("Price ($price) does not meet the tick size ($(pf.tick_size)) requirement."))
            end
        end

        return true
    end

    """
    Validate quantity using pre-parsed filter (faster than parsing each time).
    """
    @inline function validate_quantity(qty::Float64, lf::ParsedLotSizeFilter)
        if qty < lf.min_qty
            throw(ArgumentError("Quantity ($qty) is below the minimum allowed quantity ($(lf.min_qty))."))
        end

        if qty > lf.max_qty
            throw(ArgumentError("Quantity ($qty) is above the maximum allowed quantity ($(lf.max_qty))."))
        end

        if lf.step_size > 0
            steps_from_min = (qty - lf.min_qty) / lf.step_size
            rounded_steps = round(steps_from_min)
            tolerance = lf.step_size * 1e-9
            if abs(steps_from_min - rounded_steps) * lf.step_size > tolerance
                throw(ArgumentError("Quantity ($qty) does not meet the step size ($(lf.step_size)) requirement."))
            end
        end

        return true
    end

    """
    Validate notional value using pre-parsed filter.
    """
    @inline function validate_notional(notional::Float64, nf::ParsedNotionalFilter)
        if notional < nf.min_notional
            throw(ArgumentError("Notional value ($notional) is below the minimum required ($(nf.min_notional))."))
        end

        if notional > nf.max_notional
            throw(ArgumentError("Notional value ($notional) is above the maximum allowed ($(nf.max_notional))."))
        end

        return true
    end

    # --- Original filter validation (parses on each call - for backward compatibility) ---

    """
        validate_filter(params::Dict, filter::PriceFilter)

    Validates an order's price against the PRICE_FILTER rules.
    """
    function validate_filter(params::Dict, filter::PriceFilter)
        price = get(params, "price", nothing)
        !isnothing(price) || return true # Only validate if price is present

        price_val = parse(Float64, string(price))
        pf = parse_filter(filter)
        return validate_price(price_val, pf)
    end

    """
        validate_filter(params::Dict, filter::LotSizeFilter)

    Validates an order's quantity against the LOT_SIZE filter rules.
    """
    function validate_filter(params::Dict, filter::LotSizeFilter)
        quantity = get(params, "quantity", nothing)
        !isnothing(quantity) || return true # Only validate if quantity is present

        qty_val = parse(Float64, string(quantity))
        lf = parse_filter(filter)
        return validate_quantity(qty_val, lf)
    end

    """
        validate_filter(params::Dict, filter::MinNotionalFilter)

    Validates an order's notional value against the MIN_NOTIONAL filter.
    """
    function validate_filter(params::Dict, filter::MinNotionalFilter)
        price = get(params, "price", nothing)
        quantity = get(params, "quantity", nothing)
        quoteOrderQty = get(params, "quoteOrderQty", nothing)
        min_notional = parse(Float64, filter.minNotional)

        notional_value = 0.0

        if !isnothing(quoteOrderQty)
            notional_value = parse(Float64, string(quoteOrderQty))
        elseif !isnothing(price) && !isnothing(quantity)
            price_val = parse(Float64, string(price))
            qty_val = parse(Float64, string(quantity))
            notional_value = price_val * qty_val
        else
            # Cannot determine notional value for client-side validation (e.g., MARKET order with base quantity).
            # The server will have to validate this.
            return true
        end

        if notional_value < min_notional
            throw(ArgumentError("Notional value ($notional_value) is below the minimum required ($min_notional)."))
        end

        return true
    end

    """
        validate_filter(params::Dict, filter::NotionalFilter)

    Validates an order's notional value against the NOTIONAL filter rules.
    """
    function validate_filter(params::Dict, filter::NotionalFilter)
        price = get(params, "price", nothing)
        quantity = get(params, "quantity", nothing)
        quoteOrderQty = get(params, "quoteOrderQty", nothing)

        nf = parse_filter(filter)

        notional_value = 0.0

        if !isnothing(quoteOrderQty)
            notional_value = parse(Float64, string(quoteOrderQty))
        elseif !isnothing(price) && !isnothing(quantity)
            price_val = parse(Float64, string(price))
            qty_val = parse(Float64, string(quantity))
            notional_value = price_val * qty_val
        else
            # Cannot determine notional value for client-side validation (e.g., MARKET order with base quantity).
            # The server will have to validate this.
            return true
        end

        return validate_notional(notional_value, nf)
    end

    """
        validate_filter(params::Dict, filter::MaxAssetsFilter)

    The MAX_ASSET filter defines the maximum amount of an asset that an account can hold.
    This filter is not checked when placing an order.
    """
    function validate_filter(params::Dict, filter::MaxAssetsFilter)
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
