-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

------------------------------------------------------------------
-- Collection of utilities to help testing Kong-Enterprise features and plugins.
--
-- @copyright Copyright 2016-2022 Kong Inc. All rights reserved.
-- @module spec-ee.helpers

local helpers     = require "spec.helpers"
local listeners = require "kong.conf_loader.listeners"
local cjson = require "cjson.safe"
local assert = require "luassert"
local utils = require "kong.tools.utils"
local admins_helpers = require "kong.enterprise_edition.admins_helpers"


local _M = {}

--- Registers RBAC resources.
-- @function register_rbac_resources
-- @param db db object (see `get_db_utils`)
-- @param ws_name (optional)
-- @param ws_table (optional)
-- @return `super_admin + super_user_role` or `nil + nil + err` on failure
function _M.register_rbac_resources(db, ws_name, ws_table)
  local bit   = require "bit"
  local rbac  = require "kong.rbac"
  local bxor  = bit.bxor

  local opts = ws_table and { workspace = ws_table.id }

  -- action int for all
  local action_bits_all = 0x0
  for k, v in pairs(rbac.actions_bitfields) do
    action_bits_all = bxor(action_bits_all, rbac.actions_bitfields[k])
  end

  local roles = {}
  local err, _
  -- now, create the roles and assign endpoint permissions to them

  -- first, a read-only role across everything
  roles.read_only, err = db.rbac_roles:insert({
    id = utils.uuid(),
    name = "read-only",
    comment = "Read-only access across all initial RBAC resources",
  }, opts)

  if err then
    return nil, nil, err
  end

  -- this role only has the 'read-only' permissions
  _, err = db.rbac_role_endpoints:insert({
    role = { id = roles.read_only.id, },
    workspace = ws_name or "*",
    endpoint = "*",
    actions = rbac.actions_bitfields.read,
  })

  ws_name = ws_name or "default"

  if err then
    return nil, nil, err
  end

  -- admin role with CRUD access to all resources except RBAC resource
  roles.admin, err = db.rbac_roles:insert({
    id = utils.uuid(),
    name = "admin",
    comment = "CRUD access to most initial resources (no RBAC)",
  }, opts)

  if err then
    return nil, nil, err
  end

  -- the 'admin' role has 'full-access' + 'no-rbac' permissions
  _, err = db.rbac_role_endpoints:insert({
    role = { id = roles.admin.id, },
    workspace = "*",
    endpoint = "*",
    actions = action_bits_all, -- all actions
  })

  if err then
    return nil, nil, err
  end

  local rbac_endpoints = { '/rbac/*', '/rbac/*/*', '/rbac/*/*/*' }
  for _, endpoint in ipairs(rbac_endpoints) do
    _, err = db.rbac_role_endpoints:insert({
      role = { id = roles.admin.id, },
      workspace = "*",
      endpoint = endpoint,
      negative = true,
      actions = action_bits_all, -- all actions
    })

    if err then
      return nil, nil, err
    end
  end

  -- finally, a super user role who has access to all initial resources
  roles.super_admin, err = db.rbac_roles:insert({
    id = utils.uuid(),
    name = "super-admin",
    comment = "Full CRUD access to all initial resources, including RBAC entities",
  }, opts)

  if err then
    return nil, nil, err
  end

  _, err = db.rbac_role_entities:insert({
    role = { id = roles.super_admin.id, },
    entity_id = "*",
    entity_type = "wildcard",
    actions = action_bits_all, -- all actions
  })

  if err then
    return nil, nil, err
  end

  _, err = db.rbac_role_endpoints:insert({
    role = { id = roles.super_admin.id, },
    workspace = "*",
    endpoint = "*",
    actions = action_bits_all, -- all actions
  })

  if err then
    return nil, nil, err
  end

  local super_admin, err = db.rbac_users:insert({
    id = utils.uuid(),
    name = "super_gruce-" .. ws_name,
    user_token = "letmein-" .. ws_name,
    enabled = true,
    comment = "Test - Initial RBAC Super Admin User"
  }, opts)

  if err then
    return nil, nil, err
  end

  local super_user_role, err = db.rbac_user_roles:insert({
    user = super_admin,
    role = roles.super_admin,
  })

  if err then
    return nil, nil, err
  end

  return super_admin, super_user_role
