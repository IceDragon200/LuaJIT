-- Behavioral coverage adapted from Lua's upstream testes/errors.lua.
local test = require("test.ljtest")

test.describe("baseline errors", function()
  test.it("keeps arbitrary error objects through pcall", function(t)
    local object = { kind = "bad_packet" }
    local ok, err = pcall(function() error(object, 0) end)
    t.refute(ok)
    t.raw_equal(err, object)
  end)

  test.it("invokes xpcall handlers with the original error", function(t)
    local object = { kind = "bad_packet" }
    local ok, result = xpcall(function()
      error(object, 0)
    end, function(err)
      return { handled = err }
    end)
    t.refute(ok)
    t.raw_equal(result.handled, object)
  end)

  test.it("reports assertion and explicit errors", function(t)
    t.raises(function() assert(false, "expected failure") end, "expected failure")
    t.raises(function() error("plain failure", 0) end, "plain failure")
  end)

  test.it("returns syntax failures from loadstring", function(t)
    local chunk, err = loadstring("function (")
    t.equal(chunk, nil)
    t.assert(type(err) == "string" and err:find("expected", 1, true) ~= nil)
  end)
end)
