-- Behavioral coverage adapted from Lua's upstream testes/calls.lua,
-- testes/closure.lua, and testes/vararg.lua.
local test = require("test.ljtest")

test.describe("baseline functions", function()
  test.it("supports local recursive functions", function(t)
    local function factorial(value)
      if value == 0 then return 1 end
      return value * factorial(value - 1)
    end
    t.equal(factorial(8), 40320)
  end)

  test.it("retains independent closure state", function(t)
    local function counter(start)
      local value = start
      return function(step)
        value = value + (step or 1)
        return value
      end
    end
    local left, right = counter(0), counter(10)
    t.equal(left(), 1)
    t.equal(left(4), 5)
    t.equal(right(), 11)
    t.equal(left(), 6)
  end)

  test.it("captures numeric-for values for closures", function(t)
    local functions = {}
    for index = 1, 3 do
      functions[index] = function() return index end
    end
    t.equal(functions[1](), 1)
    t.equal(functions[2](), 2)
    t.equal(functions[3](), 3)
  end)

  test.it("preserves multiple results and nil holes", function(t)
    local function values()
      return "first", nil, "third"
    end
    t.results(t.pack("first", nil, "third"), values)
    t.equal(select("#", values()), 3)
  end)

  test.it("passes and selects ordinary varargs", function(t)
    local function inspect(...)
      return select("#", ...), select(2, ...)
    end
    t.results(t.pack(3, nil, "last"), function()
      return inspect("first", nil, "last")
    end)
  end)

  test.it("passes self through colon calls", function(t)
    local object = { value = 4 }
    function object:add(amount)
      self.value = self.value + amount
      return self.value
    end
    t.equal(object:add(3), 7)
    t.equal(object.value, 7)
  end)
end)
