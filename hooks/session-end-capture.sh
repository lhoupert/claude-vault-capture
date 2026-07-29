#!/usr/bin/env bash
# SessionEnd hook entry point — returns in <200ms; all model work is backgrounded.
set -euo pipefail

HOOKS_LOG="$HOME/.claude/hooks.log"

# Print a credential file's contents only if it is owner-only (mode *00); a
# hand-made `echo $TOKEN > file` is 644, i.e. readable by every local user, and
# must not be treated as a usable credential. -L follows symlinks so a token
# symlinked to a 600 file is not refused with a chmod hint that cannot fix it.
# GNU -c is probed first because BSD stat rejects it cleanly, whereas GNU stat
# treats -f as "filesystem" and prints a multi-line blob.
_read_secret_file() {
    local f="$1" perms
    perms="$(stat -L -c '%a' "$f" 2>/dev/null || stat -L -f '%Lp' "$f" 2>/dev/null)" || return 1
    if [[ "$perms" != *00 ]]; then
        mkdir -p "$(dirname "$HOOKS_LOG")"
        printf 'CAPTURE_TOKEN_FILE_PERMS\t%s\t%s is mode %s (group/other-readable) — refusing to use it; run: chmod 600 %s\n' \
            "${NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" "$f" "$perms" "$f" >> "$HOOKS_LOG"
        return 1
    fi
    cat "$f"
}

# Resolve the repo from this script's own location so the checkout can live anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"
CURATE="$REPO/hooks/curate.py"
VENV_PYTHON="$REPO/.venv/bin/python3"

# Load per-user config (CAPTURE_VAULT_DIR and any optional flags) written by
# install.sh. Gitignored, so each user's vault path stays out of version control.
if [[ -f "$REPO/capture.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$REPO/capture.env"
    set +a
fi

# Every branch below may log; guarantee the destination and one coherent
# timestamp up front (each $(date) is a fork — this is the <200ms close path).
mkdir -p "$(dirname "$HOOKS_LOG")"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Read hook JSON from stdin
HOOK_JSON=$(cat)

# Extract fields
TRANSCRIPT_PATH=$(echo "$HOOK_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('transcript_path',''))" 2>/dev/null || true)
SESSION_ID=$(echo "$HOOK_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null || true)
CWD=$(echo "$HOOK_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || true)

# Guard: if we couldn't parse the fields, bail silently
if [[ -z "$SESSION_ID" || -z "$TRANSCRIPT_PATH" ]]; then
    exit 0
fi

# Guard: refuse to run unconfigured. install.sh writes CAPTURE_VAULT_DIR into
# capture.env; without it we have no destination, so log a marker and exit cleanly.
if [[ -z "${CAPTURE_VAULT_DIR:-}" ]]; then
    printf 'CAPTURE_NOT_CONFIGURED\t%s\tCAPTURE_VAULT_DIR unset — run install.sh\n' \
        "$NOW" >> "$HOOKS_LOG"
    exit 0
fi

# Claude Code sanitizes its environment before spawning hooks, so credentials are
# often absent even when the desktop app has them. Fall back to token files.
if [[ "${CAPTURE_USE_SUBSCRIPTION:-}" == "1" ]]; then
    # Subscription mode: the Claude Agent SDK authenticates with this OAuth token
    # (generate it once with `claude setup-token`).
    if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -f "$HOME/.claude_vault_oauth_token" ]]; then
        # SC2155: export masks cat's exit code on purpose — a token-read hiccup must
        # not abort this close-path hook under `set -e`; curate.py handles missing creds.
        # shellcheck disable=SC2155
        export CLAUDE_CODE_OAUTH_TOKEN="$(_read_secret_file "$HOME/.claude_vault_oauth_token")"
    fi
elif [[ -z "${ANTHROPIC_API_KEY:-}" && -f "$HOME/.claude_vault_token" ]]; then
    # shellcheck disable=SC2155  # see rationale above: don't abort the close path
    export ANTHROPIC_API_KEY="$(_read_secret_file "$HOME/.claude_vault_token")"
fi

# Ground-truth marker BEFORE backgrounding (pre-log crash gap detection)
printf 'SESSION_END_RECEIVED\t%s\t%s\n' "$SESSION_ID" "$NOW" >> "$HOOKS_LOG"

# Deploy-drift guard: the June–July timeout outage was a checkout stuck behind
# origin/main, so the running code silently wasn't the merged code. Log the
# running SHA every session and flag when the last-fetched origin/main is not
# an ancestor of HEAD. Local-only git ops — never fetch on the close path.
DEPLOY_SHA="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
DEPLOY_STATE="ok"
if [[ "$DEPLOY_SHA" == "unknown" ]]; then
    DEPLOY_STATE="unknown"
elif git -C "$REPO" rev-parse --verify -q origin/main >/dev/null 2>&1 \
    && ! git -C "$REPO" merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
    DEPLOY_STATE="STALE_DEPLOY(behind origin/main as last fetched)"
fi
printf 'CAPTURE_DEPLOY\t%s\t%s\t%s\n' "$DEPLOY_SHA" "$DEPLOY_STATE" \
    "$NOW" >> "$HOOKS_LOG"

# Background curate.py — detached, stdout/stderr → hooks.log
nohup "$VENV_PYTHON" "$CURATE" "$TRANSCRIPT_PATH" "$SESSION_ID" "$CWD" \
    >>"$HOOKS_LOG" 2>&1 &

exit 0
