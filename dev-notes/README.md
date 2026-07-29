# dev-notes

> **⚠️ Nothing in this directory describes current behaviour, and nothing here is
> a to-do list.** These are frozen working notes kept for provenance only. The
> task files are written in the present tense with unchecked `[ ]` boxes, but the
> work they describe is either **already shipped** or **deliberately abandoned** —
> an unchecked box here is not an invitation to go implement it. They also
> reference the author's own absolute paths (`~/Obsidian/loics_vault`,
> `~/DevDS/claude-vault-capture`), which the shipped code does not hardcode.

**If you are new to the project, you want [`README.md`](../README.md) (install and
configuration) and [`CLAUDE.md`](../CLAUDE.md) (current architecture and
invariants) instead. Neither of those is in this directory.**

Contents:

- `tasks/` — plan/review/todo notes from the `/vault-save` → `claude-docs/` refactor. Shipped; retained for the reasoning.
- `docs_claude/` — the e2e test plan that informed `tests/`. Executed; the suite it describes now exists and has grown well past it.
- `SPEC-claude-docs-refactor.md` — the refactor spec for that same work. Its step 11 says to fold deltas into the old canonical spec and delete itself; that never happened, and the canonical spec has since been archived (see below).
- `archive/2026-04-original-eval-spec.md` — the original April 2026 design spec, formerly `.github/SPEC.md`. Archived 2026-07-29: roughly half of it describes the retired two-path design. Kept because it records *why* several still-live decisions were made.
