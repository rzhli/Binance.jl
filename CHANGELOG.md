# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.7.2] - 2025-01-31

### Added
- **Comprehensive SPOT API Error Codes** - Added 50+ new error codes to `Errors.jl`
  - FIX protocol errors (-1033, -1034, -1035, -1169 to -1191)
  - SBE-related errors (-1152 to -1155, -1161)
  - OCO/OPO order validation errors (-1158, -1160, -1165 to -1168, -1196 to -1199)
  - Parameter and request errors (-1013, -1108, -1122, -1135, -1139, -1145, -1194)
  - Peg order errors (-1210, -1211)
  - OPO/symbol status errors (-1220 to -1225)
  - Subscription and order amend errors (-2035, -2036, -2038, -2039, -2042)
- **New Filter Failure Descriptions** - 5 new entries in `FILTER_FAILURES`
  - `NOTIONAL`, `MAX_NUM_ORDER_AMENDS`, `MAX_NUM_ORDER_LISTS`
  - `EXCHANGE_MAX_NUM_ICEBERG_ORDERS`, `EXCHANGE_MAX_NUM_ORDER_LISTS`

### Performance Improvements
- **Convert.jl** - Julia performance optimization
  - All `show` methods: replaced string interpolation `$()` with direct `print` arguments
  - Validation checks: replaced vector `["BUY", "SELL"]` with tuple `("BUY", "SELL")` for `in` operations (stack-allocated, zero allocation)
