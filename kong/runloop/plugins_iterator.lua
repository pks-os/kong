local workspaces = require "kong.workspaces"
local constants = require "kong.constants"
local tablepool = require "tablepool"
local req_dyn_hook = require "kong.dynamic_hook"


local kong = kong
local error = error
local assert = assert
local var = ngx.var
local null = ngx.null
local pcall = pcall
local subsystem = ngx.config.subsystem
local pairs = pairs
local ipairs = ipairs
local format = string.format
local fetch_table = tablepool.fetch
local release_table = tablepool.release
local uuid = require("kong.tools.uuid").uuid
local get_updated_monotonic_ms = require("kong.tools.time").get_updated_monotonic_ms
local req_dyn_hook_disable_by_default = req_dyn_hook.disable_by_default


local TTL_ZERO = { ttl = 0 }
local GLOBAL_QUERY_OPTS = { workspace = null, show_ws_id = true }


local NON_COLLECTING_PHASES, DOWNSTREAM_PHASES, DOWNSTREAM_PHASES_COUNT, COLLECTING_PHASE, CONFIGURE_PHASE
do
  if subsystem == "stream" then
    NON_COLLECTING_PHASES = {
      "certificate",
      "log",
    }

    DOWNSTREAM_PHASES = {
      "log",
    }

    COLLECTING_PHASE = "preread"

  else
    NON_COLLECTING_PHASES = {
      "certificate",
      "rewrite",
      "response",
      "header_filter",
      "body_filter",
      "log",
    }

    DOWNSTREAM_PHASES = {
      "response",
      "header_filter",
      "body_filter",
      "log",
    }

    COLLECTING_PHASE = "access"
  end

  DOWNSTREAM_PHASES_COUNT = #DOWNSTREAM_PHASES
  CONFIGURE_PHASE = "configure"
end


local PLUGINS_NS = "plugins." .. subsystem
local ENABLED_PLUGINS
local LOADED_PLUGINS
local CONFIGURABLE_PLUGINS


local PluginsIterator = {}


---
-- Build a compound key by string formatting route_id, service_id, and consumer_id with colons as separators.
--
-- @function build_compound_key
-- @tparam string|nil route_id The route identifier. If `nil`, an empty string is used.
-- @tparam string|nil service_id The service identifier. If `nil`, an empty string is used.
-- @tparam string|nil consumer_id The consumer identifier. If `nil`, an empty string is used.
-- @treturn string The compound key, in the format `route_id:service_id:consumer_id`.
local function build_compound_key(route_id, service_id, consumer_id)
  return format("%s:%s:%s", route_id or "", service_id or "", consumer_id or "")
end


local PLUGIN_GLOBAL_KEY = build_compound_key() -- all nil


local function get_table_for_ctx(ws)
  local tbl = fetch_table(PLUGINS_NS, 0, DOWNSTREAM_PHASES_COUNT + 2)
  if not tbl.initialized then
    for i = 1, DOWNSTREAM_PHASES_COUNT do
      tbl[DOWNSTREAM_PHASES[i]] = kong.table.new(ws.plugins[0] * 2, 1)
    end
    tbl.initialized = true
  end

  for i = 1, DOWNSTREAM_PHASES_COUNT do
    tbl[DOWNSTREAM_PHASES[i]][0] = 0
  end

  tbl.ws = ws

  return tbl
end


local function release(ctx)
  local plugins = ctx.plugins
  if plugins then
    release_table(PLUGINS_NS, plugins, true)
    ctx.plugins = nil
  end
end


local function get_loaded_plugins()
  return assert(kong.db.plugins:get_handlers())
end


local function get_configurable_plugins()
  local i = 0
  local plugins_with_configure_phase = {}
  for _, plugin in ipairs(LOADED_PLUGINS) do
    if plugin.handler[CONFIGURE_PHASE] then
      i = i + 1
      local name = plugin.name
      plugins_with_configure_phase[name] = true
      plugins_with_configure_phase[i] = plugin
    end
  end
  return plugins_with_configure_phase
end


local function should_process_plugin(plugin)
  if plugin.enabled then
    local c = constants.PROTOCOLS_WITH_SUBSYSTEM
    for _, protocol in ipairs(plugin.protocols) do
      if c[protocol] == subsystem then
        return true
      end
    end
  end
end


