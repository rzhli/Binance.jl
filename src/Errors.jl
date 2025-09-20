module Errors

export BinanceException,
       BinanceError,
       MalformedRequestError,
       UnauthorizedError,
       WAFViolationError,
       CancelReplacePartialSuccess,
       RateLimitError,
       IPAutoBannedError,
       BinanceServerError

# --- Custom Exception Types ---

abstract type BinanceException <: Exception end

struct BinanceError <: BinanceException
    http_status::Int
    code::Int
    msg::String
end
Base.show(io::IO, e::BinanceError) = print(io, "BinanceError(http_status=$(e.http_status), code=$(e.code), msg=\"$(e.msg)\")")

struct MalformedRequestError <: BinanceException
    code::Int
    msg::String
end
Base.show(io::IO, e::MalformedRequestError) = print(io, "MalformedRequestError(code=$(e.code), msg=\"$(e.msg)\")")

struct UnauthorizedError <: BinanceException
    code::Int
    msg::String
end
Base.show(io::IO, e::UnauthorizedError) = print(io, "UnauthorizedError(401): code=$(e.code), msg=\"$(e.msg)\")")

struct WAFViolationError <: BinanceException end
Base.show(io::IO, e::WAFViolationError) = print(io, "WAF Limit Violated (403)")

struct CancelReplacePartialSuccess <: BinanceException
    code::Int
    msg::String
end
Base.show(io::IO, e::CancelReplacePartialSuccess) = print(io, "Cancel/Replace Partially Succeeded (409): code=$(e.code), msg=\"$(e.msg)\"")

struct RateLimitError <: BinanceException
    code::Int
    msg::String
end
Base.show(io::IO, e::RateLimitError) = print(io, "Rate Limit Exceeded (429): code=$(e.code), msg=\"$(e.msg)\"")

struct IPAutoBannedError <: BinanceException end
Base.show(io::IO, e::IPAutoBannedError) = print(io, "IP Auto-banned (418)")

struct BinanceServerError <: BinanceException
    http_status::Int
    code::Int
    msg::String
end
Base.show(io::IO, e::BinanceServerError) = print(io, "Binance Server Error (http_status=$(e.http_status), code=$(e.code), msg=\"$(e.msg)\"). Execution status is UNKNOWN.")

end # module Errors
