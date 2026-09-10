-- Additional independently authored behavioral tests for the fork's syntax.
-- Run with the fork's test/run.lua, with JIT on and off.
local test = require('test.ljtest')

local function example(name, source)
  test.it(name, function(t)
    local chunk, err = loadstring('return function(t)\n' .. source .. '\nend', '=' .. name)
    t.assert(chunk ~= nil, err)
    local worker = chunk()
    for _ = 1, 80 do worker(t) end
  end)
end

test.describe('extended table patterns', function()
  example('optional fields and false required fields', [[
    local {missing, enabled!, .first, .second!} = {enabled=false, [2]=false}
    t.equal(missing,nil); t.equal(enabled,false)
    t.equal(first,nil); t.equal(second,false)
  ]])
  example('absent optional parent binds nils', [[
    local {parent={kind='ok', leaf!, nested={value!}!, ...tail}} = {}
    t.equal(leaf,nil); t.equal(value,nil); t.equal(tail,nil)
  ]])
  example('required parent fails when missing', [[
    t.raises(function() local {parent={value}!} = {} end, 'parent')
  ]])
  example('present non-table parent fails', [[
    t.raises(function() local {parent={value}} = {parent=false} end, 'parent')
  ]])
  example('literals and wildcards consume positional fields', [[
    local {'ok', ._, .number!, flag=false, ...tail} = {'ok','skip',7,9,flag=false,keep=true}
    t.equal(number,7); t.deep_equal(tail,{[4]=9,keep=true})
  ]])
  example('nil literal matches absent named and positional fields', [[
    local {nil, flag=nil, ...tail} = {keep=true}
    t.deep_equal(tail,{keep=true})
  ]])
  example('rest is shallow and independent of input', [[
    local child={x=1}; local original={drop=7,child=child}
    local {drop,...tail}=original
    tail.added=8; t.equal(original.added,nil); t.raw_equal(tail.child,child)
    t.equal(tail.drop,nil); t.equal(original.drop,7)
  ]])
  example('nested rest remains at its own level', [[
    local {parent={a,...inner}!,...outer}={parent={a=1,b=2},other=3}
    t.equal(a,1); t.deep_equal(inner,{b=2}); t.deep_equal(outer,{other=3})
  ]])
  example('table pins compare raw identities', [[
    local count=0; local mt={__eq=function() count=count+1; return true end}
    local expected=setmetatable({},mt); local actual=setmetatable({},mt)
    local result=case {value=actual} do when {value=^expected} then 'bad' else 'ok' end
    t.equal(result,'ok'); t.equal(count,0)
  ]])
  example('strict assignment waits until the whole match succeeds', [[
    local a,b='old-a','old-b'
    t.raises(function() {a,b,kind='ok'}={a=1,b=2,kind='wrong'} end,'kind')
    t.equal(a,'old-a'); t.equal(b,'old-b')
  ]])
  example('assignment can swap existing variables', [[
    local a,b=1,2
    {.a,.b}={b,a}
    t.equal(a,2); t.equal(b,1)
  ]])
  example('strict match evaluates the input once', [[
    local calls=0; local function input() calls=calls+1; return {a=3,b=4} end
    local {a,b}=input()
    t.equal(calls,1); t.equal(a+b,7)
  ]])
  example('local pin sees the outer name before shadowing', [[
    local value=7
    do local {value,.^value}={value=9,7}; t.equal(value,9) end
    t.equal(value,7)
  ]])
  example('mixed parameter patterns preserve untouched arguments', [[
    local function decode({value}=original,@b{'P',kind<u8>}=packet,suffix)
      return original,value,packet,kind,suffix
    end
    local original={value=3}; local packet='P'..string.char(7)
    t.results(t.pack(original,3,packet,7,'end'),function() return decode(original,packet,'end') end)
  ]])
  example('parameter pins reference an earlier parameter', [[
    local function decode(expected,{value=^expected,payload}) return payload end
    t.equal(decode(7,{value=7,payload='ok'}),'ok')
    t.raises(function() decode(8,{value=7}) end,'value')
  ]])
  example('method patterns preserve self and named varargs', [[
    local object={tag='self'}
    function object:decode({value},...args) return self.tag,value,args.n,args[1],args[2] end
    t.results(t.pack('self',4,2,nil,8),function() return object:decode({value=4},nil,8) end)
  ]])
end)

