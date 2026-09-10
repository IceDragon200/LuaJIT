/*
** UTC date and time library.
** Local experimental extension.
** API direction informed by Erlang/OTP calendar and Elixir calendar values.
** This implementation was written independently for this fork.
*/

#define lib_datetime_c
#define LUA_LIB

#include "lj_arch.h"

#include <time.h>

#if LJ_TARGET_WINDOWS
#include <windows.h>
#elif LJ_TARGET_POSIX || LJ_TARGET_OSX
#include <sys/time.h>
#endif

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
UTC-only, proleptic-Gregorian date and time values.
Values are ordinary Lua tables so they remain easy to inspect and match.
@module datetime
@usage local datetime = require("datetime")
@see doc/ext_datetime.html
*/

#define DT_SECONDS_PER_DAY 86400
#define DT_UNIX_EPOCH_DAYS 719468

typedef struct {
  int year;
  int month;
  int day;
  int hour;
  int minute;
  int second;
  int microsecond;
} DateTimeFields;

static int datetime_invalid(lua_State *L, const char *message)
{
  lua_pushnil(L);
  lua_pushstring(L, message);
  return 2;
}

static int datetime_check_int(lua_State *L, int narg, int min, int max,
			      const char *name)
{
  lua_Number value = luaL_checknumber(L, narg);

  if (value < (lua_Number)min || value > (lua_Number)max ||
      value != (lua_Number)(int)value)
    luaL_error(L, "%s must be a whole number between %d and %d", name,
		min, max);
  return (int)value;
}

static int datetime_check_field(lua_State *L, int table, const char *name,
				int min, int max)
{
  lua_Number value;

  lua_getfield(L, table, name);
  if (lua_type(L, -1) != LUA_TNUMBER) {
    lua_pop(L, 1);
    luaL_error(L, "datetime value has no numeric %s field", name);
  }
  value = lua_tonumber(L, -1);
  lua_pop(L, 1);
  if (value < (lua_Number)min || value > (lua_Number)max ||
      value != (lua_Number)(int)value)
    luaL_error(L, "datetime value has an invalid %s field", name);
  return (int)value;
}

static int datetime_is_leap_year(int year)
{
  return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
}

static int datetime_last_day_of_month(int year, int month)
{
  static const uint8_t days[] = {
    31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
  };

  if (month == 2 && datetime_is_leap_year(year)) return 29;
  return days[month-1];
}

static int datetime_valid_date(int year, int month, int day)
{
  return year >= 0 && year <= 9999 && month >= 1 && month <= 12 &&
    day >= 1 && day <= datetime_last_day_of_month(year, month);
}

static int datetime_valid_time(int hour, int minute, int second,
			       int microsecond)
{
  return hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59 &&
    second >= 0 && second <= 59 && microsecond >= 0 && microsecond <= 999999;
}

/* Howard Hinnant's civil-date algorithms, using 1970-01-01 as day zero. */
static int64_t datetime_days_from_civil(int year, int month, int day)
{
  int64_t y = year - (month <= 2);
  int64_t era = (y >= 0 ? y : y - 399) / 400;
  unsigned yoe = (unsigned)(y - era * 400);
  unsigned mp = (unsigned)(month + (month > 2 ? -3 : 9));
  unsigned doy = (153 * mp + 2) / 5 + (unsigned)day - 1;
  unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;

  return era * 146097 + (int64_t)doe - DT_UNIX_EPOCH_DAYS;
}

static void datetime_civil_from_days(int64_t days, int *year, int *month,
				     int *day)
{
  int64_t z = days + DT_UNIX_EPOCH_DAYS;
  int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  unsigned doe = (unsigned)(z - era * 146097);
  unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  int64_t y = (int64_t)yoe + era * 400;
  unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  unsigned mp = (5 * doy + 2) / 153;

  *day = (int)(doy - (153 * mp + 2) / 5 + 1);
  *month = (int)(mp + (mp < 10 ? 3 : -9));
  *year = (int)(y + (*month <= 2));
}

static int64_t datetime_floor_div(int64_t value, int64_t divisor)
{
  if (value >= 0) return value / divisor;
  return -(((-value) + divisor - 1) / divisor);
}

static int datetime_fields_to_unix(const DateTimeFields *fields,
				    int64_t *seconds)
{
  if (!datetime_valid_date(fields->year, fields->month, fields->day) ||
      !datetime_valid_time(fields->hour, fields->minute, fields->second,
			   fields->microsecond))
    return 0;
  *seconds = datetime_days_from_civil(fields->year, fields->month, fields->day) *
    DT_SECONDS_PER_DAY + fields->hour * 3600 + fields->minute * 60 +
    fields->second;
  return 1;
}

