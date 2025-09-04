# Binance (Spot) SDK 全功能开发任务清单

## 一、 核心与基础模块 (Core & Foundation)

- [ ] **基础配置 (Configuration)**
    - [ ] API Key / Secret Key 管理
    - [ ] Base URL 管理 (区分 `api/`, `sapi/` 等)
    - [ ] Base URL 切换 (主网 / 测试网)
    - [x] HTTP 请求客户端封装 (超时、代理、Keep-Alive等)
- [x] **架构重构 (Architecture Refactoring)**
    - [x] 将 REST API 逻辑分离到 `RESTClient.jl`
    - [x] 将行情数据流逻辑重命名并分离到 `MarketDataStreams.jl`
    - [x] 将交互式 WebSocket API 逻辑分离到 `WebSocketAPI.jl`
- [ ] **签名与安全 (Signing & Security)**
    - [x] `HMAC SHA256` 请求签名逻辑
    - [x] `RSA` 请求签名逻辑 (针对特定接口)
    - [x] `timestamp` 与 `recvWindow` 参数处理
- [ ] **错误处理与模型 (Error Handling & Models)**
    - [x] 统一的 API 异常类，包含错误码和消息
    - [ ] 定义所有接口的请求参数 (Request) 和响应数据 (Response) 模型
    - [ ] 日志系统 (Logging) 集成
- [ ] **常量与枚举 (Constants & Enums)**
    - [ ] 定义所有文档中提到的枚举值 (如订单状态、K线间隔、产品类型等)
- [ ] **过滤器逻辑 (Filters Logic)**
    - [ ] `exchangeInfo` 中过滤器规则的解析
    - [ ] (可选) 在下单前进行客户端验证 (如价格、数量、金额精度等)

---

## 二、 REST API

> 这是 SDK 的主体部分，包含了所有通过 HTTP 访问的功能。

### 1. 通用接口 (General Endpoints)

- [x] `ping()` - 测试服务器连通性 (`GET /api/v3/ping`)
- [x] `getServerTime()` - 获取服务器时间 (`GET /api/v3/time`)
- [x] `getExchangeInfo()` - 获取交易所规则与交易对信息 (`GET /api/v3/exchangeInfo`)
- [ ] `getSystemStatus()` - 获取系统状态 (`GET /sapi/v1/system/status`)

### 2. 行情接口 (Market Data Endpoints)

- [x] `getOrderBook()` - 获取订单簿 (`GET /api/v3/depth`)
- [x] `getRecentTrades()` - 获取近期成交 (`GET /api/v3/trades`)
- [x] `getHistoricalTrades()` - 获取历史成交 (`GET /api/v3/historicalTrades`)
- [x] `getAggregateTrades()` - 获取归集交易 (`GET /api/v3/aggTrades`)
- [x] `getKlines()` - 获取K线数据 (`GET /api/v3/klines`)
- [x] `getUiKlines()` - 获取UI友好的K线数据 (`GET /api/v3/uiKlines`)
- [x] `getAveragePrice()` - 获取平均价格 (`GET /api/v3/avgPrice`)
- [x] `get24hrTicker()` - 获取24小时价格变动 (`GET /api/v3/ticker/24hr`)
- [x] `getSymbolTicker()` - 获取交易对最新价 (`GET /api/v3/ticker/price`)
- [x] `getOrderBookTicker()` - 获取最优挂单价 (`GET /api/v3/ticker/bookTicker`)
- [x] `getRollingWindowTicker()` - 获取滚动窗口价格变动 (`GET /api/v3/ticker`)

### 3. 现货账户和交易 (Spot Account and Trade)

