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
    # Also emit errors as job annotations: those are readable through the
    # public checks API even when the full log is not.
    grep -E "error:" "$log" | head -20 | while IFS= read -r line; do
      printf '::error::%s\n' "$line"
    done
    rm -f "$log"
    return 1
  }
else
  run_logged() { "$@"; }
fi

# Phase markers with elapsed seconds: the last line printed before a
# stuck run names the phase that hung. Notices become job annotations,
# readable through the public checks API even when the full log is not.
STARTED=$(date +%s)
mark() {
  local at=$(($(date +%s) - STARTED))
  echo "[$at s] $1 $2"
  if [[ -n "$SUMMARY" ]]; then
    printf -- '- %s s: %s %s\n' "$at" "$1" "$2" >> "$SUMMARY"
    printf '::notice::%ss %s %s\n' "$at" "$1" "$2"
  fi
}

echo "== Swift build and tests"
mark swift-build begin
run_logged swift build
mark swift-build done
mark swift-test begin
run_logged swift test --parallel
mark swift-test done

echo "== Docs: every relative link in a Markdown file points at a file that exists"
mark docs begin
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
  mark app begin
  xcodegen generate
  xcodebuild -project EmailArchiver.xcodeproj -scheme EmailArchiver \
    -configuration Debug -destination 'platform=macOS' build \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
  mark app done
fi

echo "== All checks passed"
