#!/bin/bash
# Import-following attachment: the Python import resolver is extracted from
# the engine between its anchor comments and exercised directly — never a
# hand-typed mirror. Structural checks then pin where the engine calls it.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./lib.sh

# The extraction must be non-empty as its OWN check first: an anchor that
# stops matching would otherwise make every negative assertion below pass
# vacuously (see CLAUDE.md, "awk range vacuous pass").
extract_between '# ---- py_import_candidates ----' '# ---- end py_import_candidates ----' > /tmp/pic_block.sh
t "resolver block extracted (non-empty)" "yes" "$([ -s /tmp/pic_block.sh ] && echo yes || echo no)"
t "resolver block defines the function"  "yes" "$(grep -qF 'py_import_candidates() {' /tmp/pic_block.sh && echo yes || echo no)"

# The awk program sits in a single-quoted shell string: an apostrophe
# anywhere inside it (comments included) ends the string early.
sed -n '/^py_import_candidates() {/,/^}/p' /tmp/pic_block.sh | extract_quoted > /tmp/pic_prog.awk
t "resolver program extracted (non-empty)" "yes" "$([ -s /tmp/pic_prog.awk ] && echo yes || echo no)"
t "resolver program has no apostrophes"    "0"   "$(grep -c "'" /tmp/pic_prog.awk)"

# shellcheck disable=SC1091
. /tmp/pic_block.sh

resolve() { # <importing-file> <python-source>  (pr file list from /tmp/pic_prfiles.txt)
  printf '%s\n' "$2" | py_import_candidates "$1" /tmp/pic_prfiles.txt
}
has() { grep -qxF "$1" /tmp/pic_out.txt && echo yes || echo no; }

printf 'src/pkg/mod.py\ntests/test_mod.py\n' > /tmp/pic_prfiles.txt

# ---------- Relative imports: resolved against the importing file ----------
resolve src/pkg/mod.py $'from .util import helper, Klass\nfrom .. import base' > /tmp/pic_out.txt
t "relative: module file"                    "yes" "$(has src/pkg/util.py)"
t "relative: package __init__"               "yes" "$(has src/pkg/util/__init__.py)"
t "relative: lower-case name as submodule"   "yes" "$(has src/pkg/util/helper.py)"
t "relative: Capitalized name is a symbol"   "no"  "$(has src/pkg/util/Klass.py)"
t "relative: double-dot climbs one level"    "yes" "$(has src/base.py)"

# `from .. import x` at the repository root has nowhere to climb to.
resolve main.py $'from . import sibling\nfrom .. import toohigh' > /tmp/pic_out.txt
t "relative at root: sibling resolved"       "yes" "$(has sibling.py)"
t "relative above root: dropped"             "no"  "$(has toohigh.py)"
t "relative above root: no leading slash"    "0"   "$(grep -c '^/' /tmp/pic_out.txt)"

# ---------- Absolute imports anchored on the importing file path ----------
resolve src/pkg/mod.py $'from pkg.core import run as r\nimport pkg.sub.deep' > /tmp/pic_out.txt
t "anchored: root taken from own path"       "yes" "$(has src/pkg/core.py)"
t "anchored: aliased name still resolved"    "yes" "$(has src/pkg/core/run.py)"
t "anchored: dotted import"                  "yes" "$(has src/pkg/sub/deep.py)"
# Since R1F1 the root/src fallback is always added BEHIND the anchored
# candidate — anchored first, so the budget bites the guess, not the hit.
t "anchored: precedes the root-level fallback" "src/pkg/core.py pkg/core.py" \
  "$(grep -E '^(src/)?pkg/core\.py$' /tmp/pic_out.txt | tr '\n' ' ' | sed 's/ $//')"

# ---------- Tests-only PR: anchor comes from the PR file list ----------
resolve tests/test_mod.py 'from pkg.core import run' > /tmp/pic_out.txt
t "list-anchored: pkg root found via prfiles" "yes" "$(has src/pkg/core.py)"

