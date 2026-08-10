# Review rules for this repository

Rules for the AI reviewer, on top of the default focus. This engine
ships to every caller repository the moment the `v1` tag moves — weight
severity accordingly.

## Always blocking

- A code path in `ai-review.yml` that can exit non-zero or otherwise
  block a pull request. Every failure must soft-fail: a `::warning::`
  plus `exit 0`. The run block executes under `bash -e {0}` without
  pipefail — an unguarded command substitution or a new unconsumed
  status is how this usually breaks.
- Reading a guidance file (`CLAUDE.md`, `AGENTS.md`,
  `.github/copilot-instructions.md`, `REVIEW.md`) at the PR head
  instead of the base revision, or removing one of them from the
  changed-file attachment deny-list.
- Any edit that lets repository-provided or model-provided content
  (guidance, REVIEW.md, the diff, model output) reach the Output
  format section of the system prompt, a shell `eval`, or an
  unfiltered echo that could emit workflow commands.
- In `pr-gate.yml`: interpolating a `${{ ... }}` expression into the
  `github-script` source instead of passing it through `env:`,
  checking out PR content, or weakening `TRUSTED_ASSOCIATIONS` or the
  private-repo-only same-repo-branch check.
- Changing, localizing, or conditionally skipping a load-bearing
  string other code greps for: `===FINDING===`, `===LEDGER===`,
  `severity:` lines, the `blocking`/`advisory` enum,
  `No findings clear the reporting bar`, or the ledger JSON shape.

## Report even though the default focus would not

- A byte cap introduced or changed outside the central "Byte caps"
  block in `ai-review.yml`, or a cap change that leaves that block
  header comment arithmetic stale.
- An apostrophe inside a single-quoted shell string in `ai-review.yml`
  (the system/verifier prompts and the jq programs, including comments
  inside the jq programs). The test suite catches this too; report it
  anyway so it dies in review instead of in CI.
- A truncated attachment or guidance file whose prompt header does not
  say TRUNCATED, or a TRUNCATED label on content the cap never
  actually clamped.
- A behavioral change to logic the test suite extracts from the
  committed YAML (the deny-list case block, delta detection, the
  ledger jq programs, the pr-gate script block, the REVIEW.md
  conditional) with no matching test update in the same PR.

## Never report

- Style, wording, or formatting preferences in prose or comments.
- The absence of a capability this repository has deliberately
  rejected: checkout of PR content, `pull_request_target` in
  `ai-review.yml`, auto-fix behavior, or general prose-quality review
  in docs-mode.
