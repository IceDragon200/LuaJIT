local test = require('test.ljtest')

test.describe('pattern stack and collection', function()
  for _,kind in ipairs({'table','binary'}) do
    test.it('collects discarded '..kind..' captures after failed clauses', function(t)
      local source=kind=='table' and [[
        return function(subject)
          for i=1,3000 do
            case subject do
            when {branch={...capture},kind='ok'} then return false
            else end
          end
          return true
        end
      ]] or [[
        return function(subject)
          for i=1,3000 do
            case subject do
            when @b{capture<u8[16]>,'ok'} then return false
            else end
          end
          return true
        end
      ]]
      local fn=assert(loadstring(source))()
      local subject=kind=='table' and {branch={a=1,b=2,c=3,d=4},kind='no'} or
        string.rep('X',16)..'no'
      local pause=collectgarbage('setpause',100)
      local step=collectgarbage('setstepmul',4000)
      collectgarbage('collect')
      local witness=setmetatable({{}},{__mode='v'})
      local ok,result=pcall(fn,subject)
      collectgarbage('setpause',pause)
      collectgarbage('setstepmul',step)
      t.equal(ok,true); t.equal(result,true)
      t.equal(witness[1],nil,'failed matches must advance collection')
    end)
  end

  test.it('bounds recursive source patterns with the normal syntax limit', function(t)
    local source='local '..string.rep('{child=',220)..'{}'..string.rep('}',220)..'={}'
    local fn,err=loadstring(source)
    t.equal(fn,nil)
    t.assert(err:find('syntax levels',1,true) ~= nil,err)
    t.equal(assert(loadstring('return 7'))(),7)
  end)

  test.it('bounds recursive legacy helper descriptors', function(t)
    -- A chain of optional child keys, followed by one END for every node.
    local descriptor=string.rep(string.char(4,0,0,0,0,0),201)..string.rep('\0',202)
    t.raises(function() __try_table_match({},descriptor) end,'nesting too deep')
    t.raises(function() __table_match({},descriptor) end,'nesting too deep')
  end)

  test.it('matches nested present and absent tables through collection', function(t)
    local depth=40
    local source='return function(input) local '..string.rep('{child=',depth)..
      '{value,...rest}'..string.rep('}',depth)..'=input; return value,rest end'
    local fn=assert(loadstring(source))()
    local input={value=7,keep={key='retained'}}
    for i=1,depth do input={child=input} end
    for i=1,100 do
      collectgarbage('step',1)
      local value,rest=fn(input)
      t.equal(value,7); t.equal(rest.keep.key,'retained')
      t.results(t.pack(nil,nil),function() return fn({}) end)
    end
  end)

  test.it('preserves large vararg and protected-return tuples with nil holes', function(t)
    local fn=assert(loadstring([[
      return function(...args)
        try do return ...args catch problem then return problem end
      end
    ]]))()
    local input={}; for i=1,600 do if i%7~=0 then input[i]=i end end
    for i=1,10 do
      local output=test.pack(fn(unpack(input,1,602)))
      t.equal(output.n,602)
      for j=1,602 do t.equal(output[j],input[j]) end
      collectgarbage('collect')
    end
  end)
end)
