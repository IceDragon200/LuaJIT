/*
** Pattern matching support.
** Local experimental extension.
** Syntax and semantics are informed by Erlang and Elixir pattern matching.
** This implementation was written independently for this fork.
*/

#define lj_pattern_c
#define LUA_CORE

#include <stdint.h>
#include <string.h>

#include "lua.h"

#include "lj_obj.h"
#include "lj_gc.h"
#include "lj_err.h"
#include "lj_buf.h"
#include "lj_str.h"
#include "lj_strfmt.h"
#include "lj_tab.h"
#include "lj_pattern.h"

static uint32_t binfmt_get_u32(const uint8_t **pfmt, const uint8_t *end)
{
  const uint8_t *p = *pfmt;
  uint32_t n;
  if ((size_t)(end-p) < 4) return UINT32_MAX;
  n = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
      ((uint32_t)p[2] << 8) | (uint32_t)p[3];
  *pfmt = p+4;
  return n;
}

static uint64_t bin_read_uint(const uint8_t *data, MSize pos,
			      uint8_t nbytes, int little)
{
  uint64_t value = 0;
  uint8_t i;
  for (i = 0; i < nbytes; i++)
    value = (value << 8) | data[pos + (little ? nbytes-1-i : i)];
  return value;
}

static const TValue *pattern_pin_value(lua_State *L, const TValue *pins,
				       uint32_t npins, uint32_t index)
{
  if (index >= npins)
    lj_err_callermsg(L, "invalid pattern format");
  return pins + index;
}

static void bin_set_int(TValue *out, uint64_t value, uint8_t nbits,
			int issigned)
{
  if (issigned) {
    int64_t signed_value;
    uint64_t signbit = (uint64_t)1 << (nbits-1);
    if (value & signbit)
      signed_value = (int64_t)(value - ((uint64_t)1 << nbits));
    else
      signed_value = (int64_t)value;
    setint64V(out, signed_value);
  } else if (value <= INT32_MAX) {
    setintV(out, (int32_t)value);
  } else {
    setnumV(out, (lua_Number)value);
  }
}

static void bin_push_int(lua_State *L, uint64_t value, uint8_t nbits,
			 int issigned)
{
  bin_set_int(L->top++, value, nbits, issigned);
}

/* Decode IEEE-754 interchange formats. Non-finite segments do not match. */
static int bin_decode_float(uint64_t bits, uint8_t nbits, lua_Number *out)
{
  if (nbits == 16) {
    uint32_t exp = (uint32_t)(bits >> 10) & 0x1f;
    lua_Number n;
    int power;
    if (exp == 0x1f) return 0;
    if (exp == 0) {
      n = (lua_Number)(bits & 0x3ff) / 16777216.0;  /* 2^-24. */
    } else {
      n = (lua_Number)(1024 + (bits & 0x3ff));
      power = (int)exp - 25;
      while (power < 0) { n *= 0.5; power++; }
      while (power > 0) { n *= 2.0; power--; }
    }
    *out = (bits & 0x8000) ? -n : n;
    return 1;
  } else if (nbits == 32) {
    uint32_t word = (uint32_t)bits;
    float n;
    if ((word & 0x7f800000) == 0x7f800000) return 0;
    LJ_STATIC_ASSERT(sizeof(n) == 4);
    memcpy(&n, &word, sizeof(n));
    *out = (lua_Number)n;
    return 1;
  } else if (nbits == 64) {
    double n;
    if ((bits & U64x(7ff00000,00000000)) == U64x(7ff00000,00000000))
      return 0;
    LJ_STATIC_ASSERT(sizeof(n) == 8);
    memcpy(&n, &bits, sizeof(n));
    *out = (lua_Number)n;
    return 1;
  }
  return 0;
}

static int binfmt_get_literal_number(const uint8_t **pfmt,
				     const uint8_t *end, lua_Number *out)
{
  const uint8_t *fmt = *pfmt;
  uint64_t bits;
  lua_Number n;
  if (fmt >= end) return 0;
  if (*fmt++ == TBLLIT_INT) {
    if ((size_t)(end-fmt) < 4) return 0;
    bits = ((uint32_t)fmt[0] << 24) | ((uint32_t)fmt[1] << 16) |
	   ((uint32_t)fmt[2] << 8) | (uint32_t)fmt[3];
    *out = (lua_Number)(int32_t)(uint32_t)bits;
    fmt += 4;
  } else if (fmt[-1] == TBLLIT_NUM) {
    if ((size_t)(end-fmt) < 8) return 0;
    bits = ((uint64_t)fmt[0] << 56) | ((uint64_t)fmt[1] << 48) |
	   ((uint64_t)fmt[2] << 40) | ((uint64_t)fmt[3] << 32) |
	   ((uint64_t)fmt[4] << 24) | ((uint64_t)fmt[5] << 16) |
	   ((uint64_t)fmt[6] << 8) | (uint64_t)fmt[7];
    LJ_STATIC_ASSERT(sizeof(bits) == sizeof(n));
    memcpy(&n, &bits, sizeof(n));
    *out = n;
    fmt += 8;
  } else {
    return 0;
  }
  *pfmt = fmt;
  return 1;
}

static int bin_encode_int(lua_Number n, uint8_t nbits, int issigned,
			  uint64_t *out);
static int bin_encode_float(lua_Number n, uint8_t nbits, uint64_t *out);