test.describe('extended case expressions', function()
  example('subject executes once and a pure guard selects the clause', [[
    local reads=0
    local function input() reads=reads+1; return {value=7} end
    local function guard(n) return n==7 end
    local result=case input() do
      when {value} if guard(value) then value
      when _ then 0
    end
    t.equal(result,7); t.equal(reads,1)
  ]])
  example('false guards fall through without leaking captures', [[
    local value='outer'
    local result=case {value=7} do when {value} if false then value when _ then value end
    t.equal(result,'outer'); t.equal(value,'outer')
  ]])
  example('case result preserves false and nil', [[
    local a=case 1 do when 1 then false else true end
    local b=case 2 do when 1 then 7 else nil end
    t.equal(a,false); t.equal(b,nil)
  ]])
  example('case in arithmetic preserves the left operand', [[
    local result=10+(case 2 do when 2 then 7 else 0 end)
    t.equal(result,17)
  ]])
  example('case in call preserves preceding arguments', [[
    local function collect(...) return ... end
    t.results(t.pack('first',7,'last'),function()
      return collect('first',case 2 do when 2 then 7 else 0 end,'last')
    end)
  ]])
  example('case in a table constructor preserves previous fields', [[
    local values={'first',(case 2 do when 2 then 7 else 0 end),'last'}
    t.deep_equal(values,{'first',7,'last'})
  ]])
  example('case in multiple assignment preserves previous results', [[
    local a,b,c='first',case 2 do when 2 then 7 else 0 end,'last'
    t.equal(a,'first'); t.equal(b,7); t.equal(c,'last')
  ]])
  example('nested case expressions select the inner result', [[
    local result=case 1 do when 1 then case 2 do when 2 then 7 else 0 end else -1 end
    t.equal(result,7)
  ]])
  example('scalar pins use raw equality', [[
    local count=0; local mt={__eq=function() count=count+1; return true end}
    local expected=setmetatable({},mt); local actual=setmetatable({},mt)
    local result=case actual do when ^expected then 'bad' else 'ok' end
    t.equal(result,'ok'); t.equal(count,0)
  ]])
  example('escaping closures retain each clause binding', [[
    local callbacks={}
    for i=1,3 do
      case {value=i} do when {value} then callbacks[i]=function() return value end end
    end
    t.equal(callbacks[1](),1); t.equal(callbacks[2](),2); t.equal(callbacks[3](),3)
  ]])
  example('case stays contextual for ordinary identifiers', [[
    local case=function(x) return x+1 end
    local when,catch,try=2,3,4
    t.equal(case(when)+catch+try,10)
  ]])
end)

test.describe('extended try statements', function()
  example('return without values leaves the enclosing function', [[
    local function f() try do return catch e then error(e) end; return 'bad' end
    t.results(t.pack(),f)
  ]])
  example('nested try return reaches the enclosing function', [[
    local function f()
      try do
        try do return 'ok',nil,3 catch e then error(e) end
      catch e then error(e) end
      return 'fell through'
    end
    t.results(t.pack('ok',nil,3),f)
  ]])
  example('nested try zero-result return reaches the enclosing function', [[
    local function f()
      try do try do return catch e then error(e) end catch e then error(e) end
      return 'fell through'
    end
    t.results(t.pack(),f)
  ]])
  example('return from an inner catch reaches the enclosing function', [[
    local function f()
      try do try do error('x',0) catch e then return 'caught',e end catch e then error(e) end
      return 'fell through'
    end
    t.results(t.pack('caught','x'),f)
  ]])
  example('normal nested try resumes the outer body', [[
    local value=0
    try do try do value=value+1 catch e then error(e) end; value=value+2 catch e then error(e) end
    t.equal(value,3)
  ]])
  example('return from a nested function stays local to it', [[
    local function f()
      try do
        local function g() return 7 end
        t.equal(g(),7)
      catch e then error(e) end
      return 'outer'
    end
    t.equal(f(),'outer')
  ]])
  example('unmatched errors retain table identity', [[
    local expected={reason='x'}
    local ok,actual=pcall(function() try do error(expected) catch 'no' then end end)
    t.equal(ok,false); t.raw_equal(actual,expected)
  ]])
  example('catch pins use raw equality', [[
    local count=0; local mt={__eq=function() count=count+1; return true end}
    local expected=setmetatable({},mt); local actual=setmetatable({},mt)
    local ok,err=pcall(function() try do error(actual) catch ^expected then return 'bad' end end)
    t.equal(ok,false); t.raw_equal(err,actual); t.equal(count,0)
  ]])
  example('nil and false error objects reach catches', [[
    local count=0
    try do error(nil) catch nil then count=count+1 end
    try do error(false) catch false then count=count+1 end
    t.equal(count,2)
  ]])
  example('catch errors propagate to an outer catch', [[
    local result
    try do try do error('first',0) catch e then error('second',0) end
    catch e then result=e end
    t.equal(result,'second')
  ]])
  example('return closes captured locals with their current values', [[
    local function f()
      try do local n=7; return function() return n end catch e then error(e) end
    end
    local read=f(); t.equal(read(),7)
  ]])
end)

