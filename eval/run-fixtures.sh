#!/usr/bin/env bash
# Run each fixture through curate.py and VALIDATE the written artifacts.
#
# Default (CAPTURE_MOCK_SDK=1): inject the recorded mock-responses.json artifacts
# into _call_path_a (same logic as the mock_from_responses pytest fixture) and
# assert the pipeline writes exactly the files the mock implies and logs no
# error skip reason. This is a real output check — it is NOT always-green.
#
# Live (CAPTURE_LIVE_TESTS=1): unset the mock and run against the real API; assert
# only that the pipeline completed without an error skip reason.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
FIXTURES="$SCRIPT_DIR/fixtures"
HOOKS="$ROOT/hooks"

export CAPTURE_MOCK_SDK="${CAPTURE_MOCK_SDK:-1}"

if [[ "${CAPTURE_LIVE_TESTS:-0}" == "1" ]]; then
    unset CAPTURE_MOCK_SDK
fi

VAULT_TMP=$(mktemp -d)
LOG_TMP=$(mktemp -d)
trap 'rm -rf "$VAULT_TMP" "$LOG_TMP"' EXIT

export PYTHONPATH="$HOOKS:${PYTHONPATH:-}"

PASS=0
FAIL=0

run_fixture() {
    local name="$1"
    local fixture="$FIXTURES/${name}.txt"
    if [[ ! -f "$fixture" ]]; then
        echo "SKIP $name (fixture not found)"
        return
    fi

    local session_id
    session_id="fixture-${name}-$(date +%s)-$RANDOM"
    local log_file="$LOG_TMP/log-${name}.md"
    local index_file="$LOG_TMP/index-${name}.tsv"

    # The python block builds the transcript, injects mocks (mock mode), runs the
    # pipeline, and asserts the written files match what the mock entry implies.
    # A non-zero exit here is a real failure, not a swallowed one.
    if FIXTURE_NAME="$name" FIXTURE_PATH="$fixture" \
       SESSION_ID="$session_id" VAULT_TMP="$VAULT_TMP" \
       LOG_FILE="$log_file" INDEX_FILE="$index_file" \
       MOCK_RESPONSES="$FIXTURES/mock-responses.json" \
       python3 - <<'PY' 2>&1; then
import json, os, pathlib, sys
import curate  # resolved via PYTHONPATH (exported above)

name = os.environ["FIXTURE_NAME"]
fixture_path = os.environ["FIXTURE_PATH"]
session_id = os.environ["SESSION_ID"]
vault_dir = pathlib.Path(os.environ["VAULT_TMP"]) / name
mock_mode = os.environ.get("CAPTURE_MOCK_SDK") == "1"

content = open(fixture_path).read()
# Repeat enough to clear the threshold (>=3 user turns, >=1500 chars).
transcript = [{"role": "user", "content": content} for _ in range(4)]

if mock_mode:
    responses = json.loads(open(os.environ["MOCK_RESPONSES"]).read())
    if name not in responses:
        print(f"no mock entry for {name!r} in mock-responses.json")
        sys.exit(1)
    entry = responses[name]
    a = entry["path_a"]

    def _mock_a(*args, **kwargs):
        return None if a is None else dict(a)

    curate._call_path_a = _mock_a

curate.run_capture(
    transcript=transcript,
    session_id=session_id,
    cwd="/tmp",
    vault_dir=str(vault_dir),
    log_path=pathlib.Path(os.environ["LOG_FILE"]),
    index_path=pathlib.Path(os.environ["INDEX_FILE"]),
    date_str="2026-01-01",
)

log_lines = [l for l in pathlib.Path(os.environ["LOG_FILE"]).read_text().splitlines() if l.strip()]
assert log_lines, "no log entry written"
log = json.loads(log_lines[-1])

auto = list((vault_dir / "Inbox" / "auto").glob("*.md"))

errors = []
if (log.get("skip_reason_a") or "").startswith("error:"):
    errors.append(f"skip_reason_a={log['skip_reason_a']} (pipeline error swallowed)")

if mock_mode:
    expect_a = isinstance(a, dict)
    if bool(auto) != expect_a:
        errors.append(f"Path A file present={bool(auto)} but expected={expect_a}")
    if a is None and log.get("skip_reason_a") != "model_returned_null":
        errors.append(f"expected model_returned_null, got {log.get('skip_reason_a')!r}")

if errors:
    print("; ".join(errors))
    sys.exit(1)
PY
        echo "PASS $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL $name"
        FAIL=$((FAIL + 1))
    fi
}

for fixture_file in "$FIXTURES"/*.txt; do
    name=$(basename "$fixture_file" .txt)
    run_fixture "$name"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
