#!/bin/bash
# Inline review comments: the hunk parser that decides which lines GitHub
# will accept, the finding-line splitter, and the wiring that keeps the
# whole step best-effort. Both functions are extracted from the committed
# YAML, never retyped.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./lib.sh

# Each extraction is asserted non-empty as its OWN check first: a broken
# anchor would otherwise make the checks below pass on empty input.
extract_between '# ---- commentable_lines ----' '# ---- end commentable_lines ----' > /tmp/ic_cl.sh
t "commentable_lines block extracted"  "yes" "$([ -s /tmp/ic_cl.sh ] && echo yes || echo no)"
t "...and defines the function"        "yes" "$(grep -qF 'commentable_lines() {' /tmp/ic_cl.sh && echo yes || echo no)"
extract_between '# ---- finding_anchor ----' '# ---- end finding_anchor ----' > /tmp/ic_fa.sh
t "finding_anchor block extracted"     "yes" "$([ -s /tmp/ic_fa.sh ] && echo yes || echo no)"
t "...and defines the function"        "yes" "$(grep -qF 'finding_anchor() {' /tmp/ic_fa.sh && echo yes || echo no)"

# Both blocks hold single-quoted programs, and an apostrophe inside one
# ends the string early. Counting the total pins that: two quotes per
# program and no stray third. A legitimate new program changes the number
# and forces this to be re-read rather than silently drifting.
t "commentable_lines: only the program quotes" "4" "$(grep -o "'" /tmp/ic_cl.sh | wc -l | tr -d ' ')"
t "finding_anchor: only the program quotes"    "4" "$(grep -o "'" /tmp/ic_fa.sh | wc -l | tr -d ' ')"

# shellcheck disable=SC1091
. /tmp/ic_cl.sh
# shellcheck disable=SC1091
. /tmp/ic_fa.sh

# ---------- Which lines a comment can be anchored to ----------
run_cl() { cat > /tmp/ic_dir/prfiles.json; ( cd /tmp/ic_dir && commentable_lines ); }
mkdir -p /tmp/ic_dir

# One hunk: context and added lines advance the right side, a deletion
# does not.
run_cl <<'JSON' > /tmp/ic_out.txt
[{"filename":"src/a.py","patch":"@@ -1,3 +1,4 @@\n import os\n+import sys\n def f():\n-    old()\n+    new()"}]
JSON
t "hunk: context line"            "yes" "$(grep -qxF "$(printf 'src/a.py\t1')" /tmp/ic_out.txt && echo yes || echo no)"
t "hunk: added line"              "yes" "$(grep -qxF "$(printf 'src/a.py\t2')" /tmp/ic_out.txt && echo yes || echo no)"
t "hunk: line after a deletion"   "yes" "$(grep -qxF "$(printf 'src/a.py\t4')" /tmp/ic_out.txt && echo yes || echo no)"
t "hunk: deletion adds no right line" "4" "$(wc -l < /tmp/ic_out.txt | tr -d ' ')"

# A header with no count means a one-line hunk.
run_cl <<'JSON' > /tmp/ic_out.txt
[{"filename":"docs/b.md","patch":"@@ -10 +10 @@\n-x\n+y"}]
JSON
t "hunk: countless header"        "yes" "$(grep -qxF "$(printf 'docs/b.md\t10')" /tmp/ic_out.txt && echo yes || echo no)"
t "hunk: ...and only that line"   "1"   "$(wc -l < /tmp/ic_out.txt | tr -d ' ')"

# Several hunks in one file each reset the right-side counter.
run_cl <<'JSON' > /tmp/ic_out.txt
[{"filename":"src/c.py","patch":"@@ -1,1 +1,1 @@\n+a\n@@ -50,2 +60,2 @@\n b\n+c"}]
JSON
t "hunk: second hunk restarts at its own line" "yes" "$(grep -qxF "$(printf 'src/c.py\t61')" /tmp/ic_out.txt && echo yes || echo no)"
t "hunk: first hunk still counted"             "yes" "$(grep -qxF "$(printf 'src/c.py\t1')" /tmp/ic_out.txt && echo yes || echo no)"

# A file with no patch (binary, or past GitHub's own size threshold)
# contributes nothing, and must not swallow the next file.
run_cl <<'JSON' > /tmp/ic_out.txt
[{"filename":"img/c.png"},{"filename":"src/d.py","patch":"@@ -1,1 +7,1 @@\n+z"}]
JSON
t "hunk: file with no patch yields nothing" "no"  "$(grep -q 'png' /tmp/ic_out.txt && echo yes || echo no)"
t "hunk: ...and the next file still parses" "yes" "$(grep -qxF "$(printf 'src/d.py\t7')" /tmp/ic_out.txt && echo yes || echo no)"

