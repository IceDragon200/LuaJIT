# API source annotations

This fork documents its public Lua APIs next to their implementation. It uses
the common Luadoc/LDoc tag vocabulary now, without adding a documentation
generator or build dependency. The existing HTML pages remain the place for
longer explanations, design rationale, and worked examples.

Lua source can use LDoc's normal `---` comments. Native C libraries use an
ordinary `/*** ... */` block immediately before the Lua-facing entry point.
Those C blocks intentionally have the same fields and prose structure, but
are not claimed to be directly consumable by LDoc. If this project later adds
a generator, it can either read these blocks directly or translate them to
Lua stubs without rewriting the API documentation.

## Required shape

Every public module has one module block near its `LJLIB_MODULE_*` declaration.
Every public function has one block immediately before its `LJLIB_CF(...)`
entry point (or before the static C function registered in a Lua table).

Use the tags shared by Luadoc and LDoc:

- `@module` for the Lua module name.
- `@function` for a public dotted name, such as `binary.match`.
- `@param` for each Lua argument, in call order. Include optionality and the
  Lua-level value shape, not C implementation types.
- `@return` for every returned value, including `nil, message`, an empty
  result list, or a variable number of values where relevant.
- `@usage` for a short, runnable example when it clarifies a non-obvious API.
- `@see` for a related public API or the extension's HTML page.

Put errors, indexing conventions, mutations, dependency requirements, and
security boundaries in the descriptive prose. Keep the comments focused on
the Lua contract: `GCstr *`, stack slots, and temporary buffers belong in
ordinary implementation comments instead.

```c
/***
Find the first literal byte pattern in a string.
Offsets and lengths are zero-based.
@function binary.match
@param data byte string to search
@param pattern non-empty string, list of strings, or compiled pattern
@param[opt] options table with optional `start` and `length` byte bounds
@return offset, length for the first match; no results when no match exists
@usage local offset, length = binary.match("GET /", " ")
*/
LJLIB_CF(binary_match)
```

```lua
--- Find the first literal byte pattern in a string.
-- @function M.match
-- @param data byte string to search
-- @param pattern non-empty literal byte string
-- @return zero-based offset and byte length, or no values when absent
function M.match(data, pattern)
  -- ...
end
```

## Review rule

Changing a public function's name, arguments, return shape, error result, or
meaning requires updating its source annotation and the matching HTML page in
the same change. Internal helpers need ordinary C comments only. New APIs
should be annotated before tests are added, so tests, implementation, and the
public contract are easy to review together.
