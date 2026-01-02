---
description: "Julia performance tips and best practices for writing high-performance code"
allowed-tools: ["Read", "Edit", "Write", "Grep", "Glob"]
---

# Julia Performance Tips

When writing or reviewing Julia code, apply these performance best practices:

## General Rules

1. **Performance critical code must be inside functions** - top-level code is slow due to how Julia's compiler works
2. **Avoid untyped global variables** - use `const` for constants, or pass as function arguments
3. **Measure with `@time` and watch allocations** - unexpected allocations indicate type instability

## Type Stability

1. **Avoid abstract type parameters in containers** - use `Vector{Float64}` not `Vector{Real}`
2. **Avoid fields with abstract types** - use parameterized types: `struct Foo{T} a::T end`
3. **Write type-stable functions** - return consistent types, use `zero(x)`, `oneunit(x)`, `oftype(x, y)`
4. **Don't change variable types** - initialize with correct type: `x = 1.0` not `x = 1` then divide
5. **Use function barriers** - separate type-unstable setup from type-stable kernel functions
6. **Use `@code_warntype`** - check for `Union` or `Any` types (shown in red/uppercase)

## Memory Management

1. **Pre-allocate outputs** - use in-place functions with `!` suffix (e.g., `mul!`, `fill!`)
2. **Use views for slices** - `@views` or `view()` instead of copying with `array[1:5, :]`
3. **Use StaticArrays.jl** - for small fixed-size arrays (< 100 elements)
4. **Fuse vectorized operations** - use `@.` macro: `@. 3x^2 + 4x` instead of separate allocations
5. **Access arrays in column-major order** - inner loop should vary first index

## Performance Annotations

1. **`@inbounds`** - eliminate bounds checking (be certain indices are valid)
2. **`@fastmath`** - allow floating-point reordering (may change results for IEEE edge cases)
3. **`@simd`** - promise loop iterations are independent and reorderable

## Common Patterns

```julia
# BAD: Type unstable
pos(x) = x < 0 ? 0 : x

# GOOD: Type stable
pos(x) = x < 0 ? zero(x) : x

# BAD: Global variable
x = rand(1000)
function sum_global()
    s = 0.0
    for i in x
        s += i
    end
    return s
end

# GOOD: Pass as argument
function sum_arg(x)
    s = zero(eltype(x))
    for i in x
        s += i
    end
    return s
end

# GOOD: Pre-allocation with in-place function
function compute!(result, x)
    @inbounds @simd for i in eachindex(x)
        result[i] = expensive_op(x[i])
    end
    return result
end

# GOOD: Function barrier for type stability
function process_data(data)
    # Type-unstable setup
    T = detect_type(data)
    arr = Vector{T}(undef, length(data))
    # Type-stable kernel
    fill_array!(arr, data)  # Compiler specializes this
    return arr
end
```

## Captured Variables in Closures

```julia
# BAD: Type unstable closure
function abmult(r::Int)
    if r < 0; r = -r; end
    f = x -> x * r  # r's type unknown to compiler
    return f
end

# GOOD: Use let block to capture concrete type
function abmult(r::Int)
    if r < 0; r = -r; end
    f = let r = r
        x -> x * r
    end
    return f
end
```

## Avoid These Mistakes

- Don't use `Union{Function, AbstractString}` - redesign instead
- Don't use `Vector{Any}` unless truly necessary
- Don't overuse `try-catch` - validate inputs instead
- Don't use `...` splat excessively - `[a; b]` is better than `[a..., b...]`
- Don't interpolate strings for I/O - use `println(file, a, " ", b)` not `println(file, "$a $b")`

## Quick Checklist

When reviewing Julia code for performance:

- [ ] Is all performance-critical code inside functions?
- [ ] Are global variables `const` or passed as arguments?
- [ ] Are container element types concrete (not abstract)?
- [ ] Are struct fields concretely typed or parameterized?
- [ ] Does `@code_warntype` show any red/uppercase types?
- [ ] Are arrays pre-allocated where possible?
- [ ] Are loops accessing arrays in column-major order?
- [ ] Are appropriate `@inbounds`, `@simd` annotations used?

$ARGUMENTS