local function get_plugin_config(plugin, name, ws_id)
  if not plugin or not plugin.enabled then
    return
  end

  local cfg = plugin.config or {}

  cfg.route_id = plugin.route and plugin.route.id
  cfg.service_id = plugin.service and plugin.service.id
  cfg.consumer_id = plugin.consumer and plugin.consumer.id
  local is_global = true
  local expr = ''
  if cfg.route_id then
    expr = string.format('%s %s == "%s"', expr, "route.id", cfg.route_id)
    is_global = false
  end
  if cfg.service_id then
    if expr ~= "" then
      expr = expr .. " and "
    end
    expr = string.format('%s %s == "%s"', expr, "service.id", cfg.service_id)
    is_global = false
  end
  if cfg.consumer_id then
    if expr ~= "" then
      expr = expr .. " and "
    end
    expr = string.format('%s %s == "%s"', expr, "consumer.id", cfg.consumer_id)
    is_global = false
  end
  print("cfg = " .. require("inspect")(cfg))
  cfg.expression = plugin.expression or expr
  cfg.plugin_instance_name = plugin.instance_name
  cfg.__plugin_id = plugin.id
  cfg.__ws_id = ws_id

  local key = kong.db.plugins:cache_key(name,
                                        cfg.route_id,
                                        cfg.service_id,
                                        cfg.consumer_id,
                                        nil,
                                        ws_id)

  -- TODO: deprecate usage of __key__ as id of plugin
  if not cfg.__key__ then
    cfg.__key__ = key
    -- generate a unique sequence across workers
    -- with a seq 0, plugin server generates an unused random instance id
    local next_seq, err = ngx.shared.kong:incr("plugins_iterator:__seq__", 1, 0, 0)
    if err then
      next_seq = 0
    end
    cfg.__seq__ = next_seq
  end

  return cfg
end


---
-- Lookup a configuration for a given combination of route_id, service_id, consumer_id
--
-- The function checks various combinations of route_id, service_id and consumer_id to find
-- the best matching configuration in the given 'combos' table. The priority order is as follows:
--
-- 1. Route, Service, Consumer
-- 2. Route, Consumer
-- 3. Service, Consumer
-- 4. Route, Service
-- 5. Consumer
-- 6. Route
-- 7. Service
-- 8. Global
--
-- @function lookup_cfg
-- @tparam table combos A table containing configuration data indexed by compound keys.
-- @tparam string|nil route_id The route identifier.
-- @tparam string|nil service_id The service identifier.
-- @tparam string|nil consumer_id The consumer identifier.
-- @return any|nil The configuration corresponding to the best matching combination, or 'nil' if no configuration is found.
local function lookup_cfg(combos, route_id, service_id, consumer_id)
  -- Use the build_compound_key function to create an index for the 'combos' table
  if route_id and service_id and consumer_id then
    local key = build_compound_key(route_id, service_id, consumer_id)
    if combos[key] then
      return combos[key]
    end
  end

  if route_id and consumer_id then
    local key = build_compound_key(route_id, nil, consumer_id)
    if combos[key] then
      return combos[key]
    end
  end

  if service_id and consumer_id then
    local key = build_compound_key(nil, service_id, consumer_id)
    if combos[key] then
      return combos[key]
    end
  end

  if route_id and service_id then
    local key = build_compound_key(route_id, service_id, nil)
    if combos[key] then
      return combos[key]
    end
  end

  if consumer_id then
    local key = build_compound_key(nil, nil, consumer_id)
    if combos[key] then
      return combos[key]
    end
  end

  if route_id then
    local key = build_compound_key(route_id, nil, nil)
    if combos[key] then
      return combos[key]
    end
  end

  if service_id then
    local key = build_compound_key(nil, service_id, nil)
    if combos[key] then
      return combos[key]
    end
  end

  return combos[PLUGIN_GLOBAL_KEY]
end


---
-- Load the plugin configuration based on the context (route, service, and consumer) and plugin handler rules.
--
-- This function filters out route, service, and consumer information from the context based on the plugin handler rules,
-- and then calls the 'lookup_cfg' function to get the best matching plugin configuration for the given combination of
-- route_id, service_id, and consumer_id.
--
-- @function load_configuration_through_combos
-- @tparam table ctx A table containing the context information, including route, service, and authenticated_consumer.
-- @tparam table combos A table containing configuration data indexed by compound keys.
-- @tparam table plugin A table containing plugin information, including the handler with no_route, no_service, and no_consumer rules.
-- @treturn any|nil The configuration corresponding to the best matching combination, or 'nil' if no configuration is found.
local function load_configuration_through_combos(ctx, combos, plugin)
  -- Filter out route, service, and consumer based on the plugin handler rules and get their ids
  local handler = plugin.handler
  local route_id = (not handler.no_route and ctx.route) and ctx.route.id or nil
  local service_id = (not handler.no_service and ctx.service) and ctx.service.id or nil
  local consumer_id = (not handler.no_consumer and ctx.authenticated_consumer) and ctx.authenticated_consumer.id or nil

  -- Call the lookup_cfg function to get the best matching plugin configuration
  return lookup_cfg(combos, route_id, service_id, consumer_id)
