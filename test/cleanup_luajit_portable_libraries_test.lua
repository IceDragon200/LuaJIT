-- Regression tests adapted from LuaJIT/LuaJIT-test-cleanup.
--
-- Source paths and provenance are recorded in test/THIRD_PARTY_NOTICES.md.
-- The imported source cases were present in Mike Pall's initial commit
-- a273241fe6386718cc741c852f783ad5a0138e2b, which the upstream README
-- places in the public domain for tests written by Mike Pall. They have been
-- reshaped into ljtest examples and avoid platform, C API, and FFI coverage.

local test = require("test.ljtest")

test.describe("LuaJIT cleanup portable-library regressions", function()
  test.it("converts numbers and honors callable tostring metamethods", function(t)
    local sum = 0
    for index = 1, 100 do sum = sum + tonumber(tostring(index)) end
    t.equal(sum, 5050)
    t.equal(tonumber({}), nil)
    t.equal(tonumber(111, 2), 7)

    local callable = setmetatable({}, {
      __call = function(_, value) return tostring(value[1]) end,
    })
    local values = {}
    for index = 1, 100 do
      values[index] = setmetatable({ index }, { __tostring = callable })
    end
    local converted = 0
    for index = 1, 100 do converted = converted + tonumber(tostring(values[index])) end
    t.equal(converted, 5050)
    t.refute(pcall(function() return tostring(setmetatable({}, { __tostring = "x" })) end))
  end)

  test.it("preserves base assertion, error, metatable, and iterator contracts", function(t)
    local object = {}
    t.raw_equal(assert(object), object)
    local first, second = assert("first", "second")
    t.equal(first, "first")
    t.equal(second, "second")
    t.results(test.pack(false, "message"), function() return pcall(assert, false, "message") end)
    t.results(test.pack(false, "emsg"), function() return pcall(error, "emsg", 0) end)

    local protected = setmetatable({}, { __metatable = "protected" })
    t.equal(getmetatable(protected), "protected")
    t.refute(pcall(setmetatable, protected, {}))

    local values, count = { 4, 5, 6, 7 }, 0
    for index, value in ipairs(values) do
      t.equal(value, index + 3)
      count = count + 1
    end
    t.equal(count, 4)
    t.refute(pcall(next, values, "missing"))
  end)

  test.it("keeps coroutine-specific environments separate", function(t)
    local seen
    local function worker() seen = getfenv(0) end
    local coroutine_value = coroutine.create(worker)
    local environment = {}
    debug.setfenv(coroutine_value, environment)
    worker()
    t.raw_equal(seen, getfenv(0))
    t.assert(coroutine.resume(coroutine_value))
    t.raw_equal(seen, environment)
  end)

  test.it("sorts numbers, strings, and ordered objects", function(t)
    math.randomseed(42)
    local function sorted(values, key)
      table.sort(values)
      for index = 2, #values do t.assert(key(values[index - 1]) <= key(values[index])) end
    end
    local numbers, strings, objects = {}, {}, {}
    local ordered = { __lt = function(left, right) return left[1] < right[1] end }
    for index = 1, 300 do
      local value = math.random(300)
      numbers[index] = value
      strings[index] = tostring(value)
      objects[index] = setmetatable({ value }, ordered)
    end
    sorted(numbers, function(value) return value end)
    sorted(strings, function(value) return value end)
    sorted(objects, function(value) return value[1] end)
  end)

  test.it("keeps math constants, absolute values, and pseudo-random bounds valid", function(t)
    t.equal(math.pi, 3.141592653589793)
    t.assert(math.huge > 0)
    t.equal(1 / math.huge, 0)
    t.equal(math.abs(-3), 3)
    math.randomseed(4242)
    for _ = 1, 100 do
      local value = math.random(10, 20)
      t.in_range(value, 10, 20)
    end
  end)

  test.it("keeps format and string-metatable operations ordinary", function(t)
    t.equal(string.format("%04d:%0.2f:%s", 7, 1.5, "ok"), "0007:1.50:ok")
    t.equal(("abc"):reverse(), "cba")
    t.equal(("AbC"):lower(), "abc")
    t.equal(("abc"):sub(2), "bc")
    local mt = getmetatable("")
    t.equal(type(mt.__index), "table")
    t.equal(mt.__index.upper("abc"), "ABC")
  end)

  test.it("resumes large coroutine results and values yielded through pcall", function(t)
    local coroutine_value = coroutine.create(function()
      coroutine.yield(string.byte(string.rep(" ", 100), 1, 100))
    end)
    t.equal(select("#", coroutine.resume(coroutine_value)), 101)

    local function body(value)
      local ok, returned = pcall(coroutine.yield, value)
      return ok, returned
    end
    coroutine_value = coroutine.create(body)
    local ok, yielded = coroutine.resume(coroutine_value, "first")
    t.assert(ok)
    t.equal(yielded, "first")
    local complete, protected, returned = coroutine.resume(coroutine_value, "second")
    t.assert(complete)
    t.assert(protected)
    t.equal(returned, "second")
  end)
end)
