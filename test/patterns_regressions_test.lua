local test = require('test.ljtest')

local function example(name, source)
  test.it(name, function(t)
    local chunk, err = loadstring('return function(t)\n' .. source .. '\nend', '=' .. name)
    t.assert(chunk ~= nil, err)
    local worker = chunk()
    for _ = 1, 80 do worker(t) end
  end)
end

test.describe('pattern regressions', function()
  test.it('contextual lookahead works across reader chunks and collection', function(t)
    local source = [[
      local function outer()
        local function case(value) return value end
        local first = case(function() return 'retained in a child' end)()
        local second = case ({value='retained in a pattern'}) do
          when {value} then value
        end
        return first, second
      end
      return outer()
    ]]
    local pos = 0
    local chunk, err = load(function()
      collectgarbage('collect')
      pos = pos + 1
      if pos <= #source then return source:sub(pos, pos) end
    end, '=case-reader')
    t.assert(chunk ~= nil, err)
    t.results(t.pack('retained in a child', 'retained in a pattern'), chunk)
  end)

  test.it('contextual lookahead preserves syntax error line numbers', function(t)
    local chunk, err = loadstring('local case = function(x) return x end\n' ..
      'local value = case(\n1\n)\nlocal broken =\n', '=case-lines')
    t.equal(chunk, nil)
    t.assert(err:find('case-lines:6:', 1, true) ~= nil, err)
  end)

  example('rest excludes positional keys in the hash part', [[
    local input = require('table.new')(0, 8)
    input[1], input[2], input.keep = 'first', 'second', 'retained'
    local {.first, .second, ...rest} = input
    t.equal(first, 'first'); t.equal(second, 'second')
    t.deep_equal(rest, {keep='retained'})
    local result = case input do when {.a, .b, ...tail} then tail end
    t.deep_equal(result, {keep='retained'})
  ]])

  example('case preserves pending names and RHS scope', [[
    local x = 'outer'
    local x, y, z = case 1 do when 1 then x end, 'second', 'third'
    t.equal(x, 'outer'); t.equal(y, 'second'); t.equal(z, 'third')
    local f, x = function() return x end, case 1 do when 1 then 9 end
    t.equal(f(), 'outer'); t.equal(x, 9)
  ]])

  example('case preserves raw and named varargs', [[
    local function f(first, ...args)
      return first, case select('#', ...) do
        when 3 then select(3, ...)
        else select('#', ...args)
      end
    end
    t.results(t.pack('first', 9), function() return f('first', 1, nil, 9) end)
    t.results(t.pack('first', 0), function() return f('first') end)
  ]])

  example('case always yields one result', [[
    local function values() return 7, 8, 9 end
    local function f() return case true do when true then values() end end
    t.results(t.pack(7), f)
    local a, b = case true do when true then values() end
    t.equal(a, 7); t.equal(b, nil)
  ]])

  example('expression clause closures preserve captures and outer updates', [[
    local total, callbacks = 0, {}
    local function add(x) total = total + x; return total end
    for i=1,3 do
      callbacks[i] = case {value=i} do
        when {value} if value > 0 then function() add(value); return value end
      end
    end
    t.equal(callbacks[1](), 1); t.equal(callbacks[2](), 2); t.equal(callbacks[3](), 3)
    t.equal(total, 6)
  ]])

  example('case closures survive a bytecode round trip', [[
    local function f(value, ...)
      return 'prefix', case (value) do when 1 then select(2, ...) else 0 end
    end
    local copy = assert(loadstring(string.dump(f)))
    t.results(t.pack('prefix', 9), function() return copy(1, nil, 9) end)
  ]])

  example('case supports parenthesized subjects and arithmetic', [[
    local value = 6
    local a = case (value + 1) do when 7 then 'grouped' end
    local b = case (value) + 1 do when 7 then 'sum' end
    local c = case -value do when -6 then 'negative' end
    t.equal(a, 'grouped'); t.equal(b, 'sum'); t.equal(c, 'negative')
    case (value) do when 6 then value = value + 1 end
    t.equal(value, 7)
  ]])

  example('case supports other contextual names as subjects', [[
    local when, catch, continue, const = 7, 8, 9, 10
    t.equal(case when do when 7 then 'when' end, 'when')
    t.equal(case catch do when 8 then 'catch' end, 'catch')
    t.equal(case continue do when 9 then 'continue' end, 'continue')
    t.equal(case const do when 10 then 'const' end, 'const')
  ]])

  example('case variables remain valid in operators and clause results', [[
    local case = 7
    t.equal(case - 1, 6); t.equal(case + 1, 8); t.equal(case * 2, 14)
    t.equal(case | 8, 15); t.equal(case ~ 1, 6)
    t.equal(case == 7, true)
    local result = case 1 do when 2 then case when 1 then case else case end
    t.equal(result, 7)
    local function f() return case end
    t.equal(f(), 7)
  ]])

  example('case calls accept all Lua argument forms', [[
    local calls = 0
    local function case(value) calls = calls + 1; return value end
    t.equal(case(7), 7); t.equal(case 'text', 'text')
    t.deep_equal(case {1, 2}, {1, 2})
    case(7)
    do calls = calls + 1 end
    t.equal(calls, 5)
    local function f() return case(8) end
    t.equal(f(), 8)
  ]])

  example('global case calls remain contextual', [[
    local chunk = assert(loadstring('return case(9), case "text", case {3}'))
    setfenv(chunk, {case=function(x) return x end})
    local a, b, c = chunk()
    t.equal(a, 9); t.equal(b, 'text'); t.deep_equal(c, {3})
  ]])

  example('nested binary constructors retain each descriptor', [[
    local data = @b{'A',(@b{'B',(@b{})<bytes>,7<u8>})<bytes>,'Z'}
    t.equal(data, 'AB\7Z')
    t.equal(@b{}, '')
    local other = @b{'X',(function({value}) return value end)({value=9})<u8>,'Y'}
    t.equal(other, 'X\9Y')
  ]])

  example('failed binary parsing does not affect the next chunk', [[
    local chunk = loadstring("return @b{'A',(@b{7<unknown>})<bytes>}")
    t.equal(chunk, nil)
    local nextchunk = assert(loadstring("return @b{'B',(@b{9<u8>})<bytes>,'C'}"))
    t.equal(nextchunk(), 'B\9C')
  ]])

  example('three nested try scopes preserve trailing nils and closures', [[
    local function f()
      try do
        try do
          try do
            local value=7
            return function() return value end, nil, 3, nil
          catch e then error(e) end
        catch e then error(e) end
      catch e then error(e) end
      return 'fell through'
    end
    local values = t.pack(f())
    t.equal(values.n, 4); t.equal(values[1](), 7)
    t.equal(values[2], nil); t.equal(values[3], 3); t.equal(values[4], nil)
  ]])

  example('scalar pins still match identical objects and numeric values', [[
    local expected = setmetatable({}, {__eq=function() error('unexpected equality') end})
    t.equal(case expected do when ^expected then true else false end, true)
    local number = 7.0
    t.equal(case 7 do when ^number then true else false end, true)
    local caught = false
    try do error(expected) catch ^expected then caught = true end
    t.equal(caught, true)
  ]])

  example('float16 rejects non-finite values and rounded overflow', [[
    for _,value in ipairs({math.huge, -math.huge, 0/0, 65520, -65520}) do
      t.raises(function() return @b{value<f16>} end, 'does not fit')
    end
  ]])
end)

test.describe('built-in function metadata', {requires={ffi=true}}, function()
  test.it('keeps FFI functions identifiable after extension registration', function(t)
    local ffi, util = require('ffi'), require('jit.util')
    for _, fn in pairs(ffi) do
      if type(fn) == 'function' then
        local info = util.funcinfo(fn)
        t.assert(info.ffid > 0 and info.ffid <= 255)
        t.equal(debug.getinfo(fn).what, 'C')
      end
    end
    local value = ffi.gc(ffi.new('int[1]', 7), function() end)
    t.equal(value[0], 7)
    t.raw_equal(ffi.gc(value, nil), value)
  end)
end)
