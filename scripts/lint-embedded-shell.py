#!/usr/bin/env python3
"""Shellcheck every `run:` block in the repo's workflow files, each passed
to shellcheck as a FILE rather than piped over stdin.

Works around a known, unfixed actionlint bug (rhysd/actionlint#712):
actionlint's built-in shellcheck integration writes a run: block's script to
the shellcheck subprocess's stdin pipe before it starts draining stdout, and
deadlocks forever once the script exceeds the OS pipe buffer (65536 bytes on
Linux). This repo's own "Request AI review" step sits close enough to that
threshold that it crosses it as the engine grows -- confirmed to trigger the
hang in practice (a 67139-byte revision of that step hung actionlint for
2+ hours in CI before this workaround existed; the exact byte count moves
with every edit to that step, so don't trust a stale number here -- measure
the live file with `len(run.encode("utf-8"))` if you need to know whether a
given revision is over or under). actionlint's own maintainer-confirmed
workaround (per the issue) is to disable the integration (`-shellcheck=`)
and shellcheck each run: block as a file instead, which is what this script
does.

actionlint itself (workflow structure, expression syntax, etc.) still runs
separately with -shellcheck= in ci.yml; this script covers exactly what that
flag turns off.

This is this repo's first Python dependency (PyYAML). tests/lib.sh's own
extract_run() deliberately avoids one -- its comment notes a plain awk/sed
dedent was verified byte-identical to a PyYAML parse specifically so CI
would not need a YAML library. That held for extracting one hardcoded
block; it does not extend to this script's job, which needs real parsed
structure (env:/defaults: at three scope levels, per-step shell:) across
every workflow file, not a single block's text.
"""

import pathlib
import re
import subprocess
import sys
import tempfile

import yaml

WORKFLOWS_DIR = pathlib.Path(".github/workflows")


class _Loader(yaml.SafeLoader):
    """PyYAML's default resolver follows YAML 1.1, where unquoted
    yes/no/on/off/y/n (any case) parse as booleans -- notoriously including
    a bare `on:` key at the top of every workflow file. An env: block key
    or value spelled that way (e.g. `NO: "1"`) silently becomes the Python
    bool False rather than the string "NO", which crashes sorted() on a
    mixed str/bool key set and would produce the wrong placeholder name
    even if it did not crash. GitHub Actions itself treats these as plain
    strings, so drop the bool resolver entirely -- true/false (and case
    variants) are the only workflow fields this script reads as actual
    booleans (none), so nothing here relies on it either way.
    """


_Loader.yaml_implicit_resolvers = {
    first_char: [
        (tag, regexp)
        for tag, regexp in resolvers
        if tag != "tag:yaml.org,2002:bool"
    ]
    for first_char, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}


def effective_default_shell(workflow_defaults: dict | None, job_defaults: dict | None) -> str | None:
    # Job-level defaults.run.shell overrides the workflow-level one; either
    # can set a non-bash default (e.g. python, pwsh) for every step in
    # scope that omits its own shell:.
    for defaults in (job_defaults, workflow_defaults):
        if defaults and (shell := defaults.get("run", {}).get("shell")):
            return shell
    return None


