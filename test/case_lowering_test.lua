local test=require('test.ljtest')

local function example(name,source)
  test.it(name,function(t)
    local fn,err=loadstring('return function(t) '..source..' end','='..name)
    t.assert(fn~=nil,err)
    fn=fn()
    for i=1,80 do fn(t) end
  end)
end

test.describe('direct case expression compilation',function()
  test.it('emits no internal closure for scalar cases',function(t)
    local util=require('jit.util')
    local fn=assert(loadstring('return function(x) return 1+case x do when 7 then 3 else 4 end end'))()
    local info=util.funcinfo(fn)
    t.equal(info.children,false)
    t.equal(fn(7),4); t.equal(fn(8),5)
  end)

  example('preserves pending bindings across nested cases and pattern inputs',[[
    local a,b,c='outer-a','outer-b','outer-c'
    local a,b,c=11,case 1 do when 1 then case 2 do when 2 then b else false end end,c
    t.equal(a,11); t.equal(b,'outer-b'); t.equal(c,'outer-c')
    local {a,b}=case {a=1,b=2} do when {a,b} then {a=a+1,b=b+1} end
    t.equal(a,2); t.equal(b,3)
    local @b{n<u8>,body<bytes(n)>}=case true do when true then '\2ok' end
    t.equal(n,2); t.equal(body,'ok')
  ]])

  example('preserves indexed assignment addresses and compound values',[[
    local a={10,20}; local i=1
    a[i],i=case true do when true then 30 end,2
    t.equal(a[1],30); t.equal(a[2],20); t.equal(i,2)
    a[i]+=case 7 do when 7 then 5 end
    t.equal(a[2],25)
  ]])

  example('preserves method arguments and binary constructor temporaries',[[
    local receiver={prefix='self'}
    function receiver:join(a,b,c) return self.prefix,a,b,c end
    t.results(t.pack('self','first',7,'last'),function()
      return receiver:join('first',case 1 do when 1 then 7 end,'last')
    end)
    local data=@b{1<u8>,(case 1 do when 1 then 2 end)<u8>,3<u8>}
    t.equal(data,'\1\2\3')
  ]])

  example('closes captures separately for each loop iteration and branch',[[
    local funcs={}
    for i=1,12 do
      funcs[i]=case {value=i} do
        when {value} if value%2==0 then function() return value end
        when {value} then function() return -value end
      end
    end
    collectgarbage('collect')
    for i=1,12 do t.equal(funcs[i](),i%2==0 and i or -i) end
  ]])

  example('preserves captures in nested returned closures and dumps',[[
    local maker=case {value=7} do when {value} then function()
      return function() return value end
    end end
    t.equal(maker()(),7)
    local function decode(input)
      local result=case input do when {value} then function() return value end end
      return result
    end
    local copy=assert(loadstring(string.dump(decode)))
    local first,second=copy({value=8}),copy({value=9})
    t.equal(first(),8); t.equal(second(),9)
  ]])

  example('works with loop bounds and iterator expressions',[[
    local total=0
    for i=case 1 do when 1 then 2 end,case 1 do when 1 then 4 end do total=total+i end
    t.equal(total,9)
    for k,v in pairs(case true do when true then {a=3,b=4} end) do total=total+v end
    t.equal(total,16)
  ]])

  example('preserves raw varargs and yields in the original frame',[[
    local function worker(...)
      local value=case select('#',...) do
        when 3 then coroutine.yield(select(3,...))
        else false
      end
      return value,nil,select(1,...)
    end
    local co=coroutine.create(worker)
    t.results(t.pack(true,9),function() return coroutine.resume(co,7,nil,9) end)
    t.results(t.pack(true,11,nil,7,nil,9),function() return coroutine.resume(co,11) end)
  ]])

  example('retains Lua guard truthiness and error propagation',[[
    t.equal(case 7 do when 7 if 0 then 'selected' else 'wrong' end,'selected')
    local issue={}
    local function fail() error(issue,0) end
    local ok,err=pcall(function()
      return case 7 do when 7 if fail() then 'wrong' else 'wrong' end
    end)
    t.equal(ok,false); t.raw_equal(err,issue)
  ]])

  test.it('keeps debug local names correct inside and after pending declarations',function(t)
    local function inspect()
      local locals={}
      for slot=1,40 do
        local name,value=debug.getlocal(2,slot)
        if not name then break end
        if name:sub(1,1)~='(' then locals[name]=value end
      end
      return locals
    end
    local factory=assert(loadstring([[
      return function(inspect)
        local outer='outside'
        local result,later=case {value=7} do when {value} then inspect() end,'after'
        return result,inspect(),later
      end
    ]]))
    for _,fn in ipairs({factory(),assert(loadstring(string.dump(factory())))}) do
      local inside,after,later=fn(inspect)
      t.equal(inside.value,7); t.equal(inside.outer,'outside'); t.equal(inside.later,nil)
      t.raw_equal(after.result,inside); t.equal(after.value,nil); t.equal(after.later,'after')
      t.equal(later,'after')
    end
  end)

  test.it('supports cases after more than 200 live argument slots',function(t)
    local args={}; for i=1,210 do args[i]=tostring(i) end
    local source='return function(collect) return collect('..table.concat(args,',')..
      ",case {value=7} do when {value} then value end,'last') end"
    local fn=assert(loadstring(source))()
    local values=fn(test.pack)
    t.equal(values.n,212); t.equal(values[1],1); t.equal(values[210],210)
    t.equal(values[211],7); t.equal(values[212],'last')
  end)
end)
