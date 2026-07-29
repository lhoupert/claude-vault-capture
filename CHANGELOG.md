# Changelog

## [0.3.0](https://github.com/developmentseed/claude-vault-capture/compare/v0.2.0...v0.3.0) (2026-07-29)


### Features

* **curate:** make the model-call timeout configurable via CAPTURE_TIMEOUT_SECONDS ([#16](https://github.com/developmentseed/claude-vault-capture/issues/16)) ([7694a43](https://github.com/developmentseed/claude-vault-capture/commit/7694a43b937dafe309ba5bf21128bfd803800145))
* surface tool activity to the curator ([#15](https://github.com/developmentseed/claude-vault-capture/issues/15)) ([541a2e5](https://github.com/developmentseed/claude-vault-capture/commit/541a2e5b0fd7663c0e185ee9be9e0018eeabbfcb))


### Bug Fixes

* **capture:** close the W29 no-capture failure classes ([#26](https://github.com/developmentseed/claude-vault-capture/issues/26)) ([8d8a239](https://github.com/developmentseed/claude-vault-capture/commit/8d8a2393d8349f3046fa7b83143aae6c10f5ce1e))
* **capture:** close the W30 failure classes (test pollution, subscription error_max_turns) ([#27](https://github.com/developmentseed/claude-vault-capture/issues/27)) ([f046ed0](https://github.com/developmentseed/claude-vault-capture/commit/f046ed02000a2d9de6eccce3e9239795063b614d))
* close scrubber gaps and harden the artifact write path ([#30](https://github.com/developmentseed/claude-vault-capture/issues/30)) ([3249bf9](https://github.com/developmentseed/claude-vault-capture/commit/3249bf93fe60464338e4571da4040c6220d2bb8c))
* **curate:** terminate the transcript so the model curates instead of continuing it ([#29](https://github.com/developmentseed/claude-vault-capture/issues/29)) ([7577892](https://github.com/developmentseed/claude-vault-capture/commit/7577892d979a2480fad59f4e9b60b27681c55205))

## [0.2.0](https://github.com/lhoupert/claude-vault-capture/compare/v0.1.0...v0.2.0) (2026-06-05)


### ⚠ BREAKING CHANGES

* log/index schema bumped to version 2 — path_b, skip_reason_b, tokens_in_b, tokens_out_b, cost_usd_b dropped; session-index loses its path_b column. Inbox/raw/ is no longer written; external triage extensions reading it must tolerate its absence. The 'per-path failure isolation' invariant is removed (only one path remains).

### Features

* **curate:** retry Path A once on null to recover non-deterministic misses ([d346921](https://github.com/lhoupert/claude-vault-capture/commit/d3469218ccaf534c87cb84090827766cd97349e6))


### Documentation

* document Pro/Max subscription mode with a macOS Keychain recipe ([baf99ec](https://github.com/lhoupert/claude-vault-capture/commit/baf99ec1fea67b7be45b7993733aa9324bc46557))
* document subscription mode with a macOS Keychain token recipe ([dc85234](https://github.com/lhoupert/claude-vault-capture/commit/dc8523464435d1a51e9c6116a255d6190aef4ab6))
* **readme:** fix stale Path B references missed in the removal ([806ca0e](https://github.com/lhoupert/claude-vault-capture/commit/806ca0eaf4eb6537eec8fecc8c39672152d407a2))


### Code Refactoring

* retire Path B (Haiku raw baseline) — single-path capture ([4c9cfdc](https://github.com/lhoupert/claude-vault-capture/commit/4c9cfdcb3ee8968ae9bdf220eed3737ea822c693))
