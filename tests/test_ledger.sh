#!/bin/bash
# Ledger merge, severity carry-forward/corroboration, cap eviction and
# verdict computation. The jq programs are extracted from the engine file
# itself (not retyped) so a future edit that changes behavior fails this
# suite instead of silently diverging from it.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./lib.sh

extract_between 'merged=$(jq -n -c' "2>/dev/null || true)" | extract_quoted > /tmp/merge.jq
extract_between 'LEDGER_RESULT=$(jq -n -c' "2>/dev/null || true)" | extract_quoted > /tmp/cap.jq
extract_between '# ---------- Render the visible review body ----------' 'kept.txt | iconv' \
  | extract_quoted > /tmp/render.awk
[ -s /tmp/merge.jq ] || { echo "FAIL: could not extract the merge jq program"; exit 1; }
[ -s /tmp/cap.jq ] || { echo "FAIL: could not extract the cap/ledger-result jq program"; exit 1; }
[ -s /tmp/render.awk ] || { echo "FAIL: could not extract the render-step awk program"; exit 1; }
t "merge.jq has no apostrophes"  "0" "$(grep -c "'" /tmp/merge.jq)"
t "cap.jq has no apostrophes"    "0" "$(grep -c "'" /tmp/cap.jq)"
t "render.awk has no apostrophes" "0" "$(grep -c "'" /tmp/render.awk)"

run_merge() { # old model emitted round
  jq -n -c --argjson old "$1" --argjson model "$2" --argjson emitted "$3" --arg round "$4" "$(cat /tmp/merge.jq)"
}

# ---------- Severity carry-forward across a quiet round ----------
OLD='[{"id":"R1F1","summary":"still open, was blocking","status":"open","severity":"blocking"},{"id":"R1F2","summary":"fixed earlier","status":"fixed","severity":"advisory"}]'
out=$(run_merge "$OLD" '[]' '[]' 2)
t "merge: severity survives a round with zero model findings" \
  "blocking" "$(printf '%s' "$out" | jq -r '.[] | select(.id=="R1F1").severity')"
t "merge: settled entries keep their status" \
  "fixed" "$(printf '%s' "$out" | jq -r '.[] | select(.id=="R1F2").status')"

# ---------- Status transitions from the digest alone ----------
MODEL_FIX='[{"id":"R1F1","summary":"still open, was blocking","status":"fixed","severity":"blocking"}]'
out=$(run_merge "$OLD" "$MODEL_FIX" '[]' 2)
t "merge: status can transition without a finding block" \
  "fixed" "$(printf '%s' "$out" | jq -r '.[] | select(.id=="R1F1").status')"

# ---------- Severity corroboration gate (self-review R1F1 fix) ----------
MODEL_DOWNGRADE='[{"id":"R1F1","summary":"still open, was blocking","status":"open","severity":"advisory"}]'
out=$(run_merge "$OLD" "$MODEL_DOWNGRADE" '[]' 2)
t "merge: uncorroborated severity downgrade rejected" \
  "blocking" "$(printf '%s' "$out" | jq -r '.[] | select(.id=="R1F1").severity')"
out=$(run_merge "$OLD" "$MODEL_DOWNGRADE" '["R1F1"]' 2)
t "merge: corroborated severity downgrade accepted" \
  "advisory" "$(printf '%s' "$out" | jq -r '.[] | select(.id=="R1F1").severity')"

# ---------- normsev case-insensitivity (must match the render step) ----------
# A model-emitted case variant ("Blocking") must normalize the same way
# normsev does everywhere else in this file — a case-sensitive normsev
# would silently fold it to advisory with no visible signal, while the
# render step (which matches case-insensitively) shows the same finding
# as cleanly-classified. Found reviewing #17's render-step fix, which
# exposed that normsev itself disagreed with it.
MODEL_CASE_VARIANT='[{"id":"R2F1","summary":"new finding","status":"open","severity":"Blocking"}]'
out=$(run_merge '[]' "$MODEL_CASE_VARIANT" '["R2F1"]' 2)
t "merge: new finding with case-variant severity normalizes to blocking" \
  "blocking" "$(printf '%s' "$out" | jq -r '.[] | select(.id=="R2F1").severity')"

OLD_UPPER='[{"id":"R1F1","summary":"still open","status":"open","severity":"blocking"}]'
MODEL_CASE_CORROBORATE='[{"id":"R1F1","summary":"still open","status":"open","severity":"ADVISORY"}]'
out=$(run_merge "$OLD_UPPER" "$MODEL_CASE_CORROBORATE" '["R1F1"]' 2)
t "merge: corroborated case-variant severity downgrade normalizes" \
  "advisory" "$(printf '%s' "$out" | jq -r '.[] | select(.id=="R1F1").severity')"

