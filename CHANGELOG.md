# Changelog

## v1.0.0 (2026-08-06)

Initial release.

- Reusable workflow (`on: workflow_call`) for advisory AI code review via an
  OpenAI-compatible endpoint (Azure AI Foundry v1 API).
- Sticky comment with a cross-round findings ledger, delta rounds on
  `synchronize`, docs-only skip, severity verdict.
- Reporting bar + skeptical verifier pass; both calls share the same context
  (guidance, changed-file attachments, capped diff).
- Repository guidance sent whole under byte caps, read at the PR base
  revision; changed files attached whole at the PR head under a deny-list
  (guidance / secrets / binaries / bulk data) with honest truncation
  headers.
- `reasoning_effort` per call with a one-shot HTTP-400 fallback;
  `finish_reason=length` surfaced; `off` sentinel to disable.
- `language` input / `AI_REVIEW_LANG` variable (en|ja) for the finding
  prose.