/* Decode input according to format, returning 0 for an ordinary mismatch. */
static int bin_match(lua_State *L, GCstr *input, GCstr *format,
		     const TValue *pins, uint32_t npins, MSize *pfailpos)
{
  const uint8_t *data = (const uint8_t *)strdata(input);
  const uint8_t *fmt = (const uint8_t *)strdata(format);
  const uint8_t *fmtend = fmt + format->len;
  MSize pos = 0;

  if (pfailpos) *pfailpos = 0;
  while (fmt < fmtend) {
    uint8_t opcode = *fmt++;
    uint32_t size;
    if (pfailpos) *pfailpos = pos;
    switch (opcode) {
    case BINFMT_LITERAL:
      size = binfmt_get_u32(&fmt, fmtend);
      if ((size_t)(fmtend-fmt) < size)
	lj_err_callermsg(L, "invalid binary pattern format");
      if (size == UINT32_MAX || size > input->len-pos ||
	  (size && memcmp(data+pos, fmt, size) != 0))
	return 0;
      fmt += size;
      pos += size;
      break;
    case BINFMT_LITERAL_INT:
    case BINFMT_LITERAL_FLOAT: {
      uint8_t nbits, flags, nbytes;
      uint64_t expected, actual;
      lua_Number literal;
      if ((size_t)(fmtend-fmt) < 2)
	lj_err_callermsg(L, "invalid binary pattern format");
      nbits = *fmt++;
      flags = *fmt++;
      if ((opcode == BINFMT_LITERAL_INT &&
	   (nbits < 8 || nbits > 48 || (nbits & 7) ||
	    flags & ~(BINFMT_F_LITTLE|BINFMT_F_SIGNED))) ||
	  (opcode == BINFMT_LITERAL_FLOAT &&
	   ((nbits != 16 && nbits != 32 && nbits != 64) ||
	    flags & ~BINFMT_F_LITTLE)) ||
	  !binfmt_get_literal_number(&fmt, fmtend, &literal))
	lj_err_callermsg(L, "invalid binary pattern format");
      if (opcode == BINFMT_LITERAL_INT) {
	if (!bin_encode_int(literal, nbits, flags & BINFMT_F_SIGNED, &expected))
	  return 0;
      } else {
	if (!bin_encode_float(literal, nbits, &expected)) return 0;
      }
      nbytes = nbits >> 3;
      if (input->len-pos < nbytes) return 0;
      actual = bin_read_uint(data, pos, nbytes, flags & BINFMT_F_LITTLE);
      if (actual != expected) return 0;
      pos += nbytes;
      break;
    }
    case BINFMT_INT:
    case BINFMT_SKIP_INT: {
      uint8_t nbits, flags, nbytes;
      uint64_t value;
      if ((size_t)(fmtend-fmt) < 2)
	lj_err_callermsg(L, "invalid binary pattern format");
      nbits = *fmt++;
      flags = *fmt++;
      if (nbits < 8 || nbits > 48 || (nbits & 7) ||
	  flags & ~(BINFMT_F_LITTLE|BINFMT_F_SIGNED))
	lj_err_callermsg(L, "invalid binary pattern format");
      nbytes = nbits >> 3;
      if (input->len-pos < nbytes) return 0;
      value = bin_read_uint(data, pos, nbytes, flags & BINFMT_F_LITTLE);
      pos += nbytes;
      if (opcode == BINFMT_INT) {
	if (!lua_checkstack(L, 1)) lj_err_caller(L, LJ_ERR_STKOV);
	bin_push_int(L, value, nbits, flags & BINFMT_F_SIGNED);
      }
      break;
    }
    case BINFMT_FLOAT:
    case BINFMT_SKIP_FLOAT: {
      uint8_t nbits, flags, nbytes;
      uint64_t bits;
      lua_Number value;
      if ((size_t)(fmtend-fmt) < 2)
	lj_err_callermsg(L, "invalid binary pattern format");
      nbits = *fmt++;
      flags = *fmt++;
      if ((nbits != 16 && nbits != 32 && nbits != 64) ||
	  flags & ~BINFMT_F_LITTLE)
	lj_err_callermsg(L, "invalid binary pattern format");
      nbytes = nbits >> 3;
      if (input->len-pos < nbytes) return 0;
      bits = bin_read_uint(data, pos, nbytes, flags & BINFMT_F_LITTLE);
      pos += nbytes;
      if (!bin_decode_float(bits, nbits, &value)) return 0;
      if (opcode == BINFMT_FLOAT) {
	if (!lua_checkstack(L, 1)) lj_err_caller(L, LJ_ERR_STKOV);
	setnumV(L->top++, value);
      }
      break;
    }
    case BINFMT_BYTES:
      size = binfmt_get_u32(&fmt, fmtend);
      if (size == UINT32_MAX || size > input->len-pos)
	return 0;
      setstrV(L, L->top++, lj_str_new(L, (const char *)data+pos, size));
      pos += size;
      break;
    case BINFMT_SKIP_BYTES:
      size = binfmt_get_u32(&fmt, fmtend);
      if (size == UINT32_MAX || size > input->len-pos)
	return 0;
      pos += size;
      break;
    case BINFMT_REST:
      setstrV(L, L->top++,
	      lj_str_new(L, (const char *)data+pos, input->len-pos));
      pos = input->len;
      break;
    case BINFMT_SKIP_REST:
      pos = input->len;
      break;
    case BINFMT_PIN_LITERAL: {
      const TValue *pin;
      size = binfmt_get_u32(&fmt, fmtend);
      if (size == UINT32_MAX)
	lj_err_callermsg(L, "invalid binary pattern format");
      pin = pattern_pin_value(L, pins, npins, size);
      if (!tvisstr(pin)) return 0;
      size = strV(pin)->len;
      if (size > input->len-pos ||
	  (size && memcmp(data+pos, strdata(strV(pin)), size) != 0))
	return 0;
      pos += size;
      break;
    }
    case BINFMT_PIN_INT: {
      uint8_t nbits, flags, nbytes;
      uint64_t value;
      TValue actual;
      if ((size_t)(fmtend-fmt) < 2)
	lj_err_callermsg(L, "invalid binary pattern format");
      nbits = *fmt++;
      flags = *fmt++;
      size = binfmt_get_u32(&fmt, fmtend);
      if (size == UINT32_MAX || nbits < 8 || nbits > 48 || (nbits & 7) ||
	  flags & ~(BINFMT_F_LITTLE|BINFMT_F_SIGNED))
	lj_err_callermsg(L, "invalid binary pattern format");
      nbytes = nbits >> 3;
      if (input->len-pos < nbytes) return 0;
      value = bin_read_uint(data, pos, nbytes, flags & BINFMT_F_LITTLE);
      pos += nbytes;
      bin_set_int(&actual, value, nbits, flags & BINFMT_F_SIGNED);
      if (!lj_obj_equal(&actual, pattern_pin_value(L, pins, npins, size))) return 0;
      break;
    }
    case BINFMT_PIN_FLOAT: {
      uint8_t nbits, flags, nbytes;
      uint64_t bits;
      lua_Number value;
      TValue actual;
      if ((size_t)(fmtend-fmt) < 2)
	lj_err_callermsg(L, "invalid binary pattern format");
      nbits = *fmt++;
      flags = *fmt++;
      size = binfmt_get_u32(&fmt, fmtend);
      if (size == UINT32_MAX ||
	  (nbits != 16 && nbits != 32 && nbits != 64) ||
	  flags & ~BINFMT_F_LITTLE)
	lj_err_callermsg(L, "invalid binary pattern format");
      nbytes = nbits >> 3;
      if (input->len-pos < nbytes) return 0;
      bits = bin_read_uint(data, pos, nbytes, flags & BINFMT_F_LITTLE);
      pos += nbytes;
      if (!bin_decode_float(bits, nbits, &value)) return 0;
      setnumV(&actual, value);
      if (!lj_obj_equal(&actual, pattern_pin_value(L, pins, npins, size))) return 0;
      break;
    }
    case BINFMT_PIN_BYTES: {
      const TValue *pin;
      uint32_t index;
      size = binfmt_get_u32(&fmt, fmtend);
      index = binfmt_get_u32(&fmt, fmtend);
      if (size == UINT32_MAX || index == UINT32_MAX)
	lj_err_callermsg(L, "invalid binary pattern format");
      pin = pattern_pin_value(L, pins, npins, index);
      if (!tvisstr(pin) || strV(pin)->len != size || size > input->len-pos ||
	  (size && memcmp(data+pos, strdata(strV(pin)), size) != 0))
	return 0;
      pos += size;
      break;
    }
    case BINFMT_PIN_REST: {
      const TValue *pin;
      size = binfmt_get_u32(&fmt, fmtend);
      if (size == UINT32_MAX)
	lj_err_callermsg(L, "invalid binary pattern format");
      pin = pattern_pin_value(L, pins, npins, size);
      if (!tvisstr(pin) || strV(pin)->len != input->len-pos ||
	  (strV(pin)->len && memcmp(data+pos, strdata(strV(pin)),
				       strV(pin)->len) != 0))
	return 0;
      pos = input->len;
      break;
    }
    case BINFMT_ARRAY:
    case BINFMT_SKIP_ARRAY: {
      uint8_t kind, nbits, flags, nbytes;
      uint32_t count, i;
      GCtab *array = NULL;
      if ((size_t)(fmtend-fmt) < 3)
	lj_err_callermsg(L, "invalid binary pattern format");
      kind = *fmt++;
      nbits = *fmt++;
      flags = *fmt++;
      count = binfmt_get_u32(&fmt, fmtend);
      if (count == UINT32_MAX || count > INT32_MAX ||
	  (kind != 0 && kind != 1) ||
	  (kind == 0 && (nbits < 8 || nbits > 48 || (nbits & 7) ||
			 flags & ~(BINFMT_F_LITTLE|BINFMT_F_SIGNED))) ||
	  (kind == 1 && ((nbits != 16 && nbits != 32 && nbits != 64) ||
			 flags & ~BINFMT_F_LITTLE)))
	lj_err_callermsg(L, "invalid binary pattern format");
      nbytes = nbits >> 3;
      if (count > (input->len-pos) / nbytes) return 0;
      if (opcode == BINFMT_ARRAY)
	array = lj_tab_new(L, count, 0);
      for (i = 0; i < count; i++) {
	uint64_t bits = bin_read_uint(data, pos, nbytes, flags & BINFMT_F_LITTLE);
	pos += nbytes;
	if (kind == 1) {
	  lua_Number number;
	  if (!bin_decode_float(bits, nbits, &number)) return 0;
	  if (array) setnumV(lj_tab_setint(L, array, (int32_t)i+1), number);
	} else if (array) {
	  bin_set_int(lj_tab_setint(L, array, (int32_t)i+1), bits, nbits,
		      flags & BINFMT_F_SIGNED);
	}
      }
      if (array) {
	if (!lua_checkstack(L, 1)) lj_err_caller(L, LJ_ERR_STKOV);
	settabV(L, L->top++, array);
      }
      break;
    }
    default:
      lj_err_callermsg(L, "invalid binary pattern format");
    }
  }
  if (pfailpos) *pfailpos = pos;
  return pos == input->len;
}

