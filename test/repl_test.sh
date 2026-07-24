#!/bin/sh
#
# Interactive frontend integration tests.
#
# Copyright (C) 2026 LuaJIT contributors. See Copyright Notice in luajit.h
#

set -eu

interpreter=${1:-./src/luajit}

# -i forces the interactive frontend even though stdin is piped. Empty prompts
# make the transcript deterministic; the first two banner lines are intentionally
# discarded because they include build- and platform-dependent JIT details.
output=$(printf '%s\n' \
  '1 + 2' \
  'answer = 42' \
  'local ephemeral = 1' \
  'answer' \
  'string.byte("ab", 1, 2)' \
  '=10 * 2' \
  'if true then' \
  'answer = answer + 1' \
  'end' \
  'answer' | \
  "$interpreter" -e '_PROMPT = ""' -e '_PROMPT2 = ""' -i 2>&1)

actual=$(printf '%s\n' "$output" | sed '1,2d')
expected='3
warning: locals do not survive across lines in interactive mode
42
97	98
20
43'

if [ "$actual" != "$expected" ]; then
  printf '%s\n' 'unexpected REPL transcript:' >&2
  printf '%s\n' "$output" >&2
  exit 1
fi
