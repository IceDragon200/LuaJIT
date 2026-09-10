local test = require('test.ljtest')

local function load_example(source, environment)
  local chunk = assert(loadstring(source))
  setfenv(chunk, environment or {})
  return chunk
end

test.describe('private pattern helpers', function()
  test.it('uses native matchers in an empty environment', function(t)
    local chunk = load_example([[
      local {value, ...rest} = {value=7, keep=9}
      local @b{number<u8>} = '\8'
      7 = value
      local expected = {}
      local same = case expected do when ^expected then true else false end
      return value, rest.keep, number, same, @b{number<u8>}
    ]])
    t.results(t.pack(7,9,8,true,'\8'), chunk)
  end)

  test.it('ignores replaced globals before and after compilation', function(t)
    local calls = 0
    local environment = setmetatable({}, {__index=function()
      calls = calls+1
      error('pattern syntax looked up the environment')
    end})
    environment.rawequal = function() return true end
    environment.__table_match = function() return 'wrong' end
    local chunk = load_example([[
      local {value}={value=7}
      local expected={}
      return value, case {} do when ^expected then 'wrong' else 'right' end
    ]], environment)
    t.results(t.pack(7,'right'), chunk)
    environment.rawequal = nil
    environment.__table_match = nil
    t.results(t.pack(7,'right'), chunk)
    t.equal(calls,0)
  end)

  test.it('binds helpers in nested functions and preserves user upvalues', function(t)
    local chunk = load_example([[
      local x=10
      return function(input)
        local {value}=input
        x=x+value
        return x
      end
    ]])
    local fn = chunk()
    for i=1,100 do t.equal(fn({value=1}),10+i) end
  end)

  test.it('restores private bindings from stripped and normal dumps', function(t)
    local source = [[
      return function(input,...args)
        try do
          local {value}=input
          local @b{number<u8>}='\9'
          return value,number,...args
        catch problem then return problem end
      end
    ]]
    local factory = load_example(source)
    for _,mode in ipairs({'d','sd'}) do
      local factory_dump = string.dump(factory,mode)
      t.equal(factory_dump:byte(4),128)
      local copy = assert(loadstring(factory_dump))
      setfenv(copy,{})
      local fn = copy()
      t.results(t.pack(7,9,1,nil,3),function() return fn({value=7},1,nil,3) end)
      local fncopy = assert(loadstring(string.dump(fn,mode)))
      setfenv(fncopy,{})
      t.results(t.pack(8,9,nil),function() return fncopy({value=8},nil) end)
    end
  end)

  test.it('keeps ordinary dumps in the upstream format', function(t)
    local dump = string.dump(function(x) return x+1 end,'sd')
    t.equal(dump:byte(4),2)
    t.equal(assert(loadstring(dump))(7),8)
  end)

  test.it('rejects a private dump mislabeled as an upstream dump', function(t)
    local fn = load_example('local {value}={value=7}; return value')
    local dump = string.dump(fn,'sd')
    local chunk,err = loadstring(dump:sub(1,3)..string.char(2)..dump:sub(5))
    t.equal(chunk,nil)
    t.assert(err:find('bytecode',1,true) ~= nil)
  end)

  test.it('uses native protected calls and rethrows the original error', function(t)
    local expected={}
    local calls=0
    local environment={raise=function() error(expected) end,
      pcall=function() calls=calls+1 end, error=function() calls=calls+1 end}
    local fn=load_example('try do raise() catch false then end',environment)
    local ok,err=pcall(fn)
    t.equal(ok,false); t.raw_equal(err,expected); t.equal(calls,0)
  end)

  test.it('preserves coroutine yields through a protected body', function(t)
    local fn=load_example([[
      try do
        local value=yield('paused')
        return value,nil,3
      catch problem then return 'caught',problem end
    ]],{yield=coroutine.yield})
    local co=coroutine.create(fn)
    t.results(t.pack(true,'paused'),function() return coroutine.resume(co) end)
    t.results(t.pack(true,7,nil,3),function() return coroutine.resume(co,7) end)
  end)

  test.it('initializes helpers when compilation happens during collection', function(t)
    for i=1,20 do
      local fn=load_example('return function() local {value}={value=7}; return value end')
      collectgarbage('collect')
      local child=fn()
      collectgarbage('collect')
      t.equal(child(),7)
    end
  end)
end)
