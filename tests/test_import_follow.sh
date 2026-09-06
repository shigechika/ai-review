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

# The resolver prints <tier*10+rank>TAB<path>. Keep both views: the keyed
# one for order/tier assertions, the path-only one for existence checks.
resolve() { # <importing-file> <python-source>  (pr file list from /tmp/pic_prfiles.txt)
  printf '%s\n' "$2" | py_import_candidates "$1" /tmp/pic_prfiles.txt > /tmp/pic_keyed.txt
  cut -f2 /tmp/pic_keyed.txt
}
key_of() { grep -F "	$1" /tmp/pic_keyed.txt | head -1 | cut -f1; }
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
# R12F1: only the delimiter that opened the string can close it.
resolve src/pkg/mod.py $'x = """\n# \x27\x27\x27\nimport hidden\n"""\nimport visible' > /tmp/pic_out.txt
t "R12F1: opposite delimiter does not close the string" "no"  "$(has hidden.py)"
t "R12F1: the real closer still ends it"                "yes" "$(has visible.py)"
resolve src/pkg/mod.py $'y = \x27\x27\x27\n"""\nimport still_inside\n\x27\x27\x27\nimport out' > /tmp/pic_out.txt
t "R12F1: same, with the quote kinds swapped"           "no"  "$(has still_inside.py)"
t "R12F1: ...and its own closer works"                  "yes" "$(has out.py)"

