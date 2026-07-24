-- Regression tests adapted from LuaJIT/LuaJIT-test-cleanup.
--
-- Source paths and provenance are recorded in test/THIRD_PARTY_NOTICES.md.
-- The imported source cases were present in Mike Pall's initial commit
-- a273241fe6386718cc741c852f783ad5a0138e2b, which the upstream README
-- places in the public domain for tests written by Mike Pall. They have been
-- reshaped into ljtest examples; the bit library case is capability-gated.

local test = require("test.ljtest")

test.describe("LuaJIT cleanup library regressions", function()
  test.describe("bit library", { requires = { bit = true } }, function()
    test.it("preserves the published operation-vector checksums", function(t)
      local bit = require("bit")
      local values = {
        0, 1, -1, 2, -2, 0x12345678, 0x87654321,
        0x33333333, 0x77777777, 0x55aa55aa, 0xaa55aa55,
        0x7fffffff, 0x80000000, 0xffffffff,
      }
      local function checksum(text)
        local total = 0
        for index = 1, #text do total = (total + string.byte(text, index) * index) % 2147483629 end
        return total
      end
      local function unary(name, expected)
        local fn = bit[name]
        t.refute(pcall(fn))
        t.refute(pcall(fn, "z"))
        t.refute(pcall(fn, true))
        local text = ""
        for _, value in ipairs(values) do text = text .. "," .. tostring(fn(value)) end
        t.equal(checksum(text), expected)
      end
      local function binary(name, expected, first, last)
        local fn = bit[name]
        t.refute(pcall(fn))
        t.refute(pcall(fn, "z"))
        t.refute(pcall(fn, true))
        t.refute(pcall(fn, 1, true))
        local text = ""
        for _, value in ipairs(values) do
          for other = first, last do text = text .. "," .. tostring(fn(value, other)) end
        end
        t.equal(checksum(text), expected)
      end
      local function binary_values(name, expected)
        local fn = bit[name]
        t.refute(pcall(fn))
        t.refute(pcall(fn, "z"))
        t.refute(pcall(fn, true))
        local text = ""
        for _, value in ipairs(values) do
          for _, other in ipairs(values) do text = text .. "," .. tostring(fn(value, other)) end
        end
        t.equal(checksum(text), expected)
      end

      unary("tobit", 277312)
      unary("bnot", 287870)
      unary("bswap", 307611)
      binary_values("band", 41206764)
      binary_values("bor", 51253663)
      binary_values("bxor", 79322427)
      binary("lshift", 325260344, 0, 31)
      binary("rshift", 139061800, 0, 31)
      binary("arshift", 111364720, 0, 31)
      binary("rol", 302401155, 0, 31)
      binary("ror", 302316761, 0, 31)
      binary("tohex", 47880306, -8, 8)
    end)
  end)

  test.describe("string library", function()
    test.it("keeps byte slices and a 500-result call well formed", function(t)
      local band, bor = bit.band, bit.bor
      local byte = string.byte
      local first, second, third
      for outer = 100, 107 do
        for index = 1, outer do
          first, second, third = byte("abcdefg", band(index, 7), band(index + 2, 7))
        end
        local expected_first, expected_second, expected_third =
          byte("abcdefg", band(outer, 7), band(outer + 2, 7))
        t.equal(first, expected_first)
        t.equal(second, expected_second)
        t.equal(third, expected_third)
      end
      for outer = -100, -107, -1 do
        for index = -1, outer, -1 do first, second, third = byte("abc", bor(index, -8), -1) end
        local expected_first, expected_second, expected_third = byte("abc", bor(outer, -8), -1)
        t.equal(first, expected_first)
        t.equal(second, expected_second)
        t.equal(third, expected_third)
      end
      t.equal(select("#", byte(string.rep("x", 500), 1, 500)), 500)
    end)

    test.it("converts character arguments and rejects an out-of-range result", function(t)
      local value
      for _ = 1, 100 do value = string.char(65) end
      t.equal(value, "A")
      for _ = 1, 100 do value = string.char("98") end
      t.equal(value, "b")
      for index = 1, 100 do value = string.char(32 + index) end
      t.equal(value, "\132")
      t.raises(function()
        for index = 1, 200 do value = string.char(100 + index) end
      end)
      t.equal(value, "\255")
      for index = 1, 100 do value = string.char(65, 66, index, 67, 68) end
      t.equal(value, "ABdCD")
    end)

    test.it("dumps bytecode without retaining JIT patches", function(t)
      local function worker()
        local values = {}
        for index = 1, 100 do values[index] = index end
        for _ in ipairs(values) do end
        local count = 0
        while count < 100 do count = count + 1 end
      end
      local before = string.dump(worker)
      worker()
      t.equal(string.dump(worker), before)
      jit.off(worker)
      worker()
      t.equal(string.dump(worker), before)
      local stripped = string.dump(loadstring(before, ""), true)
      local redumped = string.dump(assert(loadstring(stripped, "")), true)
      t.equal(stripped, redumped)
      t.assert(loadstring(string.dump(assert(loadstring(stripped, "")))))
    end)

    test.it("keeps reverse, case conversion, and repetition values stable", function(t)
      local value
      for _ = 1, 100 do value = string.reverse("abc") end
      t.equal(value, "cba")
      for _ = 1, 100 do value = string.upper(":abCd+") end
      t.equal(value, ":ABCD+")
      for _ = 1, 100 do value = string.lower(":aBcD+") end
      t.equal(value, ":abcd+")
      for _ = 1, 100 do value = string.rep("ab", 10, "c") end
      t.equal(value, "abcabcabcabcabcabcabcabcabcab")
      for index = 1, 100 do value = string.rep("ab", index - 85) end
      t.equal(value, "ababababababababababababababab")
    end)

    test.it("does not fold incorrect fixed string-sub comparisons", function(t)
      local source = "abcde"
      local match_one, match_two, match_three, match_four = 0, 0, 0, 0
      for _ = 1, 100 do
        if string.sub(source, 1, 1) == "a" then match_one = match_one + 1 end
        if string.sub(source, 1, 1) == "b" then match_two = match_two + 1 end
        if string.sub(source, 1, 2) == "ab" then match_three = match_three + 1 end
        if string.sub(source, 1, 2) == "a" then match_four = match_four + 1 end
      end
      t.equal(match_one, 100)
      t.equal(match_two, 0)
      t.equal(match_three, 100)
      t.equal(match_four, 0)
    end)
  end)

  test.describe("table library and constructors", function()
    test.it("keeps table insertion and removal boundaries correct", function(t)
      local values = {}
      for index = 1, 100 do values[index] = index end
      for index = 1, 100 do table.insert(values, index) end
      t.equal(#values, 200)
      t.equal(values[100], 100)
      t.equal(values[200], 100)

      values = {}
      for index = 1, 200 do values[index] = index end
      for index = 1, 100 do t.equal(table.remove(values), 201 - index) end
      t.equal(#values, 100)
      t.equal(values[100], 100)

      values = {}
      for index = 1, 200 do values[index] = index end
      for index = 1, 100 do t.equal(table.remove(values, 1), index) end
      t.equal(#values, 100)
      t.equal(values[100], 200)
    end)

    test.it("expands only the final function expression in a table constructor", function(t)
      local function values() return 1, 2, 3 end
      local result = { (values()) }
      t.equal(result[1], 1)
      t.equal(result[2], nil)
      result = { values() }
      t.deep_equal(result, { 1, 2, 3 })
      result = { values(), values() }
      t.deep_equal(result, { 1, 1, 2, 3 })
      local function last() return 9, 10 end
      for _ = 1, 100 do result = { 1, 2, 3, last() } end
      t.deep_equal(result, { 1, 2, 3, 9, 10 })
    end)

    test.it("does not reuse a table.concat result after a table write", function(t)
      local values = { 1, 2, 3 }
      local before, after
      for index = 1, 100 do
        before = table.concat(values, "x", 1, 3)
        values[2] = index
        after = table.concat(values, "x", 1, 3)
      end
      t.equal(before, "1x99x3")
      t.equal(after, "1x100x3")
    end)
  end)

  test.describe("multi-result selection", function()
    test.it("retains select counts and values across a hot vararg loop", function(t)
      local count_total, value_total, next_total = 0, 0, 0
      for index = 1, 100 do
        count_total = count_total + select("#", 3, 4)
        value_total = value_total + select(1, index)
        local first, second = select(2, 1, index, index + 10)
        next_total = next_total + first + second
      end
      t.equal(count_total, 200)
      t.equal(value_total, 5050)
      t.equal(next_total, 11100)

      local function sum(expected, ...)
        local total = 0
        for index = 1, select("#", ...) do total = total + select(index, ...) end
        return total == expected
      end
      for _ = 1, 100 do
        t.assert(sum(1, 1))
        t.assert(sum(15, 1, 2, 3, 4, 5))
        t.assert(sum(0))
        t.assert(sum(3200, string.byte(string.rep(" ", 100), 1, 100)))
      end
    end)
  end)
end)
