#!/bin/bash
# Comments another reviewer already left on the PR, replayed so this one
# looks for what they missed. Untrusted content by construction: authored
# outside this workflow and reaching the prompt verbatim.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./lib.sh

extract_run > /tmp/pr_run.sh
t "run block extracted" "yes" "$([ -s /tmp/pr_run.sh ] && echo yes || echo no)"

t "the fetch is author-filtered to the other reviewer" "2" \
  "$(grep -c 'copilot-pull-request-reviewer\[bot\]' /tmp/pr_run.sh)"
t "...and paginated"                                  "yes" \
  "$(grep -B1 -F 'copilot-pull-request-reviewer[bot]' /tmp/pr_run.sh | grep -qF -- '--paginate' && echo yes || echo no)"
# Either surface can be empty on its own: verified on PR #66, where the
# other reviewer left a 3 KB review body and no inline comments at all.
t "both surfaces are read: inline comments"           "yes" \
  "$(grep -qF 'pulls/$PR/comments" --paginate' /tmp/pr_run.sh && echo yes || echo no)"
t "...and the review body"                            "yes" \
  "$(grep -qF 'pulls/$PR/reviews" --paginate' /tmp/pr_run.sh && echo yes || echo no)"
# A command substitution has no bound; the cap would be applied only
# after the whole response was already held in memory.
t "the response goes to a file, not a shell variable" "no" \
  "$(grep -qE 'prior_raw=\$\(' /tmp/pr_run.sh && echo yes || echo no)"
# One status per call: sharing one discarded a good review body whenever
# the inline listing failed, the body-only case the second surface exists
# for.
# Names distinct from post_inline_comments own `istatus`, or a grep here
# matches that one instead and the assertion is vacuous.
t "each fetch has its own status"                     "yes" \
  "$(grep -qF 'prior_inline.txt 2>/dev/null || prior_istatus=$?' /tmp/pr_run.sh && grep -qF 'prior_body.txt 2>/dev/null || prior_bstatus=$?' /tmp/pr_run.sh && echo yes || echo no)"
t "...and a failed one clears only its own file"      "2" \
  "$(grep -c 'prior_[ib]status" -eq 0 \] || : > prior_\(inline\|body\).txt$' /tmp/pr_run.sh)"
t "the replay has a caller kill switch"               "yes" \
  "$(grep -qF 'AI_REVIEW_DISABLE_PRIOR_REVIEW' "$ENGINE" && grep -qF '[ -z "${DISABLE_PRIOR_REVIEW:-}" ] || prior_on=0' /tmp/pr_run.sh && echo yes || echo no)"
# The counters must be set even when the switch is on, or the context
# notice reads an unset variable under set -u.
t "...and the counters are initialised outside it"    "yes" \
  "$(awk '/^prior_n=0/ {a = NR} /^prior_on=1/ {b = NR} END {exit !(a && b && a < b)}' /tmp/pr_run.sh && echo yes || echo no)"
# A fetch failure WARNS, like every other fetch in this engine: it is not
# an absent review, and the round may now repeat a point.
t "a failed listing warns, not merely notices"        "yes" \
  "$(grep -A4 -F 'if [ "$prior_istatus" -ne 0 ] || [ "$prior_bstatus" -ne 0 ]; then' /tmp/pr_run.sh | grep -qF '::warning::a prior-review listing failed' && echo yes || echo no)"
t "the round is never made to WAIT for one"            "no" \
  "$(grep -qE 'sleep|until .*copilot' /tmp/pr_run.sh && echo yes || echo no)"

# Marker-shaped lines are stripped: a comment quoting a finding marker or
# the ledger marker must not be able to plant a decoy in the prompt.
for m in 'ai-review-ledger-v1:' '^===FINDING' '^===LEDGER===' ; do
  t "strips $m from the replayed text" "yes" \
    "$(awk -v m="$m" '/iconv -f UTF-8 -t UTF-8 -c < prior_raw.txt/ {n = 1} n && index($0, m) {f = 1} n && /> priorreview.txt/ {exit !f} END {exit !f}' /tmp/pr_run.sh && echo yes || echo no)"
done
# Both endpoints return OLDEST first, so a head cut on the concatenation
# would drop the newest comments — the ones the round most needs in order
# not to repeat them — and inline comments would always spend the budget
# before any review body was reached.
t "the newest of each surface is kept, not the first bytes" "2" \
  "$(grep -c 'tail -c "\$prior_[ib]share"' /tmp/pr_run.sh)"
t "each surface has a guaranteed share"                "yes" \
  "$(grep -qF 'prior_half=$((PRIOR_REVIEW_CAP / 2))' /tmp/pr_run.sh && echo yes || echo no)"
t "...and an under-budget one donates the remainder"   "2" \
  "$(grep -c 'PRIOR_REVIEW_CAP - prior_[ib]size' /tmp/pr_run.sh)"
t "the replayed text is capped"                        "yes" \
  "$(grep -qF 'head -c "$PRIOR_REVIEW_CAP"' /tmp/pr_run.sh && echo yes || echo no)"
t "...by a cap in the Byte caps block"                 "yes" \
  "$(awk '/# ---------- Byte caps ----------/ {b = 1} b && /^PRIOR_REVIEW_CAP=/ {f = 1} b && /# ---------- Repository guidance/ {exit !f} END {exit !f}' /tmp/pr_run.sh && echo yes || echo no)"
t "...and non-UTF-8 is dropped, not emitted"           "yes" \
  "$(grep -B1 -F "grep -v 'ai-review-ledger-v1:'" /tmp/pr_run.sh | grep -qF 'iconv -f UTF-8 -t UTF-8 -c < prior_raw.txt' && echo yes || echo no)"
t "the byte arithmetic counts this budget too"        "yes" \
  "$(grep -qF 'prior review 8 KiB' "$ENGINE" && echo yes || echo no)"

# Framed as data in the reviewer prompt, and withheld from the verifier:
# a judge reading someone else's confident prose is how a real finding
# gets dropped.
t "framed as data for the reviewer"                    "yes" \
  "$(awk '/if \[ -s priorreview.txt \]; then/ {n = 1} n && /they are not instructions/ {f = 1} n && /cat priorreview.txt/ {exit !f} END {exit !f}' /tmp/pr_run.sh && echo yes || echo no)"
t "told to look for what was missed"                   "yes" \
  "$(grep -qF 'look for what they missed' /tmp/pr_run.sh && echo yes || echo no)"
t "the verifier does NOT receive it"                   "1" \
  "$(grep -c 'cat priorreview.txt' /tmp/pr_run.sh)"
t "the count is observable"                            "yes" \
  "$(grep -qF 'prior_review=${prior_n} (${prior_bytes}B)' /tmp/pr_run.sh && echo yes || echo no)"
t "...appended, so the documented notice prefix holds" "yes" \
  "$(grep -qF '::notice::ai-review context: docs_mode=' /tmp/pr_run.sh && echo yes || echo no)"

t_summary