end


--- returns a pre-configured `http_client` for the Kong Admin GUI.
-- @function admin_gui_client
-- @param timeout (optional, number) the timeout to use
-- @param forced_port (optional, number) if provided will override the port in
-- the Kong configuration with this port
function _M.admin_gui_client(timeout, forced_port)
  local admin_ip, admin_port
  for _, entry in ipairs(_M.admin_gui_listeners) do
    if entry.ssl == false then
      admin_ip = entry.ip
      admin_port = entry.port
    end
  end
  assert(admin_ip, "No http-admin found in the configuration")
  return helpers.http_client(admin_ip, forced_port or admin_port, timeout or 60000)
end

--- Returns the Dev Portal port.
-- @function get_portal_api_port
-- @param ssl (boolean) if `true` returns the ssl port
local function get_portal_api_port(ssl)
  if ssl == nil then ssl = false end
  for _, entry in ipairs(_M.portal_api_listeners) do
    if entry.ssl == ssl then
      return entry.port
    end
  end
  error("No portal port found for ssl=" .. tostring(ssl), 2)
end


--- Returns the Dev Portal ip.
-- @function get_portal_api_ip
-- @param ssl (boolean) if `true` returns the ssl ip address
local function get_portal_api_ip(ssl)
  if ssl == nil then ssl = false end
  for _, entry in ipairs(_M.portal_api_listeners) do
    if entry.ssl == ssl then
      return entry.ip
    end
  end
  error("No portal ip found for ssl=" .. tostring(ssl), 2)
end


--- Returns the Dev Portal port.
-- @function get_portal_gui_port
-- @param ssl (boolean) if `true` returns the ssl port
local function get_portal_gui_port(ssl)
  if ssl == nil then ssl = false end
  for _, entry in ipairs(_M.portal_gui_listeners) do
    if entry.ssl == ssl then
      return entry.port
    end
  end
  error("No portal port found for ssl=" .. tostring(ssl), 2)
end


--- Returns the Dev Portal ip.
-- @function get_portal_gui_ip
-- @param ssl (boolean) if `true` returns the ssl ip address
local function get_portal_gui_ip(ssl)
  if ssl == nil then ssl = false end
  for _, entry in ipairs(_M.portal_gui_listeners) do
    if entry.ssl == ssl then
      return entry.ip
    end
  end
  error("No portal ip found for ssl=" .. tostring(ssl), 2)
end


--- returns a pre-configured `http_client` for the Dev Portal API.
-- @function portal_api_client
-- @param timeout (optional, number) the timeout to use
function _M.portal_api_client(timeout)
  local portal_ip = get_portal_api_ip()
  local portal_port = get_portal_api_port()
  assert(portal_ip, "No portal_ip found in the configuration")
  return helpers.http_client(portal_ip, portal_port, timeout)
end


--- returns a pre-configured `http_client` for the Dev Portal GUI.
-- @function portal_gui_client
-- @param timeout (optional, number) the timeout to use
function _M.portal_gui_client(timeout)
  local portal_ip = get_portal_gui_ip()
  local portal_port = get_portal_gui_port()
  assert(portal_ip, "No portal_ip found in the configuration")
  return helpers.http_client(portal_ip, portal_port, timeout)
end

-- TODO: remove this, the clients already have a post helper method...
function _M.post(client, path, body, headers, expected_status)
  headers = headers or {}
  headers["Content-Type"] = "application/json"
  local res = assert(client:send{
    method = "POST",
    path = path,
    body = body or {},
    headers = headers
  })
  return cjson.decode(assert.res_status(expected_status or 201, res))
end


