// Table-driven unit tests for pr-gate.yml's admission logic.
//
// The trust decision lives entirely inside an actions/github-script
// block (plain JS) in .github/workflows/pr-gate.yml, which the bash/jq
// harness in the rest of this suite (see lib.sh) cannot exercise. This
// file extracts the real `script:` block from the committed YAML at
// test time — the same principle extract_run() already applies to
// ai-review.yml's `run:` block — and runs it against mock github/
// context/core objects, so a future behavioral change fails here
// instead of silently diverging from what actually ships.
//
// Output format matches tests/lib.sh's t()/t_summary() convention
// ("ok   name" / "FAIL name" + "N passed, M failed") so this composes
// with run_all.sh's existing summary line without a separate test
// framework or an npm dependency — ubuntu-latest ships Node already,
// and this repo has no package.json.

import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ENGINE = path.join(__dirname, "..", ".github", "workflows", "pr-gate.yml");

let pass = 0;
let fail = 0;

function t(name, expected, actual) {
  if (expected === actual) {
    pass += 1;
    console.log(`ok   ${name}`);
  } else {
    fail += 1;
    console.log(`FAIL ${name}`);
    console.log(`     expected: ${expected}`);
    console.log(`     actual:   ${actual}`);
  }
}

function t_summary() {
  console.log();
  console.log(`${pass} passed, ${fail} failed`);
  return fail === 0;
}

// ---------- Extraction (mirrors lib.sh's extract_run, in pure JS) ----------
// The `script: |` key sits at 10-space indent under `with:`; its content
// is indented 12 spaces. Pure string parsing, no YAML library, so this
// stays dependency-free the same way the bash extractor is.
function extractScript(engineText) {
  const lines = engineText.split("\n");
  const out = [];
  let grab = false;
  for (const line of lines) {
    if (!grab) {
      if (line === "          script: |") grab = true;
      continue;
    }
    if (line.startsWith("            ") || line.trim() === "") {
      out.push(line.length >= 12 ? line.slice(12) : "");
      continue;
    }
    break;
  }
  return out.join("\n");
}

const engineText = readFileSync(ENGINE, "utf8");
const script = extractScript(engineText);

// extractScript grabs the FIRST line matching `script: |` — silently
// the wrong block (or the wrong step) if pr-gate.yml ever grows a
// second github-script step, rather than a loud failure. Pin the
// single-step shape this file depends on so that changes instead of
// silently testing dead code.
const scriptKeyCount = engineText.split("\n").filter((l) => l === "          script: |").length;
t("pr-gate.yml has exactly one script block", "1", String(scriptKeyCount));

t("extractScript non-empty", "yes", script.length > 0 ? "yes" : "no");
t(
  "extractScript starts correctly",
  "yes",
  script.split("\n")[0].includes("REVIEW_LABEL travels through env") ? "yes" : "no"
);
const scriptEnd = script.trimEnd();
t(
  "extractScript reaches the end",
  "yes",
  scriptEnd.includes('state: "closed",') && scriptEnd.endsWith("});") ? "yes" : "no"
);

// Cross-check against a from-scratch YAML-aware extraction, same
// discipline test_extraction.sh applies to extract_run(): a change to
// the block's indentation base (hard-coded here at 12 spaces) fails
// loudly instead of silently feeding every scenario below truncated or
// wrong content. Skips (not fails) when python3/PyYAML is unavailable.
try {
  const pyScript = execFileSync(
    "python3",
    [
      "-c",
      "import yaml,sys; sys.stdout.write(yaml.safe_load(open(sys.argv[1]))['jobs']['gate']['steps'][0]['with']['script'])",
      ENGINE,
    ],
    { encoding: "utf8" }
  );
  // PyYAML's block-scalar value has no trailing newline stripped the
  // same way our line-by-line join does; compare trimmed.
  t("extractScript matches PyYAML", "identical", script.trimEnd() === pyScript.trimEnd() ? "identical" : "DIFFERS");
} catch (err) {
  if (err.code === "ENOENT" || /No module named 'yaml'|ModuleNotFoundError/.test(String(err.stderr || ""))) {
    console.log("skip PyYAML cross-check (PyYAML not installed) — not a failure");
  } else {
    throw err;
  }
}

// ---------- Mock harness ----------
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const runTrustLogic = new AsyncFunction("github", "context", "core", script);

