-- Regression tests adapted from LuaJIT/LuaJIT-test-cleanup.
--
-- Source paths and provenance are recorded in test/THIRD_PARTY_NOTICES.md.
-- The imported source cases were present in Mike Pall's initial commit
-- a273241fe6386718cc741c852f783ad5a0138e2b, which the upstream README
-- places in the public domain for tests written by Mike Pall. They have been
-- reshaped into ljtest examples; LuaJIT-specific cases are capability-gated.

local test = require("test.ljtest")

test.describe("LuaJIT cleanup regression corpus", function()
  test.describe("length metamethod", function()
    test.it("honors a table __len metamethod", function(t)
      local received_first, received_second
      local value = setmetatable({ 1, 2, 3 }, {
        __len = function(first, second)
          received_first, received_second = first, second
          return 42
        end,
      })

      t.equal(#value, 42)
      t.raw_equal(received_first, value)
      t.raw_equal(received_second, value)
      t.equal(#"abcdef", 6)
    end)

    test.it("keeps __len on userdata", function(t)
      local value = newproxy(true)
      getmetatable(value).__len = function() return 42 end
      local total = 0

      for _ = 1, 100 do total = total + #value end
      t.equal(total, 4200)
    end)
  end)

  test.describe("bytecode constant limits", { requires = { luajit = 2 } }, function()
    test.it("rejects float constants beyond the bytecode pool limit", function(t)
      local source = { "local x\n" }
      for i = 2, 65537 do source[i] = "x=" .. i .. ".5\n" end

      t.assert(loadstring(table.concat(source)) ~= nil)
      source[65538] = "x=65538.5"
      t.equal(loadstring(table.concat(source)), nil)
    end)

    test.it("rejects string constants beyond the bytecode pool limit", function(t)
      local source = { "local x\n" }
      for i = 2, 65537 do source[i] = "x='" .. i .. "'\n" end

      t.assert(loadstring(table.concat(source)) ~= nil)
      source[65538] = "x='65538'"
      t.equal(loadstring(table.concat(source)), nil)
    end)
  end)

  test.describe("JIT trace exits", { requires = { jit = true } }, function()
    test.it("grows a shrunken stack before filling exit slots", function(t)
      local function f(index)
        local a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a
        local b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b
        local c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c
        if index == 90 then return end
      end

      for _ = 1, 5 do
        collectgarbage()
        for index = 1, 100 do f(index) end
      end
      t.assert(true)
    end)

    test.it("grows a shrunken stack after filling exit slots", function(t)
      local function g(index)
        if index == 90 then return end
        do return end
        do
          local a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a
          local b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b,b
          local c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c,c
        end
      end

      for _ = 1, 5 do
        collectgarbage()
        for index = 1, 100 do g(index) end
      end
      t.assert(true)
    end)

    test.it("preserves the result count at a JIT function-frame exit", function(t)
      local assert = assert
      local function recursive(a, remaining, c, d, e, f)
        assert(f == a + 1)
        if remaining == 0 then return 7 end
        do
          local x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14
          local x15, x16, x17, x18, x19, x20, x21, x22, x23, x24, x25, x26
          local x27, x28, x29, x30, x31, x32, x33, x34, x35, x36, x37, x38
          local x39, x40, x41, x42, x43, x44, x45, x46, x47, x48, x49, x50
          local x51, x52, x53, x54, x55, x56, x57, x58, x59, x60, x61, x62
          local x63, x64, x65, x66, x67, x68, x69, x70, x71, x72, x73, x74
          local x75, x76, x77, x78, x79, x80, x81, x82, x83, x84, x85, x86
          local x87, x88, x89, x90, x91, x92, x93, x94, x95, x96, x97, x98
          local x99, x100
        end
        return recursive(a, remaining - 1, c, d, e, f) + 1
      end

      t.equal(recursive(42, 200, 1, 2, 3, 43), 207)
      local function frame_exit() return recursive(42, 0, 1, 2, 3, 43) end
      for _ = 1, 200 do assert(frame_exit() == 7) end
      for _ = 1, 10 do collectgarbage() end
      t.equal(frame_exit(), 7)
    end)
  end)
end)
