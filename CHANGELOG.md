# Changelog

## [1.4.2](https://github.com/shigechika/ai-review/compare/v1.4.1...v1.4.2) (2026-08-09)


### Bug Fixes

* detect README rename via previous_filename, not just current path ([#42](https://github.com/shigechika/ai-review/issues/42)) ([fb651f8](https://github.com/shigechika/ai-review/commit/fb651f87bd81eab5de8ea247f53f6db41d725544))

## [1.4.1](https://github.com/shigechika/ai-review/compare/v1.4.0...v1.4.1) (2026-08-09)


### Bug Fixes

* trust same-repo PRs on private repos over author_association ([#38](https://github.com/shigechika/ai-review/issues/38)) ([c406276](https://github.com/shigechika/ai-review/commit/c406276d5cd5d63cc0fbe11df556d0050009eaf7))

## [1.4.0](https://github.com/shigechika/ai-review/compare/v1.3.1...v1.4.0) (2026-08-08)


### Features

* detect README.md/README.ja.md claim mismatches in docs-mode ([#34](https://github.com/shigechika/ai-review/issues/34)) ([5a547b7](https://github.com/shigechika/ai-review/commit/5a547b7efd73dc472e8924531efe235c9e3a585f))

## [1.3.1](https://github.com/shigechika/ai-review/compare/v1.3.0...v1.3.1) (2026-08-08)


### Bug Fixes

* add explicit contents: read to the pr-gate.yml caller recipe ([#31](https://github.com/shigechika/ai-review/issues/31)) ([4796658](https://github.com/shigechika/ai-review/commit/4796658b629ddb1f42c1cfa5dbe47e6282f3ab76))

## [1.3.0](https://github.com/shigechika/ai-review/compare/v1.2.1...v1.3.0) (2026-08-08)


### Features

* add pr-gate.yml, admission control for unsolicited PRs ([#28](https://github.com/shigechika/ai-review/issues/28)) ([92d68db](https://github.com/shigechika/ai-review/commit/92d68db513f261ae13a4809caea5c5433282b1fd))


### Bug Fixes

* don't label same-repo release-please PRs in pr-gate.yml ([#30](https://github.com/shigechika/ai-review/issues/30)) ([6dcb2c7](https://github.com/shigechika/ai-review/commit/6dcb2c7b047b8b8fcfe9be29c416ac027a4fd259))

## [1.2.1](https://github.com/shigechika/ai-review/compare/v1.2.0...v1.2.1) (2026-08-08)


### Bug Fixes

* sweep orphan sticky comments on skip paths too, not only full reviews ([#26](https://github.com/shigechika/ai-review/issues/26)) ([d61271b](https://github.com/shigechika/ai-review/commit/d61271ba5d4b562704bce4c15138f5786fe116de))

## [1.2.0](https://github.com/shigechika/ai-review/compare/v1.1.3...v1.2.0) (2026-08-07)


### Features

* repost the sticky comment at the bottom instead of editing in place ([#24](https://github.com/shigechika/ai-review/issues/24)) ([3278cc0](https://github.com/shigechika/ai-review/commit/3278cc01c84798472d25f498d929482a7454876a))

## [1.1.3](https://github.com/shigechika/ai-review/compare/v1.1.2...v1.1.3) (2026-08-07)


### Bug Fixes

* add timeout-minutes to CI jobs to prevent silent multi-hour hangs ([#18](https://github.com/shigechika/ai-review/issues/18)) ([850e242](https://github.com/shigechika/ai-review/commit/850e242bfdcbb0766679e69b09630b50fb844fc4))
* mask GitHub Actions expressions before shellchecking (PR [#17](https://github.com/shigechika/ai-review/issues/17) finding) ([#22](https://github.com/shigechika/ai-review/issues/22)) ([eb6415f](https://github.com/shigechika/ai-review/commit/eb6415f62bb49554dedb6bb3adea8c49b69eb3c3))
* replace actionlint's install script with a bounded direct download ([#20](https://github.com/shigechika/ai-review/issues/20)) ([bb3315d](https://github.com/shigechika/ai-review/commit/bb3315d14103aeb9c8d9dc04bb345454983c60c5))
* surface malformed severity lines in the rendered review comment ([#17](https://github.com/shigechika/ai-review/issues/17)) ([3ab6dd4](https://github.com/shigechika/ai-review/commit/3ab6dd442d6a7905fe3ae161e8f4b784e0db561e))
* work around actionlint's shellcheck-integration deadlock ([#21](https://github.com/shigechika/ai-review/issues/21)) ([7ceb1f4](https://github.com/shigechika/ai-review/commit/7ceb1f4267a4cd2d70cbf13974d6087a011fe0bd))

## [1.1.2](https://github.com/shigechika/ai-review/compare/v1.1.1...v1.1.2) (2026-08-06)


### Bug Fixes

* severity-aware eviction in the 80-entry ledger cap ([#11](https://github.com/shigechika/ai-review/issues/11)) ([db50697](https://github.com/shigechika/ai-review/commit/db5069745450f475dc223c834f09125144448e60))

## [1.1.1](https://github.com/shigechika/ai-review/compare/v1.1.0...v1.1.1) (2026-08-06)


### Bug Fixes

* verdict was blind to persisted open findings' severity across rounds ([#9](https://github.com/shigechika/ai-review/issues/9)) ([62eeccc](https://github.com/shigechika/ai-review/commit/62eeccc305f08fddcad792a9883288e41482c2c7))

## [1.1.0](https://github.com/shigechika/ai-review/compare/v1.0.0...v1.1.0) (2026-08-06)


### Features

* docs-mode — review documentation-only PRs against cited sources ([#6](https://github.com/shigechika/ai-review/issues/6)) ([93bbbbd](https://github.com/shigechika/ai-review/commit/93bbbbd31a4edcbea6468fa7930bd71ea3d0f272))

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
