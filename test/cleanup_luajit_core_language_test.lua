-- Regression tests adapted from LuaJIT/LuaJIT-test-cleanup.
--
-- Source paths and provenance are recorded in test/THIRD_PARTY_NOTICES.md.
-- The imported source cases were present in Mike Pall's initial commit
-- a273241fe6386718cc741c852f783ad5a0138e2b, which the upstream README
-- places in the public domain for tests written by Mike Pall. They have been
-- reshaped into ljtest examples, with ordinary functional checks retained.

local test = require("test.ljtest")

test.describe("LuaJIT cleanup core-language regressions", function()
  test.it("evaluates nested and/or expressions without losing operands", function(t)
    local values = {
      { "nil", nil }, { "false", false }, { "true", true }, { "10", 10 },
    }
    local expressions = {}
    for _, left in ipairs(values) do
      for _, right in ipairs(values) do
        expressions[#expressions + 1] = {
          "(" .. left[1] .. " and " .. right[1] .. ")", left[2] and right[2],
        }
        expressions[#expressions + 1] = {
          "(" .. left[1] .. " or " .. right[1] .. ")", left[2] or right[2],
        }
      end
    end
    for _, expression in ipairs(expressions) do
      local actual = assert(loadstring("return " .. expression[1]))()
      t.equal(actual, expression[2])
    end
  end)

  test.it("assigns all right-hand values before changing indexed left-hand sides", function(t)
    local first, second, third = 0, 1
    t.equal(third, nil)
    first, second, third = first + 1, second + 1, first + second
    t.equal(first, 1)
    t.equal(second, 2)
    t.equal(third, 1)

    local values, index = {}, 3
    index, values[index] = index + 1, 20
    t.equal(index, 4)
    t.equal(values[3], 20)
    t.equal(values[4], nil)
  end)

  test.it("keeps ordered comparisons and NaN unordered", function(t)
    local less = function(left, right) return left < right end
    local greater = function(left, right) return left > right end
    t.assert(less(1, 2))
    t.refute(greater(1, 2))
    t.assert(2 >= 2)
    t.refute(2 ~= 2)

    local nan = 0 / 0
    for _, value in ipairs({ nan, 1 }) do
      t.refute(nan < value)
      t.refute(nan <= value)
      t.refute(nan > value)
      t.refute(nan >= value)
      t.refute(nan == value)
      t.assert(nan ~= value)
      t.refute(value < nan)
      t.refute(value <= nan)
      t.refute(value > nan)
      t.refute(value >= nan)
      t.refute(value == nan)
      t.assert(value ~= nan)
    end
  end)

  test.it("parses numeric constants and preserves table constructor fields", function(t)
    t.equal(1e5, 100000)
    t.equal(1e-5, 0.00001)
    t.equal(0xep9, 7168)
    t.equal(0xep-9, 0.02734375)
    local retained = {}
    local values = { [true] = nil, [false] = retained or 1 }
    t.equal(values[true], nil)
    t.raw_equal(values[false], retained)
  end)

  test.it("concatenates numeric values and grows long strings correctly", function(t)
    local value
    for index = 1, 100 do value = "a" .. index end
    t.equal(value, "a100")
    for index = 1.5, 100.5 do value = "a" .. index end
    t.equal(value, "a100.5")
    local text = "a"
    for _ = 1, 20 do text = text .. text end
    t.equal(#text, 2 ^ 20)
    t.equal(text:sub(1, 6), text:sub(-6, -1))
  end)

  test.it("keeps numeric for-loop direction and coercion at each invocation", function(t)
    local start, finish, step = 10, 1, -1
    for _ = 1, 20 do
      start, finish, step = finish, start, -step
      local count = 0
      for _ = start, finish, step do count = count + 1 end
      t.equal(count, 10)
    end
    local value, count = 1, 0
    for outer = 1, 20 do
      for _ = value, 100 do count = count + 1 end
      if outer == 13 then value = "2" end
    end
    t.equal(count, 1993)
    t.refute(pcall(function()
      local invalid = 1
      for outer = 1, 20 do
        for _ = invalid, 100 do end
        if outer == 10 then invalid = "not a number" end
      end
    end))
  end)

  test.it("uses Lua floor modulo semantics for integers, fractions, and zero", function(t)
    for numerator = -5, 5 do
      for denominator = -5, 5 do
        if denominator ~= 0 then
          t.equal(numerator % denominator,
            numerator - math.floor(numerator / denominator) * denominator)
        end
      end
    end
    for numerator = -5, 5, 0.25 do
      for denominator = -5, 5, 0.25 do
        if denominator ~= 0 then
          t.equal(numerator % denominator,
            numerator - math.floor(numerator / denominator) * denominator)
        end
      end
    end
    t.assert((1 % 0) ~= (1 % 0))
  end)

  test.it("closes loop variables independently and retains mutable upvalues", function(t)
    local first, last
    for index = 1, 10 do
      local function capture() return index end
      if first then last = capture else first = capture end
    end
    t.equal(first(), 1)
    t.equal(last(), 10)

    local factor = 1
    local function sum()
      local total = 0
      for _ = 1, 100 do total = total + factor end
      return total
    end
    t.equal(sum(), 100)
    factor = 2
    t.equal(sum(), 200)
  end)

  test.it("keeps table identity as a key and colon receivers as self", function(t)
    local forward, reverse = {}, {}
    for index = 1, 100 do
      local value = {}
      forward[index] = value
      reverse[value] = index
    end
    for index = 1, 100 do t.equal(reverse[forward[index]], index) end

    local object = {}
    function object:set(value) self.value = value end
    function object:get() return self.value end
    object:set(42)
    t.equal(object:get(), 42)
    t.equal(object.value, 42)
  end)

  test.it("maintains length and table data across allocation and collection", function(t)
    local values = {}
    for index = 1, 100 do values[#values + 1] = index end
    t.equal(#values, 100)
    for _ = 1, 100 do values[#values] = nil end
    t.equal(#values, 0)

    collectgarbage()
    local table_value = { ac = 1, nn = 1, mm = 1 }
    table_value.nn, table_value.mm = nil, nil
    local key = "a" .. "i"
    table_value[key] = 2
    table_value.ad = 3
    table_value[key], key = nil, nil
    collectgarbage()
    key = "a" .. "f"
    table_value[key] = 4
    table_value.ak = 5
    t.equal(table_value[key], 4)
  end)

  test.describe("numeric JIT representations", { requires = { jit = true } }, function()
    test.it("crosses signed integer boundaries without losing loop counts", function(t)
      local positive, negative = 0, 0
      for _ = 2147483446, 2147483647, 2 do positive = positive + 1 end
      for _ = -2147483447, -2147483648, -2 do negative = negative + 1 end
      t.equal(positive, 101)
      t.equal(negative, 101)

      local function minimum(left, right)
        for _ = 1, 100 do left = math.min(left, right) end
        return left
      end
      local function maximum(left, right)
        for _ = 1, 100 do left = math.max(left, right) end
        return left
      end
      t.equal(minimum(-1, -3), -3)
      t.equal(maximum(-1, -3), -1)
    end)

    test.it("retains converted integer values through loop phis and table lookups", function(t)
      local bit = require("bit")
      local random = {}
      for index = 0, 16 do random[index] = 0 end
      local seed = 1
      for index = 16, 0, -1 do
        seed = bit.band(seed * 9069, 0x7fffffff)
        random[index] = seed
      end
      t.equal(seed, 1952688301)

      local data, offset = {
        3, 1, 1, 1, 0, 3, 1, 0, 0, 2, 0, 2, 0, 0, 3, 1, 1, 1, 1,
      }, 0
      local codes = { [0] = true, [4] = true, [11] = true, [36] = true, [68] = true }
      local masks = { 0x0002, 0x0003, 0x0004, 0x0005 }
      local function bits() offset = offset + 1; return data[offset] end
      local function decode()
        local lookup, code = bits(), nil
        code = codes[lookup]
        if not code then
          for index = 1, 4 do
            lookup = bit.bor(lookup, bit.lshift(bits(), index + 1))
            code = codes[lookup + masks[index]]
            if code then break end
          end
        end
        return code
      end
      for _ = 1, 6 do t.assert(decode()) end
    end)
  end)
end)
