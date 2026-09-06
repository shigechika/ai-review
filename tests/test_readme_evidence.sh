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
t "carve-out demands both citations"     "yes" \
  "$(grep -qF 'name the README file and' /tmp/re_code.txt && echo yes || echo no)"
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
  "$(grep -B3 -F 'for rf in README.md README.ja.md; do' /tmp/re_run.sh | grep -qF '[ "$DOCS_MODE" != "1" ]; then' && echo yes || echo no)"
t "a README already attached as a changed file is not re-sent" "yes" \
  "$(grep -qF 'grep -qxF "$rf" attached.txt && continue' /tmp/re_run.sh && echo yes || echo no)"
t "...checked against the ROUND list, not the whole PR" "no" \
  "$(grep -F 'grep -qxF "$rf"' /tmp/re_run.sh | grep -qF 'prfiles' && echo yes || echo no)"
# A file can be in attach_list.txt and still be missing from the prompt:
# the deny-list, the count cap and the byte budget all drop entries. The
# skip has to read what LANDED, or the README ends up in neither place.
t "...and against what was ATTACHED, not merely listed" "no" \
  "$(grep -F 'grep -qxF "$rf"' /tmp/re_run.sh | grep -qF 'attach_list.txt' && echo yes || echo no)"
# Placement, not mere presence: a write ahead of the deny-list or the
# budget checks would record files that never reached the prompt, which
# is the bug this list exists to prevent. Assert the ORDER — budget
# check, then the append to changedfiles.txt, then the record.
t "the attached list records every file that landed" "yes" \
  "$(awk '
      /remaining=\$\(\(FILES_TOTAL_CAP/ { budget = NR }
      /\} >> changedfiles.txt/ { landed = NR }
      />> attached.txt/ { recorded = NR }
      END { exit !(budget && landed && recorded && budget < landed && landed < recorded) }
    ' /tmp/re_run.sh && echo yes || echo no)"
t "...and the record cannot fail the job" "yes" \
  "$(grep -F '>> attached.txt' /tmp/re_run.sh | grep -qF '|| true' && echo yes || echo no)"
t "own budget, not the changed-file pool" "yes" \
  "$(grep -qF 'README_TOTAL_CAP - readme_total' /tmp/re_run.sh && echo yes || echo no)"
# A negative check on an extracted range passes vacuously when the range
# stops matching, so the extraction is asserted on its own first — the
# failure mode CLAUDE.md documents.
sed -n '/for rf in README.md/,/^          fi$/p' /tmp/re_run.sh > /tmp/re_loop.txt
t "the README loop is extractable"        "yes" "$([ -s /tmp/re_loop.txt ] && echo yes || echo no)"
t "...and really is the loop"             "yes" "$(grep -qF 'README_TOTAL_CAP' /tmp/re_loop.txt && echo yes || echo no)"
t "...and not a FILE_COUNT_CAP slot"      "no"  "$(grep -qF 'FILE_COUNT_CAP' /tmp/re_loop.txt && echo yes || echo no)"
t "TRUNCATED is decided on what the cap clamped" "yes" \
  "$(grep -qF 'if [ "$rdclamped" -lt "$rdsize" ]; then' /tmp/re_run.sh && echo yes || echo no)"
t "a 404 is absence, anything else warns" "yes" \
  "$(grep -A6 -F 'if [ "$rdstatus" -ne 0 ]; then' /tmp/re_run.sh | grep -qF 'grep -q "HTTP 404" rderr.txt' && echo yes || echo no)"
t "...and the fetch status is captured, not discarded" "yes" \
  "$(grep -qF '2>rderr.txt) || rdstatus=$?' /tmp/re_run.sh && echo yes || echo no)"
t "the count is observable"               "yes" \
  "$(grep -qF 'readmes=${readme_n} (${readme_total}B)' /tmp/re_run.sh && echo yes || echo no)"
# README documents the notice by quoting its opening; appending rather
# than prepending is what keeps that quote true.
t "...without falsifying the documented prefix" "yes" \
  "$(grep -qF 'ai-review context: docs_mode=' ../README.md && grep -qF '::notice::ai-review context: docs_mode=' /tmp/re_run.sh && echo yes || echo no)"
t "callers can turn README evidence off"  "yes" \
  "$(grep -qF 'AI_REVIEW_DISABLE_README' "$ENGINE" && grep -qF '[ -z "${DISABLE_README:-}" ] || readme_on=0' /tmp/re_run.sh && echo yes || echo no)"
t "...and both READMEs document that switch" "yes" \
  "$(grep -qF 'AI_REVIEW_DISABLE_README' ../README.md && grep -qF 'AI_REVIEW_DISABLE_README' ../README.ja.md && echo yes || echo no)"
t "the verifier frames the README independently of the changed files" "yes" \
  "$(awk '/if \[ -s readmes.txt \]; then/ {n++} n == 2 && /never/ {found = 1} END {exit !found}' /tmp/re_run.sh && echo yes || echo no)"
# The fallback loop runs precisely when the changed-file path did NOT
# attach the file, which includes a README the PR edited and a cap
# dropped — so no framing may claim it is not PR-authored.
t "...without claiming provenance it has not verified" "no" \
  "$(grep -qF 'not authored by this' /tmp/re_run.sh && echo yes || echo no)"
# Item 7 documents caps that do not apply to item 8, so the trailing
# paragraphs of 7 must stay with 7.
t "README item 8 does not absorb item 7 tail (en)" "no" \
  "$(awk '/^8\. For a \*\*code PR\*\*/ {n=1} n && /slot cap/ {f=1} END {exit !f}' ../README.md && echo yes || echo no)"
t "README item 8 does not absorb item 7 tail (ja)" "no" \
  "$(awk '/^8\. \*\*コードのPR\*\*/ {n=1} n && /専用のスロット上限/ {f=1} END {exit !f}' ../README.ja.md && echo yes || echo no)"
t "the carve-out says which line to anchor on" "yes" \
  "$(grep -qF 'ANCHOR it on the diff line' /tmp/re_run.sh && echo yes || echo no)"

# ---------- Caps tuned before REVIEW.md existed ----------
t "both modes cap findings at the same number" "2" "$(grep -c 'Report at most 5 findings, most severe first' /tmp/re_run.sh)"
t "no mode still says 3"                       "0" "$(grep -c 'Report at most 3 findings' /tmp/re_run.sh)"
# The engine and the two READMEs state the same number, or this change
# makes a documented claim false — which is the very check it adds.
t "README.md states the same number"           "yes" \
  "$(grep -qF 'at most 5 findings' ../README.md && echo yes || echo no)"
t "README.ja.md states the same number"        "yes" \
  "$(grep -qF '最大5件' ../README.ja.md && echo yes || echo no)"
t "the PR description cap is named, not inline" "yes" \
  "$(grep -qF 'head -c "$PR_BODY_CAP"' /tmp/re_run.sh && echo yes || echo no)"
t "...and lives in the Byte caps block" "3" \
  "$(awk '/# ---------- Byte caps ----------/ {b=1} b && /^(PR_BODY_CAP|README_CAP|README_TOTAL_CAP)=/ {n++} b && /# ---------- Repository guidance/ {exit} END {print n+0}' /tmp/re_run.sh)"
t "the header arithmetic mentions both new budgets" "yes" \
  "$(grep -qF 'READMEs 64 KiB + PR body' "$ENGINE" && echo yes || echo no)"

t_summary
