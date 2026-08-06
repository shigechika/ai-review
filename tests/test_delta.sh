#!/bin/bash
# Delta-round detection: the strictly-ahead guard, DELTA_FILES scoping, and
# the byte-budget clamp/input-parsing invariants around it.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./lib.sh

# ---------- Strictly-ahead guard must precede docs-only skip AND delta mode ----------
run=$(extract_run)
guard_line=$(printf '%s\n' "$run" | grep -n 'cstatus" != "ahead"' | head -1 | cut -d: -f1)
docs_line=$(printf '%s\n' "$run" | grep -n 'docs-only delta since' | head -1 | cut -d: -f1)
delta_line=$(printf '%s\n' "$run" | grep -n 'DELTA_MODE=1' | tail -1 | cut -d: -f1)
t "ahead-guard precedes docs-only skip" "yes" "$([ -n "$guard_line" ] && [ "$guard_line" -lt "$docs_line" ] && echo yes || echo no)"
t "ahead-guard precedes delta mode"     "yes" "$([ -n "$guard_line" ] && [ "$guard_line" -lt "$delta_line" ] && echo yes || echo no)"
t "docs-mode PRs skip the docs-only-delta exit" "yes" \
  "$(grep -qF 'DOCS_MODE" != "1"' "$ENGINE" && echo yes || echo no)"

# ---------- DELTA_FILES: same jq expression the engine uses ----------
compare='{"files":[
  {"filename":"a.py","status":"modified"},
  {"filename":"b.py","status":"added"},
  {"filename":"gone.py","status":"removed"},
  {"filename":"new_name.py","status":"renamed","previous_filename":"old_name.py"}
]}'
got=$(printf '%s' "$compare" | jq -r '.files[]? | select(.status != "removed") | .filename' | paste -sd, -)
t "delta files: excludes removed"      "a.py,b.py,new_name.py" "$got"
got=$(printf '%s' '{}' | jq -r '.files[]? | select(.status != "removed") | .filename' | paste -sd, -)
t "delta files: empty compare -> empty" "" "$got"
t "engine: DELTA_FILES uses this exact filter" "yes" \
  "$(grep -qF 'select(.status != "removed") | .filename' "$ENGINE" && echo yes || echo no)"

# ---------- FILES_TOTAL_CAP input parsing (leading-zero octal, R1F3 fix) ----------
resolve_cap() {
  local FILES_TOTAL_CAP=131072 FILES_TOTAL_CAP_INPUT=$1
  case "$FILES_TOTAL_CAP_INPUT" in
    ''|*[!0-9]*) : ;;
    *) FILES_TOTAL_CAP=$((10#$FILES_TOTAL_CAP_INPUT)) ;;
  esac
  local probe=$((FILES_TOTAL_CAP - 1)) || return 1
  : "$probe"
  echo "$FILES_TOTAL_CAP"
}
t "cap input: default on empty"        "131072" "$(resolve_cap '')"
t "cap input: default on garbage"      "131072" "$(resolve_cap 'abc')"
t "cap input: default on negative"     "131072" "$(resolve_cap '-1')"
t "cap input: override numeric"        "65536"  "$(resolve_cap 65536)"
t "cap input: override zero"           "0"      "$(resolve_cap 0)"
t "cap input: leading zero not octal"  "80000"  "$(resolve_cap '080000')"
t "engine: uses base-10 marker"        "yes" "$(grep -qF '10#$FILES_TOTAL_CAP_INPUT' "$ENGINE" && echo yes || echo no)"

# ---------- Budget clamp invariant (hard bound on attachment bytes) ----------
simulate() { # cap sizes...
  local FILES_TOTAL_CAP=$1 FILE_CAP=49152 FILE_COUNT_CAP=15
  shift
  local files_total=0 files_n=0 remaining cap fsent
  for fsize in "$@"; do
    remaining=$((FILES_TOTAL_CAP - files_total))
    if [ "$files_n" -ge "$FILE_COUNT_CAP" ] || [ "$remaining" -le 0 ]; then continue; fi
    cap=$FILE_CAP
    [ "$cap" -le "$remaining" ] || cap=$remaining
    fsent=$fsize
    [ "$fsent" -le "$cap" ] || fsent=$cap
    files_total=$((files_total + fsent))
    files_n=$((files_n + 1))
  done
  echo "$files_total $files_n"
}
t "clamp: hard bound holds across 3 max-size files" "131072 3" "$(simulate 131072 49152 49152 49152)"
t "clamp: 16 small files -> only 15 attach"          "15000 15" "$(simulate 131072 $(for i in $(seq 16); do printf '1000 '; done))"
t "clamp: no attach once remaining hits zero"        "131072 3" "$(simulate 131072 49152 49152 32768 100)"

t_summary
