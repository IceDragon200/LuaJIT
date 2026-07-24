-- Regression tests adapted from LuaJIT/LuaJIT-test-cleanup.
--
-- Source paths and provenance are recorded in test/THIRD_PARTY_NOTICES.md.
-- The imported source cases were present in Mike Pall's initial commit
-- a273241fe6386718cc741c852f783ad5a0138e2b, which the upstream README
-- places in the public domain for tests written by Mike Pall. They have been
-- reshaped into ljtest examples; JIT-specific cases are capability-gated.

local test = require("test.ljtest")

test.describe("LuaJIT cleanup protected-call regressions", { requires = { jit = true } }, function()
  local function triple_pcall(fn, value)
    return pcall(pcall, pcall, fn, value)
  end

  local function handler(err) return "tr" .. err end
  local function triple_xpcall(fn, value)
    return xpcall(xpcall, handler, xpcall, handler, fn, handler, value)
  end

  local function check_success(t, invoke)
    local function square(value) return value * value end
    local square_total, sqrt_total = 0, 0
    for value = 1, 100 do
      local first, second, third, result = invoke(square, value)
      t.assert(first and second and third)
      square_total = square_total + result
      first, second, third, result = invoke(math.sqrt, value * value)
      t.assert(first and second and third)
      sqrt_total = sqrt_total + result
    end
    t.equal(square_total, 338350)
    t.equal(sqrt_total, 5050)
  end

  local function check_error_transition(t, invoke, expected_error)
    local function fail_at_150(value)
      if value >= 150 then error("test", 0) end
      return value
    end
    local total = 0
    for value = 1, 200 do
      local first, second, third, result = invoke(fail_at_150, value)
      if not (first and second and third) then
        t.assert(first and second and not third)
        t.equal(result, expected_error)
        break
      end
      total = total + result
    end
    t.equal(total, 11175)
  end

  local function check_side_exit(t, invoke, expected_error)
    local function branch(value)
      if value >= 150 then
        if value >= 175 then error("test", 0) end
        return value * value
      end
      return value
    end
    local total = 0
    for value = 1, 200 do
      local first, second, third, result = invoke(branch, value)
      if first and second and third then
        total = total + result
      else
        t.assert(first and second and not third)
        t.equal(result, expected_error)
      end
    end
    t.equal(total, 668575)
  end

  test.it("keeps nested pcall result frames intact", function(t)
    check_success(t, triple_pcall)
    check_error_transition(t, triple_pcall, "test")
    check_side_exit(t, triple_pcall, "test")
  end)

  test.it("keeps nested xpcall result frames and handlers intact", function(t)
    check_success(t, triple_xpcall)
    check_error_transition(t, triple_xpcall, "trtest")
    check_side_exit(t, triple_xpcall, "trtest")

    for _ = 1, 100 do
      local first, second, third, result = triple_xpcall(error, "test")
      t.assert(first and second and not third)
      t.equal(result, "trtest")
    end
  end)

  test.it("returns ordinary values after a compiled branch transition", function(t)
    local function branch(value)
      if value >= 150 then return value * value end
      return value
    end
    local pcall_total, xpcall_total = 0, 0
    for value = 1, 200 do
      local first, second, third, result = triple_pcall(branch, value)
      t.assert(first and second and third)
      pcall_total = pcall_total + result
      first, second, third, result = triple_xpcall(branch, value)
      t.assert(first and second and third)
      xpcall_total = xpcall_total + result
    end
    t.equal(pcall_total, 1584100)
    t.equal(xpcall_total, 1584100)
  end)
end)
