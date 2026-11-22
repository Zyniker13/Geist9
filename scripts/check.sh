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
# Both executables must exist as linked products: a plain `swift build` can
# leave a newly added executable unlinked until its product is requested.
run_logged swift build --product email-archiver-mcp --product mcp-fixture-builder --product bench-search
mark swift-build done
# The IMAP integration suite needs a real local server (TESTING.md, Protocol
# row): start GreenMail before the tests, stop it after. Start is idempotent
# and unprivileged; failure to start fails the run loudly.
mark imap-servers begin
run_logged bash scripts/imap-servers.sh start
mark imap-servers done
mark swift-test begin
run_logged swift test --parallel
mark swift-test done
run_logged bash scripts/imap-servers.sh stop

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

  # Official MCP inspector conformance (ROADMAP M3, DESIGN 9A): drive the
  # stdio helper with the inspector CLI. Darwin-only: the Linux CI container
  # has no node; the cross-platform protocol contract is pinned by
  # StdioEndToEndTests, which runs on both platforms.
  echo "== MCP inspector conformance"
  mark inspector begin
  run_logged ./scripts/mcp-inspector-check.sh
  mark inspector done
fi

echo "== All checks passed"
