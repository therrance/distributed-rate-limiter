-- Edge rate limiting for the OpenResty front door. The only enforcement
-- point: server.js no longer runs the limiter middleware.
--
-- The fixed-window algorithm itself is not reimplemented here -- the repo's
-- Redis-side script (rate_limiter.lua) is bind-mounted at SCRIPT_PATH, read
-- once at start-up, and shipped to Redis with EVAL, so it stays atomic and
-- lives in exactly one file.

local redis = require "resty.redis"

local ngx       = ngx
local os_getenv = os.getenv
local tonumber  = tonumber
local tostring  = tostring
local floor     = math.floor

local _M = {}

-- Outside /etc/nginx/lua on purpose: this is Redis-side Lua, not an nginx module.
local SCRIPT_PATH = "/etc/nginx/redis/rate_limiter.lua"

-- Byte-for-byte what the Express middleware used to send.
local DENY_BODY  = '{"message":"Too many requests. Please try again later"}'
local ERROR_BODY = '{"message":"Internal server error"}'
local JSON_TYPE  = "application/json; charset=utf-8"

-- Defaults for the Redis socket tunables; overridable via the env vars read
-- in _M.init(). Total connections to Redis is roughly
-- replicas * worker_processes * pool_size, which matters against maxclients.
local DEFAULT_TIMEOUT_MS        = 200
local DEFAULT_KEEPALIVE_IDLE_MS = 30000
local DEFAULT_KEEPALIVE_POOL    = 64

-- Populated by _M.init() in the master process; inherited by every worker.
local conf = {}


-- nil for absent/unparseable/<1, mirroring parseInt(x) || default in server.js.
local function env_num(name)
    local n = tonumber(os_getenv(name))
    if not n or n < 1 then
        return nil
    end
    return floor(n)
end


local function read_script(path)
    local fh, err = io.open(path, "r")
    if not fh then
        return nil, tostring(err)
    end
    local body = fh:read("*a")
    fh:close()
    if not body or body == "" then
        return nil, "file is empty"
    end
    return body
end


-- Runs once in the master before workers fork. Throwing here aborts
-- start-up -- serving unlimited traffic silently would be worse.
function _M.init()
    local script, err = read_script(SCRIPT_PATH)
    if not script then
        error("rate_limit: cannot read Redis script " .. SCRIPT_PATH ..
              ": " .. err, 0)
    end

    local ip_limit    = env_num("RATE_LIMIT")       or 10
    local ip_window   = env_num("TIME_WINDOW")      or 60
    -- USER_* falls back to the ip values, same as server.js.
    local user_limit  = env_num("USER_RATE_LIMIT")  or ip_limit
    local user_window = env_num("USER_TIME_WINDOW") or ip_window

    conf.script     = script
    conf.redis_host = os_getenv("REDIS_HOST") or "127.0.0.1"
    conf.redis_port = env_num("REDIS_PORT") or 6379
    conf.fail_open  = os_getenv("RATE_LIMIT_FAIL_OPEN") == "true"

    conf.timeout_ms        = env_num("REDIS_TIMEOUT_MS")
                             or DEFAULT_TIMEOUT_MS
    conf.keepalive_idle_ms = env_num("REDIS_KEEPALIVE_IDLE_MS")
                             or DEFAULT_KEEPALIVE_IDLE_MS
    conf.keepalive_pool    = env_num("REDIS_KEEPALIVE_POOL_SIZE")
                             or DEFAULT_KEEPALIVE_POOL

    conf.rules = {
        ip   = { limit = tostring(ip_limit),   window = tostring(ip_window)   },
        user = { limit = tostring(user_limit), window = tostring(user_window) },
    }

    ngx.log(ngx.NOTICE, "rate_limit: redis=", conf.redis_host, ":",
            conf.redis_port, " ip=", ip_limit, "/", ip_window,
            "s user=", user_limit, "/", user_window,
            "s fail_open=", tostring(conf.fail_open),
            " timeout=", conf.timeout_ms, "ms pool=", conf.keepalive_pool,
            " script=", SCRIPT_PATH, " (", #script, " bytes)")
end


local function send_json(status, body)
    ngx.status = status
    ngx.header["Content-Type"]   = JSON_TYPE
    ngx.header["Content-Length"] = #body
    -- print, not say: say() appends "\n" and would break byte parity with
    -- Express's res.json().
    ngx.print(body)
    -- Headers are already flushed; this just finalizes with the status set
    -- above. Never ngx.exit(ngx.OK) here -- that means "continue upstream".
    return ngx.exit(status)
end


local function on_redis_failure(scope, identifier, err)
    ngx.log(ngx.ERR, "rate_limit: redis failure for ", scope, " ",
            identifier, ": ", err)
    if conf.fail_open then
        ngx.log(ngx.WARN, "rate_limit: failing open, allowing ", scope, " ",
                identifier)
        return
    end
    return send_json(500, ERROR_BODY)
end


function _M.run()
    -- Same rule as server.js: a present, non-empty X-User-Id switches scope.
    local uid = ngx.var.http_x_user_id
    local scope, identifier
    if uid and uid ~= "" then
        scope, identifier = "user", uid
    else
        scope, identifier = "ip", ngx.var.remote_addr or "unknown"
    end

    local rule = conf.rules[scope]
    local key  = "rate:limit:" .. scope .. ":" .. identifier

    local red, nerr = redis:new()
    if not red then
        return on_redis_failure(scope, identifier, "new(): " .. tostring(nerr))
    end
    red:set_timeouts(conf.timeout_ms, conf.timeout_ms, conf.timeout_ms)

    local ok, cerr = red:connect(conf.redis_host, conf.redis_port)
    if not ok then
        return on_redis_failure(scope, identifier, "connect: " .. tostring(cerr))
    end

    -- lua-resty-redis returns (nil, err) for transport errors and (false, err)
    -- for a Redis "-ERR" reply -- and 0 (denied) is truthy in Lua, so neither
    -- `if res then` nor `if not res then` is safe here.
    local res, eerr = red:eval(conf.script, 1, key, rule.limit, rule.window)
    if res == nil or res == false then
        red:close() -- may be half-consumed; never pool it
        return on_redis_failure(scope, identifier, "eval: " .. tostring(eerr))
    end

    -- Pool it instead of close()ing: a fresh handshake per request would
    -- roughly double the latency this check adds.
    local kok, kerr = red:set_keepalive(conf.keepalive_idle_ms,
                                       conf.keepalive_pool)
    if not kok then
        ngx.log(ngx.WARN, "rate_limit: set_keepalive failed: ", tostring(kerr))
    end

    if tonumber(res) == 1 then
        ngx.log(ngx.NOTICE, "Request allowed for ", scope, " ", identifier)
        return
    end

    ngx.log(ngx.WARN, "Request denied for ", scope, " ", identifier)
    return send_json(429, DENY_BODY)
end


return _M
