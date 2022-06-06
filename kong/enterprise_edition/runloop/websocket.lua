-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local ws_proxy = require "kong.enterprise_edition.runloop.websocket.proxy"
local balancer = require "kong.runloop.balancer"
local pdk = require "kong.enterprise_edition.pdk.private.websocket"
local cert_utils = require "kong.enterprise_edition.cert_utils"
local balancers = require "kong.runloop.balancer.balancers"
local const = require "kong.constants"
local kong_global = require "kong.global"
local tracing = require "kong.tracing"
local runloop = require "kong.runloop.handler"


local NOOP = function() end
local PHASES = kong_global.phases

local STATUS = const.WEBSOCKET.STATUS
local RECV_TIMEOUT = 5000
local JANITOR_TIMEOUT = 5
local WS_EXTENSIONS = const.WEBSOCKET.HEADERS.EXTENSIONS

local ngx = ngx
local var = ngx.var
local req_get_headers = ngx.req.get_headers
local kong = kong
local type = type
local ipairs = ipairs
local pairs = pairs
local fmt = string.format
local load_certificate = cert_utils.load_certificate
local assert = assert
local get_balancer = balancers.get_balancer
local find = string.find
local spawn = ngx.thread.spawn
local kill = ngx.thread.kill
local exiting = ngx.worker.exiting
local sleep = ngx.sleep
local tonumber = tonumber
local update_time = ngx.update_time
local now = ngx.now
local log = ngx.log
local clear_header = ngx.req.clear_header
local concat = table.concat


local function is_timeout(err)
  return type(err) == "string"
         and find(err, "timeout", 1, true)
end


---
-- Parse the HTTP response string and return the status code
local function response_status(res)
  if type(res) ~= "string" then
    return nil, "non-string response"
  end

  -- 123456789012345678901234567890
  -- HTTP/1.1 301 Moved Permanently
  -- HTTP/2 301 Moved Permanently

  local status = tonumber(res:sub(10, 12)) or -- 0.9, 1.0, 1.1
                 tonumber(res:sub(8, 10))     -- 1, 2

  if not status then
    return nil, "failed parsing HTTP response status"
  end

  return status
end


local function get_updated_now_ms()
  update_time()
  return now() * 1000 -- time is kept in seconds with millisecond resolution.
end


---
-- Execute the balancer and select an IP/port for the upstream.
--
-- This is mostly copy/paste from `Kong.balancer()`, but with the
-- ngx.upstream/proxy_pass bits removed and/or adapted for use with
-- resty.websocket.proxy, which uses ngx.socket.tcp() under the hood
--
---@param ctx table
---@param opts resty.websocket.client.connect.opts
---@param upstream_scheme "ws"|"wss"
local function get_peer(ctx, opts, upstream_scheme)
  local trace = tracing.trace("balancer")

  ctx.KONG_PHASE = PHASES.balancer

  local now_ms = get_updated_now_ms()

  if not ctx.KONG_BALANCER_START then
    ctx.KONG_BALANCER_START = now_ms
  end

  local balancer_data = ctx.balancer_data
  local tries = balancer_data.tries
  local current_try = {}
  balancer_data.try_count = balancer_data.try_count + 1
  tries[balancer_data.try_count] = current_try

  current_try.balancer_start = now_ms

  if balancer_data.try_count > 1 then
    -- record failure data
    local previous_try = tries[balancer_data.try_count - 1]

    -- Report HTTP status for health checks
    local balancer_instance = balancer_data.balancer
    if balancer_instance then
      if previous_try.state == "failed" then
        if previous_try.code == 504 then
          balancer_instance.report_timeout(balancer_data.balancer_handle)
        else
          balancer_instance.report_tcp_failure(balancer_data.balancer_handle)
        end

      else
        balancer_instance.report_http_status(balancer_data.balancer_handle,
                                             previous_try.code)
      end
    end

    local ok, err, errcode = balancer.execute(balancer_data, ctx, true)
    if not ok then
      log(ngx.ERR, "failed to retry the dns/balancer resolver for ",
              tostring(balancer_data.host), "' with: ", tostring(err))

      ctx.KONG_BALANCER_ENDED_AT = get_updated_now_ms()
      ctx.KONG_BALANCER_TIME = ctx.KONG_BALANCER_ENDED_AT - ctx.KONG_BALANCER_START
      ctx.KONG_PROXY_LATENCY = ctx.KONG_BALANCER_ENDED_AT - ctx.KONG_PROCESSING_START

      return ngx.exit(errcode)
    end
  end

  if not balancer_data.preserve_host then
    -- set the upstream host header if not `preserve_host`
    local new_upstream_host = balancer_data.hostname
    local port = balancer_data.port

    if (port ~= 80  and port ~= 443)
    or (port == 80 and upstream_scheme ~= "ws")
    or (port == 443 and upstream_scheme ~= "wss")
    then
      new_upstream_host = new_upstream_host .. ":" .. port
    end

    if new_upstream_host ~= opts.host then
      opts.host = new_upstream_host
    end
  end

  if upstream_scheme == "wss" then
    local server_name = opts.host

    -- the host header may contain a port number that needs to be stripped
    local pos = server_name:find(":")
    if pos then
      server_name = server_name:sub(1, pos - 1)
    end

    opts.server_name = server_name
  end

  current_try.ip   = balancer_data.ip
  current_try.port = balancer_data.port

  -- set the targets as resolved
  log(ngx.DEBUG, "setting address (try ", balancer_data.try_count, "): ",
                     balancer_data.ip, ":", balancer_data.port)

  -- record overall latency
  ctx.KONG_BALANCER_ENDED_AT = get_updated_now_ms()
  ctx.KONG_BALANCER_TIME = ctx.KONG_BALANCER_ENDED_AT - ctx.KONG_BALANCER_START

  -- record try-latency
  local try_latency = ctx.KONG_BALANCER_ENDED_AT - current_try.balancer_start
  current_try.balancer_latency = try_latency

  -- time spent in Kong before sending the request to upstream
  -- start_time() is kept in seconds with millisecond resolution.
  ctx.KONG_PROXY_LATENCY = ctx.KONG_BALANCER_ENDED_AT - ctx.KONG_PROCESSING_START

  trace:finish()

  return current_try
