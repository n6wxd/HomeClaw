#!/bin/bash
set -euo pipefail

# HomeClaw — Archive for TestFlight / App Store
# Generates the Xcode project from project.yml, builds HomeClawHelper
# separately as Mac Catalyst, then archives the main app.
# Open the resulting .xcarchive in Xcode Organizer to distribute.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HomeClaw"
HELPER_PROJECT="$PROJECT_ROOT/Sources/HomeClawHelper"
DERIVED_DATA="$PROJECT_ROOT/.build/DerivedData"

# ─── Load configuration ─────────────────────────────────────

if [[ -f "$PROJECT_ROOT/.env.local" ]]; then
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/.env.local"
fi
TEAM_ID="${HOMEKIT_TEAM_ID:-}"
export HOMEKIT_TEAM_ID="$TEAM_ID"

if [[ -z "$TEAM_ID" || "$TEAM_ID" == "YOUR_TEAM_ID" ]]; then
    echo "Error: No Apple Developer Team ID specified." >&2
    echo "  Set HOMEKIT_TEAM_ID in .env.local or your environment." >&2
    exit 1
fi

# ─── Helpers ─────────────────────────────────────────────────

bold()  { printf "\033[1m%s\033[0m" "$1"; }
green() { printf "\033[32m✓\033[0m"; }

# ─── Derive version and build number ─────────────────────────

GIT_TAG=$(git -C "$PROJECT_ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo "v0.0.1")
MARKETING_VERSION="${GIT_TAG#v}"

# Auto-incrementing build number persisted in .build-number
BUILD_NUMBER_FILE="$PROJECT_ROOT/.build-number"
if [[ -f "$BUILD_NUMBER_FILE" ]]; then
    BUILD_NUMBER=$(( $(cat "$BUILD_NUMBER_FILE") + 1 ))
else
    # Seed from git commit count on first run
    BUILD_NUMBER=$(git -C "$PROJECT_ROOT" rev-list --count HEAD)
fi
echo "$BUILD_NUMBER" > "$BUILD_NUMBER_FILE"

ARCHIVE_PATH="$PROJECT_ROOT/.build/archives/$APP_NAME.xcarchive"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            cat <<EOF
Usage: scripts/archive.sh [options]

Creates an .xcarchive that can be distributed via Xcode Organizer.

Options:
  --help      Show this help

Environment:
  HOMEKIT_TEAM_ID   Apple Developer Team ID (required, or set in .env.local)

After archiving, open in Xcode Organizer to submit to TestFlight:
  open '.build/archives/HomeClaw.xcarchive'
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo ""
echo "$(bold "Archiving $APP_NAME...") v$MARKETING_VERSION build $BUILD_NUMBER"
echo ""

# ─── Step 1: Generate Xcode projects ─────────────────────────

echo "  [1/4] Generating Xcode projects..."
if ! command -v xcodegen &>/dev/null; then
    echo "Error: xcodegen not installed. Install with: brew install xcodegen" >&2
    exit 1
fi

# Generate root project (homeclaw + homeclaw-cli, macOS)
xcodegen generate --spec "$PROJECT_ROOT/project.yml" --project "$PROJECT_ROOT" --use-cache 2>/dev/null

# Generate helper project (Mac Catalyst) if needed
if [[ ! -d "$HELPER_PROJECT/HomeClawHelper.xcodeproj" ]]; then
    xcodegen generate --spec "$HELPER_PROJECT/project.yml" --project "$HELPER_PROJECT" 2>/dev/null
fi
printf "  %s\n" "$(green)"

# ─── Step 2: Build MCP server ───────────────────────────────

echo "  [2/4] Building MCP server..."
if command -v node &>/dev/null && [[ -f "$PROJECT_ROOT/mcp-server/build.mjs" ]]; then
    cd "$PROJECT_ROOT" && npm run build:mcp 2>/dev/null
fi
printf "  %s\n" "$(green)"

# ─── Step 3: Build HomeClawHelper (Mac Catalyst) ─────────────

echo "  [3/4] Building HomeClawHelper (Catalyst)..."

# Verify HomeKit entitlement exists before building
HELPER_ENTITLEMENTS="$HELPER_PROJECT/HomeClawHelper.entitlements"
if ! grep -q 'com.apple.developer.homekit' "$HELPER_ENTITLEMENTS" 2>/dev/null; then
    echo "Error: HomeKit entitlement missing from $HELPER_ENTITLEMENTS" >&2
    exit 1
fi

xcodebuild build \
    -project "$HELPER_PROJECT/HomeClawHelper.xcodeproj" \
    -scheme HomeClawHelper \
    -configuration Release \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    ONLY_ACTIVE_ARCH=NO \
    -quiet

printf "  %s\n" "$(green)"

# ─── Step 4: Archive main app ─────────────────────────────────

echo "  [4/4] Creating archive..."
rm -rf "$ARCHIVE_PATH"

xcodebuild archive \
    -project "$PROJECT_ROOT/$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=macOS' \
    -allowProvisioningUpdates \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    ONLY_ACTIVE_ARCH=NO \
    -quiet

printf "  %s\n" "$(green)"

# ─── Summary ────────────────────────────────────────────────

echo ""
echo "$(bold "Archive:") $ARCHIVE_PATH"
echo "$(bold "Version:") $MARKETING_VERSION ($BUILD_NUMBER)"
echo ""

# Verify the bundle structure
APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
if [[ -d "$APP_PATH" ]]; then
    echo "Bundle contents:"
    [[ -f "$APP_PATH/Contents/MacOS/homeclaw" ]]     && echo "  $(green) Contents/MacOS/homeclaw"
    [[ -f "$APP_PATH/Contents/MacOS/homeclaw-cli" ]]  && echo "  $(green) Contents/MacOS/homeclaw-cli"
    [[ -d "$APP_PATH/Contents/Helpers/HomeClawHelper.app" ]] && echo "  $(green) Contents/Helpers/HomeClawHelper.app"
    [[ -f "$APP_PATH/Contents/Resources/mcp-server.js" ]]   && echo "  $(green) Contents/Resources/mcp-server.js"
    [[ -d "$APP_PATH/Contents/Resources/openclaw" ]]         && echo "  $(green) Contents/Resources/openclaw/"

    # Verify HomeKit entitlement on helper
    if codesign -d --entitlements :- "$APP_PATH/Contents/Helpers/HomeClawHelper.app" 2>/dev/null | grep -q "com.apple.developer.homekit"; then
        echo "  $(green) HomeKit entitlement on helper"
    else
        echo "  Warning: HomeKit entitlement missing on helper!"
    fi
    echo ""
fi

echo "$(bold "Done!") Open in Xcode Organizer to submit to TestFlight:"
echo "  open '$ARCHIVE_PATH'"
echo ""