# ---------- The scanner: quoting context, not delimiter counting ----------
# Every row here was a silent total loss of the imports after it under the
# counting versions (R9F1, R11F1, R12F1 and the code-review round).
SQ=$(printf "\047")
resolve src/pkg/mod.py "$(printf 'if s.startswith(%s"""%s):\n    pass\nimport after_a\n' "$SQ" "$SQ")" > /tmp/pic_out.txt
t "scan: triple quote inside an ordinary string literal" "yes" "$(has after_a.py)"
resolve src/pkg/mod.py 'import foo  # see """ below
import bar' > /tmp/pic_out.txt
t "scan: triple quote in a trailing comment, same line"  "yes" "$(has foo.py)"
t "scan: ...and the next line still parses"              "yes" "$(has bar.py)"
resolve src/pkg/mod.py "$(printf '"""\ndoc %s%s%s here\n"""\nimport after_d\n' "$SQ" "$SQ" "$SQ")" > /tmp/pic_out.txt
t "scan: docstring holding the other delimiter"          "yes" "$(has after_d.py)"
t "scan: ...and its prose is not parsed as an import"    "0"   "$(grep -c 'doc\|here' /tmp/pic_out.txt)"
resolve src/pkg/mod.py "$(printf 'x = """a %s%s%s b"""\nimport after_e\n' "$SQ" "$SQ" "$SQ")" > /tmp/pic_out.txt
t "scan: one-line string mixing both delimiters"         "yes" "$(has after_e.py)"
resolve src/pkg/mod.py 'x = "a # b"
import after_f' > /tmp/pic_out.txt
t "scan: a hash inside a string is not a comment"        "yes" "$(has after_f.py)"
resolve src/pkg/mod.py 'x = "unterminated
import after_g' > /tmp/pic_out.txt
t "scan: an unterminated one-line string does not swallow the file" "yes" "$(has after_g.py)"
# A backslash at the end of the line continues the string, so what looks
# like an import on the next physical line is still string content.
resolve src/pkg/mod.py "$(printf 's = "text\\\nimport billing"\nimport after_h\n')" > /tmp/pic_out.txt
t "scan: a continued string is not parsed as code"   "no"  "$(has billing.py)"
t "scan: ...and the line after it still is"          "yes" "$(has after_h.py)"

# ---------- CRLF (a Windows-authored file lost one import per line) ----------
resolve src/pkg/mod.py "$(printf 'import foo\r\nimport a, b\r\nfrom .util import helper\r')" > /tmp/pic_crlf.txt
resolve src/pkg/mod.py "$(printf 'import foo\nimport a, b\nfrom .util import helper')" > /tmp/pic_out.txt
t "CRLF output is identical to LF"  "yes" "$(cmp -s /tmp/pic_crlf.txt /tmp/pic_out.txt && echo yes || echo no)"
t "CRLF: the last name on a line survives" "yes" "$(grep -qxF src/pkg/util/helper.py /tmp/pic_crlf.txt && echo yes || echo no)"

# ---------- The tier/rank key, which the caller sorts on ----------
resolve src/pkg/mod.py $'from .util import a\nfrom pkg.core import b\nimport httpx' > /tmp/pic_out.txt
t "key: relative import is tier 1"            "11" "$(key_of src/pkg/util.py)"
t "key: anchored import is tier 2"            "21" "$(key_of src/pkg/core.py)"
t "key: unanchored fallback is tier 3"        "31" "$(key_of httpx.py)"
t "key: src/ fallback is the second rank"     "32" "$(key_of src/httpx.py)"
t "key: every line carries one"               "0"  "$(grep -cv "^[1-6][1-6]	" /tmp/pic_keyed.txt)"

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
  "$(grep -qF 'head -"$IMPORT_CANDIDATE_CAP" import_cands_all.txt' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: candidates dropped by either cap are reported, not silent" "yes" \
  "$(grep -qF 'import_cands_untried=$(( $(wc -l < import_cands_all.txt' /tmp/pic_run.sh && echo yes || echo no)"
# The filter ADDS its directory-cap skips to this count, so the assignment
# must come first or the filter increments are overwritten.
t "engine: the candidate-cap count is assigned before the filter runs" "yes" \
  "$(awk '/import_cands_untried=\$\(\( \$\(wc -l < import_cands_all/ {a=NR} /import_existing_filter < import_cands.txt/ {f=NR} END {exit !(a && f && a < f)}' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: one percent-encoder, not one per call site" "1" \
  "$(grep -c 'map(@uri)' /tmp/pic_run.sh)"
t "engine: both directory caps are checked before a listing" "yes" \
  "$(grep -A1 -F 'if [ "$import_dirs_listed" -ge "$IMPORT_DIR_CAP" ]' /tmp/pic_run.sh | grep -qF 'IMPORT_DIR_TRY_CAP' && echo yes || echo no)"
t "engine: candidates settled by the listing filter, via a file not a pipe" "yes" \
  "$(grep -qF 'import_existing_filter < import_cands.txt > attach_imports.txt' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: every import cap lives in the Byte caps block" "4" \
  "$(awk '/# ---------- Byte caps ----------/ {b=1} b && /^IMPORT_[A-Z_]*CAP=/ {n++} b && /# ---------- Repository guidance/ {exit} END {print n+0}' /tmp/pic_run.sh)"
t "engine: IMPORT_COUNT_CAP lives in the Byte caps block" "yes" \
  "$(awk '/# ---------- Byte caps ----------/ {b=1} b && /^IMPORT_COUNT_CAP=/ {found=1} b && /# ---------- Repository guidance/ {exit} END {exit !found}' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: import slot cap is checked only for kind=imported" "yes" \
  "$(grep -qF '{ [ "$kind" = "imported" ] && [ "$imports_n" -ge "$IMPORT_COUNT_CAP" ]; }' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: imported header is distinct from the changed-file header" "yes" \
  "$(grep -qF 'flabel="Imported file"' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: exactly one attachment loop (deny-list applies by construction)" "1" \
  "$(grep -c 'case "\$f" in' /tmp/pic_run.sh)"
t "engine: candidate order is restored across files by a stable key sort" "yes" \
  "$(grep -qF 'sort -s -k1,1n imports_raw.txt | awk -F"\t"' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: fallback-tier candidates get a separate list" "yes" \
  "$(grep -qF 'int($1 / 10) == 3 || int($1 / 10) == 6' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: a fallback attachment says it may be the wrong module" "yes" \
  "$(grep -qF 'grep -qxF "$f" import_fallback.txt' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: the content fetch separates failure from absence" "yes" \
  "$(grep -qF '2>ferr.txt) || fstatus=$?' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: ...and reports the failures it counted" "yes" \
  "$(grep -qF 'fetch_failed" -eq 0 ] || echo "::warning::' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: a failed listing is recorded, not cached as absence" "yes" \
  "$(grep -qF 'dirs_failed.txt' /tmp/pic_run.sh && grep -A2 -F 'HTTP 404" derr.txt; then' /tmp/pic_run.sh | grep -qF 'dirs_failed.txt' && echo yes || echo no)"
t "engine: a 1000-entry listing is treated as unproven absence" "yes" \
  "$(grep -qF 'dirs_truncated.txt' /tmp/pic_run.sh && echo yes || echo no)"
# The switch itself, its truth table and its default live in
# test_feature_switch.sh. Here: only that this feature is wired to it,
# and that a caller which never sets anything gets NO import step.
t "engine: import-following is wired to the switch" "yes" \
  "$(grep -qF 'feature_switch IMPORTS' /tmp/pic_run.sh && grep -qF 'imports_on=$FEATURE_ON' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: prompt tells the model callers are not attached" "yes" \
  "$(grep -qF 'Callers of the' "$ENGINE" && echo yes || echo no)"


# ================= import_existing_filter (extracted, gh shimmed) =================
extract_between '# ---- import_existing_filter ----' '# ---- end import_existing_filter ----' > /tmp/ief_block.sh
t "filter block extracted (non-empty)" "yes" "$([ -s /tmp/ief_block.sh ] && echo yes || echo no)"
t "filter block defines the function"  "yes" "$(grep -qF 'import_existing_filter() {' /tmp/ief_block.sh && echo yes || echo no)"
t "filter: jq guards on the array-vs-object shape" "yes" "$(grep -qF 'if type == "array" then' /tmp/ief_block.sh && echo yes || echo no)"
t "filter: 404 is absence, other failures are counted" "yes" "$(grep -qF 'grep -q "HTTP 404" derr.txt' /tmp/ief_block.sh && echo yes || echo no)"
t "filter: stderr is never echoed" "no" "$(grep -F 'derr.txt' /tmp/ief_block.sh | grep -qE 'cat derr|\$\(<derr|echo.*derr' && echo yes || echo no)"

# The filter calls the shared percent-encoder, so that block is part of
# what is under test — extract it the same way rather than redefining it.
extract_between '# ---- urlenc_path ----' '# ---- end urlenc_path ----' > /tmp/urlenc_block.sh
t "urlenc block extracted (non-empty)" "yes" "$([ -s /tmp/urlenc_block.sh ] && echo yes || echo no)"
# shellcheck disable=SC1091
. /tmp/urlenc_block.sh
# shellcheck disable=SC1091
. /tmp/ief_block.sh
t "urlenc: segments encoded, slashes kept" "a%20b/c%2Bd.py" "$(urlenc_path 'a b/c+d.py')"
GH_REPO=o/r; HEAD_SHA=deadbeef; IMPORT_DIR_CAP=25; IMPORT_DIR_TRY_CAP=50
gh_calls=0
# The shim returns the RAW API shape and runs the engine own --jq argument
# on it — never a hand-copied filter, which would pin the array-vs-object
# guard by a grep instead of by behaviour (CLAUDE.md mirror-fidelity rule).
gh() {
  gh_calls=$((gh_calls + 1)); echo "$*" >> /tmp/ief_calls.txt
  local jqexpr="" prev="" a json
  for a in "$@"; do
    [ "$prev" = "--jq" ] && jqexpr=$a
    prev=$a
  done
  case "$*" in
    *"contents?ref="*)     json='[{"type":"file","name":"util.py"},{"type":"dir","name":"sub"},{"type":"file","name":"README.md"}]' ;;
    *"contents/src/pkg?"*) json='[{"type":"file","name":"core.py"},{"type":"file","name":"__init__.py"}]' ;;
    # A candidate directory that is really a module file: the API answers
    # with an OBJECT here, which is what the engine jq has to survive.
    *"contents/pkg?"*)     json='{"type":"file","name":"pkg.py","encoding":"base64"}' ;;
    # Exactly the 1000 entries the Contents API returns at most, with no
    # flag to say it stopped there.
    *"contents/big?"*)     json=$(jq -nc '[range(1000) | {type: "file", name: ("f" + (. | tostring) + ".py")}]') ;;
    *"contents/gone?"*)    echo "gh: Not Found (HTTP 404)" >&2; return 1 ;;
    *"contents/broken?"*)  echo "gh: something else (HTTP 502)" >&2; return 1 ;;
    # An unrouted path is a directory that does not exist, which the real
    # API answers with a 404 — not a bare failure.
    *)                     echo "gh: Not Found (HTTP 404)" >&2; return 1 ;;
  esac
  printf '%s' "$json" | jq -r "$jqexpr"
}
run_filter() { # <candidates...>  -> /tmp/ief_out.txt (file in, file out: a pipe
  # or $(...) would run the filter in a subshell and lose its counters — the
  # engine wires it the same way, for the same reason)
  : > dirs_done.txt; : > dirlist.txt; : > /tmp/ief_calls.txt
  : > dirs_failed.txt; : > dirs_truncated.txt
  import_cands_untried=0; import_dirs_failed=0; import_dirs_listed=0; gh_calls=0
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
# The engine jq guards on type; without the guard jq errors on the object
# and the shim reports a failure, which is what this pins.
t "filter: ...and the object response is not a failure" "0" "$import_dirs_failed"
run_filter gone/a.py
t "filter: 404 directory yields nothing, no failure" "0" "$import_dirs_failed"
run_filter broken/a.py broken/b.py
t "filter: non-404 failure counted once per directory" "1" "$import_dirs_failed"
# A failed listing proves nothing, so its candidates must be counted, not
# silently treated as absent like a 404.
t "filter: ...and its candidates are counted, not called absent" "2" "$import_cands_untried"
t "filter: ...and none of them is emitted"                       ""  "$out"
run_filter gone/a.py gone/b.py
t "filter: a 404 directory IS absence, nothing counted"          "0" "$import_cands_untried"

# A directory at the 1000-entry API ceiling cannot prove a name absent, so
# the candidate passes through and the content fetch settles it.
run_filter big/f1.py big/nowhere.py
t "filter: truncated listing still resolves a listed name"   "yes" "$(printf '%s\n' "$out" | grep -qxF big/f1.py && echo yes || echo no)"
t "filter: ...and passes an unlisted one through anyway"     "yes" "$(printf '%s\n' "$out" | grep -qxF big/nowhere.py && echo yes || echo no)"
run_filter src/pkg/nope.py
t "filter: a normal listing DOES prove absence"              ""    "$out"
IMPORT_DIR_CAP=1
run_filter util.py src/pkg/core.py src/pkg/x.py
t "filter: past IMPORT_DIR_CAP, candidates are counted as untried" "2" "$import_cands_untried"
t "filter: ...and the listed directory still resolves" "util.py" "$out"
IMPORT_DIR_CAP=25

# A directory that 404s costs an API call but must NOT count against the
# LISTED cap, or a src/ layout (which guesses a root-level directory for
# every import first) starves the real directories behind them.
IMPORT_DIR_CAP=2
run_filter gone/a.py gone2/a.py gone3/a.py util.py src/pkg/core.py
t "404 dirs do not consume the listed cap" "util.py src/pkg/core.py" "$(printf '%s\n' "$out" | tr '\n' ' ' | sed 's/ $//')"
t "...and the listed count is only the real ones" "2" "$import_dirs_listed"
# The attempt cap is what bounds API calls, 404s included.
IMPORT_DIR_CAP=25; IMPORT_DIR_TRY_CAP=2
run_filter gone/a.py gone2/a.py util.py src/pkg/core.py
t "attempt cap counts 404s and stops further listings" "2" "$(wc -l < /tmp/ief_calls.txt | tr -d ' ')"
t "...and the blocked candidates are counted untried"  "2" "$import_cands_untried"
IMPORT_DIR_TRY_CAP=50
cd - >/dev/null

t_summary
