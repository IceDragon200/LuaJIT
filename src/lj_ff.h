/*
** Fast function IDs.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
*/

#ifndef _LJ_FF_H
#define _LJ_FF_H

/* Fast function ID. */
typedef enum {
  FF_LUA_ = FF_LUA,	/* Lua function (must be 0). */
  FF_C_ = FF_C,		/* Regular C function (must be 1). */
#define FFDEF(name)	FF_##name,
#include "lj_ffdef.h"
  FF__MAX
} FastFunc;

/* Indices into the existing assembly fast-function bytecode table. */
typedef enum {
#define FFDEF(name)
#define FFASMDEF(name, index)	FFASM_##name = index,
#include "lj_ffdef.h"
#undef FFASMDEF
  FFASM__MAX
} FastFuncASM;

#endif
