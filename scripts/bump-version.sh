#!/bin/bash
set -euo pipefail

# bump-version.sh — Update version across all HomeKit Bridge files
#
# Usage: scripts/bump-version.sh 0.2.0

if [[ $# -ne 1 ]]; then
    echo "Usage: scripts/bump-version.sh <version>"
    echo "Example: scripts/bump-version.sh 0.2.0"
    exit 1
fi

VERSION="$1"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Validate version format (semver: X.Y.Z)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Version must be in semver format (e.g., 0.2.0)"
    exit 1
fi

echo "Bumping version to $VERSION"
echo ""

update_file() {
    local file="$1"
    local description="$2"
    local relative="${file#$PROJECT_ROOT/}"

    if [[ ! -f "$file" ]]; then
        echo "  SKIP  $relative (not found)"
        return
    fi

    echo "  OK    $relative — $description"
}

# 1. AppConfig.swift — version = "X.Y.Z"
FILE="$PROJECT_ROOT/Sources/homekit-mcp/Shared/AppConfig.swift"
sed -i '' "s/static let version = \"[^\"]*\"/static let version = \"$VERSION\"/" "$FILE"
update_file "$FILE" "Swift app version"

# 2. Resources/Info.plist — CFBundleShortVersionString
FILE="$PROJECT_ROOT/Resources/Info.plist"
sed -i '' "/<key>CFBundleShortVersionString<\/key>/{ n; s/<string>[^<]*<\/string>/<string>$VERSION<\/string>/; }" "$FILE"
update_file "$FILE" "Main bundle version"

# 3. HomeKitHelper/Info.plist — CFBundleShortVersionString
FILE="$PROJECT_ROOT/Sources/HomeKitHelper/Info.plist"
sed -i '' "/<key>CFBundleShortVersionString<\/key>/{ n; s/<string>[^<]*<\/string>/<string>$VERSION<\/string>/; }" "$FILE"
update_file "$FILE" "Helper bundle version"

# 4. package.json (root)
FILE="$PROJECT_ROOT/package.json"
sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" "$FILE"
update_file "$FILE" "Root npm package"

# 5. openclaw/package.json
FILE="$PROJECT_ROOT/openclaw/package.json"
sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" "$FILE"
update_file "$FILE" "OpenClaw plugin (homeclaw)"

# 6. mcp-server/package.json
FILE="$PROJECT_ROOT/mcp-server/package.json"
sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" "$FILE"
update_file "$FILE" "MCP server package"

# 7. .claude-plugin/plugin.json
FILE="$PROJECT_ROOT/.claude-plugin/plugin.json"
sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" "$FILE"
update_file "$FILE" "Claude Code plugin"

# 8. .claude-plugin/marketplace.json
FILE="$PROJECT_ROOT/.claude-plugin/marketplace.json"
sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" "$FILE"
update_file "$FILE" "Claude marketplace"

# 9. mcp-server/server.js — version in Server constructor
FILE="$PROJECT_ROOT/mcp-server/server.js"
if [[ -f "$FILE" ]]; then
    sed -i '' "s/version: '[^']*'/version: '$VERSION'/" "$FILE"
    update_file "$FILE" "MCP server JS version"
fi

echo ""
echo "All files updated to v$VERSION"
echo ""
echo "Next steps:"
echo "  git add -A && git commit -m \"Bump version to $VERSION\""
echo "  git tag v$VERSION"
