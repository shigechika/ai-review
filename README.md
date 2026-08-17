# ai-review

English | [日本語](README.ja.md)

A reusable GitHub Actions workflow for **advisory AI code review** of pull
requests, using your own OpenAI-compatible endpoint (tested against the Azure
AI Foundry v1 API). One central engine, called from any number of
repositories with an ~20-line caller — engine fixes reach every caller by
moving a tag, not by copy-pasting workflow files around.

## What it does

On every PR (and every push to it, if the caller enables `synchronize`), the
engine:

1. Builds a review prompt from the PR title/description, the **repository
   guidance files** (`CLAUDE.md`, `AGENTS.md`,
   `.github/copilot-instructions.md`), the **full contents of the changed
   files**, and the diff. An optional **`REVIEW.md`** at the repository
   root is spliced in ahead of everything else and takes precedence over
   the default focus and severity calibration wherever the two conflict —
   useful for repository-specific rules (stricter severity, paths to
   skip, checks to always run). It cannot change the fixed output format
   (finding markers, severity values, the ledger). Missing entirely, it
   is simply skipped, the same as any other guidance file.
2. Asks the model for at most 3 findings, each with a named failing
   input/state, a severity (`blocking`/`advisory`), and a strict output
   format.
3. Runs a second, cheap **verifier call** that tries to refute each candidate
   finding; refuted ones are dropped before anything is posted.
