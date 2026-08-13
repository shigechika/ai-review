#!/bin/bash
# Fetch-path observability (#48): telling a failed fetch apart from a file
# that genuinely is not there, labelling TRUNCATED on what the CAP actually
# clamped, and noticing a verifier response this engine cannot read.
#
# The three used to share one failure shape — a silent fallback that looked
# exactly like the healthy case — so each check here asserts the DISTINGUISHING
# signal, not merely that the happy path still works.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./lib.sh

# ---------- fetch classification: 404 is silent, anything else warns ----------
# Mirrors the engine's branch. Extracted rather than retyped where the shape
# allows; this one spans a for-loop body, so the structural greps below are
# what tie it to the real code.
classify_fetch() { # <gh-exit-status> <stderr-text>
  local gstatus="$1" err="$2" out=""
  printf '%s' "$err" > /tmp/fetch_err.txt
  if [ "$gstatus" -ne 0 ]; then
    if ! grep -q "HTTP 404" /tmp/fetch_err.txt; then
      out="WARN"
    else
      out="SILENT"
    fi
  else
    out="OK"
  fi
  printf '%s' "$out"
}

t "fetch: 404 is silent (the file simply is not there)" \
  "SILENT" "$(classify_fetch 1 'gh: Not Found (HTTP 404)')"
t "fetch: 500 warns" \
  "WARN" "$(classify_fetch 1 'gh: Internal Server Error (HTTP 500)')"
t "fetch: rate limit warns" \
  "WARN" "$(classify_fetch 1 'gh: API rate limit exceeded (HTTP 403)')"
t "fetch: network failure with no HTTP status warns" \
  "WARN" "$(classify_fetch 1 'dial tcp: lookup api.github.com: no such host')"
t "fetch: success is neither" \
  "OK" "$(classify_fetch 0 '')"

# ---------- TRUNCATED is decided by the cap, not by iconv ----------
# total = size the API reported, clamped = bytes after head -c, sent = bytes
# after iconv -c. Only clamped < total means the CAP cut the file.
# Takes `sent` as well, even though the correct rule ignores it, so the OLD
# buggy basis is expressible here: a mirror that only ever saw `clamped`
# could not distinguish the two rules, and reverting the engine to `sent`
# would leave every assertion green.
label() { # <total> <clamped> <sent>
  if [ "$2" -lt "$1" ]; then printf 'TRUNCATED'; else printf 'FULL'; fi
}
label_old_buggy() { # the pre-fix rule, kept only to prove the cases differ
  if [ "$3" -lt "$1" ]; then printf 'TRUNCATED'; else printf 'FULL'; fi
}

t "label: under the cap, clean UTF-8 -> FULL" "FULL"      "$(label 1000 1000 1000)"
t "label: cap actually clamped -> TRUNCATED"  "TRUNCATED" "$(label 9000 8192 8192)"
# The regression this exists for: iconv drops a stray invalid byte from a file
# the cap never touched. clamped stays 1000 while sent falls to 999.
t "label: iconv dropped a byte, cap did not clamp -> FULL" \
  "FULL" "$(label 1000 1000 999)"
# ...and the same input under the old rule, to prove the two disagree. If this
# ever stops being TRUNCATED the case above has gone vacuous.
t "label: that same input WAS mislabelled by the old sent-based rule" \
  "TRUNCATED" "$(label_old_buggy 1000 1000 999)"

# ---------- verifier: unreadable output is not "nothing to drop" ----------
# Distinct ids carrying a readable verdict — mirrors the engine, which
# compares this against the candidate id count so a PARTIAL answer is
# visible too, not only a wholly unreadable one.
# No "no candidate ids" fallback: the engine ALWAYS pipes through
# `grep -Fxf vids.txt`, and an empty pattern file matches nothing. A mirror
# that counted everything in that case would assert numbers the engine can
# never produce.
conforming() { # <verdict-text> <candidate-ids> -> count of answered candidates
  printf '%s\n' "$2" | tr '[:lower:]' '[:upper:]' | grep . > /tmp/vids_test.txt || true
  printf '%s\n' "$1" \
    | grep -oiE '^[[:space:]]*[A-Za-z0-9]+[[:space:]]*:[[:space:]]*(KEEP|DROP)' \
    | cut -d: -f1 | tr -d ' \t' | tr '[:lower:]' '[:upper:]' | sort -u \
    | { grep -Fxf /tmp/vids_test.txt || true; } | grep -c . || true
}

