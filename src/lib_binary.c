/*
** Byte-oriented binary library.
** Local experimental extension.
** API direction informed by Erlang/OTP's binary module; independently written.
*/

#define lib_binary_c
#define LUA_LIB

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lj_obj.h"
#include "lj_gc.h"
#include "lj_buf.h"
#include "lj_str.h"
#include "lj_lib.h"

/* ------------------------------------------------------------------------ */


/***
Literal, byte-oriented operations on immutable Lua strings.
All offsets and lengths exposed by this module are zero-based byte counts.
@module binary
@usage local binary = require("binary")
@see doc/ext_binary.html
*/

#define BINARY_PATTERN_MT "binary.compiled_pattern"

typedef struct {
  int table;
  int count;
  int temporary;
  GCstr *single;
} BinaryPattern;

static MSize binary_check_bound(lua_State *L, int narg, MSize limit,
				const char *name)
{
  lua_Number value = luaL_checknumber(L, narg);

  if (value < 0 || value > (lua_Number)limit ||
      value != (lua_Number)(MSize)value)
    luaL_error(L, "%s must be a whole number between 0 and %d", name,
		(int)limit);
  return (MSize)value;
}

static void binary_check_pattern_table(lua_State *L, int table, int *count)
{
  size_t length = lua_objlen(L, table);
  size_t i;

  if (length == 0 || length > 0x7fffffffU)
    luaL_error(L, "pattern list must contain at least one string");
  for (i = 1; i <= length; i++) {
    size_t needle_len;
    lua_rawgeti(L, table, (int)i);
    if (lua_type(L, -1) != LUA_TSTRING) {
      lua_pop(L, 1);
      luaL_error(L, "pattern list element %d must be a string", (int)i);
    }
    (void)lua_tolstring(L, -1, &needle_len);
    lua_pop(L, 1);
    if (needle_len == 0)
      luaL_error(L, "empty binary patterns are not supported");
  }
  *count = (int)length;
}

static BinaryPattern binary_pattern_open(lua_State *L, int narg)
{
  BinaryPattern pattern;
  int type = lua_type(L, narg);

  pattern.table = 0;
  pattern.count = 0;
  pattern.temporary = 0;
  pattern.single = NULL;
  if (type == LUA_TSTRING) {
    pattern.single = lj_lib_checkstr(L, narg);
    if (pattern.single->len == 0)
      luaL_argerror(L, narg, "empty binary patterns are not supported");
    pattern.count = 1;
  } else if (type == LUA_TTABLE) {
    pattern.table = narg;
    binary_check_pattern_table(L, pattern.table, &pattern.count);
  } else if (type == LUA_TUSERDATA &&
		     luaL_testudata(L, narg, BINARY_PATTERN_MT)) {
    lua_getfenv(L, narg);
    if (!lua_istable(L, -1))
      luaL_error(L, "invalid compiled binary pattern");
    pattern.table = lua_gettop(L);
    pattern.temporary = 1;
    binary_check_pattern_table(L, pattern.table, &pattern.count);
  } else {
    luaL_argerror(L, narg, "string, pattern list, or compiled pattern expected");
  }
  return pattern;
}

static void binary_pattern_close(lua_State *L, BinaryPattern *pattern)
{
  if (pattern->temporary)
    lua_remove(L, pattern->table);
}

static int binary_pattern_at(lua_State *L, BinaryPattern *pattern,
			     const char *data, MSize offset,
			     MSize end, MSize *match_len)
{
  int i;

  for (i = 1; i <= pattern->count; i++) {
    const char *needle;
    MSize needle_len;

    if (pattern->single) {
      needle = strdata(pattern->single);
      needle_len = pattern->single->len;
    } else {
      size_t length;
      lua_rawgeti(L, pattern->table, i);
      needle = lua_tolstring(L, -1, &length);
      needle_len = (MSize)length;
    }
    if (needle_len <= end - offset &&
	memcmp(data + offset, needle, needle_len) == 0) {
      if (!pattern->single) lua_pop(L, 1);
      *match_len = needle_len;
      return 1;
    }
    if (!pattern->single) lua_pop(L, 1);
  }
  return 0;
}

