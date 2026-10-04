# 总体架构决策

## overview-1: 2 阶段架构（content + log）

**状态：** 已采纳

**决策驱动因素：** 桥接库无插件系统，Kong 式 5 阶段（rewrite/access/content/header_filter/log）是过度工程。

**背景：** 原提案 `adapt-yar-v010-phased-loading` 设计了 5 阶段拆分，参考 Kong Gateway。但 Kong 的多阶段因插件系统而生——不同插件在不同阶段执行。桥接库没有插件，5 阶段拆分带来维护复杂度和文档负担。

**思考与取舍：**
- 保留 `serve()` 在 `content_by_lua`，新增 `log_phase()` 在 `log_by_lua`
- `serve()` 内部用 `ngx.ctx` 存储元数据（service、method、status、latency）
- `log_phase()` 从 `ngx.ctx` 读取元数据，异步执行日志/指标
- 用户只需在 nginx 配置中加一行 `log_by_lua_block`，迁移成本最低

**业界参考：** Kong 的"将副作用推到 log 阶段"是直接可用的；但"插件化一切"对桥接库是反模式。

## overview-2: 模块化分层

**状态：** 已采纳

**决策驱动因素：** 关注点分离，每层可独立测试。

**背景：** 桥接需要处理 gRPC 帧编解码、YAR 协议桥接、错误映射、deadline、熔断、可观测性等多个关注点。

**思考与取舍：**
- `codec.lua` — gRPC 帧编解码（纯函数，无状态）
- `grpc2yar.lua` — YAR 协议桥接（protobuf ↔ YAR 转换）
- `errors.lua` — gRPC 状态码映射
- `deadline.lua` — gRPC deadline 解析与检查
- `trace.lua` — 请求 ID 管理 + 错误状态（入口本职观测）
- `init.lua` — Facade，组装各层

**业界参考：** lua-resty-http 的分层（http.lua + http_headers.lua + http_const.lua）。

## overview-3: persistent Client 模式

**状态：** 已采纳

**决策驱动因素：** 连接复用，避免每请求创建新 TCP 连接。

**背景：** lua-yar 0.1.0 支持 `transport.persistent = true`，缓存 `_transport` 实例。

**思考与取舍：**
- 按 service 名缓存 YAR Client 实例
- persistent 模式下无法 per-request `set_options`，deadline 只能做前后检查
- 连接失败时 lua-yar 自动清 nil 重建

**业界参考：** lua-resty-redis 的 `set_keepalive` 连接池模式。

## overview-4: hooks 驱动的横切关注点

**状态：** 已采纳

**决策驱动因素：** 可观测性不侵入核心桥接逻辑。

**背景：** lua-yar 0.1.0 提供 `hooks = { on_request, on_response }` 接口，pcall 保护。

**思考与取舍：**
- 内置 hooks（恒开，入口本职）：收集 yar_call_latency / yar_error_code 到 `ngx.ctx`，供 `log_phase` 读取
- 用户 hooks 透传：`set_hooks(opts.hooks)` 对齐 lua-yar `opts.hooks`，pcall 隔离
- hooks 引用 `ngx.ctx` 全局 table，per-request 自动隔离，persistent 复用安全

**业界参考：** grpc-gateway 的 middleware/interceptor 注入模式；lua-yar `opts.hooks` 透传。

## overview-5: 按职责拆分入口文件（包入口 / 编排 / OpenResty HTTP 入口）

- **状态**：已采纳（待实施）
- **决策驱动因素**：关注点分离、可独立测试、宿主迁移前置
- **关联决策**：overview-2（模块化分层）、overview-6（编排不下沉 lua-yar-grpc）

### 背景

现状两个入口文件职责混合：

- `init.lua` 同时承担"包门面"（VERSION / setup / log_phase / 配置解析 / resolve_service_config）与"grpc2yar OpenResty HTTP 入口"（serve 读 body + 解析 path + 输出响应、send_error / send_ok 写 grpc-status trailer）。前者是包入口职责，后者是 HTTP 框架绑定 I/O（Category 2）。
- `yar2grpc.lua` 同时承担"编排"（setup 构建 proxy service、_dispatch 的 encode→transport→decode 编排、set_grpc_transport 注入）与"OpenResty HTTP 入口"（handle 读 `ngx.var.service_name`、`ngx.req.read_body`、`Yar.server:handle` 的 writer 回调直接写 `ngx.status/header/print`）。

单文件混合多职责阻碍宿主迁移（Category 2 I/O 与编排耦合在一起无法单独替换）与独立测试（编排逻辑无法脱离 HTTP I/O 单测）。

### 思考与取舍

> "Separation of concerns." — Edsger Dijkstra
> "关注点分离。" — Edsger Dijkstra

拆分方向按三职责切分：

- `init.lua` 收敛为纯包门面：setup() 配置加载 + log_phase() + 公共常量/映射。serve() 及 send_error/send_ok（HTTP I/O）移出到 grpc2yar 专用入口文件。
- `grpc2yar.lua` 现状已较接近"编排层"定位（handle / get_client / build_hooks），明确其职责为"编排"，不再兼 HTTP 入口。
- `yar2grpc.lua` 拆为编排（setup / _dispatch / set_grpc_transport）与 HTTP 入口（handle）两文件。

拆分后三职责清晰：包入口（配置/生命周期）、编排（client/transport 编排，宿主无关但运行时相关）、HTTP 入口（Category 2 I/O，宿主绑定）。

当前 `init.lua` / `yar2grpc.lua` 仍为混合形态，重构待后续迭代；此决策先锁定拆分方向，避免后续改动继续往混合文件里堆。

