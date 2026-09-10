-- Independent interaction checks for patterns and ordinary Lua control flow.
local test = require('test.ljtest')

local function example(name, source)
  test.it(name, function(t)
    local factory, err = loadstring('return function(t)\n' .. source .. '\nend', '=' .. name)
    t.assert(factory ~= nil, err)
    local fn = factory()
    for i = 1, 80 do fn(t) end
  end)
end

test.describe('pattern combinations', function()
  example('nested pure guards preserve outer captures across fallthrough', [[
    local value='outside'
    local function select(input)
      return case input do
        when {value!,child={value=inner}!} if
          (case {value=inner} do when {value} if type(value)=='number' then value>10 else false end)
          then function() return value,inner end
        when {value!,child={value=inner}!} if
          (case inner do when false then true when 0 then true else false end)
          then function() return inner,value end
        else function() return value end
      end
    end
    local first=select({value=7,child={value=12}})
    local second=select({value=8,child={value=0}})
    local third=select({value=9,child={value=3}})
    local fourth=select({value=10,child={value=false}})
    t.results(t.pack(7,12),first)
    t.results(t.pack(0,8),second)
    t.results(t.pack('outside'),third)
    t.results(t.pack(false,10),fourth)
    t.equal(value,'outside')
  ]])

  example('adjacent case arguments keep independent closures and trailing varargs', [[
    local receiver={tag='receiver'}
    function receiver:collect(...) return self.tag,... end
    local function invoke(a,b,...)
      return receiver:collect('prefix',
        case a do when {value} then function() return value end end,
        case b do when {value} then function() return value end end,
        case nil do when nil then nil end,...)
    end
    local values=t.pack(invoke({value=7},{value=false},nil,9,nil))
    t.equal(values.n,8); t.equal(values[1],'receiver'); t.equal(values[2],'prefix')
    t.equal(values[3](),7); t.equal(values[4](),false)
    t.equal(values[5],nil); t.equal(values[6],nil); t.equal(values[7],9); t.equal(values[8],nil)
  ]])

  example('binary fallthrough closes the selected captures in stripped functions', [[
    local function decode(packet,expected)
      return case packet do
        when @b{n<u8>,payload<bytes(n)>,255<u8>} then function() return 'wrong' end
        when @b{n<u8>,payload<bytes(n)>,^expected<bytes(n)>,rest<bytes>}
          then function() return n,payload,rest end
        else function() return 'fallback' end
      end
    end
    local copy=assert(loadstring(string.dump(decode,'sd')))
    setfenv(copy,{})
    local first=copy('\2A\0A\0tail','A\0')
    local second=copy('\0','')
    local third=copy('\2ABCD','AB')
    collectgarbage('collect')
    t.results(t.pack(2,'A\0','tail'),first)
    t.results(t.pack(0,'',''),second)
    t.results(t.pack('fallback'),third)
  ]])

  example('short circuit operators preserve case truthiness and skip unused subjects', [[
    local function unused() error('unused branch evaluated') end
    local a=false and (case unused() do when _ then true end)
    local b=true or (case unused() do when _ then false end)
    local c=(case {value=false} do when {value!} then value end) or 'fallback'
    local d=(case true do when true then nil end) and unused()
    local e='left:'..(case 0 do when 0 then 'middle' end)..':right'
    local f=(case false do when false then 0 end) and 'zero is truthy'
    t.equal(a,false); t.equal(b,true); t.equal(c,'fallback'); t.equal(d,nil)
    t.equal(e,'left:middle:right'); t.equal(f,'zero is truthy')
  ]])

  example('nested try returns relay case closures and nil holes from a binary catch', [[
    local function decode(packet)
      try do
        try do error(packet,0)
        catch @b{n<u8>,payload<bytes(n)>} then
          return 'caught',nil,case {n=n,payload=payload} do
            when {n,payload} then function() return n,nil,payload end
          end,nil
        end
      catch issue then return 'unmatched',issue end
    end
    local values=t.pack(decode('\2ok'))
    t.equal(values.n,4); t.equal(values[1],'caught'); t.equal(values[2],nil); t.equal(values[4],nil)
    t.results(t.pack(2,nil,'ok'),values[3])
    local issue={kind='not a packet'}
    t.results(t.pack('unmatched',issue),function() return decode(issue) end)
  ]])

  example('a yielded case body retains captures and pending expression values', [[
    local function worker(input,...)
      local first,result,last='before',case input do
        when {value} then coroutine.yield(function() return value end)
      end,select(2,...)
      return first,result,last,...
    end
    local co=coroutine.create(worker)
    local suspended=t.pack(coroutine.resume(co,{value=false},7,nil,9))
    t.equal(suspended.n,2); t.equal(suspended[1],true); t.equal(suspended[2](),false)
    collectgarbage('collect')
    t.results(t.pack(true,'before',11,nil,7,nil,9),function()
      return coroutine.resume(co,11,12)
    end)
    t.equal(suspended[2](),false); t.equal(coroutine.status(co),'dead')
  ]])

  test.it('table clauses agree with a reference across missing false and pinned values', function(t)
    local factory=assert(loadstring([[
      return function(input,expected)
        return case input do
          when {first!,child={value=^expected}!,...rest} if first then
            {kind='pinned',value=first,extra=rest.extra}
          when {child={value,...inside}!,...outside} then
            {kind='nested',value=value,keep=inside.keep,first=outside.first,extra=outside.extra}
          else {kind='fallback'}
        end
      end
    ]]))
    local original=factory()
    local functions={original,assert(loadstring(string.dump(original,'sd')))}
    local expected={}
    local values=t.pack(nil,false,0,7,'text',expected,{})
    local function reference(input)
      local child=input.child
      if input.first~=nil and type(child)=='table' and rawequal(child.value,expected) and input.first then
        return {kind='pinned',value=input.first,extra=input.extra}
      elseif type(child)=='table' then
        return {kind='nested',value=child.value,keep=child.keep,first=input.first,extra=input.extra}
      end
      return {kind='fallback'}
    end
    for round=1,4 do
      for i=1,values.n do
        for j=1,values.n+2 do
          local child
          if j<=values.n then child={value=values[j],keep='inside'}
          elseif j==values.n+1 then child=false end
          local input={first=values[i],child=child,extra='outside'}
          local want=reference(input)
          for _,fn in ipairs(functions) do
            local actual=fn(input,expected)
            t.equal(actual.kind,want.kind); t.raw_equal(actual.value,want.value)
            t.raw_equal(actual.first,want.first); t.equal(actual.keep,want.keep)
            t.equal(actual.extra,want.extra)
          end
        end
      end
    end
  end)

  test.it('binary clauses agree with a reference for lengths payloads and late mismatches', function(t)
    local original=assert(loadstring([[
      return function(packet)
        return case packet do
          when @b{n<s8>,payload<bytes(n)>,255<u8>} then {kind='tagged',n=n,payload=payload}
          when @b{n<u8>,payload<bytes>} then {kind='fallback',n=n,payload=payload}
          else {kind='empty'}
        end
      end
    ]]))()
    local functions={original,assert(loadstring(string.dump(original,'sd')))}
    local packets={''}
    for _,n in ipairs({0,1,2,3,127,255}) do
      for size=0,4 do
        for _,tag in ipairs({0,255}) do
          packets[#packets+1]=string.char(n)..string.rep('A\0',size):sub(1,size)..string.char(tag)
        end
      end
    end
    local function reference(packet)
      if #packet==0 then return {kind='empty'} end
      local n=packet:byte(1)
      if n<128 and #packet==n+2 and packet:byte(-1)==255 then
        return {kind='tagged',n=n,payload=packet:sub(2,-2)}
      end
      return {kind='fallback',n=n,payload=packet:sub(2)}
    end
    for round=1,4 do
      for _,packet in ipairs(packets) do
        local want=reference(packet)
        for _,fn in ipairs(functions) do t.deep_equal(fn(packet),want) end
      end
    end
  end)
end)
