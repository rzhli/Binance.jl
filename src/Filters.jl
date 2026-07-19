module Filters

    using ..Types

    export validate_order, validate_symbol, validate_interval, validate_order_type,
           validate_side, validate_time_in_force, ParsedPriceFilter, ParsedLotSizeFilter,
           ParsedNotionalFilter, parse_filter

    # --- Parsed Filter Structs (pre-parsed exact values) ---

    """
    Parsed version of PriceFilter with exact fixed-point values.
    """
    struct ParsedPriceFilter
        min_price::DecimalPrice
        max_price::DecimalPrice
        tick_size::DecimalPrice
    end

    """
    Parsed version of LotSizeFilter with exact fixed-point values.
    """
    struct ParsedLotSizeFilter
        min_qty::DecimalPrice
        max_qty::DecimalPrice
        step_size::DecimalPrice
    end

    """
    Parsed version of NotionalFilter with exact fixed-point values.
    """
    struct ParsedNotionalFilter
        min_notional::DecimalPrice
        max_notional::Union{DecimalPrice,Nothing}
    end

    @inline parse_decimal(value) = parse(DecimalPrice, string(value))

    # --- Filter Parsing Functions ---

    """
    Parse a PriceFilter once for exact, allocation-free validation.
    Call this once when loading symbol info, then reuse for all validations.
    """
    function parse_filter(filter::PriceFilter)
        return ParsedPriceFilter(
            parse_decimal(filter.minPrice),
            parse_decimal(filter.maxPrice),
            parse_decimal(filter.tickSize),
        )
    end

    """
    Parse a LotSizeFilter into a ParsedLotSizeFilter with Float64 values.
    """
    function parse_filter(filter::LotSizeFilter)
        return ParsedLotSizeFilter(
            parse_decimal(filter.minQty),
            parse_decimal(filter.maxQty),
            parse_decimal(filter.stepSize),
        )
    end

    """
    Parse a NotionalFilter into a ParsedNotionalFilter with Float64 values.
    """
    function parse_filter(filter::NotionalFilter)
        return ParsedNotionalFilter(
            parse_decimal(filter.minNotional),
            parse_decimal(filter.maxNotional),
        )
    end

    """
    Parse a MinNotionalFilter into a ParsedNotionalFilter with Float64 values.
    """
    function parse_filter(filter::MinNotionalFilter)
        return ParsedNotionalFilter(
            parse_decimal(filter.minNotional),
            nothing,
        )
    end

    # --- Generic Validation Dispatch ---

    """
        validate_order(params::Dict{String,Any}, filters::Vector{AbstractFilter})

    Iterates through all symbol filters and applies the appropriate validation logic.
    """
    function validate_order(params::Dict{String,Any}, filters::Vector{AbstractFilter})
        for filter in filters
            validate_filter(params, filter)
        end
        return true
    end

    # --- Filter-Specific Validation Functions ---

    function validate_filter(params::Dict{String,Any}, filter::AbstractFilter)
        # Generic fallback for unimplemented filters
        return true
    end

    # --- Fast validation using parsed filters ---

    """
    Validate price using pre-parsed filter (faster than parsing each time).
    """
    @inline function validate_price(price::DecimalPrice, pf::ParsedPriceFilter)
        if pf.min_price > 0 && price < pf.min_price
            throw(ArgumentError("Price ($price) is below the minimum allowed price ($(pf.min_price))."))
        end

        if pf.max_price > 0 && price > pf.max_price
            throw(ArgumentError("Price ($price) is above the maximum allowed price ($(pf.max_price))."))
        end

        if pf.tick_size > 0
            if rem(price - pf.min_price, pf.tick_size) != 0
                throw(ArgumentError("Price ($price) does not meet the tick size ($(pf.tick_size)) requirement."))
            end
        end

        return true
    end

    @inline validate_price(price, pf::ParsedPriceFilter) = validate_price(parse_decimal(price), pf)

    """
    Validate quantity using pre-parsed filter (faster than parsing each time).
    """
    @inline function validate_quantity(qty::DecimalPrice, lf::ParsedLotSizeFilter)
        if qty < lf.min_qty
            throw(ArgumentError("Quantity ($qty) is below the minimum allowed quantity ($(lf.min_qty))."))
        end

        if qty > lf.max_qty
            throw(ArgumentError("Quantity ($qty) is above the maximum allowed quantity ($(lf.max_qty))."))
        end

        if lf.step_size > 0
            if rem(qty - lf.min_qty, lf.step_size) != 0
                throw(ArgumentError("Quantity ($qty) does not meet the step size ($(lf.step_size)) requirement."))
            end
        end

        return true
    end

    @inline validate_quantity(qty, lf::ParsedLotSizeFilter) = validate_quantity(parse_decimal(qty), lf)

    """
    Validate notional value using pre-parsed filter.
    """
    @inline function validate_notional(notional::DecimalPrice, nf::ParsedNotionalFilter)
        if notional < nf.min_notional
            throw(ArgumentError("Notional value ($notional) is below the minimum required ($(nf.min_notional))."))
        end

        if !isnothing(nf.max_notional) && notional > nf.max_notional
            throw(ArgumentError("Notional value ($notional) is above the maximum allowed ($(nf.max_notional))."))
        end

        return true
    end

    @inline validate_notional(notional, nf::ParsedNotionalFilter) = validate_notional(parse_decimal(notional), nf)

    # --- Original filter validation (parses on each call - for backward compatibility) ---

    """
        validate_filter(params::Dict{String,Any}, filter::PriceFilter)

    Validates an order's price against the PRICE_FILTER rules.
    """
    function validate_filter(params::Dict{String,Any}, filter::PriceFilter)
        price = get(params, "price", nothing)
        !isnothing(price) || return true # Only validate if price is present

        pf = parse_filter(filter)
        return validate_price(price, pf)
    end

    """
        validate_filter(params::Dict{String,Any}, filter::LotSizeFilter)

    Validates an order's quantity against the LOT_SIZE filter rules.
    """
    function validate_filter(params::Dict{String,Any}, filter::LotSizeFilter)
        quantity = get(params, "quantity", nothing)
        !isnothing(quantity) || return true # Only validate if quantity is present

        lf = parse_filter(filter)
        return validate_quantity(quantity, lf)
    end

    """
        validate_filter(params::Dict{String,Any}, filter::MinNotionalFilter)

    Validates an order's notional value against the MIN_NOTIONAL filter.

    # Server-side reference price (2026-05-08)
    On the server side, when a non-null reference price exists for the symbol,
    Binance evaluates this filter against `referencePrice * quantity` rather
    than the historical `avgPrice * quantity`. When the reference price is
    null (or unavailable), behavior falls back to the previous formula. This
    client-side validator only checks the explicit price/quantity from the
    request, so client-server results may diverge for orders the server
    re-evaluates against reference price; the server's verdict is authoritative.
    """
    function validate_filter(params::Dict{String,Any}, filter::MinNotionalFilter)
        price = get(params, "price", nothing)
        quantity = get(params, "quantity", nothing)
        quoteOrderQty = get(params, "quoteOrderQty", nothing)
        min_notional = parse_decimal(filter.minNotional)

        if !isnothing(quoteOrderQty)
            notional_value = parse_decimal(quoteOrderQty)
        elseif !isnothing(price) && !isnothing(quantity)
            price_val = parse_decimal(price)
            qty_val = parse_decimal(quantity)
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
        validate_filter(params::Dict{String,Any}, filter::NotionalFilter)

    Validates an order's notional value against the NOTIONAL filter rules.

    # Server-side reference price (2026-05-08)
    Like `MIN_NOTIONAL`, the server evaluates `NOTIONAL` against
    `referencePrice * quantity` when a non-null reference price exists for
    the symbol; otherwise it falls back to the historical `avgPrice * quantity`
    behavior. Client-side validation here uses the explicit request price/qty,
    so the server may accept or reject orders that the client side judged
    differently — defer to the server's decision.
    """
    function validate_filter(params::Dict{String,Any}, filter::NotionalFilter)
        price = get(params, "price", nothing)
        quantity = get(params, "quantity", nothing)
        quoteOrderQty = get(params, "quoteOrderQty", nothing)

        nf = parse_filter(filter)

        if !isnothing(quoteOrderQty)
            notional_value = parse_decimal(quoteOrderQty)
        elseif !isnothing(price) && !isnothing(quantity)
            price_val = parse_decimal(price)
            qty_val = parse_decimal(quantity)
            notional_value = price_val * qty_val
        else
            # Cannot determine notional value for client-side validation (e.g., MARKET order with base quantity).
            # The server will have to validate this.
            return true
        end

        return validate_notional(notional_value, nf)
    end

    """
        validate_filter(params::Dict{String,Any}, filter::MaxAssetsFilter)

    The MAX_ASSET filter defines the maximum amount of an asset that an account can hold.
    This filter is not checked when placing an order.
    """
    function validate_filter(params::Dict{String,Any}, filter::MaxAssetsFilter)
        return true
    end

    # --- Utility Functions (from former Utils.jl) ---

    # Pre-allocated validation tuples (avoid per-call array allocation)
    const VALID_INTERVALS = ("1s", "1m", "3m", "5m", "15m", "30m", "1h", "2h", "4h", "6h", "8h", "12h", "1d", "3d", "1w", "1M")
    const VALID_ORDER_TYPES = ("LIMIT", "MARKET", "STOP_LOSS", "STOP_LOSS_LIMIT", "TAKE_PROFIT", "TAKE_PROFIT_LIMIT", "LIMIT_MAKER")
    const VALID_SIDES = ("BUY", "SELL")
    const VALID_TIME_IN_FORCE = ("GTC", "IOC", "FOK")

    function validate_symbol(symbol::String)
        if isempty(symbol)
            throw(ArgumentError("Symbol cannot be empty"))
        end
        return uppercase(symbol)
    end

    function validate_interval(interval::String)
        if !(interval in VALID_INTERVALS)
            throw(ArgumentError("Invalid interval. Valid intervals: $(join(VALID_INTERVALS, ", "))"))
        end
        return interval
    end

    function validate_order_type(order_type::String)
        if !(order_type in VALID_ORDER_TYPES)
            throw(ArgumentError("Invalid order type. Valid types: $(join(VALID_ORDER_TYPES, ", "))"))
        end
        return order_type
    end

    function validate_side(side::String)
        if !(side in VALID_SIDES)
            throw(ArgumentError("Invalid side. Valid sides: $(join(VALID_SIDES, ", "))"))
        end
        return side
    end

    function validate_time_in_force(tif::String)
        if !(tif in VALID_TIME_IN_FORCE)
            throw(ArgumentError("Invalid time in force. Valid values: $(join(VALID_TIME_IN_FORCE, ", "))"))
        end
        return tif
    end

end # module Filters