end


local function get_workspace(self, ctx)
  if not ctx then
    return self.ws[kong.default_workspace]
  end

  return self.ws[workspaces.get_workspace_id(ctx) or kong.default_workspace]
end


local function get_next_init_worker(plugins, i)
  local i = i + 1
  local plugin = plugins[i]
  if not plugin then
    return nil
  end

  if plugin.handler.init_worker then
    return i, plugin
  end

  return get_next_init_worker(plugins, i)
end


local function get_init_worker_iterator(self)
  if #self.loaded == 0 then
    return nil
  end

  return get_next_init_worker, self.loaded
end


local function get_next_global_or_collected_plugin(plugins, i)
  i = i + 2
  if i > plugins[0] then
    return nil
  end

  return i, plugins[i - 1], plugins[i]
end


local function get_global_iterator(self, phase)
  local plugins = self.globals[phase]
  local count = plugins and plugins[0] or 0
  if count == 0 then
    return nil
  end

  -- only execute this once per request
  if phase == "certificate" or (phase == "rewrite" and var.https ~= "on") then
    local i = 2
    while i <= count do
      kong.vault.update(plugins[i])
      i = i + 2
    end
  end

  return get_next_global_or_collected_plugin, plugins
end


local function get_collected_iterator(self, phase, ctx)
  local plugins = ctx.plugins
  if plugins then
    plugins = plugins[phase]
    if not plugins or plugins[0] == 0 then
      return nil
    end

    return get_next_global_or_collected_plugin, plugins
  end

  return get_global_iterator(self, phase)
end


local function get_next_and_collect(ctx, i)
  i = i + 1
  local ws = ctx.plugins.ws
  local plugins = ws.plugins
  if i > plugins[0] then
    return nil
  end

  local plugin = plugins[i]
  local name = plugin.name
  local cfg
  -- Only pass combos for the plugin we're operating on
  local combos = ws.combos[name]
  if combos then
    cfg = load_configuration_through_combos(ctx, combos, plugin)
    if cfg then
      kong.vault.update(cfg)
      local handler = plugin.handler
      local collected = ctx.plugins
      for j = 1, DOWNSTREAM_PHASES_COUNT do
        local phase = DOWNSTREAM_PHASES[j]
        if handler[phase] then
          local n = collected[phase][0] + 2
          collected[phase][0] = n
          collected[phase][n] = cfg
          collected[phase][n - 1] = plugin
          if phase == "response" and not ctx.buffered_proxying then
            ctx.buffered_proxying = true
          end
        end
      end

      if handler[COLLECTING_PHASE] then
        return i, plugin, cfg
      end
    end
  end

  return get_next_and_collect(ctx, i)
end


local function get_collecting_iterator(self, ctx)
  local ws = get_workspace(self, ctx)
  ctx.plugins = get_table_for_ctx(ws)
  if not ws then
    return nil
  end

  local plugins = ws.plugins
  if plugins[0] == 0 then
    return nil
  end

  return get_next_and_collect, ctx
end


local function new_ws_data()
  return {
    plugins = {},
  }
end


local function configure(configurable, ctx)
  -- Disable hooks that are selectively enabled by plugins
  -- in their :configure handler
  req_dyn_hook_disable_by_default("observability_logs")

  ctx = ctx or ngx.ctx
  local kong_global = require "kong.global"
  for _, plugin in ipairs(CONFIGURABLE_PLUGINS) do
    local name = plugin.name

    kong_global.set_namespaced_log(kong, plugin.name, ctx)
    local start = get_updated_monotonic_ms()
    local ok, err = pcall(plugin.handler[CONFIGURE_PHASE], plugin.handler, configurable[name])
    local elapsed = get_updated_monotonic_ms() - start
    kong_global.reset_log(kong, ctx)

    if not ok then
      kong.log.err("failed to execute plugin '", name, ":", CONFIGURE_PHASE, " (", err, ")")
    else
      if elapsed > 50 then
        kong.log.notice("executing plugin '", name, ":", CONFIGURE_PHASE, " took excessively long: ", elapsed, " ms")
      end
    end
  end
end