--- Creates a new Admin user.
-- The returned admin will have the rbac token set in field `rbac_user.raw_user_token`. This
-- is only for test purposes and should never be done outside the test environment.
-- @param email
-- @param custom_id
-- @param status
-- @param db db object (see `get_db_utils`)
-- @param username
-- @param workspace
-- @function create_admin
-- @return The admin object created, or `nil + err` on failure
function _M.create_admin(email, custom_id, status, db, username, workspace)
  local opts = workspace and { workspace = workspace.id }

  local admin = assert(db.admins:insert({
    username = username or email,
    custom_id = custom_id,
    email = email,
    status = status,
  }, opts))

  local token_res, err = admins_helpers.update_token(admin)
  if err then
    return nil, err
  end

  -- only used for tests so we can reference token
  -- WARNING: do not do this outside test environment
  admin.rbac_user.raw_user_token = token_res.body.token

  return admin
end


--- returns the cookie for the admin.
-- @function get_admin_cookie_basic_auth
-- @param client the http-client to use to make the auth request
-- @param username the admin user name to get the cookie for
-- @param password the password for the admin user
-- @return the cookie value, as returned in the `Set-Cookie` response header.
function _M.get_admin_cookie_basic_auth(client, username, password)
  local res = assert(client:send {
    method = "GET",
    path = "/auth",
    headers = {
      ["Authorization"] = "Basic " .. ngx.encode_base64(username .. ":"
                                                        .. password),
      ["Kong-Admin-User"] = username,
    }
  })

  assert.res_status(200, res)
  return res.headers["Set-Cookie"]
end



----------------
-- Variables/constants
-- @section exported-fields


--- Below is a list of fields/constants exported on the `spec-ee.helpers` module table:
-- @table helpers
-- @field portal_api_listeners the listener configuration for the Portal API
-- @field portal_gui_listeners the listener configuration for the Portal GUI
-- @field admin_gui_listeners the listener configuration for the Admin GUI


local http_flags = { "ssl", "http2", "proxy_protocol", "transparent" }
_M.portal_api_listeners = listeners._parse_listeners(helpers.test_conf.portal_api_listen, http_flags)
_M.portal_gui_listeners = listeners._parse_listeners(helpers.test_conf.portal_gui_listen, http_flags)
_M.admin_gui_listeners = listeners._parse_listeners(helpers.test_conf.admin_gui_listen, http_flags)


