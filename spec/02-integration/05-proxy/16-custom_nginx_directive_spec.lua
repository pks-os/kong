-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers = require "spec.helpers"


describe("Custom NGINX directives", function()
  local proxy_client
  local bp

  local function start(config)
    return function()
      bp.routes:insert {
        hosts = { "headers-inspect.test" },
      }

      config = config or {}
      config.nginx_conf = "spec/fixtures/custom_nginx.template"

      assert(helpers.start_kong(config))
    end
  end

  lazy_setup(function()
    bp = helpers.get_db_utils(nil, {
      "routes",
      "services",
    })
  end)

  before_each(function()
    proxy_client = helpers.proxy_client()
  end)

  after_each(function()
    if proxy_client then
      proxy_client:close()
    end
  end)

  describe("with config value 'nginx_proxy_add_header=foo-header bar-value'", function()

    lazy_setup(start {
      ["nginx_proxy_add_header"] = "foo-header bar-value"
    })

    lazy_teardown(helpers.stop_kong)

    it("should insert 'foo-header' header", function()
      local res = assert(proxy_client:send {
        method  = "GET",
        path    = "/get",
        headers = {
          host  = "headers-inspect.test",
        }
      })

      assert.res_status(200, res)
      assert.equal("bar-value", res.headers["foo-header"])
    end)
  end)
end)
