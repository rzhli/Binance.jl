"""
Binance API Error Handling Module

This module defines exception types and error code mappings for the Binance API.

## Error Code Categories
- **10xx**: General Server or Network issues
- **11xx-2xxx**: Request issues
- **3xxx-5xxx**: SAPI-specific issues
- **6xxx**: Savings Issues
- **7xxx**: Futures
- **10xxx**: Crypto Loans
- **12xxx**: Liquid Swap
- **13xxx**: BLVT
- **18xxx**: Binance Code
- **20xxx**: Futures/Spot Algo
- **21xxx**: Portfolio Margin Account

## HTTP Status Codes
- **403**: WAF Limit Violated
- **409**: Cancel/Replace Partially Succeeded
- **418**: IP Auto-banned
- **429**: Rate Limit Exceeded
- **5xx**: Server Error (execution status UNKNOWN)

See: https://developers.binance.com/docs/binance-spot-api-docs/errors
"""
module Errors

export BinanceException,
       BinanceError,
       MalformedRequestError,
       UnauthorizedError,
       WAFViolationError,
       CancelReplacePartialSuccess,
       RateLimitError,
       IPAutoBannedError,
       BinanceServerError,
       get_error_description,
       ERROR_CODES

# --- Error Code Dictionary ---

"""
Dictionary mapping Binance error codes to their descriptions.
"""
const ERROR_CODES = Dict{Int,String}(
    # 10xx - General Server or Network issues
    -1000 => "UNKNOWN: An unknown error occurred while processing the request.",
    -1001 => "DISCONNECTED: Internal error; unable to process your request. Please try again.",
    -1002 => "UNAUTHORIZED: You are not authorized to execute this request.",
    -1003 => "TOO_MANY_REQUESTS: Too many requests queued or too much request weight used.",
    -1004 => "SERVER_BUSY: Server is busy, please wait and try again.",
    -1006 => "UNEXPECTED_RESP: An unexpected response was received from the message bus.",
    -1007 => "TIMEOUT: Timeout waiting for response from backend server.",
    -1008 => "SERVER_BUSY: Spot server is currently overloaded with other requests.",
    -1013 => "INVALID_MESSAGE: The request is rejected by the API.",
    -1014 => "UNKNOWN_ORDER_COMPOSITION: Unsupported order combination.",
    -1015 => "TOO_MANY_ORDERS: Too many new orders.",
    -1016 => "SERVICE_SHUTTING_DOWN: This service is no longer available.",
    -1020 => "UNSUPPORTED_OPERATION: This operation is not supported.",
    -1021 => "INVALID_TIMESTAMP: Timestamp for this request is outside of the recvWindow.",
    -1022 => "INVALID_SIGNATURE: Signature for this request is not valid.",
    -1033 => "COMP_ID_IN_USE: SenderCompId is currently in use.",
    -1034 => "TOO_MANY_CONNECTIONS: Too many concurrent connections.",
    -1035 => "LOGGED_OUT: Please send Logout message to close the session.",
    -1099 => "NOT_FOUND: Not found, authenticated, or authorized.",

    # 11xx-2xxx - Request issues
    -1100 => "ILLEGAL_CHARS: Illegal characters found in a parameter.",
    -1101 => "TOO_MANY_PARAMETERS: Too many parameters sent for this endpoint.",
    -1102 => "MANDATORY_PARAM_EMPTY_OR_MALFORMED: A mandatory parameter was not sent, was empty/null, or malformed.",
    -1103 => "UNKNOWN_PARAM: An unknown parameter was sent.",
    -1104 => "UNREAD_PARAMETERS: Not all sent parameters were read.",
    -1105 => "PARAM_EMPTY: A parameter was empty.",
    -1106 => "PARAM_NOT_REQUIRED: A parameter was sent when not required.",
    -1108 => "PARAM_OVERFLOW: Parameter overflowed.",
    -1111 => "BAD_PRECISION: Precision is over the maximum defined for this asset.",
    -1112 => "NO_DEPTH: No orders on book for symbol.",
    -1114 => "TIF_NOT_REQUIRED: TimeInForce parameter sent when not required.",
    -1115 => "INVALID_TIF: Invalid timeInForce.",
    -1116 => "INVALID_ORDER_TYPE: Invalid orderType.",
    -1117 => "INVALID_SIDE: Invalid side.",
    -1118 => "EMPTY_NEW_CL_ORD_ID: New client order ID was empty.",
    -1119 => "EMPTY_ORG_CL_ORD_ID: Original client order ID was empty.",
    -1120 => "BAD_INTERVAL: Invalid interval.",
    -1121 => "BAD_SYMBOL: Invalid symbol.",
    -1122 => "INVALID_SYMBOLSTATUS: Invalid symbolStatus.",
    -1125 => "INVALID_LISTEN_KEY: This listenKey does not exist.",
    -1127 => "MORE_THAN_XX_HOURS: Lookup interval is too big.",
    -1128 => "OPTIONAL_PARAMS_BAD_COMBO: Combination of optional parameters invalid.",
    -1130 => "INVALID_PARAMETER: Invalid data sent for a parameter.",
    -1131 => "BAD_RECV_WINDOW: recvWindow must be less than 60000.",
    -1134 => "BAD_STRATEGY_TYPE: strategyType was less than 1000000.",
    -1135 => "INVALID_JSON: Invalid JSON Request.",
    -1139 => "INVALID_TICKER_TYPE: Invalid ticker type.",
    -1145 => "INVALID_CANCEL_RESTRICTIONS: cancelRestrictions has to be either ONLY_NEW or ONLY_PARTIALLY_FILLED.",
    -1151 => "DUPLICATE_SYMBOLS: Symbol is present multiple times in the list.",
    -1152 => "INVALID_SBE_HEADER: Invalid X-MBX-SBE header.",
    -1153 => "UNSUPPORTED_SCHEMA_ID: Unsupported SBE schema ID or version.",
    -1155 => "SBE_DISABLED: SBE is not enabled.",
    -1158 => "OCO_ORDER_TYPE_REJECTED: Order type not supported in OCO.",
    -1160 => "OCO_ICEBERGQTY_TIMEINFORCE: TimeInForce must be GTC when using icebergQty in OCO.",
    -1161 => "DEPRECATED_SCHEMA: Unable to encode response in specified SBE schema.",
    -1165 => "BUY_OCO_LIMIT_MUST_BE_BELOW: A limit order in a buy OCO must be below.",
    -1166 => "SELL_OCO_LIMIT_MUST_BE_ABOVE: A limit order in a sell OCO must be above.",
    -1168 => "BOTH_OCO_ORDERS_CANNOT_BE_LIMIT: At least one OCO order must be contingent.",
    -1169 => "INVALID_TAG_NUMBER: Invalid tag number.",
    -1170 => "TAG_NOT_DEFINED_IN_MESSAGE: Tag not defined for this message type.",
    -1171 => "TAG_APPEARS_MORE_THAN_ONCE: Tag appears more than once.",
    -1172 => "TAG_OUT_OF_ORDER: Tag specified out of required order.",
    -1173 => "GROUP_FIELDS_OUT_OF_ORDER: Repeating group fields out of order.",
    -1174 => "INVALID_COMPONENT: Component is incorrectly populated.",
    -1175 => "RESET_SEQ_NUM_SUPPORT: Sequence numbers must be reset for each new session.",
    -1176 => "ALREADY_LOGGED_IN: Logon should only be sent once.",
    -1177 => "GARBLED_MESSAGE: Message format error (CheckSum, BeginString, MsgType, BodyLength).",
    -1178 => "BAD_SENDER_COMPID: SenderCompId contains an incorrect value.",
    -1179 => "BAD_SEQ_NUM: MsgSeqNum contains an unexpected value.",
    -1180 => "EXPECTED_LOGON: Logon must be the first message in the session.",
    -1181 => "TOO_MANY_MESSAGES: Too many messages.",
    -1182 => "PARAMS_BAD_COMBO: Conflicting fields.",
    -1183 => "NOT_ALLOWED_IN_DROP_COPY_SESSIONS: Operation not allowed in DropCopy sessions.",
    -1184 => "DROP_COPY_SESSION_NOT_ALLOWED: DropCopy sessions not supported on this server.",
    -1185 => "DROP_COPY_SESSION_REQUIRED: Only DropCopy sessions supported on this server.",
    -1186 => "NOT_ALLOWED_IN_ORDER_ENTRY_SESSIONS: Operation not allowed in order entry sessions.",
    -1187 => "NOT_ALLOWED_IN_MARKET_DATA_SESSIONS: Operation not allowed in market data sessions.",
    -1188 => "INCORRECT_NUM_IN_GROUP_COUNT: Incorrect NumInGroup count for repeating group.",
    -1189 => "DUPLICATE_ENTRIES_IN_A_GROUP: Group contains duplicate entries.",
    -1190 => "INVALID_REQUEST_ID: MDReqID already in use or does not match active subscription.",
    -1191 => "TOO_MANY_SUBSCRIPTIONS: Too many subscriptions.",
    -1194 => "INVALID_TIME_UNIT: Invalid value for time unit; expected MICROSECOND or MILLISECOND.",
    -1196 => "BUY_OCO_STOP_LOSS_MUST_BE_ABOVE: A stop loss order in a buy OCO must be above.",
    -1197 => "SELL_OCO_STOP_LOSS_MUST_BE_BELOW: A stop loss order in a sell OCO must be below.",
    -1198 => "BUY_OCO_TAKE_PROFIT_MUST_BE_BELOW: A take profit order in a buy OCO must be below.",
    -1199 => "SELL_OCO_TAKE_PROFIT_MUST_BE_ABOVE: A take profit order in a sell OCO must be above.",
    -1210 => "INVALID_PEG_PRICE_TYPE: Invalid pegPriceType.",
    -1211 => "INVALID_PEG_OFFSET_TYPE: Invalid pegOffsetType.",
    -1220 => "SYMBOL_DOES_NOT_MATCH_STATUS: The symbol's status does not match the requested symbolStatus.",
    -1221 => "INVALID_SBE_MESSAGE_FIELD: Invalid/missing field(s) in SBE message.",
    -1222 => "OPO_WORKING_MUST_BE_BUY: Working order in an OPO list must be a bid.",
    -1223 => "OPO_PENDING_MUST_BE_SELL: Pending orders in an OPO list must be asks.",
    -1224 => "WORKING_PARAM_REQUIRED: Working order must include the required tag.",
    -1225 => "PENDING_PARAM_NOT_REQUIRED: Pending orders should not include the specified tag.",

    # Order rejection issues
    -1010 => "ERROR_MSG_RECEIVED: Error message received from matching engine.",
    -2010 => "NEW_ORDER_REJECTED: New order rejected.",
    -2011 => "CANCEL_REJECTED: Cancel rejected.",
    -2013 => "NO_SUCH_ORDER: Order does not exist.",
    -2014 => "BAD_API_KEY_FMT: API-key format invalid.",
    -2015 => "REJECTED_MBX_KEY: Invalid API-key, IP, or permissions for action.",
    -2016 => "NO_TRADING_WINDOW: No trading window could be found for the symbol.",
    -2021 => "ORDER_CANCEL_REPLACE_PARTIALLY_FAILED: Order cancel-replace partially failed.",
    -2022 => "ORDER_CANCEL_REPLACE_FAILED: Order cancel-replace failed.",
    -2026 => "ORDER_ARCHIVED: Order was canceled or expired with no executed qty over 90 days ago and has been archived.",
    -2035 => "SUBSCRIPTION_ACTIVE: User Data Stream subscription already active.",
    -2036 => "SUBSCRIPTION_INACTIVE: User Data Stream subscription not active.",
    -2038 => "ORDER_AMEND_REJECTED: Order amend rejected.",
    -2039 => "CLIENT_ORDER_ID_INVALID: Client order ID is not correct for this order ID.",
    -2042 => "MAXIMUM_SUBSCRIPTION_IDS: Maximum subscription ID reached for this connection.",

    # 3xxx-5xxx - SAPI-specific issues
    -3000 => "INNER_FAILURE: Internal server error.",
    -3001 => "NEED_ENABLE_2FA: Please enable 2FA first.",
    -3002 => "ASSET_DEFICIENCY: We don't have this asset.",
    -3003 => "NO_OPENED_MARGIN_ACCOUNT: Margin account does not exist.",
    -3004 => "TRADE_NOT_ALLOWED: Trade not allowed.",
    -3005 => "TRANSFER_OUT_NOT_ALLOWED: Transferring out not allowed.",
    -3006 => "EXCEED_MAX_BORROWABLE: Your borrow amount has exceed maximum borrow amount.",
    -3007 => "HAS_PENDING_TRANSACTION: You have pending transaction, please try again later.",
    -3008 => "BORROW_NOT_ALLOWED: Borrow not allowed.",
    -3009 => "ASSET_NOT_MORTGAGEABLE: This asset are not allowed to transfer into margin account currently.",
    -3010 => "REPAY_NOT_ALLOWED: Repay not allowed.",
    -3011 => "BAD_DATE_RANGE: Your input date is invalid.",
    -3012 => "ASSET_ADMIN_BAN_BORROW: Borrow is banned for this asset.",
    -3013 => "LT_MIN_BORROWABLE: Borrow amount less than minimum borrow amount.",
    -3014 => "ACCOUNT_BAN_BORROW: Borrow is banned for this account.",
    -3015 => "REPAY_EXCEED_LIABILITY: Repay amount exceeds borrow amount.",
    -3016 => "LT_MIN_REPAY: Repay amount less than minimum repay amount.",
    -3017 => "ASSET_ADMIN_BAN_MORTGAGE: This asset are not allowed to transfer into margin account currently.",
    -3018 => "ACCOUNT_BAN_MORTGAGE: Transferring in has been banned for this account.",
    -3019 => "ACCOUNT_BAN_ROLLOUT: Transferring out has been banned for this account.",
    -3020 => "EXCEED_MAX_ROLLOUT: Transfer out amount exceeds max amount.",
    -3021 => "PAIR_ADMIN_BAN_TRADE: Margin account are not allowed to trade this trading pair.",
    -3022 => "ACCOUNT_BAN_TRADE: You account's trading is banned.",
    -3023 => "WARNING_MARGIN_LEVEL: You can't transfer out/place order under current margin level.",
    -3024 => "FEW_LIABILITY_LEFT: The unpaid debt is too small after this repayment.",
    -3025 => "INVALID_EFFECTIVE_TIME: Your input date is invalid.",
    -3026 => "VALIDATION_FAILED: Your input param is invalid.",
    -3027 => "NOT_VALID_MARGIN_ASSET: Not a valid margin asset.",
    -3028 => "NOT_VALID_MARGIN_PAIR: Not a valid margin pair.",
    -3029 => "TRANSFER_FAILED: Transfer failed.",
    -3036 => "ACCOUNT_BAN_REPAY: This account is not allowed to repay.",
    -3037 => "PNL_CLEARING: PNL is clearing. Wait a second.",
    -3038 => "LISTEN_KEY_NOT_FOUND: Listen key not found.",
    -3041 => "BALANCE_NOT_CLEARED: Balance is not enough.",
    -3042 => "PRICE_INDEX_NOT_FOUND: PriceIndex not available for this margin pair.",
    -3043 => "TRANSFER_IN_NOT_ALLOWED: Transferring in not allowed.",
    -3044 => "SYSTEM_BUSY: System busy.",
    -3045 => "SYSTEM: The system doesn't have enough asset now.",
    -3999 => "NOT_WHITELIST_USER: This function is only available for invited users.",

    # 4xxx - Capital issues
    -4001 => "CAPITAL_INVALID: Invalid operation.",
    -4002 => "CAPITAL_IG: Invalid get.",
    -4003 => "CAPITAL_IEV: Your input email is invalid.",
    -4004 => "CAPITAL_UA: You don't login or auth.",
    -4005 => "CAPAITAL_TOO_MANY_REQUEST: Too many new requests.",
    -4006 => "CAPITAL_ONLY_SUPPORT_PRIMARY_ACCOUNT: Support main account only.",
    -4007 => "CAPITAL_ADDRESS_VERIFICATION_NOT_PASS: Address validation is not passed.",
    -4008 => "CAPITAL_ADDRESS_TAG_VERIFICATION_NOT_PASS: Address tag validation is not passed.",
    -4010 => "CAPITAL_WHITELIST_EMAIL_CONFIRM: White list mail has been confirmed.",
    -4011 => "CAPITAL_WHITELIST_EMAIL_EXPIRED: White list mail is invalid.",
    -4012 => "CAPITAL_WHITELIST_CLOSE: White list is not opened.",
    -4013 => "CAPITAL_WITHDRAW_2FA_VERIFY: 2FA is not opened.",
    -4014 => "CAPITAL_WITHDRAW_LOGIN_DELAY: Withdraw is not allowed within 2 min login.",
    -4015 => "CAPITAL_WITHDRAW_RESTRICTED_MINUTE: Withdraw is limited.",
    -4016 => "CAPITAL_WITHDRAW_RESTRICTED_PASSWORD: Within 24 hours after password modification, withdrawal is prohibited.",
    -4017 => "CAPITAL_WITHDRAW_RESTRICTED_UNBIND_2FA: Within 24 hours after the release of 2FA, withdrawal is prohibited.",
    -4018 => "CAPITAL_WITHDRAW_ASSET_NOT_EXIST: We don't have this asset.",
    -4019 => "CAPITAL_WITHDRAW_ASSET_PROHIBIT: Current asset is not open for withdrawal.",
    -4021 => "CAPITAL_WITHDRAW_AMOUNT_MULTIPLE: Asset withdrawal must be a multiple of step size.",
    -4022 => "CAPITAL_WITHDRAW_MIN_AMOUNT: Not less than the minimum pick-up quantity.",
    -4023 => "CAPITAL_WITHDRAW_MAX_AMOUNT: Within 24 hours, the withdrawal exceeds the maximum amount.",
    -4024 => "CAPITAL_WITHDRAW_USER_NO_ASSET: You don't have this asset.",
    -4025 => "CAPITAL_WITHDRAW_USER_ASSET_LESS_THAN_ZERO: The number of hold asset is less than zero.",
    -4026 => "CAPITAL_WITHDRAW_USER_ASSET_NOT_ENOUGH: You have insufficient balance.",
    -4027 => "CAPITAL_WITHDRAW_GET_TRAN_ID_FAILURE: Failed to obtain tranId.",
    -4028 => "CAPITAL_WITHDRAW_MORE_THAN_FEE: The amount of withdrawal must be greater than the Commission.",
    -4029 => "CAPITAL_WITHDRAW_NOT_EXIST: The withdrawal record does not exist.",
    -4030 => "CAPITAL_WITHDRAW_CONFIRM_SUCCESS: Confirmation of successful asset withdrawal.",
    -4031 => "CAPITAL_WITHDRAW_CANCEL_FAILURE: Cancellation failed.",
    -4032 => "CAPITAL_WITHDRAW_CHECKSUM_VERIFY_FAILURE: Withdraw verification exception.",
    -4033 => "CAPITAL_WITHDRAW_ILLEGAL_ADDRESS: Illegal address.",
    -4034 => "CAPITAL_WITHDRAW_ADDRESS_CHEAT: The address is suspected of fake.",
    -4035 => "CAPITAL_WITHDRAW_NOT_WHITE_ADDRESS: This address is not on the whitelist.",
    -4036 => "CAPITAL_WITHDRAW_NEW_ADDRESS: The new address needs to be withdrawn in hours.",
    -4037 => "CAPITAL_WITHDRAW_RESEND_EMAIL_FAIL: Re-sending Mail failed.",
    -4038 => "CAPITAL_WITHDRAW_RESEND_EMAIL_TIME_OUT: Please try again in 5 minutes.",
    -4039 => "CAPITAL_USER_EMPTY: The user does not exist.",
    -4040 => "CAPITAL_NO_CHARGE: This address not charged.",
    -4041 => "CAPITAL_MINUTE_TOO_SMALL: Please try again in one minute.",
    -4042 => "CAPITAL_CHARGE_NOT_RESET: This asset cannot get deposit address again.",
    -4043 => "CAPITAL_ADDRESS_TOO_MUCH: More than 100 recharge addresses were used in 24 hours.",
    -4044 => "CAPITAL_BLACKLIST_COUNTRY_GET_ADDRESS: This is a blacklist country.",
    -4045 => "CAPITAL_GET_ASSET_ERROR: Failure to acquire assets.",
    -4046 => "CAPITAL_AGREEMENT_NOT_CONFIRMED: Agreement not confirmed.",
    -4047 => "CAPITAL_DATE_INTERVAL_LIMIT: Time interval must be within 0-90 days.",
    -4060 => "CAPITAL_WITHDRAW_USER_ASSET_LOCK_DEPOSIT: Deposit has not reached required block confirmations.",

    # 5xxx - Asset issues
    -5001 => "ASSET_DRIBBLET_CONVERT_SWITCH_OFF: Don't allow transfer to micro assets.",
    -5002 => "ASSET_ASSET_NOT_ENOUGH: You have insufficient balance.",
    -5003 => "ASSET_USER_HAVE_NO_ASSET: You don't have this asset.",
    -5004 => "USER_OUT_OF_TRANSFER_FLOAT: The residual balances have exceeded 0.001BTC.",
    -5005 => "USER_ASSET_AMOUNT_IS_TOO_LOW: The residual balances is too low.",
    -5006 => "USER_CAN_NOT_REQUEST_IN_24_HOURS: Only transfer once in 24 hours.",
    -5007 => "AMOUNT_OVER_ZERO: Quantity must be greater than zero.",
    -5008 => "ASSET_WITHDRAW_WITHDRAWING_NOT_ENOUGH: Insufficient amount of returnable assets.",
    -5009 => "PRODUCT_NOT_EXIST: Product does not exist.",
    -5010 => "TRANSFER_FAIL: Asset transfer fail.",
    -5011 => "FUTURE_ACCT_NOT_EXIST: Future account not exists.",
    -5012 => "TRANSFER_PENDING: Asset transfer is in pending.",
    -5021 => "PARENT_SUB_HAVE_NO_RELATION: This parent sub have no relation.",

    # 6xxx - Savings Issues
    -6001 => "DAILY_PRODUCT_NOT_EXIST: Daily product not exists.",
    -6003 => "DAILY_PRODUCT_NOT_ACCESSIBLE: Product not exist or you don't have permission.",
    -6004 => "DAILY_PRODUCT_NOT_PURCHASABLE: Product not in purchase status.",
    -6005 => "DAILY_LOWER_THAN_MIN_PURCHASE_LIMIT: Smaller than min purchase limit.",
    -6006 => "DAILY_REDEEM_AMOUNT_ERROR: Redeem amount error.",
    -6007 => "DAILY_REDEEM_TIME_ERROR: Not in redeem time.",
    -6008 => "DAILY_PRODUCT_NOT_REDEEMABLE: Product not in redeem status.",
    -6009 => "REQUEST_FREQUENCY_TOO_HIGH: Request frequency too high.",
    -6011 => "EXCEEDED_USER_PURCHASE_LIMIT: Exceeding the maximum num allowed to purchase per user.",
    -6012 => "BALANCE_NOT_ENOUGH: Balance not enough.",
    -6013 => "PURCHASING_FAILED: Purchasing failed.",
    -6014 => "UPDATE_FAILED: Exceed up-limit allowed to purchased.",
    -6015 => "EMPTY_REQUEST_BODY: Empty request body.",
    -6016 => "PARAMS_ERR: Parameter error.",
    -6017 => "NOT_IN_WHITELIST: Not in whitelist.",
    -6018 => "ASSET_NOT_ENOUGH: Asset not enough.",
    -6019 => "PENDING: Need confirm.",
    -6020 => "PROJECT_NOT_EXISTS: Project not exists.",

    # 7xxx - Futures
    -7001 => "FUTURES_BAD_DATE_RANGE: Date range is not supported.",
    -7002 => "FUTURES_BAD_TYPE: Data request type is not supported.",

    # 10xxx - Crypto Loans
    -10001 => "SYSTEM_MAINTENANCE: The system is under maintenance, please try again later.",
    -10002 => "INVALID_INPUT: Invalid input parameters.",
    -10005 => "NO_RECORDS: No records found.",
    -10007 => "COIN_NOT_LOANABLE: This coin is not loanable.",
    -10008 => "COIN_NOT_LOANABLE: This coin is not loanable.",
    -10009 => "COIN_NOT_COLLATERAL: This coin can not be used as collateral.",
    -10010 => "COIN_NOT_COLLATERAL: This coin can not be used as collateral.",
    -10011 => "INSUFFICIENT_ASSET: Insufficient spot assets.",
    -10012 => "INVALID_AMOUNT: Invalid repayment amount.",
    -10013 => "INSUFFICIENT_AMOUNT: Insufficient collateral amount.",
    -10015 => "DEDUCTION_FAILED: Collateral deduction failed.",
    -10016 => "LOAN_FAILED: Failed to provide loan.",
    -10017 => "REPAY_EXCEED_DEBT: Repayment amount exceeds debt.",
    -10018 => "INVALID_AMOUNT: Invalid repayment amount.",
    -10019 => "CONFIG_NOT_EXIST: Configuration does not exists.",
    -10020 => "UID_NOT_EXIST: User ID does not exist.",
    -10021 => "ORDER_NOT_EXIST: Order does not exist.",
    -10022 => "INVALID_AMOUNT: Invalid adjustment amount.",
    -10023 => "ADJUST_LTV_FAILED: Failed to adjust LTV.",
    -10024 => "ADJUST_LTV_NOT_SUPPORTED: LTV adjustment not supported.",
    -10025 => "REPAY_FAILED: Repayment failed.",
    -10026 => "INVALID_PARAMETER: Invalid parameter.",
    -10028 => "INVALID_PARAMETER: Invalid parameter.",
    -10029 => "AMOUNT_TOO_SMALL: Loan amount is too small.",
    -10030 => "AMOUNT_TOO_LARGE: Loan amount is too much.",
    -10031 => "QUOTA_REACHED: Individual loan quota reached.",
    -10032 => "REPAY_NOT_AVAILABLE: Repayment is temporarily unavailable.",
    -10034 => "REPAY_NOT_AVAILABLE: Repay with collateral is not available currently.",
    -10039 => "AMOUNT_TOO_SMALL: Repayment amount is too small.",
    -10040 => "AMOUNT_TOO_LARGE: Repayment amount is too large.",
    -10041 => "INSUFFICIENT_AMOUNT: Insufficient loanable assets due to high demand.",
    -10042 => "ASSET_NOT_SUPPORTED: Asset is not supported.",
    -10043 => "ASSET_NOT_SUPPORTED: Borrowing is currently not supported.",
    -10044 => "QUOTA_REACHED: Collateral amount has reached the limit.",
    -10045 => "COLLTERAL_REPAY_NOT_SUPPORTED: The loan coin does not support collateral repayment.",
    -10046 => "EXCEED_MAX_ADJUSTMENT: Collateral Adjustment exceeds the maximum limit.",
    -10047 => "REGION_NOT_SUPPORTED: This coin is currently not supported in your location.",

    # 12xxx - Liquid Swap
    -12014 => "TOO_MANY_REQUESTS: More than 1 request in 2 seconds.",

    # 13xxx - BLVT
    -13000 => "BLVT_FORBID_REDEEM: Redemption of the token is forbidden now.",
    -13001 => "BLVT_EXCEED_DAILY_LIMIT: Exceeds individual 24h redemption limit of the token.",
    -13002 => "BLVT_EXCEED_TOKEN_DAILY_LIMIT: Exceeds total 24h redemption limit of the token.",
    -13003 => "BLVT_FORBID_PURCHASE: Subscription of the token is forbidden now.",
    -13004 => "BLVT_EXCEED_DAILY_PURCHASE_LIMIT: Exceeds individual 24h subscription limit of the token.",
    -13005 => "BLVT_EXCEED_TOKEN_DAILY_PURCHASE_LIMIT: Exceeds total 24h subscription limit of the token.",
    -13006 => "BLVT_PURCHASE_LESS_MIN_AMOUNT: Subscription amount is too small.",
    -13007 => "BLVT_PURCHASE_AGREEMENT_NOT_SIGN: The Agreement is not signed.",

    # 18xxx - Binance Code
    -18002 => "CODE_LIMIT_24H: The total amount of codes created has exceeded the 24-hour limit.",
    -18003 => "TOO_MANY_CODES: Too many codes created in 24 hours.",
    -18004 => "TOO_MANY_REDEEM_ATTEMPTS: Too many invalid redeem attempts in 24 hours.",
    -18005 => "TOO_MANY_VERIFY_ATTEMPTS: Too many invalid verify attempts.",
    -18006 => "AMOUNT_TOO_SMALL: The amount is too small.",
    -18007 => "TOKEN_NOT_SUPPORTED: This token is not currently supported.",

    # 20xxx - Futures/Spot Algo
    -20121 => "INVALID_SYMBOL: Invalid symbol.",
    -20124 => "INVALID_ALGO_ID: Invalid algo id or it has been completed.",
    -20130 => "INVALID_DATA: Invalid data sent for a parameter.",
    -20132 => "DUPLICATE_CLIENT_ALGO_ID: The client algo id is duplicated.",
    -20194 => "DURATION_TOO_SHORT: Duration is too short to execute all required quantity.",
    -20195 => "TOTAL_SIZE_TOO_SMALL: The total size is too small.",
    -20196 => "TOTAL_SIZE_TOO_LARGE: The total size is too large.",
    -20198 => "MAX_OPEN_ORDERS_REACHED: Reach the max open orders allowed.",
    -20204 => "NOTIONAL_LIMIT: The notional of USD is less or more than the limit.",

    # 21xxx - Portfolio Margin Account
    -21001 => "USER_IS_NOT_UNIACCOUNT: Request ID is not a Portfolio Margin Account.",
    -21002 => "UNI_ACCOUNT_CANT_TRANSFER_FUTURE: Portfolio Margin Account doesn't support transfer from margin to futures.",
    -21003 => "NET_ASSET_MUST_LTE_RATIO: Fail to retrieve margin assets.",
    -21004 => "USER_NO_LIABILITY: User doesn't have portfolio margin bankruptcy loan.",
    -21005 => "NO_ENOUGH_ASSET: User's spot wallet doesn't have enough BUSD to repay portfolio margin bankruptcy loan.",
    -21006 => "HAD_IN_PROCESS_REPAY: User had portfolio margin bankruptcy loan repayment in process.",
    -21007 => "IN_FORCE_LIQUIDATION: User failed to repay portfolio margin bankruptcy loan since liquidation was in process.",
)

