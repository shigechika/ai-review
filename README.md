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
4. Posts (or updates) **one sticky comment** per PR with a one-line verdict,
   the surviving findings, and a machine-readable **findings ledger** that
   carries per-finding status (`open`/`fixed`/`dismissed`) across rounds —
   settled points are never re-argued.
5. On later pushes, reviews only the **new commits** (delta rounds via the
   compare API), skips docs-only pushes, and degrades safely to a full-diff
   round whenever the delta is incomplete.

The review is **advisory only**: every failure path soft-fails, so this job
can never block a PR.

## Quick start

1. Add two **secrets** to your repository (or organization):

   | Secret | Value |
   |---|---|
   | `AI_REVIEW_ENDPOINT` | Resource root, e.g. `https://<resource>.services.ai.azure.com` |
   | `AI_REVIEW_API_KEY` | API key for that resource |

   Treat the endpoint hostname like a credential: the engine masks it in
   logs, and it should not appear in code or docs.

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

That's it. Draft PRs, `release-please--*` branches and Dependabot PRs are
skipped by the engine itself.

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

- `v1` is a **moving tag**: callers pinned to `@v1` get engine fixes
  automatically. Breaking interface changes bump the major.
- Immutable `vX.Y.Z` tags exist for pinning and for rollback
  (`git tag -f v1 <last-good>` rolls back every caller at once).
- **This repository must stay public** — GitHub can only resolve a
  reusable workflow from a repository the caller can read, so making it
  private would break every caller outside it.

## License

[MIT](LICENSE)
