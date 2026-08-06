#!/bin/bash
# Deny-list decisions, extracted verbatim from the engine's case statement
# so this test cannot drift from the implementation.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./lib.sh

extract_between 'case "$f" in' '  esac' > /tmp/denylist_case.txt
[ -s /tmp/denylist_case.txt ] || { echo "FAIL: could not extract the deny-list case block"; exit 1; }
grep -v '^\s*#' /tmp/denylist_case.txt > /tmp/denylist_case_clean.txt

classify() {
  local skipped=""
  for f in "$1"; do
    eval "$(cat /tmp/denylist_case_clean.txt)"
    echo "ATTACH"
  done
  [ -n "$skipped" ] && echo "SKIP"
  return 0
}

t "deny CLAUDE.md"                    "SKIP"   "$(classify CLAUDE.md)"
t "deny AGENTS.md"                    "SKIP"   "$(classify AGENTS.md)"
t "deny copilot-instructions"         "SKIP"   "$(classify .github/copilot-instructions.md)"
t "deny dot.env"                      "SKIP"   "$(classify dot.env)"
t "deny nested dot.env"               "SKIP"   "$(classify apps/api/dot.env)"
t "deny .env"                         "SKIP"   "$(classify .env)"
t "deny nested .env"                  "SKIP"   "$(classify apps/api/.env)"
t "deny prod.env"                     "SKIP"   "$(classify prod.env)"
t "deny .env.local"                   "SKIP"   "$(classify .env.local)"
t "deny nested .env.local"            "SKIP"   "$(classify apps/.env.local)"
t "deny config.ini"                   "SKIP"   "$(classify config.ini)"
t "deny nested config.ini"            "SKIP"   "$(classify deploy/config.ini)"
t "deny key.pem"                      "SKIP"   "$(classify certs/key.pem)"
t "deny id_rsa"                       "SKIP"   "$(classify id_rsa)"
t "deny nested id_rsa"                "SKIP"   "$(classify keys/id_rsa)"
t "deny id_rsa.pub"                   "SKIP"   "$(classify keys/id_rsa.pub)"
t "deny service_account json"         "SKIP"   "$(classify creds/my-service_account-prod.json)"
t "deny package-lock.json"            "SKIP"   "$(classify package-lock.json)"
t "deny nested package-lock.json"     "SKIP"   "$(classify pkg/sub/package-lock.json)"
t "deny poetry.lock"                  "SKIP"   "$(classify poetry.lock)"
t "deny app.min.js"                   "SKIP"   "$(classify dist/app.min.js)"
t "deny image"                        "SKIP"   "$(classify img/logo.png)"
t "deny archive"                      "SKIP"   "$(classify data/dump.tar.gz)"
t "deny pickle"                       "SKIP"   "$(classify REPORTS/x.pickle)"
t "deny csv"                          "SKIP"   "$(classify history/big.csv)"
t "allow python"                      "ATTACH" "$(classify analytics/core.py)"
t "allow yaml workflow"               "ATTACH" "$(classify .github/workflows/ai-review.yml)"
t "allow nested CLAUDE.md (docs copy)" "ATTACH" "$(classify docs/CLAUDE.md)"
t "allow environment.py"              "ATTACH" "$(classify environment.py)"
t "allow envelope.ts"                 "ATTACH" "$(classify src/envelope.ts)"
t "allow README.md"                   "ATTACH" "$(classify README.md)"
t "allow config.initializer.rb"       "ATTACH" "$(classify app/config.initializer.rb)"

t_summary
