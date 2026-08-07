#!/usr/bin/env python3
"""Shellcheck every `run:` block in the repo's workflow files, each passed
to shellcheck as a FILE rather than piped over stdin.

Works around a known, unfixed actionlint bug (rhysd/actionlint#712):
actionlint's built-in shellcheck integration writes a run: block's script to
the shellcheck subprocess's stdin pipe before it starts draining stdout, and
deadlocks forever once the script exceeds the OS pipe buffer (65536 bytes on
Linux) -- this repo's own "Request AI review" step is 67139 bytes, just over
that threshold. actionlint's own maintainer-confirmed workaround (per the
issue) is to disable the integration (`-shellcheck=`) and shellcheck each
run: block as a file instead, which is what this script does.

actionlint itself (workflow structure, expression syntax, etc.) still runs
separately with -shellcheck= in ci.yml; this script covers exactly what that
flag turns off.
"""

import pathlib
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


def step_is_bash(step: dict, default_shell: str | None) -> bool:
    shell = step.get("shell") or default_shell
    if shell is None:
        return True
    # GitHub Actions allows a custom shell command string (e.g.
    # "bash -e {0}", "bash --noprofile --norc -eo pipefail {0}") in place
    # of a bare "bash" -- still bash underneath, just with extra flags, and
    # still worth shellchecking. Only the leading command word matters.
    return shell.split()[0] == "bash" if shell.strip() else False


def env_keys(*envs: dict | None) -> set[str]:
    keys: set[str] = set()
    for env in envs:
        if env:
            keys.update(str(k) for k in env.keys())
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
            steps = job.get("steps") or []
            for i, step in enumerate(steps):
                run = step.get("run")
                if not run or not step_is_bash(step, default_shell):
                    continue
                step_label = step.get("name", f"step {i}")
                # GitHub Actions injects env:-block keys as real environment
                # variables before the script runs; the extracted run: text
                # alone doesn't show that assignment, so shellcheck flags
                # them as unassigned/possible-typos (SC2154/SC2153). actionlint's
                # own integration avoids this by passing the same context;
                # reproduce it here with harmless placeholder assignments.
                keys = sorted(env_keys(workflow_env, job_env, step.get("env")))
                # SC2034 (appears unused): some of these (GH_TOKEN, GH_REPO)
                # are read implicitly by external commands (gh) rather than
                # referenced in the script text -- expected for a synthetic
                # placeholder declaration whose only job is to exist.
                declares = "\n".join(f"{name}=''" for name in keys)
                if declares:
                    declares = "# shellcheck disable=SC2034\n" + declares
                script = (declares + "\n" + run) if declares else run
                with tempfile.NamedTemporaryFile(
                    mode="w", suffix=".sh", delete=False
                ) as tf:
                    tf.write(script)
                    script_path = tf.name
                try:
                    result = subprocess.run(
                        ["shellcheck", "--shell=bash", script_path],
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
