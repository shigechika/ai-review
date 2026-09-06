#!/bin/bash
# feature_switch: the one parser behind AI_REVIEW_IMPORTS / _README /
# _PRIOR_REVIEW.
#
# This suite EXECUTES the function extracted from the committed YAML
# rather than grepping for its text. A grep cannot tell `default 1` from
# `default 0`, which is the whole substance of this change — the previous
# three assertions it replaces did exactly that, and every one of them
# would have passed against a build where all three features were on.
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/lib.sh
. ./lib.sh

extract_run > /tmp/fs_run.sh
# The initialiser line first, the closing brace last. `FEATURE_ON=0`
# appears again INSIDE the function (the legacy branch), and `}` appears
# nowhere in the body, so first-match/next-match brackets the whole thing.
extract_between 'FEATURE_ON=0' '}' > /tmp/fs_fn.sh

# Non-empty FIRST, as its own check. An awk/extract range whose start
# anchor stopped matching yields nothing, and nearly every assertion
# below would then pass vacuously against an empty file.
t "feature_switch extracted"                    "yes" \
  "$([ -s /tmp/fs_fn.sh ] && grep -qF 'feature_switch() {' /tmp/fs_fn.sh && echo yes || echo no)"
t "...and the extraction is closed"             "yes" \
  "$(tail -1 /tmp/fs_fn.sh | grep -qxF '}' && echo yes || echo no)"

# sw <new-value> <legacy-value> <default> -> "on=<0|1> rc=<status> <log>"
# Runs in a subshell so a leaked variable cannot carry between cases.
sw() {
  (
    set -u
    # shellcheck disable=SC1091
    . /tmp/fs_fn.sh
    feature_switch TESTFEAT "$1" "$2" "$3" > /tmp/fs_log.txt 2>&1
    rc=$?
    printf 'on=%s rc=%s hint=[%s] %s' "$FEATURE_ON" "$rc" "$FEATURE_HINT" "$(tr '\n' ' ' < /tmp/fs_log.txt)"
  )
}

# ---- the value itself ----
t "true turns a default-off feature on"         "on=1 rc=0 hint=[set vars.AI_REVIEW_TESTFEAT=true] "  "$(sw true '' 0)"
t "false turns a default-on feature off"        "on=0 rc=0 hint=[set vars.AI_REVIEW_TESTFEAT=true] "  "$(sw false '' 1)"
t "unset takes the default (on)"                "on=1 rc=0 hint=[set vars.AI_REVIEW_TESTFEAT=true] "  "$(sw '' '' 1)"
t "unset takes the default (off)"               "on=0 rc=0 hint=[set vars.AI_REVIEW_TESTFEAT=true] "  "$(sw '' '' 0)"
# Repository variables are typed by hand in a settings form; TRUE and
# False are what people actually enter.
t "TRUE is accepted"                            "on=1 rc=0 hint=[set vars.AI_REVIEW_TESTFEAT=true] "  "$(sw TRUE '' 0)"
t "False is accepted"                           "on=0 rc=0 hint=[set vars.AI_REVIEW_TESTFEAT=true] "  "$(sw False '' 1)"

# ---- a typo must be LOUD, not silently default ----
# The failure this closes: a maintainer sets `ture`, sees no complaint,
# and believes the feature is running for weeks while it never does.
#
# Every case below keeps `rc=0` in the compared value, warning and
# deprecation paths included. The run block is `bash -e`: a branch that
# logged and then returned 1 would take the whole job down and BLOCK the
# PR, breaking the advisory contract, while an assertion that cut the
# status off after the state still passed (codex review of this commit).
t "a typo warns and keeps the default (on)"     "on=1 rc=0"   "$(sw ture '' 1 | cut -d' ' -f1,2)"
t "...and the warning actually fires"           "yes" \
  "$(case "$(sw ture '' 1)" in *"::warning::vars.AI_REVIEW_TESTFEAT"*) echo yes ;; *) echo no ;; esac)"
t "a typo keeps the default the other way too"  "on=0 rc=0"   "$(sw ture '' 0 | cut -d' ' -f1,2)"

