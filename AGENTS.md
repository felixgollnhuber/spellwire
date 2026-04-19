# Spellwire AGENTS

This file defines the repository direction for human contributors and coding agents.

Keep this file, `PLAN.md`, and `README.md` aligned. If product direction or architecture changes, update all three in the same change.

## Mission

Spellwire is an iPhone-first `iOS 26.4+` SwiftUI app in Liquid Glass design that remotely controls the Codex environment on a Mac over SSH.

The product is:

- SSH-only
- LAN- and Tailscale-friendly
- macOS-hosted in v1
- open source under an `AGPL-3.0-only` repository policy
- designed to stay in sync with the same local Codex environment used on the Mac

Spellwire is not a hosted control plane, does not depend on a relay, and does not introduce a separate mobile backend.

## Current State

- The repo now contains a buildable TypeScript helper scaffold at the repo root under `src/` plus npm metadata and tests.
- `spellwire-ios/` now includes Ed25519 key onboarding, host fingerprint pinning, a shared SSH identity model, and a rudimentary Codex-first workspace for browsing projects and threads, opening threads with a recent-history window, lazily loading older history, sending prompts, interrupting turns, opening a thread on the Mac, and surfacing helper-owned Git status, diff, and commit actions for the selected thread `cwd`.
- The helper-owned sync layer, rollout recovery, desktop handoff, terminal, file manager, preview flows, and new Git working-tree actions exist as early implementations and are not production-complete yet.
- The current docs must describe that reality honestly.

## Agent Workflow (Local Validation)

- **iOS:** Prefer Xcode.app for local builds, runs, and tests. Open `spellwire-ios/spellwire-ios.xcodeproj`, use the shared `spellwire-ios` scheme, and treat the active Xcode window, scheme, and destination as the source of truth while validating changes.
- Use **XcodeBuildMCP only as a fallback** when Xcode.app is unavailable, fails to cooperate, or cannot expose the diagnostics or simulator control you need. Do not reach for XcodeBuildMCP first.
- Do **not** substitute ad-hoc shell `xcodebuild` commands unless the user explicitly asks for them.
- Prefer simulator validation first for routine iOS changes. Simulator builds do not require local signing overrides.
- Device builds and archives require a local signing override file at `spellwire-ios/Config/Signing.local.xcconfig`. Start from `spellwire-ios/Config/Signing.local.xcconfig.example`, then set `SPELLWIRE_BUNDLE_IDENTIFIER` and `SPELLWIRE_DEVELOPMENT_TEAM` locally.

## Hard Guardrails

- Do not reintroduce a relay, hosted broker, or hosted control plane.
- Do not assume hosted relay routing, WebSocket pairing brokers, or QR-based bootstrap flows.
- macOS is the only host target for v1.
- The iPhone app is the primary client surface in v1; iPad-specific UX is not part of the initial promise.
- `iOS 26.4+` and Liquid Glass are required product constraints for the iPhone app.
- npm is the primary installation and update path for the Mac helper in v1. Homebrew is later work, not current scope.
- Manual SSH pairing is the v1 trust model.
- The iPhone stores an Ed25519 private key and pinned host fingerprint in iOS secure storage.
- The Mac requires `Remote Login` plus a user-installed public key in `~/.ssh/authorized_keys`.
- Do not add a macOS Keychain dependency to the trust model in v1.
- All helper APIs consumed by the iPhone app must return machine-readable JSON. The iPhone app must not parse human CLI text as protocol.
- Any command sent through SSH exec, or shown to the user for copy-paste into a shell, must work regardless of whether the remote account uses fish, zsh, bash, or another common shell. Wrap POSIX bootstrap logic in an explicit `/bin/sh` invocation instead of assuming the login shell parses POSIX syntax.

## Architecture Contract

### SSH transport

Use one SSH trust model with separate channels for:

- helper RPC over `ssh exec` plus JSON over stdio
- interactive terminal over SSH PTY
- file management over SFTP and SSH file operations
- localhost web previews over SSH port forwarding

### Mac runtime

- The Mac helper is a globally installed npm package exposed as the `spellwire` CLI.
- The helper runs background-first as a LaunchAgent and must also support foreground debugging, logs, status, and diagnostics from Terminal.
- The public CLI contract is:
  - `spellwire up`
  - `spellwire stop`
  - `spellwire status`
  - `spellwire logs`
  - `spellwire doctor`
  - `spellwire rpc`
  - `spellwire open <threadId>`
  - `spellwire previews list`

### Codex source of truth

- The helper owns or attaches to a long-lived local `codex app-server`.
- Canonical conversation state comes from the App Server plus persisted session and rollout artifacts under `~/.codex/sessions`.
- The visible thread in `Codex.app` is not the source of truth for the mobile app.
- The mobile app must expose the full Codex universe independently of whichever desktop thread is currently open.

### Sync contract

Agents must preserve this model:

- Use paginated `thread/list` across relevant source kinds to discover all projects and chats, including archived threads.
- Use `thread/resume` when opening or reattaching to a thread so the same thread id stays bound to the correct `cwd` and runtime context.
- Use `thread/read(includeTurns=true)` for canonical history hydration and reconciliation, with recent-window reads for fast initial open and older-history paging on demand.
- Use live notifications such as `thread/*`, `turn/*`, `item/*/delta`, and `item/completed` for low-latency UI updates.
- Use persisted rollout and session files in `~/.codex/sessions` as the recovery and catch-up path for running chats, context usage, off-screen runs, and desktop continuity.
- Merge history item-aware, not `turnId`-only.
- When a running or very large chat needs fast recovery, allow a recent-window merge first and schedule canonical reconciliation afterward.

### Desktop continuity

- The helper remembers the last active thread.
- The helper can explicitly open a specific thread in `Codex.app`.
- Since `Codex.app` may not live-refresh external writes, any desktop refresh or handoff behavior must stay bounded, optional, and helper-owned.

## Implementation Guardrails

- Keep Spellwire local-first around the user's Mac. Do not introduce a separate Spellwire service.
- Build multi-project and multi-thread support from the beginning. The app must not assume a single active project.
- The file surface is a Finder-like remote manager over SSH and SFTP, not a second full desktop IDE.
- Git status, diff, commit, push, and PR actions for a thread must stay helper-owned JSON RPC over SSH exec. The iPhone app must not run Git directly or parse human CLI output.
- The preview browser must use SSH tunnels only. v1 supports both helper-backed preview discovery and manual port entry.
- The terminal surface must use a pinned `libghostty-vt` revision or vendored snapshot. Do not float to arbitrary latest builds.
- Keep helper state, session recovery, and desktop handoff logic separate from SwiftUI views.
- Prefer stable, typed RPC contracts over shell scraping or ad hoc text parsing.
- v1 Git status and diff presentation are scoped to files changed by the current thread, while commit actions stage and commit the full working tree, push only to `origin`, and create pull requests only for GitHub remotes with authenticated `gh`.
- Keep SSH bootstrap commands shell-neutral. Remote helper startup, tmux/session resume, and onboarding snippets must execute correctly even when the account login shell is not POSIX-compatible.

## Documentation Rule

- `AGENTS.md`, `PLAN.md`, and `README.md` must describe the same architecture, terminology, and scope.
- `README.md` must always distinguish clearly between current repo state and planned runtime behavior.
- If old relay-era assumptions exist anywhere in repo-facing docs, remove them instead of layering compatibility language on top.
