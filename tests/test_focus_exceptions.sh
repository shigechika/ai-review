#!/bin/bash
# The code-mode reporting bar admits exactly two classes that name no
# failing input: a README claim the diff falsifies, and redundancy the
# diff leaves behind. Each needs THREE places to agree — the positive
# admission clause, the exception list, and the verifier's own criterion
# — or the class is filtered out before anything can report it. That is
# the failure this file exists to catch (PR #64, where the exception was
# added to the exclusion list alone and could never have fired).
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./lib.sh

extract_run > /tmp/fe_run.sh
extract_between "focus_para='Focus on: real bugs" "most severe first.'" > /tmp/fe_code.txt
t "code-mode paragraph extracted"     "yes" "$([ -s /tmp/fe_code.txt ] && echo yes || echo no)"
t "...and it terminates"              "yes" "$(tail -1 /tmp/fe_code.txt | grep -qF 'most severe first' && echo yes || echo no)"
extract_between "vsystem='You are a skeptical verifier" "Keep each reason under 15" > /tmp/fe_v.txt
t "verifier prompt extracted"         "yes" "$([ -s /tmp/fe_v.txt ] && echo yes || echo no)"
t "...and it terminates"              "yes" "$(tail -1 /tmp/fe_v.txt | grep -qF 'Keep each reason' && echo yes || echo no)"

# ---------- The redundancy check ----------
t "redundancy: described in the focus paragraph" "yes" \
  "$(grep -qF 'leave redundancy behind' /tmp/fe_code.txt && echo yes || echo no)"
t "redundancy: both sides must be cited"         "yes" \
  "$(grep -qF 'cite BOTH sides' /tmp/fe_code.txt && echo yes || echo no)"
t "redundancy: absence from the prompt is not evidence" "yes" \
  "$(grep -qF 'absence here is not evidence of absence' /tmp/fe_code.txt && echo yes || echo no)"
t "redundancy: not a style opinion"              "yes" \
  "$(grep -qF 'not a style or naming opinion' /tmp/fe_code.txt && echo yes || echo no)"
t "redundancy: scoped to what the diff touches"  "yes" \
  "$(grep -qF 'does not extend to code the diff does not touch' /tmp/fe_code.txt && echo yes || echo no)"

# ---------- All three places must agree ----------
# 1. the positive clause, or the class never reaches the exception list
t "admission clause names both extra checks" "yes" \
  "$(grep -qF 'for the two checks described' /tmp/fe_code.txt && echo yes || echo no)"
t "...including the duplication one"         "yes" \
  "$(grep -qF 'the two locations the duplication spans' /tmp/fe_code.txt && echo yes || echo no)"
# 2. the exception list itself, closed and counted
t "the list says exactly two exceptions"     "yes" \
  "$(grep -qF 'Exactly two exceptions to that list' /tmp/fe_code.txt && echo yes || echo no)"
t "...and the second one is the redundancy check" "yes" \
  "$(awk '/Exactly two exceptions/ {n = 1} n && /^Two: redundancy THIS DIFF leaves behind/ {f = 1} END {exit !f}' /tmp/fe_code.txt && echo yes || echo no)"
t "...and both come after the Do-NOT list closes" "yes" \
  "$(awk '/findings ledger marks fixed or/ {seen = 1} seen && /Exactly two exceptions/ {f = 1} END {exit !f}' /tmp/fe_code.txt && echo yes || echo no)"
# 3. the verifier, or every such finding is silently dropped
t "verifier is told redundancy changes no behavior" "yes" \
  "$(grep -qF 'a redundancy finding change no runtime behavior' /tmp/fe_v.txt && echo yes || echo no)"
t "verifier is given something it CAN check instead" "yes" \
  "$(grep -qF 'equivalent or really dead' /tmp/fe_v.txt && echo yes || echo no)"

t_summary
