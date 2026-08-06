#!/bin/bash
# Shared helpers for the ai-review test suite. No dependencies beyond bash,
# awk, sed, jq — the same tools the engine itself uses, so a test failure
# here means the engine itself would fail the same way.
set -u

ENGINE="${ENGINE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/workflows/ai-review.yml}"

t_pass=0
t_fail=0

# t <name> <expected> <actual>
t() {
  if [ "$2" = "$3" ]; then
    t_pass=$((t_pass + 1))
    echo "ok   $1"
  else
    t_fail=$((t_fail + 1))
    echo "FAIL $1"
    echo "     expected: $2"
    echo "     actual:   $3"
  fi
}

t_summary() {
  echo
  echo "$t_pass passed, $t_fail failed"
  [ "$t_fail" -eq 0 ]
}

# Extracts the single `run: |` block scalar from the engine's one job/step
# as plain shell text, dedented. Depends only on the block being indented
# exactly 10 spaces per content line (verified once, in test_extraction.sh)
# — pure awk/sed so CI needs no YAML library.
extract_run() {
  awk '
    /^        run: \|$/ { grab=1; next }
    grab && (/^          / || /^[[:space:]]*$/) { print substr($0, 11); next }
    grab { exit }
  ' "$ENGINE"
}

# extract_between <start-literal> <end-literal>
# Prints the lines from the run block between the FIRST line CONTAINING
# start (inclusive) and the NEXT line CONTAINING end (inclusive) after it.
# Plain substring match (awk index()), not a regex — so a marker with
# jq/bash metacharacters ($, ", etc.) needs no escaping by the caller.
extract_between() {
  local start="$1" end="$2"
  extract_run | awk -v s="$start" -v e="$end" '
    index($0, s) { grab = 1 }
    grab { print }
    grab && index($0, e) { exit }
  '
}

# Prints the content between the FIRST and LAST single-quote in a block
# piped on stdin — i.e. the jq/awk program a bash `cmd '...'` call wraps.
# Bash single-quoted strings cannot contain an escaped quote, so this is
# unambiguous as long as the block contains exactly one quoted program
# (true for every jq/awk invocation this suite extracts — a second quoted
# span in the same block would make this wrong, so keep marker pairs tight
# around a single call).
extract_quoted() {
  python3 -c '
import sys
text = sys.stdin.read()
q = "\x27"
i = text.index(q) + 1
j = text.rindex(q)
sys.stdout.write(text[i:j])
'
}
