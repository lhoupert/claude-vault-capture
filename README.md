# claude-vault-capture

Automatically turn your [Claude Code](https://claude.ai/code) sessions into notes in your [Obsidian](https://obsidian.md) vault. When a session ends, a background job summarizes it and drops a markdown file into your vault's `Inbox/` — so the decisions, runbooks, and gotchas you worked through don't evaporate when you close the terminal.

Nothing runs synchronously on session close (the hook returns in well under 200 ms); all model work is backgrounded. Secrets are scrubbed before anything is sent to a model and again before anything is written to disk.

## What you get

At most one note per session, in `<vault>/Inbox/auto/`. A model reads the session and either extracts **one** durable artifact — a decision, runbook, gotcha, or spec — or returns nothing, if the session was low-signal. Most sessions produce nothing, by design.

A capture looks like this:

```markdown
---
title: "icechunk RepositoryConfig storage timeouts silently ignored"
type: gotcha
project: my-project
tags: [claude-code, curated, icechunk, s3]
source: claude-code-curated
session_id: 4f3a91c2-...
created: 2026-07-29
model: claude-sonnet-4-6
cost_usd: 0.0198
---

# icechunk RepositoryConfig storage timeouts silently ignored
## Symptom
Timeouts passed via `config=` are ignored when `Repository.exists(storage)` ran first…
```

**What leaves your machine:** the session transcript — your prompts, Claude's replies, and a budgeted summary of tool activity (commands run, edit diffs, output heads, errors) — is sent to Anthropic's API after scrubbing. Secrets matching the [scrub rules](hooks/scrub_rules.py) are redacted first, but scrubbing is pattern-based and not a guarantee. If you work with material you can't send to a model API, don't install this.

**What it costs:** roughly $0.01–0.05 per captured session on Sonnet, depending on transcript size. Sessions below the capture threshold cost nothing (no model call is made). Or bill it to a Claude Pro/Max plan instead — see [subscription mode](#using-your-claude-pro-or-max-subscription-instead-of-an-api-key).

## Install

Install it as a Claude Code plugin:

```
/plugin marketplace add developmentseed/skills
/plugin install claude-vault-capture@skills
```

Claude Code prompts for your Obsidian vault path (and optionally an API key). The `SessionEnd` hook is registered automatically, the `/vault-save` skill becomes available, and runtime state is kept in the plugin's own data directory. Sensitive values (API key, OAuth token) go to your OS keychain.

**This is the install route you want.** The rest of this README documents the repo itself — the upstream source for that plugin, useful if you're developing on it or need a rollback.

<details>
<summary><strong>Standalone install from this checkout</strong> (maintainers / rollback only)</summary>

`install.sh` predates the plugin. It still works, but **do not run it if you have the plugin installed** — you would get two `SessionEnd` hooks, each with its own dedup index, so every session costs two model calls and writes two notes. If you previously ran `install.sh`, remove its entry from `~/.claude/settings.json` before installing the plugin.

```bash
git clone https://github.com/developmentseed/claude-vault-capture
cd claude-vault-capture
uv sync                                   # create .venv/ and install dependencies
./install.sh --vault ~/path/to/YourVault  # register the hook + point it at your vault
```

If you omit `--vault`, the installer reads `CAPTURE_VAULT_DIR`, reuses a previous choice from `capture.env`, or prompts you. Your vault path is written to a gitignored `capture.env` and never committed.

The installer is idempotent — safe to re-run after updates. It writes **outside this repo**, which matters if you later want to remove it:
- Creates `<vault>/Inbox/auto/` and `<vault>/claude-docs/`
- Registers the `SessionEnd` hook in `~/.claude/settings.json`
- Writes `capture.env` in the repo with your `CAPTURE_VAULT_DIR`
- Installs a `/vault-save` skill at `~/.claude/skills/vault-save/`
- Injects a marker-bounded trigger block into your global `~/.claude/CLAUDE.md`

To uninstall: delete the `SessionEnd` entry from `~/.claude/settings.json`, remove `~/.claude/skills/vault-save/`, and delete the `<!-- BEGIN claude-vault-capture: vault-save-trigger -->` block from `~/.claude/CLAUDE.md`. Captured notes already in your vault are yours to keep or delete.

</details>

## Making your credentials reachable by the hook

**This step is required, and skipping it is the most common reason nothing gets captured.** Claude Code sanitizes the environment it spawns hooks with, so an `export ANTHROPIC_API_KEY=…` in your shell profile does **not** reach the capture worker. Write the credential to a file the hook reads instead. It must be owner-only — the hook refuses group- or world-readable credential files:

```bash
umask 077 && printf '%s\n' "$ANTHROPIC_API_KEY" > ~/.claude_vault_token
chmod 600 ~/.claude_vault_token    # required; a 644 file is ignored
```

(Plugin users can instead set the API key in the plugin's config, where it's stored in your OS keychain.)

For subscription mode, the equivalent file is `~/.claude_vault_oauth_token` — see [below](#using-your-claude-pro-or-max-subscription-instead-of-an-api-key).

## Verify it's working

After your **next** session ends — the hook fires at session close, so the session you installed during doesn't count:

```bash
# 1. Did the hook fire?
grep SESSION_END_RECEIVED ~/.claude/hooks.log | tail -5

# 2. What did it decide? (standalone install; plugin state lives in its own data dir)
tail -1 eval/state/log.md | python3 -m json.tool

# 3. Was a note written?
ls "$(grep -E '^CAPTURE_VAULT_DIR=' capture.env | cut -d= -f2- | tr -d '"')"/Inbox/auto/
```

A `skip_reason_a` of `null` in step 2 means a note was written. Anything else is a skip.

### Nothing was captured — what now?

Most "it's broken" reports are one of the deliberate skips. Sessions are silently skipped when there are fewer than 3 user turns, under 1500 characters of your own content, the transcript exceeds the token ceiling, an excluded slash command was used, or the session is already indexed. **Test with a real, substantial session**, not a two-message one.

If step 1 shows nothing, the hook isn't registered — check `~/.claude/settings.json` (or `/hooks` in Claude Code). If step 1 works but step 2 shows a problem, `~/.claude/hooks.log` names it:

| In `hooks.log` | Meaning | Fix |
|---|---|---|
| `ANTHROPIC_API_KEY not set` | no credential reached the hook | write the token file above |
| `CAPTURE_TOKEN_FILE_PERMS` | token file is group/other-readable | `chmod 600` the file it names |
| `CAPTURE_NOT_CONFIGURED` | no vault path | re-run `install.sh --vault …` |
| `skip_reason: timeout` | model call exceeded the deadline | raise `CAPTURE_TIMEOUT_SECONDS` |
| `skip_reason: malformed_json` | model didn't return a usable artifact | usually transient; check it isn't every session |

## Tests

```bash
uv run pytest          # full suite; no network, no API key needed
```

An opt-in live test makes real model calls and is skipped unless `CAPTURE_LIVE_TESTS=1`.
Two harnesses cover the parts pytest doesn't: `bash eval/run-fixtures.sh` (pipeline against recorded fixtures) and `bash eval/run-install-smoke.sh` (installer, against temp dirs).

If you plan to contribute, install the git hooks so the same checks CI runs
(ruff, shellcheck, zizmor, tests) run locally first:

```bash
uv run pre-commit install          # one-time
uv run pre-commit run --all-files  # run them all now
```

## Configuration

Standalone installs read these from `capture.env` (the hook sources the whole file before launching the worker). Plugin installs set the equivalents in the plugin's config instead.

| Env var | Default | Effect |
|---|---|---|
| `CAPTURE_VAULT_DIR` | — | **Required.** Your Obsidian vault path. Set by `install.sh` (via `--vault`/prompt). |
| `ANTHROPIC_API_KEY` | — | Required in API-key mode; falls back to `~/.claude_vault_token` (mode 600) |
| `CAPTURE_USE_SUBSCRIPTION` | — | Set to `1` to bill model calls to your Claude Pro/Max subscription (see below) |
| `CLAUDE_CODE_OAUTH_TOKEN` | — | Subscription auth; falls back to `~/.claude_vault_oauth_token` (mode 600) |
| `CAPTURE_TIMEOUT_SECONDS` | `30` | Hard wall on one model call. Raise it if large sessions log `timeout` — model work is backgrounded, so a higher value never delays session close |
| `CAPTURE_MAX_EST_TOKENS` | `50000` | Token ceiling before skipping (~200 KB transcript) |
| `CAPTURE_EXCLUDED_COMMANDS` | — | Comma-separated slash commands whose sessions are not captured (e.g. `/my-journal,/my-recap`). Empty by default |
| `CAPTURE_TOOL_CHARS_BUDGET` | `30000` | Max characters of rendered tool activity added to the model input |
| `CAPTURE_SUCCESS_HEAD_CHARS` | `200` | Characters of each successful tool result included; `0` keeps only commands and errors |
| `CAPTURE_MOCK_SDK` | — | Set to `1` to skip API calls and use fixture responses (testing) |
| `SCRUB_FAILURES_PATH` | `eval/state/scrub-failures.md` | Where a failed scrub rule is logged (testing) |

### Using your Claude Pro or Max subscription instead of an API key

By default the model call hits the metered Messages API (`ANTHROPIC_API_KEY`).
Set `CAPTURE_USE_SUBSCRIPTION=1` to route it through the Claude Code runtime
(via the [Claude Agent SDK](https://docs.claude.com/en/api/agent-sdk/overview))
and bill it to your Pro or Max subscription instead. Works the same on either
plan — both share the rolling rate limit noted in the trade-offs below.

**1. Install the transport and turn the flag on**

```bash
uv sync --extra subscription                 # installs claude-agent-sdk (the `claude` CLI must also be installed)
echo 'CAPTURE_USE_SUBSCRIPTION=1' >> capture.env
```

**2. Generate a long-lived OAuth token**

Run this in a *normal terminal* — it opens a browser (or prints a URL to open),
so it can't complete from inside a non-interactive shell:

```bash
claude setup-token        # authorize in the browser; it prints a token starting with sk-ant-oat01-…
```

**3. Make the token available to the hook**

The hook authenticates with `CLAUDE_CODE_OAUTH_TOKEN`, falling back to the file
`~/.claude_vault_oauth_token`. Choose one of:

*Option A — plaintext file (simplest):*

```bash
umask 077 && printf '%s\n' '<token>' > ~/.claude_vault_oauth_token
```

*Option B — macOS Keychain (recommended; no plaintext token on disk):*

Store the token in your login Keychain once, then let `capture.env` resolve it
at hook time. `capture.env` is sourced with `set -a`, so the export reaches the
backgrounded worker.

```bash
# Store it once. -A lets the background hook read it without a GUI prompt:
security add-generic-password -U -a "$(id -un)" -s claude-vault-oauth -w '<token>' -A

# Point capture.env at the Keychain item:
cat >> capture.env <<'EOF'
export CLAUDE_CODE_OAUTH_TOKEN="$(security find-generic-password -s claude-vault-oauth -w 2>/dev/null)"
EOF
```

The lookup is by service name only (no `-a` on read) so it still works even
though Claude Code strips `$USER` from the hook environment; `2>/dev/null` plus
the export's masked exit code mean a Keychain miss can never abort the
sub-200 ms close path. Rotate the token later with the same
`security add-generic-password -U …` command, and revert to API-key mode by
removing the two subscription lines from `capture.env`.

> The Keychain route is `capture.env`-only, so it does **not** apply to plugin
> installs — the plugin never reads `capture.env`. Set `oauth_token` in the
> plugin's config (keychain-backed) or use the token file.

**Verify it worked:** after your next session ends, `tail ~/.claude/hooks.log`
should show a normal capture with no `CLAUDE_CODE_OAUTH_TOKEN not set` line, and
the new `eval/state/log.md` entry will carry an *estimated* `cost_usd`.

**Trade-offs:** background captures draw from the *same* rolling rate limit as
your interactive Claude Code usage; the `claude` CLI must be installed; and
`cost_usd` in the eval log becomes an *estimated* API-equivalent (not billed).
Token counts still come from the SDK's result message. `max_tokens` has no
equivalent in this mode — output length is governed by the runtime.

## Consuming captures: the Inbox contract

This project is a capture *engine*. Triaging captured artifacts into structured
vault folders (promoting, backlinking, weekly rollups) is intentionally **out of
scope** — it's left to separate extensions that build on the stable, documented
interface below. Keeping triage in an external extension means it can be wired to
your own skills and vault layout without coupling them to the capture engine.

An extension consumes:

**Outputs** (the captured artifacts) in your vault:
- `Inbox/auto/` — curated artifacts. (`Inbox/raw/` was retired with Path B and is
  no longer written; extensions must tolerate its absence.)
- Filenames: `YYYY-MM-DD-<slug>-<sid8>.md`. Frontmatter includes `session_id`,
  `created` (date), `source`, `type`, and `tags`.

**Read-only runtime state** — in the repo's gitignored `eval/state/` for standalone
installs, or the plugin's own data directory for plugin installs:
- `session-index.tsv` — `<session_id>\t<path_a_or_null>\t<date>` (schema_version 2).
- `log.md` — per-session JSON-lines (skip reasons, costs, token counts).
- `scrub-failures.md` — dated lines when a scrub rule failed.

Extensions **read** these; they should never write into the state directory (keep their own
state elsewhere). To stop the pipeline from archiving an extension's own workflow
sessions, set **`CAPTURE_EXCLUDED_COMMANDS`** (comma-separated slash commands) —
empty by default, so the public pipeline captures everything.

The `/vault-save` skill (on-demand export of a Claude-generated document to your
vault's `claude-docs/`) is always installed.

## Design history

Capture is a single curated path (`_call_path_a` in `hooks/curate.py`). It began
as a two-path A/B eval — curated Sonnet vs a raw Haiku baseline written to
`Inbox/raw/`. The raw path was **retired 2026-06-04** after the eval showed it
didn't earn its keep: it was almost never the version kept, and its unique
catches were mostly out-of-scope. See
[`eval/experiments/FINDINGS.md`](eval/experiments/FINDINGS.md) for the evidence.

Per-session costs and skip reasons land in the state log (gitignored JSON-lines):

```bash
jq -r '[.date, .skip_reason_a, .cost_usd_a] | @tsv' eval/state/log.md
```

The original design spec is kept as a historical record at
[`dev-notes/archive/2026-04-original-eval-spec.md`](dev-notes/archive/2026-04-original-eval-spec.md).
It describes the retired two-path system and is **not** a guide to current
behaviour — read `CLAUDE.md` for that.

## Project structure

```
hooks/
  session-end-capture.sh   # entry point — self-locating, returns in <200ms
  curate.py                # full pipeline (scrub → filter → API → write → log)
  scrub.py / scrub_rules.py # secret scrubber (no network, pure stdlib)
prompts/
  curation-system-prompt.md  # the curation prompt — may return null (resampled once)
skill-patches/             # /vault-save skill + its global auto-trigger
eval/
  fixtures/                # test transcripts and mock API responses
  state/                   # runtime-only (gitignored): log.md, session-index.tsv
dev-notes/                 # historical design notes (not user docs)
CLAUDE.md                  # current architecture + invariants
```

## License

[MIT](LICENSE) © Loïc Houpert
