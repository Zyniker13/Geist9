#!/bin/bash
# MCP inspector gate (DESIGN 9A / ROADMAP M3): drives the built stdio helper
# with the official @modelcontextprotocol/inspector CLI and checks the
# contract the e2e tests pin: the ten tools, the resource templates, a real
# resources/read with untrusted-content fences, and the -32601 unknown-tool
# error form. Exits non-zero on any deviation.
#
# Requires node >= 22.7.5 (the inspector's engines field). check.sh builds the
# products (email-archiver-mcp, mcp-fixture-builder) before invoking this.
set -euo pipefail
cd "$(dirname "$0")/.."

INSPECTOR_VERSION=0.16.2
FIXTURE="$(mktemp -d)/fixture.emailarchive"
trap 'rm -rf "$(dirname "$FIXTURE")"' EXIT

echo "== MCP inspector gate"
# 1. Fixture archive, built through the public ingest path.
./.build/debug/mcp-fixture-builder "$FIXTURE"

# 2. tools/list: exactly the ten DESIGN 9A tools.
npx -y "@modelcontextprotocol/inspector@${INSPECTOR_VERSION}" --cli \
  ./.build/debug/email-archiver-mcp -e ARCHIVE_PATH="$FIXTURE" \
  --method tools/list > "$FIXTURE.tools.json"
python3 - "$FIXTURE.tools.json" <<'PY'
import json, sys
tools = {t["name"] for t in json.load(open(sys.argv[1]))["tools"]}
expected = {
    "search_messages", "get_message", "get_thread", "list_accounts",
    "list_folders", "list_labels", "list_attachments",
    "get_attachment_text", "find_contacts", "archive_stats",
}
if tools != expected:
    sys.exit(f"tools/list mismatch: {sorted(tools)} != {sorted(expected)}")
print("tools/list: 10 tools")
PY

# 3. search_messages through the real index, and the fence around the hit.
# Parse the envelope: the hit fields live inside structuredContent, where the
# fence markers survive only as JSON string values.
npx -y "@modelcontextprotocol/inspector@${INSPECTOR_VERSION}" --cli \
  ./.build/debug/email-archiver-mcp -e ARCHIVE_PATH="$FIXTURE" \
  --method tools/call --tool-name search_messages \
  --tool-arg "query=lease" --tool-arg "limit=10" > "$FIXTURE.search.json"
python3 - "$FIXTURE.search.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
hits = d["structuredContent"]["messages"]
if not hits:
    sys.exit("search_messages returned no hits for 'lease'")
subject = hits[0]["subject"]
if "BEGIN UNTRUSTED CONTENT (subject)" not in subject or "Lease renewal" not in subject:
    sys.exit(f"search hit subject not fenced: {subject!r}")
print("search_messages: fenced hit")
PY

# 4. resources/read of a message document, fenced on every surface.
# The envelope's text field is itself a JSON document; parse it rather than
# grepping escaped quotes.
npx -y "@modelcontextprotocol/inspector@${INSPECTOR_VERSION}" --cli \
  ./.build/debug/email-archiver-mcp -e ARCHIVE_PATH="$FIXTURE" \
  --method resources/read --uri "emailarchiver://message/1" > "$FIXTURE.read.json"
python3 - "$FIXTURE.read.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
doc = json.loads(d["contents"][0]["text"])
if doc.get("thread_id") != 1:
    sys.exit(f"message document missing its thread link: {doc.get('thread_id')}")
fences = {
    "from": doc["from"], "subject": doc["subject"], "message body": doc["body"],
}
for kind, value in fences.items():
    if f"BEGIN UNTRUSTED CONTENT ({kind})" not in value:
        sys.exit(f"missing fence ({kind}) in resources/read")
    if f"END UNTRUSTED CONTENT ({kind})" not in value:
        sys.exit(f"missing fence end ({kind}) in resources/read")
print("resources/read: fenced document")
PY

# 5. Unknown tool must fail with the -32601 method-not-found error form.
if npx -y "@modelcontextprotocol/inspector@${INSPECTOR_VERSION}" --cli \
  ./.build/debug/email-archiver-mcp -e ARCHIVE_PATH="$FIXTURE" \
  --method tools/call --tool-name no_such_tool > "$FIXTURE.unknown.json" 2>&1; then
  echo "unknown tool unexpectedly succeeded"; exit 1
fi
grep -q -- "-32601" "$FIXTURE.unknown.json" \
  || { echo "unknown tool error was not -32601"; exit 1; }
echo "unknown tool: -32601"

# 6. resources/list: every fixture message and thread is listed.
npx -y "@modelcontextprotocol/inspector@${INSPECTOR_VERSION}" --cli \
  ./.build/debug/email-archiver-mcp -e ARCHIVE_PATH="$FIXTURE" \
  --method resources/list > "$FIXTURE.resources.json"
python3 - "$FIXTURE.resources.json" <<'PY'
import json, sys
uris = {r["uri"] for r in json.load(open(sys.argv[1]))["resources"]}
expected = {
    "emailarchiver://message/1", "emailarchiver://message/2",
    "emailarchiver://message/3", "emailarchiver://thread/1",
    "emailarchiver://thread/2",
}
if uris != expected:
    sys.exit(f"resources/list mismatch: {sorted(uris)} != {sorted(expected)}")
print("resources/list: 5 resources")
PY

echo "== MCP inspector gate passed"