local function create_configure(configurable)
  -- we only want the plugin_iterator:configure to be only available on proxying
  -- nodes (or data planes), thus we disable it if this code gets executed on control
  -- plane or on a node that does not listen any proxy ports.
  --
  -- TODO: move to PDK, e.g. kong.node.is_proxying()
  if kong.configuration.role == "control_plane"
  or ((subsystem == "http"   and #kong.configuration.proxy_listeners == 0) or
      (subsystem == "stream" and #kong.configuration.stream_listeners == 0))
  then
    return function() end
  end

  return function(self, ctx)
    configure(configurable, ctx)
    -- self destruct the function so that it cannot be called twice
    -- if it ever happens to be called twice, it should be very visible
    -- because of this.
    self.configure = nil
    configurable = nil
  end
end


function PluginsIterator.new(version)
  local is_not_dbless = kong.db.strategy ~= "off"
  if is_not_dbless then
    if not version then
      error("version must be given", 2)
    end
  end

  LOADED_PLUGINS = LOADED_PLUGINS or get_loaded_plugins()
  CONFIGURABLE_PLUGINS = CONFIGURABLE_PLUGINS or get_configurable_plugins()
  ENABLED_PLUGINS = ENABLED_PLUGINS or kong.configuration.loaded_plugins

  local ws_id = workspaces.get_workspace_id() or kong.default_workspace
  -- indexed by workspace
  local plugins_table = {
    [ws_id] = {}
  }

  local schema_mod = require("resty.router.schema")
  local router_mod = require("resty.router.router")
  local context_mod = require("resty.router.context")

  local schema = schema_mod.new()
  schema:add_field("route.name", "String")
  schema:add_field("route.id", "String")
  schema:add_field("service.name", "String")
  schema:add_field("service.id", "String")
  -- schema:add_field("http.host", "String")
  local context = context_mod.new(schema)
  local router = router_mod.new(schema)


  local counter = 0

  local configurable = {}
  local has_plugins = false

  local globals = {}
  local page_size = kong.db.plugins.pagination.max_page_size
  for plugin, err in kong.db.plugins:each(page_size, GLOBAL_QUERY_OPTS) do
    if err then
      return nil, err
    end

    local name = plugin.name

    if is_not_dbless and counter > 0 and counter % page_size == 0 and kong.core_cache then
      local new_version, err = kong.core_cache:get("plugins_iterator:version", TTL_ZERO, uuid)
      if err then
        return nil, "failed to retrieve plugins iterator version: " .. err
      end

      if new_version ~= version then
        -- the plugins iterator rebuild is being done by a different process at
        -- the same time, stop here and let the other one go for it
        kong.log.info("plugins iterator was changed while rebuilding it")
        return
      end
    end

    if not should_process_plugin(plugin) then
      goto continue
    end
    -- Get the plugin configuration for the specified workspace (ws_id)
    local cfg = get_plugin_config(plugin, name, plugin.ws_id)
    if not cfg then
      goto continue
    end
    has_plugins = true

    if CONFIGURABLE_PLUGINS[name] then
      configurable[name] = configurable[name] or {}
      configurable[name][#configurable[name] + 1] = cfg
    end


    -- Create a new entry for the plugin's workspace in the
    if not plugins_table[plugin.ws_id] then
      plugins_table[plugin.ws_id] = {}
    end
    local handler = kong.db.plugins:get_handlers_by_name(plugin.name)

    -- build the plugins table for easier consumption of the respective phase. This means we need
    -- to build a table that is indexed by the workspace and secondly by the phase and
    -- contains the plugin configuration as well as the handler for that phase.
    for _, phase in pairs{"rewrite", "access", "log"} do
      if handler[phase] then
        -- insert into table
        if not plugins_table[plugin.ws_id][phase] then
          plugins_table[plugin.ws_id][phase] = {}
        end
        plugins_table[plugin.ws_id][phase][cfg.__plugin_id] = { cfg = cfg, handler_fn = handler[phase], name = name }
        print("name = " .. require("inspect")(name))
        print("cfg.expression = " .. require("inspect")(cfg.expression))
        print("handler = " .. require("inspect")(handler))
        -- add PRIORITY so that the matching is done in the correct order
        local ok, err = router:add_matcher(handler.PRIORITY, cfg.__plugin_id, cfg.expression)
        print("ok = " .. require("inspect")(ok))
        print("err = " .. require("inspect")(err))
      end
    end
    print("plugins_table = " .. require("inspect")(plugins_table))

    ::continue::
  end

  return {
    version = version,
    plugins_table = plugins_table,
    router = router,
    router_context = context,
    schema = schema,
    ws = {},
    loaded = LOADED_PLUGINS,
    configure = create_configure(configurable),
    globals = globals,
    get_init_worker_iterator = get_init_worker_iterator,
    get_global_iterator = get_global_iterator,
    get_collecting_iterator = get_collecting_iterator,
    get_collected_iterator = get_collected_iterator,
    has_plugins = has_plugins,
    release = release,
  }
end


-- for testing
PluginsIterator.lookup_cfg = lookup_cfg
PluginsIterator.build_compound_key = build_compound_key


return PluginsIterator
