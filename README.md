# ai-review

[日本語版 README](README.ja.md)

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
   files**, and the diff.
2. Asks the model for at most 3 findings, each with a named failing
   input/state, a severity (`blocking`/`advisory`), and a strict output
   format.
3. Runs a second, cheap **verifier call** that tries to refute each candidate
   finding; refuted ones are dropped before anything is posted.
4. Posts **one sticky comment** per PR at a time with a one-line verdict, the
   surviving findings, and a machine-readable **findings ledger** that
   carries per-finding status (`open`/`fixed`/`dismissed`) across rounds —
   settled points are never re-argued. Every round that actually reviews
   (see below for the pushes that don't) posts a fresh comment at the
   bottom of the PR and removes the earlier one(s). Every round, including
   a skipped one, also sweeps away any orphaned marker comment left by a
   prior round's failed or racing delete — so a stale duplicate is never
   left waiting for the next full review to clean it up, and the current
   review state is always the most recent (and only) `ai-review` comment in
   the thread — though not necessarily the very last comment overall, since
   a skipped push posts nothing itself and human comments made afterward
   can land below it. Because every non-skipped round posts a brand-new
   comment rather than editing one in place, PR subscribers get a
   notification on every such round, not just the first.
5. On later pushes, reviews only the **new commits** (delta rounds via the
   compare API), and **skips posting entirely** for docs-only pushes to
   code PRs or a head already reviewed, degrading safely to a full-diff
   round whenever the delta is incomplete.
6. A **documentation-only PR** switches to docs-mode: documentation
   accuracy becomes the review subject, and source files the docs cite are
   attached (at the PR head) as evidence, so claims about signatures,
   defaults or behavior are checked against the code.

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
   are not a maintainer, member, or collaborator (with a canned comment
   explaining why), and adds an `ai-review` label to admitted ones. It is
   independent of `ai-review.yml` — adopting it does not change how or
   when reviews run; it only stops spam/unsolicited PRs from sitting open
   and adds a label you can use for your own purposes (branch protection,
   a second workflow's trigger, etc.). It needs its own trigger — do not
   reuse the `pull_request` trigger from step 2 above, it will not work:
   closing or labeling a fork's PR needs a base-repo-scoped token that a
   plain `pull_request` event never grants a fork, silently skipping this
   job on every run instead of erroring:

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

   Trust is a single live signal — GitHub's own `author_association`
   (`OWNER`/`MEMBER`/`COLLABORATOR`) — plus a small built-in allowlist for
   `dependabot[bot]`/`github-actions[bot]` and same-repo
   `release-please--*` branches, so routine dependency/release PRs are
   never closed and never mislabeled with a review that
   `ai-review.yml`'s own skip logic will never actually run. A rejected
   author's own reopen is re-evaluated the same way and closes again;
   anyone else reopening it is honored as an override, since GitHub
   itself only lets someone with sufficient access perform that action in
   the first place — no permission lookup needed here. Set the repository
   variable `AI_REVIEW_DISABLE_GATE` to `true` to turn this workflow into
   a no-op without removing the caller file.

That's it.

## Verifying your setup

Open a real pull request — not a draft, not from Dependabot, and not a
same-repo `release-please--*` branch, all three are skipped by the engine
itself — and check the `review` job's log:

- `::notice::guidance <file>: sent N of M bytes` — appears once per
  guidance file present in your repository. Missing entirely means the
  engine found no `CLAUDE.md`/`AGENTS.md`/`.github/copilot-instructions.md`
  at the base revision, which is normal if you have none.
- `::notice::ai-review context: docs_mode=… delta_mode=… diff=…B …` — one
  line summarizing what was actually sent to the model. `diff=0B` or a
  missing line means the diff fetch failed.
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

## Security model

Read the header comment of
[`ai-review.yml`](.github/workflows/ai-review.yml) for the full rationale;
the short version:

- **`pull_request`, never `pull_request_target`** — the job must not run
  with secrets against an attacker-controlled head. Consequence: fork PRs
  have no secrets and get no review. Accepted.
- **No checkout.** Everything arrives over the GitHub API; nothing from the
  PR is ever a file on the runner's disk (which also kills the
  symlink-to-`/proc/self/environ` class of attack).
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
- Immutable `vX.Y.Z` tags exist for pinning and for rollback
  (`git tag -f v1 <last-good>` rolls back every caller at once).
- **This repository must stay public** — GitHub can only resolve a
  reusable workflow from a repository the caller can read, so making it
  private would break every caller outside it.

## License

[MIT](LICENSE)
