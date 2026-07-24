local test = require("test.ljtest")

test.describe("ljtest assertions", function()
  test.it("compares scalars and structures", function(t)
    t.equal(12, 12)
    t.not_equal("left", "right")
    t.raw_equal(false, false)
    t.deep_equal(
      { header = { kind = "send", flags = { 1, 2 } }, payload = "hi" },
      { payload = "hi", header = { flags = { 1, 2 }, kind = "send" } }
    )
  end)

  test.it("handles cyclic structures", function(t)
    local left, right = {}, {}
    left.self = left
    right.self = right
    t.deep_equal(left, right)
  end)

  test.it("partially matches tables", function(t)
    t.matches(
      { kind = "send", header = { version = 1, flags = 3 }, payload = "body" },
      { kind = "send", header = { flags = 3 } }
    )
  end)

  test.it("checks errors by message", function(t)
    t.raises(function() error("bad packet") end, "bad packet")
    t.raises(function() error({ reason = "bad packet" }) end, function(err)
      return type(err) == "table" and err.reason == "bad packet"
    end)
  end)

  test.it("keeps nil holes in multi-results", function(t)
    t.results(t.pack("ok", nil, 3), function()
      return "ok", nil, 3
    end)
  end)
end)

test.describe("ljtest hooks", function()
  local setup_count = 0
  local torn_down = false

  test.before_each(function()
    setup_count = setup_count + 1
    torn_down = false
  end)

  test.after_each(function()
    torn_down = true
  end)

  test.it("runs setup before the example", function(t)
    t.assert(setup_count >= 1)
    t.refute(torn_down)
  end)

  test.it("runs setup independently for each example", function(t)
    t.assert(setup_count >= 2)
    t.refute(torn_down)
  end)
end)

test.xtest("a visible intentionally skipped example", function()
  error("a skipped test must not run")
end)
