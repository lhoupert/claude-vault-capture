"""Secret scrubber — pure stdlib, no network, no subprocess.

Exports:
    scrub(text: str) -> tuple[str, dict[str, int]]
        Returns (redacted_text, counts_by_rule).

Design:
- Idempotent: scrub(scrub(x)) == scrub(x)
- Deterministic: same input → same output
- Fail-safe: re.error on a rule → skip that rule, log to scrub-failures.md
- All patterns compiled with re.MULTILINE
"""

import re
import os
import datetime
import pathlib

from scrub_rules import RULES


def _failures_path() -> pathlib.Path:
    env = os.environ.get("SCRUB_FAILURES_PATH")
    if env:
        return pathlib.Path(env)
    # Derived from this file's location so the checkout can live anywhere.
    return (
        pathlib.Path(__file__).resolve().parent.parent
        / "eval"
        / "state"
        / "scrub-failures.md"
    )


def _log_failure(rule_name: str, exc: Exception) -> None:
    fp = _failures_path()
    fp.parent.mkdir(parents=True, exist_ok=True)
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    line = f"{ts}\t{rule_name}\t{exc}\n"
    try:
        with open(fp, "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass  # log failure is itself non-fatal


def _compile_rules():
    """Compile all rules; a failed rule is logged and skipped."""
    compiled = []
    for rule in RULES:
        try:
            pat = re.compile(rule["pattern"], re.MULTILINE)
            compiled.append((rule, pat))
        except re.error as exc:
            _log_failure(rule["name"], exc)
    return compiled


# Module-level compilation so it happens once on import.
_COMPILED = _compile_rules()


def scrub(text: str) -> tuple[str, dict[str, int]]:
    """Apply all rules to *text* and return (redacted, counts_by_rule)."""
    counts: dict[str, int] = {rule["name"]: 0 for rule in RULES}
    result = text
    for rule, pat in _COMPILED:
        result, n = pat.subn(rule["replacement"], result)
        counts[rule["name"]] += n
    return result, counts