- [x] `createOrder()` - 下单 (`POST /api/v3/order`)
- [x] `createTestOrder()` - 测试下单 (`POST /api/v3/order/test`)
- [x] `getOrder()` - 查询订单 (`GET /api/v3/order`)
- [x] `cancelOrder()` - 撤销订单 (`DELETE /api/v3/order`)
- [x] `cancelAndReplaceOrder()` - 撤销并替换订单 (`POST /api/v3/order/cancelReplace`)
- [x] `getOpenOrders()` - 查询当前挂单 (`GET /api/v3/openOrders`)
- [x] `cancelAllOpenOrders()` - 撤销交易对的所有挂单 (`DELETE /api/v3/openOrders`)
- [x] `getAllOrders()` - 查询所有订单 (`GET /api/v3/allOrders`)
- [x] `createOcoOrder()` - 下OCO订单 (`POST /api/v3/order/oco`)
- [x] `cancelOcoOrder()` - 撤销OCO订单 (`DELETE /api/v3/orderList`)
- [x] `getOcoOrder()` - 查询OCO订单 (`GET /api/v3/orderList`)
- [x] `getAllOcoOrders()` - 查询所有OCO订单 (`GET /api/v3/allOrderList`)
- [x] `getOpenOcoOrders()` - 查询所有打开的OCO订单 (`GET /api/v3/openOrderList`)
- [x] `getAccountInfo()` - 查询账户信息 (`GET /api/v3/account`)
- [x] `getMyTrades()` - 查询账户成交历史 (`GET /api/v3/myTrades`)
- [x] `getOrderRateLimit()` - 查询当前下单数 (`GET /api/v3/rateLimit/order`)

### 4. 杠杆账户和交易 (Margin Account and Trade)

- [ ] `marginCrossTransfer()` - 资金划转(全仓) (`POST /sapi/v1/margin/transfer`)
- [ ] `marginLoan()` - 借款(全仓/逐仓) (`POST /sapi/v1/margin/loan`)
- [ ] `marginRepay()` - 归还借款(全仓/逐仓) (`POST /sapi/v1/margin/repay`)
- [ ] `getMarginAsset()` - 查询杠杆资产 (`GET /sapi/v1/margin/asset`)
- [ ] `getMarginPair()` - 查询杠杆交易对 (`GET /sapi/v1/margin/pair`)
- [ ] `getAllMarginAssets()` - 获取所有杠杆资产 (`GET /sapi/v1/margin/allAssets`)
- [ ] `getAllMarginPairs()` - 获取所有杠杆交易对 (`GET /sapi/v1/margin/allPairs`)
- [ ] `getMarginPriceIndex()` - 查询杠杆价格指数 (`GET /sapi/v1/margin/priceIndex`)
- [ ] `createMarginOrder()` - 杠杆账户下单 (`POST /sapi/v1/margin/order`)
- [ ] `cancelMarginOrder()` - 杠杆账户撤单 (`DELETE /sapi/v1/margin/order`)
- [ ] `cancelAllMarginOpenOrders()` - 撤销杠杆账户所有挂单 (`DELETE /sapi/v1/margin/openOrders`)
- [ ] `getMarginTransferHistory()` - 获取杠杆划转历史 (`GET /sapi/v1/margin/transfer`)
- [ ] `getMarginLoanHistory()` - 查询借款记录 (`GET /sapi/v1/margin/loan`)
- [ ] `getMarginRepayHistory()` - 查询还款记录 (`GET /sapi/v1/margin/repay`)
- [ ] `getMarginInterestHistory()` - 获取利息历史 (`GET /sapi/v1/margin/interestHistory`)
- [ ] `getMarginForceLiquidationHistory()` - 获取强制平仓记录 (`GET /sapi/v1/margin/forceLiquidationRec`)
- [ ] `getMarginAccountDetails()` - 查询杠杆账户详情 (`GET /sapi/v1/margin/account`)
- [ ] `getMarginOrder()` - 查询杠杆账户订单 (`GET /sapi/v1/margin/order`)
- [ ] `getMarginOpenOrders()` - 查询杠杆账户挂单 (`GET /sapi/v1/margin/openOrders`)
- [ ] `getAllMarginOrders()` - 查询杠杆账户所有订单 (`GET /sapi/v1/margin/allOrders`)
- [ ] `createMarginOcoOrder()` - 杠杆账户OCO下单 (`POST /sapi/v1/margin/order/oco`)
- [ ] `cancelMarginOcoOrder()` - 撤销杠杆OCO订单 (`DELETE /sapi/v1/margin/orderList`)
- [ ] `getMarginOcoOrder()` - 查询杠杆OCO订单 (`GET /sapi/v1/margin/orderList`)
- [ ] `getAllMarginOcoOrders()` - 查询所有杠杆OCO订单 (`GET /sapi/v1/margin/allOrderList`)
- [ ] `getOpenMarginOcoOrders()` - 查询打开的杠杆OCO订单 (`GET /sapi/v1/margin/openOrderList`)
- [ ] `getMarginMyTrades()` - 查询杠杆账户成交历史 (`GET /sapi/v1/margin/myTrades`)
- [ ] `getMarginMaxBorrowable()` - 查询最大可借 (`GET /sapi/v1/margin/maxBorrowable`)
- [ ] `getMarginMaxTransferable()` - 查询最大可转出额 (`GET /sapi/v1/margin/maxTransferable`)
- [ ] `getMarginIsolatedAccount()` - 查询逐仓杠杆账户信息 (`GET /sapi/v1/margin/isolated/account`)
- [ ] `marginIsolatedTransfer()` - 逐仓账户划转 (`POST /sapi/v1/margin/isolated/transfer`)
- [ ] `getMarginIsolatedTransferHistory()` - 获取逐仓划转历史 (`GET /sapi/v1/margin/isolated/transfer`)
- [ ] ... (以及其他所有杠杆相关接口)

