module Events

using StructTypes

export ExecutionReport, OutboundAccountPosition, BalanceUpdate, ListStatus, Balance

struct Balance
    a::String           # Asset
    f::String           # Free
    l::String           # Locked
end
StructTypes.StructType(::Type{Balance}) = StructTypes.Struct()

struct OutboundAccountPosition
    e::String             # Event type
    E::Int64              # Event time
    u::Int64              # Time of last account update
    B::Vector{Balance}    # Balances
end
StructTypes.StructType(::Type{OutboundAccountPosition}) = StructTypes.Struct()

struct BalanceUpdate
    e::String           # Event Type
    E::Int64            # Event Time
    a::String           # Asset
    d::String           # Balance Delta
    T::Int64            # Clear Time
end
StructTypes.StructType(::Type{BalanceUpdate}) = StructTypes.Struct()

struct OrderInListStatus
    s::String           # Symbol
    i::Int64            # OrderId
    c::String           # ClientOrderId
end
StructTypes.StructType(::Type{OrderInListStatus}) = StructTypes.Struct()

struct ListStatus
    e::String           # Event Type
    E::Int64            # Event Time
    s::String           # Symbol
    g::Int64            # OrderListId
    c::String           # Contingency Type
    l::String           # List Status Type
    L::String           # List Order Status
    r::String           # List Reject Reason
    C::String           # List Client Order ID
    T::Int64            # Transaction Time
    O::Vector{OrderInListStatus} # An array of objects
end
StructTypes.StructType(::Type{ListStatus}) = StructTypes.Struct()

struct ExecutionReport
    e::String             # Event type
    E::Int64              # Event time
    s::String             # Symbol
    c::String             # Client order ID
    S::String             # Side
    o::String             # Order type
    f::String             # Time in force
    q::String             # Order quantity
    p::String             # Order price
    P::String             # Stop price
    F::String             # Iceberg quantity
    g::Int64              # OrderListId
    C::String             # Original client order ID
    x::String             # Current execution type
    X::String             # Current order status
    r::String             # Order reject reason
    i::Int64              # Order ID
    l::String             # Last executed quantity
    z::String             # Cumulative filled quantity
    L::String             # Last executed price
    n::String             # Commission amount
    N::Union{String, Nothing} # Commission asset
    T::Int64              # Transaction time
    t::Int64              # Trade ID
    I::Int64              # Execution Id
    w::Bool               # Is the order on the book?
    m::Bool               # Is this trade the maker side?
    M::Bool               # Ignore
    O::Int64              # Order creation time
    Z::String             # Cumulative quote asset transacted quantity
    Y::String             # Last quote asset transacted quantity (quote)
    Q::String             # Quote Order Qty
    V::String             # Self-trade prevention mode

    # Conditional Fields
    W::Union{Int64, Nothing}   # Working Time
    d::Union{Int, Nothing}     # Trailing Delta
    D::Union{Int64, Nothing}   # Trailing Time
    j::Union{Int, Nothing}     # Strategy Id
    J::Union{Int, Nothing}     # Strategy Type
    v::Union{Int, Nothing}     # Prevented Match Id
    A::Union{String, Nothing}  # Prevented Quantity
    B::Union{String, Nothing}  # Last Prevented Quantity
    u::Union{Int, Nothing}     # Trade Group Id
    U::Union{Int, Nothing}     # Counter Order Id
    Cs::Union{String, Nothing} # Counter Symbol
    pl::Union{String, Nothing} # Prevented Execution Quantity
    pL::Union{String, Nothing} # Prevented Execution Price
    pY::Union{String, Nothing} # Prevented Execution Quote Qty
    b::Union{String, Nothing}  # Match Type
    a::Union{Int, Nothing}     # Allocation ID
    k::Union{String, Nothing}  # Working Floor
    uS::Union{Bool, Nothing}   # UsedSor
    gP::Union{String, Nothing} # Pegged Price Type
    gOT::Union{String, Nothing}# Pegged offset Type
    gOV::Union{Int, Nothing}   # Pegged Offset Value
    gp::Union{String, Nothing} # Pegged Price
end
StructTypes.StructType(::Type{ExecutionReport}) = StructTypes.Struct()

end # module Events
