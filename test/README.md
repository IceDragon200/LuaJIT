# LuaJIT Test Framework

`ljtest` is the small, self-hosted test framework used by this fork. Test
files declare suites and examples; `test/run.lua` loads them, runs them, and
owns reporting and the exit status. It deliberately has no object system and
no external Lua dependencies.

Run the complete suite from the repository root:

```sh
make test
```

The Makefile discovers every `test/*_test.lua` file and every POSIX-shell
`test/*_test.sh` integration test. Module tests are kept in one file per
module, so an optional dependency can be tested or skipped without obscuring
the rest of the suite. Run selected files or tests directly when iterating on a
change:

```sh
src/luajit test/run.lua test/patterns_test.lua
src/luajit test/run.lua --filter binary --trace test/*_test.lua
src/luajit test/run.lua --seed 42 test/*_test.lua
```

`test/repl_test.sh` is a small POSIX-shell integration test, also run by
`make test`. It drives `luajit -i` through standard input so that the frontend
itself—not merely the compiler—keeps accepting bare expressions, normal
statements, multiline input, multiple results, and LuaJIT's legacy `=` alias.
It also verifies the warning for top-level `local` declarations, whose scope
ends with that individual REPL submission.

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

`patterns_extended_test.lua` and `patterns_regressions_test.lua` cover nested
patterns, expression contexts, contextual identifiers, return propagation,
and bytecode round trips. Run them with both the default JIT setting and
`src/luajit -joff test/run.lua ...` when changing the parser or matchers.
`pattern_helpers_test.lua` checks independence from function environments,
private bindings in dumped functions, collection, and yieldable protected calls.
`pattern_bindings_test.lua` covers duplicate-name diagnostics, dependent binary
lengths, mismatch behavior, and stack growth with many captures and later pins.
`pattern_stack_test.lua` covers discarded captures, nesting limits, collection,
and large result tuples. `case_lowering_test.lua` checks direct case compilation,
pending declarations, live arguments, closures, varargs, yields, and debug names.
`pattern_combinations_test.lua` combines nested pure guards, clause fallthrough,
escaped captures, call arguments, short circuit operators, protected returns,
and yields. Small table and binary input matrices compare source and stripped
bytecode behavior against ordinary Lua reference implementations.

The standalone C API check uses an allocator that moves every reallocation and
fails each allocation in turn during compilation, helper creation, and matching.
It verifies memory-error recovery and releases all memory when closing the state.
Build and run it against a default-feature static build from the repository root:

```sh
cc -Isrc test/pattern_alloc.c src/libluajit.a -lm -o /tmp/luajit-pattern-alloc
/tmp/luajit-pattern-alloc
```

Use the same deployment target and additional link flags as the LuaJIT build
when required by the platform or optional libraries. Compare case-expression
timing and allocation with `src/luajit test/bench_case.lua`, also using `-joff`.
The benchmark reports median times over five runs and allocation with collection
temporarily stopped; it is a focused comparison, not an application benchmark.
`binary_numeric_test.lua` checks encoded bytes against independent Python
fixtures, including binary16 rounding boundaries. Its fixtures are checked
in; Python is only needed to regenerate them with
`python3 test/generate_numeric_tests.py` (Python 3.9 or newer).

## Capability gates and provenance

Suites and examples may accept an options table before their callback:

```lua
test.describe("JIT regressions", { requires = { jit = true } }, function()
  test.it("uses the FFI when available", { requires = { ffi = true } }, function(t)
    -- ...
  end)
end)
```

Known capabilities are `luajit` (optionally with a minimum numeric version),
`jit`, `ffi`, and `bit`. Available capabilities are enabled by default; a
missing requirement is reported as a skip rather than a failure. This keeps
the original feature-gating intent of adopted LuaJIT tests while making the
standard fork build run its JIT and FFI coverage out of the box.

When tests are adapted from another project, add a source/provenance header and
record the exact source path, commit, author, and license status in
`test/THIRD_PARTY_NOTICES.md`. Do not import a test merely because its behavior
is useful: unclear authorship or licensing means it must be excluded or
independently re-authored with explicit attribution.
