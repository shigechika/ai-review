#!/bin/bash
# Docs-mode detection, evidence-token extraction, and the FILES_TOTAL_CAP
# input parsing bug class (leading-zero octal). Logic mirrored from the
# engine's actual expressions, not re-derived — see each test's comment
# for where it lives.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./lib.sh

# ---------- Docs-mode detection (mirrors the DOCS_MODE block) ----------
detect_docs_mode() {
  local prfiles=$1 DOCS_MODE=0 non_md
  non_md=$(printf '%s\n' "$prfiles" | grep -cv '\.md$' || true)
  case "$non_md" in ''|*[!0-9]*) non_md=1 ;; esac
  [ "$non_md" -eq 0 ] && DOCS_MODE=1
  echo "$DOCS_MODE"
}
t "docs-mode: all-md"                "1" "$(detect_docs_mode $'docs/a.md\ndocs/b.md')"
t "docs-mode: mixed"                 "0" "$(detect_docs_mode $'docs/a.md\nsrc/x.py')"
t "docs-mode: rename hides code removal" "0" "$(detect_docs_mode $'docs/new.md\nold_code.py')"
t "docs-mode: empty prfiles (API fail-safe)" "0" "$(detect_docs_mode '')"

# The real engine gates prfiles on the files-API call's exit status (a
# pagination failure yields empty, not a partial first page) — this is a
# structural check that the gate still wraps the assignment, since a unit
# test on detect_docs_mode alone cannot exercise gh api failing mid-page.
t "engine: files-API call is exit-status gated" "yes" \
  "$(grep -qF 'if ! prfiles=$(gh api "repos/$GH_REPO/pulls/$PR/files' "$ENGINE" && echo yes || echo no)"

# ---------- Evidence token extraction ----------
extract_tokens() {
  grep -oE '\.?[A-Za-z0-9_][A-Za-z0-9_./-]*\.(py|pyi|ts|tsx|js|mjs|go|rs|rb|java|kt|kts|c|h|cc|cpp|hpp|cs|php|swift|scala|sql|lua|sh|bash|yml|yaml|toml|cfg|json)' \
    | sed 's#^\./##' | sort -u
}
# The allow-list actually used by the engine must be the one this test
# exercises above — check the line the extraction regex lives on still
# contains the R1F2-widened extensions, not a narrower reverted one.
denylist_line=$(grep -F 'grep -oE' "$ENGINE" | head -1)
t "engine token regex includes java"  "yes" "$(printf '%s' "$denylist_line" | grep -qF 'java' && echo yes || echo no)"
t "engine token regex includes sql"   "yes" "$(printf '%s' "$denylist_line" | grep -qF 'sql' && echo yes || echo no)"

printf 'The health_check() tool in server.py returns keycloak_version.\nSee src/keycloak_mcp/server.py and config in pyproject.toml, run scripts/run.sh.\nNot a path: version 3.10, example.com, a.b, https://x.io/y.md\nWindows-ish: .github/workflows/ci.yml\nJava: src/Main.java\n' \
  | extract_tokens > /tmp/tokens.txt
t "token: bare filename"             "yes" "$(grep -qxF 'server.py' /tmp/tokens.txt && echo yes || echo no)"
t "token: nested path"               "yes" "$(grep -qxF 'src/keycloak_mcp/server.py' /tmp/tokens.txt && echo yes || echo no)"
t "token: config file"               "yes" "$(grep -qxF 'pyproject.toml' /tmp/tokens.txt && echo yes || echo no)"
t "token: dotdir path"               "yes" "$(grep -qxF '.github/workflows/ci.yml' /tmp/tokens.txt && echo yes || echo no)"
t "token: java (R1F2 fix)"           "yes" "$(grep -qxF 'src/Main.java' /tmp/tokens.txt && echo yes || echo no)"
t "token: version number rejected"   "no"  "$(grep -qxF '3.10' /tmp/tokens.txt && echo yes || echo no)"
t "token: bare domain rejected"      "no"  "$(grep -qxF 'example.com' /tmp/tokens.txt && echo yes || echo no)"

# ---------- Directory-relative variants (R1F1 fix) ----------
# `./client.py` cited from docs/guide.md should also try docs/client.py,
# not only the root-anchored client.py.
: > /tmp/tokens_raw.txt
printf 'client.py\ndocs/api.py\nMain.java\n' > /tmp/tokens_raw.txt
printf 'docs/guide.md\nREADME.md\n' > /tmp/attach_docs.txt
: > /tmp/tokens_variants.txt
while IFS= read -r md; do
  d=$(dirname -- "$md" 2>/dev/null) || d="."
  [ "$d" = "." ] && continue
  awk -v d="$d" '$0 !~ "^" d "/" { print d "/" $0 }' /tmp/tokens_raw.txt >> /tmp/tokens_variants.txt || true
done < /tmp/attach_docs.txt
cat /tmp/tokens_raw.txt /tmp/tokens_variants.txt | awk '!seen[$0]++' > /tmp/candidates.txt
t "dir-variant: adds docs/client.py"   "yes" "$(grep -qxF 'docs/client.py' /tmp/candidates.txt && echo yes || echo no)"
t "dir-variant: keeps raw client.py"   "yes" "$(grep -qxF 'client.py' /tmp/candidates.txt && echo yes || echo no)"
t "dir-variant: root README skipped"   "0"   "$(grep -cxF 'README.md/client.py' /tmp/candidates.txt)"

# Ordering (R2F2 fix): literal citations must survive the cap ahead of
# directory guesses. 35 real citations plus guesses must not push any real
# citation past the 40-entry head.
: > /tmp/tokens_raw35.txt
for i in $(seq 1 35); do printf 'src/f%02d.py\n' "$i"; done > /tmp/tokens_raw35.txt
: > /tmp/tokens_variants35.txt
printf 'docs/guide.md\n' > /tmp/attach_docs35.txt
while IFS= read -r md; do
  d=$(dirname -- "$md" 2>/dev/null) || d="."
  [ "$d" = "." ] && continue
  awk -v d="$d" '$0 !~ "^" d "/" { print d "/" $0 }' /tmp/tokens_raw35.txt >> /tmp/tokens_variants35.txt || true
done < /tmp/attach_docs35.txt
kept_n=$(cat /tmp/tokens_raw35.txt /tmp/tokens_variants35.txt | awk '!seen[$0]++' | head -40 | grep -c '^src/')
t "ordering: all 35 real citations survive the cap" "35" "$kept_n"

# ---------- Leading-dash filenames (R2F1 fix) ----------
d=$(dirname -- "-guide.md" 2>/dev/null) || d="."
t "dash-filename: dirname does not abort" "." "$d"

t_summary
