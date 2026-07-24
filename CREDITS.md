# Experimental fork credits and provenance

This document records the design sources for local experimental extensions. It
supplements, and never replaces, LuaJIT's upstream [COPYRIGHT](COPYRIGHT).

## Pattern matching and binary syntax

The pattern-matching syntax and semantics in `src/lj_pattern.c`,
`src/lj_pattern.h`, and the parser support around them are informed by Erlang
and Elixir pattern matching. Binary field concepts are informed by Erlang's
binary syntax. The implementation in this fork was written independently; no
OTP or Elixir runtime implementation code is incorporated.

## `binary` module

`src/lib_binary.c` borrows the API direction of Erlang/OTP's
`lib/stdlib/src/binary.erl`: literal byte operations, compiled patterns,
offset/length matches, splitting, replacement, and common-prefix/suffix
helpers. Lua strings have different ownership and slicing semantics, so the
module is an independent implementation rather than a port of OTP code.

## `datetime` module

`src/lib_datetime.c` takes its value shapes and UTC-only timezone boundary
from Elixir's `Date`, `Time`, `NaiveDateTime`, and `DateTime` APIs, and from
Erlang/OTP's `calendar` module. Its Gregorian conversion uses the civil-date
algorithm credited in the source to Howard Hinnant. The C implementation was
written independently; no Elixir or OTP implementation code is incorporated.

## Imported tests

See [test/THIRD_PARTY_NOTICES.md](test/THIRD_PARTY_NOTICES.md) for source
paths, commit identifiers, authorship, and license status for adopted test
material.
