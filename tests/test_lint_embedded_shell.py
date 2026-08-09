"""Unit tests for scripts/lint-embedded-shell.py's own logic: the Windows
implicit-shell detection, sh dialect support, and quote-aware GHA-expression
masking added to close the three advisory edge cases from issue #23. Loads
the real script by path (its filename has a hyphen, so it cannot be a
normal import) so a future edit is tested directly, not a hand-retyped
mirror of it.

Output format matches tests/lib.sh's t()/t_summary() convention so this
composes with run_all.sh's existing summary line.
"""

import importlib.util
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "scripts" / "lint-embedded-shell.py"

_spec = importlib.util.spec_from_file_location("lint_embedded_shell", SCRIPT_PATH)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

t_pass = 0
t_fail = 0


def t(name, expected, actual):
    global t_pass, t_fail
    if expected == actual:
        t_pass += 1
        print(f"ok   {name}")
    else:
        t_fail += 1
        print(f"FAIL {name}")
        print(f"     expected: {expected!r}")
        print(f"     actual:   {actual!r}")


def t_summary():
    print()
    print(f"{t_pass} passed, {t_fail} failed")
    return t_fail == 0


# ---------- R4F2: implicit Windows shells are not bash ----------
t("runs_on_is_windows: windows-latest", True, _mod.runs_on_is_windows("windows-latest"))
t("runs_on_is_windows: windows-2022", True, _mod.runs_on_is_windows("windows-2022"))
t("runs_on_is_windows: ubuntu-latest", False, _mod.runs_on_is_windows("ubuntu-latest"))
t("runs_on_is_windows: list with a windows label", True, _mod.runs_on_is_windows(["self-hosted", "Windows"]))
t("runs_on_is_windows: list without a windows label", False, _mod.runs_on_is_windows(["self-hosted", "linux"]))
t("runs_on_is_windows: unresolvable expression", False, _mod.runs_on_is_windows("${{ matrix.os }}"))

t(
    "step_shell_dialect: no shell key, ubuntu runner -> bash",
    "bash",
    _mod.step_shell_dialect({}, None, runs_on_windows=False),
)
t(
    "step_shell_dialect: no shell key, windows runner -> skip (was bash before the fix)",
    None,
    _mod.step_shell_dialect({}, None, runs_on_windows=True),
)
t(
    "step_shell_dialect: explicit shell: pwsh on windows runner -> skip",
    None,
    _mod.step_shell_dialect({"shell": "pwsh"}, None, runs_on_windows=True),
)

# ---------- R4F3: shell: sh is checked, not silently skipped ----------
t("step_shell_dialect: shell: sh -> sh", "sh", _mod.step_shell_dialect({"shell": "sh"}, None, runs_on_windows=False))
t(
    "step_shell_dialect: shell: sh -e {0} (flags) -> sh",
    "sh",
    _mod.step_shell_dialect({"shell": "sh -e {0}"}, None, runs_on_windows=False),
)
t(
    "step_shell_dialect: job default shell: sh -> sh",
    "sh",
    _mod.step_shell_dialect({}, "sh", runs_on_windows=False),
)
t(
    "step_shell_dialect: bash with flags -> bash (unchanged)",
    "bash",
    _mod.step_shell_dialect({"shell": "bash --noprofile --norc -eo pipefail {0}"}, None, runs_on_windows=False),
)
t(
    "step_shell_dialect: shell: python -> skip (unchanged)",
    None,
    _mod.step_shell_dialect({"shell": "python"}, None, runs_on_windows=False),
)

# ---------- R5F1: quote-aware }} termination ----------
t(
    "mask_gha_expressions: plain expression",
    'echo "GHA_EXPR"',
    _mod.mask_gha_expressions('echo "${{ github.ref }}"'),
)
t(
    "mask_gha_expressions: literal }} inside a string argument is not the terminator",
    "echo GHA_EXPR",
    _mod.mask_gha_expressions("echo ${{ format('}}{0}', 'x') }}"),
)
t(
    "mask_gha_expressions: doubled '' escaped quote inside the string still finds the real terminator",
    "echo GHA_EXPR",
    _mod.mask_gha_expressions("echo ${{ format('a''b}}c', 1) }}"),
)
t(
    "mask_gha_expressions: two separate expressions on one line",
    "GHA_EXPR and GHA_EXPR",
    _mod.mask_gha_expressions("${{ a }} and ${{ b }}"),
)
t(
    "mask_gha_expressions: no expression present -> untouched",
    "echo hello",
    _mod.mask_gha_expressions("echo hello"),
)
t(
    "mask_gha_expressions: unterminated expression is left as-is, not eaten",
    "echo ${{ a.b",
    _mod.mask_gha_expressions("echo ${{ a.b"),
)

# ---------- Structural checks: the real script must call these, not a
# reverted always-bash / naive-regex version ----------
source = SCRIPT_PATH.read_text()
t("engine: main() uses step_shell_dialect, not the old step_is_bash", True, "step_shell_dialect(" in source)
t("engine: main() computes runs_on_is_windows per job", True, "runs_on_is_windows(" in source)
t(
    "engine: shellcheck invocation uses the resolved dialect, not a hardcoded --shell=bash",
    True,
    '"--shell={dialect}"' in source or "f'--shell={dialect}'" in source,
)

if t_summary():
    sys.exit(0)
sys.exit(1)
