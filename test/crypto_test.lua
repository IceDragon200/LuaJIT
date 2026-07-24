local test = require("test.ljtest")
local has_crypto, crypto = pcall(require, "crypto")

if not has_crypto then
  test.xtest("crypto module requires an OpenSSL build", function() end)
  return
end

local encoding = require("encoding")

test.describe("crypto module", function()
  test.it("hashes and obtains secure random bytes", function(t)
    t.equal(encoding.hex_encode(crypto.hash("sha256", "abc")),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    t.equal(#crypto.random_bytes(32), 32)
    t.assert(crypto.constant_time_equal("same", "same"))
    t.refute(crypto.constant_time_equal("left", "right"))
  end)

  test.it("calculates an HMAC without changing its binary result", function(t)
    t.equal(encoding.hex_encode(crypto.hmac("sha256", "key", "data")),
      "5031fe3d989c6d1537a013fa6e739da23463fd6e6cc8da4f1d9e65f2c1d74e31")
  end)
end)
