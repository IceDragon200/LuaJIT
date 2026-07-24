-- Behavioral coverage adapted from Lua's upstream testes/coroutine.lua.
local test = require("test.ljtest")

test.describe("baseline coroutines", function()
  test.it("resumes, yields, and passes values in both directions", function(t)
    local thread = coroutine.create(function(initial)
      local next_value = coroutine.yield("ready", initial)
      return "done", next_value
    end)
    t.results(t.pack(true, "ready", 7), function() return coroutine.resume(thread, 7) end)
    t.equal(coroutine.status(thread), "suspended")
    t.results(t.pack(true, "done", 9), function() return coroutine.resume(thread, 9) end)
    t.equal(coroutine.status(thread), "dead")
  end)

  test.it("wrap returns yielded values and raises resumed errors", function(t)
    local worker = coroutine.wrap(function()
      coroutine.yield("first")
      return "last"
    end)
    t.equal(worker(), "first")
    t.equal(worker(), "last")

    local broken = coroutine.wrap(function() error("broken worker", 0) end)
    t.raises(broken, "broken worker")
  end)

  test.it("returns an error from resume without killing the caller", function(t)
    local thread = coroutine.create(function() error({ kind = "bad" }) end)
    local ok, err = coroutine.resume(thread)
    t.refute(ok)
    t.matches(err, { kind = "bad" })
    t.equal(coroutine.status(thread), "dead")
  end)
end)
