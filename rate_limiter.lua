local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window  = tonumber(ARGV[2])
local current = redis.call("get", key)

if current and tonumber(current) >= limit then
    return 0
else
    if current then
        redis.call("inct", key)
    else
        redis.call("set", key, 1, "EX", window)
    end
    return 1
end
