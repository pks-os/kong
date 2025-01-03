require("spec.helpers") -- for kong.log
local declarative = require "kong.db.declarative"
local conf_loader = require "kong.conf_loader"

local null = ngx.null


describe("declarative", function()
  describe("parse_string", function()
    it("converts lyaml.null to ngx.null", function()
      local dc = declarative.new_config(conf_loader())
      local entities, err = dc:parse_string [[
_format_version: "1.1"
routes:
  - name: null
    paths:
    - /
]]
      assert.equal(nil, err)
      local _, route = next(entities.routes)
      assert.equal(null,   route.name)
      assert.same({ "/" }, route.paths)
    end)
  end)

  it("ttl fields are accepted in DB-less schema validation", function()
    local dc = declarative.new_config(conf_loader())
    local entities, err = dc:parse_string([[
_format_version: '2.1'
consumers:
- custom_id: ~
  id: e150d090-4d53-4e55-bff8-efaaccd34ec4
  tags: ~
  username: bar@example.com
services:
keyauth_credentials:
- created_at: 1593624542
  id: 3f9066ef-b91b-4d1d-a05a-28619401c1ad
  tags: ~
  ttl: ~
  key: test
  consumer: e150d090-4d53-4e55-bff8-efaaccd34ec4
]])
    assert.equal(nil, err)

    assert.is_nil(entities.keyauth_credentials['3f9066ef-b91b-4d1d-a05a-28619401c1ad'].ttl)
  end)

  describe("unique_field_key()", function()
    local unique_field_key = declarative.unique_field_key
    local sha256_hex = require("kong.tools.sha256").sha256_hex

    it("utilizes the schema name, workspace id, field name, and checksum of the field value", function()
      local key = unique_field_key("services", "123", "fieldname", "test", false)
      assert.is_string(key)
      assert.equals("U|services|fieldname|123|" .. sha256_hex("test"), key)
    end)

    -- since rpc sync the param `unique_across_ws` is useless
    -- this test case is just for compatibility
    it("does not omits the workspace id when 'unique_across_ws' is 'true'", function()
      local key = unique_field_key("services", "123", "fieldname", "test", true)
      assert.equals("U|services|fieldname|123|" .. sha256_hex("test"), key)
    end)
  end)

  it("parse nested entity correctly", function ()
    local dc = declarative.new_config(conf_loader())
    local entities, err = dc:parse_string([[{"_format_version": "3.0","consumers": [{"username": "consumerA","basicauth_credentials": [{"username": "qwerty","password": "qwerty"}]}],"certificates": [{"id": "eab647a0-314a-4c26-94ec-3e9d78e4293f","cert": "-----BEGIN CERTIFICATE-----\nMIIBoTCCAQoCCQC/V5OfTXu7xDANBgkqhkiG9w0BAQsFADAVMRMwEQYDVQQDDApr\nb25naHEuY29tMB4XDTIzMDYwMTE3NTAwOFoXDTI0MDUzMTE3NTAwOFowFTETMBEG\nA1UEAwwKa29uZ2hxLmNvbTCBnzANBgkqhkiG9w0BAQEFAAOBjQAwgYkCgYEAuyL5\n0o4RyWoYLQTU5wKkYXcx9nDYTn+6O6WQPcDyOfPQmm92vauBK3zNJQxnhK3pdCJs\n/li+q2BqnBWYoFcp/DETIeOuyI43+BpARjAHntUM02sofcbTMRGA28/uCgq+46LS\nDqPGl6LeSA1pc7muc1mEmkvklYFzQ57Gee4i5SECAwEAATANBgkqhkiG9w0BAQsF\nAAOBgQBBvx0bdyFdWxa75R9brz8s1GYLrVmk7zCXspvy9sDy1RoaV7TnYdWxv/HU\n9fumw+0RoSsxysQRc1iWA8qJ6y2rq3G7A3GHtIPqsDHrjoS9s9YtJo4iT4INJ3Im\n0fB0QDr1F4F5P6TZyMu1Wjgt2CheqaZH6TLa8Em4Fz/Qrfc1Ag==\n-----END CERTIFICATE-----","key": "-----BEGIN PRIVATE KEY-----\nMIICdQIBADANBgkqhkiG9w0BAQEFAASCAl8wggJbAgEAAoGBALsi+dKOEclqGC0E\n1OcCpGF3MfZw2E5/ujulkD3A8jnz0Jpvdr2rgSt8zSUMZ4St6XQibP5YvqtgapwV\nmKBXKfwxEyHjrsiON/gaQEYwB57VDNNrKH3G0zERgNvP7goKvuOi0g6jxpei3kgN\naXO5rnNZhJpL5JWBc0OexnnuIuUhAgMBAAECgYARpvz11Zzr6Owa4wfKOr+SyhGW\nc5KT5QyGL9npWVgAC3Wz+6uxvInUtlMLmZ3yMA2DfPPXEjv6IoAr9QWOqmo1TDou\nvpi7n06GlT8qOMWOpbPoR7hCCa4nlsx48q8QQ+KnnChz0AgNYtlIu9H1l1a20Hut\n/qoEW7We/GPtbHbAAQJBAPc7wVUGtmHiFtXI2N/bdRkefk67TgytMQVU1eHIhnh8\nglAVpuGNYcyXYoDfod/yMpIJ4To2FNgRNVaHWgfOhQECQQDBxbIvw+PKrurNIbqr\nsu/fcDJXdKZ+wfuJJX2kRQeMga0nVcqLUZV1RAPmCg0Yv+QNhovq1ouwLNsZKpe5\nw8AhAkBDGaG4LPE1EcK21SMfZpWacq8/ORDO2faTBtphxCXS76ACkk3Pq6qed3vR\nlGB/wmE9R5csUF9J4SnDyUqDEecBAkAvVWSeiGJ3m1zd+RRJZu9zjEuv013sbuRL\n7y2O2BHs/6xVhH5yo943hALTybbDSfSiXTCGkBwVUA/BSQdBKJEhAkA/XSV2JTle\ng5RhxkuDZst3K8aupwWKC4E9zug+araQknzjMh6MSl6u2+RNifRrz2kThQ3HYj0g\n5GTyl7XJmyY/\n-----END PRIVATE KEY-----","snis": [{"name": "alpha.example","id": "c6ac927c-4f5a-4e88-8b5d-c7b01d0f43af"}]}]}]])

    assert.is_nil(err)
    assert.is_table(entities)
    assert.is_not_nil(entities.certificates)
    assert.is_not_nil(entities.snis)
    assert.same('alpha.example', entities.certificates['eab647a0-314a-4c26-94ec-3e9d78e4293f'].snis[1].name)
  end)

end)
