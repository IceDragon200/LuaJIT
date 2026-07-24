local test = require("test.ljtest")
local has_regexp, regexp = pcall(require, "regexp")

if not has_regexp then
  test.xtest("regexp module requires a PCRE2 build", function() end)
  return
end

test.describe("regexp module", function()
  test.it("finds captures through PCRE2", function(t)
    local pattern = assert(regexp.compile("^(?<kind>[a-z]+)-(\\d+)$", "i"))
    t.results(t.pack(1, 6, "Abc", "42"), function()
      return pattern:find("Abc-42")
    end)
    t.equal(regexp.escape("a+b"), "a\\+b")
  end)
end)