# ---------- Unknown top package: root and src/ fallback, nothing more ----------
resolve tests/test_mod.py 'import other_pkg.thing' > /tmp/pic_out.txt
t "fallback: repo root"                      "yes" "$(has other_pkg/thing.py)"
t "fallback: src/"                           "yes" "$(has src/other_pkg/thing.py)"
# root, src/ and the importing file directory (tests/), .py + __init__ each
t "fallback: importing file directory"       "yes" "$(has tests/other_pkg/thing.py)"
t "fallback: exactly 6 candidates"           "6"   "$(wc -l < /tmp/pic_out.txt | tr -d ' ')"

# ---------- Selftest findings on PR #60 ----------
# R1F1: a nested tests package (tests/pkg/test_core.py) anchored `pkg`
# under tests/ and, being the first root seen, hid src/pkg/ entirely.
printf 'tests/pkg/test_core.py\n' > /tmp/pic_prfiles.txt
resolve tests/pkg/test_core.py 'from pkg.core import run' > /tmp/pic_out.txt
t "R1F1: nested tests root is tried"         "yes" "$(has tests/pkg/core.py)"
t "R1F1: src/ fallback is still tried"       "yes" "$(has src/pkg/core.py)"
t "R1F1: repo-root fallback is still tried"  "yes" "$(has pkg/core.py)"
t "R1F1: anchored candidate comes first"     "tests/pkg/core.py" "$(head -1 /tmp/pic_out.txt)"
# Both roots survive when the PR list carries a second one.
printf 'tests/pkg/test_core.py\nlib/pkg/core.py\n' > /tmp/pic_prfiles.txt
resolve tests/pkg/test_core.py 'from pkg.core import run' > /tmp/pic_out.txt
t "R1F1: second root from the PR list kept"  "yes" "$(has lib/pkg/core.py)"
printf 'src/pkg/mod.py\ntests/test_mod.py\n' > /tmp/pic_prfiles.txt
# R1F2: a lower-case imported name was tried as name.py but never as
# name/__init__.py, so an imported subpackage was never attached.
resolve src/pkg/mod.py 'from app import plugins' > /tmp/pic_out.txt
t "R1F2: imported name as module"            "yes" "$(has app/plugins.py)"
t "R1F2: imported name as package"           "yes" "$(has app/plugins/__init__.py)"

# ---------- Script-directory imports (codex review of PR #60) ----------
# `python scripts/main.py` puts scripts/ on sys.path, so its `import util`
# means scripts/util.py — a fallback root alongside the repo root and src/.
printf 'scripts/main.py\n' > /tmp/pic_prfiles.txt
resolve scripts/main.py 'import util' > /tmp/pic_out.txt
t "script dir: importing file directory tried"  "yes" "$(has scripts/util.py)"
t "script dir: repo root still tried"            "yes" "$(has util.py)"
t "script dir: after src/, before any __init__"  "yes" \
  "$([ "$(grep -nxF src/util.py /tmp/pic_out.txt | cut -d: -f1)" -lt "$(grep -nxF scripts/util.py /tmp/pic_out.txt | cut -d: -f1)" ] && [ "$(grep -nxF scripts/util.py /tmp/pic_out.txt | cut -d: -f1)" -lt "$(grep -nxF util/__init__.py /tmp/pic_out.txt | cut -d: -f1)" ] && echo yes || echo no)"
# R7F1: with the own-dir variant in its own rank, 14 imports from
# tests/test_mod.py still get every src/ module inside the 40-entry cap.
src=''
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do src="$src"$'\n'"import m$i"; done
printf 'tests/test_mod.py\n' > /tmp/pic_prfiles.txt
resolve tests/test_mod.py "$src" > /tmp/pic_out.txt
t "R7F1: every src/ module is a candidate with 14 imports" "14" "$(grep -c '^src/m[0-9]*\.py$' /tmp/pic_out.txt)"
t "R8F1: every own-dir module is a candidate with 14 imports" "14" "$(grep -c '^tests/m[0-9]*\.py$' /tmp/pic_out.txt)"
resolve main.py 'import util' > /tmp/pic_out.txt
t "script dir: root file adds no duplicate"      "1"   "$(grep -cxF util.py /tmp/pic_out.txt)"
printf 'src/pkg/mod.py\ntests/test_mod.py\n' > /tmp/pic_prfiles.txt

