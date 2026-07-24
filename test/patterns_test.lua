local test = require("test.ljtest")

test.describe("table patterns", function()
  test.it("captures named and positional fields", function(t)
    local {kind, payload, .first, .second} = {
      kind = "send", payload = "hello", 11, 29,
    }
    t.equal(kind, "send")
    t.equal(payload, "hello")
    t.equal(first, 11)
    t.equal(second, 29)
  end)

  test.it("handles nested literals, required fields, and rest capture", function(t)
    local {header = {kind = "send", flags}!, ...rest} = {
      header = { kind = "send", flags = 3 }, payload = "body", trace = 9,
    }
    t.equal(flags, 3)
    t.deep_equal(rest, { payload = "body", trace = 9 })
  end)

  test.it("pins existing values", function(t)
    local expected_kind = "send"
    local expected_first = 42
    local {kind = ^expected_kind, .^expected_first} = { kind = "send", 42 }
    t.assert(true)
  end)

  test.it("reports strict scalar mismatches", function(t)
    t.raises(function()
      local actual = 11
      12 = actual
    end, "value pattern match failed")
  end)

  test.it("keeps the original parameter alongside captures", function(t)
    local function decode({header = {kind = "send", flags}!} = packet)
      return packet, flags
    end
    local input = { header = { kind = "send", flags = 5 } }
    t.results(t.pack(input, 5), function()
      return decode(input)
    end)
  end)
end)

test.describe("case", function()
  test.it("evaluates matching clauses in order", function(t)
    local message = { kind = "send", payload = "hello" }
    local result = case message do
      when {kind = "send", payload} if payload ~= "" then payload
      when {kind = "send"} then "empty"
      else "other"
    end
    t.equal(result, "hello")
  end)

  test.it("requires an explicit fallback", function(t)
    t.raises(function()
      local result = case "missing" do
        when "present" then "found"
      end
      return result
    end, "case clause did not match")
  end)
end)

test.describe("binary patterns", function()
  test.it("constructs and matches typed byte-aligned fields", function(t)
    local packet = @b{"P", 7 <u8>, 0x1234 <le_u16>}
    local @b{"P", kind <u8>, value <le_u16>} = packet
    t.equal(kind, 7)
    t.equal(value, 0x1234)
  end)

  test.it("matches typed literals", function(t)
    local packet = @b{0xCA <u8>, 0xFE <u8>}
    local @b{0xCA <u8>, 0xFE <u8>} = packet
    t.equal(#packet, 2)
  end)

  test.it("supports wide integers, floats, vectors, and byte rest capture", function(t)
    local vector = { 100, 200, 300 }
    local packet = @b{
      0x010203040506 <u48>,
      0x060504030201 <le_u48>,
      -128 <s16>,
      1.25 <f32>,
      vector <le_u16[3]>,
      "body"
    }
    local @b{
      big <u48>,
      little <le_u48>,
      negative <s16>,
      ratio <f32>,
      output <le_u16[3]>,
      rest <bytes>
    } = packet
    t.equal(big, 0x010203040506)
    t.equal(little, 0x060504030201)
    t.equal(negative, -128)
    t.near(ratio, 1.25, 0.00001)
    t.deep_equal(output, vector)
    t.equal(rest, "body")
  end)
end)

test.describe("named varargs", function()
  local function inspect(prefix, ...parts)
    return prefix, parts.n, #parts, parts[1], parts[2], parts[3]
  end

  local function collect(prefix, ...parts)
    return inspect(prefix, ...parts)
  end

  test.it("packs exact argument counts and nil holes", function(t)
    t.results(t.pack("P", 3, 3, 1, nil, 3), function()
      return collect("P", 1, nil, 3)
    end)
  end)

  test.it("keeps ordinary varargs available", function(t)
    local function count(...)
      return select("#", ...)
    end
    t.equal(count(1, nil, 3), 3)
  end)
end)

test.describe("table length metamethods", function()
  test.it("uses __len for ordinary tables", function(t)
    local value = setmetatable({}, { __len = function() return 9 end })
    t.equal(#value, 9)
  end)
end)
