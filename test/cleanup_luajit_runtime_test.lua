-- Regression tests adapted from LuaJIT/LuaJIT-test-cleanup.
--
-- Source paths and provenance are recorded in test/THIRD_PARTY_NOTICES.md.
-- The imported source cases were present in Mike Pall's initial commit
-- a273241fe6386718cc741c852f783ad5a0138e2b, which the upstream README
-- places in the public domain for tests written by Mike Pall. They have been
-- reshaped into ljtest examples; JIT-specific cases are capability-gated.

local test = require("test.ljtest")

test.describe("LuaJIT cleanup runtime regressions", function()
  test.describe("parser boundaries", function()
    test.it("accepts numeric and hexadecimal escapes", function(t)
      t.equal("\79\126", "O~")
      t.equal("\x4f\x7e", "O~")
    end)

    test.it("rejects malformed hexadecimal escapes", function(t)
      t.equal(loadstring([[return "\xxx"]]), nil)
    end)

    test.it("removes whitespace following a z escape", function(t)
      local chunk = assert(loadstring([[return "abc   \z

   def"]]))
      t.equal(chunk(), "abc   def")
    end)

    test.it("rejects an ambiguous return and call boundary", function(t)
      local chunk = loadstring([[
local function f() return 99 end
return f
()
]])
      t.equal(chunk, nil)
    end)

    test.it("accepts UTF-8 identifiers", function(t)
      local chunk = assert(loadstring([[
local ä = 1
local aäa = 2
local äöü·€晶 = 3
return ä, aäa, äöü·€晶, #"ä", #"aäa", #"äöü·€晶"
]]))
      local first, second, third, first_bytes, second_bytes, third_bytes = chunk()
      t.equal(first, 1)
      t.equal(second, 2)
      t.equal(third, 3)
      t.equal(first_bytes, 2)
      t.equal(second_bytes, 4)
      t.equal(third_bytes, 14)
    end)

    test.it("parses comparisons through indexed field access", function(t)
      local values = { { n = 5 } }
      local value = values[1].n
      t.assert(1 < value)
      t.assert(1 < (values[1].n))
      t.assert(1 < values[1].n)

      local fields = { a = 1 }
      t.refute(0 >= fields.a)
    end)
  end)

  test.describe("numeric for coercion", function()
    test.it("coerces a numeric string set between loop invocations", function(t)
      local start = 1
      local count = 0
      for outer = 1, 20 do
        for _ = start, 100 do count = count + 1 end
        if outer == 13 then start = "2" end
      end
      t.equal(count, 1993)
    end)

    test.it("coerces at the next loop invocation", function(t)
      local start = 1
      local count = 0
      for outer = 1, 20 do
        for _ = start, 100 do count = count + 1 end
        if outer == 10 then start = "2" end
      end
      t.equal(count, 1990)
    end)

    test.it("rejects a non-numeric string at the next loop invocation", function(t)
      local function loop()
        local start = 1
        for outer = 1, 20 do
          for _ = start, 100 do end
          if outer == 10 then start = "x" end
        end
      end
      t.refute(pcall(loop))
    end)
  end)

  test.describe("vararg JIT paths", { requires = { jit = true } }, function()
    test.it("keeps fixed parameters and an empty vararg distinct", function(t)
      local assert = assert
      local function f(a, b, c, ...)
        return c, 100 - a, 100 - b
      end
      local first_total, second_total = 0, 0
      for i = 1, 100 do
        local empty, first, second = f(i, 100 - i)
        assert(empty == nil)
        first_total = first_total + first
        second_total = second_total + second
      end
      t.equal(first_total, 4950)
      t.equal(second_total, 5050)
    end)

    test.it("preserves varargs through local assignment and return", function(t)
      local function minimum(a, b, ...)
        if a > b then return b end
        return a
      end
      local function local_minimum(a, b, ...)
        local c, d = ...
        if c > d then return d end
        return c
      end
      local function pass_through(a, b, ...)
        if a > b then end
        return ...
      end

      local direct_total, local_total, returned_total = 0, 0, 0
      for i = 1, 200 do
        direct_total = direct_total + minimum(i, 100, 99, 88, 77)
        local_total = local_total + local_minimum(77, 88, i, 100)
        returned_total = returned_total + pass_through(i, 100, i, 100)
      end
      t.equal(direct_total, 15050)
      t.equal(local_total, 15050)
      t.equal(returned_total, 20100)
      t.equal(pass_through(1, 100), nil)
      t.equal(pass_through(1, 100, 2), 2)
    end)

    test.it("retains varargs across repeated assignments and table writes", function(t)
      local function repeat_values(a, ...)
        local left, right = 0, 0
        for _ = 1, 100 do
          local b, c = ...
          left = left + b
          right = right + c
        end
        return left, right
      end
      local function table_values(a, ...)
        local values = { [0] = 9, 9 }
        local first, second, third, fourth = 0, 0, 0, 0
        for _ = 1, 100 do
          first, second = ...
          values[0], values[1] = 9, 9
          third, fourth = ...
        end
        return first, second, third, fourth
      end
      local function same_values(a, b, ...)
        local valid = true
        for _ = 1, 100 do
          local c, d = ...
          valid = valid and a == c and b == d
        end
        return valid
      end

      local left, right = repeat_values(1, 2, 3)
      t.equal(left, 200)
      t.equal(right, 300)
      local first, second, third, fourth = table_values(1, 2, 3)
      t.equal(first, 2)
      t.equal(second, 3)
      t.equal(third, 2)
      t.equal(fourth, 3)
      t.assert(same_values(2, 3, 2, 3))
      t.assert(same_values(2, nil, 2))
      t.assert(same_values(nil, nil))
      t.assert(same_values(nil))
      t.assert(same_values())
    end)
  end)

  test.describe("tail calls and recursion", { requires = { jit = true } }, function()
    test.it("links a tail call to a previously compiled loop", function(t)
      local count = 0
      local function leaf()
        count = count + 1
        for _ = 1, 100 do end
      end
      local function call_leaf()
        for index = 1, 20 do
          if index > 19 then return leaf() end
        end
      end

      leaf()
      for _ = 1, 50 do call_leaf() end
      t.equal(count, 51)
    end)

    test.it("keeps a deeply tail-recursive loop bounded", function(t)
      local function recurse(remaining)
        if remaining > 0 then return recurse(remaining - 1) end
        return 1
      end
      local total = 0
      for _ = 1, 100 do total = total + recurse(1000) end
      t.equal(total, 100)
    end)

    test.it("preserves results through deep and mutual recursion", function(t)
      local function sum(number)
        if number == 1 then return 1 end
        return number + sum(number - 1)
      end
      local calls = 0
      local protected
      protected = function(remaining)
        if remaining <= 0 then return end
        calls = calls + 1
        return pcall(protected, remaining - 1)
      end
      local function fibonacci(number)
        if number < 2 then return 1 end
        return fibonacci(number - 2) + fibonacci(number - 1)
      end
      local first, second
      first = function(remaining)
        if remaining <= 0 then return 0 end
        return second(remaining - 1)
      end
      second = function(remaining)
        return first(remaining)
      end

      t.equal(sum(200), 20100)
      t.assert(protected(200))
      t.equal(calls, 200)
      t.equal(fibonacci(15), 987)
      t.equal(second(200), 0)
    end)
  end)

  test.describe("stack and garbage collection", function()
    test.it("marks stack slots through recursive table indexing", function(t)
      local values = setmetatable({}, {
        __index = function(self, key)
          key = key - 1
          if key == 0 then
            collectgarbage()
            return 0
          end
          return self[key]
        end,
      })
      t.equal(values[50], 0)
    end)

    test.it("rechains string keys after a collection", function(t)
      local key
      collectgarbage()
      local values = { ac = 1, nn = 1, mm = 1 }
      values.nn, values.mm = nil, nil
      key = "a" .. "i"
      values[key] = 2
      values.ad = 3
      values[key] = nil
      key = nil
      collectgarbage()
      key = "a" .. "f"
      values[key] = 4
      values.ak = 5
      t.equal(values[key], 4)
    end)

    test.it("takes incremental GC steps for common allocations", function(t)
      local function check(what, allocate)
        collectgarbage()
        local before = gcinfo()
        allocate()
        local after = gcinfo()
        t.assert(after < before * 4, "GC step missing for " .. what)
      end

      check("TNEW", function() for _ = 1, 10000 do local value = {} end end)
      check("TDUP", function() for _ = 1, 10000 do local value = { 1 } end end)
      check("FNEW", function() for _ = 1, 10000 do local function value() end end end)
      check("CAT", function() for index = 1, 10000 do local value = "x" .. index end end)
    end)

    test.it("maintains table write barriers", function(t)
      local assert = assert
      local values = {}
      for index = 1, 20000 do values[index] = tostring(index) end
      for index = 1, #values do assert(values[index] == tostring(index)) end
      t.assert(true)
    end)
  end)

  test.describe("JIT write barriers", { requires = { jit = true } }, function()
    test.it("keeps a chain of newly allocated tables reachable", function(t)
      local assert = assert
      local values = { [0] = {} }
      for index = 1, 100000 do values[index] = { values[index - 1] } end
      for index = 1, 100000 do assert(values[index][1] == values[index - 1]) end
      t.assert(true)
    end)

    test.it("tracks writes to a captured upvalue", function(t)
      local allocate
      do
        local value = 0
        allocate = function()
          for index = 1, 100000 do value = { index } end
          return value
        end
      end
      local final = allocate()
      t.equal(final[1], 100000)
    end)
  end)
end)