end


local set_response_headers

if ngx.config.subsystem == "http" then
  local add_header = require("ngx.resp").add_header

  -- Some of these are hop-by-hop, and some are just plain invalid in the
  -- context of a WebSocket handshake
  local skipped_headers = {
    ["connection"]            = true,
    ["content-length"]        = true,
    ["keep-alive"]            = true,
    ["proxy-authenticate"]    = true,
    ["proxy-authorization"]   = true,
    ["te"]                    = true,
    ["trailers"]              = true,
    ["transfer-encoding"]     = true,
    ["upgrade"]               = true,
  }

  local ext_header = WS_EXTENSIONS:lower()

  ---
  -- Copy upstream handshake response headers to the client
  function set_response_headers(ctx, res)
    local seen_status_line = false

    for line in res:gmatch("([^\r\n]+)") do
      if seen_status_line then
        local name, value = line:match([[^([^:]+):%s*(.+)]])
        local norm_name = name:lower()

        if name and value then
          if not skipped_headers[norm_name] then
            add_header(name, value)
          end

          if norm_name == ext_header then
            local ext = ctx.KONG_WEBSOCKET_EXTENSIONS_ACCEPTED
            if ext then
              value = { ext, value }
            end
            ctx.KONG_WEBSOCKET_EXTENSIONS_ACCEPTED = value
          end
        else
          kong.log.warn("invalid header line in WS handshake response: ",
                        "'", line, "'")
        end

      else
        seen_status_line = true
      end
    end
  end
end


---
-- Prepare request headers for lua-resty-websocket
--
-- 1. Delete some "special" headers
-- 2. Populate `X-Forwarded-*` headers
-- 3. Transposes the map-like table returned by ngx.req.get_headers() into
--      an array-like table
--
---@param req_headers table<string, string|table>
---@return string[]
local function prepare_req_headers(req_headers)
  -- lua-resty-websocket manages these directly
  req_headers["host"]                  = nil
  req_headers["origin"]                = nil
  req_headers["sec-websocket-key"]     = nil
  req_headers["sec-websocket-version"] = nil
  req_headers["connection"]            = nil
  req_headers["upgrade"]               = nil

  req_headers["x-forwarded-for"]       = var.upstream_x_forwarded_for
  req_headers["x-forwarded-proto"]     = var.upstream_x_forwarded_proto
  req_headers["x-forwarded-host"]      = var.upstream_x_forwarded_host
  req_headers["x-forwarded-port"]      = var.upstream_x_forwarded_port
  req_headers["x-forwarded-path"]      = var.upstream_x_forwarded_path
  req_headers["x-forwarded-prefix"]    = var.upstream_x_forwarded_prefix

  local headers = {}
  local n = 0
  for k, v in pairs(req_headers) do
    if type(v) == "table" then
      for _, item in ipairs(v) do
        n = n + 1
        headers[n] = k .. ":" .. item
      end
    else
      n = n + 1
      headers[n] = k .. ":" .. v
    end
  end

  return headers
