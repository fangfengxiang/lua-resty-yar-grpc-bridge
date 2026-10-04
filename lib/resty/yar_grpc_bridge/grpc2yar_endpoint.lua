-- lib/resty/yar_grpc_bridge/grpc2yar_endpoint.lua
-- gRPC → YAR 方向 OpenResty HTTP 入口（Category 2：HTTP 框架绑定 I/O）
--
-- 从 init.lua 拆出（overview-5 职责拆分）：serve() 读 body / 解析 path / 输出 gRPC 响应，
-- send_error / send_ok 写 ngx.header / ngx.var / ngx.exit —— 均为 HTTP 框架绑定 I/O，
-- 天然属于入口层，不应混在包门面 init.lua 中。
--
-- 配置解析（resolve_service_config）与请求体上限（max_payload_bytes）由门面 init.lua
-- 持有（setup() 时填充），本模块通过 facade 访问器运行时读取，不在入口层重复存储。
--
-- 编排（client 创建 / hooks / 调用管线）在 grpc2yar.lua，本入口只做 HTTP I/O + 编排调用。

local ngx = ngx
local codec = require("yar_grpc.codec")
local errors = require("yar_grpc.errors")
local grpc_converter = require("yar_grpc.grpc_converter")
local core_deadline = require("yar_grpc.deadline")
local host = require("resty.yar_grpc_bridge.host")
local trace = require("resty.yar_grpc_bridge.trace")
local bridge = require("resty.yar_grpc_bridge.grpc2yar")
-- 门面 init.lua 持有 setup() 填充的配置状态（resolve_service_config / max_payload_bytes）。
-- init.lua 的 serve() 用惰性委托 require 本模块，不在模块加载期触发反向 require，故无加载循环；
-- 此处模块级 require 安全（grpc2yar_endpoint 若被直接 require，init.lua 会先完整加载再返回）。
local facade = require("resty.yar_grpc_bridge")

---@class yar_grpc_bridge.grpc2yar_endpoint
local _M = {}

--- 发送 gRPC 错误响应
-- trailers-only 响应（无 body）：grpc-status 放在 HEADERS frame 中
-- grpc-status/grpc-message 通过 nginx add_trailer + $grpc_status 变量发送
-- 统一写 host.ctx.grpc_status，调用方无需再手动赋值（收口）
---@param status integer gRPC 状态码
---@param message? string grpc-message
local function send_error(status, message)
    host.ctx.grpc_status = status
    -- 错误响应无 body：grpc-status 直接写 leading response header（符合 gRPC 规范——
    -- 错误响应的 grpc-status 在 HEADERS frame 带 END_STREAM）。
    -- 同时设 ngx.var 供 nginx add_trailer 指令兼容（若部署用 HTTP/2 trailer 方式）。
    -- 注：ngx.location.capture 子请求的 res.header 不含 add_header 指令的 header，
    -- 必须用 ngx.header 直接设才能被 capture 读取（测试依赖此路径）。
    ngx.header["grpc-status"] = tostring(status)
    ngx.header["grpc-message"] = message or ""
    ngx.var.grpc_status = tostring(status)
    ngx.var.grpc_message = message or ""
    ngx.header["content-type"] = "application/grpc"
    ngx.status = ngx.HTTP_OK
    return ngx.exit(ngx.HTTP_OK)
end
_M.send_error = send_error

--- 发送 gRPC 成功响应
-- gRPC 成功响应布局：Headers(content-type, grpc-status=0) → DATA(gRPC frame) → Trailers(grpc-status=0)
-- grpc-status 规范上在 trailers，但 ngx.location.capture 子请求的 res.header 不含 add_header/
-- add_trailer 指令的 header（OpenResty 限制）。为让 capture 测试能读取 grpc-status，
-- 此处同时用 ngx.header 设 leading header；生产 HTTP/2 的 trailer 由 nginx add_trailer 指令 +
-- ngx.var.grpc_status 输出（部署时配置）。统一写 host.ctx.grpc_status = 0（收口）。
---@param frame string 完整的 gRPC 帧（已由 codec.encode_frame 编码）
local function send_ok(frame)
    host.ctx.grpc_status = errors.OK
    ngx.header["grpc-status"] = "0"
    ngx.header["grpc-message"] = ""
    ngx.var.grpc_status = "0"
    ngx.var.grpc_message = ""
    ngx.header["content-type"] = "application/grpc"
    ngx.status = ngx.HTTP_OK
    ngx.print(frame)
    return ngx.exit(ngx.HTTP_OK)
