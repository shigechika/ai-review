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
t "anchored: no root-level duplicate"        "no"  "$(has pkg/core.py)"

# ---------- Tests-only PR: anchor comes from the PR file list ----------
resolve tests/test_mod.py 'from pkg.core import run' > /tmp/pic_out.txt
t "list-anchored: pkg root found via prfiles" "yes" "$(has src/pkg/core.py)"

# ---------- Unknown top package: root and src/ fallback, nothing more ----------
resolve tests/test_mod.py 'import other_pkg.thing' > /tmp/pic_out.txt
t "fallback: repo root"                      "yes" "$(has other_pkg/thing.py)"
t "fallback: src/"                           "yes" "$(has src/other_pkg/thing.py)"
t "fallback: exactly 4 candidates"           "4"   "$(wc -l < /tmp/pic_out.txt | tr -d ' ')"

# ---------- Noise that must produce nothing ----------
resolve src/pkg/mod.py $'import os, sys\nfrom typing import Any\n# import commented\nprint("from x import y")\nfrom __future__ import annotations' > /tmp/pic_out.txt
t "stdlib and comments: nothing emitted"     "0"   "$(wc -l < /tmp/pic_out.txt | tr -d ' ')"

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

# ---------- Engine wiring ----------
extract_run > /tmp/pic_run.sh
t "engine: imports collected only for *.py, never in docs-mode" "yes" \
  "$(grep -A1 -F 'if [ "${f%.py}" != "$f" ] && [ "$DOCS_MODE" != "1" ]; then' /tmp/pic_run.sh | grep -qF 'py_import_candidates "$f" prfiles.txt < fbody.txt >> imports_raw.txt' && echo yes || echo no)"
t "engine: changed files attached before imports" "yes" \
  "$(awk '/attach_from_list attach_list.txt changed/ {c=NR} /attach_from_list attach_imports.txt imported/ {i=NR} END {exit !(c && i && c < i)}' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: a changed file is never re-attached as an import" "yes" \
  "$(grep -qF 'grep -vxFf attach_list.txt' /tmp/pic_run.sh && echo yes || echo no)"
t "engine: import candidates capped like docs-mode citations" "yes" \
  "$(grep -F 'imports_raw.txt' /tmp/pic_run.sh | grep -qF 'head -40' && echo yes || echo no)"
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

t_summary
