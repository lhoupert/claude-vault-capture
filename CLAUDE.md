# claude-vault-capture — agent context

Automatically captures Claude Code sessions into an Obsidian vault on `SessionEnd`. A single curation path runs on every qualifying session: **Path A** (Sonnet) extracts one durable artifact or returns null (→ `Inbox/auto/`), retrying once on a non-deterministic null. Path B (the Haiku raw baseline → `Inbox/raw/`) was retired 2026-06-04 after the eval showed it didn't earn its keep — see `eval/experiments/FINDINGS.md`.

## How to run tests

```bash
uv sync                # installs anthropic + the default dev group (pytest, pyyaml, ruff, pre-commit)
uv run pytest          # 158 tests, no network (plus 1 opt-in live, skipped)
CAPTURE_MOCK_SDK=1 uv run pytest -k failure_isolation   # specific test with mock SDK
bash eval/run-install-smoke.sh   # installer smoke test (tmp dirs, no real writes)
```

## Local checks (pre-commit)

```bash
uv run pre-commit install          # one-time: installs pre-commit + pre-push hooks
uv run pre-commit run --all-files  # run every hook against the whole repo
```

`.pre-commit-config.yaml` mirrors the CI gates so failures surface before they reach CI: ruff check + format and pytest (pre-push) run via `uv run`, so they use the **same versions pinned in `pyproject.toml`** — no drift from CI. shellcheck (`-S warning`) and zizmor (workflow + dependabot security audit) run as hosted hooks. The CI `lint`/`zizmor` jobs remain the enforced gate; pre-commit is the local mirror.

No test requires a live Anthropic API key. `CAPTURE_MOCK_SDK=1` substitutes `eval/fixtures/mock-responses.json`. The live test runs only with `CAPTURE_LIVE_TESTS=1`. PyYAML is a **test-only** dependency — runtime parses frontmatter with stdlib regex and never imports `yaml`.

## Architecture

```
session-end-capture.sh  →  curate.py (backgrounded, nohup)
                               │
          render tool I/O → scrub → excluded_cmd? → threshold? → token_limit? → dedup?
                               │
                        Path A: Sonnet → strip fences → parse JSON (or null,
                                retried once) → curated artifact
                               │
                        scrub output → sanitize title → write file → log
```

**Key files:**
- `hooks/session-end-capture.sh` — entry point; reads stdin JSON, logs `SESSION_END_RECEIVED`, backgrounds `curate.py`. Returns in <200ms.
- `hooks/curate.py` — full pipeline. All imports at function scope for fast startup. `render_transcript()` builds the model input: text plus compact `[TOOL]`/`[OUT]`/`[ERROR]` lines (commands, edit diffs, output heads, failures), budgeted so the enriched transcript stays under the token guard. Filters read the text-only `content`; only the model input is enriched.
- `hooks/scrub.py` + `hooks/scrub_rules.py` — pure stdlib secret scrubber; runs twice (before API call, after).
- `prompts/curation-system-prompt.md` — the only model-facing prompt; every change is a commit.
- `eval/state/log.md` — JSON-lines eval log (gitignored); `eval/state/session-index.tsv` — dedup index.

**Skill integrations** (installed by `install.sh`). The remaining patch file carries `__VAULT_DIR__` / `__REPO_DIR__` placeholders that the installer substitutes with the user's resolved absolute paths:
- `/vault-save` skill (`skill-patches/vault-save.md`) — on-demand export of a Claude-generated markdown document to `<vault>/claude-docs/`. No model call; Claude writes the file directly with structured frontmatter (`source: claude-code-export`). Always installed. Auto-triggered when the user asks to save/export a document to their vault (via `~/.claude/CLAUDE.md` injection from `skill-patches/global-claude-md.vault-save-trigger.md`).

**Inbox triage is out-of-scope for this repo.** Promoting/backlinking captured artifacts is handled by *external extensions* that consume the documented Inbox contract: they read `Inbox/auto/` and read-only `eval/state/{session-index.tsv,log.md,scrub-failures.md}`, and set `CAPTURE_EXCLUDED_COMMANDS` in `capture.env` to skip capturing their own workflow sessions. (`Inbox/raw/` is no longer written as of the Path B retirement; extensions must tolerate its absence.) The public installer never patches workflow skills — it only ships `/vault-save`.

## Invariants — never violate these

