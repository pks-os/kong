-- this software is copyright kong inc. and its licensors.
-- use of the software is subject to the agreement between your organization
-- and kong inc. if there is no such agreement, use is governed by and
-- subject to the terms of the kong master software license agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ end of license 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers = require "spec.helpers"
local conf_loader = require "kong.conf_loader"
local insert = table.insert
local factories = require "spec-ee.fixtures.factories.plugins"

local PluginFactory = factories.PluginFactory
local EntitiesFactory = factories.EntitiesFactory

-- the `off` strategy only works when the `postgres` strategy was run before.
for _, strategy in helpers.all_strategies({"postgres", "off"}) do

    describe("Plugins Iterator - Single Scoping - #multiple #ConsumerGroup on #" .. strategy, function()
        local proxy_client, expected_header, must_not_have_headers, unexpected_header

        lazy_teardown(function()
            helpers.stop_kong()
            helpers.kill_all()
            assert(conf_loader(nil, {}))
        end)

        local declarative_config
        lazy_setup(function()
            proxy_client = helpers.proxy_client
            helpers.stop_kong()
            helpers.kill_all()
            assert(conf_loader(nil, {}))

            local ef = EntitiesFactory:setup(strategy)
            local pf = PluginFactory:setup(ef)

            -- adding header-names of plugins that should _not_ be executed
            -- this assists with tracking if a plugin was executed or not
            must_not_have_headers = {}


            expected_header, unexpected_header = pf:consumer_group_multiple_groups()

            insert(must_not_have_headers, unexpected_header)


            insert(must_not_have_headers, pf:route())

            insert(must_not_have_headers, pf:service())

            insert(must_not_have_headers, pf:consumer())

            insert(must_not_have_headers, pf:global())

            assert.is_equal(#must_not_have_headers, 5)

            declarative_config = strategy == "off" and helpers.make_yaml_file() or nil
            assert(helpers.start_kong({
                declarative_config = declarative_config,
                database = strategy ~= "off" and strategy or nil,
                nginx_conf = "spec/fixtures/custom_nginx.template",
            }))
        end)

        it("verify deterministic outcome when dealing with multiple consumergroup affiliation", function()
          for _ = 1, 100 do
            local r = proxy_client():get("/anything", {
                headers = {
                    host = "route.test",
                    -- authenticate as `eve`
                    apikey = "eve",
                },
            })
            assert.response(r).has.status(200)
            -- verify that the expected plugin was executed
            assert.request(r).has_header(expected_header)
            -- verify that no other plugin was executed that had lesser scopes configured
            for _, header in pairs(must_not_have_headers) do
                assert.request(r).has_no_header(header)
            end
          end
        end)
    end)
end