do
  local resty_ws_client = require "resty.websocket.client"
  local ws = require "spec-ee.fixtures.websocket"
  local ws_const = require "spec-ee.fixtures.websocket.constants"
  local inspect = require "inspect"

  do
    -- ensure Kong/lua-resty-websocket is installed
    local ws_ver = tostring(resty_ws_client._VERSION)
    assert(ws_ver == "0.2.0", "unexpected resty.websocket.client version: " .. ws_ver)
  end


  local function response_status(res)
    if type(res) ~= "string" then
      error("expected response data as a string", 2)
    end

    -- 123456789012345678901234567890
    -- 000000000111111111122222222223
    -- HTTP/1.1 301 Moved Permanently
    local version = tonumber(res:sub(6, 8))
    if not version then
      return nil, "failed parsing HTTP response version"
    end

    local status = tonumber(res:sub(10, 12))
    if not status then
      return nil, "failed parsing HTTP response status"
    end

    local reason = res:match("[^\r\n]+", 14)

    return status, version, reason
  end

  local headers_mt = {
    __index = function(self, k)
      return rawget(self, k:lower())
    end,

    __newindex = function(self, k, v)
      return rawset(self, k:lower(), v)
    end,
  }


  local function add_header(t, name, value)
    if not name or not value then
      return
    end

    if t[name] then
      value = { t[name], value }
    end
    t[name] = value
  end


  local function response_headers(res)
    if type(res) ~= "string" then
      return nil, "expected response data as a string"
    end

    local seen_status_line = false

    local headers = setmetatable({}, headers_mt)

    for line in res:gmatch("([^\r\n]+)") do
      if seen_status_line then
        local name, value = line:match([[^([^:]+):%s*(.+)]])

        add_header(headers, name, value)
      else
        seen_status_line = true
      end
    end

    return headers
  end

  local function format_request_headers(headers)
    if not headers then return end

    local t = {}

    for i = 1, #headers do
      t[i] = headers[i]
      headers[i] = nil
    end
    for k, v in pairs(headers) do
      table.insert(t, k .. ": " .. v)
    end

    return t
  end

  local fmt = string.format

  local function handle_failure(params, uri, err, res, id)
    local msg = {
      "WebSocket handshake failed!",
      "--- Request URI: " .. uri,
      "--- Request Params:", inspect(params),
      "--- Error: ", err or "unknown error",
      "--- Response:", res or "<none>",
    }

    -- attempt to retrieve the request ID from the request or response headers
    local header = ws_const.headers.id
    id = id or
         params and
         params.headers and
         params.headers[header] or
         (response_headers(res) or {})[header]

    if id then
      table.insert(msg, "--- Request ID: " .. id)
      local log = ws.get_session_log(id)
      if log then
        table.insert(msg, "--- kong.log.serialize():")
        table.insert(msg, inspect(log))
      end
    end

    table.insert(msg, "---")
    assert(nil, table.concat(msg, "\n\n"))
  end


  local function read_body() return "" end

  local OPCODES = ws_const.opcode

  ---@param client resty.websocket.client
  ---@param data string
  ---@return boolean ok
  ---@return string? error
  local function init_fragment(client, opcode, data)
    return client:send_frame(false, opcode, data)
  end

  ---@param client resty.websocket.client
  ---@param data string
  ---@return boolean ok
  ---@return string? error
  local function continue_fragment(client, data)
    return client:send_frame(false, OPCODES.continuation, data)
  end

  ---@param client resty.websocket.client
  ---@param data string
  ---@return boolean ok
  ---@return string? error
  local function finish_fragment(client, data)
    return client:send_frame(true, OPCODES.continuation, data)
  end

  ---@param client resty.websocket.client
  ---@param typ '"text"'|'"binary"'
  ---@param data string[]
  ---@return boolean ok
  ---@return string? error
  local function send_fragments(client, typ, data)
    assert(typ == "text" or typ == "string",
           "attempt to fragment non-data frame")

    local opcode = OPCODES[typ]
    local ok, err
    local len = #data
    for i = 1, len do
      local first = i == 1
      local last = i == len

      local payload = data[i]

      -- single length: just send a single frame
      if first and last then
        ok, err = client:send_frame(true, opcode, payload)

      -- first frame: init fragment
      elseif first then
        ok, err = init_fragment(client, opcode, payload)

      -- last frame: finish fragment
      elseif last then
        ok, err = finish_fragment(client, payload)

      -- in the middle: continue
      else
        ok, err = continue_fragment(client, payload)
      end

      if not ok then
        return nil, fmt("failed sending %s fragment %s/%s: %s",
                        typ, i, len, err)
      end
    end

    return true
  end

  ---@class ws.test.client.response : table
  ---@field status number
  ---@field reason string
  ---@field version number
  ---@field headers table<string, string|string[]>
  ---@field read_body function

  ---@class ws.test.client
  ---@field client resty.websocket.client
  ---@field id string
  ---@field response ws.test.client.response
  local ws_client = {}

  ---@param data string|string[]
  ---@return boolean ok
  ---@return string? error
  function ws_client:send_text(data)
    if type(data) == "table" then
      return send_fragments(self.client, "text", data)
    end

    return self.client:send_text(data)
  end

  ---@param data string|string[]
  ---@return boolean ok
  ---@return string? error
  function ws_client:send_binary(data)
    if type(data) == "table" then
      return send_fragments(self.client, "binary", data)
    end

    return self.client:send_binary(data)
  end

  ---@param data string
  ---@return boolean ok
  ---@return string? error
  function ws_client:init_text_fragment(data)
    return init_fragment(self.client, OPCODES.text, data)
  end

  ---@param data string
  ---@return boolean ok
  ---@return string? error
  function ws_client:init_binary_fragment(data)
    return init_fragment(self.client, OPCODES.binary, data)
  end

  ---@param data string
  ---@return boolean ok
  ---@return string? error
  function ws_client:send_continue(data)
    return continue_fragment(self.client, data)
  end

  ---@param data string
  ---@return boolean ok
  ---@return string? error
  function ws_client:send_final_fragment(data)
    return finish_fragment(self.client, data)
  end


  ---@param data? string
  ---@return boolean ok
  ---@return string? error
  function ws_client:send_ping(data)
    return self.client:send_ping(data)
  end

  ---@param data? string
  ---@return boolean ok
  ---@return string? error
  function ws_client:send_pong(data)
    return self.client:send_pong(data)
  end

  ---@param data? string
  ---@param status? integer
  ---@return boolean ok
  ---@return string? error
  function ws_client:send_close(data, status)
    return self.client:send_close(status, data)
  end

  function ws_client:send_frame(...)
    return self.client:send_frame(...)
  end

  ---@return string? data
  ---@return string? type
  ---@return string|number|nil err
  function ws_client:recv_frame()
    return self.client:recv_frame()
  end

  -- unlike resty.websocket.client, this does _not_ attempt to send
  -- a close frame
  ---@return boolean ok
  ---@return string? error
  function ws_client:close()
    return self.client.sock:close()
  end

  ws_client.__index = ws_client

  ---@class ws.test.client.opts : resty.websocket.client.connect.opts
  ---@field path            string
  ---@field query           table
  ---@field scheme          '"ws"'|'"wss"'
  ---@field port            number
  ---@field addr            string
  ---@field fail_on_error   boolean
  ---@field connect_timeout number
  ---@field write_timeout   number
  ---@field read_timeout    number
  ---@field timeout         number

  ---
  -- Instantiate a WebSocket client
  --
  ---@param opts? ws.test.client.opts
  ---@return ws.test.client client
  function _M.ws_client(opts)
    opts = opts or {}

    local query = opts.query or {}
    local scheme = opts.scheme or "ws"

    local port = opts.port
    if not port then
      port = (scheme == "wss" and 443) or 80
    end

    local client, err = resty_ws_client:new()
    assert(client, err)

    local qs = ngx.encode_args(query)
    if qs and qs ~= "" then qs = "?" .. qs end

    local uri = fmt("%s://%s:%s%s%s",
      scheme,
      opts.addr or opts.host or "127.0.0.1",
      port,
      opts.path or "/",
      qs
    )

    if opts.connect_timeout or opts.write_timeout or opts.read_timeout then
      client.sock:settimeouts(opts.connect_timeout,
                              opts.write_timeout,
                              opts.read_timeout)
    elseif opts.timeout then
      client.sock:settimeout(opts.timeout)
    end

    local id = opts.headers and opts.headers[ws_const.headers.id]

    local params = {
      host            = opts.host or opts.addr or "127.0.0.1",
      origin          = opts.origin,
      key             = opts.key,
      server_name     = opts.server_name or opts.host or opts.addr,
      keep_response   = true,
      headers         = format_request_headers(opts.headers),
      client_cert     = opts.client_cert,
      client_priv_key = opts.client_priv_key,
    }

    local ok, res
    ok, err, res = client:connect(uri, params)

    if opts.fail_on_error and (not ok or err ~= nil) then
      handle_failure(params, uri, err, res, id)
    end

    assert.is_not_nil(res, "resty.websocket.client:connect() returned no response data")

    local status, version, reason = response_status(res)
    assert.not_nil(status, version)

    local response = {
      status = status,
      reason = reason,
      version = version,
      headers = response_headers(res),

      -- without this function the response modifier won't think this is
      -- a valid response object
      read_body = read_body,
    }

    return setmetatable({
      client = client,
      response = response,
      id = response.headers[ws_const.headers.id],
    }, ws_client )
  end

  ---
  -- Establish a WebSocket connection to Kong
  --
  ---@param opts? ws.test.client.opts
  ---@return ws.test.client client
  function _M.ws_proxy_client(opts)
    opts = opts or {}
    local ssl = opts.scheme == "wss"

    if not opts.addr then
      opts.addr = helpers.get_proxy_ip(ssl)
    end

    if not opts.port then
      opts.port = helpers.get_proxy_port(ssl)
    end

    if opts.fail_on_error ~= false then
      opts.fail_on_error = true
    end

    return assert(_M.ws_client(opts))
  end
end


return _M
