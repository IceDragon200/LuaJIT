-- Independent behavioral coverage for capture names and dependent byte lengths.
local test = require('test.ljtest')

local function example(name, source)
  test.it(name, function(t)
    local factory,err=loadstring('return function(t) '..source..' end', '='..name)
    t.assert(factory ~= nil,err)
    local fn=factory()
    for i=1,80 do fn(t) end
  end)
end

test.describe('dependent binary lengths', function()
  example('reads a payload length and trailing bytes', [[
    local @b{length<u16>,payload<bytes(length)>,rest<bytes>}='\0\3abcXYZ'
    t.equal(length,3); t.equal(payload,'abc'); t.equal(rest,'XYZ')
  ]])
  example('supports zero and several independent lengths', [[
    local @b{a<u8>,first<bytes(a)>,b<le_u16>,second<bytes(b)>,last<u8>}='\0\2\0ok\9'
    t.equal(a,0); t.equal(first,''); t.equal(b,2); t.equal(second,'ok'); t.equal(last,9)
  ]])
  example('counts captures rather than descriptor fields', [[
    local @b{'P',_<u8>,1<u8>,head<bytes(1)>,items<u8[2]>,n<u8>,body<bytes(n)>}=
      'P\9\1H\5\6\2ok'
    t.equal(head,'H'); t.deep_equal(items,{5,6}); t.equal(n,2); t.equal(body,'ok')
  ]])
  example('uses the captured length rather than an outer binding', [[
    local n=99
    do local @b{n<u8>,body<bytes(n)>}='\2ok'; t.equal(n,2); t.equal(body,'ok') end
    t.equal(n,99)
  ]])
  example('supports skipped and pinned dependent fields', [[
    local expected='ok'
    local @b{n<u8>,_<bytes(n)>,^expected<bytes(n)>,tail<bytes>}='\2XXok!'
    t.equal(n,2); t.equal(tail,'!')
    t.raises(function() local @b{n<u8>,^expected<bytes(n)>}='\2no' end,'binary pattern')
  ]])
  example('supports assignments and deferred parameter patterns', [[
    local n,body=99,'old'
    @b{n<u8>,body<bytes(n)>}='\2ok'
    t.equal(n,2); t.equal(body,'ok')
    local function decode(@b{n<u8>,body<bytes(n)>}=original)
      return n,body,original
    end
    t.results(t.pack(2,'ok','\2ok'),function() return decode('\2ok') end)
  ]])
  example('supports global and upvalue assignment targets', [[
    local n,body=0,''
    local function assign() @b{n<u8>,body<bytes(n)>}='\2ok' end
    assign(); t.equal(n,2); t.equal(body,'ok')
    local fn=assert(loadstring("@b{n<u8>,body<bytes(n)>}='\\2ok'"))
    local env={}; setfenv(fn,env); fn(); t.equal(env.n,2); t.equal(env.body,'ok')
  ]])
  example('supports cases guards and binary catches', [[
    local result=case '\2ok' do
      when @b{n<u8>,body<bytes(n)>} if n==2 then body
      else 'bad'
    end
    t.equal(result,'ok')
    local caught
    try do error('\2ok',0)
    catch @b{n<u8>,body<bytes(n)>} then caught=body end
    t.equal(caught,'ok')
  ]])
  example('treats truncated negative and very large lengths as mismatches', [[
    for _,packet in ipairs({'\3ab','\255','\127'}) do
      local result=case packet do when @b{n<s8>,body<bytes(n)>} then 'bad' else 'ok' end
      t.equal(result,'ok')
      t.raises(function() local @b{n<s8>,body<bytes(n)>}=packet end,'binary pattern')
    end
    local huge='\255\255\255\255\255\255'
    local result=case huge do when @b{n<u48>,body<bytes(n)>} then 'bad' else 'ok' end
    t.equal(result,'ok')
  ]])
  example('preserves assignment targets after a mismatch', [[
    local n,body=99,'old'
    t.raises(function() @b{n<u8>,body<bytes(n)>}='\3ab' end,'binary pattern')
    t.equal(n,99); t.equal(body,'old')
  ]])
  example('survives stripped bytecode round trips', [[
    local function decode(packet)
      local @b{n<u8>,body<bytes(n)>}=packet
      return n,body
    end
    local copy=assert(loadstring(string.dump(decode,'sd')))
    setfenv(copy,{})
    t.results(t.pack(2,'ok'),function() return copy('\2ok') end)
  ]])
  test.it('rejects unavailable and noninteger length bindings', function(t)
    local sources={
      'local @b{body<bytes(n)>,n<u8>}=packet',
      'local @b{n<bytes(n)>}=packet',
      'local n=2; local @b{body<bytes(n)>}=packet',
      'local @b{n<f32>,body<bytes(n)>}=packet',
      'local @b{n<u8[1]>,body<bytes(n)>}=packet',
      'local @b{n<bytes(1)>,body<bytes(n)>}=packet',
      'return @b{payload<bytes(n)>}',
    }
    for _,source in ipairs(sources) do
      local fn,err=loadstring(source)
      t.equal(fn,nil); t.assert(err:find('earlier integer capture',1,true) ~= nil,err)
    end
  end)
end)

