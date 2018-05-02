local cjson        = require "cjson"
local helpers      = require "spec.helpers"
local dao_helpers  = require "spec.02-integration.03-dao.helpers"


local POLL_INTERVAL = 0.3


dao_helpers.for_each_dao(function(kong_conf)

describe("proxy-cache invalidations via: " .. kong_conf.database, function()

  local client_1
  local client_2
  local admin_client_1
  local admin_client_2
  local api1
  local api2
  local plugin1
  local plugin2

  local dao
  local wait_for_propagation

  setup(function()
    local kong_dao_factory = require "kong.dao.factory"
    dao = assert(kong_dao_factory.new(kong_conf))
    dao:truncate_tables()
    helpers.dao:run_migrations()

    api1 = assert(dao.apis:insert {
      name = "api-1",
      hosts = { "api-1.com" },
      upstream_url = "http://httpbin.org",
    })

    api2 = assert(dao.apis:insert {
      name = "api-2",
      hosts = { "api-2.com" },
      upstream_url = "http://httpbin.org",
    })

    plugin1 = assert(dao.plugins:insert {
      name = "proxy-cache",
      api_id = api1.id,
      config = {
        strategy = "memory",
        content_type = { "text/plain", "application/json" },
        memory = {
          dictionary_name = "kong",
        },
      },
    })

    plugin2 = assert(dao.plugins:insert {
      name = "proxy-cache",
      api_id = api2.id,
      config = {
        strategy = "memory",
        content_type = { "text/plain", "application/json" },
        memory = {
          dictionary_name = "kong",
        },
      },
    })

    local db_update_propagation = kong_conf.database == "cassandra" and 3 or 0

    assert(helpers.start_kong {
      log_level             = "debug",
      prefix                = "servroot1",
      database              = kong_conf.database,
      proxy_listen          = "0.0.0.0:8000",
      proxy_listen_ssl      = "0.0.0.0:8443",
      admin_listen          = "0.0.0.0:8001",
      admin_gui_listen      = "0.0.0.0:8002",
      admin_ssl             = false,
      admin_gui_ssl         = false,
      db_update_frequency   = POLL_INTERVAL,
      db_update_propagation = db_update_propagation,
      custom_plugins        = "proxy-cache",
    })

    assert(helpers.start_kong {
      log_level             = "debug",
      prefix                = "servroot2",
      database              = kong_conf.database,
      proxy_listen          = "0.0.0.0:9000",
      proxy_listen_ssl      = "0.0.0.0:9443",
      admin_listen          = "0.0.0.0:9001",
      admin_gui_listen      = "0.0.0.0:9002",
      admin_ssl             = false,
      admin_gui_ssl         = false,
      db_update_frequency   = POLL_INTERVAL,
      db_update_propagation = db_update_propagation,
      custom_plugins        = "proxy-cache",
    })

    client_1       = helpers.http_client("127.0.0.1", 8000)
    client_2       = helpers.http_client("127.0.0.1", 9000)
    admin_client_1 = helpers.http_client("127.0.0.1", 8001)
    admin_client_2 = helpers.http_client("127.0.0.1", 9001)

    wait_for_propagation = function()
      ngx.sleep(POLL_INTERVAL + db_update_propagation)
    end
  end)

  teardown(function()
    helpers.stop_kong("servroot1", true)
    helpers.stop_kong("servroot2", true)

    dao:truncate_tables()
  end)

  before_each(function()
    client_1       = helpers.http_client("127.0.0.1", 8000)
    client_2       = helpers.http_client("127.0.0.1", 9000)
    admin_client_1 = helpers.http_client("127.0.0.1", 8001)
    admin_client_2 = helpers.http_client("127.0.0.1", 9001)
  end)

  after_each(function()
    client_1:close()
    client_2:close()
    admin_client_1:close()
    admin_client_2:close()
  end)

  describe("cache purge", function()
    local cache_key, cache_key2

    setup(function()
      -- prime cache entries on both instances
      local res_1 = assert(client_1:send {
        method = "GET",
        path = "/get",
        headers = {
          Host = "api-1.com",
        },
      })

      local body = assert.res_status(200, res_1)
      assert.same("Miss", res_1.headers["X-Cache-Status"])
      cache_key = res_1.headers["X-Cache-Key"]

      local res_2 = assert(client_2:send {
        method = "GET",
        path = "/get",
        headers = {
          host = "api-1.com",
        },
      })

      body = assert.res_status(200, res_2)
      assert.same("Miss", res_2.headers["X-Cache-Status"])
      assert.same(cache_key, res_2.headers["X-Cache-Key"])

      res_1 = assert(client_1:send {
        method = "GET",
        path = "/get",
        headers = {
          host = "api-2.com",
        },
      })

      body = assert.res_status(200, res_1)
      assert.same("Miss", res_1.headers["X-Cache-Status"])
      cache_key2 = res_1.headers["X-Cache-Key"]
      assert.not_same(cache_key, cache_key2)

      res_2 = assert(client_2:send {
        method = "GET",
        path = "/get",
        headers = {
          host = "api-2.com",
        },
      })

      body = assert.res_status(200, res_2)
      assert.same("Miss", res_2.headers["X-Cache-Status"])
    end)

    it("propagates purges via cluster events mechanism", function()
      local res_1 = assert(client_1:send {
        method = "GET",
        path = "/get",
        headers = {
          host = "api-1.com",
        },
      })

      local body = assert.res_status(200, res_1)
      assert.same("Hit", res_1.headers["X-Cache-Status"])

      local res_2 = assert(client_2:send {
        method = "GET",
        path = "/get",
        headers = {
          host = "api-1.com",
        },
      })

      body = assert.res_status(200, res_2)
      assert.same("Hit", res_2.headers["X-Cache-Status"])

      -- now purge the entry
      local res = assert(admin_client_1:send {
        method = "DELETE",
        path = "/proxy-cache/" .. plugin1.id .. "/caches/" .. cache_key,
      })

      assert.res_status(204, res)

      -- wait for propagation
      wait_for_propagation()

      -- assert that the entity was purged from the second instance
      res = assert(admin_client_2:send {
        method = "GET",
        path = "/proxy-cache/" .. plugin1.id .. "/caches/" .. cache_key,
      })

      assert.res_status(404, res)

      -- refresh and purge with our second endpoint
      res_1 = assert(client_1:send {
        method = "GET",
        path = "/get",
        headers = {
          Host = "api-1.com",
        },
      })

      body = assert.res_status(200, res_1)
      assert.same("Miss", res_1.headers["X-Cache-Status"])

      res_2 = assert(client_2:send {
        method = "GET",
        path = "/get",
        headers = {
          host = "api-1.com",
        },
      })

      body = assert.res_status(200, res_2)
      assert.same("Miss", res_2.headers["X-Cache-Status"])
      assert.same(cache_key, res_2.headers["X-Cache-Key"])

      -- now purge the entry
      res = assert(admin_client_1:send {
        method = "DELETE",
        path = "/proxy-cache/" .. cache_key,
      })

      assert.res_status(204, res)

      -- wait for propagation
      wait_for_propagation()

      -- assert that the entity was purged from the second instance
      res = assert(admin_client_2:send {
        method = "GET",
        path = "/proxy-cache/" .. cache_key,
      })

      assert.res_status(404, res)

    end)

    it("does not affect cache entries under other plugin instances", function()
      local res = assert(admin_client_1:send {
        method = "GET",
        path = "/proxy-cache/" .. plugin2.id .. "/caches/" .. cache_key2,
      })

      assert.res_status(200, res)

      local res = assert(admin_client_2:send {
        method = "GET",
        path = "/proxy-cache/" .. plugin2.id .. "/caches/" .. cache_key2,
      })

      assert.res_status(200, res)
    end)

    it("propagates global purges", function()
      local res = assert(admin_client_1:send {
        method = "DELETE",
        path = "/proxy-cache/",
      })

      assert.res_status(204, res)

      wait_for_propagation()

      local res = assert(admin_client_1:send {
        method = "GET",
        path = "/proxy-cache/" .. plugin2.id .. "/caches/" .. cache_key2,
      })

      assert.res_status(404, res)

      local res = assert(admin_client_2:send {
        method = "GET",
        path = "/proxy-cache/" .. plugin2.id .. "/caches/" .. cache_key2,
      })

      assert.res_status(404, res)
    end)
  end)
end)

end)