# ---------- Noise that must produce nothing ----------
resolve src/pkg/mod.py $'import os, sys\nfrom typing import Any\n# import commented\nprint("from x import y")\nfrom __future__ import annotations' > /tmp/pic_out.txt
t "stdlib and comments: nothing emitted"     "0"   "$(wc -l < /tmp/pic_out.txt | tr -d ' ')"

# ---------- Strings and the stdlib list (codex terra/luna on PR #60) ----------
resolve src/pkg/mod.py $'"""Example:\n    import private_config\n"""\nimport real_one\nx = """import inline_a"""\ny = \x27\x27\x27\nimport inside_single\n\x27\x27\x27\nimport real_two' > /tmp/pic_out.txt
t "strings: import inside a docstring ignored"      "no"  "$(has private_config.py)"
t "strings: import inside single-quoted triple ignored" "no" "$(has inside_single.py)"
t "strings: one-line triple string does not flip state" "yes" "$(has real_one.py)"
t "strings: import after the string still resolved"  "yes" "$(has real_two.py)"
resolve src/pkg/mod.py 'from typing_extensions import Self' > /tmp/pic_out.txt
t "stdlib list: typing_extensions is resolved (not stdlib)" "yes" "$(has typing_extensions.py)"
# R9F1: a comment line mentioning a triple quote must not flip the
# string state and swallow every import after it.
resolve src/pkg/mod.py $'# see the """ docstring below\nimport after_comment\n    # indented """ too\nimport after_indented' > /tmp/pic_out.txt
t "R9F1: import after a comment containing triple quotes" "yes" "$(has after_comment.py)"
t "R9F1: import after an indented such comment"          "yes" "$(has after_indented.py)"
# R11F1: inside a string a `# """` line is content and may close it.
resolve src/pkg/mod.py $'x = """\n# """\nimport after_close' > /tmp/pic_out.txt
t "R11F1: hash-prefixed closing delimiter inside a string" "yes" "$(has after_close.py)"

# ---------- Shape details ----------
resolve src/pkg/mod.py $'import httpx\nfrom .util import a\nfrom pkg.core import b' > /tmp/pic_out.txt
t "order: relative before anchored before fallback" "src/pkg/util.py src/pkg/core.py httpx.py" \
  "$(grep -E '^(src/pkg/util\.py|src/pkg/core\.py|httpx\.py)$' /tmp/pic_out.txt | tr '\n' ' ' | sed 's/ $//')"
resolve src/pkg/mod.py $'def f():\n    from .lazy import x\nimport a.b, c.d as e' > /tmp/pic_out.txt
t "indented import inside a function"        "yes" "$(has src/pkg/lazy.py)"
t "comma-separated import: first"            "yes" "$(has src/a/b.py)"
t "comma-separated import: aliased second"   "yes" "$(has src/c/d.py)"
resolve src/pkg/mod.py $'from .util import a\nfrom .util import a' > /tmp/pic_out.txt
t "duplicates collapsed"                     "1"   "$(grep -cxF src/pkg/util.py /tmp/pic_out.txt)"

# ---------- Ordering under the candidate cap ----------
# Module candidates of every tier come before any name-as-submodule guess,
# so six imports with several names each cannot push the sixth module
# (or the src/ fallback of the first) past the 40-entry cap.
src=''
for m in one two three four five six; do src="$src"$'\n'"from pkg.$m import alpha, beta, gamma, delta"; done
resolve tests/test_mod.py "$src" > /tmp/pic_out.txt
last_mod=$(grep -nxF 'src/pkg/six.py' /tmp/pic_out.txt | cut -d: -f1)
first_guess=$(grep -n '/alpha\.py$' /tmp/pic_out.txt | head -1 | cut -d: -f1)
t "order: last module precedes first name guess" "yes" \
  "$([ -n "$last_mod" ] && [ -n "$first_guess" ] && [ "$last_mod" -lt "$first_guess" ] && echo yes || echo no)"
