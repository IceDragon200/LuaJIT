-- Behavioral coverage adapted from Lua's upstream testes/events.lua.
local test = require("test.ljtest")

test.describe("baseline metamethods", function()
  test.it("dispatches arithmetic, concatenation, and calls", function(t)
    local operations = {}
    local object = setmetatable({ value = 4 }, {
      __add = function(left, right)
        operations[#operations + 1] = "add"
        return left.value + right.value
      end,
      __concat = function(left, right)
        operations[#operations + 1] = "concat"
        return left.value .. ":" .. right
      end,
      __call = function(self, amount)
        operations[#operations + 1] = "call"
        return self.value + amount
      end,
    })
    t.equal(object + object, 8)
    t.equal(object .. "ok", "4:ok")
    t.equal(object(3), 7)
    t.deep_equal(operations, { "add", "concat", "call" })
  end)

  test.it("uses comparison metamethods", function(t)
    local mt = {
      __lt = function(left, right) return left.rank < right.rank end,
      __le = function(left, right) return left.rank <= right.rank end,
    }
    local low = setmetatable({ rank = 1 }, mt)
    local high = setmetatable({ rank = 2 }, mt)
    t.assert(low < high)
    t.assert(low <= high)
    t.refute(high <= low)
  end)

  test.it("uses matching equality metamethods", function(t)
    local mt = { __eq = function(left, right) return left.id == right.id end }
    local left = setmetatable({ id = "same" }, mt)
    local right = setmetatable({ id = "same" }, mt)
    local other = setmetatable({ id = "other" }, mt)
    t.assert(left == right)
    t.refute(left == other)
    t.refute(rawequal(left, right))
  end)

  test.it("honors protected metatables", function(t)
    local value = setmetatable({}, { __metatable = "locked" })
    t.equal(getmetatable(value), "locked")
    t.raises(function() setmetatable(value, {}) end, "protected metatable")
  end)
end)