static int datetime_fields_from_unix(int64_t seconds, int microsecond,
				     DateTimeFields *fields)
{
  int64_t days = datetime_floor_div(seconds, DT_SECONDS_PER_DAY);
  int64_t rest = seconds - days * DT_SECONDS_PER_DAY;

  datetime_civil_from_days(days, &fields->year, &fields->month, &fields->day);
  if (!datetime_valid_date(fields->year, fields->month, fields->day)) return 0;
  fields->hour = (int)(rest / 3600);
  fields->minute = (int)((rest % 3600) / 60);
  fields->second = (int)(rest % 60);
  fields->microsecond = microsecond;
  return 1;
}

static DateTimeFields datetime_check_fields(lua_State *L, int narg,
					     int with_time)
{
  DateTimeFields fields;

  luaL_checktype(L, narg, LUA_TTABLE);
  fields.year = datetime_check_field(L, narg, "year", 0, 9999);
  fields.month = datetime_check_field(L, narg, "month", 1, 12);
  fields.day = datetime_check_field(L, narg, "day", 1, 31);
  fields.hour = 0;
  fields.minute = 0;
  fields.second = 0;
  fields.microsecond = 0;
  if (!datetime_valid_date(fields.year, fields.month, fields.day))
    luaL_error(L, "datetime value has an invalid date");
  if (with_time) {
    fields.hour = datetime_check_field(L, narg, "hour", 0, 23);
    fields.minute = datetime_check_field(L, narg, "minute", 0, 59);
    fields.second = datetime_check_field(L, narg, "second", 0, 59);
    lua_getfield(L, narg, "microsecond");
    if (!lua_isnil(L, -1)) {
      if (lua_type(L, -1) != LUA_TNUMBER) {
	lua_pop(L, 1);
	luaL_error(L, "datetime value has an invalid microsecond field");
      }
      fields.microsecond = datetime_check_int(L, -1, 0, 999999,
					       "microsecond");
    }
    lua_pop(L, 1);
  }
  return fields;
}

static void datetime_set_number(lua_State *L, const char *field, int value)
{
  lua_pushnumber(L, (lua_Number)value);
  lua_setfield(L, -2, field);
}

static void datetime_push_date(lua_State *L, const DateTimeFields *fields)
{
  lua_createtable(L, 0, 3);
  datetime_set_number(L, "year", fields->year);
  datetime_set_number(L, "month", fields->month);
  datetime_set_number(L, "day", fields->day);
}

static void datetime_push_time(lua_State *L, const DateTimeFields *fields)
{
  lua_createtable(L, 0, 4);
  datetime_set_number(L, "hour", fields->hour);
  datetime_set_number(L, "minute", fields->minute);
  datetime_set_number(L, "second", fields->second);
  datetime_set_number(L, "microsecond", fields->microsecond);
}

static void datetime_push_naive(lua_State *L, const DateTimeFields *fields)
{
  lua_createtable(L, 0, 7);
  datetime_set_number(L, "year", fields->year);
  datetime_set_number(L, "month", fields->month);
  datetime_set_number(L, "day", fields->day);
  datetime_set_number(L, "hour", fields->hour);
  datetime_set_number(L, "minute", fields->minute);
  datetime_set_number(L, "second", fields->second);
  datetime_set_number(L, "microsecond", fields->microsecond);
}

static void datetime_push_utc(lua_State *L, const DateTimeFields *fields)
{
  datetime_push_naive(L, fields);
  lua_pushliteral(L, "Etc/UTC");
  lua_setfield(L, -2, "time_zone");
  lua_pushliteral(L, "UTC");
  lua_setfield(L, -2, "zone_abbr");
  datetime_set_number(L, "utc_offset", 0);
  datetime_set_number(L, "std_offset", 0);
}

static int datetime_is_utc(lua_State *L, int narg)
{
  GCstr *zone;

  if (lua_isnoneornil(L, narg)) return 1;
  zone = lj_lib_checkstr(L, narg);
  return zone->len == 7 && memcmp(strdata(zone), "Etc/UTC", 7) == 0;
}