static int binary_find(lua_State *L, BinaryPattern *pattern,
		       const char *data, MSize start, MSize length,
		       MSize *match_start, MSize *match_len)
{
  MSize offset;
  MSize end = start + length;

  for (offset = start; offset < end; offset++) {
    if (binary_pattern_at(L, pattern, data, offset, end, match_len)) {
      *match_start = offset;
      return 1;
    }
  }
  return 0;
}

static void binary_scope(lua_State *L, int narg, MSize size,
			 MSize *start, MSize *length)
{
  *start = 0;
  *length = size;
  if (lua_isnoneornil(L, narg)) return;
  luaL_checktype(L, narg, LUA_TTABLE);
  lua_getfield(L, narg, "start");
  if (!lua_isnil(L, -1))
    *start = binary_check_bound(L, -1, size, "options.start");
  lua_pop(L, 1);
  lua_getfield(L, narg, "length");
  if (!lua_isnil(L, -1))
    *length = binary_check_bound(L, -1, size - *start, "options.length");
  else
    *length = size - *start;
  lua_pop(L, 1);
}

static int binary_option(lua_State *L, int narg, const char *name)
{
  int value;

  if (lua_isnoneornil(L, narg)) return 0;
  luaL_checktype(L, narg, LUA_TTABLE);
  lua_getfield(L, narg, name);
  value = lua_toboolean(L, -1);
  lua_pop(L, 1);
  return value;
}

static void binary_push_slice(lua_State *L, const char *data,
			      MSize start, MSize length)
{
  setstrV(L, L->top++, lj_str_new(L, data + start, length));
}

static void binary_push_match(lua_State *L, MSize start, MSize length)
{
  lua_createtable(L, 2, 0);
  lua_pushnumber(L, (lua_Number)start);
  lua_rawseti(L, -2, 1);
  lua_pushnumber(L, (lua_Number)length);
  lua_rawseti(L, -2, 2);
}

static void binary_trim_result(lua_State *L, int table, int count,
			       int trim_all)
{
  int i;
  int write = 1;

  if (trim_all) {
    for (i = 1; i <= count; i++) {
      size_t length;
      lua_rawgeti(L, table, i);
      (void)lua_tolstring(L, -1, &length);
      if (length != 0) {
	if (write != i)
	  lua_rawseti(L, table, write);
	else
	  lua_pop(L, 1);
	write++;
      } else {
	lua_pop(L, 1);
      }
    }
    for (i = write; i <= count; i++) {
      lua_pushnil(L);
      lua_rawseti(L, table, i);
    }
  } else {
    while (count > 0) {
      size_t length;
      lua_rawgeti(L, table, count);
      (void)lua_tolstring(L, -1, &length);
      lua_pop(L, 1);
      if (length != 0) break;
      lua_pushnil(L);
      lua_rawseti(L, table, count);
      count--;
    }
  }
}

/* ------------------------------------------------------------------------ */

/***
Return the byte at a zero-based offset.
@function binary.at
@param data byte string to inspect
@param offset zero-based byte offset
@return byte integer from 0 through 255
*/
static int lj_cf_binary_at(lua_State *L)
{
  GCstr *input = lj_lib_checkstr(L, 1);
  MSize offset = binary_check_bound(L, 2, input->len, "offset");

  if (offset == input->len)
    return luaL_argerror(L, 2, "offset out of range");
  lua_pushnumber(L, (lua_Number)(uint8_t)strdata(input)[offset]);
  return 1;
}

/***
Return the first byte of a non-empty string.
@function binary.first
@param data non-empty byte string
@return byte integer from 0 through 255
*/
static int lj_cf_binary_first(lua_State *L)
{
  GCstr *input = lj_lib_checkstr(L, 1);

  if (input->len == 0) return luaL_argerror(L, 1, "empty binary");
  lua_pushnumber(L, (lua_Number)(uint8_t)strdata(input)[0]);
  return 1;
}