### 业界参考

- **lua-resty-http**：`http.lua`（client 编排）与入口用法分离，模块边界清晰。
- **Kong Gateway**：`kong.run`（入口执行）与 plugin handler（编排逻辑）分层，入口不混编排。
- **nginx upstream**：入口处理与 LB 编排分离到不同模块。

### 代码评价

`init.lua:300-417` serve()、`init.lua:110-143` send_error/send_ok 为 grpc2yar HTTP 入口职责；`yar2grpc.lua:134-200` handle() 为 HTTP 入口职责（`ngx.var.service_name` 于 142、`ngx.req.read_body` 于 161、`server:handle` writer 回调于 179-189）。`grpc2yar.lua:138-166` handle() 与 `yar2grpc.lua:98-128` _dispatch() 为编排职责。`init.lua:160-268` setup() 与 `:423-442` log_phase() 为包门面职责。

### 知识领域

1. *The Mythical Man-Month*（Fred Brooks）— 模块化与职责分离的工程价值
2. *Clean Architecture*（Robert C. Martin）— 关注点分离与层次边界

## overview-6: 编排层不下沉 lua-yar-grpc

- **状态**：已采纳
- **决策驱动因素**：依赖方向约束、纯协议库定位、层次不可倒置
- **关联决策**：overview-2（模块化分层）、overview-5（入口职责拆分）

### 背景

grpc2yar.handle / yar2grpc._dispatch 瘦身（解耦 host.ctx 为 observer 注入）后可成宿主无关。是否进一步下沉到 `lua-yar-grpc`（与 codec / converter 同库）被反复讨论。`lua-yar-grpc` 定位为纯协议转换库（`init.lua:19` 注释"纯函数，运行时无关"），对标 dkjson。

### 思考与取舍

> "Keep dependencies pointing in the direction of increasing stability." — Robert C. Martin
> "让依赖指向稳定性递增的方向。" — Robert C. Martin

三层理由，依赖方向为最硬约束。

1. **定位层** — 编排即使宿主无关仍是有状态运行时逻辑：`grpc2yar.lua:21` `_client_cache` per-worker 可变状态、`client:call()` / `_grpc_transport()` 发起网络 I/O、`build_hooks` 运行时回调组装。纯函数库管字节↔语义转换，不管 client 生命周期 / 连接复用 / 调用流程。对标 dkjson / lua-MessagePack——纯编解码无 client。

2. **依赖方向层（最硬）** — `grpc2yar.handle` require `lua-yar` 的 `Yar.client.new` / `client:call` + persistent 缓存；`yar2grpc._dispatch` / handle require `lua-yar` 的 `Yar.error.*` / `Yar.server.new`。一旦下沉，`lua-yar-grpc` 必须 require `lua-yar` 的运行时 client API。现状依赖链为 `bridge → lua-yar-grpc(协议) & lua-yar(client)`，二者平级、互不依赖；下沉后变为 `lua-yar-grpc → lua-yar`，协议层反向依赖运行时层，层次倒置，违反稳定依赖原则（稳定层不应依赖易变层）。后果：只想用协议转换的消费者被迫拖入 `lua-yar` 依赖；`lua-yar-grpc` 单独演进受 `lua-yar` client API 变化牵制；平级协议资产关系被打破。

3. **概念层** — "宿主无关"≠"协议层"。协议转换宿主无关且运行时无关（纯函数）；编排宿主无关但运行时相关（有状态 + I/O 副作用，依赖 client + transport + observer）。编排属"运行时编排层"，介于协议层与入口层之间，不应与纯协议层同居。

编排归属：留在 bridge 仓库的 `grpc2yar.lua` / `yar2grpc.lua`（配合 overview-5 职责拆分瘦身）。bridge 定位对标 `lua-resty-http`：协议（外部 `lua-yar-grpc`）+ 编排（自身）+ OpenResty 入口（自身）同库，为 Lua 生态惯例。

例外：仅当 yar-group 决定把 `lua-yar-grpc` 定位从"纯协议转换库"升级为"YAR-gRPC RPC 框架"（对标 grpc-go，codec + ClientConn + transport 同包）时，编排可进——但那是一次定位重构（重定义依赖/发布/边界），不是"宿主无关即顺手放入"。当前无此诉求，不为此升级底层定位。

### 业界参考

- **dkjson**（David Kolf）：纯 JSON 编解码库，无 client/transport，对标 `lua-yar-grpc` 定位。
- **lua-MessagePack**：纯编解码，不涉运行时调用流程。
- **grpc-go**：定位为完整 RPC 框架，codec + ClientConn + transport 同包——属另一种定位，非 `lua-yar-grpc` 当前定位。
- **lua-resty-http**：协议（HTTP 解析）+ client 编排 + OpenResty 入口同库，对标 bridge 定位。

### 代码评价

`grpc2yar.lua:10` require("yar")、`:21` `_client_cache`、`:99` `Yar.client.new`、`:153` `client:call`；`yar2grpc.lua:20` require("yar")、`:30-34` `Yar.error.*` 常量、`:175` `Yar.server.new`。`init.lua:19-25` 对 `lua-yar-grpc` 各纯协议模块（codec/errors/grpc_converter/pb_converter/deadline/forward/reverse）的 require 证明其当前职责为协议转换。

### 知识领域

1. *Clean Architecture*（Robert C. Martin）— 依赖规则与稳定依赖原则
2. *A Philosophy of Software Design*（John Ousterhout）— 模块职责边界与 deep modules