end
_M.send_ok = send_ok

--- 处理单个 gRPC 请求（在 content_by_lua_block 中调用）
-- 读取请求体 → 解析 gRPC 帧 → 检测流式 → 解析 path → 查 services → bridge.handle → 输出响应
---@return nil
function _M.serve()
    -- 0. 记录请求开始时间，解析 deadline
    local request_start = host.now()
    local deadline_ms = core_deadline.parse_timeout(host.var.http_grpc_timeout)
    host.ctx.request_start = request_start
    host.ctx.grpc_deadline_ms = deadline_ms

    -- 0a. 生成/提取请求 ID（委托给 trace 模块，消除内联重复）
    trace.ensure_request_id("x-request-id")

    -- 0b. 前置 deadline 检查（核心 check_expired 接受注入的 now，运行时无关）
    if core_deadline.check_expired(deadline_ms, request_start, host.now()) then
        send_error(errors.DEADLINE_EXCEEDED, "deadline already exceeded")
        return
    end

    local max_payload_bytes = facade.get_max_payload_bytes()

    -- 1. Content-Length 预检（P0-4，DoS 防护：超限不产生读 I/O）
    local content_length = tonumber(host.var.http_content_length)
    if content_length and content_length > max_payload_bytes then
        send_error(errors.RESOURCE_EXHAUSTED, "request body too large")
        return
    end

    -- 2. 读取请求体
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        -- 请求体可能被写入临时文件（body spill）
        local file = ngx.req.get_body_file()
        if file then
            host.log(host.LOG_WARN, "request body spilled to disk: " .. file)
            -- 先查文件大小，超限不读入内存（P0-4 兜底防线）
            local f = io.open(file, "rb")
            if f then
                f:seek("end")
                local fsize = f:seek("cur")
                f:seek("set")
                if fsize > max_payload_bytes then
                    f:close()
                    send_error(errors.RESOURCE_EXHAUSTED, "request body too large")
                    return
                end
                body = f:read("*a")
                f:close()
            end
        end
    end

    -- 2b. 内存 body 超限检查（file spill 路径已在上面检查 fsize；
    --     Content-Length 预检对子请求/缺 header 的请求无效，此处为兜底防线）
    if body and #body > max_payload_bytes then
        send_error(errors.RESOURCE_EXHAUSTED, "request body too large")
        return
    end

    -- 3. 解析 gRPC 帧
    local flag, payload, frame_size, err = codec.decode_frame(body)
    if not flag then
        send_error(errors.INVALID_ARGUMENT, err)
        return
    end

    -- 4. 压缩标志检查
    if flag ~= codec.COMPRESSION_NONE then
        send_error(errors.UNIMPLEMENTED, "compression not supported")
        return
    end

    -- 5. 流式模式检测（多帧 = streaming）
    if codec.has_multiple_frames(body, frame_size) then
        send_error(errors.UNIMPLEMENTED, "streaming mode not supported")
        return
    end

    -- 6. 解析 gRPC path
    local path = host.var.uri
    local service, method, perr = grpc_converter.parse_grpc_path(path)
    if not service then
        send_error(errors.INVALID_ARGUMENT, perr)
        return
    end

    -- 写入请求元数据到 host.ctx（供 log_by_lua 阶段读取）
    host.ctx.grpc_service = service
    host.ctx.grpc_method = method

    -- 7. 查 services（配置解析由门面 init.lua 持有）
    local url, svc_opts = facade.resolve_service_config(service)
    if not url then
        send_error(errors.NOT_FOUND, "service not found: " .. service)
        return
    end

    -- 8. 调用 bridge.handle（完整管线，pcall 防止未预期异常逃逸）
    local ok, response_payload, status, errmsg = pcall(bridge.handle, service, method, payload, {
        url = url,
        options = svc_opts,
    })
    if not ok then
        send_error(errors.INTERNAL, "uncaught error: " .. tostring(response_payload))
        return
    end

    if not response_payload then
        send_error(status or errors.INTERNAL, errmsg)
        return
    end

    -- 8a. 后置 deadline 检查（核心 check_expired，now 注入）
    if core_deadline.check_expired(deadline_ms, request_start, host.now()) then
        send_error(errors.DEADLINE_EXCEEDED, "deadline exceeded after call")
        return
    end

    -- 9. 输出成功响应
    local frame = codec.encode_frame(response_payload)
    send_ok(frame)
end

return _M