// The real script reads process.env.REVIEW_LABEL directly (not an
// injected parameter) — actions/github-script scripts run with normal
// Node globals available, same as this test file.
process.env.REVIEW_LABEL = "ai-review";

function makeMockGithub(existingComments = []) {
  const calls = {
    addLabels: [],
    removeLabel: [],
    createComment: [],
    updateComment: [],
    pullsUpdate: [],
  };
  const github = {
    rest: {
      issues: {
        addLabels: async (params) => {
          calls.addLabels.push(params);
        },
        removeLabel: async (params) => {
          calls.removeLabel.push(params);
        },
        listComments: async () => ({ data: existingComments }),
        createComment: async (params) => {
          calls.createComment.push(params);
        },
        updateComment: async (params) => {
          calls.updateComment.push(params);
        },
      },
      pulls: {
        update: async (params) => {
          calls.pullsUpdate.push(params);
        },
      },
    },
    // Mirrors Octokit's paginate plugin: calls the passed endpoint
    // function and unwraps its {data} envelope, rather than ignoring
    // the argument — so if upsertGateComment ever starts paginating a
    // different endpoint, this mock actually exercises that call
    // instead of silently returning a fixed list regardless.
    paginate: async (fn, params) => {
      const res = await fn(params);
      return res.data;
    },
  };
  return { github, calls };
}

function makeMockCore() {
  const infoLines = [];
  return { core: { info: (msg) => infoLines.push(msg) }, infoLines };
}

// yes/no helpers keep assertions readable and match lib.sh's t() shape
// (plain string comparison, no assert-throwing framework).
const yn = (bool) => (bool ? "yes" : "no");
const calledOnce = (arr) => arr.length === 1;
const notCalled = (arr) => arr.length === 0;

function buildPR({
  author = "someone",
  association = "CONTRIBUTOR",
  number = 1,
  headFullName = "someone/widgets",
  headRef = "feat/thing",
  baseVisibility = "public",
} = {}) {
  return {
    number,
    user: { login: author },
    author_association: association,
    head: { ref: headRef, repo: headFullName ? { full_name: headFullName } : null },
    base: { repo: { visibility: baseVisibility } },
  };
}

function buildContext({ action = "opened", pr, senderLogin } = {}) {
  return {
    repo: { owner: "acme-corp", repo: "widgets" },
    payload: {
      action,
      pull_request: pr,
      sender: senderLogin ? { login: senderLogin } : undefined,
    },
  };
}

async function run({ action = "opened", prOverrides = {}, senderLogin, existingComments = [] } = {}) {
  const pr = buildPR(prOverrides);
  const context = buildContext({ action, pr, senderLogin });
  const { github, calls } = makeMockGithub(existingComments);
  const { core } = makeMockCore();
  await runTrustLogic(github, context, core);
  return calls;
}

function assertAdmitted(name, calls) {
  t(`${name}: label added`, "yes", yn(calledOnce(calls.addLabels)));
  t(`${name}: PR not closed`, "yes", yn(notCalled(calls.pullsUpdate)));
  t(`${name}: no rejection comment`, "yes", yn(notCalled(calls.createComment)));
}

function assertRejected(name, calls) {
  t(`${name}: no label added`, "yes", yn(notCalled(calls.addLabels)));
  t(`${name}: label removed`, "yes", yn(calledOnce(calls.removeLabel)));
  t(`${name}: PR closed`, "yes", yn(calledOnce(calls.pullsUpdate) && calls.pullsUpdate[0]?.state === "closed"));
  t(`${name}: rejection comment posted`, "yes", yn(calledOnce(calls.createComment)));
}

function assertUngated(name, calls) {
  t(`${name}: left alone (no label)`, "yes", yn(notCalled(calls.addLabels)));
  t(`${name}: left alone (not closed)`, "yes", yn(notCalled(calls.pullsUpdate)));
  t(`${name}: left alone (no comment)`, "yes", yn(notCalled(calls.createComment)));
}

