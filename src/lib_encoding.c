/*
** Byte encoding library.
** Local experimental extension.
*/

#define lib_encoding_c
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

#define LJLIB_MODULE_encoding

static int encoding_invalid(lua_State *L, const char *message)
{
  lua_pushnil(L);
  lua_pushstring(L, message);
  return 2;
}

static int encoding_hex_value(uint8_t c)
{
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

LJLIB_CF(encoding_hex_encode)
{
  static const char lower[] = "0123456789abcdef";
  static const char upper[] = "0123456789ABCDEF";
  GCstr *input = lj_lib_checkstr(L, 1);
  const char *digits = lua_toboolean(L, 2) ? upper : lower;
  const uint8_t *data = (const uint8_t *)strdata(input);
  SBuf *out = lj_buf_tmp_(L);
  MSize i;

  for (i = 0; i < input->len; i++) {
    lj_buf_putb(out, digits[data[i] >> 4]);
    lj_buf_putb(out, digits[data[i] & 15]);
  }
  setstrV(L, L->top++, lj_buf_str(L, out));
  lj_gc_check(L);
  return 1;
}

LJLIB_CF(encoding_hex_decode)
{
  GCstr *input = lj_lib_checkstr(L, 1);
  const uint8_t *data = (const uint8_t *)strdata(input);
  SBuf *out;
  MSize i;

  if (input->len & 1)
    return encoding_invalid(L, "invalid hexadecimal encoding");
  out = lj_buf_tmp_(L);
  for (i = 0; i < input->len; i += 2) {
    int hi = encoding_hex_value(data[i]);
    int lo = encoding_hex_value(data[i+1]);
    if (hi < 0 || lo < 0)
      return encoding_invalid(L, "invalid hexadecimal encoding");
    lj_buf_putb(out, (hi << 4) | lo);
  }
  setstrV(L, L->top++, lj_buf_str(L, out));
  lj_gc_check(L);
  return 1;
}

static void encoding_base64_encode(lua_State *L, GCstr *input, int urlsafe)
{
  static const char base64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  static const char base64url[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  const char *alphabet = urlsafe ? base64url : base64;
  const uint8_t *data = (const uint8_t *)strdata(input);
  SBuf *out = lj_buf_tmp_(L);
  MSize i = 0;

  while (input->len - i >= 3) {
    uint32_t n = ((uint32_t)data[i] << 16) |
	 ((uint32_t)data[i+1] << 8) | data[i+2];
    lj_buf_putb(out, alphabet[n >> 18]);
    lj_buf_putb(out, alphabet[(n >> 12) & 63]);
    lj_buf_putb(out, alphabet[(n >> 6) & 63]);
    lj_buf_putb(out, alphabet[n & 63]);
    i += 3;
  }
  if (input->len - i == 1) {
    uint32_t n = (uint32_t)data[i] << 16;
    lj_buf_putb(out, alphabet[n >> 18]);
    lj_buf_putb(out, alphabet[(n >> 12) & 63]);
    if (!urlsafe) {
      lj_buf_putb(out, '=');
      lj_buf_putb(out, '=');
    }
  } else if (input->len - i == 2) {
    uint32_t n = ((uint32_t)data[i] << 16) | ((uint32_t)data[i+1] << 8);
    lj_buf_putb(out, alphabet[n >> 18]);
    lj_buf_putb(out, alphabet[(n >> 12) & 63]);
    lj_buf_putb(out, alphabet[(n >> 6) & 63]);
    if (!urlsafe) lj_buf_putb(out, '=');
  }
  setstrV(L, L->top++, lj_buf_str(L, out));
}

LJLIB_CF(encoding_base64_encode)
{
  encoding_base64_encode(L, lj_lib_checkstr(L, 1), 0);
  lj_gc_check(L);
  return 1;
}

LJLIB_CF(encoding_base64url_encode)
{
  encoding_base64_encode(L, lj_lib_checkstr(L, 1), 1);
  lj_gc_check(L);
  return 1;
}

static int encoding_base64_value(uint8_t c, int urlsafe)
{
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (urlsafe ? c == '-' : c == '+') return 62;
  if (urlsafe ? c == '_' : c == '/') return 63;
  return -1;
}

static int encoding_base64_decode(lua_State *L, GCstr *input, int urlsafe)
{
  const uint8_t *data = (const uint8_t *)strdata(input);
  MSize data_len = input->len;
  MSize i = 0;
  uint32_t padding = 0;
  SBuf *out;

  while (data_len && data[data_len-1] == '=') {
    data_len--;
    padding++;
  }
  if (padding > 2 || data_len % 4 == 1)
    return encoding_invalid(L, "invalid base64 encoding");
  for (i = 0; i < data_len; i++) {
    if (data[i] == '=' || encoding_base64_value(data[i], urlsafe) < 0)
      return encoding_invalid(L, "invalid base64 encoding");
  }
  if (urlsafe) {
    if (padding && (input->len % 4 ||
	    padding != (uint32_t)((4 - data_len % 4) % 4)))
      return encoding_invalid(L, "invalid base64 encoding");
  } else if (input->len % 4 ||
	     padding != (uint32_t)((4 - data_len % 4) % 4)) {
    return encoding_invalid(L, "invalid base64 encoding");
  }

  out = lj_buf_tmp_(L);
  i = 0;
  while (data_len - i >= 4) {
    int a = encoding_base64_value(data[i], urlsafe);
    int b = encoding_base64_value(data[i+1], urlsafe);
    int c = encoding_base64_value(data[i+2], urlsafe);
    int d = encoding_base64_value(data[i+3], urlsafe);
    lj_buf_putb(out, (a << 2) | (b >> 4));
    lj_buf_putb(out, (b << 4) | (c >> 2));
    lj_buf_putb(out, (c << 6) | d);
    i += 4;
  }
  if (data_len - i == 2) {
    int a = encoding_base64_value(data[i], urlsafe);
    int b = encoding_base64_value(data[i+1], urlsafe);
    if (b & 15) return encoding_invalid(L, "invalid base64 encoding");
    lj_buf_putb(out, (a << 2) | (b >> 4));
  } else if (data_len - i == 3) {
    int a = encoding_base64_value(data[i], urlsafe);
    int b = encoding_base64_value(data[i+1], urlsafe);
    int c = encoding_base64_value(data[i+2], urlsafe);
    if (c & 3) return encoding_invalid(L, "invalid base64 encoding");
    lj_buf_putb(out, (a << 2) | (b >> 4));
    lj_buf_putb(out, (b << 4) | (c >> 2));
  }
  setstrV(L, L->top++, lj_buf_str(L, out));
  lj_gc_check(L);
  return 1;
}

LJLIB_CF(encoding_base64_decode)
{
  return encoding_base64_decode(L, lj_lib_checkstr(L, 1), 0);
}

LJLIB_CF(encoding_base64url_decode)
{
  return encoding_base64_decode(L, lj_lib_checkstr(L, 1), 1);
}

/* ------------------------------------------------------------------------ */

#include "lj_libdef.h"

LUALIB_API int luaopen_encoding(lua_State *L)
{
  LJ_LIB_REG(L, LUA_ENCODINGLIBNAME, encoding);
  return 1;
}