t "order: every module candidate within the cap" "yes" \
  "$([ "$(grep -n -E '^(src/)?pkg/(one|two|three|four|five|six)(\.py|/__init__\.py)$' /tmp/pic_out.txt | tail -1 | cut -d: -f1)" -le 40 ] && echo yes || echo no)"
# `from . import x` names ARE modules — they stay in the first tier.
resolve src/pkg/mod.py $'from . import bare\nfrom pkg.core import guess' > /tmp/pic_out.txt
t "order: bare relative name stays ahead of name guesses" "yes" \
  "$([ "$(grep -nxF src/pkg/bare.py /tmp/pic_out.txt | cut -d: -f1)" -lt "$(grep -nxF src/pkg/core/guess.py /tmp/pic_out.txt | cut -d: -f1)" ] && echo yes || echo no)"

# R3F1: a path first recorded as a name guess (tier 6) must be PROMOTED
# when a later statement imports it directly, not rejected as already
# seen. With nine unrelated imports in between this is also the case the
# breadth-first order exists for: depth-first, four candidates per import
# put pkg/sub.py at position 41 even after promotion.
src='from pkg import sub, helper'
for m in a b c d e f g h i; do src="$src"$'\n'"import other_$m"; done
src="$src"$'\n''import pkg.sub'
resolve tests/test_mod.py "$src" > /tmp/pic_out.txt
pos_sub=$(grep -nxF pkg/sub.py /tmp/pic_out.txt | cut -d: -f1)
pos_guess=$(grep -nxF pkg/helper.py /tmp/pic_out.txt | cut -d: -f1)
t "R3F1: directly imported module promoted ahead of the remaining guess" "yes" \
  "$([ -n "$pos_sub" ] && [ -n "$pos_guess" ] && [ "$pos_sub" -lt "$pos_guess" ] && echo yes || echo no)"
t "R3F1: promoted path printed exactly once"  "1" "$(grep -cxF pkg/sub.py /tmp/pic_out.txt)"
# Breadth-first within a tier: every import as mod.py before any as
# src/mod.py, and both before the __init__ forms.
t "breadth-first: all root .py before the first src/ variant" "yes" \
  "$([ "$(grep -nxF other_i.py /tmp/pic_out.txt | cut -d: -f1)" -lt "$(grep -nxF src/other_a.py /tmp/pic_out.txt | cut -d: -f1)" ] && echo yes || echo no)"
t "breadth-first: src .py before the first __init__" "yes" \
  "$([ "$(grep -nxF src/other_i.py /tmp/pic_out.txt | cut -d: -f1)" -lt "$(grep -nxF other_a/__init__.py /tmp/pic_out.txt | cut -d: -f1)" ] && echo yes || echo no)"

# ---------- Root-level package is a real root (empty prefix) ----------
# A string-joined root set dropped the empty prefix; the always-on
# fallback masked it. With counted roots pkg/core.py is an ANCHORED
# candidate and therefore precedes the src/ fallback.
printf 'pkg/core.py\ntests/test_mod.py\n' > /tmp/pic_prfiles.txt
resolve tests/test_mod.py 'from pkg.core import run' > /tmp/pic_out.txt
t "empty-prefix root: anchored before src/ fallback" "pkg/core.py src/pkg/core.py" \
  "$(grep -E '^(src/)?pkg/core\.py$' /tmp/pic_out.txt | tr '\n' ' ' | sed 's/ $//')"
printf 'src/pkg/mod.py\ntests/test_mod.py\n' > /tmp/pic_prfiles.txt