/***
Return the last byte of a non-empty string.
@function binary.last
@param data non-empty byte string
@return byte integer from 0 through 255
*/
static int lj_cf_binary_last(lua_State *L)
{
  GCstr *input = lj_lib_checkstr(L, 1);

  if (input->len == 0) return luaL_argerror(L, 1, "empty binary");
  lua_pushnumber(L, (lua_Number)(uint8_t)strdata(input)[input->len-1]);
  return 1;
}

/***
Return a strict zero-based byte slice.
@function binary.part
@param data byte string to slice
@param offset zero-based start offset
@param[opt] length number of bytes; omitting it selects through the end
@return string copied byte slice
*/
static int lj_cf_binary_part(lua_State *L)
{
  GCstr *input = lj_lib_checkstr(L, 1);
  MSize start = binary_check_bound(L, 2, input->len, "offset");
  MSize length = input->len - start;

  if (!lua_isnoneornil(L, 3))
    length = binary_check_bound(L, 3, input->len - start, "length");
  binary_push_slice(L, strdata(input), start, length);
  lj_gc_check(L);
  return 1;
}

/***
Create an opaque, reusable literal search pattern.
@function binary.compile_pattern
@param patterns non-empty string or sequence of non-empty strings
@return compiled pattern accepted by the search and replacement functions
*/
static int lj_cf_binary_compile_pattern(lua_State *L)
{
  int type = lua_type(L, 1);
  int count;
  int i;

  if (type == LUA_TSTRING) {
    if (lj_lib_checkstr(L, 1)->len == 0)
      return luaL_argerror(L, 1, "empty binary patterns are not supported");
    count = 1;
  } else if (type == LUA_TTABLE) {
    binary_check_pattern_table(L, 1, &count);
  } else {
    return luaL_argerror(L, 1, "string or pattern list expected");
  }
  (void)lua_newuserdata(L, 1);
  lua_createtable(L, count, 0);
  if (type == LUA_TSTRING) {
    lua_pushvalue(L, 1);
    lua_rawseti(L, -2, 1);
  } else {
    for (i = 1; i <= count; i++) {
      lua_rawgeti(L, 1, i);
      lua_rawseti(L, -2, i);
    }
  }
  lua_setfenv(L, -2);
  if (luaL_newmetatable(L, BINARY_PATTERN_MT)) {
    lua_pushliteral(L, "binary pattern");
    lua_setfield(L, -2, "__metatable");
  }
  lua_setmetatable(L, -2);
  return 1;
}

/***
Find the first literal byte pattern in a string.
When several patterns begin at the same offset, the first supplied pattern
wins. The optional bounds use zero-based byte offsets.
@function binary.match
@param data byte string to search
@param pattern non-empty string, pattern list, or compiled pattern
@param[opt] options table with optional `start` and `length` byte bounds
@return offset, length for the first match; no results when no match exists
*/
static int lj_cf_binary_match(lua_State *L)
{
  GCstr *input = lj_lib_checkstr(L, 1);
  BinaryPattern pattern = binary_pattern_open(L, 2);
  MSize start, length, match_start, match_len;
  int found;

  binary_scope(L, 3, input->len, &start, &length);
  found = binary_find(L, &pattern, strdata(input), start, length,
			      &match_start, &match_len);
  binary_pattern_close(L, &pattern);
  if (!found) return 0;
  lua_pushnumber(L, (lua_Number)match_start);
  lua_pushnumber(L, (lua_Number)match_len);
  return 2;
}