end


---
-- Because WebSocket connections are much more long-lived than normal HTTP
-- requests, there are conditions where we as the proxy should terminate them
-- ourselves:
--
-- 1. When NGINX is exiting
-- 2. TODO: When a change to the plugins iterator would affect the connection
--
local function janitor(proxy, ctx)
  local t = ctx.KONG_WEBSOCKET_JANITOR_TIMEOUT or JANITOR_TIMEOUT

  while not exiting() do
    sleep(t)
  end

  ngx.log(ngx.INFO, "NGINX is exiting, closing proxy...")

  local status = STATUS.GOING_AWAY

  proxy:close(status.CODE, status.REASON, status.CODE, status.REASON)

  return true
end


---
-- Check if the current request context has any active plugins with WS
-- frame handler functions.
local function has_proxy_plugins(ctx)
  local iter = ctx.KONG_WEBSOCKET_PLUGINS_ITERATOR

  local _, state = iter("ws_client_frame", ctx)

  if state ~= nil then
    return true
  end

  _, state = iter("ws_upstream_frame", ctx)

  return state ~= nil
end


local on_frame
do
  local set_named_ctx = kong_global.set_named_ctx
  local set_namespaced_log = kong_global.set_namespaced_log
  local reset_log = kong_global.reset_log
  local get_state = pdk.get_state
  local co_running = coroutine.running


  local function send_close(proxy, initiator, state)
    local client_status, upstream_status
    local client_reason, upstream_reason

    if initiator == "client" then
      client_status = state.status
      client_reason = state.data
      upstream_status = state.peer_status
      upstream_reason = state.peer_data
    else
      upstream_status = state.status
      upstream_reason = state.data
      client_status = state.peer_status
      client_reason = state.peer_data
    end

    proxy:close(client_status, client_reason,
                upstream_status, upstream_reason)
  end


  on_frame = function(proxy, sender, typ, data, fin, code)
    local ctx = ngx.ctx
    local state = get_state(ctx, sender)

    -- frame aggregation is expected to be on at all times
    assert(fin, "unexpected continuation frame/fragment")

    state.type        = typ
    state.data        = data
    state.status      = code
    state.drop        = nil
    state.peer_status = nil
    state.peer_data   = nil

    if state.closing then
      return
    end

    if not state.thread then
      state.thread = co_running()
    end

    local name = (sender == "client" and "ws_client_frame")
                 or "ws_upstream_frame"

    local iter = ctx.KONG_WEBSOCKET_PLUGINS_ITERATOR

    for plugin, conf in iter(name, ctx) do
      local handler = plugin.handler
      local fn = handler[name]

      set_named_ctx(kong, "plugin", handler, ctx)
      set_namespaced_log(kong, name, ctx)

      -- XXX This deviates from the standard plugin handler API by including
      -- the frame type, payload, and status code in the function arguments.
      --
      -- It's pretty much a given that any plugin frame handler will need to
      -- inspect the frame type and/or payload, so passing these things in as
      -- func args saves on plugin boilerplate _and_ improves performance by not
      -- incurring the penalty of a ngx.ctx lookup.
      local ok, err = pcall(fn, handler, conf,
                            state.type, state.data, state.status)

      reset_log(kong, ctx)

      if not ok then
        kong.log.err("plugin handler (", plugin.name, ") threw an error: ", err)

        state.status      = STATUS.SERVER_ERROR.CODE
        state.peer_status = STATUS.SERVER_ERROR.CODE
        state.data        = STATUS.SERVER_ERROR.REASON
        state.peer_data   = STATUS.SERVER_ERROR.REASON
        state.closing     = true
        state.drop        = true
      end

      -- a plugin has signalled to terminate the connection or drop the frame,
      -- so we probably need to break out of the loop
      if state.closing or state.drop then
        break
      end
    end

    if state.closing then
      send_close(proxy, sender, state)
      return
    end

    if state.drop then
      return
    end

    if state.type == "close" then
      state.closing = true
    end

    return state.data, state.status
  end