# ---------- Engine wiring ----------
extract_run > /tmp/pic_run.sh
t "engine: imports collected only for *.py, never in docs-mode" "yes" \
  "$(grep -A1 -F 'if [ "${f%.py}" != "$f" ] && [ "$DOCS_MODE" != "1" ]; then' /tmp/pic_run.sh | grep -qF 'py_import_candidates "$f" prfiles.txt < fbody.txt >> imports_raw.txt' && echo yes || echo no)"
t "engine: changed files attached before imports" "yes" \
  "$(awk '/attach_from_list attach_list.txt changed/ {c=NR} /attach_from_list attach_imports.txt imported/ {i=NR} END {exit !(c && i && c < i)}' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: a file from this round is never re-attached as an import" "yes" \
  "$(grep -qF 'grep -vxF -f attach_list.txt -f prfiles.txt' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: nor a file changed in an earlier round (delta header honesty)" "yes" \
  "$(grep -F 'grep -vxF -f attach_list.txt' /tmp/pic_run.sh | grep -qF -- '-f prfiles.txt' && echo yes || echo no)"
t "engine: imported header does not claim the file is unchanged" "no" \
  "$(grep -F 'fnote=' /tmp/pic_run.sh | grep -qiF 'not changed' && echo yes || echo no)"
# R5F1: nor may the SECTION heading over the attachments (reviewer or
# verifier prompt) — the exclusion against the PR file list is only as
# good as that list, which is empty when the files API failed.
t "R5F1: no prompt heading calls attached imports unchanged" "0" \
  "$(grep -F 'echo "' /tmp/pic_run.sh | grep -F 'those files import' | grep -ci 'unchanged')"
t "R5F1: delta round without the PR file list attaches no imports" "yes" \
  "$(grep -qF 'if [ "$DELTA_MODE" = "1" ] && ! grep -q . prfiles.txt; then' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: candidate list bounded by IMPORT_CANDIDATE_CAP" "yes" \
  "$(grep -F 'imports_raw.txt' /tmp/pic_run.sh | grep -qF 'head -"$IMPORT_CANDIDATE_CAP"' && echo yes || echo no)"
t "engine: candidates settled by the listing filter, via a file not a pipe" "yes" \
  "$(grep -qF 'import_existing_filter < import_cands.txt > attach_imports.txt' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: IMPORT_DIR_CAP and IMPORT_CANDIDATE_CAP live in the Byte caps block" "2" \
  "$(awk '/# ---------- Byte caps ----------/ {b=1} b && /^IMPORT_(DIR|CANDIDATE)_CAP=/ {n++} b && /# ---------- Repository guidance/ {exit} END {print n+0}' /tmp/pic_run.sh)"
t "engine: IMPORT_COUNT_CAP lives in the Byte caps block" "yes" \
  "$(awk '/# ---------- Byte caps ----------/ {b=1} b && /^IMPORT_COUNT_CAP=/ {found=1} b && /# ---------- Repository guidance/ {exit} END {exit !found}' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: import slot cap is checked only for kind=imported" "yes" \
  "$(grep -qF '{ [ "$kind" = "imported" ] && [ "$imports_n" -ge "$IMPORT_COUNT_CAP" ]; }' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: imported header is distinct from the changed-file header" "yes" \
  "$(grep -qF 'flabel="Imported file"' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: exactly one attachment loop (deny-list applies by construction)" "1" \
  "$(grep -c 'case "\$f" in' /tmp/pic_run.sh)"
t "engine: prompt tells the model callers are not attached" "yes" \
  "$(grep -qF 'Callers of the' "$ENGINE" && echo yes || echo no)"