- **<200ms on the close path.** All model work is backgrounded. Nothing synchronous on `SessionEnd`.
- **Curation failure is contained.** A Path A exception is caught in `run_capture` and logged as `error:<type>` — it must never write a partial file or abort the log append.
- **Scrub runs twice.** On the transcript before any API call; on each model output before writing to disk.
- **Title is always sanitized** before it appears in a filename, frontmatter, or wikilink.
- **Fence-stripping before JSON parsing.** Models sometimes wrap JSON in ` ```json…``` ` despite prompt instructions. `_strip_fences()` is applied to every model response before `json.loads()`.
- **The transcript is always terminated.** `_invoke_model` appends `_TRANSCRIPT_TAIL` once, before dispatching to either transport, closing the delimiter and restating the JSON-or-null contract. Without it the prompt is an unfinished chat log and the model writes the conversation's next turn instead of curating — the cause of every `malformed_json` in the archive. Never send transcript text as the last thing in a prompt, and keep the append at the dispatch point so a new transport can't forget it.
- **Salvage requires artifact shape.** `_salvage_artifact()` only accepts an object carrying `title`/`type`/`body`. The write path defaults every missing field, so an unshaped dict (e.g. a fabricated `{"file_path": …}`) would otherwise be written to `Inbox/` as an empty "untitled" note.
- **No writes outside `Inbox/`.** Promotions to structured vault folders happen only via explicit user approval in skill patches.
- **`eval/state/` is gitignored.** Runtime state is never committed.

## Pipeline skip reasons (for log.md)

| skip_reason | when |
|---|---|
| `excluded_command` | a user turn starts with a command listed in `CAPTURE_EXCLUDED_COMMANDS` (empty by default; set by extensions via `capture.env`) |
| `threshold` | < 3 user turns OR < 1500 chars of user content |
| `token_limit` | `len(scrubbed_text) // 4 > CAPTURE_MAX_EST_TOKENS` (default 50 000) |
| `duplicate` | session_id already present in session-index.tsv |
| `model_returned_null` | Sonnet returned the literal string `null` on **every** attempt (initial call plus the one resample) |
| `malformed_json` | at least one attempt was unparseable after fence-stripping and artifact salvage, and no attempt produced an artifact. Wins over `model_returned_null` in a mixed sequence, so a trailing null can't erase the unparseable reply from the log |
| `timeout` | a model call exceeded `CAPTURE_TIMEOUT_SECONDS` (default 30 s) |
| `error:<ExcType>` | any other exception |

## Environment

- Python **3.11+** (floor: subscription-mode timeout relies on `asyncio.TimeoutError` aliasing the builtin, 3.11+). Dev venv is 3.14. `pyproject.toml` is the manifest; `uv sync` installs deps. Run via `uv run` or `.venv/bin/python3`.
- **Paths are not hardcoded.** The repo root is derived from each file's own location (`__file__` / `${BASH_SOURCE[0]}`), so the checkout can live anywhere. The vault path comes from `CAPTURE_VAULT_DIR`, which `install.sh` resolves and writes to a gitignored `capture.env`; `session-end-capture.sh` sources that file and refuses to run (logs `CAPTURE_NOT_CONFIGURED`) if the vault is unset.
- `ANTHROPIC_API_KEY` must be set (API-key mode). If absent in hook env, `session-end-capture.sh` reads `~/.claude_vault_token` as fallback.
- `CAPTURE_USE_SUBSCRIPTION=1` — route the curation model call through the Claude Agent SDK (Claude Code runtime) so it bills to a Pro/Max subscription instead of a metered key. Auth via `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`; hook falls back to `~/.claude_vault_oauth_token`). Because `capture.env` is sourced with `set -a`, you can resolve the token from the **macOS Keychain** instead of a plaintext file — see the README's "Using your Claude Pro or Max subscription" section for the `security add-generic-password` + `find-generic-password` recipe. Requires `claude-agent-sdk` + the `claude` CLI. In this mode `cost_usd` is an *estimated* API-equivalent, not billed, and `max_tokens` is not enforced (runtime controls output). The model-call transport is the only difference — scrub/filter/parse/write are identical.
- `CAPTURE_MOCK_SDK=1` — skip real API calls; use `eval/fixtures/mock-responses.json`.
- `CAPTURE_MAX_EST_TOKENS` — override token ceiling (default 50 000).
- `CAPTURE_TIMEOUT_SECONDS` — override the per-call model timeout in seconds (default 30). Raise it for large sessions or slow links; all model work is backgrounded off the close path, so a higher value never delays a session.
- `CAPTURE_TOOL_CHARS_BUDGET` — max chars of rendered tool activity added to the curator input (default 30 000). Once spent, further `[TOOL]`/`[OUT]` lines are dropped; `[ERROR]` lines are always kept. Caps the enrichment so it can't trip the token guard. Measured impact: ~+$0.015/session input (output unchanged); see `eval/experiments/tool_enrichment_cost.py`.
- `CAPTURE_SUCCESS_HEAD_CHARS` — chars of each successful tool result included as an `[OUT]` head (default 200; set `0` to drop successful output entirely and keep only commands + errors).

## What NOT to do

- Don't add synchronous work to `session-end-capture.sh` — it must return in <200ms.
- Don't add model calls to the scrubber — it's pure stdlib, no network.
- Don't log to the user's terminal — errors go to `~/.claude/hooks.log` via stderr.
- Don't write outside `Inbox/` from `curate.py`.
- Don't change `eval/state/log.md` schema without bumping `schema_version`.
- Don't add a model call without updating the cost estimate in `_estimate_cost_a` and §8 of the spec.
