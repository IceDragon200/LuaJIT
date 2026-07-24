-- Regression tests adapted from LuaJIT/LuaJIT-test-cleanup.
--
-- Source paths and provenance are recorded in test/THIRD_PARTY_NOTICES.md.
-- The imported source cases were present in Mike Pall's initial commit
-- a273241fe6386718cc741c852f783ad5a0138e2b, which the upstream README
-- places in the public domain for tests written by Mike Pall. They have been
-- reshaped into ljtest examples; JIT-specific cases are capability-gated.

local test = require("test.ljtest")

test.describe("LuaJIT cleanup metamethod regressions", function()
  test.describe("call and concatenation metamethods", function()
    test.it("passes a callable table or userdata as its first argument", function(t)
      local function callmeta(object, first, second)
        return object, first, second
      end
      local callable = setmetatable({}, { __call = callmeta })
      local object, first, second = callable("foo", "bar")
      t.raw_equal(object, callable)
      t.equal(first, "foo")
      t.equal(second, "bar")

      local userdata = newproxy(true)
      getmetatable(userdata).__call = callmeta
      object, first, second = userdata("foo", "bar")
      t.raw_equal(object, userdata)
      t.equal(first, "foo")
      t.equal(second, "bar")
    end)

    test.it("continues calling an object returned by another metamethod", function(t)
      local callable = setmetatable({}, {
        __call = function(object, first) return first end,
      })
      local operand = setmetatable({}, { __add = callable })
      t.raw_equal(operand + operand, operand)

      getmetatable(callable).__call = function(object, first) return object end
      t.raw_equal(operand + operand, callable)
    end)

    test.it("keeps callable and newindex table operations distinct on a hot path", function(t)
      local callable = setmetatable({}, { __call = function(_, index) return 100 - index end })
      for index = 1, 100 do t.equal(callable(index), 100 - index) end

      local values = setmetatable({}, { __newindex = pcall, __call = rawset })
      for index = 1, 100 do values(index, 100 - index) end
      for index = 1, 100 do t.equal(values[index], 100 - index) end
    end)

    test.it("evaluates long concatenation chains in the correct order", function(t)
      local function create(concatenate, first, second)
        local meta = { __concat = concatenate }
        return setmetatable({ first }, meta), setmetatable({ second }, meta)
      end

      local first, second = create(function(left) return left end)
      t.raw_equal(first .. second .. second, first)
      t.raw_equal(first .. first .. second, first)

      first, second = create(function(_, right) return right end)
      t.raw_equal(first .. second .. first, first)
      t.raw_equal(first .. first .. second, second)

      first, second = create(function(left, right)
        return (type(left) == "string" and left or left[1]) ..
          (type(right) == "string" and right or right[1])
      end, "a", "b")
      t.equal(first .. second .. second, "abb")
      t.equal("x" .. first .. first .. second, "xaab")
      t.equal(first .. first .. first .. "x" .. "x" .. first .. first .. second,
        "aaaxxaab")
    end)
  end)

  test.describe("comparison metamethods", function()
    test.it("uses the ordered-comparison metamethod and its fallback", function(t)
      local operation
      local function create(compare)
        local meta = {
          __lt = function(left, right) return compare("lt", left, right) end,
          __le = function(left, right) return compare("le", left, right) end,
        }
        return setmetatable({}, meta), setmetatable({}, meta)
      end
      local first, second = create(function(kind)
        operation = kind
        return "truthy"
      end)

      t.assert(first < second)
      t.equal(operation, "lt")
      t.assert(first <= second)
      t.equal(operation, "le")
      t.assert(first > second)
      t.equal(operation, "lt")
      t.assert(first >= second)
      t.equal(operation, "le")

      getmetatable(first).__le = nil
      t.refute(first <= second)
      t.equal(operation, "lt")
      t.refute(first >= second)
      t.equal(operation, "lt")
    end)

    test.it("compares values returned by ordered metamethods", function(t)
      local function create(first_value, second_value)
        local meta = {
          __lt = function(left, right) return left[1] < right[1] end,
          __le = function(left, right) return left[1] <= right[1] end,
        }
        return setmetatable({ first_value }, meta), setmetatable({ second_value }, meta)
      end
      local first, second = create(1, 2)
      t.assert(first < second)
      t.refute(first > second)
      t.assert(first <= second)
      t.refute(first >= second)

      second[1] = 1
      t.refute(first < second)
      t.assert(first <= second)
      t.assert(first >= second)

      first[1] = 2
      t.assert(first > second)
      t.refute(first <= second)
      t.assert(first >= second)
    end)

    test.it("uses the equality metamethod for matching metatables", function(t)
      local called = false
      local meta = {
        __eq = function(left, right)
          called = true
          return left[1] == right[1]
        end,
      }
      local first = setmetatable({ 1 }, meta)
      local second = setmetatable({ 2 }, meta)
      t.refute(first == second)
      t.assert(called)

      called = false
      second[1] = 1
      t.assert(first == second)
      t.assert(called)
      t.refute(first ~= second)
    end)
  end)

  test.describe("table access metamethods", function()
    test.it("switches an index metamethod only when its named lookup is reached", function(t)
      local keys = {}
      for index = 1, 100 do keys[index] = "foo" end
      keys[95] = "__index"
      local function index_value() return 12345 end
      local meta = { foo = 1, __index = "" }
      local values = setmetatable({ 1 }, meta)
      values[1] = nil
      meta.__index = nil

      local first_hit
      for index = 1, 100 do
        meta[keys[index]] = index_value
        if values[1] then
          first_hit = first_hit or index
          t.equal(values[1], 12345)
        end
      end
      t.equal(first_hit, 95)
    end)

    test.it("reapplies index lookup after table entries are removed", function(t)
      local values = setmetatable({}, {
        __index = function(_, key) return 100 - key end,
      })
      for index = 1, 100 do t.equal(values[index], 100 - index) end
      for index = 1, 100 do values[index] = index end
      for index = 1, 100 do t.equal(values[index], index) end
      for index = 1, 100 do values[index] = nil end
      for index = 1, 100 do t.equal(values[index], 100 - index) end
    end)

    test.it("receives absent numeric and string keys in index lookup", function(t)
      local received
      local values = setmetatable({}, {
        __index = function(_, key)
          received = key
        end,
      })
      t.equal(values[1], nil)
      t.equal(received, 1)
      t.equal(values.foo, nil)
      t.equal(received, "foo")
    end)

    test.it("uses newindex only for absent entries", function(t)
      local count = 0
      local values = setmetatable({ foo = nil }, {
        __newindex = function() count = count + 1 end,
      })
      for _ = 1, 2 do
        for _ = 1, 100 do values.foo = 1 end
        rawset(values, "foo", 1)
      end
      t.equal(count, 100)
    end)

    test.it("keeps a string value written by newindex", function(t)
      local values = setmetatable({}, {
        __newindex = function(object, key, value)
          t.equal(value, "foo" .. key)
          rawset(object, key, "bar" .. key)
        end,
      })
      for index = 1, 100 do values[index] = "foo" .. index end
      for index = 1, 100 do t.equal(values[index], "bar" .. index) end
      for index = 1, 100 do values[index] = "baz" .. index end
      for index = 1, 100 do t.equal(values[index], "baz" .. index) end
    end)
  end)

  test.describe("metatable access", function()
    test.it("returns a protected metatable marker", function(t)
      local values = setmetatable({}, { __metatable = "foo" })
      for _ = 1, 100 do t.equal(getmetatable(values), "foo") end
    end)

    test.it("does not overwrite protected metatables", function(t)
      local marker = {}
      local values = {}
      for index = 1, 200 do values[index] = setmetatable({}, marker) end
      values[150] = setmetatable({}, { __metatable = "protected" })

      for index = 1, 200 do
        local ok = pcall(setmetatable, values[index], marker)
        t.equal(ok, index ~= 150)
      end
      for index = 1, 200 do
        if index == 150 then
          t.equal(getmetatable(values[index]), "protected")
        else
          t.raw_equal(getmetatable(values[index]), marker)
        end
      end
    end)
  end)

  test.describe("JIT metamethod paths", { requires = { jit = true } }, function()
    test.it("retains a comparison result and operands through a compiled loop", function(t)
      local equal = false
      local first, second = {}, {}
      local result, left, right
      local meta = {
        __eq = function(a, b)
          left, right = a, b
          return equal
        end,
      }
      first, second = setmetatable(first, meta), setmetatable(second, meta)

      for _ = 1, 100 do result = first == second and 2 or 1 end
      t.equal(result, 1)
      t.raw_equal(left, first)
      t.raw_equal(right, second)

      equal = true
      for _ = 1, 100 do result = first ~= second and 2 or 1 end
      t.equal(result, 1)
      t.raw_equal(left, first)
      t.raw_equal(right, second)
    end)

    test.it("keeps a large frame intact across an arithmetic metamethod", function(t)
      local values = setmetatable({}, {
        __add = function(_, right)
          if right > 200 then
            for _ = 1, 10 do end
            return right + 3
          elseif right > 100 then
            return right + 2
          end
          return right + 1
        end,
      })
      local function add(object, index)
        do return object + index end
        do local a, b, c, d, e, f, g, h, i, j, k end
      end
      local result = 0
      for index = 1, 300 do result = add(values, index) end
      t.equal(result, 303)
    end)
  end)
end)