"""
Filter failure messages and their descriptions.
"""
const FILTER_FAILURES = Dict{String,String}(
    "PRICE_FILTER" => "Price is too high, too low, and/or not following the tick size rule for the symbol.",
    "PERCENT_PRICE" => "Price is X% too high or X% too low from the average weighted price.",
    "PERCENT_PRICE_BY_SIDE" => "Price is X% too high or Y% too low from the lastPrice on that side.",
    "LOT_SIZE" => "Quantity is too high, too low, and/or not following the step size rule for the symbol.",
    "MIN_NOTIONAL" => "price * quantity is too low to be a valid order for the symbol.",
    "NOTIONAL" => "price * quantity is not within range of the minNotional and maxNotional.",
    "ICEBERG_PARTS" => "ICEBERG order would break into too many parts; icebergQty is too small.",
    "MARKET_LOT_SIZE" => "MARKET order's quantity is too high, too low, and/or not following the step size rule.",
    "MAX_POSITION" => "The account's position has reached the maximum defined limit.",
    "MAX_NUM_ORDERS" => "Account has too many open orders on the symbol.",
    "MAX_NUM_ALGO_ORDERS" => "Account has too many open stop loss and/or take profit orders on the symbol.",
    "MAX_NUM_ICEBERG_ORDERS" => "Account has too many open iceberg orders on the symbol.",
    "MAX_NUM_ORDER_AMENDS" => "Account has made too many amendments to a single order on the symbol.",
    "MAX_NUM_ORDER_LISTS" => "Account has too many open order lists on the symbol.",
    "TRAILING_DELTA" => "trailingDelta is not within the defined range of the filter for that order type.",
    "EXCHANGE_MAX_NUM_ORDERS" => "Account has too many open orders on the exchange.",
    "EXCHANGE_MAX_NUM_ALGO_ORDERS" => "Account has too many open stop loss and/or take profit orders on the exchange.",
    "EXCHANGE_MAX_NUM_ICEBERG_ORDERS" => "Account has too many open iceberg orders on the exchange.",
    "EXCHANGE_MAX_NUM_ORDER_LISTS" => "Account has too many open order lists on the exchange.",
)

