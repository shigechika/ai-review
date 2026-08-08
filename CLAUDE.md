# CLAUDE.md

Guidance for AI assistants (and humans) editing this repository.

## What this repository is

Two reusable GitHub Actions workflows, plus a selftest caller and CI. Many
downstream repositories pin the moving `v1` tag, so every change to either
one ships to all of them at once — treat edits accordingly.

- `.github/workflows/ai-review.yml` (`on: workflow_call`) performs advisory
  AI code review of pull requests.
- `.github/workflows/pr-gate.yml` (`on: workflow_call`) is optional
  admission control: it closes pull requests from authors who are not a
  maintainer/member/collaborator, and labels admitted ones. It is a
  **deliberately different threat model** from ai-review.yml — see its own
  invariants section below before editing it. Do not let its patterns leak
  into ai-review.yml, or vice versa.

## Invariants — do not "fix" these

These apply to `ai-review.yml`. `pr-gate.yml` has its own, opposite-by-design
set — see "pr-gate.yml invariants" below.

- **Guidance at BASE, changed files at HEAD.** Repository guidance steers
  the model, so it must not be editable by the PR under review; changed-file
  attachments are the review subject, same trust class as the diff. This
  asymmetry is intentional and documented inline. The guidance paths are
  also on the attachment deny-list — keep them there.
- **Advisory contract.** Every failure path must soft-fail (`exit 0` with a
  `::warning::`), so the job can never block a PR. New code paths must
  preserve this: guard command substitutions, consume statuses, remember
  that the run block executes under `bash -e {0}` (errexit **without**
  pipefail).
- **No checkout, `pull_request` only.** Nothing from the PR may become a
  file on the runner's disk, and the workflow must never be wired to
  `pull_request_target`. (This is the one invariant `pr-gate.yml`
  deliberately violates — see below for why that is safe there.)
- **Model output is data.** Parse it from files; never `eval` it or echo it
  raw (it could emit `::workflow-command::` lines). Ledger content is
  model-influenced: keep the author filter, shape validation and
  round-stamped id checks in front of any reuse.
- **Deny-list before size caps.** A secret-shaped file must never be
  attached, however small. Anchored basename patterns in the `case`
  deny-list need a `*/` twin to match nested paths; pure suffix patterns
  (`*.env`, `*.pem`) already cross `/`.

## pr-gate.yml invariants — opposite by design, do not blur with ai-review.yml

- **`pull_request_target` is required, not forbidden.** Closing or labeling
  a fork's PR is a write, and GitHub forces a read-only `GITHUB_TOKEN` on
  plain `pull_request` events from forks no matter what `permissions:`
  says — there is no way to do this job without a base-repo-scoped token.
  The usual caution that goes with `pull_request_target` still applies in
  full: never check out PR content, never run anything the PR authored,
  never let a PR-controlled string reach the runner's shell or the
  `actions/github-script` source itself (pass it through `env:` /
  `process.env`, never string-interpolate a `${{ ... }}` into the script
  body — this is exactly the class of bug the PostToolUse security hook
  flags on every edit to this file).
- **Blocking is the point.** Unlike ai-review.yml's advisory contract, a
  rejected PR is actually closed. Do not soften this into a warning-only
  path — the whole value of the file is that it acts, not just reports.
- **Trust is one live signal, no file to go stale.** `author_association`
  (`OWNER`/`MEMBER`/`COLLABORATOR`) plus the hardcoded bot allowlist
  (`dependabot[bot]`, `github-actions[bot]`) — deliberately no
  `APPROVED_CONTRIBUTORS`-style file to maintain or forget to update.
  `CONTRIBUTOR` (has had a PR merged before, holds no standing write
  access) is intentionally NOT trusted; only a maintainer's reopen admits
  one. Do not widen `TRUSTED_ASSOCIATIONS` without confirming that is
  actually wanted — it is the exact false-positive class most likely to
  surprise a real contributor.
- **`vars.AI_REVIEW_DISABLE_GATE` is the one kill switch.** It resolves
  against the calling repository (same as every other `vars.*` this repo
  reads) — keep it that way so a caller can flip the file to a no-op
  without touching its own workflow YAML.