# ---------- Future-round id rejection (pre-existing invariant) ----------
MODEL_FUTURE='[{"id":"R2F1","summary":"new finding","status":"open","severity":"advisory"},{"id":"R3F9","summary":"future id","status":"dismissed","severity":"advisory"}]'
out=$(run_merge '[]' "$MODEL_FUTURE" '["R2F1","R3F9"]' 2)
t "merge: current-round id accepted"  "open" "$(printf '%s' "$out" | jq -r '.[] | select(.id=="R2F1").status')"
t "merge: future-round id rejected"   ""     "$(printf '%s' "$out" | jq -r '.[] | select(.id=="R3F9").status')"

# ---------- Ledger cap: severity-aware eviction ----------
run_cap() { # base old kept dropped round
  jq -n -c --argjson base "$1" --argjson old "$2" --argjson kept "$3" --argjson dropped "$4" --arg round "$5" "$(cat /tmp/cap.jq)"
}
python3 -c "
import json
findings = [{'id': f'R1F{i}', 'summary': f'adv {i}', 'status': 'open', 'severity': 'advisory'} for i in range(90)]
findings += [{'id': f'R1B{i}', 'summary': f'block {i}', 'status': 'open', 'severity': 'blocking'} for i in range(5)]
print(json.dumps(findings))
" > /tmp/base95.json
out=$(run_cap "$(cat /tmp/base95.json)" '[]' '[]' '[]' 1)
t "cap: all blocking-open survive a 95->80 shed" \
  "5" "$(printf '%s' "$out" | jq -r '[.findings[] | select(.severity=="blocking")] | length')"
t "cap: advisory-open trimmed to fill remaining room" \
  "75" "$(printf '%s' "$out" | jq -r '[.findings[] | select(.severity=="advisory")] | length')"
t "cap: precap_n reports the true pre-cap count" \
  "95" "$(printf '%s' "$out" | jq -r '.precap_n')"

python3 -c "
import json
findings = [{'id': f'S{i}', 'summary': 'settled', 'status': 'fixed', 'severity': 'advisory'} for i in range(151)]
findings += [{'id': f'O{i}', 'summary': 'open', 'status': 'open', 'severity': 'advisory'} for i in range(50)]
print(json.dumps(findings))
" > /tmp/base201.json
out=$(run_cap "$(cat /tmp/base201.json)" '[]' '[]' '[]' 1)
t "cap regression: settled-first still holds (settled kept)" \
  "80" "$(printf '%s' "$out" | jq -r '[.findings[] | select(.status=="fixed")] | length')"
t "cap regression: settled-first still holds (open shed to 0)" \
  "0" "$(printf '%s' "$out" | jq -r '[.findings[] | select(.status=="open")] | length')"

out=$(run_cap '[{"id":"R1F1","summary":"x","status":"open","severity":"blocking"}]' '[]' '[]' '[]' 1)
t "cap: under-cap list passes through unchanged" \
  '[{"id":"R1F1","summary":"x","status":"open","severity":"blocking"}]' \
  "$(printf '%s' "$out" | jq -c '.findings')"

