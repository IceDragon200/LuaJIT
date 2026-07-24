# Test provenance and third-party notices

This file records the provenance of test material adapted into this fork. It
does not replace LuaJIT's upstream [COPYRIGHT](../COPYRIGHT) notice.

## LuaJIT-test-cleanup regression corpus

`cleanup_luajit_regressions_test.lua` and
`cleanup_luajit_runtime_test.lua` and
`cleanup_luajit_metamethods_test.lua`, `cleanup_luajit_coroutines_test.lua`,
`cleanup_luajit_errors_test.lua`, and `cleanup_luajit_libraries_test.lua`
adapt the following source cases from the initial commit
(`a273241fe6386718cc741c852f783ad5a0138e2b`, 2016-01-31) of
[LuaJIT/LuaJIT-test-cleanup](https://github.com/LuaJIT/LuaJIT-test-cleanup):

- `test/misc/meta_len.lua`
- `test/misc/constov.lua`
- `test/misc/exit_growstack.lua`
- `test/misc/exit_jfuncf.lua`
- `test/misc/parse_esc.lua`
- `test/misc/parse_misc.lua`
- `test/misc/parse_comp.lua`
- `test/misc/fori_coerce.lua`
- `test/misc/vararg_jit.lua`
- `test/misc/tcall_base.lua`
- `test/misc/tcall_loop.lua`
- `test/misc/recurse_deep.lua`
- `test/misc/recurse_tail.lua`
- `test/misc/stack_gc.lua`
- `test/misc/gcstep.lua`
- `test/misc/gc_rechain.lua`
- `test/misc/wbarrier.lua`
- `test/misc/wbarrier_jit.lua`
- `test/misc/meta_call.lua`
- `test/misc/meta_cat.lua`
- `test/misc/meta_comp.lua`
- `test/misc/meta_eq.lua`
- `test/misc/meta_framegap.lua`
- `test/misc/meta_getset.lua`
- `test/misc/meta_nomm.lua`
- `test/misc/meta_tget.lua`
- `test/misc/meta_tset_nilget.lua`
- `test/misc/meta_tset_str.lua`
- `test/misc/meta_eq_jit.lua`
- `test/misc/coro_traceback.lua`
- `test/misc/coro_yield.lua`
- `test/misc/pcall_jit.lua`
- `test/misc/xpcall_jit.lua`
- `test/misc/bit_op.lua`
- `test/misc/string_byte.lua`
- `test/misc/string_char.lua`
- `test/misc/string_dump.lua`
- `test/misc/string_op.lua`
- `test/misc/string_sub_opt.lua`
- `test/misc/table_insert.lua`
- `test/misc/table_misc.lua`
- `test/misc/table_remove.lua`
- `test/misc/select.lua`
- `test/lang/andor.lua`
- `test/lang/assignment.lua`
- `test/lang/compare.lua`
- `test/lang/compare_nan.lua`
- `test/lang/concat.lua`
- `test/lang/constant/number.lua`
- `test/lang/constant/table.lua`
- `test/lang/for.lua`
- `test/lang/gc.lua`
- `test/lang/length.lua`
- `test/lang/modulo.lua`
- `test/lang/self.lua`
- `test/lang/table.lua`
- `test/lang/upvalue/closure.lua`
- `test/misc/dualnum.lua`
- `test/misc/phi_conv.lua`
- `test/lib/base/getfenv.lua`
- `test/lib/base/assert.lua`
- `test/lib/base/error.lua`
- `test/lib/base/getsetmetatable.lua`
- `test/lib/base/ipairs.lua`
- `test/lib/base/next.lua`
- `test/lib/base/tonumber_tostring.lua`
- `test/lib/coroutine/yield.lua`
- `test/lib/math/abs.lua`
- `test/lib/math/constants.lua`
- `test/lib/math/random.lua`
- `test/lib/string/format/num.lua`
- `test/lib/string/metatable.lua`
- `test/lib/table/sort.lua`

That commit is authored by Mike Pall. The repository's root README states that
Lua/LuaJIT tests and benchmarks written by Mike Pall are placed in the public
domain. The cases above are therefore imported under that declaration, with
their source paths and commit retained here and in the adapted test header.

The upstream workspace also contains work by other contributors. It is not
copied into this fork unless its authorship and license are individually clear.
When a test is independently re-authored from an upstream behavioural idea,
the new test must say so in its header and name the original source path.

### Deliberate scope boundary

The default suite adopts the public-domain, self-contained core-language and
standard-library cases that apply to this LuaJIT configuration. It deliberately
leaves `test/lib/ffi/`, `test/sysdep/`, `test/unportable/`, C/C++ helper cases,
debug-hook stress tests, and optimizer-code-generation probes for separately
maintained, capability-gated suites. `test/lib/table/pack.lua` is also omitted:
it requires Lua-5.2 compatibility (`table.pack`/`table.unpack`), which this
stock LuaJIT-2.1 configuration does not expose. These are scope decisions, not
claims about the license status of the remaining upstream files.

## Attribution practice for experimental features

Experimental feature files name external designs that informed their API or
semantics. Inspiration is not a claim that upstream implementation code was
copied. See [CREDITS.md](../CREDITS.md) for the current feature-level record.
