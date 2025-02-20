local md5 = require "resty.md5"
local str = require "resty.string"
local mlcache = require "sm.utils.mlcache"
local error = require "sm.utils.error"

local M = {}

-- Grab hostname config
function M.hostname(redis, hostname)
    local md5 = md5:new()
    if not md5 then
        return nil, nil, error("Failed to initialize MD5 instance")
    end

    local ok = md5:update(hostname)
    if not ok then
        return nil, nil, error("Failed to update MD5 object")
    end

    local digest = md5:final()
    if not digest then
        return nil, nil, error("Failed to finialize MD5 object")
    end

    local key = str.to_hex(digest)
    if not key then
        return nil, nil, error("Failed to compute MD5 key")
    end

    local hostname, hit_level, err = mlcache.get(key, redis.hgetall, key)
    if not hostname then
        return nil, nil, err
    end

    return hostname, hit_level, err
end

-- Grab rule
function M.rule(redis, zone, target, value)
    local md5 = md5:new()
    if not md5 then
        return nil, nil, nil, error("Failed to initialize MD5 instance")
    end

    local ok = md5:update(zone)
    if not ok then
        return nil, nil, nil, error("Failed to update MD5 object")
    end

    ok = md5:update(target)
    if not ok then
        return nil, nil, nil, "Failed to update MD5 object"
    end

    ok = md5:update(value)
    if not ok then
        return nil, nil, nil, error("Failed to update MD5 object")
    end

    local digest = md5:final()
    if not digest then
        return nil, nil, nil, error("Failed to finialize MD5 object")
    end

    local key = str.to_hex(digest)
    if not key then
        return nil, nil, nil, error("Failed to compute MD5 key")
    end

    local rule, hit_level, err = mlcache.get(key, redis.get, key)
    if err then
        return nil, nil, nil, err
    end

    return key, rule, hit_level, err
end

-- Grab zone config
function M.zone(redis, key)
    -- Grab config from mlcache
    local config, hit_level, err = mlcache.get(key, redis.hgetall, key)
    --if err then
    --    return nil, nil, err
    --end

    return config, hit_level, err
end

return M