def runs_on_is_windows(runs_on) -> bool:
    # runs-on can be a bare string, a list, or an unresolvable
    # ${{ ... }} expression (matrix-driven OS). Only a literal windows-*
    # STRING is treated as Windows; anything we cannot prove is Windows
    # keeps today's behavior (assume bash) -- a matrix job that resolves
    # to windows at runtime but is not literally spelled out here is a
    # false negative, not a regression, since this script never checked
    # runs-on at all before this fix.
    #
    # A LIST containing "self-hosted" needs a narrower rule than the
    # windows-* PREFIX match used for GitHub-hosted labels. GitHub
    # auto-assigns an EXACT "Windows"/"Linux"/"macOS" OS label (plus an
    # architecture label like "X64"/"ARM64") to every self-hosted runner
    # at registration time, alongside "self-hosted" and any custom labels
    # its admin adds -- e.g. [self-hosted, Windows, X64] is GitHub's own
    # standard shape (this is what ai-review's R2F1 on PR #44 flagged
    # this function as wrongly treating as Bash). That auto-assigned
    # EXACT "windows" label is trustworthy. A mere PREFIX match is not: a
    # Linux self-hosted box can validly carry a custom label like
    # "windows-sdk" ("builds the Windows SDK", not "runs Windows" -- this
    # is what R1F1 on the same PR flagged the previous prefix-based
    # version as wrongly treating as Windows). So for a self-hosted list,
    # only an exact "windows" entry counts; a prefix match does not.
    if isinstance(runs_on, str):
        # Known, accepted gap (not fixed, unlike the list branch above): a
        # BARE STRING custom label -- runs-on: windows-sdk, with no list
        # and no literal "self-hosted" token anywhere for this branch to
        # key off of -- is exactly R1F1's failure mode again, and this
        # branch still can't tell that shape apart from a GitHub-hosted
        # windows-latest/windows-2022 label; both are just a string. Left
        # as a prefix match on the judgment that GitHub's own documented
        # self-hosted examples all use the list form (["self-hosted",
        # ...]), so a bare custom label colliding with the windows-*
        # prefix is a narrower, unconfirmed case rather than one seen in
        # practice -- same bar issue #23's other two cases were held to
        # before being picked up. Revisit if a real workflow hits it.
        return runs_on.strip().lower().startswith("windows")
    if isinstance(runs_on, list):
        labels = [x.strip().lower() for x in runs_on if isinstance(x, str)]
        if "self-hosted" in labels:
            return "windows" in labels
        return any(label.startswith("windows") for label in labels)
    return False


def step_shell_dialect(step: dict, default_shell: str | None, runs_on_windows: bool) -> str | None:
    """Returns the shellcheck --shell dialect to use ("bash" or "sh"), or
    None if the step's script is not a POSIX shell shellcheck understands
    (pwsh, python, a Windows default, etc.) and must be skipped."""
    shell = step.get("shell") or default_shell
    if shell is None:
        # No shell: key anywhere in scope (step/job/workflow defaults).
        # GitHub Actions' own implicit default depends on the runner OS:
        # pwsh on a Windows runner, bash everywhere else (Linux/macOS).
        return None if runs_on_windows else "bash"
    if not shell.strip():
        return None
    # GitHub Actions allows a custom shell command string (e.g.
    # "bash -e {0}", "bash --noprofile --norc -eo pipefail {0}") in place
    # of a bare "bash"/"sh" -- still the same dialect underneath, just with
    # extra flags, and still worth shellchecking. Only the leading command
    # word matters.
    word = shell.split()[0]
    if word == "bash":
        return "bash"
    if word == "sh":
        return "sh"
    return None


_BASH_IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def mask_gha_expressions(script: str) -> str:
    # GitHub Actions substitutes ${{ ... }} expressions into the script text
    # BEFORE bash ever sees it -- it isn't bash syntax at all (it commonly
    # appears inside a quoted string like "${{ github.ref }}", which
    # shellcheck reads as an invalid parameter expansion starting with `{`
    # and rejects with SC2296, failing a step that is valid GitHub Actions
    # workflow syntax and would run correctly in practice). actionlint's
    # own shellcheck integration masks these before handing the script to
    # shellcheck; do the same with a bash-safe placeholder. Contents of the
    # expression don't matter here -- actionlint's own -shellcheck= run in
    # ci.yml (not this script) is what validates expression syntax itself.
    #
    # A plain regex can't find the real closing }} correctly: GHA
    # expression syntax allows a '...' string literal inside the
    # expression, and a literal }} can appear as DATA inside that string
    # (e.g. ${{ format('}}{0}', 'x') }}, or a doubled '' escaped quote
    # inside one). A non-greedy \}\}.*?\}\} regex stops at the first }} it
    # sees, which can be the one inside the string, leaving a corrupted,
    # unmasked fragment of GHA syntax behind for shellcheck to choke on as
    # invalid bash. Scan quote-aware instead: track whether each character
    # is inside a '...' literal (toggling on every quote character --
    # doubled '' quotes cancel out to the same state, which is exactly
    # right, since GHA's own escape convention for a literal quote inside a
    # string is to double it) and only treat }} as the terminator when not
    # inside one.
    out = []
    i = 0
    n = len(script)
    while i < n:
        start = script.find("${{", i)
        if start == -1:
            out.append(script[i:])
            break
        out.append(script[i:start])
        j = start + 3
        in_quote = False
        end = None
        while j < n:
            ch = script[j]
            if ch == "'":
                in_quote = not in_quote
                j += 1
                continue
            if not in_quote and script.startswith("}}", j):
                end = j + 2
                break
            j += 1
        if end is None:
            # Unterminated expression (malformed workflow) -- bail out and
            # keep the rest of the script untouched rather than eating it.
            out.append(script[start:])
            break
        out.append("GHA_EXPR")
        i = end
    return "".join(out)


