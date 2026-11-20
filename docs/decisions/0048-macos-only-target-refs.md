# 0048 — macOS-only target references in dependency lists are `#if`-branched, never `.when`-conditioned

## Context

`bench-search` (decision 0046) links `ArchiveEmbedApple` on macOS only, and decision 0047 added `SearchEval` to the same executable. Both were expressed as `.target(name: ..., condition: .when(platforms: [.macOS]))` entries in the Benchmarks dependency list, and the `SearchEvalTests` test target referenced `ArchiveEmbedApple` unconditionally. macOS CI stayed green while Linux CI failed at manifest evaluation on every push:

```
error: 'geist9': Source files for target ArchiveEmbedApple should be
located under 'Sources/ArchiveEmbedApple', ...
```

## Decision

Any reference to a macOS-only target (`ArchiveEmbedApple`, `ArchiveExtractApple`) from a cross-platform target's dependency list must be branched with `#if os(macOS)` around whole dependency arrays in Package.swift:

```swift
let benchDeps: [Target.Dependency]
#if os(macOS)
benchDeps = ["ArchiveCore", ..., .target(name: "ArchiveEmbedApple")]
#else
benchDeps = ["ArchiveCore", ...]
#endif
```

with the constants declared before first use (Package.swift is a script; a use before the declaration line crashes the manifest at runtime with "missing or empty JSON output").

- `.when(platforms:)` conditions on dependency entries do NOT prevent Linux SwiftPM from validating the referenced target's name, so they are not a substitute.
- Source files of a macOS-only target import it under `#if canImport(<Module>)`; test targets that need it gate their test bodies the same way and `XCTSkip` on other platforms.
- Executable targets that only exist to drive macOS-only phases keep an `#else` stub that fails with a clear message.

## Consequences

- Linux CI evaluates a manifest that never names a nonexistent target; the failure mode above cannot recur.
- Adding a future macOS-only target (Vision OCR, app-support code) follows the same pattern: `#if os(macOS)` arrays, `canImport`-gated imports, stubs elsewhere.
- The conditional-compilation blocks live at top level of Package.swift next to the existing `appleEmbedTargets`/`appleExtractTargets` pattern, keeping one style.