end


----
-- Check if the service or upstream have a client certificate associated
-- with them, and if so, add it to the WS connection options table.
--
---@param ctx table
---@param opts resty.websocket.client.connect.opts
local function set_client_cert(ctx, opts)
  local balancer_data = ctx.balancer_data

  -- service/upstream client certificate
  local client_cert = ctx.service.client_certificate

  if not client_cert then
    local _, upstream = get_balancer(balancer_data)
    client_cert = upstream and upstream.client_certificate
  end

  if client_cert then
    local cert, key, err = load_certificate(client_cert.id)

    if not cert then
      kong.log.err("failed loading certificate for service: ", err)
      return kong.response.error(500)
    end

    opts.client_cert = cert
    opts.client_priv_key = key
  end
end


return {
  handlers = {
    ws_handshake = {
      before = NOOP,
      after = function(ctx)
        -- validate the client handshake
        --
        -- NOTE: HTTP version, method, and Connection+Upgrade headers have
        -- already been validated by the router in order to reach this point, so
        -- there's no need to check them again.

        -- Sec-WebSocket-Key must appear exactly once
        -- https://datatracker.ietf.org/doc/html/rfc6455#section-11.3.1
        local ws_key = var.http_sec_websocket_key -- ["Sec-WebSocket-Key"]
        if not ws_key then
          return kong.response.exit(400, "missing Sec-WebSocket-Key header")

        elseif type(ws_key) == "table" then
          return kong.response.exit(400, "more than one Sec-WebSocket-Key header found")
        end

        -- Sec-WebSocket-Version must appear exactly once
        -- https://datatracker.ietf.org/doc/html/rfc6455#section-11.3.5
        local ws_version = var.http_sec_websocket_version -- headers["Sec-WebSocket-Version"]
        if not ws_version then
          return kong.response.exit(400, "missing Sec-WebSocket-Version header")

        elseif type(ws_version) == "table" then
          return kong.response.exit(400, "more than Sec-Websocket-Version header found")

        -- Sec-WebSocket-Version must be 13
        -- https://datatracker.ietf.org/doc/html/rfc6455#section-4.1
        elseif ws_version ~= "13" then
          return kong.response.exit(400, "Sec-WebSocket-Version header is invalid")
        end

        -- No WebSocket extensions are currently supported, so remove them from
        -- the handshake
        local extensions = var.http_sec_websocket_extensions
        if extensions then
          ctx.KONG_WEBSOCKET_EXTENSIONS_REQUESTED = extensions

          if type(extensions) == "table" then
            extensions = concat(extensions, ", ")
          end
          kong.log.debug("WebSocket client requested unsupported extensions ",
                         "(", extensions, "). ",
                         "Clearing the ", WS_EXTENSIONS, " request header")
          clear_header(WS_EXTENSIONS)
        end

        runloop.access.after(ctx)
      end,
    },
    ws_proxy = {
      -- XXX this code re-implements a lot of things that are otherwise handled
      -- by Kong.access(), proxy_pass, balancer_by_lua, etc, and as such it
      -- deserves special attention
      before = function(ctx)
        ---@type kong.db.entities.Service
        local service = ctx.service
        local tries = (service.retries or 0) + 1

        -- the on_frame function is only needed for plugin handlers, so skip it
        -- if there aren't any
        local frame_handler
        if has_proxy_plugins(ctx) then
          frame_handler = on_frame
        else
          kong.log.debug("service ", service.id, " has no WS plugins active")
        end

        local proxy, err = ws_proxy.new({
          aggregate_fragments       = true,
          debug                     = ctx.KONG_WEBSOCKET_DEBUG,
          recv_timeout              = ctx.KONG_WEBSOCKET_RECV_TIMEOUT
                                      or RECV_TIMEOUT,
          connect_timeout           = ctx.KONG_WEBSOCKET_CONNECT_TIMEOUT
                                      or service.connect_timeout,
          on_frame                  = frame_handler,
          lingering_time            = ctx.KONG_WEBSOCKET_LINGERING_TIME,
          lingering_timeout         = ctx.KONG_WEBSOCKET_LINGERING_TIMEOUT,
          client_max_frame_size     = ctx.KONG_WEBSOCKET_CLIENT_MAX_PAYLOAD_SIZE,
          upstream_max_frame_size   = ctx.KONG_WEBSOCKET_UPSTREAM_MAX_PAYLOAD_SIZE,
        })

        if not proxy then
          kong.log.err("couldn't create proxy instance: ", err)
          return kong.response.error(500)
        end

        local headers = req_get_headers()
        local origin = headers.origin

        ---@type resty.websocket.client.connect.opts
        local opts = {
          ssl_verify    = service.tls_verify,
          headers       = prepare_req_headers(headers),
          origin        = origin,
          host          = var.upstream_host,
        }

        set_client_cert(ctx, opts)

        local connected = false
        local response

        local upstream_scheme = var.upstream_scheme

        local uri_template = fmt(
          "%s://%%s:%%s%s",
          upstream_scheme,
          var.upstream_uri
        )

        local ok, status

        for _ = 1, tries do
          local try = get_peer(ctx, opts, upstream_scheme)
          local uri = fmt(uri_template, try.ip, try.port)

          ok, err, response = proxy:connect_upstream(uri, opts)

          if ok then
            connected = true
            break

          elseif response then
            status, err = response_status(response)

            if status then
              set_response_headers(ctx, response)
            else
              status = 500
              kong.log.err("failed parsing response: ", err)
            end

            try.state = "next"
            try.code = status
            ngx.status = status
            return ngx.exit(0)

          else
            status = is_timeout(err) and 504 or 502
            try.state = "failed"
            try.code = status
            kong.log.err("failed connecting to ", uri, ": ", err)
          end
        end

        if not connected then
          kong.log.err("exhausted retries trying to proxy WS")
          return ngx.exit(status or 502)
        end

        set_response_headers(ctx, response)

        -- XXX We don't support any WebSocket extensions right now, but that
        -- doesn't mean this logic should just go away when we add support for
        -- them. To protect the client (and in conformance with the WS spec),
        -- we must validate this field to ensure that the upstream does not
        -- offer any extensions that weren't requested by the client.
        if ctx.KONG_WEBSOCKET_EXTENSIONS_ACCEPTED then
          proxy:close_upstream(STATUS.PROTOCOL_ERROR.CODE,
                               STATUS.PROTOCOL_ERROR.REASON)

          local ext = ctx.KONG_WEBSOCKET_EXTENSIONS_ACCEPTED
          if type(ext) == "table" then
            ext = concat(ext, ", ")
          end
          ext = tostring(ext)

          -- FIXME WS phases aren't very granular and might need to be reworked
          -- at some point before the PDK is declared stable.
          --
          -- `kong.response.exit` is not enabled during the `ws_proxy` phase
          -- because we don't want anyone calling it from a frame handler, but
          -- it's perfectly fine to use here because we haven't upgraded the
          -- client connection yet.
          ctx.KONG_PHASE = PHASES.ws_handshake
          return kong.response.exit(501, "WebSocket upstream sent unsupported "
                                         .. WS_EXTENSIONS .. " (" .. ext .. ")")
        end

        ok, err = proxy:connect_client()
        if not ok then
          kong.log.err("failed handshaking client: ", err)
          return ngx.exit(500)
        end

        -- sending the response headers triggers the header_filter which, in
        -- turn, sets ctx.KONG_PHASE to the header filter, so we need to set it
        -- back to ws_proxy here
        ctx.KONG_PHASE = PHASES.ws_proxy

        -- per-frame state is only needed for plugin frame handlers
        if frame_handler then
          pdk.init_state(ctx)
        end

        local janitor_thread
        janitor_thread, err = spawn(janitor, proxy, ctx)
        if not janitor_thread then
          kong.log.err("failed to spawn janitor thread for proxy: ", err)
        end

        ok, err = proxy:execute()
        if not ok then
          kong.log.err("proxy execution terminated abnormally: ", err)
        end

        kill(janitor_thread)
      end,

      after = NOOP,
    },
    ws_close = {
      before = NOOP,
      after = runloop.log.after,
    },
  },
}
