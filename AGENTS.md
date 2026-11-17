# Working in This Repository

This guide is for anyone, human or agent, changing this repository. Read [README.md](README.md), [ROADMAP.md](ROADMAP.md), and [STATUS.md](STATUS.md) first, then the parts of [docs/DESIGN.md](docs/DESIGN.md), [docs/PROVIDERS.md](docs/PROVIDERS.md), and [docs/TESTING.md](docs/TESTING.md) that your work touches.

## Priorities

Data safety, then security, then correctness, then search quality and speed, then everything else.

- **Data safety:** the archive may be someone's only copy of their mail. Never lose, rewrite, or corrupt a stored message. The original bytes of every message are kept exactly as downloaded.
- **Read-only toward providers:** sync never sets flags, deletes, moves, or appends on a server. Only the explicit Restore feature writes, and only when the person starts it.
- **Search is a primary feature,** with agent access (MCP) the other. A change that makes search slower or less relevant fails the build (see [docs/TESTING.md](docs/TESTING.md)).

## Rules

- Run `scripts/check.sh` before every push. It runs exactly what CI runs; keep the two identical.
- Every change in behavior comes with tests, and every bug fix starts with a regression test that fails without the fix.
- Never skip, disable, or loosen a test, a budget, or a safety check to get CI green. If a test is wrong, fix the test in its own commit and say why.
- Record each significant decision in [docs/decisions/](docs/decisions/) (Context, Decision, Consequences), numbered in order. Decisions already recorded stand until a new record replaces them.
- Keep [STATUS.md](STATUS.md) current: current milestone, last done, next step, blocked on, and a log line.
- Keep claims in the README and docs no stronger than the code and its tests.
- A change to the archive format, the index schema, or an MCP tool's inputs or outputs updates [docs/DESIGN.md](docs/DESIGN.md) and adds a migration or a compatibility test in the same commit.
- Work on `main` in small commits that keep CI green, or on a short-lived branch for a large change. Never force-push or rewrite pushed history.
- Add dependencies only when the gain is clear, from well-known, maintained projects with permissive licenses (MIT, BSD, Apache-2.0, ISC, zlib), pinned to exact versions. No GPL or AGPL code anywhere in the app. Record each dependency in a decision record.
- Pin GitHub Actions to full commit SHAs and keep workflow permissions read-only.
- Swift 6 language mode with strict concurrency. Core packages build and test on Linux as well as macOS; only the app, the viewer, and Apple-only extractors (Vision, PDFKit) are macOS-only.
- Tests never touch real mail accounts, real providers, or anything in the home folder. They use temporary folders and local test servers.

## What Needs the Maintainer

Some steps can only be done by the maintainer: anything needing an Apple Developer account (signing, notarization, App Store Connect), registering OAuth clients with providers, payment and licensing accounts, domains and websites, real test mail accounts, repository settings, and releases. List each under "Needs the Maintainer" in [STATUS.md](STATUS.md), build everything around it that you can (mocks, flags, local test servers), and keep going.

## Public Repository

This repository is public for now, so everything committed here, and every commit message, is visible to anyone, forever, even after it goes private. The code is not open source: [LICENSE](LICENSE) reserves all rights. Never commit:

- secrets of any kind: keys, tokens, passwords, OAuth client secrets, signing material, `.env` contents;
- real email addresses, real messages, or anyone's personal data, including in test fixtures (use `alice@example.com`, `bob@example.org`, and messages you write yourself or take from public corpora with their licenses noted);
- hostnames, IP addresses, or local paths outside the repository, other than the public provider hosts in [docs/PROVIDERS.md](docs/PROVIDERS.md);
- anything about the machines, services, or tools used to develop it.

Commit messages describe the code only.