int lj_pattern_bin_match(lua_State *L, GCstr *input, GCstr *format,
			 const TValue *pins, uint32_t npins)
{
  MSize top = (MSize)(L->top - L->base);
  MSize failpos;
  if (!bin_match(L, input, format, pins, npins, &failpos))
    lj_err_callermsg(L, lj_strfmt_pushf(L,
	"binary pattern match failed at byte %u", (uint32_t)failpos));
  lj_gc_check(L);
  return (int)((L->top - L->base) - top);
}

int lj_pattern_try_bin_match(lua_State *L, TValue *input, GCstr *format,
			     const TValue *pins, uint32_t npins)
{
  MSize top = (MSize)(L->top - L->base);

  if (tvisstr(input)) {
    if (!lua_checkstack(L, 1)) lj_err_caller(L, LJ_ERR_STKOV);
    setboolV(L->top++, 1);
    if (bin_match(L, strV(input), format, pins, npins, NULL)) {
      lj_gc_check(L);
      return (int)((L->top - L->base) - top);
    }
  }
  L->top = L->base + top;
  setboolV(L->top++, 0);
  return 1;
}

static int tablefmt_get_u32(const uint8_t **pfmt, const uint8_t *end,
			    uint32_t *pn)
{
  const uint8_t *p = *pfmt;
  if ((size_t)(end-p) < 4) return 0;
  *pn = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
	((uint32_t)p[2] << 8) | (uint32_t)p[3];
  *pfmt = p+4;
  return 1;
}

