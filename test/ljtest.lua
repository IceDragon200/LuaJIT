--
-- A deliberately small test framework for LuaJIT itself and its extensions.
-- Test files register examples when they are loaded; test/run.lua owns loading,
-- filtering, execution, reporting, and the process exit status.
--

local test = {}

local root = {
  kind = "suite",
  name = nil,
  entries = {},
  before_each = {},
  after_each = {},
  before_all = {},
  after_all = {},
}
local current = root

test._root = root
test._stats = { assertions = 0, assertion_failures = 0 }

local function traceback(err)
  return debug.traceback(tostring(err), 2)
end

local function check_name(kind, name)
  if type(name) ~= "string" or name == "" then
    error(kind .. " name must be a non-empty string", 3)
  end
end

local function check_function(kind, fn)
  if type(fn) ~= "function" then
    error(kind .. " expects a function", 3)
  end
end

local function format_message(message, fallback)
  if message == nil then return fallback end
  if type(message) == "function" then return tostring(message()) end
  return tostring(message)
end

local function append(entries, entry)
  entries[#entries + 1] = entry
  return entry
end

local function normalize_options(kind, options, body)
  if type(options) == "function" then return {}, options end
  if options == nil then return {}, body end
  if type(options) ~= "table" then
    error(kind .. " options must be a table", 3)
  end
  return options, body
end

local function add_suite(name, options, body, skipped)
  check_name("describe", name)
  options, body = normalize_options("describe", options, body)
  check_function("describe", body)
  local parent = current
  local suite = append(parent.entries, {
    kind = "suite",
    name = name,
    parent = parent,
    skipped = skipped,
    requires = options.requires,
    entries = {},
    before_each = {},
    after_each = {},
    before_all = {},
    after_all = {},
  })
  current = suite
  local ok, err = xpcall(body, traceback)
  current = parent
  if not ok then error(err, 0) end
  return suite
end

local function add_test(name, options, fn, skipped)
  check_name("test", name)
  options, fn = normalize_options("test", options, fn)
  check_function("test", fn)
  return append(current.entries, {
    kind = "test",
    name = name,
    fn = fn,
    parent = current,
    skipped = skipped,
    requires = options.requires,
  })
end

--- Register a named group of tests. Groups may be nested.
function test.describe(name, options, body)
  return add_suite(name, options, body, false)
end

--- Register a group whose tests are reported as skipped.
function test.xdescribe(name, options, body)
  return add_suite(name, options, body, true)
end

--- Register one test. The callback receives this module as its first argument.
function test.test(name, options, fn)
  return add_test(name, options, fn, false)
end

test.it = test.test

--- Register one test but do not execute it.
function test.xtest(name, options, fn)
  return add_test(name, options, fn, true)
end

test.xit = test.xtest

local function add_hook(name, fn)
  check_function(name, fn)
  current[name][#current[name] + 1] = fn
end

function test.before_each(fn) add_hook("before_each", fn) end
function test.after_each(fn) add_hook("after_each", fn) end
function test.before_all(fn) add_hook("before_all", fn) end
function test.after_all(fn) add_hook("after_all", fn) end

local type_rank = {
  ["nil"] = 1,
  ["boolean"] = 2,
  ["number"] = 3,
  ["string"] = 4,
  ["table"] = 5,
  ["function"] = 6,
  ["userdata"] = 7,
  ["thread"] = 8,
  ["cdata"] = 9,
}

local function render(value, seen, depth)
  local kind = type(value)
  if kind == "nil" or kind == "boolean" or kind == "number" then
    return tostring(value)
  elseif kind == "string" then
    return string.format("%q", value)
  elseif kind ~= "table" then
    return "<" .. kind .. " " .. tostring(value) .. ">"
  end

  seen = seen or {}
  depth = depth or 0
  if seen[value] then return "<cycle>" end
  if depth >= 5 then return "{...}" end
  seen[value] = true

  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b)
    local ak, bk = type(a), type(b)
    if ak ~= bk then return type_rank[ak] < type_rank[bk] end
    return tostring(a) < tostring(b)
  end)

  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = "[" .. render(key, seen, depth + 1) .. "] = " ..
      render(value[key], seen, depth + 1)
  end
  seen[value] = nil
  return "{" .. table.concat(parts, ", ") .. "}"
end

test.inspect = render

local function fail(message, level)
  test._stats.assertions = test._stats.assertions + 1
  test._stats.assertion_failures = test._stats.assertion_failures + 1
  error("assertion failed: " .. message, (level or 1) + 1)
end

local function pass()
  test._stats.assertions = test._stats.assertions + 1
end

--- Assert a truthy value.
function test.assert(value, message)
  if value then
    pass()
    return value
  end
  fail(format_message(message, "expected a truthy value"), 2)
end

test.ok = test.assert

--- Assert a falsy value.
function test.refute(value, message)
  if not value then
    pass()
    return value
  end
  fail(format_message(message, "expected a falsy value, got " .. render(value)), 2)
