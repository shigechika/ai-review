#!/bin/bash
# READMEs attached as documentation evidence in code-mode, and the two
# caps that were tuned before REVIEW.md existed. The focus paragraphs are
# read out of the committed YAML, never retyped.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./lib.sh

extract_run > /tmp/re_run.sh
t "run block extracted" "yes" "$([ -s /tmp/re_run.sh ] && echo yes || echo no)"

# ---------- The carve-out has to read as an ADDITION ----------
# A closed "Do NOT report" list has nothing that CONFLICTS with a new
# check, so a rule phrased as "wins where it conflicts" is a no-op for
# one — the lesson this repository recorded when REVIEW.md was added.
extract_between "focus_para='Focus on: real bugs" "most severe first.'" > /tmp/re_code.txt
t "code-mode paragraph extracted"        "yes" "$([ -s /tmp/re_code.txt ] && echo yes || echo no)"
t "carve-out names the diff, not drift"  "yes" "$(grep -qF 'that this diff makes' /tmp/re_code.txt && echo yes || echo no)"
t "carve-out is phrased as an addition"  "yes" "$(grep -qF 'report that check even though' /tmp/re_code.txt && echo yes || echo no)"
t "carve-out demands both citations"     "yes" "$(grep -qF 'citing both the README line and the diff' /tmp/re_code.txt && echo yes || echo no)"
t "parity is excluded from code-mode"    "yes" "$(grep -qF 'Do not compare the two READMEs' /tmp/re_code.txt && echo yes || echo no)"
t "pre-existing wrongness excluded"      "yes" "$(grep -qF 'already wrong before this diff' /tmp/re_code.txt && echo yes || echo no)"
t "READMEs are evidence, not scope"      "yes" "$(grep -qF 'evidence, never report scope' /tmp/re_code.txt && echo yes || echo no)"

# Docs-mode keeps its own, opposite job: documentation IS the subject
# there, and the parity check lives there.
extract_between "focus_para='This pull request changes documentation only" "most severe first.'" > /tmp/re_docs.txt
t "docs-mode paragraph extracted"        "yes" "$([ -s /tmp/re_docs.txt ] && echo yes || echo no)"
t "docs-mode still owns the parity check" "yes" "$(grep -qF 'whether the two make the same claims' /tmp/re_docs.txt && echo yes || echo no)"
t "docs-mode is not given the code-mode carve-out" "no" \
  "$(grep -qF 'report that check even though' /tmp/re_docs.txt && echo yes || echo no)"

# ---------- Both prompts must see the same evidence ----------
# A verifier blind to the README refutes every finding that cites one,
# which is the exact class this attachment exists to enable.
t "readmes reach the reviewer AND the verifier" "2" "$(grep -c 'cat readmes.txt' /tmp/re_run.sh)"
t "reviewer labels them as evidence, not subject" "yes" \
  "$(grep -qF 'It is' /tmp/re_run.sh && grep -qF 'not the review subject and not report scope' /tmp/re_run.sh && echo yes || echo no)"

# ---------- The attachment loop ----------
t "code-mode only"                       "yes" \
  "$(grep -B2 -F 'for rf in README.md README.ja.md; do' /tmp/re_run.sh | grep -qF 'if [ "$DOCS_MODE" != "1" ]; then' && echo yes || echo no)"
t "a README already attached as a changed file is not re-sent" "yes" \
  "$(grep -qF 'grep -qxF "$rf" attach_list.txt && continue' /tmp/re_run.sh && echo yes || echo no)"
t "...checked against the ROUND list, not the whole PR" "no" \
  "$(grep -F 'grep -qxF "$rf"' /tmp/re_run.sh | grep -qF 'prfiles' && echo yes || echo no)"
t "own budget, not the changed-file pool" "yes" \
  "$(grep -qF 'README_TOTAL_CAP - readme_total' /tmp/re_run.sh && echo yes || echo no)"
t "...and not a FILE_COUNT_CAP slot"      "no" \
  "$(sed -n '/for rf in README.md/,/^          fi$/p' /tmp/re_run.sh | grep -qF 'FILE_COUNT_CAP' && echo yes || echo no)"
t "TRUNCATED is decided on what the cap clamped" "yes" \
  "$(grep -qF 'if [ "$rdclamped" -lt "$rdsize" ]; then' /tmp/re_run.sh && echo yes || echo no)"
t "a 404 is absence, anything else warns" "yes" \
  "$(grep -A6 -F 'if [ "$rdstatus" -ne 0 ]; then' /tmp/re_run.sh | grep -qF 'grep -q "HTTP 404" rderr.txt' && echo yes || echo no)"
t "...and the fetch status is captured, not discarded" "yes" \
  "$(grep -qF '2>rderr.txt) || rdstatus=$?' /tmp/re_run.sh && echo yes || echo no)"
t "the count is observable"               "yes" \
  "$(grep -qF 'readmes=${readme_n} (${readme_total}B)' /tmp/re_run.sh && echo yes || echo no)"

# ---------- Caps tuned before REVIEW.md existed ----------
t "both modes cap findings at the same number" "2" "$(grep -c 'Report at most 5 findings, most severe first' /tmp/re_run.sh)"
t "no mode still says 3"                       "0" "$(grep -c 'Report at most 3 findings' /tmp/re_run.sh)"
t "the PR description cap is named, not inline" "yes" \
  "$(grep -qF 'head -c "$PR_BODY_CAP"' /tmp/re_run.sh && echo yes || echo no)"
t "...and lives in the Byte caps block" "3" \
  "$(awk '/# ---------- Byte caps ----------/ {b=1} b && /^(PR_BODY_CAP|README_CAP|README_TOTAL_CAP)=/ {n++} b && /# ---------- Repository guidance/ {exit} END {print n+0}' /tmp/re_run.sh)"
t "the header arithmetic mentions both new budgets" "yes" \
  "$(grep -qF 'READMEs 64 KiB + PR body' "$ENGINE" && echo yes || echo no)"

t_summary
