local test = require("test.ljtest")
local utf8 = require("utf8")

test.describe("utf8 module", function()
  test.it("encodes, measures, and iterates codepoints", function(t)
    local value = utf8.char(0x1f980, 0x20, 0x4c, 0x75, 0x61)
    t.equal(utf8.len(value), 5)
    t.results(t.pack(0x1f980, 0x20), function()
      return utf8.codepoint(value, 1, 5)
    end)
    local positions = {}
    for position, codepoint in utf8.codes(value) do
      positions[#positions + 1] = { position, codepoint }
    end
    t.deep_equal(positions, {
      { 1, 0x1f980 }, { 5, 0x20 }, { 6, 0x4c }, { 7, 0x75 }, { 8, 0x61 },
    })
  end)
end)