/***
Find all non-overlapping literal matches in a string.
@function binary.matches
@param data byte string to search
@param pattern non-empty string, pattern list, or compiled pattern
@param[opt] options table with optional `start` and `length` byte bounds
@return array of `{ offset, length }` tables in match order
*/
static int lj_cf_binary_matches(lua_State *L)
{
  GCstr *input = lj_lib_checkstr(L, 1);
  int result;
  BinaryPattern pattern;
  MSize start, length, offset, remaining, match_start, match_len;
  int count = 1;

  lua_newtable(L);
  result = lua_gettop(L);
  pattern = binary_pattern_open(L, 2);
  binary_scope(L, 3, input->len, &start, &length);
  offset = start;
  remaining = length;
  while (binary_find(L, &pattern, strdata(input), offset, remaining,
		     &match_start, &match_len)) {
    binary_push_match(L, match_start, match_len);
    lua_rawseti(L, result, count++);
    offset = match_start + match_len;
    remaining = start + length - offset;
  }
  binary_pattern_close(L, &pattern);
  return 1;
}

/***
Split a byte string at literal matches.
By default only the first match splits the string; `global = true` splits at
every match. `trim` drops trailing empty fields and `trim_all` drops all of
them.
@function binary.split
@param data byte string to split
@param pattern non-empty string, pattern list, or compiled pattern
@param[opt] options table with `global`, `trim`, or `trim_all` booleans
@return array of byte-string fields
*/
static int lj_cf_binary_split(lua_State *L)
{
  GCstr *input = lj_lib_checkstr(L, 1);
  int result;
  BinaryPattern pattern;
  MSize offset = 0, match_start, match_len;
  int count = 1;
  int global = binary_option(L, 3, "global");
  int trim_all = binary_option(L, 3, "trim_all");
  int trim = trim_all || binary_option(L, 3, "trim");

  lua_newtable(L);
  result = lua_gettop(L);
  pattern = binary_pattern_open(L, 2);
  while (binary_find(L, &pattern, strdata(input), offset,
		     input->len - offset, &match_start, &match_len)) {
    binary_push_slice(L, strdata(input), offset, match_start - offset);
    lua_rawseti(L, result, count++);
    offset = match_start + match_len;
    if (!global) break;
  }
  binary_push_slice(L, strdata(input), offset, input->len - offset);
  lua_rawseti(L, result, count++);
  if (trim) binary_trim_result(L, result, count-1, trim_all);
  binary_pattern_close(L, &pattern);
  lj_gc_check(L);
  return 1;
}

/***
Replace literal byte matches without interpreting Lua patterns.
The optional bounds preserve bytes outside the selected zero-based range.
@function binary.replace
@param data byte string to transform
@param pattern non-empty string, pattern list, or compiled pattern
@param replacement byte string to insert for each match
@param[opt] options table with `global`, `start`, and `length` fields
@return string with the requested replacements
*/
static int lj_cf_binary_replace(lua_State *L)
{
  GCstr *input = lj_lib_checkstr(L, 1);
  GCstr *replacement = lj_lib_checkstr(L, 3);
  BinaryPattern pattern;
  SBuf *out;
  MSize start, length, offset, remaining, match_start, match_len;
  int global = binary_option(L, 4, "global");

  pattern = binary_pattern_open(L, 2);
  binary_scope(L, 4, input->len, &start, &length);
  out = lj_buf_tmp_(L);
  offset = start;
  remaining = length;
  lj_buf_putmem(out, strdata(input), start);
  while (binary_find(L, &pattern, strdata(input), offset, remaining,
		     &match_start, &match_len)) {
    lj_buf_putmem(out, strdata(input) + offset, match_start - offset);
    lj_buf_putstr(out, replacement);
    offset = match_start + match_len;
    remaining = start + length - offset;
    if (!global) break;
  }
  lj_buf_putmem(out, strdata(input) + offset, start + length - offset);
  lj_buf_putmem(out, strdata(input) + start + length,
		input->len - start - length);
  setstrV(L, L->top++, lj_buf_str(L, out));
  binary_pattern_close(L, &pattern);
  lj_gc_check(L);
  return 1;
}

