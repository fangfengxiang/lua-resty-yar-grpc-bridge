-- lib/resty/yar_grpc_bridge/init.lua
-- lua-resty-yar-grpc-bridge: gRPC → YAR 协议代理 OPM 包入口（门面）
--
-- 在 init_by_lua_block 阶段调用 setup(opts) 一次，完成：
--   1. 加载预编译 .pb 二进制描述符（pb.load）
--   2. 存储 services（服务名 → { proto, url, options }）
--   3. 注入 cosocket（Yar.client.set_socket(ngx.socket)）
--   4. 配置 YAR 默认选项
--
-- HTTP 入口 serve() 已拆出到 grpc2yar_endpoint.lua（overview-5：包门面不混 HTTP I/O）。
--   content_by_lua_block 调 require("resty.yar_grpc_bridge.grpc2yar_endpoint").serve()
--   本模块保留 serve() 委托别名（向后兼容现有 nginx 配置 / 测试）。
--   配置状态（_services / _svc_cache / _max_payload_bytes）仍由门面持有，
--   入口层通过 resolve_service_config() / get_max_payload_bytes() 运行时读取。

local ngx = ngx
local pb = require("pb")
local Yar = require("yar")
local bridge = require("resty.yar_grpc_bridge.grpc2yar")
local host = require("resty.yar_grpc_bridge.host")
-- 核心协议转换库 lua-yar-grpc（纯函数，运行时无关；门面 setup 仅用 core.clear_cache）
-- 协议编解码 / 错误码 / deadline / trace 由 grpc2yar_endpoint 在入口层按需 require。
local core = require("yar_grpc")

---@class yar_grpc_bridge
---@field VERSION string
local _M = {}
_M.VERSION = "0.1.2"

