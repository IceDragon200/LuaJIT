-- Behavioral coverage adapted from Lua's upstream testes/calls.lua,
-- testes/closure.lua, and testes/gc.lua.
local test = require("test.ljtest")

test.describe("baseline runtime", function()
  test.it("dumps and reloads ordinary Lua functions", function(t)
    local function add(left, right)
      return left + right
    end
    local restored = assert(loadstring(string.dump(add)))
    t.equal(restored(20, 22), 42)
  end)

  test.it("gives functions a configurable environment", function(t)
    local function read_answer()
      return answer
    end
    setfenv(read_answer, { answer = 42 })
    t.equal(read_answer(), 42)
    t.equal(getfenv(read_answer).answer, 42)
  end)

  test.it("collects unreachable values without retaining weak keys", function(t)
    local weak = setmetatable({}, { __mode = "k" })
    do
      local key = {}
      weak[key] = true
    end
    collectgarbage()
    collectgarbage()
    t.equal(next(weak), nil)
  end)

  test.it("keeps normal and raw equality distinct", function(t)
    local mt = { __eq = function() return true end }
    local left, right = setmetatable({}, mt), setmetatable({}, mt)
    t.assert(left == right)
    t.refute(rawequal(left, right))
  end)
end)
