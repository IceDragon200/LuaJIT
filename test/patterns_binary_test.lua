local test = require("test.ljtest")

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

test.describe("binary patterns regression", function ()
  test.it("supports variable length constructor form", function (t)
    local result = t.assert(loadstring([[
    local x = "hello"
    local y = "universe"
    return @b{x <bytes>, " glorious ", y <bytes>}
    ]]))

    t.eq(result(), "hello glorious universe")
  end)
end)
