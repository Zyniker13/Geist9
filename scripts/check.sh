#!/bin/bash
# Runs exactly what CI runs. Keep it and .github/workflows/ci.yml identical in what they check.
set -euo pipefail
cd "$(dirname "$0")/.."

# CI renders step summaries publicly, so failed build/test output lands there
# even without API-log access.
SUMMARY="${GITHUB_STEP_SUMMARY:-}"
if [[ -n "$SUMMARY" ]]; then
  tail_summary() {
    echo '```' >> "$SUMMARY"
    tail -80 "$1" >> "$SUMMARY" 2>/dev/null || true
    echo '```' >> "$SUMMARY"
  }
  run_logged() {
    local log="/tmp/check-$$.log"
    if "$@" >"$log" 2>&1; then
      rm -f "$log"
      return 0
    fi
    echo "### Failed: $*" >> "$SUMMARY"
    tail_summary "$log"
    rm -f "$log"
    return 1
  }
else
  run_logged() { "$@"; }
fi

echo "== Swift build and tests"
run_logged swift build
run_logged swift test --parallel

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