static int tablefmt_get_u64(const uint8_t **pfmt, const uint8_t *end,
			    uint64_t *pn)
{
  uint32_t hi, lo;
  if (!tablefmt_get_u32(pfmt, end, &hi) ||
      !tablefmt_get_u32(pfmt, end, &lo))
    return 0;
  *pn = ((uint64_t)hi << 32) | lo;
  return 1;
}

static int tablefmt_get_string(const uint8_t **pfmt, const uint8_t *end,
			       const uint8_t **pstr, uint32_t *plen)
{
  const uint8_t *p = *pfmt;
  uint32_t len;
  if (!tablefmt_get_u32(&p, end, &len) || (size_t)(end-p) < len)
    return 0;
  *pstr = p;
  *plen = len;
  *pfmt = p+len;
  return 1;
}

static cTValue *table_match_key(lua_State *L, GCtab *table,
				 const uint8_t *key, uint32_t len)
{
  GCstr *str = lj_str_new(L, (const char *)key, len);
  return lj_tab_getstr(table, str);
}

static int table_match_push(lua_State *L, cTValue *value, int required)
{
  if (required && (!value || tvisnil(value))) return 0;
  if (!lua_checkstack(L, 1))
    lj_err_caller(L, LJ_ERR_STKOV);
  if (value)
    copyTV(L, L->top++, value);
  else
    setnilV(L->top++);
  return 1;
}

static int table_match_literal(cTValue *value, uint8_t opcode,
			       const uint8_t *literal, uint32_t literal_len,
			       uint32_t intbits, uint64_t numbits)
{
  TValue expected;
  if (opcode == TBLLIT_NIL)
    return !value || tvisnil(value);
  if (opcode == TBLLIT_FALSE)
    return value && tvisfalse(value);
  if (opcode == TBLLIT_TRUE)
    return value && tvistrue(value);
  if (opcode == TBLLIT_STRING)
    return value && tvisstr(value) && strV(value)->len == literal_len &&
	  memcmp(strdata(strV(value)), literal, literal_len) == 0;
  if (opcode == TBLLIT_INT) {
    setintV(&expected, (int32_t)intbits);
    return value && lj_obj_equal(value, &expected);
  }
  if (opcode == TBLLIT_NUM) {
    lua_Number n;
    LJ_STATIC_ASSERT(sizeof(numbits) == sizeof(n));
    memcpy(&n, &numbits, sizeof(n));
    setnumV(&expected, n);
    return value && lj_obj_equal(value, &expected);
  }
  return 0;
}

static int table_match_pin(cTValue *value, const TValue *pin)
{
  if (!value || tvisnil(value)) return tvisnil(pin);
  return lj_obj_equal(value, pin);
}

typedef struct TableMatchFailure {
  uint8_t kind;
  uint32_t position;
  GCstr *key;
} TableMatchFailure;

#define TBLFAIL_POS	1
#define TBLFAIL_KEY	2

static void table_match_fail(lua_State *L, TableMatchFailure *failure,
			     uint8_t kind, uint32_t position,
			     const uint8_t *key, uint32_t keylen)
{
  if (!failure || failure->kind) return;
  failure->kind = kind;
  failure->position = position;
  failure->key = key ? lj_str_new(L, (const char *)key, keylen) : NULL;
}

