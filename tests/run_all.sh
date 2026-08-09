#!/bin/bash
# Runs every test_*.sh in this directory and fails if any of them failed.
# test_extraction.sh must pass first — every other file depends on its
# extraction helpers being sound.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

overall=0
run_one() {
  echo "=== $1 ==="
  case "$1" in
    *.mjs) node "$1" ;;
    *.py) python3 "$1" ;;
    *) bash "$1" ;;
  esac
  local rc=$?
  echo
  [ "$rc" -eq 0 ] || overall=1
}

run_one test_extraction.sh
for f in test_*.sh test_*.mjs test_*.py; do
  [ "$f" = "test_extraction.sh" ] && continue
  run_one "$f"
done

if [ "$overall" -eq 0 ]; then
  echo "ALL TEST FILES PASSED"
else
  echo "SOME TEST FILES FAILED"
fi
exit $overall
