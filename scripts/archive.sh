#!/bin/bash
set -euo pipefail

# HomeClaw — Archive for TestFlight / App Store
# Generates the Xcode project from project.yml, then archives the
# unified Mac Catalyst app. Open the resulting .xcarchive in Xcode
# Organizer to distribute.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HomeClaw"

# Load local configuration (Team ID, etc.)
if [[ -f "$PROJECT_ROOT/.env.local" ]]; then
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/.env.local"
fi
TEAM_ID="${HOMEKIT_TEAM_ID:-}"

# ─── Helpers ─────────────────────────────────────────────────

bold()  { printf "\033[1m%s\033[0m" "$1"; }
green() { printf "\033[32m✓\033[0m"; }

# ─── Derive version and build number ─────────────────────────

GIT_TAG=$(git -C "$PROJECT_ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo "v0.0.1")
MARKETING_VERSION="${GIT_TAG#v}"

BUILD_NUMBER_FILE="$PROJECT_ROOT/.build-number"
if [[ -f "$BUILD_NUMBER_FILE" ]]; then
    BUILD_NUMBER=$(( $(cat "$BUILD_NUMBER_FILE") + 1 ))
else
    BUILD_NUMBER=$(git -C "$PROJECT_ROOT" rev-list --count HEAD)
fi

ARCHIVE_PATH="$PROJECT_ROOT/.build/archives/$APP_NAME.xcarchive"
EXPORT_PATH="$PROJECT_ROOT/.build/export"
DO_UPLOAD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --upload)
            DO_UPLOAD=true
            shift
            ;;
        --team-id)
            TEAM_ID="$2"
            shift 2
            ;;
        --help|-h)
            cat <<EOF
Usage: scripts/archive.sh [options]

Creates an .xcarchive that can be distributed via Xcode Organizer.

Options:
  --upload      Export and upload to App Store Connect after archiving
  --team-id ID  Apple Developer Team ID (or set HOMEKIT_TEAM_ID)
  --help        Show this help

After archiving, open in Xcode Organizer to submit to TestFlight:
  open '.build/archives/HomeClaw.xcarchive'
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Resolve team ID ─────────────────────────────────────────

if [[ -z "$TEAM_ID" || "$TEAM_ID" == "YOUR_TEAM_ID" ]]; then
    echo "Error: No Apple Developer Team ID specified." >&2
    echo "  Use --team-id YOUR_ID or set HOMEKIT_TEAM_ID in your environment." >&2
    echo "  Find your Team ID at https://developer.apple.com/account#MembershipDetailsCard" >&2
    exit 1
fi

echo ""
echo "$(bold "Archiving $APP_NAME...") v$MARKETING_VERSION build $BUILD_NUMBER"
echo ""

# ─── Step 1: Generate Xcode project ─────────────────────────

if $DO_UPLOAD; then
    TOTAL_STEPS=4
else
    TOTAL_STEPS=3
fi

echo "  [1/$TOTAL_STEPS] Generating Xcode project..."
if ! command -v xcodegen &>/dev/null; then
    echo "Error: xcodegen not installed. Install with: brew install xcodegen" >&2
    exit 1
fi
xcodegen generate --spec "$PROJECT_ROOT/project.yml" --project "$PROJECT_ROOT" --use-cache 2>/dev/null
printf "  %s\n" "$(green)"

# ─── Step 2: Build MCP server ───────────────────────────────

echo "  [2/$TOTAL_STEPS] Building MCP server..."
if command -v node &>/dev/null && [[ -f "$PROJECT_ROOT/mcp-server/build.mjs" ]]; then
    cd "$PROJECT_ROOT" && npm run build:mcp 2>/dev/null
fi
printf "  %s\n" "$(green)"

# ─── Step 3: Archive ─────────────────────────────────────────

echo "  [3/$TOTAL_STEPS] Creating archive..."

# Verify HomeKit entitlement exists
ENTITLEMENTS="$PROJECT_ROOT/Resources/HomeClaw.entitlements"
if ! grep -q 'com.apple.developer.homekit' "$ENTITLEMENTS" 2>/dev/null; then
    echo "Error: HomeKit entitlement missing from $ENTITLEMENTS" >&2
    exit 1
fi

rm -rf "$ARCHIVE_PATH"

xcodebuild archive \
    -project "$PROJECT_ROOT/$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=macOS,variant=Mac Catalyst' \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" \
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
    [[ -f "$APP_PATH/Contents/MacOS/HomeClaw" ]]          && echo "  $(green) Contents/MacOS/HomeClaw"
    [[ -f "$APP_PATH/Contents/MacOS/homeclaw-cli" ]]      && echo "  $(green) Contents/MacOS/homeclaw-cli"
    [[ -d "$APP_PATH/Contents/Resources/macOSBridge.bundle" ]] && echo "  $(green) Contents/Resources/macOSBridge.bundle"
    [[ -f "$APP_PATH/Contents/Resources/mcp-server.js" ]] && echo "  $(green) Contents/Resources/mcp-server.js"
    [[ -d "$APP_PATH/Contents/Resources/openclaw" ]]       && echo "  $(green) Contents/Resources/openclaw/"

    # Verify HomeKit entitlement
    if codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | grep -q "com.apple.developer.homekit"; then
        echo "  $(green) HomeKit entitlement present"
    else
        echo "  Warning: HomeKit entitlement missing!"
    fi
    echo ""
fi

# ─── Step 4 (optional): Export & Upload ──────────────────────

if $DO_UPLOAD; then
    echo "  [4/$TOTAL_STEPS] Exporting and uploading to App Store Connect..."

    rm -rf "$EXPORT_PATH"

    # Generate ExportOptions with team ID injected
    EXPORT_OPTIONS="$PROJECT_ROOT/.build/ExportOptions.plist"
    /usr/libexec/PlistBuddy -c "Clear dict" "$EXPORT_OPTIONS" 2>/dev/null || true
    cp "$PROJECT_ROOT/ExportOptions.plist" "$EXPORT_OPTIONS"
    /usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS"

    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -exportPath "$EXPORT_PATH" \
        -allowProvisioningUpdates

    printf "  %s\n" "$(green)"
    echo ""
    echo "$(bold "Done!") Build uploaded to App Store Connect."
    echo "Check TestFlight status at: https://appstoreconnect.apple.com/apps/6759682551/testflight"
else
    echo "$(bold "Done!") Open in Xcode Organizer to submit to TestFlight:"
    echo "  open '$ARCHIVE_PATH'"
    echo ""
    echo "Or upload directly:"
    echo "  scripts/archive.sh --upload"
fi
echo ""
