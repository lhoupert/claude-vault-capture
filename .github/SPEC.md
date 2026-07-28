# SPEC — Claude Code → Obsidian Vault Capture (Eval)

Status: draft · Owner: loic · Eval window: 4 weeks from first working hook

> **Amendment 2026-06-04 — Path B retired.** The eval concluded: the raw Haiku
> baseline (Path B → `Inbox/raw/`) was almost never the version kept and its
> unique catches were mostly out-of-scope, so it was removed. Capture is now a
> single curated path (Path A → `Inbox/auto/`) that retries once on a
> non-deterministic null. The two-path design described below is **historical**;
> where this spec mentions Path B, `Inbox/raw/`, `claude-haiku-4-5-20251001`,
> per-path failure isolation, or `*_b` log fields, read it as superseded. The
> log/index schema is now **version 2** (no `*_b` fields). See
> `eval/experiments/FINDINGS.md` for the evidence and
> `claude-docs/2026-06-04-dual-pipeline-capture-keep-path-a-retire-path-b.md`
> for the decision record.

> **Note on paths.** This spec predates the portability work and shows the
> author's absolute paths (`~/Obsidian/loics_vault`, `~/DevDS/claude-vault-capture`).
> The shipped code does not hardcode these: the repo root is derived from each
> file's location, and the vault is configured via `CAPTURE_VAULT_DIR`. See the
> top-level `README.md` for current install and configuration.

## 1. Objective

Evaluate two complementary capture paths from Claude Code sessions into the Obsidian vault at `~/Obsidian/loics_vault/`, running **in parallel** for ~4 weeks. At the end of the window, pick a long-term approach based on kept-rate and subjective usefulness. Both paths fire automatically on `SessionEnd` — no manual triggering.

- **Path A — curated (approach 2):** A `SessionEnd` hook pipes each session's transcript to `claude-sonnet-4-6` with an extraction prompt. The model returns a durable artifact — a decision, runbook, spec, or non-obvious gotcha — or `null`. Non-null outputs land in `Inbox/auto/`.
- **Path B — raw baseline (approach 3):** The same hook also pipes the transcript to `claude-haiku-4-5-20251001` with a lighter prompt that always returns a file: a topic line, a bullet summary of what happened, and source links. Outputs land in `Inbox/raw/`.

Both paths share the **Inbox pattern**: every capture goes to `Inbox/`, never directly into structured folders (`notes_daily/`, `notes_weekly/`, `work/`, etc). Triage out of `Inbox/` is performed by external extensions that consume the Inbox contract (see §2.3) — not by this repo.

### Glossary

- **`<sid8>`** — first 8 chars of the session UUID; appended to Inbox filenames to disambiguate same-day same-title collisions.
- **user turn** — one message with role `user` in the transcript JSONL; counted against the small-signal threshold.
- **user content** — concatenated text of all user turns; its char count is compared against the threshold.
- **kept rate** — fraction of Inbox captures promoted into a structured vault folder during triage.
- **miss rate** — fraction of Path B promotions where `eval/state/session-index.tsv` shows `path_a` was `null` (no curated sibling was ever written) for that `session_id`. False-negative signal for the curation prompt.
- **no-capture session** — a session where neither path wrote a file for a reason *other than* the small-signal threshold or the excluded-command filter (i.e. an error, timeout, or token-limit skip). Drives the 25% crash alarm in §2.3.

### Why run both

The raw baseline makes the curation prompt's quality *visible*. Without it, you only see what Path A let through; you never see what it dropped. After 4 weeks the comparison answers one question: **is the filter doing useful work, or is capture-everything just as useful?**

### Success criteria for the eval

After 4 weeks, the following data drives the decision:
- Captures per path (count).
- **Kept rate** — fraction promoted out of `Inbox/` into a structured vault folder.
- **Discard rate** — fraction deleted during sweep.
- **Miss rate** — measured against `eval/state/session-index.tsv`, not the vault. The index is the canonical record of what Path A wrote. Vault state drifts as the user deletes or moves curated artifacts during triage, so a vault scan would conflate "Path A never produced an artifact" with "Path A produced one the user later deleted." The eval is evaluating the *filter*, so we want the former.
- API cost per session, tracked in `eval/state/log.md`.
- Subjective: which folder produced artifacts the user actually wanted to keep.

Decision rules of thumb:
- If Path A kept-rate ≥ Path B kept-rate AND miss rate is low → keep only Path A, drop the raw baseline.
- If miss rate is high → Path A prompt is too strict; iterate or fall back to Path B only.
- If both have low kept-rate → the whole approach is off; rethink.

## 2. Triggers

### 2.1 `SessionEnd` hook — pipeline

- Claude Code fires `SessionEnd` at session close with session info (including transcript path) on stdin.
- `~/DevDS/claude-vault-capture/hooks/session-end-capture.sh` is the entry point. It returns in under 200ms — **all model work runs in a backgrounded `curate.py` process**, so session close is never blocked. The shell script:
  1. Reads the hook JSON from stdin and extracts: `.transcript_path` (absolute path to the JSONL transcript), `.session_id` (UUID string), `.cwd` (session working directory at close).
  2. Appends `SESSION_END_RECEIVED\t<session_id>\t<ISO-8601 timestamp>` to `~/.claude/hooks.log` *before* backgrounding — this marker is the ground truth for "a session-end fired" and is what the 25% crash alarm (§2.3) counts against `log.md` entries. Without it, a `curate.py` that dies before its first log write is invisible.
  3. Spawns `curate.py` detached (`nohup … &`), redirecting stdout/stderr to `~/.claude/hooks.log`. Returns 0 immediately. All args are double-quoted to prevent word-splitting on paths containing spaces or shell metacharacters. Concrete spawn line:
     ```bash
     nohup "$HOME/DevDS/claude-vault-capture/hooks/curate.py" \
       "$TRANSCRIPT_PATH" "$SESSION_ID" "$CWD" \
       >>"$HOME/.claude/hooks.log" 2>&1 &
     ```
     All semantic checks (threshold, dedup) run inside `curate.py` — nothing that requires reading or parsing the transcript happens in the shell script.
