local test = require("test.ljtest")

test.describe("LuaJIT built-in modules", function()
  test.it("provides the BitOp-compatible bit module", function(t)
    local bit = require("bit")
    t.equal(bit.band(0xf0, 0x3c), 0x30)
    t.equal(bit.rol(0x80000000, 1), 1)
    t.equal(bit.tohex(-1), "ffffffff")
  end)

  test.it("provides JIT metadata and control", function(t)
    local jit = require("jit")
    local enabled = jit.status()
    t.assert(type(jit.version) == "string")
    t.assert(jit.version:find("LuaJIT", 1, true) == 1)
    t.assert(type(enabled) == "boolean")
  end)

  test.it("loads table allocation and clearing helpers", function(t)
    local new = require("table.new")
    local clear = require("table.clear")
    local value = new(2, 1)
    value[1], value.named = "first", "value"
    clear(value)
    t.equal(next(value), nil)
  end)

  test.it("provides the mutable string buffer library", function(t)
    local buffer = require("string.buffer")
    local value = buffer.new():put("Lua", "JIT")
    t.equal(value:tostring(), "LuaJIT")
    t.equal(value:skip(3):tostring(), "JIT")
  end)
end)

local has_ffi, ffi = pcall(require, "ffi")
if has_ffi then
  test.describe("LuaJIT FFI module", function()
    test.it("allocates and accesses C data", function(t)
      local values = ffi.new("uint8_t[3]", { 3, 5, 8 })
      t.equal(ffi.sizeof(values), 3)
      t.equal(values[1], 5)
    end)
  end)
else
  test.xtest("LuaJIT FFI module requires an FFI-enabled build", function() end)
end