### 5. 子母账户 (Sub-account)

- [ ] `createSubAccount()` - 创建子账户 (`POST /sapi/v1/sub-account/virtualSubAccount`)
- [ ] `getSubAccounts()` - 查询子账户列表 (`GET /sapi/v1/sub-account/list`)
- [ ] `getSubAccountSpotAssetTransferHistory()` - 查询子账户现货资产划转历史 (`GET /sapi/v1/sub-account/sub/transfer/history`)
- [ ] `getSubAccountFuturesAssetTransferHistory()` - 查询子账户合约资产划转历史 (`GET /sapi/v1/sub-account/futures/internalTransfer`)
- [ ] `subAccountFuturesAssetTransfer()` - 子账户合约资产划转 (`POST /sapi/v1/sub-account/futures/internalTransfer`)
- [ ] `getSubAccountAssets()` - 查询子账户资产 (`GET /sapi/v3/sub-account/assets`)
- [ ] ... (以及其他所有子母账户相关接口)

### 6. 其他 `SAPI` 模块

> 以下模块接口众多，这里仅列出代表，开发时需遍历文档补全。

- [ ] **资金 (Wallet)**
    - [ ] `getSystemStatus()` (`GET /sapi/v1/system/status`)
    - [ ] `getAllCoinsInfo()` (`GET /sapi/v1/capital/config/getall`)
    - [ ] `getDepositAddress()` (`GET /sapi/v1/capital/deposit/address`)
    - [ ] `getWithdrawHistory()` (`GET /sapi/v1/capital/withdraw/history`)
    - [ ] `getDepositHistory()` (`GET /sapi/v1/capital/deposit/hisrec`)
    - [ ] ...
- [ ] **理财 (Savings)**
    - [ ] `getFlexibleSavingsProducts()` (`GET /sapi/v1/lending/daily/product/list`)
    - [ ] `purchaseFlexibleSavingsProduct()` (`POST /sapi/v1/lending/daily/purchase`)
    - [ ] ...
- [ ] **矿池 (Mining)**
    - [ ] `getMiningAlgoList()` (`GET /sapi/v1/mining/pub/algoList`)
    - [ ] `getMiningCoinList()` (`GET /sapi/v1/mining/pub/coinList`)
    - [ ] ...
