-- LuaJIT bytecode round-trip and load-mode regression coverage.
local test = require("test.ljtest")

test.describe("bytecode", function()
  test.it("round-trips deterministic bytecode containing extension syntax", function(t)
    local source = [[
      local function decode(packet)
        local {kind, payload} = packet
        local count = packet.count
        count += 1
        return kind, payload, count
      end
      return decode
    ]]
    local factory = assert(loadstring(source, "=bytecode source", "t"))
    local first = string.dump(factory, "d")
    local second = string.dump(factory, "d")
    local restored_factory = assert(loadstring(first, "=bytecode dump", "b"))
    local decode = restored_factory()

    t.equal(first, second)
    t.results(t.pack("packet", "body", 3), function()
      return decode({ kind = "packet", payload = "body", count = 2 })
    end)
  end)

  test.it("round-trips stripped bytecode without changing behavior", function(t)
    local function calculate(left, right)
      return left * 2 + right
    end
    local restored = assert(loadstring(string.dump(calculate, "s"), "=stripped", "b"))
    t.equal(restored(20, 2), 42)
  end)

  test.it("enforces source and bytecode load modes", function(t)
    local source, source_err = loadstring("return 42", "=source only", "b")
    t.equal(source, nil)
    t.assert(source_err:find("attempt to load", 1, true) ~= nil)

    local dump = string.dump(function() return 42 end, "d")
    local bytecode, bytecode_err = loadstring(dump, "=bytecode only", "t")
    t.equal(bytecode, nil)
    t.assert(bytecode_err:find("attempt to load", 1, true) ~= nil)
  end)

  test.it("rejects malformed bytecode cleanly", function(t)
    local chunk, err = loadstring(string.char(27) .. "LJ\0\1", "=malformed", "b")
    t.equal(chunk, nil)
    t.assert(type(err) == "string" and err:find("bytecode", 1, true) ~= nil)
  end)
end)