test.describe('extended named varargs', function()
  example('empty and trailing nil packs preserve counts', [[
    local function f(...args) return args.n,#args,select('#',...args),... end
    t.results(t.pack(0,0,0),f)
    t.results(t.pack(3,3,3,1,nil,nil),function() return f(1,nil,nil) end)
  ]])
  example('method spread preserves self and prefix arguments', [[
    local object={tag='self'}
    function object:accept(...) return self.tag,... end
    local function f(...args) return object:accept('prefix',...args) end
    t.results(t.pack('self','prefix',1,nil,3),function() return f(1,nil,3) end)
  ]])
  example('named pack is independent of raw varargs', [[
    local function f(...args) args[1]=9; return args[1],... end
    t.results(t.pack(9,1,2),function() return f(1,2) end)
  ]])
  example('pack can be captured and spread by a closure', [[
    local function f(...args) return function() return select('#',...args) end end
    t.equal(f(nil,2,nil)(),3)
  ]])
  example('try can return a named spread', [[
    local function f(...args) try do return 'prefix',...args catch e then error(e) end end
    t.results(t.pack('prefix',1,nil,3),function() return f(1,nil,3) end)
  ]])
  example('spread uses the declared n field', [[
    local args={1,2,3,n=2}
    t.results(t.pack(1,2),function() return (function(...) return ... end)(...args) end)
  ]])
end)

test.describe('extended binary patterns', function()
  example('byte segments may be empty and contain zero bytes', [[
    local payload='a\0b'
    local packet=@b{'P',payload<bytes(3)>,''}
    local @b{'P',zero<bytes(0)>,body<bytes(3)>,rest<bytes>}=packet
    t.equal(zero,''); t.equal(body,payload); t.equal(rest,'')
  ]])
  example('strict binary matching rejects short or trailing input', [[
    local function f(packet) local @b{'P',kind<u8>}=packet; return kind end
    t.raises(function() f('P') end,'byte 1')
    t.raises(function() f('P\1extra') end,'byte 2')
    t.equal(f('P\7'),7)
  ]])
  example('binary clause mismatch falls through after partial captures', [[
    local result=case 'P\1bad' do
      when @b{'P',kind<u8>,'good'} then kind
      when @b{'P',kind<u8>,body<bytes>} then body
      else 'no'
    end
    t.equal(result,'bad')
  ]])
  example('byte pins and numeric pins compare expected values', [[
    local magic='P'; local kind=7; local body='abc'
    local @b{^magic,^kind<u8>,^body<bytes(3)>}='P\7abc'
    local result=case 'P\8abc' do when @b{^magic,^kind<u8>,_<bytes>} then false else true end
    t.equal(result,true)
  ]])
  example('zero-length vectors preserve the next segment', [[
    local values={}
    local data=@b{values<u16[0]>,9<u8>}
    local @b{decoded<u16[0]>,tail<u8>}=data
    t.deep_equal(decoded,{}); t.equal(tail,9)
  ]])
  example('vectors reject missing entries', [[
    local values={1,nil,3}
    t.raises(function() return @b{values<u16[3]>} end,'missing element')
  ]])
  example('binary assignment preserves old values on mismatch', [[
    local a,b=10,20
    t.raises(function() @b{a<u8>,b<u8>,'Z'}='\1\2Y' end,'byte 2')
    t.equal(a,10); t.equal(b,20)
  ]])
  example('nested binary construction preserves the outer prefix', [[
    local data=@b{'A',(@b{7<u8>})<bytes>,'Z'}
    t.equal(data,'A\7Z')
  ]])
  example('nested binary construction preserves differently typed outer fields', [[
    local data=@b{258<u16>,(@b{7<u8>})<bytes>,9<u8>}
    t.equal(data,'\1\2\7\9')
  ]])
  example('binary construction can consume a case expression', [[
    local data=@b{'A',(case {value=7} do when {value} then value else 0 end)<u8>,'Z'}
    t.equal(data,'A\7Z')
  ]])
  example('binary construction evaluates fields once in order', [[
    local count=0; local function nextvalue() count=count+1; return count end
    local data=@b{nextvalue()<u8>,nextvalue()<u16>}
    t.equal(data,'\1\0\2'); t.equal(count,2)
  ]])
end)

test.describe('pattern bytecode round trips', function()
  example('dump and reload table and binary patterns', [[
    local function source(input,packet)
      local {value,...tail}=input
      local @b{'P',kind<u8>}=packet
      return value,tail.keep,kind
    end
    local copy=assert(loadstring(string.dump(source)))
    t.results(t.pack(3,4,7),function() return copy({value=3,keep=4},'P\7') end)
  ]])
  example('dump and reload named varargs and try', [[
    local function source(...args) try do return select('#',...args) catch e then error(e) end end
    local copy=assert(loadstring(string.dump(source)))
    t.equal(copy(1,nil,3),3)
  ]])
end)
