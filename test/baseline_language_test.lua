-- Behavioral coverage adapted from Lua's upstream testes/constructs.lua and
-- testes/literals.lua. This is intentionally LuaJIT-baseline coverage, not a
-- claim of Lua 5.5 syntax compatibility.
local test = require("test.ljtest")

test.describe("baseline language", function()
  test.it("uses Lua precedence and operand-preserving boolean operators", function(t)
    t.equal(2 + 3 * 4, 14)
    t.equal(2 ^ 3 ^ 2, 512)
    t.equal("left" and "right", "right")
    t.equal(false or "fallback", "fallback")
    t.equal(nil or 8, 8)
    t.equal(false and 8, false)
    t.equal("a" .. "b" .. 3, "ab3")
  end)

  test.it("keeps lexical scopes and shadowed locals separate", function(t)
    local value = "outer"
    do
      local value = "inner"
      t.equal(value, "inner")
    end
    t.equal(value, "outer")
  end)

  test.it("executes conditional and loop forms", function(t)
    local sum, repeated, branch = 0, 0, nil
    for index = 1, 10 do sum = sum + index end
    repeat
      repeated = repeated + 1
    until repeated == 3
    if sum == 55 then
      branch = "then"
    elseif false then
      branch = "elseif"
    else
      branch = "else"
    end
    t.equal(sum, 55)
    t.equal(repeated, 3)
    t.equal(branch, "then")
  end)

  test.it("supports generic for and break", function(t)
    local seen, total = {}, 0
    for key, value in pairs({ a = 1, b = 2, c = 3 }) do
      seen[key] = value
      total = total + value
    end
    t.deep_equal(seen, { a = 1, b = 2, c = 3 })
    t.equal(total, 6)

    local count = 0
    while true do
      count = count + 1
      if count == 4 then break end
    end
    t.equal(count, 4)
  end)

  test.it("loads valid chunks and rejects malformed source", function(t)
    local chunk = assert(loadstring("local x = 20; return x + 22"))
    t.equal(chunk(), 42)

    local invalid, err = loadstring("local =")
    t.equal(invalid, nil)
    t.assert(type(err) == "string" and #err > 0)
  end)

  test.it("keeps long strings and escaped literals intact", function(t)
    local long = [=[line one
line two]=]
    t.equal(long, "line one\nline two")
    t.equal("a\0b", string.char(97, 0, 98))
    t.equal("\065\066\067", "ABC")
  end)
end)
