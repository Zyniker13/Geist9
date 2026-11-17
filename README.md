# Bristlecone Email Archiver

A Mac app that keeps a complete, searchable copy of your email, and lets your AI agents search it too.

It copies every message from your accounts (Gmail, iCloud, Outlook, Yahoo, Proton, Fastmail, and any IMAP or JMAP server), stores each one as a standard `.eml` file you own, and indexes everything, including attachments and scanned documents, so you can find any message in moments, offline. A built-in MCP server lets Claude and other agents search the archive on your Mac, read-only, within limits you set.

The archiver only reads from your providers. It never deletes, moves, or marks anything as read on the server.

## Status

Early development. Nothing here is ready to use yet. [STATUS.md](STATUS.md) says where the work stands, and [ROADMAP.md](ROADMAP.md) says what comes next.

## Primary Features

- **Search.** Every word in every message and attachment, ranked, as you type, in every language your providers serve, with filters, a timeline, saved searches, and optional on-device semantic search.
- **Agent access.** A local, read-only MCP server so your agents can search and read the archive through the same engine.
- **Complete, incremental sync** from the twenty largest email providers and any standards-compliant IMAP or JMAP server.
- **Open formats.** `.eml` files plus a documented SQLite index; import and export mbox, Maildir, Apple Mail, Google Takeout, and more.
- **Private by design.** Everything stays on your Mac. Credentials live in the macOS Keychain or a 1Password vault you choose. HTML mail renders with no scripts and no remote content.

## Documents

| Document | What it covers |
| --- | --- |
| [ROADMAP.md](ROADMAP.md) | Milestones, each with what it delivers and when it is done |
| [STATUS.md](STATUS.md) | Current milestone, last done, next step, what is blocked |
| [docs/DESIGN.md](docs/DESIGN.md) | Architecture: storage, search, sync, credentials, MCP, viewer, security, distribution |
| [docs/PROVIDERS.md](docs/PROVIDERS.md) | The twenty providers: access, sign-in, limits, quirks, and generic IMAP |
| [docs/TESTING.md](docs/TESTING.md) | How every layer is tested, and the performance and relevance budgets |
| [docs/decisions/](docs/decisions/) | Decision records |
| [AGENTS.md](AGENTS.md) | Rules for anyone changing this repository |

## Building

Requires macOS 14 or later and Xcode 16 or later, or Swift 6 on Linux for the core packages.

```sh
scripts/check.sh
```

runs exactly what CI runs.

## License

Copyright © 2026 Bristlecone IT Services, LLC. All rights reserved. See [LICENSE](LICENSE). The source is visible here for now; it is not open source.
