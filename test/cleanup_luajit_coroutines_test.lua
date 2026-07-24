-- Regression tests adapted from LuaJIT/LuaJIT-test-cleanup.
--
-- Source paths and provenance are recorded in test/THIRD_PARTY_NOTICES.md.
-- The imported source cases were present in Mike Pall's initial commit
-- a273241fe6386718cc741c852f783ad5a0138e2b, which the upstream README
-- places in the public domain for tests written by Mike Pall. They have been
-- reshaped into ljtest examples.

local test = require("test.ljtest")

local create = coroutine.create
local resume = coroutine.resume
local wrap = coroutine.wrap
local yield = coroutine.yield

test.describe("LuaJIT cleanup coroutine regressions", function()
  test.it("preserves a large result count through resume and wrap", function(t)
    local resume_count = wrap(function()
      local thread = create(function()
        yield(string.byte(string.rep(" ", 100), 1, 100))
      end)
      return select("#", resume(thread))
    end)()
    t.equal(resume_count, 101)

    local wrap_count = wrap(function()
      local next_value = wrap(function()
        yield(string.byte(string.rep(" ", 100), 1, 100))
      end)
      return select("#", next_value())
    end)()
    t.equal(wrap_count, 100)
  end)

  test.it("keeps nested wrapped generators resumable", function(t)
    local function generators(value)
      return wrap(function(next_value)
        repeat
          value = value + next_value
          next_value = yield(value)
        until false
      end), wrap(function(next_value)
        repeat
          value = value * next_value
          next_value = yield(value)
        until false
      end)
    end
    local add_one, multiply_one = generators(3)
    local add_two, multiply_two = generators(5)
    t.equal(multiply_two(multiply_one(add_two(add_one(multiply_two(multiply_one(add_two(add_one(1)))))))),
      168428160)
  end)

  test.it("resumes correctly after a yield inside pcall", function(t)
    local function worker(first, second)
      if first ~= 1 or second ~= "foo" then error("unexpected coroutine arguments") end
      local resumed = yield(2, "test")
      if resumed ~= "bar" then error("unexpected first resume") end
      local ok, value = pcall(yield, "from pcall")
      if not ok or value ~= "again" then error("unexpected protected yield result") end
      return "end"
    end
    local thread = create(worker)
    local ok, first, second = resume(thread, 1, "foo")
    t.assert(ok)
    t.equal(first, 2)
    t.equal(second, "test")
    ok, first = resume(thread, "bar")
    t.assert(ok)
    t.equal(first, "from pcall")
    ok, first = resume(thread, "again")
    t.assert(ok)
    t.equal(first, "end")
  end)

  test.it("yields through protected calls, iterators, and metamethods", function(t)
    local function collect_one(fn, ...)
      local thread = create(fn)
      local results = {}
      local first, second, third, fourth = resume(thread, ...)
      if not first then error(second) end
      results[#results + 1] = second
      while coroutine.status(thread) ~= "dead" do
        first, second, third, fourth = resume(thread)
        if not first then error(second) end
        results[#results + 1] = second
      end
      return results
    end

    local values = collect_one(function(value) pcall(yield, value); return 99 end, 42)
    t.deep_equal(values, { 42, 99 })
    values = collect_one(function(value)
      pcall(function(inner) yield(inner) end, value)
      return 99
    end, 42)
    t.deep_equal(values, { 42, 99 })
    values = collect_one(function(value) xpcall(yield, debug.traceback, value); return 99 end, 42)
    t.deep_equal(values, { 42, 99 })
    values = collect_one(function(value, count)
      for _ in function(object, key)
        yield(object + key)
        if key ~= 0 then return key - 1 end
      end, value, count do end
      return 99
    end, 42, 3)
    t.deep_equal(values, { 45, 44, 43, 42, 99 })
    values = collect_one(function(value)
      local object = setmetatable({ value }, {
        __add = function(left, right)
          yield(left[1] + right[1])
          return 99
        end,
      })
      return object + object
    end, 42)
    t.deep_equal(values, { 84, 99 })
  end)

  test.it("produces a traceback for a suspended error", function(t)
    local thread = create(function()
      local value
      return value.field
    end)
    t.refute(resume(thread))
    t.equal(type(debug.traceback(thread)), "string")
  end)
end)
