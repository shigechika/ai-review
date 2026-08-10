#!/bin/bash
# REVIEW.md support: the repository-specific review override spliced into
# the system prompt ahead of focus_para. Deny-list coverage lives in
# test_deny_list.sh (extracted from the same case block every other path
# uses); this file covers the fetch/injection logic specific to REVIEW.md.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./lib.sh

# ---------- review_override_block conditional (extracted, not retyped) -----
# The engine's if/else spans a multi-line single-quoted bash string
# assignment, so extract_between's end-literal cannot land exactly on the
# closing `fi` (the assignment body itself contains the substring "fi",
# e.g. inside "specified") — it lands on the unique else-branch line
# instead, and a literal `fi` is appended before eval, mirroring how
# test_docs_mode.sh's README-sibling section handles the same shape.
cond_file="/tmp/review_override_cond.txt"
extract_between 'if [ -s review_override.txt ]; then' "review_override_block=''" > "$cond_file"
echo "fi" >> "$cond_file"
[ -s "$cond_file" ] || { echo "FAIL: could not extract the review_override_block conditional"; exit 1; }

run_review_override() { # review_override_content ("" means file absent)
  local dir
  dir="$(mktemp -d)"
  if [ -n "$1" ]; then
    printf '%s' "$1" > "$dir/review_override.txt"
  fi
  ( cd "$dir" && eval "$(cat "$cond_file")" && printf '%s' "$review_override_block" )
  rm -rf "$dir"
}

t "review-override: no REVIEW.md -> block is empty" \
  "" "$(run_review_override '')"

block_with_content="$(run_review_override 'Report unused exports as blocking.')"
t "review-override: REVIEW.md present -> block carries its content" \
  "yes" "$(echo "$block_with_content" | grep -qF 'Report unused exports as blocking.' && echo yes || echo no)"
t "review-override: block instructs following rules, not just showing them" \
  "yes" "$(echo "$block_with_content" | grep -qF 'Follow the rules below as' && echo yes || echo no)"
t "review-override: block covers additions the default reporting bar would exclude" \
  "yes" "$(echo "$block_with_content" | grep -qF 'Do NOT report' && echo yes || echo no)"

# ---------- Structural checks against the real engine ----------
t "engine: REVIEW.md fetched at BASE_SHA, not HEAD" "yes" \
  "$(grep -qF 'repos/$GH_REPO/contents/REVIEW.md?ref=$BASE_SHA' "$ENGINE" && echo yes || echo no)"

t "engine: REVIEW.md has its own cap, separate from GUIDANCE_TOTAL_CAP" "yes" \
  "$(grep -qF 'REVIEW_OVERRIDE_CAP=8192' "$ENGINE" && echo yes || echo no)"

# The fetch block must sit OUTSIDE the guidance for/done loop, i.e. after
# its closing `done`, not sharing guidance_total's budget accounting.
t "engine: REVIEW.md fetch does not touch guidance_total" "yes" \
  "$(awk '/REVIEW_OVERRIDE_CAP=8192/,/^          fi$/' "$ENGINE" | grep -qF 'guidance_total' && echo no || echo yes)"

t "engine: review_override_block is spliced ahead of focus_para in the system prompt" "yes" \
  "$(grep -qF '"$review_override_block""$focus_para"' "$ENGINE" && echo yes || echo no)"

t "engine: override is documented as NOT changing the Output format contract" "yes" \
  "$(grep -qF 'changes the mandatory Output format' "$ENGINE" && echo yes || echo no)"

t "engine: verifier prompt also receives review_override.txt" "yes" \
  "$(grep -qF 'cat review_override.txt' "$ENGINE" && echo yes || echo no)"

t "engine: context notice reports review_override byte count" "yes" \
  "$(grep -qF 'review_override=$(wc -c < review_override.txt' "$ENGINE" && echo yes || echo no)"

t_summary
