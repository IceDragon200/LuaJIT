-- Regression coverage for the LuaJIT 3.0 syntax extensions backported by
-- this fork. Keep these source snippets dynamic so a syntax failure is
-- reported as a regular failing example rather than preventing registration.
local test = require("test.ljtest")

local function compile(source)
  return assert(loadstring(source, "=modern syntax"))
end

test.describe("modern syntax", function()
  test.it("updates locals with arithmetic and concatenation assignments", function(t)
    local update = compile([[
      local value = 1
      value += 2
      value *= 4
      value -= 3
      value /= 3
      value %= 3
      value ..= "x"
      return value
    ]])
    t.equal(update(), "0x")
  end)

  test.it("updates locals with bitwise compound assignments", function(t)
    local update = compile([[
      local value = 0xf0
      value &= 0x3c
      value |= 0x03
      value ~= 0xff
      value <<= 1
      value >>= 1
      value ~>>= 1
      return value
    ]])
    t.equal(update(), 102)
  end)

  test.it("evaluates indexed compound-assignment bases and keys once", function(t)
    local update = compile([[
      local calls = 0
      local target = { value = 1 }
      local function get_target()
        calls += 1
        return target
      end
      local function get_key()
        calls += 1
        return "value"
      end
      get_target()[get_key()] += 4
      return calls, target.value
    ]])
    t.results(t.pack(2, 5), update)
  end)

  test.it("uses regular arithmetic metamethods and rejects const updates", function(t)
    local update = compile([[
      local mt = {}
      mt.__add = function(left, right)
        return setmetatable({ value = left.value + right.value }, mt)
      end
      local value = setmetatable({ value = 1 }, mt)
      value += value
      return value.value
    ]])
    t.equal(update(), 2)

    local chunk, err = loadstring("const value = 1; value += 1", "=const update")
    t.equal(chunk, nil)
    t.assert(err:find("const variable", 1, true) ~= nil)
  end)

  test.it("supports customary operators, ternaries, navigation, and coalescing", function(t)
    local evaluate = compile([[
      local nested = { child = { value = 7 } }
      return !false && true && (1 != 2),
        true ? "yes" : "no",
        nested?.child?.value,
        nested?.missing?.value,
        nil ?? "fallback"
    ]])
    t.results(t.pack(true, "yes", 7, nil, "fallback"), evaluate)
  end)

  test.it("supports short functions, continue, and digit separators", function(t)
    local evaluate = compile([[
      local double = value -> value * 2
      local add = |left, right| -> left + right
      local total = 0
      for index = 1, 4 do
        if index < 4 then continue end
        total += index
      end
      return double(21), add(20, 22), total, 1_000_000
    ]])
    t.results(t.pack(42, 42, 4, 1000000), evaluate)
  end)

  test.it("keeps exponent assignment deliberately unavailable", function(t)
    local chunk, err = loadstring("local value = 2; value ^= 3", "=power assignment")
    t.equal(chunk, nil)
    t.assert(type(err) == "string" and #err > 0)
  end)
end)