- [ ] **杠杆代币 (BLVT)**
    - [ ] `getBlvtInfo()` (`GET /sapi/v1/blvt/tokenInfo`)
    - [ ] `subscribeBlvt()` (`POST /sapi/v1/blvt/subscribe`)
    - [ ] ...
- [ ] **闪兑 (BSwap)**
    - [ ] `getBswapPools()` (`GET /sapi/v1/bswap/pools`)
    - [ ] `getBswapLiquidity()` (`GET /sapi/v1/bswap/liquidity`)
    - [ ] ...
- [ ] **法币 (Fiat)**
    - [ ] `getFiatOrderHistory()` (`GET /sapi/v1/fiat/orders`)
    - [ ] `getFiatPaymentHistory()` (`GET /sapi/v1/fiat/payments`)
- [ ] **C2C**
    - [ ] `getC2cTradeHistory()` (`GET /sapi/v1/c2c/orderMatch/listUserOrderHistory`)
- [ ] ... (以及**Staking**、**Futures**、**Portfolio Margin**、**Gift Card**、**Convert**、**Rebate**等所有SAPI接口)

---

## 三、 WebSocket 模块

### 1. WebSocket 行情流 (Market Streams)

- [x] **基础连接管理**
    - [x] 连接/断开/自动重连 (已实现基础版本)
    - [ ] 订阅/取消订阅/查询订阅 (通过发送 `SUBSCRIBE`/`UNSUBSCRIBE`/`LIST_SUBSCRIPTIONS` 消息)
    - [ ] Ping/Pong 自动处理
    - [ ] 正确处理组合流 (Combined Streams)
    - [ ] 属性管理 (`SET_PROPERTY`/`GET_PROPERTY`)
- [x] **数据流订阅实现**
    - [x] `aggTrade` - 归集交易
    - [x] `trade` - 实时成交
    - [x] `kline` - K线
    - [ ] `kline` with timezone offset - 带时区的K线
    - [x] `miniTicker` - 精简Ticker
    - [x] `!miniTicker@arr` - 所有市场精简Ticker
    - [x] `ticker` - 完整Ticker
    - [x] `!ticker@arr` - 所有市场完整Ticker
    - [x] `bookTicker` - 订单簿Ticker
    - [x] `!bookTicker@arr` - 所有市场订单簿Ticker
    - [x] `depth` - 深度信息 (有限档位/增量)
    - [x] `avgPrice` - 平均价格

### 2. 用户数据流 (User Data Stream)

- [ ] **Listen Key 管理 (通过REST API)**
    - [ ] `createSpotListenKey()` (`POST /api/v3/userDataStream`)
    - [ ] `keepAliveSpotListenKey()` (`PUT /api/v3/userDataStream`)
    - [ ] `closeSpotListenKey()` (`DELETE /api/v3/userDataStream`)
    - [ ] `createMarginListenKey()` (`POST /sapi/v1/userDataStream`)
    - [ ] `keepAliveMarginListenKey()` (`PUT /sapi/v1/userDataStream`)
    - [ ] `closeMarginListenKey()` (`DELETE /sapi/v1/userDataStream`)
    - [ ] `createIsolatedMarginListenKey()` (`POST /sapi/v1/userDataStream/isolated`)
    - [ ] ...
- [ ] **WebSocket 连接与数据解析**
    - [x] 连接用户数据流 WebSocket (已实现基础 `subscribe_user_data` 函数)
    - [ ] 定义 `outboundAccountPosition` 事件模型
    - [ ] 定义 `balanceUpdate` 事件模型
    - [ ] 定义 `executionReport` 事件模型 (订单更新)
    - [ ] 定义 `listStatus` 事件模型 (OCO订单更新)
    - [ ] 实现自动解析不同用户事件

### 3. WebSocket API (交互式) ⭐ **95% 完成**

