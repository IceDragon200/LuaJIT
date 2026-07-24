/*
** UTF-8 library.
** Local experimental extension, with the Lua 5.3 utf8 API.
*/

#define lib_utf8_c
#define LUA_LIB

#include <limits.h>
#include <stdint.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lj_lib.h"

/* ------------------------------------------------------------------------ */

#define LJLIB_MODULE_utf8

/***
UTF-8 validation, conversion, and codepoint iteration.
String positions are one-based byte positions, matching Lua's string library.
@module utf8
@usage local utf8 = require("utf8")
@see doc/ext_utf8.html
*/

#define UTF8_MAX_CODEPOINT	0x10ffffu

static int utf8_iscontinuation(uint8_t byte)
{
  return (byte & 0xc0) == 0x80;
}

/* Decode one Lua 5.3-compatible UTF-8 sequence. */
static const uint8_t *utf8_decode(const uint8_t *p, const uint8_t *end,
				  uint32_t *codepoint)
{
  uint8_t first;
  uint32_t code;

  if (p >= end) return NULL;
  first = *p++;
  if (first < 0x80) {
    code = first;
  } else if (first >= 0xc2 && first <= 0xdf) {
    if (p >= end || !utf8_iscontinuation(*p)) return NULL;
    code = ((uint32_t)(first & 0x1f) << 6) | (*p++ & 0x3f);
  } else if (first >= 0xe0 && first <= 0xef) {
    uint8_t second;
    if (p >= end || !utf8_iscontinuation(*p)) return NULL;
    second = *p++;
    if (first == 0xe0 && second < 0xa0) return NULL;  /* Overlong. */
    if (p >= end || !utf8_iscontinuation(*p)) return NULL;
    code = ((uint32_t)(first & 0x0f) << 12) |
      ((uint32_t)(second & 0x3f) << 6) | (*p++ & 0x3f);
  } else if (first >= 0xf0 && first <= 0xf4) {
    uint8_t second;
    if (p >= end || !utf8_iscontinuation(*p)) return NULL;
    second = *p++;
    if ((first == 0xf0 && second < 0x90) ||
	(first == 0xf4 && second > 0x8f)) return NULL;
    if (p >= end || !utf8_iscontinuation(*p)) return NULL;
    code = ((uint32_t)(first & 0x07) << 18) |
      ((uint32_t)(second & 0x3f) << 12) |
      ((uint32_t)(*p++ & 0x3f) << 6);
    if (p >= end || !utf8_iscontinuation(*p)) return NULL;
    code |= *p++ & 0x3f;
  } else {
    return NULL;
  }

  if (codepoint) *codepoint = code;
  return p;
}

/* Translate one-based negative indices relative to the byte string end. */
static ptrdiff_t utf8_position(lua_Integer position, size_t length)
{
  if (position >= 0) return (ptrdiff_t)position;
  if (0u - (size_t)position > length) return 0;
  return (ptrdiff_t)length + (ptrdiff_t)position + 1;
}

static size_t utf8_encode(uint32_t codepoint, char output[4])
{
  if (codepoint < 0x80) {
    output[0] = (char)codepoint;
    return 1;
  }
  if (codepoint < 0x800) {
    output[0] = (char)(0xc0 | (codepoint >> 6));
    output[1] = (char)(0x80 | (codepoint & 0x3f));
    return 2;
  }
  if (codepoint < 0x10000) {
    output[0] = (char)(0xe0 | (codepoint >> 12));
    output[1] = (char)(0x80 | ((codepoint >> 6) & 0x3f));
    output[2] = (char)(0x80 | (codepoint & 0x3f));
    return 3;
  }
  output[0] = (char)(0xf0 | (codepoint >> 18));
  output[1] = (char)(0x80 | ((codepoint >> 12) & 0x3f));
  output[2] = (char)(0x80 | ((codepoint >> 6) & 0x3f));
  output[3] = (char)(0x80 | (codepoint & 0x3f));
  return 4;
}

/* ------------------------------------------------------------------------ */

/***
Count UTF-8 codepoints in a byte-position slice.
@function utf8.len
@param string UTF-8 byte string
@param[opt] initial one-based byte position, defaulting to 1
@param[opt] final one-based byte position, defaulting to -1
@return count, or nil and the one-based invalid byte position
*/
LJLIB_CF(utf8_len)
{
  size_t length;
  const uint8_t *string = (const uint8_t *)luaL_checklstring(L, 1, &length);
  ptrdiff_t start = utf8_position(luaL_optinteger(L, 2, 1), length);
  ptrdiff_t finish = utf8_position(luaL_optinteger(L, 3, -1), length);
  const uint8_t *cursor;
  const uint8_t *end = string + length;
  lua_Integer count = 0;

  luaL_argcheck(L, start >= 1 && --start <= (ptrdiff_t)length, 2,
		"initial position out of string");
  luaL_argcheck(L, --finish < (ptrdiff_t)length, 3,
		"final position out of string");
  cursor = string + start;
  while (start <= finish) {
    const uint8_t *next = utf8_decode(cursor, end, NULL);
    if (!next) {
      lua_pushnil(L);
      lua_pushinteger(L, start + 1);
      return 2;
    }
    start = (ptrdiff_t)(next - string);
    cursor = next;
    count++;
  }
  lua_pushinteger(L, count);
  return 1;
}