- `hooks/curate.py`, running detached, then:
  1. Loads the transcript and runs `hooks/scrub.py` on it (see §7 — Secret scrubbing). The **scrubbed** transcript is what gets sent to the models; the original is never copied or persisted by this tool.
  2. Checks whether any user turn invokes an excluded slash command. The exclusion list comes from `CAPTURE_EXCLUDED_COMMANDS` (comma-separated env var, sourced from `capture.env`) and is **empty by default** — the public pipeline captures everything. An Inbox-triage extension (see §2.3) sets it to its own workflow commands so capturing the triage sessions themselves stays non-circular. Match is line-anchored (pattern: `^\s*<cmd>(\s|$)`) so mentions of the command in prose are not false-positives. If found, records `skip_reason_a = skip_reason_b = "excluded_command"` in the log entry and exits 0.
  3. Checks if the transcript is below the small-signal threshold (< 3 user turns OR < 1500 chars of user content). If so, records `skip_reason_a = skip_reason_b = "threshold"` in the log entry and exits 0. JSONL parsing runs here, in Python — not in the shell script.
  4. Estimates input token count as `len(scrubbed_transcript) // 4` (char-count proxy, not a real tokenizer). If this exceeds `CAPTURE_MAX_EST_TOKENS` (default: 50 000, configurable via env var), records `skip_reason_a = skip_reason_b = "token_limit"` and exits 0. At ~4 chars/token, 50 000 tokens ≈ 200 KB of transcript, corresponding to ~$0.15 input cost on Sonnet. Name prefix `EST_` signals this is a character-based estimate, not a real tokenizer count.
  5. Checks `eval/state/session-index.tsv` for the session_id. If found, exits 0 without writing — idempotent re-run protection that holds even after a capture has been promoted out of Inbox. If the index file is absent, writes unconditionally — accepting a potential duplicate on manual index deletion in exchange for eliminating a vault-wide file scan.
  6. Invokes both model calls **in parallel** via `concurrent.futures.ThreadPoolExecutor(max_workers=2)`:
     - `claude-sonnet-4-6` with `prompts/curation-system-prompt.md` → may return JSON artifact or `null`. `max_tokens = 2000` (covers a runbook or long decision without allowing an unbounded generation — paired with the prompt cap, not a substitute for it).
     - `claude-haiku-4-5-20251001` with `prompts/raw-baseline-prompt.md` → always returns JSON summary. `max_tokens = 800` (matches the ~60-line body target in §4).
     Both values are the SDK `max_tokens` *output* ceiling. They bound the cost surface the `CAPTURE_MAX_EST_TOKENS` *input* ceiling cannot reach. If either limit is increased later, update the frontmatter `cost_usd` calibration note in §8.
     After receiving each model response, any wrapping markdown code fences (` ```json…``` ` or ` ```…``` `) are stripped before JSON parsing — models sometimes mirror the example format in the prompt despite instructions not to. If JSON still fails to parse after fence-stripping, that path records `skip_reason_*: "malformed_json"` and continues; the other path is unaffected.
     If `CAPTURE_MOCK_SDK=1` is set, loads canned responses from `eval/fixtures/mock-responses.json` instead of calling the API.
  7. Runs `scrub.py` again on each model output (defense-in-depth — models fed scrubbed input shouldn't re-emit secrets, but re-scrubbing is cheap insurance).
  8. **Sanitizes the model-provided `title`** before using it in filenames, frontmatter, or wikilinks: strip `|`, `]]`, `[[`, `#`, backticks, control chars, and leading/trailing whitespace; collapse internal whitespace; truncate to 120 chars. Rationale: the title is model-generated (untrusted input at this boundary) and flows into `[[stem|title]]` wikilinks in devlog/recap notes (§2.3); an unsanitized title would corrupt those notes.
  9. Derives `<slug>` deterministically from the sanitized title: NFKD-normalize and strip non-ASCII; lowercase; replace every run of non-`[a-z0-9]+` chars with a single `-`; strip leading/trailing `-`; truncate to 60 chars (at a `-` boundary if possible). If the result is empty (title was all punctuation), fall back to `untitled`. Path A and Path B each derive their slug from their own model-provided title — slugs are not shared across paths.
  10. Writes non-null Path A output to `Inbox/auto/YYYY-MM-DD-<slug>-<sid8>.md`, where `<sid8>` is the first 8 chars of the session id (disambiguates same-day same-title collisions).
  11. Writes Path B output to `Inbox/raw/YYYY-MM-DD-<slug>-<sid8>.md`.
  12. Appends one line to `eval/state/session-index.tsv`: `<session_id>\t<path_a_or_null>\t<path_b_or_null>\t<YYYY-MM-DD>`. This is the fast lookup used by dedup and miss-rate checks — no vault walk required after the index exists. The file starts with a single `# schema_version: 1` comment line (skipped by the dedup scan) on first creation.
  13. Appends one record to `eval/state/log.md` (schema in §2.2).
- Per-call timeout: 30s per model call (not a session-close blocker since we're async). On timeout or error, set that path's `skip_reason_*` to `"timeout"` or `"error:<type>"`, skip that path, and continue — per-path failure isolation means the other path still writes.
- Errors log to `~/.claude/hooks.log`; nothing is ever printed to the user's terminal.

### 2.2 `eval/state/log.md` schema

One JSON object per line, appended by `curate.py` after each run. JSON-lines is append-safe and `jq`-able; weekly aggregation (into the triage extension's own `metrics.md`) is done manually or via `jq` — do not invent a custom parser.

**Fields:**

| Field | Type | Values |
|---|---|---|
| `schema_version` | int | Currently `1`. Bumped on any breaking field change (rename, removal, or type change). Additive changes keep version stable; readers MUST ignore unknown keys. |
| `timestamp` | string | ISO-8601 UTC, e.g. `2026-04-23T14:32:11Z`. Pairs with `hooks.log` entries for debugging — `date` alone is too coarse. |
| `date` | string | `YYYY-MM-DD` — kept alongside `timestamp` because weekly aggregation groups by date and `jq` bucket math is simpler with a pre-formatted key. |
| `session_id` | string | session UUID |
| `path_a` | string \| `null` | Inbox path, or `null` if Path A wrote nothing |
| `path_b` | string \| `null` | Inbox path, or `null` if Path B wrote nothing |
| `skip_reason_a` | string \| `null` | `null` when `path_a` is a path. Otherwise one of: `"model_returned_null"`, `"excluded_command"`, `"threshold"`, `"token_limit"`, `"timeout"`, `"malformed_json"`, `"error:<type>"` |
| `skip_reason_b` | string \| `null` | `null` when `path_b` is a path. Otherwise one of: `"excluded_command"`, `"threshold"`, `"token_limit"`, `"timeout"`, `"malformed_json"`, `"error:<type>"` |
| `tokens_in_a`, `tokens_in_b` | int \| `null` | `null` if the API was not called for that path (threshold / token_limit / error-before-call) |
| `tokens_out_a`, `tokens_out_b` | int \| `null` | same |
| `cost_usd_a`, `cost_usd_b` | float \| `null` | same |
| `redactions` | object | per-rule hit counts — same keys as frontmatter |

**Invariant:** for each path, exactly one of `path_*` / `skip_reason_*` is non-null. `path_a: null, skip_reason_a: null` must never appear.

**Happy path — both paths wrote:**
```json
{"schema_version":1,"timestamp":"2026-04-23T14:32:11Z","date":"2026-04-23","session_id":"…","path_a":"Inbox/auto/2026-04-23-foo-abc12345.md","path_b":"Inbox/raw/2026-04-23-foo-abc12345.md","skip_reason_a":null,"skip_reason_b":null,"tokens_in_a":1234,"tokens_out_a":456,"tokens_in_b":1234,"tokens_out_b":123,"cost_usd_a":0.0234,"cost_usd_b":0.0008,"redactions":{"env_var":0,"jwt":0,"private_key":0,"token_prefix":0,"basic_auth_url":0,"bearer":0}}
```

**Threshold skip — neither path ran:**
```json
{"schema_version":1,"timestamp":"…","date":"…","session_id":"…","path_a":null,"path_b":null,"skip_reason_a":"threshold","skip_reason_b":"threshold","tokens_in_a":null,"tokens_out_a":null,"tokens_in_b":null,"tokens_out_b":null,"cost_usd_a":null,"cost_usd_b":null,"redactions":{…}}
```

**Path A returned null, Path B wrote:**
```json
{"schema_version":1,"timestamp":"…","date":"…","path_a":null,"path_b":"Inbox/raw/….md","skip_reason_a":"model_returned_null","skip_reason_b":null,"tokens_in_a":1234,"tokens_out_a":5,"tokens_in_b":1234,"tokens_out_b":123,…}
```

**Path B malformed JSON, Path A wrote:**
```json
{"schema_version":1,"timestamp":"…","date":"…","path_a":"Inbox/auto/….md","path_b":null,"skip_reason_a":null,"skip_reason_b":"malformed_json","tokens_in_a":1234,"tokens_out_a":456,"tokens_in_b":1234,"tokens_out_b":0,"cost_usd_a":0.0234,"cost_usd_b":0.0002,…}
```

**No-capture session definition** (drives the 25% alarm in §2.3): `path_a IS null AND path_b IS null AND skip_reason_a NOT IN ("threshold", "excluded_command")`. Threshold and excluded-command skips are excluded from *both* the numerator and the denominator of the alarm ratio — they are expected behaviour, not failure.

### 2.3 Skill integrations

#### Inbox triage — handled by an external extension

Triaging captured artifacts out of `Inbox/` (same-day surfacing, weekly sweep,
promotion with backlinks, miss-rate tracking, the 25% crash alarm, and the
`metrics.md` rollup) is **out of scope for this repo.** It is implemented by a
separate, user-owned extension that patches whatever workflow skills the user runs
and consumes this project's **Inbox contract**:

- **Reads (read-only):** `Inbox/{auto,raw}/*.md` (artifacts + frontmatter) and the
  gitignored runtime state `eval/state/{session-index.tsv,log.md,scrub-failures.md}`.
- **Writes:** backlinks in the user's vault notes and the extension's *own* state
  (never this repo's `eval/state/`).
- **Config:** sets `CAPTURE_EXCLUDED_COMMANDS` in `capture.env` so the pipeline does
  not capture the triage sessions themselves (kept non-circular).

The public installer does **not** patch any workflow skills. Only the `/vault-save`
skill below is shipped here.

#### `/vault-save` — on-demand document export

A standalone skill (`~/.claude/skills/vault-save/SKILL.md`) that saves a Claude-generated markdown document to `Inbox/auto/` with structured frontmatter. Unlike the `SessionEnd` pipeline, it:
- Fires **on explicit user intent**, not automatically — either via `/vault-save` or when natural language signals export intent (e.g. "save this to my vault", "export this spec").
- Requires **no model API call** — the document already exists in the conversation; Claude writes the file directly using the Write tool.
- Writes to `Inbox/auto/` with `source: claude-code-export` in frontmatter (distinguishable from `source: claude-code-curated`).
- Follows the same title sanitization and slug generation rules as `curate.py` (`_sanitize_title`, `_make_slug`).
- Does **not** use the secret scrubber — the user is explicitly choosing what to save and has full visibility into the content.

**Frontmatter schema** (subset of the session-capture schema — `session_id`, `cost_usd`, and `redactions` are omitted as they are pipeline-specific):
```yaml
---
title: <sanitized>
type: spec | plan | adr | runbook | issue | note | document
project: <git basename or 'home'>
tags: [claude-code, <project>, <topic-tags>]
source: claude-code-export
created: YYYY-MM-DD
model: <model-id>
---
```

**Filename convention:** `YYYY-MM-DD-<slug>.md` (no `<sid8>` suffix). If the path already exists, Claude appends `-2`, `-3`, etc.

**Auto-trigger:** `install.sh` injects a marker-bounded block into `~/.claude/CLAUDE.md` (global) that instructs Claude to invoke `/vault-save` when the user asks to save/export a document. This does not require a hook — it is a global instruction read by Claude at session start.

**Install integration:** `install.sh` steps 5b and 5c create the skill file and inject the global CLAUDE.md trigger using the same idempotent marker-bounded approach as the existing skill patches. Canonical content lives in:
- `skill-patches/vault-save.md` → copied to `~/.claude/skills/vault-save/SKILL.md`
- `skill-patches/global-claude-md.vault-save-trigger.md` → injected into `~/.claude/CLAUDE.md`

**Interaction with the triage extension:** because exported documents land in `Inbox/auto/`, an Inbox-triage extension (§2.3) picks them up alongside session-captured artifacts. The `source: claude-code-export` field lets the user distinguish manually-exported docs from auto-captured ones during triage.

> The detailed step-9.5 (daily) and step-8 (weekly) triage flows, the miss-rate
> check, the `metrics.md` rollup, and the **25% crash alarm** previously specified
> here now live in the external triage extension. The public pipeline still emits
> everything those flows depend on — `eval/state/{log.md,session-index.tsv,scrub-failures.md}`
> and the `no_capture_session` definition above — as a stable read-only contract.

## 3. Project structure

```
~/DevDS/claude-vault-capture/
  SPEC.md                              # this file
  README.md                            # how to install / update (kept brief)
  install.sh                           # idempotent installer (see below)
  hooks/
    session-end-capture.sh             # entry point, stdin-driven, backgrounds curate.py
    curate.py                          # Anthropic SDK, runs both model calls in parallel
    scrub.py                           # regex-based secret scrubber (§7); pure, stdlib-only
    scrub_rules.py                     # pattern/replacement definitions used by scrub.py
  prompts/
    curation-system-prompt.md          # Path A — strict extraction, may return null
    raw-baseline-prompt.md             # Path B — always summarizes, no judgment
  skill-patches/
    vault-save.md                      # /vault-save skill — copied to ~/.claude/skills/vault-save/SKILL.md
    global-claude-md.vault-save-trigger.md  # auto-trigger instructions — injected into ~/.claude/CLAUDE.md
                                       # (workflow-skill triage patches live in the external extension)
  eval/
    .gitignore                         # ignores state/ (runtime-generated)
    fixtures/                          # checked-in test input
      debugging-only.txt               # A → null  |  B → brief summary
      adr-worthy.txt                   # A → decision  |  B → summary
      runbook-worthy.txt               # A → runbook   |  B → summary
      mixed.txt                        # judgment call — document expected
      with-secrets.txt                 # planted fake secrets; scrubber must redact all
      malformed-title.txt              # title with `|`, `]]`, `#` — sanitizer must clean it
      mock-responses.json              # canned API responses (CAPTURE_MOCK_SDK=1). Keys: one per fixture file above,
                                       # plus "malformed_haiku" (non-JSON path_b — exercises malformed_json skip) and
                                       # "malformed_title" (title with | and ]] in path_a — exercises sanitization).
      expected/                        # golden structural outputs for live regression runs
    state/                             # RUNTIME — gitignored; created on first install
      log.md                           # per-session append log (JSON-lines, see §2.2)
      session-index.tsv                # session_id → path_a, path_b, date (fast dedup lookup)
      start-date.txt                   # written by install.sh on first run; eval window anchor
      scrub-failures.md                # persistent log of scrub rule compile/match failures (§7)
    run-fixtures.sh                    # runs each fixture through curate.py (CAPTURE_MOCK_SDK=1 by default)
    run-install-smoke.sh               # install.sh smoke test against tmp dirs (no live ~/.claude writes)
  tests/
    test_scrub.py                      # unit — scrubber rules + idempotency + MULTILINE + malformed-rule skip
    test_frontmatter.py                # unit — frontmatter + filename (slug + sid8) + title sanitization
    test_dedup.py                      # unit — session_id lookup; absent-index write-through
    test_append_log.py                 # unit — concurrent append_log() correctness (fcntl.flock)
    test_threshold.py                  # unit — threshold OR logic (turns and chars clauses independently)
    test_guards.py                     # unit — project derivation from cwd, token-count ceiling
    test_log_schema.py                 # unit — each skip_reason variant produces a schema-valid JSON line
    test_failure_isolation.py          # unit — Path A exception does not prevent Path B write, and vice versa

~/.claude/
  settings.json                        # SessionEnd hook registration (added by install.sh)
  CLAUDE.md                            # vault-save auto-trigger injected by install.sh (marker-bounded)
  skills/vault-save/SKILL.md           # created by install.sh (copied from skill-patches/vault-save.md)
  skills/<workflow-skill>/SKILL.md     # amended by the external triage extension, not this installer
  hooks.log                            # errors and redaction logs land here

~/Obsidian/loics_vault/
  .gitignore                           # install.sh adds Inbox/raw/ if vault is a git repo
  Inbox/
    auto/                              # Path A (curated) lands here
    raw/                               # Path B (raw baseline) lands here
```

**Runtime state separation.** Everything under `eval/state/` is generated at runtime by `curate.py` (an external triage extension reads these files but writes its own state elsewhere). `eval/.gitignore` excludes `state/` — the directory is created on first install but never committed. Fixtures (`eval/fixtures/`) are checked-in test input; scripts at the `eval/` root are checked-in code. This boundary matters: a `git clean -fdx` or fresh clone should lose nothing irreplaceable from `state/` except the eval window anchor (which can be reset) and the running session-index (which can be rebuilt from vault frontmatter if needed).

**Install strategy.** `install.sh` is idempotent. The `/vault-save` skill is written using marker-bounded blocks in the target `SKILL.md`:

```
<!-- BEGIN claude-vault-capture: vault-save -->
… canonical content from skill-patches/vault-save.md …
<!-- END claude-vault-capture: vault-save -->
```

First install writes the file; subsequent installs replace only the content between the markers — edits the user made outside the markers are preserved. (The external triage extension uses the same marker-bounded mechanism to amend the user's own workflow skills.) `settings.json` hook registration is merged, not overwritten (installer parses, appends the entry if missing, writes back).

**Hook JSON shape and idempotency key.** The exact entry appended to `hooks.SessionEnd` in `~/.claude/settings.json`:

```json
{
  "matcher": "",
  "hooks": [
    {
      "type": "command",
      "command": "$HOME/DevDS/claude-vault-capture/hooks/session-end-capture.sh"
    }
  ]
}
```

The **command path** is the idempotency key: `install.sh` matches on the inner `command` value and replaces the whole entry if found, appends it if not. This means a user can re-run install after moving the repo — the old entry (different path) is removed and the new one is appended. `run-install-smoke.sh` (§6) covers this by running `install.sh` twice with a modified path between runs and asserting exactly one entry remains.

**Safety.** Before modifying `~/.claude/settings.json` or any SKILL.md, `install.sh`:
1. Copies the target file to `<file>.bak` in the same directory.
2. Makes the modification.
3. Validates `settings.json` with `python3 -m json.tool ~/.claude/settings.json >/dev/null`. If validation fails, restores from `.bak` and exits 1 with a clear error message.

The `.bak` files are not cleaned up automatically. Each `install.sh` run **overwrites** its corresponding `.bak` with a fresh pre-modification copy, so a trailing `.bak` always represents the last-known-good state before the most recent install — not a historical accumulation. Two consequences: (a) running `install.sh` effectively rolls the backup forward, so there's no build-up of stale files; (b) if a run corrupts the target and you need to revert, do it *before* re-running the installer, or you'll overwrite the good backup with the corrupted file. Delete `.bak` only after confirming the live file works.

**Directory creation.** `install.sh` creates required directories if absent:
```bash
mkdir -p ~/Obsidian/loics_vault/Inbox/{auto,raw}
mkdir -p ~/DevDS/claude-vault-capture/eval/fixtures/expected
mkdir -p ~/DevDS/claude-vault-capture/eval/state
```
This runs before any file modifications so write targets exist on the first real session.

**Eval window anchor.** On first successful install, `install.sh` writes today's date to `eval/state/start-date.txt` (`date +%Y-%m-%d > eval/state/start-date.txt`). Subsequent installs skip this if the file already exists. The week-4 checklist refers to this date.

## 4. Output format

### Shared frontmatter

```markdown
---
title: <short human title, sanitized — no | ]] [[ # ` or control chars>
type: <see below>
project: <derived-by-curate.py>
tags: [claude-code, <source>, <topic-tags>]
source: claude-code-curated | claude-code-raw
session_id: <claude-code session uuid>
created: YYYY-MM-DD
model: claude-sonnet-4-6 | claude-haiku-4-5-20251001
cost_usd: 0.0123
redactions: {env_var: 0, jwt: 0, private_key: 0, token_prefix: 0, basic_auth_url: 0, bearer: 0}
---
```

- `title` is sanitized per §2.1 step 7 before being written. Guarantees `[[stem|title]]` wikilinks in devlog/recap notes stay well-formed.
- `project` is derived **deterministically** by `curate.py` from the session's `cwd`: nearest git repo root's basename, or `home` if outside a repo. Not model-guessed — same repo always yields the same project tag across both paths, so downstream filtering stays consistent. Known limitation: if the session cwd is inside a git submodule, `curate.py` uses the submodule's root basename, not the parent repo name. Not handled in v0 — add if it causes incorrect project tags in week-1 review.
- Topic tags are generated by the model from artifact/summary content.
- `redactions` counts each scrubber rule's hits for this capture. Zero is normal; non-zero means the scrubber saved you from writing a secret to disk.

### Path A — `Inbox/auto/` (curated)
- `type` ∈ {`decision`, `runbook`, `gotcha`, `spec`, `devlog-snippet`}. **No `generic` fallback** — if the session didn't produce one of these, Path A returns `null` and no file is written. This keeps the kept-rate signal clean during the eval. Adding or removing a `type` value is a breaking change — update the spec, the curation prompt, and at least one eval fixture together in a single commit.
- Body is a **distilled artifact** — the runbook itself, the decision itself — not a transcript recap.
- Body structure:
  ```
  # <title>
  <artifact body>
  ## Source
  - <PR/issue/repo links>
  ## Referenced in
  *(populated by skill on promotion; section omitted until first promotion)*
  ```
- `curate.py` does not write `## Referenced in` — the section is created and maintained exclusively by the skill patches on user-approved promotion. An artifact promoted in both a devlog and a weekly sweep accumulates both backlinks as separate bullets.
- No back-and-forth. The output is the artifact.

### Path B — `Inbox/raw/` (baseline)
- `type` is always `session-summary`.
- Body follows a fixed template:
  ```
  # <topic>

  ## What happened
  - <5–10 bullets, factual, what was worked on / decided / tried>

  ## Outputs
  - <files changed, PRs opened, commands run that mattered>

  ## Source
  - <PR/issue/repo links>

  ## Referenced in
  *(populated by skill on promotion; section omitted until first promotion)*
  ```
- No filtering — if the session did anything meaningful it gets summarized. Cheap and consistent. Path B always returns structured JSON by prompt design. Before parsing, any wrapping markdown code fences are stripped (models sometimes mirror the example format in the prompt). If the response still cannot be parsed as JSON, `curate.py` records `skip_reason_b: "malformed_json"` and continues — same failure-isolation treatment as a Path A error. This alone does not count toward the no-capture alarm unless `skip_reason_a` is also non-threshold/non-excluded-command (per §2.2 no-capture definition).
- Keep body under ~60 lines. Haiku should be terse.

## 5. Code style

- Shell: bash with `set -euo pipefail`. All paths resolved from `$HOME`, no hardcoded `/Users/lhoupert`.
- Python (`curate.py`): single file, stdlib + `anthropic` SDK only. No classes unless state demands it. Read args → scrub transcript → excluded-command check → threshold check → token-count guard (`CAPTURE_MAX_EST_TOKENS`) → check session-index (dedup) → two parallel API calls via `concurrent.futures.ThreadPoolExecutor(max_workers=2)` → strip code fences → parse JSON → scrub outputs → sanitize title → write up to two files → append index + log → exit 0. Errors go to stderr and `~/.claude/hooks.log`, never to Claude Code's UI.
- Python (`scrub.py`): pure, stdlib only (`re`, `pathlib`). No network, no SDK, no subprocess. Exports one function: `scrub(text: str) -> tuple[str, dict[str, int]]` returning `(redacted_text, counts_by_rule)`. Pure functions are trivially unit-testable and safe to reuse.
- Prompt files are plain markdown with a short preamble and instructions. Version-controlled — every prompt change is a commit, so regressions are diffable.
- Frontmatter written with PyYAML or simple string templating (no custom markdown libs).
- No silent fallbacks: if a model returns malformed JSON, log the raw output and skip that path (the other path still runs). Better to miss one capture than corrupt Inbox.
- **Per-path failure isolation:** a Path A error must not prevent Path B from writing, and vice versa.
- **Concurrency model for appends.** `append_log()` protects `eval/state/log.md`, `eval/state/session-index.tsv`, `eval/state/scrub-failures.md`, and `~/.claude/hooks.log`. Two layers:
  1. **Cross-process:** `fcntl.flock(f, fcntl.LOCK_EX)` inside `append_log()`, re-opening the file per call so each call has a distinct open-file-description. This is the meaningful protection — two `curate.py` processes can run simultaneously when two sessions close at once.
  2. **In-process:** a module-level `threading.Lock` wraps the `fcntl.flock` call as defense-in-depth. By design all file appends happen in the main thread *after* `ThreadPoolExecutor.shutdown()` joins the two API calls, so thread contention is structurally impossible today — but the threading.Lock guards against future refactors that log from inside a worker. Cheap insurance.

  `fcntl` is stdlib on macOS/Linux. Both locks are held only for the duration of the write. `test_append_log.py` exercises the cross-process case with two subprocesses.

## 6. Testing strategy

- **Unit tests (`tests/`, `pytest`, no network):** cover the deterministic core — must pass before any commit.
  - `test_scrub.py` — every rule redacts its target pattern against the planted fixtures; idempotency (`scrub(scrub(x)) == scrub(x)`); non-secret text is untouched; **MULTILINE coverage:** a fixture with a `.env` assignment on line 50 must redact (proves `re.MULTILINE` is on — without it, only the first line would match); **cross-line key block:** a fixture with a complete multi-line `-----BEGIN ... PRIVATE KEY-----` block must fully redact (proves `[\s\S]` spans newlines without depending on `re.DOTALL`); **Bearer token** shapes (`Authorization: Bearer …`, `bearer xyz`, `-H 'Authorization: Bearer …'`); **malformed-rule skip:** inject a bad regex into the rule list, assert scrub returns the original text, a `scrub-failures.md` entry is appended, and no exception propagates.
  - `test_frontmatter.py` — frontmatter fields render in stable order; filenames follow `YYYY-MM-DD-<slug>-<sid8>.md`; slug generation is deterministic; **title sanitization:** titles containing `|`, `]]`, `[[`, `#`, backticks, newlines, control chars, and >120 chars are cleaned before being written to frontmatter, filenames, or wikilinks.
  - `test_dedup.py` — session_id lookup hits `eval/state/session-index.tsv` and returns correct result; when index is absent, write proceeds unconditionally and a normal log entry is emitted (dedup absence is informational, not a skip); confirms idempotency on re-run when index exists.
  - `test_append_log.py` — concurrent correctness: spawn two **subprocesses** (via `subprocess.Popen`, not threads) both calling `append_log()` against the same tmp file; assert the result contains exactly two valid JSON lines with no interleaving. Subprocesses verify the cross-process case that a `threading.Lock` alone would miss.
  - `test_threshold.py` — four cases against the `< 3 user turns OR < 1500 chars` check: (a) low turns, normal chars → skip; (b) normal turns, low chars → skip; (c) both low → skip; (d) both above threshold → passes. Verifies the OR: either clause alone is sufficient. Parse the resulting log entry to confirm `skip_reason_a == skip_reason_b == "threshold"` and both `path_*` are `null`.
  - `test_guards.py` — *project derivation*: create a `tmp_path` with `git init`; assert `cwd=<repo>` → project equals repo basename; assert `cwd=<tmp no-git>` → project is `"home"`. Submodule behaviour is documented as a known limitation in §4 and deferred — no unit test for that case (setting up a submodule in tmpdir is heavy-weight and out of scope for v0; revisit if misclassification appears in week-1 review). *Token guard*: pass a string of length `CAPTURE_MAX_EST_TOKENS * 4 + 1` chars; assert the log entry contains `skip_reason_a = skip_reason_b = "token_limit"` and no file is written.
  - `test_log_schema.py` — for each `skip_reason` variant (`excluded_command`, `threshold`, `token_limit`, `model_returned_null`, `timeout`, `malformed_json`, `error:*`) and the happy path, assert the emitted JSON line has the documented shape from §2.2: correct keys present, correct `null` vs value placement in paired fields, invariant holds (exactly one of `path_*` / `skip_reason_*` is non-null per path), `schema_version` and `timestamp` fields present.
  - `test_excluded_commands.py` — unit tests for `uses_excluded_command()`, driving the command list via the explicit parameter (the public default is empty): (a) a user turn starting with a configured command triggers exclusion; (b) prose mentioning the command mid-sentence does not trigger; (c) the **public default is empty**, so an excluded-command turn returns False under the default; (d) custom command lists are honored. The e2e `test_excluded_command` (in `test_pipeline_e2e.py`) patches `EXCLUDED_COMMANDS` and asserts a session with an excluded command produces a log entry with `skip_reason_a = skip_reason_b = "excluded_command"` and no files written.
  - `test_load_transcript.py` — unit tests for `_load_transcript()` and `_extract_text()`: (a) a JSONL line whose `content` is a plain string is returned as-is; (b) a line whose `content` is a list of `{"type": "text", "text": "…"}` blocks is flattened to a string; (c) mixed list types (text blocks and other block types) flatten without raising; (d) lines with `type` field (Claude Code JSONL format) are handled alongside lines with `role` field; (e) malformed JSON lines are silently skipped; (f) empty content is returned as empty string, not a list.
  - `test_failure_isolation.py` — exercises the §5 "per-path failure isolation" invariant as observable behaviour, not just schema shape. Two cases, both using `CAPTURE_MOCK_SDK=1` with a mock entry that raises: (a) Path A call raises `RuntimeError("boom")` → assert `Inbox/raw/…md` exists, `Inbox/auto/` is empty for this session, log row has `path_a: null, skip_reason_a: "error:RuntimeError", path_b: "Inbox/raw/…", skip_reason_b: null`; (b) symmetric case with Path B raising. Verifies that an exception in one ThreadPoolExecutor worker is caught at the future-result boundary and does not abort the other path's write or the log append.
- **Scrubber fixture (`fixtures/with-secrets.txt`):** synthetic transcript containing representative fake secrets — API key formats, `-----BEGIN … PRIVATE KEY-----` block, `.env`-style lines **placed mid-transcript to exercise MULTILINE**, URL basic auth, JWTs, `Authorization: Bearer …` headers. `test_scrub.py` asserts every planted secret is redacted.
- **Prompt regression (live, opt-in):** `eval/run-fixtures.sh` runs each fixture through `curate.py` against the real API. Gated on `CAPTURE_LIVE_TESTS=1` — default off, so CI and local test runs cost nothing. Golden structural outputs live in `fixtures/expected/<name>.json`; the diff compares structural fields (type, presence of source links, non-empty body), not exact prose. Prose judgment is a human review.
- **Hook smoke test (mocked SDK):** end-to-end script that fakes a `SessionEnd` stdin payload pointing at a fixture. Uses the shared mock mechanism: `CAPTURE_MOCK_SDK=1`. Verifies backgrounded process spawn, files landing under tmp Inbox dirs, and idempotency on re-run.
- **Install smoke test (`eval/run-install-smoke.sh`):** runs `install.sh` against a tmp directory tree with stub `settings.json` and `SKILL.md` files (pre-seeded with the expected anchor comments). Asserts: hook entry present in `settings.json`; marker blocks inserted in both SKILL.md stubs; `eval/state/start-date.txt` written; `Inbox/{auto,raw}` and `eval/state/` dirs created; `eval/.gitignore` contains `state/`; re-run is idempotent (second invocation produces identical output); vault-gitignore re-run does not duplicate `Inbox/raw/`. No writes to `~/.claude/`. Run this before any `install.sh` change and after confirming the install on a real machine.

**Mock mechanism (shared by smoke test and `run-fixtures.sh`):** `CAPTURE_MOCK_SDK=1` makes `curate.py` load `eval/fixtures/mock-responses.json` instead of calling the Anthropic API. The file maps fixture name → `{"path_a": <json-or-null>, "path_b": <json>}`. No monkeypatching required — `curate.py` checks the env var at startup and substitutes the canned responses. `run-fixtures.sh` sets `CAPTURE_MOCK_SDK=1` by default; unset it and set `CAPTURE_LIVE_TESTS=1` to run against the real API. Add a `"malformed_haiku"` key with a non-JSON string as `path_b` to exercise the malformed-JSON skip path; add a `"malformed_title"` key whose `path_a` contains `|` and `]]` in the title to exercise sanitization.

- **Eval instrumentation:** `eval/state/log.md` (and the triage extension's `metrics.md`) ARE the test of the system's usefulness. Review at weeks 1, 2, 4.
- **Link insertion (triage extension — verified there, not in this repo):** verify that on devlog promotion: (a) `## Captured Knowledge` is created in the devlog note if absent and a bullet is appended; (b) a second promotion of a different artifact appends a second bullet rather than overwriting; (c) `## Referenced in` is appended to the artifact at its `Inbox/` path; (d) an artifact whose original title contained `|` or `]]` produces a well-formed `[[stem|title]]` wikilink (i.e. sanitization upstream held). Verify that on recap promotion: (e) `## Referenced in` is written at the post-move path, not the pre-move `Inbox/` path; (f) an artifact with an existing devlog backlink accumulates the recap backlink as a second bullet without disturbing the first. Verify failure isolation: (g) if the devlog/recap note write fails, the artifact backlink write still proceeds, and the promotion itself still records as succeeded.

## 7. Boundaries

### Always
- Every capture lands in `~/Obsidian/loics_vault/Inbox/{auto,raw}/`.
- Every capture has complete frontmatter (title, type, project, tags, source, session_id, created, model, cost_usd, redactions).
- **Title is sanitized** before write (§2.1 step 7) — model-generated strings are untrusted input at this boundary.
- Source links included when the session referenced PRs, issues, or repo paths.
- Both paths run on every qualifying session — user takes no action.
- **Scrubber runs on every transcript before the LLM calls, and on every model output before writing to disk.** Redaction counts land in frontmatter and in `eval/state/log.md`.
- API cost tracked per session per path in `eval/state/log.md`.
- Anthropic API key sourced from `$ANTHROPIC_API_KEY`. If unset, `curate.py` logs and exits 0 without writing — never prompts, never blocks.

### Ask first
- Anything that writes outside `Inbox/` (promotion during sweep always prompts).
- Changes to either prompt that could materially shift signal (token usage > 2x, new artifact types).
- Changes to `scrub_rules.py` that loosen or remove patterns. Each rule change is a commit with a fixture update.
- Swapping models away from `claude-sonnet-4-6` (Path A) or `claude-haiku-4-5-20251001` (Path B).
- Enabling the hook on a new machine — only this machine's `~/.claude/settings.json` for now.
- Disabling one of the two paths before the 4-week window ends. Committing to the eval means seeing it through.

### Never
- Delete or modify existing vault files outside `Inbox/`, **except** for two append-only writes that happen only on explicit user-approved promotion: appending a bullet to `## Captured Knowledge` in a devlog or recap note, and appending a bullet to `## Referenced in` in a promoted artifact. No other content in those files is touched — these writes are strictly additive within named sections.
- Write during a session (only on `SessionEnd`, to avoid racing active edits).
- Block or delay session close. The shell hook returns in under 200ms; all model work is backgrounded. No synchronous API calls on the close path, ever.
- Drop substantive session content beyond the scrubber's redactions — Path A returns either an artifact or `null`; Path B always summarizes. Neither silently strips meaningful context.
- Capture when the transcript is below the small-signal threshold (default: < 3 user turns OR < 1500 chars of user content). Skip both paths silently, log reason. The OR means either condition alone is sufficient to classify a session as low-signal.
- Capture if the session_id is already present in `eval/state/session-index.tsv`. Re-running the hook on a known session exits 0 without writing. If the index is absent, write proceeds unconditionally (see §2.1 dedup step).

### Secret scrubbing (`hooks/scrub.py`)

Transcripts can contain pasted secrets, env vars, tokens, or private keys. `scrub.py` runs a deterministic, pattern-based pass on the transcript **before** it leaves this machine for the Anthropic API, and again on each model output **before** writing to disk. Redactions replace the match with a typed sentinel (`<redacted:jwt>`, `<redacted:env_var>`, etc.) so scrubbed text remains readable.

**Rule set v0** (defined in `hooks/scrub_rules.py`; extend via PR + fixture). **All patterns are compiled with `re.MULTILINE`** so `^`/`$` anchors match at the start/end of every line, not just string boundaries. **Cross-line matching does not rely on `re.DOTALL`**: rules that span newlines use `[\s\S]` explicitly so a future change to compile flags cannot silently regress them.

- **Private key blocks** — `-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----`. Uses `[\s\S]*?` (not `.*?`) so the match crosses newlines regardless of `re.DOTALL`. Non-greedy to avoid one giant match swallowing everything between two separate key blocks. Sentinel: `<redacted:private_key>`.
- **Well-known token prefixes** — `sk-ant-[A-Za-z0-9_\-]+`, `sk-[A-Za-z0-9]+`, `gh[pousr]_[A-Za-z0-9]+`, `xox[baprs]-[0-9]+-[A-Za-z0-9\-]+`, `AKIA[0-9A-Z]{16}`, `AIza[0-9A-Za-z\-_]{35}`. Sentinel: `<redacted:token_prefix>`.
- **JWTs** — `eyJ[A-Za-z0-9_\-]+\.eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+`. Sentinel: `<redacted:jwt>`.
- **`.env`-style secret assignments** — `^[ \t]*(?P<k>[A-Z][A-Z0-9_]+)[ \t]*=[ \t]*(?P<v>[^\s#]+)` where `k` contains `KEY|TOKEN|SECRET|PASSWORD|PASS|PWD|CREDENTIAL|API`. Only the value is replaced; the key name is kept for context. Sentinel: `<redacted:env_var>`. Three guarantees:
  - **MULTILINE is required** — without it, `^` matches only the start of the transcript string, so assignments past line 1 would never be redacted. `test_scrub.py` asserts this with a mid-transcript fixture.
  - **Value clause is `[^\s#]+`** (not `\S+`) so trailing comments are not captured into the redaction. `API_KEY=xyz # prod` redacts `xyz`, leaving `# prod` intact.
  - **Known limitation — `#` inside a quoted value truncates early.** `API_KEY="sk-abc#suffix"` redacts only `"sk-abc`, leaving `#suffix"` visible. The regex doesn't understand shell/YAML quoting. Rare in practice (secrets are rarely literal-quoted and rarely contain `#`), but documented here so users don't assume the scrubber is quote-aware. If this shape shows up in week-1 redactions, extend the rule — don't rely on the scrubber to handle it silently.
  - **Scope: `k` must start with an uppercase letter** — lowercase env vars (`db_password`, `api_key`) are not matched. Intentional; the pattern targets shell/CI convention where secrets use UPPER_SNAKE_CASE. If lowercase secrets appear in week-1 review, extend the pattern with a fixture update.
- **Bearer tokens** — `(?i)(authorization[:\s=]+bearer[:\s]+|bearer[:\s]+)[A-Za-z0-9_\-\.=]+`. Sentinel: `<redacted:bearer>`. Covers the common shapes seen in curl/httpie output and log snippets: `Authorization: Bearer xyz`, `-H 'Authorization: Bearer xyz'`, `bearer xyz` in logs.
- **Basic-auth URLs** — `https?://[^:/\s]+:[^@/\s]+@`. User kept, password replaced. Sentinel: `<redacted:basic_auth_url>`.

**Design constraints:**
- Idempotent: `scrub(scrub(x)) == scrub(x)`. Rules operate only on non-sentinel text.
- Deterministic: same input → same output. No LLM in the scrubber.
- Fail-safe to availability: on an invalid rule — `re.error` from a malformed pattern, or `IndexError`/`KeyError` from an invalid replacement template, caught at compile time via a probe `subn` (narrow catch, not broad `except Exception`) — the rule is skipped AND a line is appended to `eval/state/scrub-failures.md` with `YYYY-MM-DD HH:MM:SS\t<rule_name>\t<exception>`. Programming errors in rule logic (e.g. `TypeError`) propagate normally. **Consequence:** if the `private_key` rule fails, a full private key block may be sent to the Anthropic API and written to the vault. This is an acceptable availability tradeoff but **must be visible**:
  - `hooks.log` records `SCRUB_RULE_FAILED: <rule_name>`.
  - `eval/state/scrub-failures.md` persists the failure across restarts.
  - An Inbox-triage extension (§2.3) reads `scrub-failures.md` and displays `⚠ N scrub rule(s) failed today` at the top of its triage output when entries match the target date. The user acknowledges by manually clearing or archiving the file after reviewing what, if anything, leaked during the failure window. This repo only *writes* the file; surfacing it is the extension's job.

  `test_scrub.py` injects a malformed regex string as a rule and asserts: the skip is logged, no exception propagates, `scrub-failures.md` receives a new line, and the rest of the pipeline still runs.
- Pure Python, unit-testable. No network, no SDK, no subprocess.

The scrubber is defense-in-depth, not a cryptographic guarantee. If a user pasted a secret into a session, that content was already sent to Anthropic in the session itself. The scrubber's narrower job is to prevent that secret from landing in a **local-but-possibly-git-tracked Obsidian vault**.

### Default gitignore for the vault

If `~/Obsidian/loics_vault/` is a git repository, `install.sh` adds `Inbox/raw/` to `.gitignore` by default — raw summaries are higher-volume and less filtered. `Inbox/auto/` is not gitignored by default — curated output is lower-volume and lower-risk. User can flip this after week 1 based on observed content.

Detect via `git -C "$VAULT" rev-parse --is-inside-work-tree 2>/dev/null`. Do not use `[ -d .git ]` — it fails for worktrees where `.git` is a file. Before appending, check `grep -qxF 'Inbox/raw/' "$VAULT/.gitignore" 2>/dev/null` — skip the append if already present (idempotency guard). The install smoke test (`eval/run-install-smoke.sh`) must cover the re-run case: second invocation must not add a second `Inbox/raw/` line.

## 8. Open questions & resolved decisions

### Open
- **Cost ceiling calibration** — `CAPTURE_MAX_EST_TOKENS=50000` (≈200 KB transcript, ≈$0.15 Sonnet input cost) is the default. After week 1: compute p95 of `tokens_in_a + tokens_in_b` from `eval/state/log.md`. If p95 < 20 000, the ceiling has 2.5× headroom and is fine. If p95 > 30 000, lower the ceiling to `1.5 × p95`. Also verify the proxy formula once: compare `len(scrubbed_transcript) // 4` against the actual `tokens_in_a` the API reports for one real session — if the discrepancy exceeds 30%, switch to a character-count ceiling (`len(text) > 800 000`) and document the conversion.
- **Scrubber rule completeness** — the v0 rules cover common shapes. If week-1 redaction counts are consistently 0 on sessions where secrets were plausibly pasted, add rules (commit with a fixture). Track in `eval/state/log.md`.
- **`eval/state/log.md` extension** — the file is JSON-lines but uses a `.md` extension for consistency with the eval folder and Obsidian visibility. If Obsidian tries to render it as Markdown and that causes problems, rename to `eval/state/log.jsonl` and update all references. Decide after seeing actual Obsidian behaviour in week 1.
- **`session-index.tsv` growth and rotation** — the eval anchors at 4 weeks, but the tool may keep running indefinitely. At 50 sessions/week, linear scan stays sub-ms for years, but file size grows unboundedly. Options: (a) leave as-is, (b) rotate annually, or (c) move dedup into a SQLite DB. No decision yet — depends on observed per-week volume and whether the tool graduates past the eval window. Revisit at the week-4 retrospective.
- **Devlog vs. recap backlink accumulation** — currently both backlinks are kept (§2.3 weekly recap: "append the recap backlink as a second bullet"). If in practice the recap backlink consistently supersedes the devlog one (the user only ever follows the recap link back), overwriting rather than accumulating would keep `## Referenced in` sections tighter. No decision yet — revisit at week-4 review based on which backlinks the user actually clicks.
- **Basic-auth URL — redact the username too?** The current rule (§7) keeps the user visible in `https://alice:<redacted>@host/`. Pro-privacy case: usernames can be identifying (`service-account-prod`, `alice@company.com`). Pro-debug case: seeing *which* account leaked a credential matters for rotation. No decision yet — revisit at week-4 review based on what actually shows up in `redactions.basic_auth_url` counts.
- **Rotation for `scrub-failures.md` and `hooks.log`** — neither file rotates. `scrub-failures.md` grows by one line per failure per session (bounded by rule-count × session-count, small). `hooks.log` grows unboundedly and is shared with the pre-log-crash gap check (§2.3). At 4 weeks this is a non-issue. If the tool outlives the eval, decide at the week-4 retrospective: leave-as-is, manual archive on each weekly sweep, or `logrotate`-compatible config. Coupled with the `session-index.tsv` rotation question above — solve both together to keep state-file policy consistent.

### Resolved
- **Note filename convention for wikilinks** — `notes_daily/YYYY-MM-DD.md` (e.g. `notes_daily/2026-04-23.md`) and `notes_weekly/YYYY-Www.md` (ISO week, zero-padded — e.g. `notes_weekly/2026-W14.md`). The triage extension derives the stem deterministically from the date, not by file listing, when generating backlink wikilinks.
- **Miss-rate measurement source** — `eval/state/session-index.tsv`, not a vault scan. Rationale: the index is the canonical record of what Path A *produced*; vault state drifts as the user deletes or moves curated artifacts during triage. The eval is evaluating the filter, so "did Path A produce an artifact" (index) is the right question, not "is a curated sibling still in the vault today" (vault scan).
- **No-capture alarm ratio** — threshold-skipped entries are excluded from *both* numerator and denominator. A threshold skip is expected behaviour, not failure; counting it in either would bias the alarm. Ratio: `(both paths null AND skip_reason_a != "threshold") / (total log entries − threshold-skipped entries)`.
- **`log.md` schema handling of skips/errors** — see §2.2 table. Each path has paired `path_*` and `skip_reason_*` fields; exactly one is non-null. Token/cost fields are `null` when the API was not called for that path.

## 9. Eval checklist

- [ ] **Week 0 — pre-implementation prerequisites.** Triage integration (anchors in the user's own workflow `SKILL.md` files, plus `CAPTURE_EXCLUDED_COMMANDS`) is installed by the external triage extension, not this repo. Its installer skips gracefully if an anchor is absent — it never exits 1.
- [ ] **Week 0 — install & first session.** Run `install.sh`; confirm `eval/state/` directory created, `start-date.txt` written, hook registered in `settings.json` as `{"matcher":"", "hooks":[{"type":"command","command":"…"}]}`, the `/vault-save` skill created at `~/.claude/skills/vault-save/SKILL.md`, `eval/.gitignore` contains `state/`. First session produces one file in each of `Inbox/auto/` (or null) and `Inbox/raw/`. Verify frontmatter, cost logging, and idempotency (re-run on same session = no duplicates). Verify `~/.claude/hooks.log` contains a `SESSION_END_RECEIVED` line for the session. Verify the first `log.md` entry has `schema_version: 1` and an ISO-8601 `timestamp`. **Run `pytest tests/` — all must pass, including: multi-line `.env` redaction in `test_scrub.py`, cross-line private-key block redaction, Bearer-token redaction, title sanitization, all `skip_reason` variants (including `excluded_command`) in `test_log_schema.py`, excluded-command line-anchor matching in `test_excluded_commands.py`, list-typed content flattening in `test_load_transcript.py`, and Path A/B exception isolation in `test_failure_isolation.py`.** Manually run the hook once with a transcript containing a fake API key; confirm neither Inbox file contains the token.
- [ ] **Week 1 — mid-week review.** Review both Inboxes. Is Path A producing anything non-obvious vs Path B? Tune either prompt if obviously off. Review redaction counts in `eval/state/log.md` — if 0 across all sessions, either you're not pasting secrets (fine) or the rules are too narrow (fix). Check `eval/state/scrub-failures.md` — any entries mean a rule stopped running and secrets may have flowed through unredacted during that window.
- [ ] **Week 2 — first full weekly sweep** (via the triage extension). Record kept/discard/miss counts and no-capture sessions. Verify the 25% alarm would fire if the ratio exceeds threshold (manually simulate by seeding `log.md` with enough error entries if needed).
- [ ] **Week 4 — retrospective.** Tally metrics from the triage extension's `metrics.md`. Compare kept-rate and miss rate. Write decision note. Revisit the four open questions in §8 (cost ceiling, scrubber completeness, `log.md` extension, session-index rotation, backlink accumulation).

---

*This spec is the source of truth. Update it when decisions change — don't let it drift.*