4. Posts **one sticky comment** per PR at a time with a one-line verdict,
   the surviving findings, and a machine-readable **findings ledger**
   that carries per-finding status (`open`/`fixed`/`dismissed`) across
   rounds — settled points are never re-argued. Every round that
   actually reviews (see below for the pushes that don't) posts a fresh
   comment at the bottom of the PR and deletes the earlier one, rather
   than editing it in place — which is also why PR subscribers get a
   notification on every such round, not just the first. Every round,
   including a skipped one, also sweeps up any orphaned marker comment a
   prior round's failed or racing delete left behind, so a duplicate
   never survives past the next round (a delete failure only warns and
   moves on, so one can briefly exist in between). The result: the
   current review state is always the most recent `ai-review` comment in
   the thread, though not necessarily the very last comment overall — a
   skipped push posts nothing itself, so a human comment made afterward
   can land below the sticky one.
5. On later pushes, reviews only the **new commits** (delta rounds via the
   compare API), and **skips posting entirely** for docs-only pushes to
   code PRs or a head already reviewed, degrading safely to a full-diff
   round whenever the delta is incomplete.
6. A **documentation-only PR** switches to docs-mode: documentation
   accuracy becomes the review subject, and source files the docs cite are
   attached (at the PR head) as evidence, so claims about signatures,
   defaults or behavior are checked against the code. If the PR touches
   README.md or README.ja.md, the untouched sibling (if any) is attached
   too, so a claim present in one language but missing or contradicted in
   the other gets flagged — phrasing and translation style are explicitly
   out of scope, only what is claimed.

The review is **advisory only**: every failure path soft-fails, so this job
can never block a PR.

## Quick start

1. Add two **secrets** to your repository (or organization):

   | Secret | Value |
   |---|---|
   | `AI_REVIEW_ENDPOINT` | Resource root, e.g. `https://<resource>.services.ai.azure.com` |
   | `AI_REVIEW_API_KEY` | API key for that resource |

   Treat the **real, resource-specific** endpoint hostname like a
   credential: the engine masks it in logs, and it should not appear in
   code, docs or issues. Placeholder forms like the `<resource>` example
   above are fine.

2. Create `.github/workflows/ai-review.yml` in your repository:

   ```yaml
   name: AI review
   on:
     pull_request:
       types: [opened, reopened, ready_for_review, synchronize]
   permissions:
     contents: read
     pull-requests: write
   concurrency:
     group: ai-review-${{ github.event.pull_request.number }}
     cancel-in-progress: true
   jobs:
     review:
       uses: shigechika/ai-review/.github/workflows/ai-review.yml@v1
       secrets:
         AI_REVIEW_ENDPOINT: ${{ secrets.AI_REVIEW_ENDPOINT }}
         AI_REVIEW_API_KEY: ${{ secrets.AI_REVIEW_API_KEY }}
   ```

   Drop `synchronize` from `types` if you want one review per PR instead of
   one per push.

That covers review itself. Draft PRs, `release-please--*` branches and
Dependabot PRs are skipped by the engine itself.

3. **Optional — admission control for public repos.** `pr-gate.yml` is a
   separate reusable workflow that closes pull requests from authors who
   are not a maintainer, member, or collaborator, posting a canned
   comment that explains why, and adds an `ai-review` label to admitted
   ones. It is independent of `ai-review.yml`: adopting it does not
   change how or when reviews run. Its only job is to stop spam and
   unsolicited PRs from sitting open, and to hand you a label you can
   reuse for anything else — branch protection, a second workflow's
   trigger, and so on.

   It needs its own trigger. Do not reuse the `pull_request` trigger
   from step 2 above — it will not work. Closing or labeling a fork's PR
   needs a base-repo-scoped token, and a plain `pull_request` event
   never grants a fork one; reused this way, the job doesn't error, it
   just skips silently on every run:

   ```yaml
   name: PR Gate
   on:
     pull_request_target:
       types: [opened, reopened, closed]
   permissions:
     contents: read
     pull-requests: write
     issues: write
   concurrency:
     group: pr-gate-${{ github.event.pull_request.number }}
     cancel-in-progress: false
   jobs:
     gate:
       uses: shigechika/ai-review/.github/workflows/pr-gate.yml@v1
   ```

   Trust rests on live GitHub signals, never a maintained allowlist file:
   GitHub's own `author_association` (`OWNER`/`MEMBER`/`COLLABORATOR`),
   and, on **private repositories only**, whether the pull request's head
   branch lives in this same repository rather than a fork. On a private
   repo, every reader was deliberately invited, so a same-repo PR there
   is trusted too — this closes a real gap where `author_association`
   can report `CONTRIBUTOR` for a genuine write-access org member/admin
   whose organization membership visibility is set to private. This
   check never applies on a public repo: there, opening a PR between two
   branches that already exist in the base repo needs only read access —
   which anyone has — so a same-repo branch alone would prove nothing.
   A few cases are handled specially:

   - `dependabot[bot]`, `github-actions[bot]`, and same-repo
     `release-please--*` branches are always exempt, so routine
     dependency/release PRs are never closed — and never mislabeled with
     a review that `ai-review.yml`'s own skip logic would never actually
     run anyway.
   - A rejected author's own reopen is re-evaluated the same way and
     closes again. Anyone else's reopen is honored as an override
     instead: GitHub itself only lets someone with sufficient access
     perform that action in the first place, so no permission lookup is
     needed here.

   Set the repository variable `AI_REVIEW_DISABLE_GATE` to `true` to turn
   this workflow into a no-op without removing the caller file.

That's it.

## Verifying your setup

Open a real pull request — not a draft, not from Dependabot, and not a
same-repo `release-please--*` branch, all three are skipped by the engine
itself — and check the `review` job's log:

- `::notice::guidance <file>: sent N of M bytes` — appears once per
  guidance file present in your repository. Missing entirely means the
  engine found no `CLAUDE.md`/`AGENTS.md`/`.github/copilot-instructions.md`
  at the base revision, which is normal if you have none.
- `::notice::REVIEW.md: sent N of M bytes` — appears only if a `REVIEW.md`
  is present at the base revision. Missing entirely means you have none,
  which is normal.
- `::notice::ai-review context: docs_mode=… delta_mode=… diff=…B …
  review_override=…B …` — one line summarizing what was actually sent to
  the model. `diff=0B` or a missing line means the diff fetch failed.
- `::warning::AI_REVIEW_ENDPOINT / AI_REVIEW_API_KEY not set — skipping AI
  review` means exactly what it says — the two secrets below are missing
  or empty on this repository (or this is a fork PR, which never gets
  secrets by design).
- No sticky comment and no `::warning::` at all usually means one of the
  `::notice::...skipping this round` lines fired instead (a docs-only
  push, or a head already reviewed in an earlier round) — check the log
  for one before suspecting a bug. If the `review` job did not run at
  all, the problem is upstream of the engine: the caller's `on:` triggers,
  or a branch protection rule blocking the workflow.

Every failure path is a `::warning::` with no other visible effect
(advisory-only design) — there is no separate health-check endpoint or
workflow. If you operate many repositories on this engine, the reliable
signal is the same one your reviewers already see: did the sticky comment
land on your last few real PRs.

## Configuration

Everything is optional. Each setting resolves as
**input → repository variable (of the calling repo) → default**.

| Input | Repository variable | Default | Meaning |
|---|---|---|---|
| `language` | `AI_REVIEW_LANG` | `en` | Language of the finding prose: `en` or `ja`. Markers, severities and the ledger stay in English either way. |
| `model` | `AI_REVIEW_MODEL` | `gpt-5.6-sol` | Deployment name sent to the endpoint. |
| `reasoning-effort` | `AI_REVIEW_EFFORT` | `high` | Reviewer `reasoning_effort`. Sentinel `off` stops sending the parameter (an empty value does **not** work — it falls back to the default). |
| — | `AI_REVIEW_VERIFY_EFFORT` | `low` | Verifier `reasoning_effort` (same `off` sentinel). |
| `max-total-file-bytes` | — | `131072` | Combined byte budget for attached changed-file contents. |

Because a called workflow resolves `vars.*` against the **calling**
repository, per-repo settings (e.g. `AI_REVIEW_LANG=ja`) need no input
plumbing: set the variable on the repo and every review there picks it up.

If the deployment rejects `reasoning_effort` with HTTP 400, the engine
retries once without the parameter and says so in the log.

## Writing a `REVIEW.md`

A `REVIEW.md` at the root of a calling repository overrides the
reviewer's default focus and severity calibration for that repository.
It is optional — absent, nothing changes.

### What it is for

The engine already reads `CLAUDE.md`, `AGENTS.md` and
`.github/copilot-instructions.md` as *guidance*: background the model
weighs. `REVIEW.md` differs in three specific ways, and those three are
the only reasons to add one.

1. **Severity.** Guidance cannot declare a class of defect blocking.
   The default calibration reserves `blocking` for behavior that is
   wrong in normal operation and sends the rest to `advisory`. A
   repository where, say, a credential reaching a log line is
   categorically blocking can only say so here.
2. **Additive checks.** The default focus paragraphs — documentation
   mode especially — contain a *closed* "Do NOT report" list. A check
   falling inside that list can only be re-enabled here, because
   nothing in the default focus conflicts with an addition: an override
   that merely won where it conflicts would be a no-op for it.
3. **Binding suppression.** "Not worth reporting here" is a hint when
   it sits in guidance. The same sentence in `REVIEW.md` takes
   precedence over the default focus.

If what you want to say needs none of those three, it belongs in
`CLAUDE.md` or `.github/copilot-instructions.md` instead.

### Shape

Three sections, in this order:

```markdown
# Review rules for this repository

## Always blocking
- ...

## Report even though the default focus would not
- ...

## Never report
- ...
```

### Keep it short, and do not restate the rationale

`REVIEW.md` is capped at 8 KiB, deliberately smaller than the 48 KiB
per-file guidance cap: it is a rule list, not a second guidance
document, and a long override sitting ahead of the default focus
dilutes the priority it exists to carry. This repository's own
`REVIEW.md` is about 2.7 KB — that ratio is the target, not the
exception.

State the rule and its severity; leave the *why* in `CLAUDE.md` or
`.github/copilot-instructions.md`, which the reviewer also receives.
Because the override wins by design, a duplicated explanation is worse
than redundant: a stale sentence here would out-rank a corrected one in
guidance indefinitely.

### Drafting hazards

These come from the first repositories to adopt a `REVIEW.md`, where
each one was caught on the very pull request that added the file.

- **Every rule must be decidable from what the reviewer actually
  receives.** There is no checkout, and no link is ever followed. The
  prompt holds the diff, the *changed* files at head — only as many as
  the count and byte caps above allow, with deny-listed ones dropped
  entirely — the guidance files and `REVIEW.md` at base, and a
  **truncated** pull request description. (Documentation-only pull
  requests additionally get unchanged sources the documentation
  cites.) So a rule like "flag a changed call site that has no test
  covering it" misfires: the test file is unchanged, therefore absent
  from the prompt, and absent-from-the-prompt is never evidence of
  absent-from-the-repository — the caps mean even a *changed* file can
  be missing. Write rules the diff itself can settle, and say so
  explicitly where the temptation to infer is strong.
- **Scope a rule to the code it actually governs.** "Never write to
  stdout" is right for the process that speaks JSON-RPC on stdout and
  wrong for the CLI in the same repository whose report *is* its
  stdout. An unscoped rule turns correct code into a blocking finding,
  and because the override outranks guidance, the guidance that
  explained the distinction cannot rescue it.
- **Check the rationale, not just the rule.** A rule can be right while
  the sentence justifying it is false — "a crash CI has caught" where
  the sources only say "can crash", or "X instead of Y" where the code
  says `X || Y`. Since this file outranks the guidance it was distilled
  from, an overstated rationale here is the version that wins.
- **Do not restate what CI already fails on.** The default reporting
  bar already excludes anything a linter, typechecker or test suite
  catches, and re-enabling it only buys a review round trip and no
  information. If a rule you are about to write is already a build
  failure, it belongs under **Never report**, not above it.
- **A "Never report" entry must be unconditional.** Any "but do report
  X" attached to one reads as a contradiction rather than a
  refinement — the reviewer is told to stay silent and to comment about
  the same situation. Put the reportable half in the section above, or
  narrow the entry until the exception disappears.
- **Describe all three sections accurately at the top.** A `REVIEW.md`
  does three things — marks findings blocking, *widens* scope to
  classes the default focus skips, and suppresses noise — and an
  opening line that claims fewer is contradicted by the file's own
  contents. "Severity only" is the tempting and wrong summary: the
  middle section changes *what gets examined*, not just how harshly it
  is graded. The reviewer will say so.
- **A blanket suppression can silently cancel a rule above it.** This
  is the single most repeated mistake so far, caught twice on separate
  repositories. "Never report anything CI already fails on" reads as
  reasonable until a blocking rule turns out to be CI-enforced too — a
  committed secret caught by a test, or a credential logged in a diff
  that also adds a failing test — at which point the two entries
  contradict each other and the more specific one loses. Enumerate the
  specific gates you mean rather than writing "anything", and state
  explicitly that the suppression never applies to a rule in the
  blocking section. Before shipping a `REVIEW.md`, read each **Never
  report** entry back against every **Always blocking** entry and ask
  whether the wording could swallow it.

### What it cannot change

The output format is fixed. Finding markers, the `blocking`/`advisory`
severity values and the findings ledger stay as they are no matter what
a repository writes, because other tooling parses them. `REVIEW.md`
changes *what* is reported and *how severely*, never *how the report is
written*.

### When it takes effect

Like the other guidance files, `REVIEW.md` is read at the **base**
revision, so a pull request cannot rewrite the rules it is reviewed
against. The pull request that adds or edits `REVIEW.md` is therefore
still reviewed under the previous rules, and the change applies from the
next pull request onward.

To confirm it is being read, look for `::notice::REVIEW.md: sent N of M
bytes` and a non-zero `review_override=` in the context line of the
`review` job log.

## Security model

Read the header comment of
[`ai-review.yml`](.github/workflows/ai-review.yml) for the full rationale;
the short version:

- **`pull_request`, never `pull_request_target`** — the job must not run
  with secrets against an attacker-controlled head. Consequence: fork PRs
  have no secrets and get no review. Accepted.
- **No checkout of PR content.** The diff and changed-file contents are
  fetched over the GitHub API and written to plain text files the
  workflow itself names, purely to assemble the prompt — but the PR's
  branch is never checked out as a git working tree, so nothing from the
  PR ever controls a file's path or type on the runner (which is what
  kills the symlink-to-`/proc/self/environ` class of attack).