/***
Concatenate a sequence of byte strings with a separator.
@function binary.join
@param parts array of byte strings
@param separator byte string placed between parts
@return concatenated byte string
*/
static int lj_cf_binary_join(lua_State *L)
{
  GCstr *separator = lj_lib_checkstr(L, 2);
  size_t count;
  size_t i;
  SBuf *out;

  luaL_checktype(L, 1, LUA_TTABLE);
  count = lua_objlen(L, 1);
  out = lj_buf_tmp_(L);
  for (i = 1; i <= count; i++) {
    size_t length;
    const char *part;
    lua_rawgeti(L, 1, (int)i);
    if (lua_type(L, -1) != LUA_TSTRING) {
      lua_pop(L, 1);
      return luaL_error(L, "binary list element %d must be a string", (int)i);
    }
    part = lua_tolstring(L, -1, &length);
    if (i != 1) lj_buf_putstr(out, separator);
    lj_buf_putmem(out, part, (MSize)length);
    lua_pop(L, 1);
  }
  setstrV(L, L->top++, lj_buf_str(L, out));
  lj_gc_check(L);
  return 1;
}

static MSize binary_common(lua_State *L, int suffix)
{
  size_t count;
  size_t i;
  size_t first_len;
  const char *first;
  MSize common;

  luaL_checktype(L, 1, LUA_TTABLE);
  count = lua_objlen(L, 1);
  if (count == 0) return 0;
  lua_rawgeti(L, 1, 1);
  if (lua_type(L, -1) != LUA_TSTRING) {
    lua_pop(L, 1);
    luaL_error(L, "binary list element 1 must be a string");
  }
  first = lua_tolstring(L, -1, &first_len);
  lua_pop(L, 1);
  common = (MSize)first_len;
  for (i = 2; i <= count && common != 0; i++) {
    size_t length;
    const char *part;
    MSize j;
    lua_rawgeti(L, 1, (int)i);
    if (lua_type(L, -1) != LUA_TSTRING) {
      lua_pop(L, 1);
      luaL_error(L, "binary list element %d must be a string", (int)i);
    }
    part = lua_tolstring(L, -1, &length);
    if ((MSize)length < common) common = (MSize)length;
    for (j = 0; j < common; j++) {
      if (suffix ?
	  first[first_len-1-j] != part[length-1-j] : first[j] != part[j])
	break;
    }
    common = j;
    lua_pop(L, 1);
  }
  return common;
}

/***
Measure the shared leading bytes of a string sequence.
@function binary.longest_common_prefix
@param parts array of byte strings
@return number of bytes common to every part's prefix
*/
static int lj_cf_binary_longest_common_prefix(lua_State *L)
{
  lua_pushnumber(L, (lua_Number)binary_common(L, 0));
  return 1;
}

/***
Measure the shared trailing bytes of a string sequence.
@function binary.longest_common_suffix
@param parts array of byte strings
@return number of bytes common to every part's suffix
*/
static int lj_cf_binary_longest_common_suffix(lua_State *L)
{
  lua_pushnumber(L, (lua_Number)binary_common(L, 1));
  return 1;
}

/* ------------------------------------------------------------------------ */

/* These extensions use ordinary C functions, without fast-function IDs. */
static const luaL_Reg binary_funcs[] = {
  {"at", lj_cf_binary_at},
  {"first", lj_cf_binary_first},
  {"last", lj_cf_binary_last},
  {"part", lj_cf_binary_part},
  {"compile_pattern", lj_cf_binary_compile_pattern},
  {"match", lj_cf_binary_match},
  {"matches", lj_cf_binary_matches},
  {"split", lj_cf_binary_split},
  {"replace", lj_cf_binary_replace},
  {"join", lj_cf_binary_join},
  {"longest_common_prefix", lj_cf_binary_longest_common_prefix},
  {"longest_common_suffix", lj_cf_binary_longest_common_suffix},
  {NULL, NULL}
};

LUALIB_API int luaopen_binary(lua_State *L)
{
  luaL_register(L, LUA_BINARYLIBNAME, binary_funcs);
  return 1;
}