# ---------- carried_open filter (only pre-existing open ids) ----------
OLD_OPEN='[{"id":"R1F1","summary":"still open, was blocking","status":"open","severity":"blocking"}]'
FINAL2='[{"id":"R1F1","summary":"still open, was blocking","status":"open","severity":"blocking"},{"id":"R2F1","summary":"brand new this round","status":"open","severity":"advisory"}]'
carried=$(printf '%s' "$FINAL2" | jq -r --argjson old "$OLD_OPEN" '
  ($old | map(select(.status == "open") | .id)) as $oldopen
  | [.[] | select(.status == "open" and (.id as $i | $oldopen | index($i)))]
  | .[] | .id
')
t "carried_open: shows the pre-existing open id"  "R1F1" "$carried"
t "carried_open: excludes this round's new id"    "0"    "$(printf '%s' "$carried" | grep -c R2F1 || true)"

# ---------- Verdict counting (from FINAL_FINDINGS, not this round's kept.txt) ----------
FINAL='[{"id":"R1F1","status":"open","severity":"blocking","summary":"x"},{"id":"R1F2","status":"fixed","severity":"advisory","summary":"x"},{"id":"R1F3","status":"open","severity":"advisory","summary":"x"},{"id":"R1F4","status":"open","summary":"x"}]'
b=$(printf '%s' "$FINAL" | jq -r '[.[] | select(.status == "open" and .severity == "blocking")] | length')
a=$(printf '%s' "$FINAL" | jq -r '[.[] | select(.status == "open" and .severity != "blocking")] | length')
t "verdict: blocking counted from all-open, any round" "1" "$b"
t "verdict: missing-severity entry counts as advisory"  "2" "$a"

# Structural check: the verdict block must reference FINAL_FINDINGS, not
# kept.txt — this is the exact regression class the fix closed.
t "engine: verdict reads FINAL_FINDINGS" "yes" \
  "$(grep -A2 -F '# ---------- Verdict ----------' "$ENGINE" | grep -qF 'kept.txt' && echo no || echo yes)"
t "engine: blocking_n is computed from FINAL_FINDINGS" "yes" \
  "$(grep -qF 'blocking_n=$(printf '"'"'%s'"'"' "$FINAL_FINDINGS"' "$ENGINE" && echo yes || echo no)"

# ---------- Render-step severity handling ----------
# Regression coverage for a bug found and fixed in one pass: the render
# step used to strip EVERY severity line unconditionally, so a malformed
# one (a typo, an empty value) rendered identically to an ordinary,
# cleanly-classified advisory finding — the reader had no way to tell the
# model emitted something unparseable. The fix must (a) still silently
# drop a cleanly-classified line, case-INsensitively — same normalization
# normsev already applies elsewhere in this file — since a case-sensitive
# check here would let e.g. "severity: Blocking" count as blocking in the
# ledger while rendering as a "treated as advisory" note, contradicting
# the verdict line right above it in the same comment; (b) surface
# anything else with a bounded, visible marker.
render_kept() { printf '%s\n' "$1" | awk -f /tmp/render.awk; }

t "render: clean lowercase severity is dropped silently" \
  "0" "$(render_kept $'===FINDING R1F1===\nfoo\nseverity: blocking\nbar\n===END FINDING===' | grep -c 'malformed severity')"
t "render: clean severity is case-insensitive (Blocking)" \
  "0" "$(render_kept $'===FINDING R1F1===\nfoo\nseverity: Blocking\nbar\n===END FINDING===' | grep -c 'malformed severity')"
t "render: clean severity is case-insensitive (ADVISORY)" \
  "0" "$(render_kept $'===FINDING R1F1===\nfoo\nseverity: ADVISORY\nbar\n===END FINDING===' | grep -c 'malformed severity')"
t "render: mistyped severity is surfaced" \
  "1" "$(render_kept $'===FINDING R1F1===\nfoo\nseverity: blockingish\n===END FINDING===' | grep -c 'malformed severity')"
t "render: empty severity value is surfaced" \
  "1" "$(render_kept $'===FINDING R1F1===\nfoo\nseverity: \n===END FINDING===' | grep -c '(empty)')"
t "render: a finding block missing the severity line entirely stays unmarked" \
  "0" "$(render_kept $'===FINDING R1F1===\nno severity line at all\n===END FINDING===' | grep -c 'malformed severity')"
long_val=$(python3 -c "print('x' * 250)")
t "render: an over-length malformed value is capped at 200 chars + ellipsis" \
  "203" "$(render_kept "===FINDING R1F1===
severity: $long_val
===END FINDING===" | grep -o 'x*\.\.\.' | head -1 | tr -d '\n' | wc -c | tr -d ' ')"
t "render: a capitalized Severity: key is also recognized" \
  "1" "$(render_kept $'===FINDING R1F1===\nfoo\nSeverity: blockingish\n===END FINDING===' | grep -c 'malformed severity')"
t "render: a capitalized Severity: key with a clean value still drops silently" \
  "0" "$(render_kept $'===FINDING R1F1===\nfoo\nSeverity: blocking\nbar\n===END FINDING===' | grep -c 'malformed severity')"

# render_kept_utf8 runs the same production pipeline as the engine
# (awk | iconv -f UTF-8 -t UTF-8 -c) so a byte-truncated multibyte tail
# gets dropped rather than left as invalid UTF-8 in the output.
render_kept_utf8() { printf '%s\n' "$1" | awk -f /tmp/render.awk | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null; }
ja_val=$(python3 -c "print('あ' * 100)")  # 100 * 3 bytes = 300 bytes, well past the 200-byte cap
out=$(render_kept_utf8 "===FINDING R1F1===
severity: $ja_val
===END FINDING===")
t "render: a multibyte value truncated at the 200-byte cap stays valid UTF-8" \
  "yes" "$(printf '%s' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && echo yes || echo no)"

t_summary
