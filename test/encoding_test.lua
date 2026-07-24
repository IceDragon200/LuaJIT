local test = require("test.ljtest")
local encoding = require("encoding")

test.describe("encoding module", function()
  test.it("round-trips strict hexadecimal and base64", function(t)
    local source = "\0LuaJIT\255"
    t.equal(encoding.hex_encode(source), "004c75614a4954ff")
    t.equal(encoding.hex_decode("004c75614a4954ff"), source)
    t.equal(encoding.base64_encode("LuaJIT"), "THVhSklU")
    t.equal(encoding.base64url_encode("a?"), "YT8")
    t.equal(encoding.base64url_decode("YT8"), "a?")
  end)

  test.it("returns a value and explanation for invalid input", function(t)
    t.results(t.pack(nil, "invalid hexadecimal encoding"), function()
      return encoding.hex_decode("xyz")
    end)
  end)
end)
