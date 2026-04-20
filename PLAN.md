# Spellwire Plan

This document is the execution roadmap for future contributors and coding agents.

It assumes:

- macOS host only in v1
- iPhone-first `iOS 26.4+` client
- SSH-only transport
- shell-neutral SSH bootstrap commands that work across fish, zsh, bash, and similar login shells
- npm as the primary helper distribution path
- manual SSH pairing in v1
- no relay and no hosted control plane

## Current Snapshot

- Milestone 1 is effectively in place: repo-facing docs now align on the SSH-only, local-first architecture.
- Milestone 2 is scaffolded in code: the repo now ships a buildable TypeScript `spellwire` helper with the public CLI contract, LaunchAgent plumbing, daemon socket bridge, logs, doctor/status flows, and JSON RPC transport.
- The helper lifecycle scaffold now runs through a LaunchAgent on macOS and a detached background process on Linux for local helper development and CLI validation, while the supported product host remains macOS in v1.
- Milestone 3 is partially implemented in `spellwire-ios/`: the iPhone app now generates and stores an Ed25519 key, exports the OpenSSH public key, and pins host fingerprints instead of storing passwords.
- Milestone 4 is partially implemented: the helper owns Codex app-server attachment, project/thread listing, thread open/read, turn send/steer/interrupt, desktop handoff, preview discovery, and rollout-tail recovery scaffolding.
- Milestone 5 has a rudimentary interactive iPhone surface: browse projects and threads, open a thread into a recent-history window, lazily page older history, stream deltas, send prompts, interrupt, refresh, hand off to the Mac, and surface helper-owned Git working-tree state for the selected thread.
- Milestones 6 through 8 remain early scaffolds. Terminal, files, and previews are secondary surfaces and not production-ready.

## Milestone 1: Docs and License Baseline

**Goal**

Lock the project narrative to the SSH-first architecture and establish one consistent source of truth across docs.

**Includes**

- `AGENTS.md`
- `PLAN.md`
- `README.md`
- repository-wide language locked to SSH-first, local-first, no-relay direction
- explicit `AGPL-3.0-only` repository policy in docs

**Dependencies**

- None

**Acceptance Criteria**

- The three docs agree on scope, terminology, install path, and v1 constraints.
- No repo-facing product doc reintroduces relay or hosted control-plane assumptions.
- Docs clearly separate current repo reality from planned runtime behavior.

**v1 Non-Goals**

- Shipping helper code
- shipping transport code
- shipping a public package

## Milestone 2: npm Helper and LaunchAgent Runtime

**Goal**

Create the Mac helper as a background-first npm package with a usable local CLI and diagnostics.

**Includes**

- `spellwire` npm package and versioning
- LaunchAgent install/start/stop flow
- detached background-process fallback for local Linux helper development and CLI validation
- helper runtime lifecycle management
- foreground debug mode
- structured logs
- doctor/status output
- machine-readable RPC command surface

**Dependencies**

- Milestone 1

**Acceptance Criteria**

- `spellwire up`, `stop`, `status`, `logs`, `doctor`, and `rpc` behave consistently on macOS.
- The same CLI lifecycle works on Linux for local helper development without requiring `launchctl`.
- LaunchAgent and foreground debug mode can target the same helper runtime contract.
- iOS-facing helper commands return JSON, not human-only text.
- SSH exec bootstrap commands remain shell-neutral instead of depending on the user's login shell to parse POSIX script syntax.

**v1 Non-Goals**

- Homebrew distribution
- distro-specific Linux service integration such as `systemd`

## Milestone 3: Manual SSH Onboarding and Trust Storage

**Goal**

Implement a manual but robust v1 trust flow between iPhone and Mac.

**Includes**

- Ed25519 key generation on iPhone
- secure private key storage on iPhone
- pinned host fingerprint storage
- host/user/port configuration UI
- `Remote Login` readiness checks and guidance
- manual public-key install instructions for `authorized_keys`
- LAN and Tailscale connection support

**Dependencies**

- Milestone 2

**Acceptance Criteria**

- A user can connect from iPhone to a Mac over LAN or Tailscale without any relay.
- The app refuses host changes until the fingerprint is re-confirmed.
- The Mac trust model does not depend on macOS Keychain.
- Any onboarding snippet shown for `authorized_keys` setup works when pasted into fish, zsh, bash, and other common shells.

**v1 Non-Goals**

- QR bootstrap
- automatic key enrollment
- non-macOS host onboarding

## Milestone 4: Codex Sync Core

**Goal**

Make Spellwire reflect the full local Codex environment instead of a single visible desktop thread.

**Includes**

- helper spawn/attach flow for long-lived `codex app-server`
- paginated `thread/list` across relevant source kinds
- archived thread discovery
- `thread/resume` with stable thread-to-`cwd` binding
- `thread/read(includeTurns=true)` hydration, including recent-window reads for fast open plus older-history paging
- live notification handling for `thread/*`, `turn/*`, `item/*/delta`, and `item/completed`
- rollout and session-file recovery under `~/.codex/sessions`
- active-thread memory and explicit thread opening in `Codex.app`
- item-aware history merge logic
- recent-window recovery for large or running chats, followed by canonical reconciliation

**Dependencies**

- Milestones 2 and 3

**Acceptance Criteria**

- The mobile app can discover multiple projects and multiple chats from the same Mac.
- Reopening a thread preserves the correct thread id, `cwd`, and runtime context.
- Running chats recover after reconnect, app backgrounding, or missed live events.
- Off-screen runs and context-window usage can catch up from persisted rollout data.