// ---------- Test matrix ----------
async function main() {
  // 1. Fork PR, CONTRIBUTOR, public base repo -> rejected.
  {
    const calls = await run({
      prOverrides: {
        author: "outsider",
        association: "CONTRIBUTOR",
        headFullName: "outsider/widgets",
        baseVisibility: "public",
      },
    });
    assertRejected("fork+CONTRIBUTOR+public", calls);
  }

  // 2. Non-fork PR, CONTRIBUTOR, PUBLIC base repo -> still rejected.
  // Regression test for the bug fixed in PR #38: a public repo must
  // never be trusted via same-repo-branch alone.
  {
    const calls = await run({
      prOverrides: {
        author: "someone",
        association: "CONTRIBUTOR",
        headFullName: "acme-corp/widgets",
        baseVisibility: "public",
      },
    });
    assertRejected("non-fork+CONTRIBUTOR+public (gate-bypass regression)", calls);
  }

  // 3. Non-fork PR, CONTRIBUTOR, PRIVATE base repo -> admitted.
  // The actual incident this feature fixes.
  {
    const calls = await run({
      prOverrides: {
        author: "someone",
        association: "CONTRIBUTOR",
        headFullName: "acme-corp/widgets",
        baseVisibility: "private",
      },
    });
    assertAdmitted("non-fork+CONTRIBUTOR+private (the fixed incident)", calls);
  }

  // 4. Non-fork PR, CONTRIBUTOR, INTERNAL base repo -> rejected.
  // Regression test for the visibility-vs-legacy-private-boolean fix:
  // GitHub Enterprise "internal" repos must not be treated as private.
  {
    const calls = await run({
      prOverrides: {
        author: "someone",
        association: "CONTRIBUTOR",
        headFullName: "acme-corp/widgets",
        baseVisibility: "internal",
      },
    });
    assertRejected("non-fork+CONTRIBUTOR+internal (visibility regression)", calls);
  }

  // 5. Trusted association admits regardless of repo visibility or
  // fork-ness — a fork PR is used here specifically to prove
  // association-based trust does not depend on the same-repo signal.
  for (const association of ["OWNER", "MEMBER", "COLLABORATOR"]) {
    const calls = await run({
      prOverrides: {
        author: "maintainer",
        association,
        headFullName: "maintainer/widgets",
        baseVisibility: "public",
      },
    });
    assertAdmitted(`fork+${association}+public`, calls);
  }

  // 6. First-party automation is left alone, ungated, regardless of
  // association.
  for (const author of ["dependabot[bot]", "github-actions[bot]"]) {
    const calls = await run({
      prOverrides: {
        author,
        association: "NONE",
        headFullName: "acme-corp/widgets",
        baseVisibility: "public",
      },
    });
    assertUngated(`bot:${author}`, calls);
  }

  // 7. Same-repo release-please branch is left alone, ungated, no
  // label — even though it would otherwise be admitted by
  // isTrustedSameRepoPR (private repo) if that check ran first. Proves
  // the release-please check is ordered ahead of the general same-repo
  // trust rule, not just ahead of TRUSTED_ASSOCIATIONS.
  {
    const calls = await run({
      prOverrides: {
        author: "release-please[bot]",
        association: "CONTRIBUTOR",
        headFullName: "acme-corp/widgets",
        headRef: "release-please--branches--main",
        baseVisibility: "private",
      },
    });
    assertUngated("release-please branch (ordering regression)", calls);
  }

  // 8. action: closed -> label removed, nothing else decided.
  {
    const calls = await run({
      action: "closed",
      prOverrides: {
        author: "someone",
        association: "CONTRIBUTOR",
        headFullName: "acme-corp/widgets",
        baseVisibility: "public",
      },
    });
    t("closed: label removed", "yes", yn(calledOnce(calls.removeLabel)));
    t("closed: no label added", "yes", yn(notCalled(calls.addLabels)));
    t("closed: pulls.update not called again", "yes", yn(notCalled(calls.pullsUpdate)));
    t("closed: no comment posted", "yes", yn(notCalled(calls.createComment)));
  }

  // 9. Reopened by someone other than the author -> override honored,
  // even though association/visibility would otherwise reject.
  {
    const calls = await run({
      action: "reopened",
      senderLogin: "maintainer",
      prOverrides: {
        author: "outsider",
        association: "CONTRIBUTOR",
        headFullName: "outsider/widgets",
        baseVisibility: "public",
      },
    });
    assertAdmitted("reopened by non-author (override)", calls);
  }

  // 10. Reopened by the author themself, still untrusted -> rejected
  // again (no infinite-undo of a maintainer's rejection).
  {
    const calls = await run({
      action: "reopened",
      senderLogin: "outsider",
      prOverrides: {
        author: "outsider",
        association: "CONTRIBUTOR",
        headFullName: "outsider/widgets",
        baseVisibility: "public",
      },
    });
    assertRejected("reopened by author self (no override)", calls);
  }

  const ok = t_summary();
  process.exit(ok ? 0 : 1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