# A repository variable is caller-controlled text reaching a log line
# that GitHub parses for workflow commands — the same hazard class as
# model output. The warning names the VARIABLE, never echoes the value.
t "the warning never echoes the value back"     "yes" \
  "$(case "$(sw '::error::pwned' '' 1)" in *'::error::pwned'*) echo no ;; *) echo yes ;; esac)"

# ---- deprecated predecessors, one release only ----
t "a legacy DISABLE_ value forces off"          "on=0 rc=0"   "$(sw '' 1 1 | cut -d' ' -f1,2)"
# Precedence is the point: a repo that set the old variable keeps its
# behaviour even if someone later adds the new one saying otherwise.
t "...and it beats an explicit new true"        "on=0 rc=0"   "$(sw true 1 1 | cut -d' ' -f1,2)"
t "...and says it is deprecated"                "yes" \
  "$(case "$(sw '' 1 1)" in *'::notice::vars.AI_REVIEW_DISABLE_TESTFEAT is deprecated'*) echo yes ;; *) echo no ;; esac)"
# The remedy has to name the LEGACY variable on this path. Advising the
# caller to set the new one is advice that changes nothing, because the
# legacy variable overrides it for as long as it is set — the whole
# point of the precedence tested two lines up. Every other path advises
# the new variable, so a single shared hint string would be wrong here.
t "...and the remedy names the legacy variable"  "yes" \
  "$(case "$(sw '' 1 1)" in *'hint=[remove the deprecated vars.AI_REVIEW_DISABLE_TESTFEAT'*) echo yes ;; *) echo no ;; esac)"
t "...and does NOT advise the new one"           "yes" \
  "$(case "$(sw '' 1 1)" in *'hint=[set vars.AI_REVIEW_TESTFEAT=true]'*) echo no ;; *) echo yes ;; esac)"

# ---- the defaults the engine actually asks for ----
# The values live at the call sites, so they are checked there. These
# are the assertions that fail if a future edit flips a default.
t "imports defaults OFF"                        "yes" \
  "$(grep -qF 'feature_switch IMPORTS "${FEATURE_IMPORTS:-}" "${DISABLE_IMPORTS:-}" 0' /tmp/fs_run.sh && echo yes || echo no)"
t "prior-review defaults OFF"                   "yes" \
  "$(grep -qF 'feature_switch PRIOR_REVIEW "${FEATURE_PRIOR_REVIEW:-}" "${DISABLE_PRIOR_REVIEW:-}" 0' /tmp/fs_run.sh && echo yes || echo no)"
t "README defaults ON"                          "yes" \
  "$(grep -qF 'feature_switch README "${FEATURE_README:-}" "${DISABLE_README:-}" 1' /tmp/fs_run.sh && echo yes || echo no)"
t "each call site consumes FEATURE_ON"          "3" \
  "$(grep -c '^[a-z_]*_on=\$FEATURE_ON$' /tmp/fs_run.sh)"
# and each off-notice must carry the computed remedy rather than a
# hardcoded one, or the deprecation path advises a no-op again.
t "each off-notice carries FEATURE_HINT"        "3" \
  "$(grep -c '::notice::.* is off for this repository . \$FEATURE_HINT ' /tmp/fs_run.sh)"

# ---- plumbing ----
t "all three variables reach the step env"      "3" \
  "$(grep -cE '^ *FEATURE_(IMPORTS|README|PRIOR_REVIEW): \$\{\{ vars\.AI_REVIEW_(IMPORTS|README|PRIOR_REVIEW) \}\}$' "$ENGINE")"
t "the deprecated three are still read"         "3" \
  "$(grep -cE '^ *DISABLE_(IMPORTS|README|PRIOR_REVIEW): \$\{\{ vars\.AI_REVIEW_DISABLE_(IMPORTS|README|PRIOR_REVIEW) \}\}$' "$ENGINE")"
t "both READMEs document all three"             "yes" \
  "$(for f in ../README.md ../README.ja.md; do
       for v in AI_REVIEW_IMPORTS AI_REVIEW_README AI_REVIEW_PRIOR_REVIEW; do
         grep -qF "$v" "$f" || { echo no; exit 0; }
       done
     done; echo yes)"

t_summary