def env_keys(*envs: dict | None) -> set[str]:
    # A workflow's env: key only has to be a valid YAML mapping key -- it
    # can be referenced entirely through `${{ env.FOO-BAR }}` expression
    # syntax without ever touching bash's $VAR syntax, so GitHub Actions
    # doesn't require it to be a legal shell identifier. This script's own
    # synthetic `NAME=''` placeholder line does need one, though -- a name
    # with e.g. a hyphen or leading digit produces invalid bash on the
    # declaration line itself (shellcheck SC2276/SC2282), which would fail
    # the step for a reason having nothing to do with the workflow author's
    # actual script. Names that can't be a shell identifier are dropped
    # instead: nothing in real bash could have referenced them anyway.
    keys: set[str] = set()
    for env in envs:
        if env:
            keys.update(str(k) for k in env.keys() if _BASH_IDENTIFIER.match(str(k)))
    return keys


def main() -> int:
    failed = False
    for path in sorted(
        p for ext in ("*.yml", "*.yaml") for p in WORKFLOWS_DIR.glob(ext)
    ):
        data = yaml.load(path.read_text(), Loader=_Loader)
        workflow_env = (data or {}).get("env")
        workflow_defaults = (data or {}).get("defaults")
        jobs = (data or {}).get("jobs") or {}
        for job_name, job in jobs.items():
            job_env = job.get("env")
            job_defaults = job.get("defaults")
            default_shell = effective_default_shell(workflow_defaults, job_defaults)
            runs_on_windows = runs_on_is_windows(job.get("runs-on"))
            steps = job.get("steps") or []
            for i, step in enumerate(steps):
                run = step.get("run")
                dialect = step_shell_dialect(step, default_shell, runs_on_windows) if run else None
                if not run or dialect is None:
                    continue
                step_label = step.get("name", f"step {i}")
                # GitHub Actions injects env:-block keys as real environment
                # variables before the script runs; the extracted run: text
                # alone doesn't show that assignment, so shellcheck flags
                # them as unassigned/possible-typos (SC2154/SC2153). actionlint's
                # own integration avoids this by passing the same context;
                # reproduce it here with harmless placeholder assignments.
                keys = sorted(env_keys(workflow_env, job_env, step.get("env")))
                # SC2034 (appears unused): some of these (e.g. GH_TOKEN,
                # which `gh` reads from its own environment) are never
                # referenced as $NAME anywhere in the script text at all --
                # expected for a synthetic placeholder declaration whose
                # only job is to exist so real references to OTHER env:
                # keys don't false-positive as unassigned/typo'd.
                declares = "\n".join(f"{name}=''" for name in keys)
                if declares:
                    declares = "# shellcheck disable=SC2034\n" + declares
                masked_run = mask_gha_expressions(run)
                script = (declares + "\n" + masked_run) if declares else masked_run
                with tempfile.NamedTemporaryFile(
                    mode="w", suffix=".sh", delete=False
                ) as tf:
                    tf.write(script)
                    script_path = tf.name
                try:
                    result = subprocess.run(
                        ["shellcheck", f"--shell={dialect}", script_path],
                        capture_output=True,
                        text=True,
                        timeout=60,
                    )
                finally:
                    pathlib.Path(script_path).unlink(missing_ok=True)
                if result.returncode != 0:
                    failed = True
                    print(
                        f"::error file={path}::shellcheck failed for "
                        f"{path.name} job '{job_name}' step '{step_label}'"
                    )
                    print(result.stdout)
                    print(result.stderr, file=sys.stderr)
                else:
                    print(f"ok   {path.name} job '{job_name}' step '{step_label}'")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
