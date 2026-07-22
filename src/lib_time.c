/*
** High-resolution time library.
** Local experimental extension.
*/

#define lib_time_c
#define LUA_LIB

#include "lj_arch.h"

#include <time.h>

#if LJ_TARGET_WINDOWS
#include <windows.h>
#elif LJ_TARGET_OSX
#include <mach/mach_time.h>
#include <sys/time.h>
#elif LJ_TARGET_POSIX
#include <sys/time.h>
#endif

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lj_obj.h"
#include "lj_lib.h"

/* ------------------------------------------------------------------------ */

#define LJLIB_MODULE_time

static int time_monotonic(lua_Number *seconds)
{
#if LJ_TARGET_WINDOWS
  static LARGE_INTEGER frequency;
  LARGE_INTEGER counter;

  if (frequency.QuadPart == 0 && !QueryPerformanceFrequency(&frequency))
    return 0;
  if (!QueryPerformanceCounter(&counter))
    return 0;
  *seconds = (lua_Number)counter.QuadPart / (lua_Number)frequency.QuadPart;
  return 1;
#elif LJ_TARGET_OSX
  static mach_timebase_info_data_t timebase;

  if (timebase.denom == 0 && mach_timebase_info(&timebase) != KERN_SUCCESS)
    return 0;
  *seconds = (lua_Number)mach_absolute_time() *
    ((lua_Number)timebase.numer / (lua_Number)timebase.denom) * 1e-9;
  return 1;
#elif LJ_TARGET_POSIX
  struct timespec ts;

  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
    return 0;
  *seconds = (lua_Number)ts.tv_sec + (lua_Number)ts.tv_nsec * 1e-9;
  return 1;
#else
  clock_t ticks = clock();

  if (ticks == (clock_t)-1)
    return 0;
  *seconds = (lua_Number)ticks * (1.0 / (lua_Number)CLOCKS_PER_SEC);
  return 1;
#endif
}

static int time_wall(lua_Number *seconds)
{
#if LJ_TARGET_WINDOWS
  FILETIME filetime;
  ULARGE_INTEGER ticks;
  const ULONGLONG epoch_offset = 116444736000000000ULL;
  const ULONGLONG ticks_per_second = 10000000ULL;

  GetSystemTimeAsFileTime(&filetime);
  ticks.LowPart = filetime.dwLowDateTime;
  ticks.HighPart = filetime.dwHighDateTime;
  ticks.QuadPart -= epoch_offset;
  *seconds = (lua_Number)(ticks.QuadPart / ticks_per_second) +
    (lua_Number)(ticks.QuadPart % ticks_per_second) * 1e-7;
  return 1;
#elif LJ_TARGET_OSX || LJ_TARGET_POSIX
  struct timeval tv;

  if (gettimeofday(&tv, NULL) != 0)
    return 0;
  *seconds = (lua_Number)tv.tv_sec + (lua_Number)tv.tv_usec * 1e-6;
  return 1;
#else
  time_t now = time(NULL);

  if (now == (time_t)-1)
    return 0;
  *seconds = (lua_Number)now;
  return 1;
#endif
}

/* ------------------------------------------------------------------------ */

LJLIB_CF(time_monotonic)
{
  lua_Number seconds;

  if (!time_monotonic(&seconds))
    return luaL_error(L, "monotonic clock unavailable");
  setnumV(L->top++, seconds);
  return 1;
}

LJLIB_CF(time_wall)
{
  lua_Number seconds;

  if (!time_wall(&seconds))
    return luaL_error(L, "wall clock unavailable");
  setnumV(L->top++, seconds);
  return 1;
}

LJLIB_CF(time_cpu)
{
  clock_t ticks = clock();

  if (ticks == (clock_t)-1)
    return luaL_error(L, "CPU clock unavailable");
  setnumV(L->top++, (lua_Number)ticks * (1.0 / (lua_Number)CLOCKS_PER_SEC));
  return 1;
}

/* ------------------------------------------------------------------------ */

#include "lj_libdef.h"

LUALIB_API int luaopen_time(lua_State *L)
{
  LJ_LIB_REG(L, "time", time);
  return 1;
}