static int tablefmt_rest_end(const uint8_t *fmt, const uint8_t *end,
			     uint32_t count, const uint8_t **pafter)
{
  uint32_t i, index, keylen;
  const uint8_t *key;
  for (i = 0; i < count; i++) {
    if (fmt >= end) return 0;
    if (*fmt++ == TBLREST_POS) {
      if (!tablefmt_get_u32(&fmt, end, &index)) return 0;
    } else if (fmt[-1] == TBLREST_KEY) {
      if (!tablefmt_get_string(&fmt, end, &key, &keylen)) return 0;
    } else {
      return 0;
    }
  }
  *pafter = fmt;
  return 1;
}

static int table_rest_excludes(const uint8_t *fmt, const uint8_t *end,
			       uint32_t count, cTValue *candidate)
{
  uint32_t i, index, keylen;
  const uint8_t *key;
  for (i = 0; i < count; i++) {
    if (fmt >= end) return 0;
    if (*fmt++ == TBLREST_POS) {
      if (!tablefmt_get_u32(&fmt, end, &index)) return 0;
      if (tvisint(candidate) && intV(candidate) == (int32_t)index)
	return 1;
    } else if (fmt[-1] == TBLREST_KEY) {
      if (!tablefmt_get_string(&fmt, end, &key, &keylen)) return 0;
      if (tvisstr(candidate) && strV(candidate)->len == keylen &&
	  (!keylen || memcmp(strdata(strV(candidate)), key, keylen) == 0))
	return 1;
    } else {
      return 0;
    }
  }
  return 0;
}

static int table_match_rest(lua_State *L, GCtab *table,
			    const uint8_t **pfmt, const uint8_t *end, int capture)
{
  const uint8_t *items, *after;
  uint32_t count;
  if (!tablefmt_get_u32(pfmt, end, &count))
    lj_err_callermsg(L, "invalid table pattern format");
  items = *pfmt;
  if (!tablefmt_rest_end(items, end, count, &after))
    lj_err_callermsg(L, "invalid table pattern format");
  *pfmt = after;
  if (capture) {
    GCtab *rest;
    TValue key, pair[2];
    int more;
    if (!lua_checkstack(L, 1)) lj_err_caller(L, LJ_ERR_STKOV);
    if (!table) {
      setnilV(L->top++);
      return 1;
    }
    rest = lj_tab_new(L, 0, 0);
    /* Root it before lj_tab_set() grows its array or hash part. */
    settabV(L, L->top++, rest);
    setnilV(&key);
    while ((more = lj_tab_next(table, &key, pair)) > 0) {
      if (!table_rest_excludes(items, after, count, &pair[0])) {
	copyTV(L, lj_tab_set(L, rest, &pair[0]), &pair[1]);
	lj_gc_anybarriert(L, rest);
      }
      copyTV(L, &key, &pair[0]);
    }
    if (more < 0) lj_err_callermsg(L, "invalid table pattern format");
  }
  return 1;
}