/***
Return codepoints from a byte-position slice.
@function utf8.codepoint
@param string UTF-8 byte string
@param[opt] initial one-based byte position
@param[opt] final one-based byte position
@return one integer codepoint for each decoded character
*/
LJLIB_CF(utf8_codepoint)
{
  size_t length;
  const uint8_t *string = (const uint8_t *)luaL_checklstring(L, 1, &length);
  ptrdiff_t start = utf8_position(luaL_optinteger(L, 2, 1), length);
  ptrdiff_t finish = utf8_position(luaL_optinteger(L, 3, start), length);
  const uint8_t *cursor;
  const uint8_t *limit;
  int count = 0;

  luaL_argcheck(L, start >= 1, 2, "out of range");
  luaL_argcheck(L, finish <= (ptrdiff_t)length, 3, "out of range");
  if (start > finish) return 0;
  if (finish - start >= INT_MAX)
    return luaL_error(L, "string slice too long");
  luaL_checkstack(L, (int)(finish - start) + 1, "string slice too long");
  cursor = string + start - 1;
  limit = string + length;
  while (cursor < string + finish) {
    uint32_t codepoint;
    cursor = utf8_decode(cursor, limit, &codepoint);
    if (!cursor) return luaL_error(L, "invalid UTF-8 code");
    lua_pushinteger(L, (lua_Integer)codepoint);
    count++;
  }
  return count;
}

/***
Encode one or more Unicode codepoints as UTF-8.
@function utf8.char
@param ... integer codepoints from 0 through 0x10ffff
@return UTF-8 byte string
*/
LJLIB_CF(utf8_char)
{
  int argument;
  int count = lua_gettop(L);
  luaL_Buffer buffer;

  luaL_buffinit(L, &buffer);
  for (argument = 1; argument <= count; argument++) {
    lua_Integer value = luaL_checkinteger(L, argument);
    char encoded[4];
    size_t encoded_length;
    luaL_argcheck(L, value >= 0 && value <= (lua_Integer)UTF8_MAX_CODEPOINT,
		  argument, "value out of range");
    encoded_length = utf8_encode((uint32_t)value, encoded);
    luaL_addlstring(&buffer, encoded, encoded_length);
  }
  luaL_pushresult(&buffer);
  return 1;
}

/***
Locate a UTF-8 character boundary relative to a byte position.
@function utf8.offset
@param string UTF-8 byte string
@param n number of character boundaries to move
@param[opt] initial one-based byte position
@return one-based byte position, or nil when no such boundary exists
*/
LJLIB_CF(utf8_offset)
{
  size_t length;
  const uint8_t *string = (const uint8_t *)luaL_checklstring(L, 1, &length);
  lua_Integer count = luaL_checkinteger(L, 2);
  ptrdiff_t position = utf8_position(luaL_optinteger(L, 3,
		count >= 0 ? 1 : (lua_Integer)length + 1), length);

  luaL_argcheck(L, position >= 1 && --position <= (ptrdiff_t)length, 3,
		"position out of range");
  if (count == 0) {
    while (position > 0 && utf8_iscontinuation(string[position])) position--;
  } else {
    if (utf8_iscontinuation(string[position]))
      return luaL_error(L, "initial position is a continuation byte");
    if (count < 0) {
      while (count < 0 && position > 0) {
	do { position--; } while (position > 0 &&
				     utf8_iscontinuation(string[position]));
	count++;
      }
    } else {
      count--;
      while (count > 0 && position < (ptrdiff_t)length) {
	do { position++; } while (utf8_iscontinuation(string[position]));
	count--;
      }
    }
  }
  if (count == 0)
    lua_pushinteger(L, position + 1);
  else
    lua_pushnil(L);
  return 1;
}

LJLIB_CF(utf8_codes_iter)
{
  size_t length;
  const uint8_t *string = (const uint8_t *)luaL_checklstring(L, 1, &length);
  lua_Integer previous = luaL_checkinteger(L, 2);
  ptrdiff_t position = previous <= 0 ? -1 : (ptrdiff_t)previous - 1;
  const uint8_t *next;
  uint32_t codepoint;

  if (position < 0) {
    position = 0;
  } else if (position < (ptrdiff_t)length) {
    position++;
    while (position < (ptrdiff_t)length && utf8_iscontinuation(string[position]))
      position++;
  }
  if (position >= (ptrdiff_t)length) return 0;
  next = utf8_decode(string + position, string + length, &codepoint);
  if (!next || (next < string + length && utf8_iscontinuation(*next)))
    return luaL_error(L, "invalid UTF-8 code");
  lua_pushinteger(L, position + 1);
  lua_pushinteger(L, (lua_Integer)codepoint);
  return 2;
}

/***
Create a generic-for iterator over UTF-8 positions and codepoints.
@function utf8.codes
@param string UTF-8 byte string
@return iterator function, original string state, and initial control value
@usage for position, codepoint in utf8.codes(text) do end
*/
LJLIB_CF(utf8_codes)
{
  luaL_checkstring(L, 1);
  lua_pushcfunction(L, lj_cf_utf8_codes_iter);
  lua_pushvalue(L, 1);
  lua_pushinteger(L, 0);
  return 3;
}

/* ------------------------------------------------------------------------ */

/* Use %z instead of a literal NUL: LuaJIT's pattern parser is C-string based. */
/***
Lua pattern text that matches a valid UTF-8 byte sequence.
@field utf8.charpattern
*/
static const char utf8_charpattern[] = "[%z\1-\x7f\xc2-\xf4][\x80-\xbf]*";

#include "lj_libdef.h"

LUALIB_API int luaopen_utf8(lua_State *L)
{
  LJ_LIB_REG(L, LUA_UTF8LIBNAME, utf8);
  lua_pushlstring(L, utf8_charpattern, sizeof(utf8_charpattern)-1);
  lua_setfield(L, -2, "charpattern");
  return 1;
}