**v1 Non-Goals**

- Files UI
- terminal UI
- preview browser UI

## Milestone 5: Multi-Project Chat UI on iPhone

**Goal**

Turn the sync core into a usable iPhone-first Codex interface.

**Includes**

- project and thread browsing
- active and archived thread handling
- recent-window-first timeline rendering with lazy older-history paging and reconciliation back to canonical thread state
- thread open, continue, and state refresh flows
- helper-owned Git status refresh for the selected thread `cwd`
- thread-header diff pill, structured diff viewer, and latest-agent inline Git actions
- thread-scoped Git status and diff presentation for the current chat, full-worktree commit flow, helper-generated drafts, `origin` push, and GitHub-only PR creation when `gh` is authenticated
- rename/archive plumbing prepared behind the service layer, with UI wiring following after send/open/interrupt stability
- multi-thread switching without assuming one desktop-selected thread
- Liquid Glass visual system for the primary app shell

**Dependencies**

- Milestone 4

**Acceptance Criteria**

- Users can browse and switch among multiple Codex projects and chats from iPhone.
- Timeline state stays coherent when moving between running and idle threads.
- Dirty working trees for the selected thread surface helper-owned `+/-` counts, a structured diff, and commit actions without shell scraping on iPhone.
- The mobile UI remains independent from the current selection inside `Codex.app`.

**v1 Non-Goals**

- iPad-first layouts
- rich desktop editing workflows
- partial staging UI, remote selection, or non-GitHub PR providers

## Milestone 6: Terminal Surface

**Goal**

Ship a real SSH terminal on iPhone instead of a simplified console.

**Includes**

- SSH PTY session management
- native terminal view and input handling
- pinned `libghostty-vt` integration
- scrollback, selection, copy/paste, resize, keyboard handling
- session recovery expectations aligned with mobile lifecycle

**Dependencies**

- Milestones 2 and 3

**Acceptance Criteria**

- The terminal is interactive and suitable for normal SSH shell work on the Mac.
- Terminal emulation is tied to a pinned `libghostty-vt` revision or vendored snapshot.
- The terminal stack is separate from helper RPC and does not overload chat transport.

**v1 Non-Goals**

- building a desktop-equivalent multi-pane IDE
- unsupported floating dependency upgrades for terminal core

## Milestone 7: Finder-Like File Manager

**Goal**

Provide a broad but bounded remote file surface over SSH.

**Includes**

- directory browsing
- search
- text and code preview
- inline text editing
- create, rename, move, and delete operations
- upload and download
- common preview affordances for non-text files

**Dependencies**

- Milestones 2 and 3

**Acceptance Criteria**

- Users can browse and manage remote files from iPhone without leaving the app.
- Text editing and core file operations work over SSH and SFTP-backed flows.
- The file layer stays clearly separate from the Codex chat timeline.

**v1 Non-Goals**

- becoming a full remote desktop IDE
- advanced collaborative editing semantics

## Milestone 8: Preview Browser

**Goal**

Make local Mac web previews reachable from iPhone through SSH port forwarding.

**Includes**

- SSH tunnel lifecycle management
- helper-backed preview registry
- manual forwarded-port entry
- embedded iPhone browser for forwarded localhost sites
- helper command `spellwire previews list`

**Dependencies**

- Milestones 2 and 3

**Acceptance Criteria**

- Users can open recognized local previews from the app.
- Users can also manually connect to arbitrary forwarded ports.
- Preview transport uses SSH tunnels only.

**v1 Non-Goals**

- public preview hosting
- relay-based tunneling

## Milestone 9: Desktop Handoff and Refresh Behavior

**Goal**

Keep the Mac desktop experience aligned without making the mobile app depend on desktop selection state.

**Includes**

- remember last active thread on helper side
- `spellwire open <threadId>`
- explicit handoff into `Codex.app`
- optional bounded desktop refresh nudges
- rollout-growth observation for refresh decisions

**Dependencies**

- Milestone 4

**Acceptance Criteria**

- A specific thread can be reopened explicitly in `Codex.app`.
- The helper can remember the last active thread for handoff flows.
- Desktop refresh behavior stays optional and bounded because `Codex.app` may not live-refresh external writes.

**v1 Non-Goals**

- treating `Codex.app` as the only live source of truth
- forcing the mobile app to mirror the current visible desktop route

## Milestone 10: QA, Packaging, and Release Prep

**Goal**

Prepare the project for repeatable development, testing, packaging, and public release.

**Includes**

- focused unit and integration coverage for helper RPC, sync logic, SSH flows, and state recovery
- iPhone UI smoke coverage for onboarding, chats, files, previews, and terminal entry
- npm packaging and update flow
- release notes and contributor guidance
- backlog definition for later Homebrew support

**Dependencies**

- Milestones 2 through 9

**Acceptance Criteria**

- The published helper contract matches the documented CLI contract.
- The sync model is test-backed for list, resume, read, notifications, and rollout recovery.
- Release docs do not claim features the codebase does not ship.

**v1 Non-Goals**

- Homebrew as a required release path
- Linux host parity

## Cross-Cutting Rules

- Do not add a separate Spellwire backend.
- Do not replace SSH with a relay-based architecture.
- Keep docs, helper contracts, and iOS behavior aligned as implementation lands.
- When behavior differs between current repo state and target product state, document the difference explicitly instead of implying completion.
