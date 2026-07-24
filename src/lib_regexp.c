/*
** PCRE2 regular expression library.
** Local experimental extension. Built only with LJ_PCRE2=1.
*/

#define lib_regexp_c
#define LUA_LIB

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#if LJ_HAS_PCRE2

#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>

#define REGEXP_PATTERN_MT	"regexp.pattern"

/***
PCRE2-backed regular expressions.
This optional module is available only when LuaJIT is built with `LJ_PCRE2=1`.
@module regexp
@usage local regexp = require("regexp")
@see doc/ext_regexp.html
*/

typedef struct RegexpPattern {
  pcre2_code *code;
  uint32_t captures;
} RegexpPattern;

static RegexpPattern *regexp_check_pattern(lua_State *L, int narg)
{
  return (RegexpPattern *)luaL_checkudata(L, narg, REGEXP_PATTERN_MT);
}

static uint32_t regexp_options(lua_State *L, const char *flags)
{
  uint32_t options = 0;
  const char *p;
  for (p = flags; *p; p++) {
    switch (*p) {
    case 'i': options |= PCRE2_CASELESS; break;
    case 'm': options |= PCRE2_MULTILINE; break;
    case 's': options |= PCRE2_DOTALL; break;
    case 'u': options |= PCRE2_UTF|PCRE2_UCP; break;
    case 'x': options |= PCRE2_EXTENDED; break;
    default: luaL_error(L, "invalid regexp flag '%c'", *p);
    }
  }
  return options;
}

static int regexp_compile_error(lua_State *L, int error, PCRE2_SIZE offset)
{
  PCRE2_UCHAR message[256];
  pcre2_get_error_message(error, message, sizeof(message));
  lua_pushnil(L);
  lua_pushfstring(L, "regexp compile error at offset %d: %s",
		  (int)offset, (const char *)message);
  return 2;
}

/***
Compile a PCRE2 pattern into a reusable pattern object.
Accepted flags are `i`, `m`, `s`, `u`, and `x`.
@function regexp.compile
@param source PCRE2 pattern text
@param[opt] flags string
@return pattern object, or nil and a compile-error message
*/
static int regexp_compile(lua_State *L)
{
  size_t length;
  const char *source = luaL_checklstring(L, 1, &length);
  const char *flags = luaL_optstring(L, 2, "");
  PCRE2_SIZE offset;
  int error;
  pcre2_code *code = pcre2_compile((PCRE2_SPTR)source, length,
		regexp_options(L, flags), &error, &offset, NULL);
  RegexpPattern *pattern;

  if (!code) return regexp_compile_error(L, error, offset);
  pattern = (RegexpPattern *)lua_newuserdata(L, sizeof(*pattern));
  pattern->code = code;
  pcre2_pattern_info(code, PCRE2_INFO_CAPTURECOUNT, &pattern->captures);
  luaL_getmetatable(L, REGEXP_PATTERN_MT);
  lua_setmetatable(L, -2);
  return 1;
}

static int regexp_pattern_gc(lua_State *L)
{
  RegexpPattern *pattern = regexp_check_pattern(L, 1);
  if (pattern->code) {
    pcre2_code_free(pattern->code);
    pattern->code = NULL;
  }
  return 0;
}

/***
Find the first match of a compiled pattern.
Positions are one-based Lua byte indices. Captures follow the start and end
positions; unmatched optional captures are returned as nil.
@function regexp.Pattern:find
@param self compiled pattern object
@param subject byte string to search
@param[opt] start one-based byte offset, defaulting to 1
@return start, end, and capture strings; no results when there is no match
*/
static int regexp_pattern_find(lua_State *L)
{
  RegexpPattern *pattern = regexp_check_pattern(L, 1);
  size_t length;
  const char *subject = luaL_checklstring(L, 2, &length);
  lua_Integer start = luaL_optinteger(L, 3, 1);
  pcre2_match_data *matches;
  PCRE2_SIZE *ovector;
  int result;
  uint32_t i;

  if (start < 1 || (size_t)(start-1) > length)
    return luaL_argerror(L, 3, "start is outside the subject");
  matches = pcre2_match_data_create_from_pattern(pattern->code, NULL);
  if (!matches) return luaL_error(L, "could not allocate regexp match data");
  result = pcre2_match(pattern->code, (PCRE2_SPTR)subject, length,
		(PCRE2_SIZE)(start-1), 0, matches, NULL);
  if (result == PCRE2_ERROR_NOMATCH) {
    pcre2_match_data_free(matches);
    return 0;
  }
  if (result < 0) {
    pcre2_match_data_free(matches);
    return luaL_error(L, "regexp match failed (%d)", result);
  }
  if (!lua_checkstack(L, (int)pattern->captures + 2)) {
    pcre2_match_data_free(matches);
    return luaL_error(L, "too many regexp captures");
  }
  ovector = pcre2_get_ovector_pointer(matches);
  lua_pushinteger(L, (lua_Integer)ovector[0] + 1);
  lua_pushinteger(L, (lua_Integer)ovector[1]);
  for (i = 1; i <= pattern->captures; i++) {
    PCRE2_SIZE from = ovector[2*i];
    PCRE2_SIZE to = ovector[2*i+1];
    if (from == PCRE2_UNSET)
      lua_pushnil(L);
    else
      lua_pushlstring(L, subject + from, to - from);
  }
  pcre2_match_data_free(matches);
  return (int)pattern->captures + 2;
}

static int regexp_pattern_tostring(lua_State *L)
{
  RegexpPattern *pattern = regexp_check_pattern(L, 1);
  lua_pushfstring(L, "regexp.pattern: %p", pattern->code);
  return 1;
}

/***
Quote PCRE2 metacharacters in a literal string.
@function regexp.escape
@param text literal text to embed in a PCRE2 pattern
@return escaped pattern text
*/
static int regexp_escape(lua_State *L)
{
  size_t length, i;
  const char *source = luaL_checklstring(L, 1, &length);
  luaL_Buffer out;

  luaL_buffinit(L, &out);
  for (i = 0; i < length; i++) {
    switch (source[i]) {
    case '\\': case '.': case '^': case '$': case '|': case '(':
    case ')': case '[': case ']': case '{': case '}': case '*':
    case '+': case '?':
      luaL_addchar(&out, '\\');
    }
    luaL_addchar(&out, source[i]);
  }
  luaL_pushresult(&out);
  return 1;
}

static const luaL_Reg regexp_methods[] = {
  { "find", regexp_pattern_find },
  { "__gc", regexp_pattern_gc },
  { "__tostring", regexp_pattern_tostring },
  { NULL, NULL }
};

static const luaL_Reg regexp_library[] = {
  { "compile", regexp_compile },
  { "escape", regexp_escape },
  { NULL, NULL }
};

LUALIB_API int luaopen_regexp(lua_State *L)
{
  if (luaL_newmetatable(L, REGEXP_PATTERN_MT)) {
    luaL_register(L, NULL, regexp_methods);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
  }
  lua_pop(L, 1);
  lua_newtable(L);
  luaL_register(L, NULL, regexp_library);
  return 1;
}

#endif