test.describe('unique pattern bindings', function()
  test.it('rejects duplicate names in every pattern context', function(t)
    local sources={
      'local {x,x}=input', 'local {.x,.x}=input',
      'local {x,nested={x}}=input', 'local {x,...x}=input',
      'local @b{x<u8>,x<u8>}=input',
      'local x; {x,x}=input', '{x,x}=input',
      'local x; return function() {x,x}=input end',
      'return function({x,x}) end', 'return function({x}=x) end',
      'return function(@b{x<u8>,x<u8>}) end',
      'return case input do when {x,x} then x end',
      'try do work() catch {x,x} then end',
    }
    for _,source in ipairs(sources) do
      local fn,err=loadstring(source)
      t.equal(fn,nil); t.assert(err:find("duplicate pattern binding 'x'",1,true) ~= nil,err)
    end
  end)
  example('permits repeated wildcards and names in separate patterns', [[
    local {_,_,._,._}={1,2}
    local @b{_<u8>,_<u8>}='\1\2'
    local {x}={x=1}
    do local {x}={x=2}; t.equal(x,2) end
    t.equal(x,1)
    local x,x=3,4; t.equal(x,4)
  ]])
  example('preserves pins that refer to outer bindings', [[
    local x=7
    local {x,.^x}={x=9,7}; t.equal(x,9)
    local n=2
    do local @b{n<u8>,^n<u8>,body<bytes(n)>}='\1\2X'
      t.equal(n,1); t.equal(body,'X')
    end
    t.equal(n,2)
  ]])
end)

test.describe('capture stack growth', function()
  test.it('keeps later lengths and pins valid after many captures', function(t)
    local fields,tablefields={},{}
    for i=1,100 do
      fields[#fields+1]='v'..i..'<bytes(1)>'
      tablefields[#tablefields+1]='.v'..i
    end
    fields[#fields+1]='n<u8>'; fields[#fields+1]='body<bytes(n)>'
    fields[#fields+1]='^expected<bytes(n)>'
    tablefields[#tablefields+1]='.^expected'
    local pattern='@b{'..table.concat(fields,',')..'}'
    local input=string.rep('X',100)..'\2okok'
    for _,case in ipairs({false,true}) do
      local body=case and ('return case input do when '..pattern..' then body else false end') or
        ('local '..pattern..'=input; return body')
      local fn=assert(loadstring('return function(input,expected) '..body..' end'))()
      t.equal(fn(input,'ok'),'ok')
    end
    local source='return function(input,expected) local {'..table.concat(tablefields,',')..
      '}=input; return v1,v100 end'
    local fn=assert(loadstring(source))()
    local input={}; for i=1,100 do input[i]=i end; input[101]='ok'
    t.results(t.pack(1,100),function() return fn(input,'ok') end)
  end)
end)