# note <conform> <wanted> — mirrors the engine's three-way branch.
note() {
  if [ "$1" -eq 0 ]; then printf 'UNREADABLE'
  elif [ "$1" -lt "$2" ]; then printf 'PARTIAL'
  else printf 'NONE'; fi
}

t "verifier note: full coverage -> no note"      "NONE"       "$(note 3 3)"
t "verifier note: partial coverage -> PARTIAL"   "PARTIAL"    "$(note 1 3)"
t "verifier note: nothing readable -> UNREADABLE" "UNREADABLE" "$(note 0 3)"
t "verifier note: duplicate verdicts do not inflate coverage" \
  "PARTIAL" "$(note "$(conforming 'R1F1: KEEP - a
R1F1: DROP - b' 'R1F1
R1F2')" 2)"
# The verifier answering for ids that were never candidates must not count.
t "verifier: invented ids do not count towards coverage" \
  "1" "$(conforming 'R1F1: KEEP - real
R9F9: DROP - invented
R8F8: DROP - invented' 'R1F1
R1F2')"
# Both sides deduplicate, so a model emitting the same id twice must not
# look permanently under-answered.
wanted() { printf '%s\n' "$1" | tr '[:lower:]' '[:upper:]' | grep . | sort -u | grep -c . || true; }
t "verifier note: a duplicated CANDIDATE id does not inflate the target" \
  "NONE" "$(note "$(conforming 'R1F1: KEEP - a
R1F2: KEEP - b' 'R1F1
R1F1
R1F2')" "$(wanted 'R1F1
R1F1
R1F2')")"

t "verifier note: invented ids cannot mask an unanswered candidate" \
  "PARTIAL" "$(note "$(conforming 'R1F1: KEEP - real
R9F9: DROP - invented' 'R1F1
R1F2')" 2)"

t "verifier: all KEEP is readable (0 drops, but verified)" \
  "2" "$(conforming 'R1F1: KEEP - holds up
R1F2: KEEP - holds up' 'R1F1
R1F2')"
t "verifier: mixed verdicts are readable" \
  "2" "$(conforming 'R1F1: DROP - refuted by line 12
R1F2: KEEP - stands' 'R1F1
R1F2')"
t "verifier: indented verdicts still readable" \
  "1" "$(conforming '   R1F1: DROP - refuted' 'R1F1')"
t "verifier: lowercase still readable" \
  "1" "$(conforming 'r1f1: keep - fine' 'R1F1')"
t "verifier: prose answer is NOT readable" \
  "0" "$(conforming 'I reviewed the findings and they all look reasonable to me.' 'R1F1')"
t "verifier: markdown-wrapped verdicts are NOT readable" \
  "0" "$(conforming '- **R1F1**: DROP - refuted' 'R1F1')"

# ---------- structural checks against the real engine ----------
t "engine: guidance fetch captures gh exit status separately" "yes" \
  "$(grep -qF 'meta=$(gh api "repos/$GH_REPO/contents/$f?ref=$BASE_SHA" \' "$ENGINE" \
     && grep -qF '2>gerr.txt) || gstatus=$?' "$ENGINE" && echo yes || echo no)"

t "engine: REVIEW.md fetch captures gh exit status separately" "yes" \
  "$(grep -qF '2>rerr.txt) || rstatus=$?' "$ENGINE" && echo yes || echo no)"

t "engine: a non-404 guidance failure warns" "yes" \
  "$(grep -qF '::warning::guidance $f: fetch failed' "$ENGINE" && echo yes || echo no)"

t "engine: a non-404 REVIEW.md failure warns" "yes" \
  "$(grep -qF '::warning::REVIEW.md: fetch failed' "$ENGINE" && echo yes || echo no)"

# The warning must never interpolate the captured stderr: it is untrusted for
# workflow-command purposes (a `::` sequence in it would be obeyed).
warn_lines=$(grep -F 'fetch failed' "$ENGINE")
t "engine: fetch-failure warnings extracted" "yes" \
  "$([ -n "$warn_lines" ] && echo yes || echo no)"
t "engine: fetch-failure warnings never echo the captured stderr" "yes" \
  "$(printf '%s' "$warn_lines" | grep -qE 'gerr\.txt|rerr\.txt|\$\(cat' && echo no || echo yes)"

t "engine: guidance TRUNCATED is decided on the clamped size" "yes" \
  "$(grep -qF 'if [ "$gclamped" -lt "$total" ]; then' "$ENGINE" && echo yes || echo no)"

t "engine: REVIEW.md TRUNCATED is decided on the clamped size" "yes" \
  "$(grep -qF 'if [ "$rclamped" -lt "$rtotal" ]; then' "$ENGINE" && echo yes || echo no)"

# Both halves are asserted: the cap writing the raw file, AND iconv reading
# that raw file into the body. Checking only the first half lets the iconv
# step be deleted outright — the body would then never be written and every
# guidance file would silently skip, with the structural check still green.
t "engine: guidance cap writes the raw file" "yes" \
  "$(grep -qF '| head -c "$gcap" > graw.txt' "$ENGINE" && echo yes || echo no)"
t "engine: guidance iconv reads that raw file into the body" "yes" \
  "$(grep -qF 'iconv -f UTF-8 -t UTF-8 -c < graw.txt > gbody.txt' "$ENGINE" && echo yes || echo no)"

t "engine: REVIEW.md cap writes the raw file" "yes" \
  "$(grep -qF '| head -c "$REVIEW_OVERRIDE_CAP" > rraw.txt' "$ENGINE" && echo yes || echo no)"
t "engine: REVIEW.md iconv reads that raw file into the body" "yes" \
  "$(grep -qF 'iconv -f UTF-8 -t UTF-8 -c < rraw.txt > rbody.txt' "$ENGINE" && echo yes || echo no)"

t "engine: verifier counts KEEP as well as DROP" "yes" \
  "$(grep -qF '(KEEP|DROP)' "$ENGINE" && echo yes || echo no)"

t "engine: verifier coverage is compared against the candidate ids" "yes" \
  "$(grep -qF 'vwanted=$(sort -u vids.txt' "$ENGINE" && grep -qF '"${vconform:-0}" -lt "${vwanted:-0}"' "$ENGINE" && echo yes || echo no)"

# Both sides must deduplicate or a repeated candidate id is permanently
# under-answered — a false alarm on the very signal this file exists to pin.
t "engine: the candidate count deduplicates, matching vconform's sort -u" "yes" \
  "$(grep -qF 'sort -u vids.txt' "$ENGINE" && echo yes || echo no)"

# Coverage must be intersected with the real candidate list, or a verifier
# inventing ids reaches the candidate count with real findings unanswered.
t "engine: coverage counts only ids that were actually candidates" "yes" \
  "$(grep -qF 'grep -Fxf vids.txt' "$ENGINE" && echo yes || echo no)"

t "engine: a partial verifier answer sets its own note" "yes" \
  "$(grep -qF 'Verifier answered for ${vconform} of ${vwanted} findings' "$ENGINE" && echo yes || echo no)"

t "engine: an unreadable verifier response sets a note" "yes" \
  "$(grep -qF 'Verifier output was unreadable this round' "$ENGINE" && echo yes || echo no)"

# The advisory contract: none of the new paths may exit non-zero.
new_block=$(awk '/gstatus=0$/,/^            \[ -s gbody.txt \] \|\| continue$/' "$ENGINE")
t "engine: new guidance block extracted" "yes" \
  "$([ -n "$new_block" ] && echo yes || echo no)"
t "engine: new guidance block never exits non-zero" "yes" \
  "$(printf '%s' "$new_block" | grep -qE '^\s*exit [1-9]' && echo no || echo yes)"

t_summary
