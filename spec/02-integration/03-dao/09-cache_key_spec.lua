local helpers = require "spec.helpers"

describe("<dao>:cache_key()", function()
  describe("generates unique cache keys for core entities", function()
    ngx.ctx.workspaces = nil --ideally test with default workspace

    it("(Consumers)", function()
      local consumer_id = "59c7fb5e-3430-11e7-b51f-784f437104fa"

<<<<<<< HEAD
      local cache_key = helpers.dao.consumers:cache_key(consumer_id)
      assert.equal("consumers:" .. consumer_id .. ":::::", cache_key)
||||||| merged common ancestors
      local cache_key = helpers.dao.consumers:cache_key(consumer_id)
      assert.equal("consumers:" .. consumer_id .. "::::", cache_key)
=======
      -- raw string is a backwards-compatible alternative for entities
      -- with an `id` as their primary key
      local cache_key = helpers.db.consumers:cache_key(consumer_id)
      assert.equal("consumers:" .. consumer_id .. "::::", cache_key)

      -- primary key in table form works the same
      cache_key = helpers.db.consumers:cache_key({ id = consumer_id })
      assert.equal("consumers:" .. consumer_id .. "::::", cache_key)
>>>>>>> 0.15.0
    end)

    it("(Plugins)", function()
      local name     = "my-plugin"
      local route    = { id = "db81fe58-bf43-11e7-8e5c-784f437104fa" }
      local service  = { id = "7c46b5f8-3430-11e7-afec-784f437104fa" }
      local consumer = { id = "59c7fb5e-3430-11e7-b51f-784f437104fa" }

      -- raw string
      local cache_key = helpers.db.plugins:cache_key(name)
      assert.equal("plugins:" .. name .. "::::", cache_key)

      -- various cache key tables:

<<<<<<< HEAD
      local cache_key = helpers.dao.plugins:cache_key(name)
      assert.equal("plugins:" .. name .. ":::::", cache_key)
||||||| merged common ancestors
      local cache_key = helpers.dao.plugins:cache_key(name)
      assert.equal("plugins:" .. name .. "::::", cache_key)
=======
      cache_key = helpers.db.plugins:cache_key({ name = name })
      assert.equal("plugins:" .. name .. "::::", cache_key)
>>>>>>> 0.15.0

<<<<<<< HEAD
      cache_key = helpers.dao.plugins:cache_key(name, route_id)
      assert.equal("plugins:" .. name .. ":" .. route_id .. "::::", cache_key)
||||||| merged common ancestors
      cache_key = helpers.dao.plugins:cache_key(name, route_id)
      assert.equal("plugins:" .. name .. ":" .. route_id .. ":::", cache_key)
=======
      cache_key = helpers.db.plugins:cache_key({ name = name, route = route })
      assert.equal("plugins:" .. name .. ":" .. route.id .. ":::", cache_key)
>>>>>>> 0.15.0

<<<<<<< HEAD
      cache_key = helpers.dao.plugins:cache_key(name, route_id, service_id)
      assert.equal("plugins:" .. name .. ":" .. route_id .. ":" ..
                   service_id .. ":::", cache_key)
||||||| merged common ancestors
      cache_key = helpers.dao.plugins:cache_key(name, route_id, service_id)
      assert.equal("plugins:" .. name .. ":" .. route_id .. ":" ..
                   service_id .. "::", cache_key)
=======
      cache_key = helpers.db.plugins:cache_key({ name = name, route = route, service = service })
      assert.equal("plugins:" .. name .. ":" .. route.id .. ":" ..
                   service.id .. "::", cache_key)
>>>>>>> 0.15.0

<<<<<<< HEAD
      cache_key = helpers.dao.plugins:cache_key(name, route_id, service_id, consumer_id)
      assert.equal("plugins:" .. name .. ":" .. route_id .. ":" ..
                   service_id .. ":" .. consumer_id .. "::", cache_key)
||||||| merged common ancestors
      cache_key = helpers.dao.plugins:cache_key(name, route_id, service_id, consumer_id)
      assert.equal("plugins:" .. name .. ":" .. route_id .. ":" ..
                   service_id .. ":" .. consumer_id .. ":", cache_key)
=======
      cache_key = helpers.db.plugins:cache_key({ name = name, route = route, service = service, consumer = consumer })
      assert.equal("plugins:" .. name .. ":" .. route.id .. ":" ..
                   service.id .. ":" .. consumer.id .. ":", cache_key)
>>>>>>> 0.15.0

<<<<<<< HEAD
      cache_key = helpers.dao.plugins:cache_key(name, nil, service_id)
      assert.equal("plugins:" .. name .. "::" .. service_id .. ":::", cache_key)
||||||| merged common ancestors
      cache_key = helpers.dao.plugins:cache_key(name, nil, service_id)
      assert.equal("plugins:" .. name .. "::" .. service_id .. "::", cache_key)
=======
      cache_key = helpers.db.plugins:cache_key({ name = name, service = service })
      assert.equal("plugins:" .. name .. "::" .. service.id .. "::", cache_key)
>>>>>>> 0.15.0

<<<<<<< HEAD
      cache_key = helpers.dao.plugins:cache_key(name, nil, nil, consumer_id)
      assert.equal("plugins:" .. name .. ":::" .. consumer_id .. "::", cache_key)
||||||| merged common ancestors
      cache_key = helpers.dao.plugins:cache_key(name, nil, nil, consumer_id)
      assert.equal("plugins:" .. name .. ":::" .. consumer_id .. ":", cache_key)
=======
      cache_key = helpers.db.plugins:cache_key({ name = name, consumer = consumer })
      assert.equal("plugins:" .. name .. ":::" .. consumer.id .. ":", cache_key)
>>>>>>> 0.15.0
    end)
  end)
end)