"""
    get_error_description(code::Int) -> String

Get a human-readable description for a Binance error code.

# Arguments
- `code::Int`: The Binance error code (negative integer)

# Returns
- `String`: Description of the error, or "Unknown error code" if not found

# Example
```julia
desc = get_error_description(-1121)  # "BAD_SYMBOL: Invalid symbol."
```
"""
function get_error_description(code::Int)
    return get(ERROR_CODES, code, "Unknown error code: $code")
end

"""
    get_filter_failure_description(filter_type::String) -> String

Get a description for a filter failure message.

# Arguments
- `filter_type::String`: The filter type (e.g., "PRICE_FILTER", "LOT_SIZE")

# Returns
- `String`: Description of the filter failure
"""
function get_filter_failure_description(filter_type::String)
    return get(FILTER_FAILURES, filter_type, "Unknown filter type: $filter_type")
end

# --- Custom Exception Types ---

abstract type BinanceException <: Exception end

struct BinanceError <: BinanceException
    http_status::Int
    code::Int
    msg::String
end

function Base.show(io::IO, e::BinanceError)
    desc = get_error_description(e.code)
    print(io, "BinanceError(http_status=$(e.http_status), code=$(e.code), msg=\"$(e.msg)\")\n  → $desc")
end

struct MalformedRequestError <: BinanceException
    code::Int
    msg::String
end

function Base.show(io::IO, e::MalformedRequestError)
    desc = get_error_description(e.code)
    print(io, "MalformedRequestError(code=$(e.code), msg=\"$(e.msg)\")\n  → $desc")
end

struct UnauthorizedError <: BinanceException
    code::Int
    msg::String
end

function Base.show(io::IO, e::UnauthorizedError)
    print(io, "UnauthorizedError(401): code=$(e.code), msg=\"$(e.msg)\")")
end

struct WAFViolationError <: BinanceException end
Base.show(io::IO, e::WAFViolationError) = print(io, "WAF Limit Violated (403)")

struct CancelReplacePartialSuccess <: BinanceException
    code::Int
    msg::String
end

function Base.show(io::IO, e::CancelReplacePartialSuccess)
    desc = get_error_description(e.code)
    print(io, "Cancel/Replace Partially Succeeded (409): code=$(e.code), msg=\"$(e.msg)\"\n  → $desc")
end

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
