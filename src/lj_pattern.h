/*
** Pattern matching support.
** Local experimental extension.
** Syntax and semantics are informed by Erlang and Elixir pattern matching.
** This implementation was written independently for this fork.
*/

#ifndef _LJ_PATTERN_H
#define _LJ_PATTERN_H

#include "lj_obj.h"

/* Binary descriptor opcodes emitted by the parser. */
enum {
  BINFMT_LITERAL = 1,
  BINFMT_INT,
  BINFMT_FLOAT,
  BINFMT_BYTES,
  BINFMT_REST,
  BINFMT_SKIP_INT,
  BINFMT_SKIP_FLOAT,
  BINFMT_SKIP_BYTES,
  BINFMT_SKIP_REST,
  BINFMT_PIN_LITERAL,
  BINFMT_PIN_INT,
  BINFMT_PIN_FLOAT,
  BINFMT_PIN_BYTES,
  BINFMT_PIN_REST,
  BINFMT_ARRAY,
  BINFMT_SKIP_ARRAY,
  BINFMT_LITERAL_INT,
  BINFMT_LITERAL_FLOAT
};

/* Flags following the bit width on integer and float descriptors. */
#define BINFMT_F_LITTLE	0x01
#define BINFMT_F_SIGNED	0x02

/* Recursive table descriptor opcodes emitted by the parser. */
enum {
  TBLFMT_END = 0,
  TBLFMT_BIND_POS,
  TBLFMT_BIND_KEY,
  TBLFMT_LITERAL_KEY,
  TBLFMT_NEST_KEY,
  TBLFMT_SKIP_POS,
  TBLFMT_SKIP_KEY,
  TBLFMT_LITERAL_POS,
  TBLFMT_PIN_POS,
  TBLFMT_PIN_KEY,
  TBLFMT_REST,
  TBLFMT_SKIP_REST
};

enum {
  TBLLIT_NIL = 0,
  TBLLIT_FALSE,
  TBLLIT_TRUE,
  TBLLIT_STRING,
  TBLLIT_INT,
  TBLLIT_NUM
};

#define TBLREST_POS	0
#define TBLREST_KEY	1

LJ_FUNC int lj_pattern_bin_match(lua_State *L, GCstr *input, GCstr *format,
				 const TValue *pins, uint32_t npins);
LJ_FUNC int lj_pattern_try_bin_match(lua_State *L, TValue *input,
				     GCstr *format, const TValue *pins, uint32_t npins);
LJ_FUNC int lj_pattern_table_match(lua_State *L, GCtab *table, GCstr *format,
				   const TValue *pins, uint32_t npins);
LJ_FUNC int lj_pattern_try_table_match(lua_State *L, TValue *input,
				       GCstr *format, const TValue *pins, uint32_t npins);
LJ_FUNC int lj_pattern_bin_build(lua_State *L, GCstr *format,
				 const TValue *values, uint32_t nvalues);

#endif