static int64_t datetime_check_seconds(lua_State *L, int narg,
				      const char *name)
{
  lua_Number value = luaL_checknumber(L, narg);
  const lua_Number min = -62167219200.0;  /* 0000-01-01T00:00:00Z. */
  const lua_Number max = 253402300799.0;  /* 9999-12-31T23:59:59Z. */

  if (value < min || value > max || value != (lua_Number)(int64_t)value)
    luaL_error(L, "%s must be a whole Unix second in the supported range", name);
  return (int64_t)value;
}

static int datetime_wall_clock(int64_t *seconds, int *microsecond)
{
#if LJ_TARGET_WINDOWS
  FILETIME filetime;
  ULARGE_INTEGER ticks;
  const uint64_t epoch_offset = 116444736000000000ULL;

  GetSystemTimeAsFileTime(&filetime);
  ticks.LowPart = filetime.dwLowDateTime;
  ticks.HighPart = filetime.dwHighDateTime;
  if (ticks.QuadPart < epoch_offset) return 0;
  ticks.QuadPart -= epoch_offset;
  *seconds = (int64_t)(ticks.QuadPart / 10000000ULL);
  *microsecond = (int)((ticks.QuadPart % 10000000ULL) / 10ULL);
  return 1;
#elif LJ_TARGET_POSIX || LJ_TARGET_OSX
  struct timeval tv;

  if (gettimeofday(&tv, NULL) != 0) return 0;
  *seconds = (int64_t)tv.tv_sec;
  *microsecond = (int)tv.tv_usec;
  return 1;
#else
  time_t now = time(NULL);

  if (now == (time_t)-1) return 0;
  *seconds = (int64_t)now;
  *microsecond = 0;
  return 1;
#endif
}

static int datetime_parse_digits(const char *text, size_t start, size_t width,
				 int *value)
{
  size_t i;
  int n = 0;

  for (i = 0; i < width; i++) {
    unsigned char c = (unsigned char)text[start+i];
    if (c < '0' || c > '9') return 0;
    n = n * 10 + (c - '0');
  }
  *value = n;
  return 1;
}

static void datetime_put_digits(SBuf *out, int value, int width)
{
  char digits[6];
  int i;

  for (i = width - 1; i >= 0; i--) {
    digits[i] = (char)('0' + value % 10);
    value /= 10;
  }
  lj_buf_putmem(out, digits, (MSize)width);
}

static int datetime_parse_iso8601(const char *text, size_t length,
				  DateTimeFields *fields)
{
  size_t index = 19;
  int precision = 0;

  if (length < 20 || text[4] != '-' || text[7] != '-' ||
      (text[10] != 'T' && text[10] != 't') || text[13] != ':' ||
      text[16] != ':')
    return 0;
  if (!datetime_parse_digits(text, 0, 4, &fields->year) ||
      !datetime_parse_digits(text, 5, 2, &fields->month) ||
      !datetime_parse_digits(text, 8, 2, &fields->day) ||
      !datetime_parse_digits(text, 11, 2, &fields->hour) ||
      !datetime_parse_digits(text, 14, 2, &fields->minute) ||
      !datetime_parse_digits(text, 17, 2, &fields->second))
    return 0;
  fields->microsecond = 0;
  if (index < length && text[index] == '.') {
    index++;
    while (index < length && text[index] >= '0' && text[index] <= '9') {
      if (precision == 6) return 0;
      fields->microsecond = fields->microsecond * 10 + (text[index] - '0');
      precision++;
      index++;
    }
    if (precision == 0) return 0;
    while (precision < 6) {
      fields->microsecond *= 10;
      precision++;
    }
  }
  return index + 1 == length && text[index] == 'Z' &&
    datetime_valid_date(fields->year, fields->month, fields->day) &&
    datetime_valid_time(fields->hour, fields->minute, fields->second,
				fields->microsecond);
}

/* ------------------------------------------------------------------------ */

/***
Test whether a year is Gregorian leap year.
@function datetime.is_leap_year
@param year integer from 0 through 9999
@return boolean
*/
static int lj_cf_datetime_is_leap_year(lua_State *L)
{
  int year = datetime_check_int(L, 1, 0, 9999, "year");
  lua_pushboolean(L, datetime_is_leap_year(year));
  return 1;
}

/***
Construct a validated calendar date.
Invalid calendar combinations return `nil, message`; wrong argument types or
out-of-range fields raise ordinary Lua argument errors.
@function datetime.date
@param year integer from 0 through 9999
@param month integer from 1 through 12
@param day day of the month
@return date table, or nil and an explanation
*/
static int lj_cf_datetime_date(lua_State *L)
{
  DateTimeFields fields;

  fields.year = datetime_check_int(L, 1, 0, 9999, "year");
  fields.month = datetime_check_int(L, 2, 1, 12, "month");
  fields.day = datetime_check_int(L, 3, 1, 31, "day");
  if (!datetime_valid_date(fields.year, fields.month, fields.day))
    return datetime_invalid(L, "invalid date");
  datetime_push_date(L, &fields);
  return 1;
}