# Patch content that looks like the separator must not be read as one.
# A unified-diff body line always starts with @, space, +, - or backslash.
run_cl <<'JSON' > /tmp/ic_out.txt
[{"filename":"src/e.py","patch":"@@ -1,2 +1,2 @@\n+===AIR-FILE=== evil.py\n x"}]
JSON
t "hunk: a body line cannot impersonate the separator" "0" "$(grep -c 'evil' /tmp/ic_out.txt)"
t "hunk: ...and both real lines are kept"              "2" "$(grep -c '^src/e.py' /tmp/ic_out.txt)"

# ---------- Splitting the finding's anchor line ----------
t "anchor: plain"                 "$(printf 'src/a.py\t12')" "$(finding_anchor 'src/a.py:12 - a summary')"
t "anchor: colon in the path"     "$(printf 'weird:name.py\t7')" "$(finding_anchor 'weird:name.py:7 - text')"
t "anchor: dashes in the summary" "$(printf 'src/a.py\t3')" "$(finding_anchor 'src/a.py:3 - has - dashes - inside')"
t "anchor: a later ':<digits> - ' in the summary is ignored" "$(printf 'src/a.py\t3')" \
  "$(finding_anchor 'src/a.py:3 - see also x:99 - here')"
t "anchor: no line number"        ""   "$(finding_anchor 'no line number here')"
t "anchor: non-numeric line"      ""   "$(finding_anchor 'src/a.py:x - bad')"
t "anchor: missing separator"     ""   "$(finding_anchor 'src/a.py:12 no dash')"
# The line number is required, not optional: without at least one digit
# this would split and hand an empty line number downstream.
t "anchor: empty line number"     ""   "$(finding_anchor 'src/a.py: - bad')"

# ---------- Wiring ----------
extract_run > /tmp/ic_run.sh
t "engine: inline posting runs only after the sticky post succeeded" "yes" \
  "$(grep -A1 -F 'if [ "$sticky_posted" = "1" ]; then' /tmp/ic_run.sh | grep -qF 'post_inline_comments' && echo yes || echo no)"
t "engine: ...and never fails the job" "yes" \
  "$(grep -qF 'post_inline_comments || true' /tmp/ic_run.sh && echo yes || echo no)"
t "engine: the existing-comment listing is author-filtered" "yes" \
  "$(grep -qF 'select(.user.login == "github-actions[bot]") | .body' /tmp/ic_run.sh && echo yes || echo no)"
t "engine: ...and paginated" "yes" \
  "$(grep -B1 -F 'select(.user.login == "github-actions[bot]") | .body' /tmp/ic_run.sh | grep -qF -- '--paginate' && echo yes || echo no)"
t "engine: a failed listing posts nothing rather than duplicating" "yes" \
  "$(grep -A2 -F 'if [ "$istatus" -ne 0 ]; then' /tmp/ic_run.sh | grep -qF 'return 0' && echo yes || echo no)"
t "engine: one call per finding, not an atomic review array" "yes" \
  "$(grep -qF 'gh api --method POST "repos/$GH_REPO/pulls/$PR/comments" --input ipayload.json' /tmp/ic_run.sh && echo yes || echo no)"
t "engine: the body reaches jq as a file, never as an argument" "yes" \
  "$(grep -qF -- '--rawfile body ibody.md' /tmp/ic_run.sh && echo yes || echo no)"
t "engine: the post's stderr is never echoed" "no" \
  "$(grep -A2 -F 'gh api --method POST "repos/$GH_REPO/pulls/$PR/comments"' /tmp/ic_run.sh | grep -qE 'echo.*2>&1|post_err' && echo yes || echo no)"
t "engine: idempotency is by marker, not by the ledger" "yes" \
  "$(grep -qF 'ai-review-inline-v1:' /tmp/ic_run.sh && grep -qF 'grep -qxF "$id"' /tmp/ic_run.sh && echo yes || echo no)"
t "engine: an unaddressable finding is counted, not dropped silently" "yes" \
  "$(grep -qF 'not on a line GitHub accepts (kept in the sticky comment)' /tmp/ic_run.sh && echo yes || echo no)"
t "engine: findings come from kept.txt, after the verifier" "yes" \
  "$(grep -qF 'kept.txt > blk.txt' /tmp/ic_run.sh && echo yes || echo no)"

t_summary
