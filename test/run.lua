-- Run with: src/luajit test/run.lua test/*_test.lua
-- The top-level Makefile provides the usual entry point: make test.

local source = debug.getinfo(1, "S").source
local script_dir = source:match("^@(.*/)") or "./"
package.path = script_dir .. "../?.lua;" .. script_dir .. "../?/init.lua;" .. package.path

local test = require("test.ljtest")

local function usage()
  io.write([[usage: src/luajit test/run.lua [options] test-file.lua ...

Options:
  --filter TEXT    run tests whose full name contains TEXT
  --trace          print every test name, not just progress marks
  --list           list selected tests without running them
  --fail-fast      stop after the first failure
  --seed N         shuffle entries within each suite with integer seed N
  --help           show this help
]])
end

local options = {
  trace = false,
  list = false,
  fail_fast = false,
  filter = nil,
  seed = nil,
}
local files = {}
local index = 1
while index <= #arg do
  local item = arg[index]
  if item == "--help" then
    usage()
    os.exit(0)
  elseif item == "--trace" then
    options.trace = true
  elseif item == "--list" then
    options.list = true
  elseif item == "--fail-fast" then
    options.fail_fast = true
  elseif item == "--filter" or item == "--seed" then
    index = index + 1
    if index > #arg then
      io.stderr:write(item .. " needs a value\n")
      os.exit(2)
    end
    if item == "--filter" then
      options.filter = arg[index]
    else
      options.seed = tonumber(arg[index])
      if not options.seed or options.seed % 1 ~= 0 then
        io.stderr:write("--seed needs an integer\n")
        os.exit(2)
      end
    end
  elseif item:match("^%-%-filter=") then
    options.filter = item:sub(10)
  elseif item:match("^%-%-seed=") then
    options.seed = tonumber(item:sub(8))
    if not options.seed or options.seed % 1 ~= 0 then
      io.stderr:write("--seed needs an integer\n")
      os.exit(2)
    end
  elseif item:sub(1, 2) == "--" then
    io.stderr:write("unknown option: " .. item .. "\n")
    usage()
    os.exit(2)
  else
    files[#files + 1] = item
  end
  index = index + 1
end

if #files == 0 then
  usage()
  os.exit(2)
end

if options.seed then math.randomseed(options.seed) end
local started_at = os.clock()
local summary = {
  total = 0,
  passed = 0,
  failed = 0,
  skipped = 0,
  listed = 0,
  failures = {},
  wrote_progress = false,
  stopped = false,
}

local function traceback(err)
  return debug.traceback(tostring(err), 2)
end

local function full_name(entry)
  local names = entry.name and { entry.name } or {}
  local parent = entry.parent
  while parent and parent.name do
    table.insert(names, 1, parent.name)
    parent = parent.parent
  end
  return table.concat(names, " > ")
end

local filter = options.filter and options.filter:lower() or nil
local function selected(entry)
  return not filter or full_name(entry):lower():find(filter, 1, true) ~= nil
end

local function suite_has_selected(suite)
  for _, entry in ipairs(suite.entries) do
    if entry.kind == "test" then
      if selected(entry) then return true end
    elseif suite_has_selected(entry) then
      return true
    end
  end
  return false
end

local function entries_in_order(entries)
  local result = {}
  for i, entry in ipairs(entries) do result[i] = entry end
  if options.seed then
    for i = #result, 2, -1 do
      local j = math.random(i)
      result[i], result[j] = result[j], result[i]
    end
  end
  return result
end

local function report(mark, name, detail)
  if options.trace then
    io.write(mark .. " " .. name .. "\n")
  elseif not options.list then
    io.write(mark)
    summary.wrote_progress = true
  end
  if detail then summary.failures[#summary.failures + 1] = { name = name, detail = detail } end
end

local function record_failure(name, detail)
  summary.total = summary.total + 1
  summary.failed = summary.failed + 1
  report("FAIL", name, detail)
  if options.fail_fast then summary.stopped = true end
end

local function record_skip(entry, reason)
  if not selected(entry) then return end
  summary.total = summary.total + 1
  summary.skipped = summary.skipped + 1
  report("SKIP", full_name(entry) .. (reason and " (" .. reason .. ")" or ""))
end

local function skip_suite(suite, reason)
  for _, entry in ipairs(suite.entries) do
    if entry.kind == "test" then
      record_skip(entry, reason)
    else
      skip_suite(entry, reason)
    end
  end
end

local function call(fn, context)
  return xpcall(function() return fn(test, context) end, traceback)
end

local function run_test(entry, suites)
  if entry.skipped then
    record_skip(entry)
    return
  end
  summary.total = summary.total + 1
  local context = { name = entry.name, full_name = full_name(entry) }
  local failure = nil
  for _, suite in ipairs(suites) do
    for _, hook in ipairs(suite.before_each) do
      local ok, err = call(hook, context)
      if not ok then
        failure = "before_each failed:\n" .. err
        break
      end
    end
    if failure then break end
  end
  if not failure then
    local ok, err = call(entry.fn, context)
    if not ok then failure = err end
  end
  for suite_index = #suites, 1, -1 do
    local suite = suites[suite_index]
    for _, hook in ipairs(suite.after_each) do
      local ok, err = call(hook, context)
      if not ok then
        local hook_error = "after_each failed:\n" .. err
        failure = failure and (failure .. "\n\n" .. hook_error) or hook_error
      end
    end
  end
  if failure then
    summary.failed = summary.failed + 1
    report("FAIL", full_name(entry), failure)
    if options.fail_fast then summary.stopped = true end
  else
    summary.passed = summary.passed + 1
    report("PASS", full_name(entry))
  end
end

local function run_suite(suite, parents, inherited_skip)
  if summary.stopped or not suite_has_selected(suite) then return end
  local skipped = inherited_skip or suite.skipped
  if skipped then
    skip_suite(suite, "disabled suite")
    return
  end
  local suites = {}
  for i, parent in ipairs(parents) do suites[i] = parent end
  suites[#suites + 1] = suite

  for _, hook in ipairs(suite.before_all) do
    local ok, err = call(hook, { name = suite.name, full_name = full_name(suite) })
    if not ok then
      record_failure(full_name(suite) .. " > before_all", err)
      skip_suite(suite, "before_all failed")
      return
    end
  end

  for _, entry in ipairs(entries_in_order(suite.entries)) do
    if summary.stopped then break end
    if entry.kind == "test" then
      if selected(entry) then run_test(entry, suites) end
    else
      run_suite(entry, suites, false)
    end
  end

  for _, hook in ipairs(suite.after_all) do
    local ok, err = call(hook, { name = suite.name, full_name = full_name(suite) })
    if not ok then record_failure(full_name(suite) .. " > after_all", err) end
  end
end

local function list_suite(suite, inherited_skip)
  local skipped = inherited_skip or suite.skipped
  for _, entry in ipairs(suite.entries) do
    if entry.kind == "test" then
      if selected(entry) then
        summary.listed = summary.listed + 1
        io.write((skipped or entry.skipped) and "SKIP " or "     ", full_name(entry), "\n")
      end
    else
      list_suite(entry, skipped)
    end
  end
end

for _, file in ipairs(files) do
  local ok, err = xpcall(function() return dofile(file) end, traceback)
  if not ok then record_failure("load " .. file, err) end
  if summary.stopped then break end
end

if options.list then
  list_suite(test._root, false)
  if summary.failed > 0 then
    for number, failure in ipairs(summary.failures) do
      io.write("\n", number, ") ", failure.name, "\n", failure.detail, "\n")
    end
  end
  io.write("\n", summary.listed, " test", summary.listed == 1 and "" or "s", " listed\n")
  os.exit(summary.failed == 0 and summary.listed > 0 and 0 or 1)
end

run_suite(test._root, {}, false)
if summary.wrote_progress then io.write("\n") end
for number, failure in ipairs(summary.failures) do
  io.write("\n", number, ") ", failure.name, "\n", failure.detail, "\n")
end

local elapsed = os.clock() - started_at
io.write(string.format("\n%d tests, %d passed, %d failed, %d skipped, %d assertions in %.3fs\n",
  summary.total, summary.passed, summary.failed, summary.skipped,
  test._stats.assertions, elapsed))
if options.seed then io.write("seed: ", options.seed, "\n") end
if summary.total == 0 and summary.failed == 0 then
  io.stderr:write("no tests matched\n")
end
os.exit(summary.failed == 0 and summary.total > 0 and 0 or 1)
