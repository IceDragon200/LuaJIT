-- Behavioral coverage adapted from Lua's upstream testes/nextvar.lua and
-- testes/sort.lua.
local test = require("test.ljtest")

test.describe("baseline tables", function()
  test.it("constructs mixed array and record fields", function(t)
    local value = { "first", [3] = "third", kind = "packet", count = 2 }
    t.equal(value[1], "first")
    t.equal(value[2], nil)
    t.equal(value[3], "third")
    t.equal(value.kind, "packet")
    t.equal(value.count, 2)
  end)

  test.it("iterates each present key with next and pairs", function(t)
    local value = { [1] = "one", [3] = "three", kind = "packet" }
    local next_seen, pair_seen = {}, {}
    local key = nil
    repeat
      key = next(value, key)
      if key ~= nil then next_seen[key] = value[key] end
    until key == nil
    for name, item in pairs(value) do pair_seen[name] = item end
    t.deep_equal(next_seen, value)
    t.deep_equal(pair_seen, value)
  end)

  test.it("keeps ipairs contiguous at the first nil", function(t)
    local values, seen = { "a", "b", nil, "d" }, {}
    for index, value in ipairs(values) do seen[index] = value end
    t.deep_equal(seen, { "a", "b" })
  end)

  test.it("uses index and newindex metamethods", function(t)
    local writes = {}
    local value = setmetatable({}, {
      __index = function(_, key) return "missing:" .. key end,
      __newindex = function(_, key, item) writes[key] = item end,
    })
    t.equal(value.unknown, "missing:unknown")
    value.answer = 42
    t.equal(rawget(value, "answer"), nil)
    t.equal(writes.answer, 42)
  end)

  test.it("uses length metamethods and raw access separately", function(t)
    local value = setmetatable({ 10, 20 }, { __len = function() return 9 end })
    t.equal(#value, 9)
    rawset(value, "kind", "packet")
    t.equal(rawget(value, "kind"), "packet")
  end)

  test.it("supports the core table library operations", function(t)
    local values = { "b", "d" }
    table.insert(values, 1, "a")
    table.insert(values, 3, "c")
    t.equal(table.concat(values), "abcd")
    t.equal(table.remove(values, 2), "b")
    table.sort(values, function(left, right) return left > right end)
    t.deep_equal(values, { "d", "c", "a" })
  end)
end)
