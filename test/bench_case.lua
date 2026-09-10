-- Run before/after with the same interpreter flags, including a -joff run.
local iterations=tonumber(arg[1]) or 300000
local function scalar(n)
  local sum=0
  for i=1,n do
    sum=sum+case i%3 do when 0 then 7 when 1 then 11 else 13 end
  end
  return sum
end
local input={value=7}
local function table_case(n)
  local sum=0
  for i=1,n do
    sum=sum+case input do when {value} if value>0 then value else 0 end
  end
  return sum
end
for _,entry in ipairs({{'scalar',scalar},{'table',table_case}}) do
  local name,fn=entry[1],entry[2]
  fn(2000)
  local samples={}
  for round=1,5 do
    collectgarbage('collect')
    local start=os.clock()
    local value=fn(iterations)
    samples[round]=os.clock()-start
    local rem=iterations%3
    local expected=name=='table' and iterations*7 or
      math.floor(iterations/3)*31+(rem>=1 and 11 or 0)+(rem>=2 and 13 or 0)
    assert(value==expected)
  end
  table.sort(samples)
  collectgarbage('collect')
  collectgarbage('stop')
  local before=collectgarbage('count')
  fn(20000)
  local growth=collectgarbage('count')-before
  collectgarbage('restart')
  print(string.format('%s: median %.6f s / %d iterations; allocation %.1f KiB / 20000',
    name,samples[3],iterations,growth))
end
