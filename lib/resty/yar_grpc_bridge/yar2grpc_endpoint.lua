-- lib/resty/yar_grpc_bridge/yar2grpc_endpoint.lua
-- YAR → gRPC 方向 OpenResty HTTP 入口（Category 2：HTTP 框架绑定 I/O）
--
-- 从 yar2grpc.lua 拆出（overview-5 职责拆分）：handle() 读 ngx.var.service_name /
-- ngx.req.get_body_data / 写 ngx.status/header/print —— 均为 HTTP 框架绑定 I/O，
-- 天然属于入口层，不应与编排（setup/_dispatch/set_grpc_transport）同居。
--
-- 编排（proxy service 注册表 / _dispatch / grpc_transport 注入）在 yar2grpc.lua，
-- 本入口通过 yar2grpc.get_proxy(service_name) 运行时取已注册的 proxy 子表，
-- 再交给 lua-yar Server 的 {method, data, writer} HTTP 模式解析 YAR 协议并分发。

local ngx = ngx
local Yar = require("yar")
local yar2grpc = require("resty.yar_grpc_bridge.yar2grpc")

---@class yar_grpc_bridge.yar2grpc_endpoint
local _M = {}

--- 处理 YAR 请求（在 content_by_lua_block 中调用）
-- 利用 Yar Server 的 HTTP 模式解析 YAR 协议 + 分发到 proxy service
---@return string|nil yar_response YAR 协议响应体
---@return string|nil err 错误信息
function _M.handle()
    -- 前置校验：transport 未注入则 fast-fail（不读 body，对齐原 yar2grpc.handle 守卫）
    if not yar2grpc.has_transport() then
        return nil, "grpc transport not injected, call set_grpc_transport() first"
    end

    -- service 名由 nginx location 的 named capture `service_name` 提取（声明式解析），
    -- 部署方在 nginx 配置里决定 path 前缀规则；lua 端只消费 ngx.var.service_name。
    -- 拿不到（location 未配 capture 或直接调用）直接报错，不做 yar→pb。
    local service_name = ngx.var.service_name
    if not service_name or service_name == "" then
        ngx.status = ngx.HTTP_BAD_REQUEST
        ngx.header["Content-Type"] = "text/plain"
        ngx.say(
            "yar2grpc: service_name nginx variable not set; configure location with named capture (?<service_name>...)"
        )
        return
    end
    local proxy = yar2grpc.get_proxy(service_name)
    if not proxy then
        ngx.status = ngx.HTTP_NOT_FOUND
        ngx.header["Content-Type"] = "text/plain"
        ngx.say("yar2grpc: service not registered: " .. service_name)
        return
    end

    -- 确保 body 已读取（含 disk spill 处理，对标 grpc2yar_endpoint serve() 的 body file 回退）
    -- 当请求体超过 client_body_buffer_size 时 get_body_data() 返回 nil，数据写入临时文件
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        local file = ngx.req.get_body_file()
        if file then
            local f = io.open(file, "rb")
            if f then
                body = f:read("*a")
                f:close()
            end
        end
    end

    -- 用该 service 的 proxy 子表创建 Yar Server（纯 method 查子表，多 service 互不冲突）
    local server = Yar.server.new(proxy)

    -- HTTP 模式：{method, data, writer}
    -- server:handle 返回 true|nil, err，检查返回值不再吞掉错误
    local ok, herr = server:handle({
        method = ngx.req.get_method(),
        data = body or "",
        writer = function(status, headers, response_body)
            ngx.status = status
            for k, v in pairs(headers or {}) do
                ngx.header[k] = v
            end
            ngx.print(response_body or "")
        end,
    })

    if not ok then
        -- server:handle 返回 nil, err：输出 HTTP 500 给客户端
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.header["content-type"] = "text/plain"
        ngx.print("yar server error: " .. tostring(herr))
        return nil, tostring(herr)
    end

    return true
end

return _M