/***
Construct a validated time of day.
@function datetime.time
@param hour integer from 0 through 23
@param minute integer from 0 through 59
@param second integer from 0 through 59
@param[opt] microsecond integer from 0 through 999999, defaulting to zero
@return time table with hour, minute, second, and microsecond fields
*/
static int lj_cf_datetime_time(lua_State *L)
{
  DateTimeFields fields;

  fields.hour = datetime_check_int(L, 1, 0, 23, "hour");
  fields.minute = datetime_check_int(L, 2, 0, 59, "minute");
  fields.second = datetime_check_int(L, 3, 0, 59, "second");
  fields.microsecond = lua_isnoneornil(L, 4) ? 0 :
    datetime_check_int(L, 4, 0, 999999, "microsecond");
  datetime_push_time(L, &fields);
  return 1;
}

/***
Construct a validated timezone-free datetime value.
@function datetime.naive
@param year integer from 0 through 9999
@param month integer from 1 through 12
@param day day of the month
@param hour integer from 0 through 23
@param minute integer from 0 through 59
@param second integer from 0 through 59
@param[opt] microsecond integer from 0 through 999999, defaulting to zero
@return naive datetime table, or nil and an explanation for an invalid date
*/
static int lj_cf_datetime_naive(lua_State *L)
{
  DateTimeFields fields;

  fields.year = datetime_check_int(L, 1, 0, 9999, "year");
  fields.month = datetime_check_int(L, 2, 1, 12, "month");
  fields.day = datetime_check_int(L, 3, 1, 31, "day");
  fields.hour = datetime_check_int(L, 4, 0, 23, "hour");
  fields.minute = datetime_check_int(L, 5, 0, 59, "minute");
  fields.second = datetime_check_int(L, 6, 0, 59, "second");
  fields.microsecond = lua_isnoneornil(L, 7) ? 0 :
    datetime_check_int(L, 7, 0, 999999, "microsecond");
  if (!datetime_valid_date(fields.year, fields.month, fields.day))
    return datetime_invalid(L, "invalid date");
  datetime_push_naive(L, &fields);
  return 1;
}

/***
Attach the currently supported UTC zone to a naive datetime.
Only an omitted zone or `"Etc/UTC"` is accepted until a timezone database is
provided.
@function datetime.from_naive
@param naive table created by `datetime.naive` or with equivalent fields
@param[opt] zone `"Etc/UTC"`
@return UTC datetime table, or nil and an explanation
*/
static int lj_cf_datetime_from_naive(lua_State *L)
{
  DateTimeFields fields = datetime_check_fields(L, 1, 1);

  if (!datetime_is_utc(L, 2))
    return datetime_invalid(L, "time zone database unavailable");
  datetime_push_utc(L, &fields);
  return 1;
}

/***
Convert Unix seconds and an optional microsecond fraction to UTC.
@function datetime.from_unix
@param seconds integral Unix timestamp
@param[opt] microsecond integer from 0 through 999999
@param[opt] zone `"Etc/UTC"`
@return UTC datetime table, or nil and an explanation
*/
static int lj_cf_datetime_from_unix(lua_State *L)
{
  DateTimeFields fields;
  int64_t seconds = datetime_check_seconds(L, 1, "seconds");
  int microsecond = lua_isnoneornil(L, 2) ? 0 :
    datetime_check_int(L, 2, 0, 999999, "microsecond");

  if (!datetime_is_utc(L, 3))
    return datetime_invalid(L, "time zone database unavailable");
  if (!datetime_fields_from_unix(seconds, microsecond, &fields))
    return datetime_invalid(L, "Unix timestamp outside supported date range");
  datetime_push_utc(L, &fields);
  return 1;
}

/***
Read the current UTC wall clock.
@function datetime.utc_now
@return UTC datetime table with microsecond resolution where the platform provides it
*/
static int lj_cf_datetime_utc_now(lua_State *L)
{
  DateTimeFields fields;
  int64_t seconds;
  int microsecond;

  if (!datetime_wall_clock(&seconds, &microsecond) ||
      !datetime_fields_from_unix(seconds, microsecond, &fields))
    return luaL_error(L, "UTC wall clock unavailable");
  datetime_push_utc(L, &fields);
  return 1;
}