--- gRPC path 匹配正则（与 lua-yar-grpc grpc_converter.parse_grpc_path 同步）
-- single source of truth：供文档引用 + 测试断言同步。
-- 注意：nginx location 不能直接引用 Lua 常量（nginx 配置静态编译，不支持 Lua 插值），
--       部署方用 example/ 下的 include 片段（见 example/*.conf）。
_M.GRPC_PATH_PATTERN = "^/+([^/]+)/([^/]+)$"

-- 模块级状态
-- Module-level state
local _services = {} -- 服务名 → { url=, options= }
local _yar_options = {}
local _svc_cache = {} -- 解析后的服务配置缓存（service name → {url, options}）
-- 默认请求体上限：8MB，对齐 lua-yar Framing.DEFAULT_MAX_BODY_LEN
-- Default request body size limit: 8MB, aligned with lua-yar Framing.DEFAULT_MAX_BODY_LEN
local DEFAULT_MAX_PAYLOAD_BYTES = 8388608
local _max_payload_bytes = DEFAULT_MAX_PAYLOAD_BYTES

-- lua-yar Log 级别 → host 日志常量映射
-- lua-yar 有 DEBUG(1)/INFO(2)/WARN(3)/ERROR(4)，nginx 无 DEBUG 级别，映射到 INFO
local _LOG_LEVEL_MAP = {
    [Yar.log.DEBUG] = host.LOG_INFO,
    [Yar.log.INFO] = host.LOG_INFO,
    [Yar.log.WARN] = host.LOG_WARN,
    [Yar.log.ERROR] = host.LOG_ERR,
}
_M._LOG_LEVEL_MAP = _LOG_LEVEL_MAP

--- 递归合并：table key 递归合并，非 table key 直接覆盖
-- 对齐 lua-yar client.lua 的 deep_merge 语义（含 depth > 100 防护）
---@param target table 目标 table（原地修改）
---@param source table 源 table
---@param depth? number 当前递归深度（内部使用）
---@return table 合并后的 target
local function deep_merge(target, source, depth)
    depth = depth or 0
    if depth > 100 then
        return target
    end
    for k, v in pairs(source) do
        if type(v) == "table" and type(target[k]) == "table" then
            deep_merge(target[k], v, depth + 1)
        else
            target[k] = v
        end
    end
    return target
end

--- 加载 .pb 二进制描述符文件
---@param file string 文件路径
---@return boolean 成功
---@return string|nil err 错误信息
local function load_pb_file(file)
    local f, err = io.open(file, "rb")
    if not f then
        return false, "cannot open proto file: " .. file .. " (" .. (err or "unknown") .. ")"
    end
    local data = f:read("*a")
    f:close()

    if not data or #data == 0 then
        return false, "empty proto file: " .. file
    end

    local ok, res, offset = pcall(pb.load, data)
    if not ok then
        return false, "failed to load " .. file .. ": " .. tostring(res)
    end
    -- lua-protobuf 对格式错误的 descriptor 走返回值失败协议（false, offset），不抛异常
    -- pcall 恒 ok，必须检查第二返回值（Bug 1 修复）
    if res == false then
        return false, "invalid .pb descriptor " .. file .. " (parse error at offset " .. tostring(offset) .. ")"
    end
    return true
end

-- HTTP 响应函数 send_error / send_ok 已移至 grpc2yar_endpoint.lua（Category 2 HTTP I/O）。
-- HTTP response functions moved to grpc2yar_endpoint.lua (Category 2 HTTP framework I/O).

--- 初始化：加载 .pb 文件、配置 services、注入 cosocket
-- 在 init_by_lua_block 中调用一次
--
-- 示例配置：
--   services  = {                                  -- 服务配置（proto + endpoint 合一）
--       Calculator = {
--           proto   = "proto/calc.pb",              -- .pb 文件路径
--           url     = "http://127.0.0.1:8888/api",  -- YAR Server URL
--           options = { timeout = 5000 },           -- 可选，per-service 覆盖
--       },
--       UserService = { proto = "...", url = "..." },
--   }
--   yar_options  = { timeout = 3000, ... }  -- YAR client 全局默认选项
---@param opts table { services:table, yar_options:table }
---@return table self
function _M.setup(opts)
    opts = opts or {}

    -- 0. 清空缓存（支持重复初始化：测试、热加载）
    -- 核心协议转换缓存（类型名/字段索引）+ 入口层 client 缓存
    core.clear_cache()
    bridge.clear_cache()
    _svc_cache = {}

    -- 1. 解析 services：加载 .pb 文件 + 存储 endpoint 配置
    local services = opts.services
    if type(services) ~= "table" or next(services) == nil then
        error("yar_grpc_bridge: services is required and must be a non-empty table", 0)
    end

    local loaded_files = {} -- 去重：同一 .pb 文件只加载一次

    _services = {}
    for service_name, svc_config in pairs(services) do
        if type(svc_config) ~= "table" then
            error("yar_grpc_bridge: service config for '" .. service_name .. "' must be a table", 0)
        end

        -- 加载 .pb 文件（去重）
        local proto_file = svc_config.proto
        if not proto_file or type(proto_file) ~= "string" then
            error("yar_grpc_bridge: service '" .. service_name .. "' is missing or has invalid 'proto' field", 0)
        end
        if not loaded_files[proto_file] then
            local ok, err = load_pb_file(proto_file)
            if not ok then
                error("yar_grpc_bridge: " .. err, 0)
            end
            loaded_files[proto_file] = true
        end

        -- 校验 url
        local url = svc_config.url
        if not url or type(url) ~= "string" then
            error("yar_grpc_bridge: service '" .. service_name .. "' is missing or has invalid 'url' field", 0)
        end

        -- 校验 options（可选，但若提供则必须为 table）
        local svc_opts = svc_config.options
        if svc_opts ~= nil and type(svc_opts) ~= "table" then
            error("yar_grpc_bridge: service '" .. service_name .. "' options must be a table", 0)
        end

        _services[service_name] = {
            url = url,
            options = svc_opts,
        }
    end

    -- 1a. 检测多个 service 指向同一 url（潜在 method 撞名风险）
    -- PHP Yar_Server 只注册一个对象实例，若多个 service 共用同一 url，
    -- 且 PHP 端只注册一个类，不同 service 的同名 method 会落到同一类方法。
    -- 此为部署告警，不阻断初始化（合法的聚合类场景仍允许）。
    local url_services = {}
    for service_name, svc in pairs(_services) do
        local url = svc.url
        if not url_services[url] then
            url_services[url] = {}
        end
        url_services[url][#url_services[url] + 1] = service_name
    end
    for url, names in pairs(url_services) do
        if #names > 1 then
            host.log(
                host.LOG_WARN,
                "yar_grpc_bridge: multiple services share the same url '"
                    .. url
                    .. "': "
                    .. table.concat(names, ", ")
                    .. " — ensure each service maps to a distinct PHP class "
                    .. "to avoid method-name collisions"
            )
        end
    end

    -- 2. 存储 YAR 默认选项
    _yar_options = opts.yar_options or {}

    -- 2a. 请求体大小上限（P0-4，DoS 防护）
    if opts.max_payload_bytes ~= nil then
        if type(opts.max_payload_bytes) ~= "number" or opts.max_payload_bytes <= 0 then
            error("yar_grpc_bridge: max_payload_bytes must be a positive integer", 0)
        end
        _max_payload_bytes = opts.max_payload_bytes
    else
        _max_payload_bytes = DEFAULT_MAX_PAYLOAD_BYTES
    end

    -- 2b. 用户 hooks 透传（对齐 lua-yar opts.hooks，可选）
    bridge.set_hooks(opts.hooks)

    -- 3. 注入 cosocket（出向 YAR 调用走 OpenResty 非阻塞 I/O）
    Yar.client.set_socket(ngx.socket)

    -- 4. 注入 Log writer：将 lua-yar 内部日志路由到 host.log
    Yar.log.set_writer(function(lvl, msg)
        host.log(_LOG_LEVEL_MAP[lvl] or host.LOG_ERR, "yar: " .. msg)
    end)

    -- 5. 设置日志级别（默认 WARN，与 lua-yar 自身默认一致）
    Yar.log.set_level(opts.log_level or Yar.log.WARN)

    return _M
end

--- 解析服务配置为最终 YAR 调用参数（合并全局默认 + per-service 覆盖）
-- 由 grpc2yar_endpoint.serve() 通过门面访问器调用（配置状态由本门面持有）
---@param service_name string 服务名（用作缓存 key）
---@return string|nil url YAR Server URL
---@return table|nil opts 合并后的 YAR 选项
local function resolve_service_config(service_name)
    -- 从缓存获取已解析的配置
    local cached = _svc_cache[service_name]
    if cached then
        return cached.url, cached.options
    end

    local svc = _services[service_name]
    if not svc then
        return nil, nil
    end

    -- 合并全局默认 + per-service 覆盖（deep_merge 正确处理嵌套子组如 keepalive）
    local opts = {}
    deep_merge(opts, _yar_options)
    if svc.options then
        deep_merge(opts, svc.options)
    end

    _svc_cache[service_name] = { url = svc.url, options = opts }
    return svc.url, opts
end
-- 暴露给 grpc2yar_endpoint.serve()（配置状态由门面持有，入口层只读访问）
_M.resolve_service_config = resolve_service_config

--- 读取请求体大小上限（供 grpc2yar_endpoint.serve() DoS 预检使用）
---@return number max_payload_bytes
function _M.get_max_payload_bytes()
    return _max_payload_bytes
end

--- 处理单个 gRPC 请求（委托别名，向后兼容）
-- 实现已移至 grpc2yar_endpoint.lua（overview-5：HTTP I/O 不混包门面）。
-- 惰性 require 避免与 grpc2yar_endpoint 的加载循环（grpc2yar_endpoint 运行时 require 本门面）。
---@return nil
function _M.serve()
    return require("resty.yar_grpc_bridge.grpc2yar_endpoint").serve()
end

--- 异步日志阶段（在 log_by_lua_block 中调用）
-- 从 host.ctx 读取请求元数据和 YAR 调用元数据，输出结构化访问日志行
-- 所有字段做 nil 兜底，确保 serve() 未执行时不报错
---@return nil
function _M.log_phase()
    local ctx = host.ctx
    local service = ctx.grpc_service or "-"
    local method = ctx.grpc_method or "-"
    local status = ctx.grpc_status or "-"
    local latency = ctx.yar_call_latency
    local err_code = ctx.yar_error_code

    local line = string.format(
        "yar_grpc_bridge %s/%s status=%s yar_latency_ms=%.3f",
        service,
        method,
        tostring(status),
        latency and latency * 1000 or 0
    )
    if err_code then
        line = line .. " yar_error=" .. tostring(err_code)
    end
    host.log(host.LOG_INFO, line)
end

return _M
