<p align="center">
  <img src="./.github/assets/sign_dark.png" alt="Spellwire" width="920" />
</p>

<h1 align="center">Spellwire</h1>

<p align="center">
  A remote Codex control plane that pairs a local Mac helper with an iPhone companion over a Cloudflare relay.
</p>

<p align="center">
  Start the helper on macOS. Scan the pairing link on iPhone. Keep threads, approvals, attachments, and runtime state in sync from anywhere.
</p>

<p align="center">
  Spellwire is an alpha built around five pieces: a macOS desktop shell, a standalone helper process, an iPhone companion, a shared Swift core package, and a Durable Object relay.
</p>

<p align="center">
  <a href="#quick-start"><strong>Quick start</strong></a>
  ·
  <a href="#ios-signing"><strong>iOS signing</strong></a>
  ·
  <a href="#project-status"><strong>Project status</strong></a>
  ·
  <a href="#architecture"><strong>Architecture</strong></a>
  ·
  <a href="#verification"><strong>Verification</strong></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-iOS%2026.4%2B%20%7C%20macOS%2026%2B-black" alt="Platform: iOS 26.4+ and macOS 26+" />
  <img src="https://img.shields.io/badge/core-SwiftUI%20%2B%20Swift%206-111827" alt="Core: SwiftUI and Swift 6" />
  <img src="https://img.shields.io/badge/relay-Cloudflare%20Workers%20%2B%20Durable%20Objects-1f6feb" alt="Relay: Cloudflare Workers and Durable Objects" />
  <img src="https://img.shields.io/badge/status-alpha-f59e0b" alt="Status: alpha" />
  <img src="https://img.shields.io/badge/license-AGPL--3.0--only-black" alt="License: AGPL-3.0-only" />
</p>

## iOS signing

The iOS target reads its signing values from [`spellwire-ios/Config/Signing.xcconfig`](./spellwire-ios/Config/Signing.xcconfig).

Create a local override before you build for a device or archive:

```sh
cp spellwire-ios/Config/Signing.local.xcconfig.example spellwire-ios/Config/Signing.local.xcconfig
```

Then set your own values in `Signing.local.xcconfig`:

- `SPELLWIRE_BUNDLE_IDENTIFIER`
- `SPELLWIRE_DEVELOPMENT_TEAM`

The local file is gitignored so personal signing data stays out of the public repo.