# ================= import_existing_filter (extracted, gh shimmed) =================
extract_between '# ---- import_existing_filter ----' '# ---- end import_existing_filter ----' > /tmp/ief_block.sh
t "filter block extracted (non-empty)" "yes" "$([ -s /tmp/ief_block.sh ] && echo yes || echo no)"
t "filter block defines the function"  "yes" "$(grep -qF 'import_existing_filter() {' /tmp/ief_block.sh && echo yes || echo no)"
t "filter: jq guards on the array-vs-object shape" "yes" "$(grep -qF 'if type == "array" then' /tmp/ief_block.sh && echo yes || echo no)"
t "filter: 404 is absence, other failures are counted" "yes" "$(grep -qF 'grep -q "HTTP 404" derr.txt' /tmp/ief_block.sh && echo yes || echo no)"
t "filter: stderr is never echoed" "no" "$(grep -F 'derr.txt' /tmp/ief_block.sh | grep -qE 'cat derr|\$\(<derr|echo.*derr' && echo yes || echo no)"

# shellcheck disable=SC1091
. /tmp/ief_block.sh
GH_REPO=o/r; HEAD_SHA=deadbeef; IMPORT_DIR_CAP=25
gh_calls=0
gh() { # shim: canned listings per directory route, counts calls
  gh_calls=$((gh_calls + 1)); echo "$*" >> /tmp/ief_calls.txt
  case "$*" in
    *"contents?ref="*)            printf 'util.py\nREADME.md\n' ;;
    *"contents/src%2Fpkg?"*|*"contents/src/pkg?"*) printf 'core.py\n__init__.py\n' ;;
    *"contents/pkg?"*)            printf '{"type":"file","name":"pkg.py"}\n' | jq -r 'if type == "array" then .[] | select(.type == "file") | .name else empty end' ;;
    *"contents/gone?"*)           echo "gh: Not Found (HTTP 404)" >&2; return 1 ;;
    *"contents/broken?"*)         echo "gh: something else (HTTP 502)" >&2; return 1 ;;
    *) return 1 ;;
  esac
}
run_filter() { # <candidates...>  -> /tmp/ief_out.txt (file in, file out: a pipe
  # or $(...) would run the filter in a subshell and lose its counters — the
  # engine wires it the same way, for the same reason)
  : > dirs_done.txt; : > dirlist.txt; : > /tmp/ief_calls.txt
  import_cands_untried=0; import_dirs_failed=0; gh_calls=0
  printf '%s\n' "$@" > /tmp/ief_in.txt
  import_existing_filter < /tmp/ief_in.txt > /tmp/ief_out.txt
  out=$(cat /tmp/ief_out.txt)
}
cd /tmp
run_filter util.py src/pkg/core.py src/pkg/nope.py nothere.py src/pkg/__init__.py
t "filter: root-dir candidate found"        "yes" "$(printf '%s\n' "$out" | grep -qxF util.py && echo yes || echo no)"
t "filter: nested candidate found"          "yes" "$(printf '%s\n' "$out" | grep -qxF src/pkg/core.py && echo yes || echo no)"
t "filter: missing files dropped"           "no"  "$(printf '%s\n' "$out" | grep -qE 'nope|nothere' && echo yes || echo no)"
t "filter: order preserved"                 "util.py src/pkg/core.py src/pkg/__init__.py" "$(printf '%s\n' "$out" | tr '\n' ' ' | sed 's/ $//')"
t "filter: one API call per distinct directory" "2" "$(wc -l < /tmp/ief_calls.txt | tr -d ' ')"
run_filter pkg/x.py pkg/y.py
t "filter: a directory that is really a file yields nothing" "" "$out"
t "filter: ...and is not counted as a failure" "0" "$import_dirs_failed"
run_filter gone/a.py
t "filter: 404 directory yields nothing, no failure" "0" "$import_dirs_failed"
run_filter broken/a.py broken/b.py
t "filter: non-404 failure counted once per directory" "1" "$import_dirs_failed"
IMPORT_DIR_CAP=1
run_filter util.py src/pkg/core.py src/pkg/x.py
t "filter: past IMPORT_DIR_CAP, candidates are counted as untried" "2" "$import_cands_untried"
t "filter: ...and the listed directory still resolves" "util.py" "$out"
cd - >/dev/null

t_summary
