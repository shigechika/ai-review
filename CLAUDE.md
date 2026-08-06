# CLAUDE.md

Guidance for AI assistants (and humans) editing this repository.

## What this repository is

A single reusable GitHub Actions workflow
(`.github/workflows/ai-review.yml`, `on: workflow_call`) that performs
advisory AI code review of pull requests, plus a selftest caller and CI.
Many downstream repositories pin the moving `v1` tag, so every change to the
engine ships to all of them at once — treat edits accordingly.

## Invariants — do not "fix" these

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
  `pull_request_target`.
- **Model output is data.** Parse it from files; never `eval` it or echo it
  raw (it could emit `::workflow-command::` lines). Ledger content is
  model-influenced: keep the author filter, shape validation and
  round-stamped id checks in front of any reuse.
- **Deny-list before size caps.** A secret-shaped file must never be
  attached, however small. Anchored basename patterns in the `case`
  deny-list need a `*/` twin to match nested paths; pure suffix patterns
  (`*.env`, `*.pem`) already cross `/`.

## Editing gotchas

- The system/verifier prompts and the large jq programs live inside
  single-quoted shell strings: **no apostrophes** inside them (including
  comments inside the jq programs) — an apostrophe ends the string.
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

- `actionlint` at the repo root (CI runs it with shellcheck available).
- Extract the run block from the YAML and `bash -n` it.
- The selftest workflow reviews every PR with the PR's **own** engine
  revision (relative `uses:`), so open a PR and read the sticky comment +
  `::notice::` lines (context breakdown, guidance bytes, delta mode) in the
  run log — they are the observability surface.
- Keep `README.md` (English) and `README.ja.md` (Japanese) in sync.

## Secrets

`AI_REVIEW_ENDPOINT` / `AI_REVIEW_API_KEY` are repository secrets. The
endpoint hostname is treated like a credential: never write it in code,
docs, issues or PRs; the engine masks it in logs.
