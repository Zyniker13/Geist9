#!/bin/bash
# Runs exactly what CI runs. Keep it and .github/workflows/ci.yml identical in what they check.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Swift build and tests"
swift build
swift test --parallel

echo "== Docs: every relative link in a Markdown file points at a file that exists"
python3 - <<'PY'
import pathlib, re, sys
bad = []
for md in pathlib.Path(".").rglob("*.md"):
    if any(p in md.parts for p in (".build", "node_modules")):
        continue
    for target in re.findall(r"\]\(([^)#\s]+)(?:#[^)]*)?\)", md.read_text(encoding="utf-8")):
        if re.match(r"^[a-z]+:", target):
            continue
        if not (md.parent / target).exists():
            bad.append(f"{md}: {target}")
if bad:
    print("Broken links:\n  " + "\n  ".join(bad)); sys.exit(1)
print("ok")
PY

# The app is macOS-only (DESIGN 12): generate its project and build it unsigned.
if [[ "$(uname)" == "Darwin" ]]; then
  echo "== App: XcodeGen generate and build"
  xcodegen generate
  xcodebuild -project EmailArchiver.xcodeproj -scheme EmailArchiver \
    -configuration Debug -destination 'platform=macOS' build \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
fi

echo "== All checks passed"