/* A NULL table means an optional parent was absent: bind nils and skip tests. */
static int table_match_node(lua_State *L, GCtab *table,
			    const uint8_t **pfmt, const uint8_t *end,
			    const TValue *pins, uint32_t npins,
			    TableMatchFailure *failure)
{
  const uint8_t *fmt = *pfmt;
  for (;;) {
    const uint8_t *key, *literal;
    uint32_t keylen, index, literal_len, intbits;
    uint64_t numbits;
    cTValue *value;
    int required;
    uint8_t opcode;

    if (fmt >= end) lj_err_callermsg(L, "invalid table pattern format");
    opcode = *fmt++;
    switch (opcode) {
    case TBLFMT_END:
      *pfmt = fmt;
      return 1;
    case TBLFMT_BIND_POS:
      if (fmt >= end) lj_err_callermsg(L, "invalid table pattern format");
      required = *fmt++;
      if (!tablefmt_get_u32(&fmt, end, &index))
	lj_err_callermsg(L, "invalid table pattern format");
      value = table ? lj_tab_getint(table, (int32_t)index) : NULL;
      if (!table_match_push(L, value, required && table != NULL)) {
	table_match_fail(L, failure, TBLFAIL_POS, index, NULL, 0); return 0;
      }
      break;
    case TBLFMT_BIND_KEY:
      if (fmt >= end) lj_err_callermsg(L, "invalid table pattern format");
      required = *fmt++;
      if (!tablefmt_get_string(&fmt, end, &key, &keylen))
	lj_err_callermsg(L, "invalid table pattern format");
      value = table ? table_match_key(L, table, key, keylen) : NULL;
      if (!table_match_push(L, value, required && table != NULL)) {
	table_match_fail(L, failure, TBLFAIL_KEY, 0, key, keylen); return 0;
      }
      break;
    case TBLFMT_SKIP_POS:
      if (fmt >= end) lj_err_callermsg(L, "invalid table pattern format");
      required = *fmt++;
      if (!tablefmt_get_u32(&fmt, end, &index))
	lj_err_callermsg(L, "invalid table pattern format");
      value = table ? lj_tab_getint(table, (int32_t)index) : NULL;
      if (required && table && (!value || tvisnil(value))) {
	table_match_fail(L, failure, TBLFAIL_POS, index, NULL, 0); return 0;
      }
      break;
    case TBLFMT_SKIP_KEY:
      if (fmt >= end) lj_err_callermsg(L, "invalid table pattern format");
      required = *fmt++;
      if (!tablefmt_get_string(&fmt, end, &key, &keylen))
	lj_err_callermsg(L, "invalid table pattern format");
      value = table ? table_match_key(L, table, key, keylen) : NULL;
      if (required && table && (!value || tvisnil(value))) {
	table_match_fail(L, failure, TBLFAIL_KEY, 0, key, keylen); return 0;
      }
      break;
    case TBLFMT_LITERAL_KEY:
      if (!tablefmt_get_string(&fmt, end, &key, &keylen) || fmt >= end)
	lj_err_callermsg(L, "invalid table pattern format");
      opcode = *fmt++;

      if (opcode > TBLLIT_NUM)
	lj_err_callermsg(L, "invalid table pattern format");
      if (opcode == TBLLIT_STRING &&
	  !tablefmt_get_string(&fmt, end, &literal, &literal_len))
	lj_err_callermsg(L, "invalid table pattern format");
      if (opcode == TBLLIT_INT &&
	  !tablefmt_get_u32(&fmt, end, &intbits))
	lj_err_callermsg(L, "invalid table pattern format");
      if (opcode == TBLLIT_NUM &&
	  !tablefmt_get_u64(&fmt, end, &numbits))
	lj_err_callermsg(L, "invalid table pattern format");
      if (!table) break;  /* An optional parent suppresses nested tests. */
      value = table_match_key(L, table, key, keylen);
      if (!table_match_literal(value, opcode, literal, literal_len,
			       intbits, numbits)) {
	table_match_fail(L, failure, TBLFAIL_KEY, 0, key, keylen); return 0;
      }
      break;
    case TBLFMT_LITERAL_POS:
      if (!tablefmt_get_u32(&fmt, end, &index) || fmt >= end)
	lj_err_callermsg(L, "invalid table pattern format");
      opcode = *fmt++;
      if (opcode > TBLLIT_NUM)
	lj_err_callermsg(L, "invalid table pattern format");
      if (opcode == TBLLIT_STRING &&
	  !tablefmt_get_string(&fmt, end, &literal, &literal_len))
	lj_err_callermsg(L, "invalid table pattern format");
      if (opcode == TBLLIT_INT &&
	  !tablefmt_get_u32(&fmt, end, &intbits))
	lj_err_callermsg(L, "invalid table pattern format");
      if (opcode == TBLLIT_NUM &&
	  !tablefmt_get_u64(&fmt, end, &numbits))
	lj_err_callermsg(L, "invalid table pattern format");
      if (!table) break;
      value = lj_tab_getint(table, (int32_t)index);
      if (!table_match_literal(value, opcode, literal, literal_len,
			       intbits, numbits)) {
	table_match_fail(L, failure, TBLFAIL_POS, index, NULL, 0); return 0;
      }
      break;
    case TBLFMT_PIN_POS:
      if (fmt >= end) lj_err_callermsg(L, "invalid table pattern format");
      required = *fmt++;
      if (!tablefmt_get_u32(&fmt, end, &index) ||
	  !tablefmt_get_u32(&fmt, end, &intbits))
	lj_err_callermsg(L, "invalid table pattern format");
      if (!table) break;
      value = lj_tab_getint(table, (int32_t)index);
      if (required && (!value || tvisnil(value))) {
	table_match_fail(L, failure, TBLFAIL_POS, index, NULL, 0); return 0;
      }
      if (!table_match_pin(value, pattern_pin_value(L, pins, npins, intbits))) {
	table_match_fail(L, failure, TBLFAIL_POS, index, NULL, 0); return 0;
      }
      break;
    case TBLFMT_PIN_KEY:
      if (fmt >= end) lj_err_callermsg(L, "invalid table pattern format");
      required = *fmt++;
      if (!tablefmt_get_string(&fmt, end, &key, &keylen) ||
	  !tablefmt_get_u32(&fmt, end, &intbits))
	lj_err_callermsg(L, "invalid table pattern format");
      if (!table) break;
      value = table_match_key(L, table, key, keylen);
      if (required && (!value || tvisnil(value))) {
	table_match_fail(L, failure, TBLFAIL_KEY, 0, key, keylen); return 0;
      }
      if (!table_match_pin(value, pattern_pin_value(L, pins, npins, intbits))) {
	table_match_fail(L, failure, TBLFAIL_KEY, 0, key, keylen); return 0;
      }
      break;
    case TBLFMT_REST:
      if (!table_match_rest(L, table, &fmt, end, 1)) return 0;
      break;
    case TBLFMT_SKIP_REST:
      if (!table_match_rest(L, table, &fmt, end, 0)) return 0;
      break;
    case TBLFMT_NEST_KEY:
      if (fmt >= end) lj_err_callermsg(L, "invalid table pattern format");
      required = *fmt++;
      if (!tablefmt_get_string(&fmt, end, &key, &keylen))
	lj_err_callermsg(L, "invalid table pattern format");
      value = table ? table_match_key(L, table, key, keylen) : NULL;
      if (!table) {
	if (!table_match_node(L, NULL, &fmt, end, pins, npins, failure)) return 0;
      } else if (!value || tvisnil(value)) {
	if (required) {
	  table_match_fail(L, failure, TBLFAIL_KEY, 0, key, keylen); return 0;
	}
	if (!table_match_node(L, NULL, &fmt, end, pins, npins, failure)) return 0;
      } else if (tvistab(value)) {
	if (!table_match_node(L, tabV(value), &fmt, end, pins, npins, failure)) return 0;
      } else {
	table_match_fail(L, failure, TBLFAIL_KEY, 0, key, keylen);
	return 0;
      }
      break;
    default:
      lj_err_callermsg(L, "invalid table pattern format");
    }
  }
}