/***
Convert a datetime table to Unix seconds and microseconds.
@function datetime.to_unix
@param value UTC or equivalent datetime table
@return integral seconds, microsecond fraction
*/
static int lj_cf_datetime_to_unix(lua_State *L)
{
  DateTimeFields fields = datetime_check_fields(L, 1, 1);
  int64_t seconds;

  if (!datetime_fields_to_unix(&fields, &seconds))
    return luaL_error(L, "invalid datetime");
  lua_pushnumber(L, (lua_Number)seconds);
  lua_pushnumber(L, (lua_Number)fields.microsecond);
  return 2;
}

/***
Add calendar days to a date without using the host local timezone.
@function datetime.date_add
@param date validated date table
@param days integral calendar-day delta
@return date table, or nil and an explanation when outside the supported range
*/
static int lj_cf_datetime_date_add(lua_State *L)
{
  DateTimeFields fields = datetime_check_fields(L, 1, 0);
  int64_t days = datetime_days_from_civil(fields.year, fields.month, fields.day);
  int delta = datetime_check_int(L, 2, -4000000, 4000000, "days");

  datetime_civil_from_days(days + delta, &fields.year, &fields.month, &fields.day);
  if (!datetime_valid_date(fields.year, fields.month, fields.day))
    return datetime_invalid(L, "date outside supported range");
  datetime_push_date(L, &fields);
  return 1;
}

/***
Measure the signed calendar-day difference between two dates.
@function datetime.date_diff
@param left date table
@param right date table
@return signed number of days from right to left
*/
static int lj_cf_datetime_date_diff(lua_State *L)
{
  DateTimeFields left = datetime_check_fields(L, 1, 0);
  DateTimeFields right = datetime_check_fields(L, 2, 0);
  int64_t diff = datetime_days_from_civil(left.year, left.month, left.day) -
    datetime_days_from_civil(right.year, right.month, right.day);

  lua_pushnumber(L, (lua_Number)diff);
  return 1;
}

/***
Add integral seconds to a UTC datetime.
@function datetime.add
@param value UTC or equivalent datetime table
@param seconds signed integral second delta
@return UTC datetime table, or nil and an explanation when outside the supported range
*/
static int lj_cf_datetime_add(lua_State *L)
{
  DateTimeFields fields = datetime_check_fields(L, 1, 1);
  int64_t seconds;
  int64_t delta = datetime_check_seconds(L, 2, "seconds");

  if (!datetime_fields_to_unix(&fields, &seconds) ||
      !datetime_fields_from_unix(seconds + delta, fields.microsecond, &fields))
    return datetime_invalid(L, "datetime outside supported range");
  datetime_push_utc(L, &fields);
  return 1;
}

/***
Measure the normalized difference between two datetimes.
@function datetime.diff
@param left datetime table
@param right datetime table
@return signed seconds, non-negative microsecond remainder
*/
static int lj_cf_datetime_diff(lua_State *L)
{
  DateTimeFields left = datetime_check_fields(L, 1, 1);
  DateTimeFields right = datetime_check_fields(L, 2, 1);
  int64_t left_seconds, right_seconds;
  int64_t seconds;
  int microsecond;

  if (!datetime_fields_to_unix(&left, &left_seconds) ||
      !datetime_fields_to_unix(&right, &right_seconds))
    return luaL_error(L, "invalid datetime");
  seconds = left_seconds - right_seconds;
  microsecond = left.microsecond - right.microsecond;
  if (microsecond < 0) {
    seconds--;
    microsecond += 1000000;
  }
  lua_pushnumber(L, (lua_Number)seconds);
  lua_pushnumber(L, (lua_Number)microsecond);
  return 2;
}

/***
Order two datetime values by instant.
@function datetime.compare
@param left datetime table
@param right datetime table
@return -1, 0, or 1
*/
static int lj_cf_datetime_compare(lua_State *L)
{
  DateTimeFields left = datetime_check_fields(L, 1, 1);
  DateTimeFields right = datetime_check_fields(L, 2, 1);
  int64_t left_seconds, right_seconds;
  int result;

  if (!datetime_fields_to_unix(&left, &left_seconds) ||
      !datetime_fields_to_unix(&right, &right_seconds))
    return luaL_error(L, "invalid datetime");
  result = left_seconds < right_seconds ? -1 : left_seconds > right_seconds ? 1 :
    left.microsecond < right.microsecond ? -1 :
    left.microsecond > right.microsecond ? 1 : 0;
  lua_pushnumber(L, (lua_Number)result);
  return 1;
}

