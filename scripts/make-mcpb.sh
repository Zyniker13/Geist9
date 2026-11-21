#!/bin/bash
# Package the MCP helper as an .mcpb (MCP bundle) for one-click install into
# Claude Desktop (ROADMAP M3). The bundle is a zip with manifest.json at its
# root and the helper binary next to it; the manifest asks the person for
# their archive folder at install time (${user_config.archive_path}) and
# launches the helper from inside the unpacked bundle. The access policy is
# not part of the bundle: the helper reads the app's policy file (the single
# channel, decision 0053), falling back to the standard location when the
# client does not set BRISTLECONE_ACCESS_POLICY.
#
# The helper is built as a macOS universal binary (arm64 + x86_64) in
# Release configuration. Claude Desktop runs on macOS and Windows; Windows
# and Linux builds of the helper are future work (STATUS.md).
#
# Usage: scripts/make-mcpb.sh [output.mcpb]
# Output default: build/bristlecone-email-archiver.mcpb (build/ is ignored).

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/.*MARKETING_VERSION: \([0-9.]*\).*/\1/p' project.yml | head -1)"
test -n "$VERSION" || { echo "no MARKETING_VERSION in project.yml"; exit 1; }

OUT="${1:-build/bristlecone-email-archiver.mcpb}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "== build universal helper (release)"
swift build --configuration release --product email-archiver-mcp \
    --arch arm64 --arch x86_64
HELPER="$(swift build --configuration release --product email-archiver-mcp \
    --arch arm64 --arch x86_64 --show-bin-path)/email-archiver-mcp"
test -x "$HELPER" || { echo "helper missing: $HELPER"; exit 1; }
cp "$HELPER" "$STAGE/email-archiver-mcp"
chmod +x "$STAGE/email-archiver-mcp"

echo "== manifest $VERSION"
cat > "$STAGE/manifest.json" <<EOF
{
  "dxt_version": "0.1",
  "name": "bristlecone-email-archiver",
  "display_name": "Bristlecone Email Archiver",
  "version": "$VERSION",
  "description": "Search and read your Bristlecone Email Archiver archive from Claude. Read-only: the helper never changes your archive or your mail server, and your exposure choices from the app's Settings apply.",
  "author": {
    "name": "Bristlecone"
  },
  "server": {
    "type": "binary",
    "entry_point": "email-archiver-mcp",
    "mcp_config": {
      "command": "\${__dirname}/email-archiver-mcp",
      "env": {
        "ARCHIVE_PATH": "\${user_config.archive_path}"
      }
    }
  },
  "user_config": {
    "archive_path": {
      "type": "string",
      "title": "Archive folder",
      "description": "The folder of the archive to search. Open it in the Bristlecone app once and copy the path from Settings > Agents.",
      "required": true,
      "multiple": false,
      "sensitive": false
    }
  }
}
EOF

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
(cd "$STAGE" && zip -q -r "$OLDPWD/$OUT" manifest.json email-archiver-mcp)

echo "== contents"
unzip -l "$OUT"
echo "== wrote $OUT (version $VERSION)"
