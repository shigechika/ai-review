#!/bin/bash
# Sanity-checks the extraction machinery every other test file depends on.
# If this fails, every other test's result is meaningless — run it first.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./lib.sh

run=$(extract_run)
t "extract_run non-empty"          "yes" "$([ -n "$run" ] && echo yes || echo no)"
t "extract_run starts correctly"   "yes" "$(printf '%s\n' "$run" | head -1 | grep -qF 'if [ -z "$PR" ]; then' && echo yes || echo no)"
t "extract_run has no blank gaps"  "yes" "$(printf '%s\n' "$run" | grep -q '^          #' && echo yes || echo no)"
t "extract_run reaches the end"    "yes" "$(printf '%s\n' "$run" | tail -5 | grep -q 'failed to post AI review comment' && echo yes || echo no)"

# The pure-awk extraction (used by every test) must match a from-scratch
# YAML-aware extraction, so a change to the block's indentation base (the
# hard-coded 10 spaces in lib.sh) fails loudly here instead of silently
# feeding every other test truncated or wrong content.
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  py_run=$(python3 -c "
import yaml
print(yaml.safe_load(open('$ENGINE'))['jobs']['review']['steps'][0]['run'], end='')
")
  t "extract_run matches PyYAML" "identical" "$([ "$run" = "$py_run" ] && echo identical || echo DIFFERS)"
else
  echo "skip PyYAML cross-check (PyYAML not installed) — not a failure"
fi

bash -n <(extract_run) 2>/tmp/extract_syntax_err.txt
t "extracted run block is valid bash" "0" "$?"
[ -s /tmp/extract_syntax_err.txt ] && cat /tmp/extract_syntax_err.txt

t_summary