/***
Return the ISO weekday for a date.
@function datetime.day_of_week
@param date validated date table
@return integer from 1 for Monday through 7 for Sunday
*/
static int lj_cf_datetime_day_of_week(lua_State *L)
{
  DateTimeFields fields = datetime_check_fields(L, 1, 0);
  int64_t days = datetime_days_from_civil(fields.year, fields.month, fields.day);
  int day = (int)((days + 3) % 7);

  if (day < 0) day += 7;
  lua_pushnumber(L, (lua_Number)(day + 1));  /* Monday = 1, Sunday = 7. */
  return 1;
}

/***
Parse a strict UTC ISO-8601 datetime ending in `Z`.
@function datetime.from_iso8601
@param text ISO-8601 UTC text with up to six fractional digits
@return UTC datetime table, or nil and an explanation
*/
static int lj_cf_datetime_from_iso8601(lua_State *L)
{
  GCstr *input = lj_lib_checkstr(L, 1);
  DateTimeFields fields;

  if (!datetime_parse_iso8601(strdata(input), input->len, &fields))
    return datetime_invalid(L, "invalid UTC ISO 8601 datetime");
  datetime_push_utc(L, &fields);
  return 1;
}

/***
Format a datetime as a strict UTC ISO-8601 string ending in `Z`.
@function datetime.to_iso8601
@param value UTC or equivalent datetime table
@return ISO-8601 UTC string
*/
static int lj_cf_datetime_to_iso8601(lua_State *L)
{
  DateTimeFields fields = datetime_check_fields(L, 1, 1);
  SBuf *out = lj_buf_tmp_(L);

  datetime_put_digits(out, fields.year, 4);
  lj_buf_putb(out, '-');
  datetime_put_digits(out, fields.month, 2);
  lj_buf_putb(out, '-');
  datetime_put_digits(out, fields.day, 2);
  lj_buf_putb(out, 'T');
  datetime_put_digits(out, fields.hour, 2);
  lj_buf_putb(out, ':');
  datetime_put_digits(out, fields.minute, 2);
  lj_buf_putb(out, ':');
  datetime_put_digits(out, fields.second, 2);
  if (fields.microsecond != 0) {
    lj_buf_putb(out, '.');
    datetime_put_digits(out, fields.microsecond, 6);
  }
  lj_buf_putb(out, 'Z');
  setstrV(L, L->top++, lj_buf_str(L, out));
  lj_gc_check(L);
  return 1;
}

/***
Request a timezone representation for a datetime.
Only UTC is currently available; other named zones return `nil, message`
rather than silently consulting the host local timezone.
@function datetime.shift_zone
@param value datetime table
@param zone `"Etc/UTC"` or a future timezone name
@return UTC datetime table, or nil and an explanation
*/
static int lj_cf_datetime_shift_zone(lua_State *L)
{
  DateTimeFields fields = datetime_check_fields(L, 1, 1);

  if (!datetime_is_utc(L, 2))
    return datetime_invalid(L, "time zone database unavailable");
  datetime_push_utc(L, &fields);
  return 1;
}

/* ------------------------------------------------------------------------ */

/* These extensions use ordinary C functions, without fast-function IDs. */
static const luaL_Reg datetime_funcs[] = {
  {"is_leap_year", lj_cf_datetime_is_leap_year},
  {"date", lj_cf_datetime_date},
  {"time", lj_cf_datetime_time},
  {"naive", lj_cf_datetime_naive},
  {"from_naive", lj_cf_datetime_from_naive},
  {"from_unix", lj_cf_datetime_from_unix},
  {"utc_now", lj_cf_datetime_utc_now},
  {"to_unix", lj_cf_datetime_to_unix},
  {"date_add", lj_cf_datetime_date_add},
  {"date_diff", lj_cf_datetime_date_diff},
  {"add", lj_cf_datetime_add},
  {"diff", lj_cf_datetime_diff},
  {"compare", lj_cf_datetime_compare},
  {"day_of_week", lj_cf_datetime_day_of_week},
  {"from_iso8601", lj_cf_datetime_from_iso8601},
  {"to_iso8601", lj_cf_datetime_to_iso8601},
  {"shift_zone", lj_cf_datetime_shift_zone},
  {NULL, NULL}
};

LUALIB_API int luaopen_datetime(lua_State *L)
{
  luaL_register(L, LUA_DATETIMELIBNAME, datetime_funcs);
  return 1;
}