int lj_pattern_table_match(lua_State *L, GCtab *table, GCstr *format,
			   const TValue *pins, uint32_t npins)
{
  const uint8_t *fmt = (const uint8_t *)strdata(format);
  const uint8_t *end = fmt + format->len;
  MSize top = (MSize)(L->top - L->base);
  TableMatchFailure failure;

  failure.kind = 0;
  if (!table_match_node(L, table, &fmt, end, pins, npins, &failure)) {
    if (failure.kind == TBLFAIL_KEY)
	lj_err_callermsg(L, lj_strfmt_pushf(L,
	  "table pattern match failed at key '%s'", strdata(failure.key)));
    if (failure.kind == TBLFAIL_POS)
	lj_err_callermsg(L, lj_strfmt_pushf(L,
	  "table pattern match failed at position %u", failure.position));
    lj_err_callermsg(L, "table pattern match failed");
  }
  if (fmt != end) lj_err_callermsg(L, "invalid table pattern format");
  lj_gc_check(L);
  return (int)((L->top - L->base) - top);
}

int lj_pattern_try_table_match(lua_State *L, TValue *input, GCstr *format,
			       const TValue *pins, uint32_t npins)
{
  const uint8_t *fmt = (const uint8_t *)strdata(format);
  const uint8_t *end = fmt + format->len;
  MSize top = (MSize)(L->top - L->base);

  if (tvistab(input)) {
    if (!lua_checkstack(L, 1)) lj_err_caller(L, LJ_ERR_STKOV);
    setboolV(L->top++, 1);
    if (table_match_node(L, tabV(input), &fmt, end, pins, npins, NULL) &&
	fmt == end) {
      lj_gc_check(L);
      return (int)((L->top - L->base) - top);
    }
  }
  L->top = L->base + top;
  setboolV(L->top++, 0);
  return 1;
}

static const TValue *bin_build_value(lua_State *L, const TValue *values,
				    uint32_t nvalues, uint32_t index)
{
  if (index >= nvalues)
    lj_err_callermsg(L, "invalid binary construction format");
  return values + index;
}

static lua_Number bin_build_number(lua_State *L, const TValue *value)
{
  if (tvisint(value)) return (lua_Number)intV(value);
  if (tvisnum(value)) return numV(value);
  lj_err_callermsg(L, "binary field must be a number");
  return 0;  /* Silence the compiler. */
}

static int bin_encode_int(lua_Number n, uint8_t nbits, int issigned,
			  uint64_t *out)
{
  uint64_t limit = (uint64_t)1 << nbits;
  if (issigned) {
    int64_t value;
    lua_Number min = -(lua_Number)((uint64_t)1 << (nbits-1));
    lua_Number max = (lua_Number)((uint64_t)1 << (nbits-1)) - 1.0;
    if (!(n >= min && n <= max && n == (lua_Number)(int64_t)n)) return 0;
    value = (int64_t)n;
    *out = (uint64_t)value & (limit-1);
  } else {
    lua_Number max = (lua_Number)limit - 1.0;
    if (!(n >= 0 && n <= max && n == (lua_Number)(uint64_t)n)) return 0;
    *out = (uint64_t)n;
  }
  return 1;
}

static int bin_encode_float16(lua_Number value, uint16_t *out)
{
  float f = (float)value;
  uint32_t word, mantissa, sign;
  int exp;
  LJ_STATIC_ASSERT(sizeof(f) == 4);
  memcpy(&word, &f, sizeof(f));
  if ((word & 0x7f800000) == 0x7f800000) return 0;
  sign = word >> 16 & 0x8000;
  mantissa = word & 0x007fffff;
  exp = (int)((word >> 23) & 0xff) - 127 + 15;
  if (exp >= 31) return 0;
  if (exp <= 0) {
    int shift;
    if ((word & 0x7fffffff) == 0) { *out = (uint16_t)sign; return 1; }
    if (exp < -10) return 0;
    mantissa |= 0x00800000;
    shift = 14-exp;
    *out = (uint16_t)(sign | ((mantissa + ((uint32_t)1 << (shift-1))) >> shift));
  } else {
    uint32_t half = sign | ((uint32_t)exp << 10) | ((mantissa + 0x1000) >> 13);
    if ((half & 0x7c00) == 0x7c00) return 0;
    *out = (uint16_t)half;
  }
  return 1;
}

static int bin_encode_float(lua_Number n, uint8_t nbits, uint64_t *out)
{
  if (nbits == 16) {
    uint16_t word;
    if (!bin_encode_float16(n, &word)) return 0;
    *out = word;
  } else if (nbits == 32) {
    float value = (float)n;
    uint32_t word;
    LJ_STATIC_ASSERT(sizeof(value) == 4);
    memcpy(&word, &value, sizeof(word));
    if ((word & 0x7f800000) == 0x7f800000) return 0;
    *out = word;
  } else if (nbits == 64) {
    double value = (double)n;
    uint64_t word;
    LJ_STATIC_ASSERT(sizeof(value) == 8);
    memcpy(&word, &value, sizeof(word));
    if ((word & U64x(7ff00000,00000000)) == U64x(7ff00000,00000000))
      return 0;
    *out = word;
  } else {
    return 0;
  }
  return 1;
}

static void bin_write_uint(SBuf *out, uint64_t value, uint8_t nbytes,
			   int little)
{
  uint8_t i;
  for (i = 0; i < nbytes; i++) {
    uint8_t byte = (uint8_t)(value >> (8 * (little ? i : nbytes-1-i)));
    lj_buf_putb(out, byte);
  }
}