- **No coupling to ai-review.yml's trigger.** The two workflows compose
  only through the label; ai-review.yml's own trigger conditions are never
  to be made conditional on the `ai-review` label or on pr-gate.yml having
  run. This was evaluated and deliberately rejected: ai-review.yml already
  gets no secrets on fork PRs (GitHub's own fork-secrets restriction), so
  gating its trigger on the label would add a cross-workflow race and a
  poll loop for zero benefit on the common case. Do not reintroduce it
  without first confirming (via the repository's Settings → Actions
  page, not assumption) that the caller repo has enabled a non-default
  "send secrets to fork PR workflows" policy, since that is the only
  situation where the coupling would actually save anything.

## Editing gotchas

- The system/verifier prompts and the large jq programs live inside
  single-quoted shell strings: **no apostrophes** inside them (including
  comments inside the jq programs) — an apostrophe ends the string.
  `tests/test_ledger.sh` asserts the extracted jq programs contain zero
  apostrophes; this rule has been violated twice DESPITE being documented
  here, both times caught only by that assertion (or by shellcheck) — do
  not trust memory or review alone for this one, run the tests.
- Byte caps are named in one block ("Byte caps") — change budgets there,
  and keep the header comment's arithmetic in sync.
- Truncation must be labelled: a clamped attachment gets the `TRUNCATED`
  header, never a "full content" label.
- Delta mode requires a strictly-`ahead` compare; docs-only skip sits
  behind the same guard. Do not move either in front of it.
- User-facing strings that other code greps for (`No findings clear the
  reporting bar`, `severity:` lines, `===FINDING`/`===LEDGER===` markers)
  are load-bearing; the `language` input must never localize them.

## Verifying changes

- `bash tests/run_all.sh` — the engine's own regression suite. Extracts
  the deny-list case block, delta-detection logic, and the ledger
  merge/cap/verdict jq programs **directly from the current YAML** (not
  retyped), so a behavioral change fails the suite instead of silently
  diverging from it. Run this before every PR; CI runs it too
  (`unit-tests` job in `ci.yml`). Add a case to the relevant `test_*.sh`
  for every bug this engine's own selftest finds in itself — that is how
  the severity-corroboration regression (found on PR #9's own selftest)
  became a permanent test instead of a one-off fix.
- `actionlint -shellcheck=` at the repo root, plus
  `python3 scripts/lint-embedded-shell.py` for the shellcheck pass.
  actionlint's own built-in shellcheck integration is disabled — it has a
  known, unfixed upstream deadlock on any `run:` block over 65536 bytes
  (rhysd/actionlint#712), which this repo's largest step is close enough
  to that it has hung CI for hours in practice. The Python script
  shellchecks every `run:` block as a file instead (not over stdin),
  which doesn't hit the same bug; run both locally before every PR, same
  as CI's `actionlint` job does.
- Extract the run block from the YAML and `bash -n` it.
- The selftest workflow reviews every PR with the PR's **own** engine
  revision (relative `uses:`), so open a PR and read the sticky comment +
  `::notice::` lines (context breakdown, guidance bytes, delta mode) in the
  run log — they are the observability surface.
- Keep `README.md` (English) and `README.ja.md` (Japanese) in sync.
- `pr-gate.yml`'s logic lives in an `actions/github-script` block (plain
  JS), which the bash/jq-only `tests/run_all.sh` harness cannot exercise —
  there is no Node test coverage for it. `actionlint -shellcheck=` still
  checks the surrounding YAML, but the admission logic itself is verified
  by reasoning plus a real PR. `pr-gate-selftest.yml` dogfoods it on this
  repo's own PRs the same way `selftest.yml` dogfoods ai-review.yml, with
  one structural difference worth remembering: `pull_request_target`
  always runs the workflow file as committed on the BASE branch, never the
  PR's own proposed version (that is what makes it safe to use with a
  write-capable token at all) — so a PR that changes `pr-gate.yml` is
  evaluated by the pre-change version, not itself. Real coverage of a
  `pr-gate.yml` change starts on the first PR opened after it merges, not
  the PR that introduces it.

## Releasing

Releases go through **release-please** (`release-type: simple`;
`version.txt` + `CHANGELOG.md` are its managed files). Never hand-tag
`vX.Y.Z`: merge Conventional Commits to `main`, then merge the release PR.
The release-please workflow also force-moves the major tag (`v1`) to each
new release — that step is what actually ships to callers, since they pin
the moving tag.

## Secrets

`AI_REVIEW_ENDPOINT` / `AI_REVIEW_API_KEY` are repository secrets. The
endpoint hostname is treated like a credential: never write it in code,
docs, issues or PRs; the engine masks it in logs.