end

test.not_ok = test.refute

--- Assert ordinary Lua equality. Arguments are actual, then expected.
function test.equal(actual, expected, message)
  if actual == expected then
    pass()
    return actual
  end
  fail(format_message(message, "values differ:\n  actual: " .. render(actual) ..
    "\nexpected: " .. render(expected)), 2)
end

test.eq = test.equal

function test.not_equal(actual, expected, message)
  if actual ~= expected then
    pass()
    return actual
  end
  fail(format_message(message, "values unexpectedly match: " .. render(actual)), 2)
end

test.ne = test.not_equal

function test.raw_equal(actual, expected, message)
  if rawequal(actual, expected) then
    pass()
    return actual
  end
  fail(format_message(message, "values are not raw-equal:\n  actual: " ..
    render(actual) .. "\nexpected: " .. render(expected)), 2)
end

local function deeply_equal(actual, expected, seen)
  if actual == expected then return true end
  if type(actual) ~= type(expected) or type(actual) ~= "table" then return false end
  seen = seen or {}
  if seen[actual] then return seen[actual] == expected end
  seen[actual] = expected
  for key, value in pairs(actual) do
    if rawget(expected, key) == nil or not deeply_equal(value, expected[key], seen) then
      return false
    end
  end
  for key in pairs(expected) do
    if rawget(actual, key) == nil then return false end
  end
  return true
end

test.deeply_equal = deeply_equal

--- Assert structural equality for tables, including nested tables.
function test.deep_equal(actual, expected, message)
  if deeply_equal(actual, expected) then
    pass()
    return actual
  end
  fail(format_message(message, "structures differ:\n  actual: " .. render(actual) ..
    "\nexpected: " .. render(expected)), 2)
end

test.deep_eq = test.deep_equal

local function matches(value, pattern, seen)
  if type(value) ~= type(pattern) then return false end
  if type(pattern) ~= "table" then return value == pattern end
  seen = seen or {}
  if seen[pattern] then return seen[pattern] == value end
  seen[pattern] = value
  for key, expected in pairs(pattern) do
    if not matches(value[key], expected, seen) then return false end
  end
  return true
end

--- Assert that a table contains the fields in a partial table pattern.
function test.matches(value, pattern, message)
  if matches(value, pattern) then
    pass()
    return value
  end
  fail(format_message(message, "value does not match pattern:\n  actual: " ..
    render(value) .. "\n pattern: " .. render(pattern)), 2)
end

--- Assert that a number is within an inclusive range.
function test.in_range(value, minimum, maximum, message)
  if value >= minimum and value <= maximum then
    pass()
    return value
  end
  fail(format_message(message, "expected " .. render(value) .. " to be within " ..
    render(minimum) .. ".." .. render(maximum)), 2)
end

function test.near(actual, expected, epsilon, message)
  epsilon = epsilon or 0.000001
  if math.abs(actual - expected) <= epsilon then
    pass()
    return actual
  end
  fail(format_message(message, "expected " .. render(actual) .. " to be within " ..
    render(epsilon) .. " of " .. render(expected)), 2)
end

--- Pack all return values, retaining nil holes and the exact result count.
function test.pack(...)
  return { n = select("#", ...), ... }
end

--- Assert that fn returns precisely the packed values in expected.
function test.results(expected, fn, message)
  if type(expected) ~= "table" or type(expected.n) ~= "number" then
    error("results expects a table returned by test.pack", 2)
  end
  check_function("results", fn)
  local actual = test.pack(fn())
  if actual.n ~= expected.n then
    fail(format_message(message, "result counts differ:\n  actual: " .. actual.n ..
      "\nexpected: " .. expected.n), 2)
  end
  for index = 1, expected.n do
    if not deeply_equal(actual[index], expected[index]) then
      fail(format_message(message, "result " .. index .. " differs:\n  actual: " ..
        render(actual[index]) .. "\nexpected: " .. render(expected[index])), 2)
    end
  end
  pass()
  return actual
end

--- Assert that fn raises. expected may be a plain substring or a predicate.
function test.raises(fn, expected, message)
  check_function("raises", fn)
  -- Keep the original error value for predicate expectations. The runner adds
  -- a traceback around failed tests; an assertion should not turn an arbitrary
  -- Lua error object (for example a table) into a string first.
  local ok, err = pcall(fn)
  if ok then
    fail(format_message(message, "expected function to raise an error"), 2)
  end
  local text = tostring(err)
  if expected ~= nil then
    local matched
    if type(expected) == "function" then
      matched = expected(err)
    elseif type(expected) == "string" then
      matched = text:find(expected, 1, true) ~= nil
    else
      matched = err == expected
    end
    if not matched then
      fail(format_message(message, "error did not match expectation:\n  error: " ..
        text .. "\nexpected: " .. render(expected)), 2)
    end
  end
  pass()
  return err
end

test.error = test.raises

return test
