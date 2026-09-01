# JSON3 → JSON.jl 1.x 迁移设计

分支 `json-migration`，目标版本 0.13.0。本文件是迁移期的工作记录，合并前删除。

## 为什么迁移

JSON3.jl 已标记 `[deprecated]`（不再有新功能，仍可用）。JSON.jl 1.0 吸收了 JSON3
的设计并改用 StructUtils.jl。实测在对象形状的响应上有实质收益：

```
myTrades 1000 条 → Vector{Trade}
  JSON3 + 手写 construct   2.004 ms   3308.5 KiB   15039 allocs
  JSON.jl + 字段 tag       0.934 ms    529.9 KiB    9449 allocs
  → 2.15x 更快，内存省 6.24x
```

数组形状（Kline）速度持平、内存省 1.89x。收益来源是 `JSON3.read` 会先建完整的
二进制中间表示，而 `JSON.parse` 直接填结构体字段。

## 三个已验证的关键结论

### 1. `StructUtils.lift` 的 3 参数版必须返回 `(value, state)` 元组

上一轮我判断「`make` 不走字段级 lift、迁移必须合并成一阶段」——**这个判断是错的**。
真正的原因是我把 `lift(style, T, x)` 写成返回裸值，下游于是把 `DateTime` 当可迭代
对象，报出误导性的 `MethodError: no method matching iterate(::DateTime)`。

```julia
# 错
StructUtils.lift(::BinanceStyle, ::Type{DateTime}, x::Number) = unix2datetime(x/1000)
# 对
StructUtils.lift(s::BinanceStyle, ::Type{DateTime}, x::Number) =
    (unix2datetime(x/1000), StructUtils.defaultstate(s))
```

修正后 `StructUtils.make` 与 `JSON.parse` 两条路径都通。**这意味着不必改动
`make_request` 的返回契约**，两阶段架构（材料化 → `to_struct`）可以保留，
迁移风险大幅下降。

### 2. 字段级 tag 优于自定义 style

`@tags` 的字段 tag 走的是 `lift(st, T, x, tags)` 分支（StructUtils.jl:588），
四条路径全通且无类型污染：

```
                make(JSON3.Obj)  make(JSON.Obj)  make(Dict)  parse(raw)
对象形状+DateTime      OK              OK            OK          OK
嵌套数组形状           OK              OK            OK          OK
默认值+多态数组        OK              OK           FAIL*        OK
12 元素数组            OK              OK            OK          OK
```
\* `dicttype=Dict` 时多态数组失败，项目不用这个模式，不影响。

自定义 `style` 方案被否决：数组形状类型需要 `structlike=false`，这与 JSON.jl 内部的
`structlike(::JSONReadStyle{O,N,S<:JSONStyle}, ::Type{T})` 转发方法产生歧义：

```
MethodError: structlike(::JSON.JSONReadStyle{...,BinanceStyle}, ::Type{PriceLevel}) is ambiguous
```
补更特化的方法只会把歧义推到 `lift` 上。`@nonstruct` 宏同样触发。

不采用全局 `StructUtils.lift(::Type{DateTime}, ::Number)`：那是 type piracy，
会让所有第三方包的 `DateTime` 字段都按 unix 毫秒解析。已验证字段 tag 方案下
隔离性成立——未标注的类型仍正确拒绝 unix 毫秒、正常接受 ISO 字符串。

### 3. 迁移期可用桥接让两套声明共存

```julia
@inline function to_struct(::Type{T}, value) where {T}
    st = StructTypes.StructType(T)
    return st isa StructTypes.CustomStruct ?
        StructTypes.construct(T, value) :   # 未迁移
        StructUtils.make(T, value)          # 已迁移
end
```
已迁移类型删掉 `StructType` 声明后落到 `UnorderedStruct()`，自动走新路径。
因此可以逐文件迁移，每步都保持 `Pkg.test()` 绿。

## 各模式的迁移对照

| 原 StructTypes 写法 | 数量 | JSON.jl 写法 |
|---|---|---|
| `StructType(T) = Struct()` | 33 | 删声明，自动识别 |
| `CustomStruct` + obj + DateTime | 18 | `@tags` + `&(lift = x -> unix2datetime(x/1000),)` |
| `CustomStruct` + 缩写 key | 2 | `@tags` + `&(name="E", lift=..., lower=...)` |
| `CustomStruct` + 数组形状 | 2 | `@nonstruct` + `StructUtils.lift(::Type{T}, x)` |
| `AbstractType` + `subtypekey` | 1 | `JSON.@choosetype`，判别函数需兼容 lazy 与已材料化 |
| `Mutable` + `defaults` | 1 | `@defaults mutable struct` |
| `construct(OrderStatus, str)` | 4 | 默认支持，零声明 |
| `JSON3.write(x)` | 15 | `JSON.json(x)` |
| `JSON3.read(bytes)` | 11 | `JSON.parse(bytes)` |

### 两个语法陷阱

字段 tag 必须是**字面** NamedTuple，宏在 lowering 期解析，不能引用 `const` 变量：
```julia
const _MS = (lift = x -> unix2datetime(x/1000),)
time::DateTime &_MS        # LoadError: FieldExpr
```

`@choosetype` 的判别函数在 `JSON.parse` 下收到 `LazyValue`（需 `x.k[]`），在
`make` 下收到已材料化对象（`x.k` 已是值）。写成兼容形式：
```julia
_ft(x) = (v = x.filterType; v isa AbstractString ? v : v[])
```

## 不迁移的部分

`LazyValue` 缺 `haskey` / `keys` / `iterate`，且 `isa AbstractDict` 为 `false`。
项目有 30 处 `return make_request(...)` 直接把未类型化对象交给用户，`WebSocketAPI.jl`
内部也有 `haskey(data, :id)`、`data.event isa JSON3.Object` 判断。因此
`make_request` 继续返回**材料化**结果（`JSON.parse`，`JSON.Object` 支持全部这些操作），
不改用 `JSON.lazy`。

## 迁移顺序

1. 加 JSON + StructUtils 依赖，`to_struct` 加桥接，补反序列化回归测试（当前覆盖不足）
2. `src/Types.jl`（38 处声明，最大头）
3. `src/Events.jl`（9 处）
4. `src/Account.jl`（10 处）、`src/Convert.jl`（9 处）
5. `JSON3.read` / `JSON3.write` 调用点（26 处）
6. 移除 JSON3 + StructTypes 依赖，更新 CHANGELOG / README，合并
