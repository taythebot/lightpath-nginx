-- vim: st=4 sts=4 sw=4 et:
--- Network backend using [lua-resty-http](https://github.com/ledgetech/lua-resty-http).
--- Supports https, http, and keepalive for better performance.
--
-- @module raven.senders.lua-resty-http
-- @copyright 2014-2017 CloudFlare, Inc.
-- @license BSD 3-clause (see LICENSE file)

local util = require "sm.utils.raven.util"
local http = require "resty.http"
local cjson = require "cjson"

local log = ngx.log
local ERR = ngx.ERR
local ngx_timer_at = ngx.timer.at
local ngx_socket = ngx.socket
local ngx_get_phase = ngx.get_phase
local tostring = tostring
local setmetatable = setmetatable
local table_remove = table.remove
local parse_dsn = util.parse_dsn
local generate_auth_header = util.generate_auth_header
local _VERSION = util._VERSION
local _M = {}

local mt = {}
mt.__index = mt

local function send_msg(self, msg)
    local httpc = http.new()
    local res, err = httpc:request_uri(self.server, msg)

    if not res then
        return nil, err
    end

    if res.status ~= 200 then
        return nil, "Sentry returned status code " .. res.status
    end

    return res.body
end

local function send_task(premature, self)
    if premature then
        return
    end

    local ok, err = xpcall(function()
        local queue = self.queue

        while #queue > 0 do
            local msg = queue[1]
            local ok, err = send_msg(self, msg)

            if not ok then
                log(ERR, "Raven failed to send message asyncronously: ", err)
            end

            table_remove(queue, 1)
        end
    end, debug.traceback)

    if not ok then
        log(ERR, "Raven failed to run the async sender task: ", err)
    end

    self.task_running = false
end

function mt:send(json_str)
    -- Prepare http request config
    local msg = {
        method = "POST",
        headers = {
            ["Content-Type"] = "applicaion/json",
            ["User-Agent"] = "raven-lua-http/" .. _VERSION,
            ["X-Sentry-Auth"] = generate_auth_header(self),
            ["Content-Length"] = tostring(#json_str),
        },
        body = json_str,
        ssl_verify = self.opts.verify_ssl,
        keepalive = self.opts.keepalive,
        keepalive_timeout = self.opts.keepalive_timeout,
        keepalive_pool = self.opts.keepalive_pool
    }

    -- Cosocket is only available in certain phases
    local phase = ngx_get_phase()
    if phase == "rewrite" or phase == "access" or phase == "content" or phase == "timer" or phase == "ssl_cert" or phase == "ssl_session_fetch" then
        -- socket is available
        return send_msg(self, msg)
    else
        -- Push message into queue
        local queue = self.queue
        local queue_size = #queue

        if queue_size <= self.queue_limit then
            queue[queue_size + 1] = msg

            if not self.task_running then
                local ok, err = ngx_timer_at(0, send_task, self)
                if not ok then
                    return nil, "Failed to schedule async sender task: " .. err
                end

                self.task_running = true
            end
        else
            return nil, "Failed to send message asyncronously: queue is full"
        end

        return true
    end
end

--- Configuration table for the lua-resty-http.
-- @field dsn DSN string
-- @field verify_ssl Whether or not the SSL certificate is checked (boolean,
--  defaults to false)
-- @field keepalive Whether or not to keep connection alive (boolean,
--  defaults to false)
-- @field keepalive_timeout The maximum number of connections in the keepalive pool(int,
--  defaults to 0)
-- @field keepalive_pool Whether or not to keep connection alive (int,
--  defaults to 0)
-- @field queue_limit Maximum number of events in the queue (int,
--  defaults to 10)
-- @table sender_conf

--- Create a new sender object for the given DSN
-- @param conf Configuration table, see @{sender_conf}
-- @return A sender object
function _M.new(conf)
    local obj, err = parse_dsn(conf.dsn)
    if not obj then
        return nil, err
    end

    obj.opts = {
        verify_ssl = conf.verify_ssl or false,
        keepalive = conf.keepalive or false,
        keepalive_timeout = conf.keepalive_timeout or 0,
        keepalive_pool = conf.keepalive_pool or 0
    }

    obj.queue = {}
    obj.queue_limit = conf.queue_limit or 10
    obj.task_running = false

    return setmetatable(obj, mt)
end

return _M