int lj_pattern_bin_build(lua_State *L, GCstr *format,
			 const TValue *values, uint32_t nvalues)
{
  const uint8_t *fmt = (const uint8_t *)strdata(format);
  const uint8_t *fmtend = fmt + format->len;
  SBuf *out = lj_buf_tmp_(L);
  uint32_t value_index = 0;

  while (fmt < fmtend) {
    uint8_t opcode = *fmt++;
    uint32_t size;
    const TValue *value;
    switch (opcode) {
    case BINFMT_LITERAL:
      size = binfmt_get_u32(&fmt, fmtend);
      if (size == UINT32_MAX || (size_t)(fmtend-fmt) < size)
	lj_err_callermsg(L, "invalid binary construction format");
      lj_buf_putmem(out, fmt, size);
      fmt += size;
      break;
    case BINFMT_INT: {
      uint8_t nbits, flags;
      uint64_t bits;
      if ((size_t)(fmtend-fmt) < 2)
	lj_err_callermsg(L, "invalid binary construction format");
      nbits = *fmt++; flags = *fmt++;
      if (nbits < 8 || nbits > 48 || (nbits & 7) ||
	  flags & ~(BINFMT_F_LITTLE|BINFMT_F_SIGNED))
	lj_err_callermsg(L, "invalid binary construction format");
      value = bin_build_value(L, values, nvalues, value_index++);
      if (!bin_encode_int(bin_build_number(L, value), nbits,
			  flags & BINFMT_F_SIGNED, &bits))
	lj_err_callermsg(L, "integer does not fit binary field");
      bin_write_uint(out, bits, nbits >> 3, flags & BINFMT_F_LITTLE);
      break;
    }
    case BINFMT_FLOAT: {
      uint8_t nbits, flags;
      uint64_t bits;
      if ((size_t)(fmtend-fmt) < 2)
	lj_err_callermsg(L, "invalid binary construction format");
      nbits = *fmt++; flags = *fmt++;
      if ((nbits != 16 && nbits != 32 && nbits != 64) ||
	  flags & ~BINFMT_F_LITTLE)
	lj_err_callermsg(L, "invalid binary construction format");
      value = bin_build_value(L, values, nvalues, value_index++);
      if (!bin_encode_float(bin_build_number(L, value), nbits, &bits))
	lj_err_callermsg(L, "float does not fit binary field");
      bin_write_uint(out, bits, nbits >> 3, flags & BINFMT_F_LITTLE);
      break;
    }
    case BINFMT_BYTES:
      size = binfmt_get_u32(&fmt, fmtend);
      if (size == UINT32_MAX)
	lj_err_callermsg(L, "invalid binary construction format");
      value = bin_build_value(L, values, nvalues, value_index++);
      if (!tvisstr(value) || strV(value)->len != size)
	lj_err_callermsg(L, "binary field must be a string of the declared size");
      lj_buf_putstr(out, strV(value));
      break;
    case BINFMT_REST:
      value = bin_build_value(L, values, nvalues, value_index++);
      if (!tvisstr(value))
	lj_err_callermsg(L, "binary field must be a string");
      lj_buf_putstr(out, strV(value));
      break;
    case BINFMT_ARRAY: {
      uint8_t kind, nbits, flags;
      uint32_t count, i;
      GCtab *array;
      if ((size_t)(fmtend-fmt) < 3)
	lj_err_callermsg(L, "invalid binary construction format");
      kind = *fmt++; nbits = *fmt++; flags = *fmt++;
      count = binfmt_get_u32(&fmt, fmtend);
      if (count == UINT32_MAX || count > INT32_MAX ||
	  (kind != 0 && kind != 1) ||
	  (kind == 0 && (nbits < 8 || nbits > 48 || (nbits & 7) ||
			 flags & ~(BINFMT_F_LITTLE|BINFMT_F_SIGNED))) ||
	  (kind == 1 && ((nbits != 16 && nbits != 32 && nbits != 64) ||
			 flags & ~BINFMT_F_LITTLE)))
	lj_err_callermsg(L, "invalid binary construction format");
      value = bin_build_value(L, values, nvalues, value_index++);
      if (!tvistab(value))
	lj_err_callermsg(L, "binary vector field must be a table");
      array = tabV(value);
      for (i = 0; i < count; i++) {
	const TValue *element = lj_tab_getint(array, (int32_t)i+1);
	uint64_t bits;
	if (!element || tvisnil(element))
	  lj_err_callermsg(L, "binary vector has a missing element");
	if (kind == 0) {
	  if (!bin_encode_int(bin_build_number(L, element), nbits,
			      flags & BINFMT_F_SIGNED, &bits))
	    lj_err_callermsg(L, "integer does not fit binary vector field");
	} else {
	  if (!bin_encode_float(bin_build_number(L, element), nbits, &bits))
	    lj_err_callermsg(L, "float does not fit binary vector field");
	}
	bin_write_uint(out, bits, nbits >> 3, flags & BINFMT_F_LITTLE);
      }
      break;
    }
    default:
      lj_err_callermsg(L, "invalid binary construction format");
    }
  }
  if (value_index != nvalues)
    lj_err_callermsg(L, "invalid binary construction format");
  if (!lua_checkstack(L, 1)) lj_err_caller(L, LJ_ERR_STKOV);
  setstrV(L, L->top++, lj_str_new(L, out->b, sbuflen(out)));
  lj_gc_check(L);
  return 1;
}
