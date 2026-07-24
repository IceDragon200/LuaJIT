local test = require("test.ljtest")

test.describe("try", function()
  test.it("bypasses catch after normal completion", function(t)
    local caught = false
    try do
      local value = 12
      t.equal(value, 12)
    catch err then
      caught = err
    end
    t.refute(caught)
  end)

  test.it("relays a multiple return with nil holes", function(t)
    local function values()
      return "ok", nil, 3
    end
    local function result()
      try do
        return values()
      catch err then
        return "caught", err
      end
    end
    t.results(t.pack("ok", nil, 3), result)
  end)

  test.it("matches literal, table, and binary error objects", function(t)
    local literal
    try do
      error("closed", 0)
    catch "closed" then
      literal = true
    end
    t.assert(literal)

    local table_result = {}
    try do
      error({ kind = "packet", code = 7 })
    catch {kind = "packet", code} then
      table_result.code = code
    end
    t.equal(table_result.code, 7)

    local sum
    try do
      error(@b{"\001\002"}, 0)
    catch @b{left <u8>, right <u8>} then
      sum = left + right
    end
    t.equal(sum, 3)
  end)

  test.it("rethrows an unmatched error unchanged", function(t)
    t.raises(function()
      try do
        error("other", 0)
      catch "expected" then
      end
    end, "other")
  end)

  test.it("keeps loop control local to a protected body", function(t)
    local count = 0
    try do
      for index = 1, 3 do
        if index < 3 then continue end
        count = count + 1
      end
    catch err then
      error(err)
    end
    t.equal(count, 1)

    local chunk, err = loadstring("for i = 1, 1 do try do break catch e then end end")
    t.equal(chunk, nil)
    t.assert(err:find("cannot break out of a try block", 1, true) ~= nil)
  end)
end)
