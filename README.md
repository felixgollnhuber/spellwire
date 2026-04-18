![Spellwire](./.github/assets/sign_dark.png)

# Spellwire

Spellwire is an iPhone-first remote control for Codex on macOS. It connects directly to your Mac over SSH on the local network or through Tailscale, keeps its view aligned with the same local Codex environment used by `Codex.app`, and does not depend on a relay or hosted control plane.

> Status: alpha. This repo now includes a buildable TypeScript helper scaffold in `src/` and a rudimentary interactive iPhone client in `spellwire-ios/`. Helper-owned Codex sync, rollout recovery, terminal, files, and preview flows are present as early implementations and are not production-ready yet.

![Platform](https://img.shields.io/badge/platform-iOS%2026.4%2B%20%7C%20macOS-black)
![Transport](https://img.shields.io/badge/transport-SSH%20only-111827)
![UI](https://img.shields.io/badge/ui-SwiftUI%20%2B%20Liquid%20Glass-111827)
![Status](https://img.shields.io/badge/status-alpha-f59e0b)
![License](https://img.shields.io/badge/license-AGPL--3.0--only-black)

## What Spellwire Is

- An `iOS 26.4+` SwiftUI app designed for iPhone first.
- A direct SSH client for controlling a Mac that runs Codex locally.
- A local-first system that mirrors the same Codex universe already present on the Mac.
- A product that works on LAN and over Tailscale without introducing a relay.
- A shell-neutral SSH workflow that does not assume the Mac account uses a POSIX login shell.

## Product Surfaces

### Codex

- Browse multiple projects and multiple chats from the same Mac.
- Keep the full local Codex history visible on iPhone.
- Reattach to the correct thread, `cwd`, and runtime context instead of following only the thread currently open on the desktop.

### Terminal

- A real SSH PTY terminal on iPhone.
- Backed by a pinned `libghostty-vt` revision or vendored snapshot.
- Built as a native terminal surface, not a simplified log viewer.

### Files

- A Finder-like remote file manager over SSH and SFTP.
- The current scaffold can browse, search, preview, export, edit text, create folders, and delete remote items.
- Rename, move, upload, and download are planned follow-on file operations rather than fully wired v1 behavior today.
- Broad file access without trying to become a second full desktop IDE.

### Previews

- Target v1 preview transport is SSH port forwarding to localhost services on the Mac.
- The current iPhone scaffold supports manual preview setup through either a forwarded port or a direct browser URL on the host record.
- Helper-backed preview discovery exists in the helper scaffold, but it is not wired into the iPhone app yet.

## Architecture

`Codex.app` on the Mac remains the development environment. Spellwire stays in sync with that same local environment instead of creating a separate mobile backend or a separate remote state store.

The diagram below shows the intended v1 architecture. In the current repo scaffold, the helper already exposes `spellwire previews list`, but the iPhone preview browser still relies on manual host configuration and does not consume helper-backed preview discovery yet.

```mermaid
flowchart LR
    subgraph iPhone["iPhone"]
        IOS["Spellwire iOS app<br/>SwiftUI + Liquid Glass"]
        CHAT["Codex workspace"]
        TERM["Terminal UI"]
        FILES["File browser"]
        PREV["Preview browser"]
        KEYS["Ed25519 key + pinned host fingerprint<br/>stored on device"]
    end

    subgraph Mac["macOS host"]
        SSHD["sshd<br/>Remote Login"]
        HELPER["spellwire helper<br/>LaunchAgent + CLI"]
        RPC["spellwire rpc<br/>JSON over stdio"]
        OPEN["spellwire open &lt;threadId&gt;"]
        PRELIST["spellwire previews list"]
        APPSERVER["codex app-server"]
        SESS["~/.codex/sessions<br/>sessions + rollout artifacts"]
        CODEXAPP["Codex.app"]
        PTY["SSH PTY shell"]
        SFTP["SFTP / SSH file ops"]
        TUNNEL["SSH port forwarding"]
    end

    IOS --> CHAT
    IOS --> TERM
    IOS --> FILES
    IOS --> PREV
    IOS --> KEYS

    IOS -->|"SSH exec + JSON RPC"| SSHD
    IOS -->|"SSH PTY"| SSHD
    IOS -->|"SFTP / SSH file ops"| SSHD
    IOS -->|"SSH port forwarding"| SSHD

    SSHD --> HELPER
    SSHD --> PTY
    SSHD --> SFTP
    SSHD --> TUNNEL

    HELPER --> RPC
    HELPER --> OPEN
    HELPER --> PRELIST

    HELPER <-->|"attach / manage"| APPSERVER
    HELPER <-->|"recovery / catch-up"| SESS
    HELPER -->|"open explicit thread"| CODEXAPP

    CHAT -->|"thread/list, thread/read, thread/resume,<br/>live updates"| HELPER
    TERM -->|"interactive shell session"| PTY
    FILES -->|"browse / preview / export / edit"| SFTP
    PREV -->|"localhost preview access"| TUNNEL
```

## Sync Model

Spellwire's helper-owned sync contract is:

- Use paginated `thread/list` across relevant source kinds to discover all projects and chats, including archived threads.
- Use `thread/resume` when opening or reattaching to a thread so the same thread id stays bound to the right `cwd` and runtime context.
- Use `thread/read(includeTurns=true)` for canonical history hydration and reconciliation.
- Use live notifications such as `thread/*`, `turn/*`, `item/*/delta`, and `item/completed` for low-latency UI updates.
- Use persisted rollout and session files in `~/.codex/sessions` as the recovery and catch-up path for running chats, context-window usage, off-screen runs, and desktop continuity.
- Merge history item-aware, not `turnId`-only. For huge or still-running chats, allow a recent-window merge first and run canonical reconciliation afterward.
- Keep the mobile app independent from whichever desktop thread is currently selected in `Codex.app`.

Because `Codex.app` may not live-refresh external writes, desktop handoff and refresh behavior are helper-owned and bounded. Mobile correctness must not depend on desktop route state.

## Prerequisites

- A Mac running macOS with `Remote Login` enabled.
- Codex installed and signed in on that Mac.
- Node.js for the helper install path.
- Reachability over local network or Tailscale.
- An iPhone running `iOS 26.4+`.
- Xcode if you are building the iPhone app from source.

## Install and Update Path

For local development in this repo today:

```sh
npm install
npm run build
node dist/src/cli.js up
node dist/src/cli.js status
node dist/src/cli.js doctor
```

The intended public distribution path remains a globally installed npm package. The public command surface is:

```sh
npm install -g spellwire@latest
spellwire up
spellwire status
spellwire logs
spellwire doctor
```

When the package is published, the update path stays:

```sh
npm install -g spellwire@latest
```

Planned public CLI contract:

- `spellwire up`
- `spellwire stop`
- `spellwire status`
- `spellwire logs`
- `spellwire doctor`
- `spellwire rpc`
- `spellwire open <threadId>`
- `spellwire previews list`

Homebrew is intentionally later work, not part of the initial required path.

Spellwire's SSH bootstrap commands are expected to work even when the remote account uses fish, zsh, bash, or another common shell. POSIX bootstrap logic should run through an explicit `/bin/sh` wrapper instead of assuming the login shell accepts POSIX script syntax directly.

## Manual v1 Onboarding

v1 uses a manual SSH trust model. The current iPhone scaffold already generates and stores the Ed25519 key locally, shows the OpenSSH public key for `authorized_keys`, and requires host-fingerprint approval before connecting.

1. Enable `Remote Login` on the Mac.
2. Confirm that Codex can run locally on the Mac and that `codex app-server` is available.
3. Install the Spellwire helper globally from npm once the package is published.
4. Generate an Ed25519 keypair inside the iPhone app and store the private key in iOS secure storage.
5. Add the iPhone public key to the Mac user's `~/.ssh/authorized_keys`.
6. Verify and pin the Mac host fingerprint in the iPhone app.
7. Enter host, user, and port details in the iPhone app.
8. Connect over LAN hostname or IP, or over a Tailscale hostname or IP.

v1 does not assume QR bootstrap and does not depend on macOS Keychain.
The setup command shown for `authorized_keys` is intended to stay shell-neutral for common login shells on the Mac.

## Current Repo State

Today this repository includes:

- a buildable TypeScript helper scaffold under `src/` with `spellwire up|stop|status|logs|doctor|rpc|open <threadId>|previews list`
- helper tests under `test/` for runtime paths, launch-agent generation, thread mapping, and rollout recovery indexing
- `spellwire-ios/` with host onboarding, Ed25519 identity management, host fingerprint pinning, a Codex-first workspace, and secondary terminal/file/preview surfaces
- shared project assets under `.github/assets/`
- docs that define the target SSH-first architecture

This repository does not yet contain a production-complete v1 runtime. The helper, sync layer, and iPhone experience are scaffolded and interactive, but they still need hardening, deeper recovery coverage, and more complete terminal/file/preview behavior.

## iOS Design and Scope

- iPhone-first SwiftUI app
- `iOS 26.4+`
- Liquid Glass visual system
- macOS host only in v1
- LAN and Tailscale support

## iOS Signing

The iOS target reads its signing values from [`spellwire-ios/Config/Signing.xcconfig`](./spellwire-ios/Config/Signing.xcconfig).

Create a local override before you build for a device or archive:

```sh
cp spellwire-ios/Config/Signing.local.xcconfig.example spellwire-ios/Config/Signing.local.xcconfig
```

Then set your own values in `Signing.local.xcconfig`:

- `SPELLWIRE_BUNDLE_IDENTIFIER`
- `SPELLWIRE_DEVELOPMENT_TEAM`

The local file is gitignored so personal signing data stays out of the public repo.

## License

Spellwire is being built as an `AGPL-3.0-only` open-source project. Keep the repository docs and release artifacts consistent with that license policy.
The full license text lives in [`LICENSE`](./LICENSE).
