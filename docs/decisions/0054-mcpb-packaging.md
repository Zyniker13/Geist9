# 0054: MCP bundle (.mcpb) packaging

Date: 2026-11-21

## Context

ROADMAP M3 calls for a Claude Desktop extension (`.mcpb`) alongside the
copyable configuration for other MCP clients (DESIGN 9A). An `.mcpb` is a
zip: `manifest.json` at the root plus the server artifact. Claude Desktop
unpacks it, asks the person any `user_config` questions the manifest
declares, interpolates them into the launch configuration, and starts the
server from inside the unpacked folder.

The helper takes its inputs from the environment: `ARCHIVE_PATH` (the
archive to open) and `BRISTLECONE_ACCESS_POLICY` (the policy file,
decision 0053). A bundle cannot know either path in advance — the archive
belongs to the person, and the policy lives in the app's Application
Support folder.

## Decision

`scripts/make-mcpb.sh` builds the helper as a macOS universal binary
(arm64 + x86_64, Release), stages it next to a manifest, and zips the two
into `build/bristlecone-email-archiver.mcpb`. The manifest:

- declares the helper as a `binary` server, entry point
  `email-archiver-mcp`, launched via `${__dirname}/email-archiver-mcp`;
- asks the person for their archive folder as a required `user_config`
  string and passes it as `ARCHIVE_PATH`;
- sets no policy path: the helper resolves the policy the same way for
  every launch — the client's `BRISTLECONE_ACCESS_POLICY` when set,
  otherwise the app's standard policy location
  (`~/Library/Application Support/Bristlecone/Agents/policy.json` on
  macOS), otherwise the permissive default as before. A standard-location
  file that exists but cannot be read or decoded refuses the launch, like
  a bad explicit path does.

The bundle deliberately does not contain a policy: the policy file stays
the single channel (0053), so the app's Settings choices — including the
master switch — govern every client, whether launched with an explicit
path or from the bundle.

The output artifact is a build product: not committed, reproducible from
the script. Windows and Linux helper builds for the bundle are future
work (STATUS.md); Claude Desktop runs on macOS and Windows.

## Consequences

- One install step for the primary MCP client, and the person's exposure
  choices made in the app apply to it without a second configuration.
- A person who installed the bundle but never configured agents gets the
  permissive default, exactly as a client launched by hand without a
  policy path does today; the app-side master switch starts at off and
  writes the file as soon as Settings saves any choice.
- The helper's policy resolution gains a second source (the standard
  location), so it needs the same unit and end-to-end coverage the
  explicit path already has: standard location wins over the permissive
  default, a disabled standard-location policy refuses requests, and an
  explicit `BRISTLECONE_ACCESS_POLICY` still overrides both.
- The standard location is derived from `HOME` (passwd entry as fallback),
  not from the Cocoa Application Support lookup: that lookup ignores
  `HOME` for a bundle-less tool, so a helper launched with a controlled
  environment would read the wrong user's directory. The end-to-end tests
  pin this by launching the helper with `HOME` pointed at a folder whose
  Library/Application Support holds the policy.
- The bundle is rebuilt whenever the helper changes; nothing in the repo
  pins a stale binary.
