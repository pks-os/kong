local cjson   = require "cjson"
local helpers = require "spec.helpers"


for _, strategy in helpers.each_strategy() do
  describe("Plugin: acl (API) [#" .. strategy .. "]", function()
    local consumer
    local admin_client
    local bp
    local db

    lazy_setup(function()
      bp, db = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "plugins",
        "consumers",
        "acls",
      })

      assert(helpers.start_kong({
        database = strategy,
      }))

      admin_client = helpers.admin_client()
    end)

    lazy_teardown(function()
      if admin_client then
        admin_client:close()
      end

      helpers.stop_kong()
    end)

    describe("/consumers/:consumer/acls/", function()
<<<<<<< HEAD
      setup(function()
        dao:truncate_tables()
        helpers.register_consumer_relations(dao)
        consumer = assert(dao.consumers:insert {
||||||| merged common ancestors
      setup(function()
        dao:truncate_tables()
        consumer = assert(dao.consumers:insert {
=======
      lazy_setup(function()
        db:truncate()
        consumer = bp.consumers:insert {
>>>>>>> 0.15.0
          username = "bob"
        }
      end)
      before_each(function()
        db:truncate("acls")
      end)

      describe("POST", function()
        it("creates an ACL association", function()
          local res = assert(admin_client:send {
            method  = "POST",
            path    = "/consumers/bob/acls",
            body    = {
              group = "admin"
            },
            headers = {
              ["Content-Type"] = "application/json"
            }
          })
          local body = assert.res_status(201, res)
          local json = cjson.decode(body)
          assert.equal(consumer.id, json.consumer.id)
          assert.equal("admin", json.group)
        end)
        describe("errors", function()
          it("returns bad request", function()
            local res = assert(admin_client:send {
              method  = "POST",
              path    = "/consumers/bob/acls",
              body    = {},
              headers = {
                ["Content-Type"] = "application/json"
              }
            })
            local body = assert.res_status(400, res)
            local json = cjson.decode(body)
            assert.same({ group = "required field missing" }, json.fields)
          end)
        end)
      end)

      describe("GET", function()
        lazy_teardown(function()
          db:truncate("acls")
        end)
        it("retrieves the first page", function()
          bp.acls:insert_n(3, { consumer = { id = consumer.id } })

          local res = assert(admin_client:send {
            method  = "GET",
            path    = "/consumers/bob/acls"
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.is_table(json.data)
          assert.equal(3, #json.data)
        end)
      end)
    end)

    describe("/consumers/:consumer/acls/:id", function()
      local acl, acl2
      before_each(function()
        db:truncate("acls")
        acl = bp.acls:insert {
          group    = "hello",
          consumer = { id = consumer.id },
        }
        acl2 = bp.acls:insert {
          group    = "hello2",
          consumer = { id = consumer.id },
        }
      end)
      describe("GET", function()
        it("retrieves by id", function()
          local res = assert(admin_client:send {
            method  = "GET",
            path    = "/consumers/bob/acls/" .. acl.id
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.equal(acl.id, json.id)
        end)
        it("retrieves by group", function()
          local res = assert(admin_client:send {
            method  = "GET",
            path    = "/consumers/bob/acls/" .. acl.group
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.equal(acl.id, json.id)
        end)
        it("retrieves ACL by id only if the ACL belongs to the specified consumer", function()
          bp.consumers:insert {
            username = "alice"
          }

          local res = assert(admin_client:send {
            method  = "GET",
            path    = "/consumers/bob/acls/" .. acl.id
          })
          assert.res_status(200, res)

          res = assert(admin_client:send {
            method = "GET",
            path   = "/consumers/alice/acls/" .. acl.id
          })
          assert.res_status(404, res)
        end)
        it("retrieves ACL by group only if the ACL belongs to the specified consumer", function()
          local res = assert(admin_client:send {
            method  = "GET",
            path    = "/consumers/bob/acls/" .. acl.group
          })
          assert.res_status(200, res)

          res = assert(admin_client:send {
            method = "GET",
            path   = "/consumers/alice/acls/" .. acl.group
          })
          assert.res_status(404, res)
        end)
      end)

      describe("PUT", function()
        it("updates an ACL's groupname", function()
          local res = assert(admin_client:send {
            method = "PUT",
            path = "/consumers/bob/acls/pro",
            body = {},
            headers = {
              ["Content-Type"] = "application/json"
            }
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.equal(consumer.id, json.consumer.id)
          assert.equal("pro", json.group)
        end)
        describe("errors", function()
          it("returns bad request", function()
            local res = assert(admin_client:send {
              method  = "PUT",
              path    = "/consumers/bob/acls/f7852533-9160-4f5a-ae12-1ab99219ea95",
              body    = {
                group = 123,
              },
              headers = {
                ["Content-Type"] = "application/json"
              }
            })
            local body = assert.res_status(400, res)
            local json = cjson.decode(body)
            assert.same({ group = "expected a string" }, json.fields)
          end)
        end)
      end)

      describe("PATCH", function()
        it("updates an ACL group by id", function()
          local previous_group = acl.group

          local res = assert(admin_client:send {
            method  = "PATCH",
            path    = "/consumers/bob/acls/" .. acl.id,
            body    = {
              group            = "updatedGroup"
            },
            headers = {
              ["Content-Type"] = "application/json"
            }
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.not_equal(previous_group, json.group)
        end)
        it("updates an ACL group by group", function()
          local previous_group = acl.group

          local res = assert(admin_client:send {
            method  = "PATCH",
            path    = "/consumers/bob/acls/" .. acl.group,
            body    = {
              group            = "updatedGroup2"
            },
            headers = {
              ["Content-Type"] = "application/json"
            }
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.not_equal(previous_group, json.group)
        end)
        describe("errors", function()
          it("handles invalid input", function()
            local res = assert(admin_client:send {
              method  = "PATCH",
              path    = "/consumers/bob/acls/" .. acl.id,
              body    = {
                group            = 123,
              },
              headers = {
                ["Content-Type"] = "application/json"
              }
            })
            local body = assert.res_status(400, res)
            local json = cjson.decode(body)
            assert.same({ group = "expected a string" }, json.fields)
          end)
        end)
      end)

      describe("DELETE", function()
        it("deletes an ACL group by id", function()
          local res = assert(admin_client:send {
            method  = "DELETE",
            path    = "/consumers/bob/acls/" .. acl.id,
          })
          assert.res_status(204, res)
        end)
        it("deletes an ACL group by group", function()
          local res = assert(admin_client:send {
            method  = "DELETE",
            path    = "/consumers/bob/acls/" .. acl2.group,
          })
          assert.res_status(204, res)
        end)
        describe("errors", function()
          it("returns 404 on missing group", function()
            local res = assert(admin_client:send {
              method  = "DELETE",
              path    = "/consumers/bob/acls/blah"
            })
            assert.res_status(404, res)
          end)
          it("returns 404 if not found", function()
            local res = assert(admin_client:send {
              method  = "DELETE",
              path    = "/consumers/bob/acls/00000000-0000-0000-0000-000000000000"
            })
            assert.res_status(404, res)
          end)
        end)
      end)
    end)

    describe("/acls", function()
      local consumer2

      describe("GET", function()
        lazy_setup(function()
          db:truncate("acls")

          for i = 1, 3 do
            bp.acls:insert {
              group    = "group" .. i,
              consumer = { id = consumer.id },
            }
          end

          consumer2 = bp.consumers:insert {
            username = "bob-the-buidler"
          }

          for i = 1, 3 do
            bp.acls:insert {
              group = "group" .. i,
              consumer = { id = consumer2.id },
            }
          end
        end)

        it("retrieves all the acls with trailing slash", function()
          local res = assert(admin_client:send {
            method = "GET",
            path = "/acls/",
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.is_table(json.data)
          assert.equal(6, #json.data)
        end)
        it("retrieves all the acls without trailing slash", function()
          local res = assert(admin_client:send {
            method = "GET",
            path = "/acls",
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.is_table(json.data)
          assert.equal(6, #json.data)
        end)
        it("paginates through the acls", function()
          local res = assert(admin_client:send {
            method = "GET",
            path = "/acls?size=3",
          })
          local body = assert.res_status(200, res)
          local json_1 = cjson.decode(body)
          assert.is_table(json_1.data)
          assert.equal(3, #json_1.data)

          res = assert(admin_client:send {
            method = "GET",
            path = "/acls",
            query = {
              size = 3,
              offset = json_1.offset,
            }
          })
          body = assert.res_status(200, res)
          local json_2 = cjson.decode(body)
          assert.is_table(json_2.data)
          assert.equal(3, #json_2.data)

          assert.not_same(json_1.data, json_2.data)
          -- Disabled: on Cassandra, the last page still returns a
          -- next_page token, and thus, an offset proprty in the
          -- response of the Admin API.
          --assert.is_nil(json_2.offset) -- last page
        end)
      end)
    end)

    describe("/acls/:acl_id/consumer", function()
      describe("GET", function()
        local credential

        lazy_setup(function()
          db:truncate("acls")
          credential = db.acls:insert {
            group = "foo-group",
            consumer = { id = consumer.id },
          }
        end)
        it("retrieves a Consumer from an acl's id", function()
          local res = assert(admin_client:send {
            method = "GET",
            path = "/acls/" .. credential.id .. "/consumer",
          })
          local body = assert.res_status(200, res)
          local json = cjson.decode(body)
          assert.same(consumer, json)
        end)
      end)
    end)
  end)
end
