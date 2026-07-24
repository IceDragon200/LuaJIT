# LuaJIT Test Framework

`ljtest` is the small, self-hosted test framework used by this fork. Test
files declare suites and examples; `test/run.lua` loads them, runs them, and
owns reporting and the exit status. It deliberately has no object system and
no external Lua dependencies.

Run the complete suite from the repository root:

```sh
make test
```

The Makefile discovers every `test/*_test.lua` file. Module tests are kept in
one file per module, so an optional dependency can be tested or skipped without
obscuring the rest of the suite. Run selected files or tests directly when
iterating on a change:

```sh
src/luajit test/run.lua test/patterns_test.lua
src/luajit test/run.lua --filter binary --trace test/*_test.lua
src/luajit test/run.lua --seed 42 test/*_test.lua
```

`--filter` is a case-insensitive plain substring match against the full test
name. `--list` lists the matching tests without executing them; `--fail-fast`
stops at the first failure. `--seed` shuffles entries inside every suite while
retaining suite setup/teardown ordering.

## Writing a test

```lua
local test = require("test.ljtest")

test.describe("decoder", function()
  test.before_each(function(t, context)
    -- Hooks receive the assertion module and test metadata.
  end)

  test.it("preserves nil return values", function(t)
    t.results(t.pack("ok", nil, 3), function()
      return "ok", nil, 3
    end)
  end)
end)
```

The core assertions are `assert`/`ok`, `refute`, `equal`/`eq`,
`not_equal`/`ne`, `raw_equal`, `deep_equal`, `matches`, `in_range`, `near`,
`raises`, and `results`. Assertion arguments use `actual, expected` order.
`matches` is a partial structural table match. `results` requires `test.pack`
so return counts and `nil` holes are never lost.

Use `describe` and `test` (or its `it` alias) for registration. `xdescribe`
and `xtest`/`xit` keep intentional skips visible in the final result.

## Upstream baseline coverage

The `baseline_*_test.lua` modules translate behavioral coverage from Lua's
upstream `testes/` suite into `ljtest` examples. They cover language syntax,
functions and closures, tables, metamethods, coroutines, errors, core
libraries, bytecode loading, environments, and basic collection. They test the
LuaJIT language baseline and its supported standard-library behavior; they do
not assert Lua-5.5-only syntax or runtime internals. Each module names its
upstream source areas in a header comment, so individual cases can be extended
from the corresponding upstream tests without importing their procedural
harness.

`modern_syntax_test.lua` and `bytecode_test.lua` cover LuaJIT-specific recent
syntax and bytecode guarantees. They intentionally compile extension examples
with `loadstring`, which makes parser regressions show up as ordinary test
failures and lets bytecode round trips exercise the same compiled forms.