- **Guidance is read at the BASE revision** — the files that *steer* the
  model must not be editable by the PR being reviewed. The changed-file
  attachments are read at HEAD on purpose: they are the review *subject*,
  the same trust class as the diff. The guidance paths are also on the
  attachment deny-list so a PR cannot smuggle its own version in through
  the subject channel.
- **Deny-lists before size caps**: secrets-shaped files (`.env`-style,
  `config.ini`, key material, service-account JSON) are never attached,
  however small; binaries and bulk data are excluded as noise.
- **Model output is data, not code**: it is written to files and parsed —
  never `eval`ed, never echoed as workflow commands — and the findings
  ledger is sanitized (author-filtered comment, shape-validated JSON,
  round-stamped ids) before anything from it is reused.
- The job needs only `contents: read` and `pull-requests: write`. The worst
  outcome of a prompt injection through the diff is a misleading advisory
  comment.

## Versioning

- Releases are cut by **release-please**: merge Conventional Commits to
  `main`, then merge the release PR it opens — that mints `vX.Y.Z`, a
  GitHub Release, and the changelog.
- `v1` is a **moving tag**: callers pinned to `@v1` get engine fixes
  automatically (the release workflow moves it on every release).
  Breaking interface changes bump the major.
- Immutable `vX.Y.Z` tags exist for pinning and for rollback:
  `git tag -f v1 <last-good> && git push -f origin v1` rolls back every
  caller at once. Moving the local tag alone does nothing — callers
  resolve the tag on GitHub, so the force-push is what actually matters.
- **This repository must stay public** — GitHub can only resolve a
  reusable workflow from a repository the caller can read, so making it
  private would break every caller outside it.

## License

[MIT](LICENSE)