- [x] **基础框架**
    - [x] 建立到 `ws-api.binance.com` 的持久化连接
    - [x] 实现请求 `id` 管理与响应匹配机制
    - [x] 实现请求签名 (HMAC, RSA, Ed25519)
    - [x] 统一的请求发送与响应接收逻辑
    - [x] Ping/Pong 自动处理
    - [x] 速率限制处理 (Rate Limit Handling)
    - [x] 事件回调机制 (Event Callback Mechanism)
- [x] **会话管理 (Session Management)**
    - [x] `session.logon` - 登录并验证会话
    - [x] `session.status` - 查询会话状态
    - [x] `session.logout` - 退出会话
- [x] **通用请求 (General)**
    - [x] `ping` - 测试服务器连通性
    - [x] `time` - 获取服务器时间
    - [x] `exchangeInfo` - 获取交易所规则
- [x] **行情数据请求 (Market Data)**
    - [x] `depth` - 获取订单簿
    - [x] `trades.recent` - 获取近期成交
    - [x] `trades.historical` - 获取历史成交
    - [x] `trades.aggregate` - 获取归集交易
    - [x] `klines` - 获取K线数据
    - [x] `uiKlines` - 获取UI友好的K线数据
    - [x] `avgPrice` - 获取平均价格
    - [x] `ticker.24hr` - 获取24小时价格变动
    - [x] `ticker` - 获取滚动窗口价格变动
    - [x] `ticker.price` - 获取交易对最新价
    - [x] `ticker.book` - 获取最优挂单价
- [x] **交易请求 (需鉴权 - Trading)** ⭐ **100% 完成**
    - [x] `place_order` - 下单
    - [x] `test_order` - 测试下单
    - [x] `order_status` - 查询订单
    - [x] `cancel_order` - 撤销订单
    - [x] `cancel_replace_order` - 撤销并替换订单
    - [x] `amend_order` - 修改订单保持优先级
    - [x] `cancel_all_orders` - 取消所有开放订单
- [x] **订单列表请求 (Order Lists)** ⭐ **100% 完成**
    - [x] `place_oco_order` - 下OCO订单
    - [x] `place_oto_order` - 下OTO订单
    - [x] `place_otoco_order` - 下OTOCO订单
    - [x] `cancel_order_list` - 取消订单列表
- [x] **SOR请求 (Smart Order Routing)** ⭐ **100% 完成**
    - [x] `place_sor_order` - SOR下单
    - [x] `test_sor_order` - SOR测试下单
- [x] **账户请求 (需鉴权 - Account)** ⭐ **100% 完成**
    - [x] `account_status` - 查询账户信息
    - [x] `account_rate_limits_orders` - 查询当前下单数
    - [x] `account_commission` - 查询手续费率
    - [x] `orders_open` - 查询当前挂单
    - [x] `orders_all` - 查询所有订单
    - [x] `open_orders_status` - 查询当前挂单状态
    - [x] `all_orders` - 查询账户订单历史
    - [x] `order_list_status` - 查询订单列表
    - [x] `open_order_lists_status` - 查询当前开放订单列表
    - [x] `all_order_lists` - 查询账户订单列表历史
    - [x] `my_trades` - 查询账户成交历史
    - [x] `my_prevented_matches` - 查询账户阻止匹配
    - [x] `my_allocations` - 查询账户分配
    - [x] `order_amendments` - 查询订单修改
- [x] **用户数据流 (需鉴权 - User Data Stream)** ⭐ **100% 完成**
    - [x] `user_data_stream_start` - 开启用户数据流
    - [x] `user_data_stream_ping` - 刷新用户数据流 (Keep-alive)
    - [x] `user_data_stream_stop` - 关闭用户数据流
    - [x] `userdata_stream_subscribe` - 订阅用户数据流
    - [x] `userdata_stream_unsubscribe` - 取消订阅用户数据流
    - [x] `session_subscriptions` - 列出所有订阅
    - [x] `userdata_stream_subscribe_signature` - 签名方式订阅用户数据流
