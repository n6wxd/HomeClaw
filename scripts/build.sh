#!/bin/bash
set -euo pipefail

# HomeKit Bridge — Build & Install Script
# Assembles a proper .app bundle from SPM + Xcode Catalyst builds,
# code-signs everything, and optionally installs to /Applications.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HomeKit Bridge"
BUNDLE_DIR="$PROJECT_ROOT/.build/app"
APP_BUNDLE="$BUNDLE_DIR/$APP_NAME.app"
HELPER_PROJECT="$PROJECT_ROOT/Sources/HomeKitHelper"
TEAM_ID="YOUR_TEAM_ID"

# Defaults
BUILD_CONFIG="release"
DO_INSTALL=false
DO_CLEAN=false
SKIP_HELPER=false

# ─── Helpers ────────────────────────────────────────────────────────

bold()  { printf "\033[1m%s\033[0m" "$1"; }
green() { printf "\033[32m✓\033[0m"; }
red()   { printf "\033[31m✗\033[0m"; }

step() {
    local num="$1" total="$2" label="$3"
    printf "  [%s/%s] %s..." "$num" "$total" "$label"
}

step_done() {
    printf "  %s\n" "$(green)"
}

step_fail() {
    printf "  %s\n" "$(red)"
    echo "Error: $1" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: scripts/build.sh [options]

Options:
  --release       Build in release mode (default)
  --debug         Build in debug mode
  --install       Install to /Applications and symlink CLI
  --clean         Clean build artifacts first
  --skip-helper   Skip building HomeKitHelper (faster iteration)
  --help          Show this help
EOF
    exit 0
}

# ─── Parse arguments ────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)      BUILD_CONFIG="release"; shift ;;
        --debug)        BUILD_CONFIG="debug"; shift ;;
        --install)      DO_INSTALL=true; shift ;;
        --clean)        DO_CLEAN=true; shift ;;
        --skip-helper)  SKIP_HELPER=true; shift ;;
        --help|-h)      usage ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

# ─── Derived paths ──────────────────────────────────────────────────

SPM_BUILD_DIR="$PROJECT_ROOT/.build/$BUILD_CONFIG"
DERIVED_DATA="$PROJECT_ROOT/.build/DerivedData"
CATALYST_PRODUCTS="$DERIVED_DATA/Build/Products/Release-maccatalyst"
if [[ "$BUILD_CONFIG" == "debug" ]]; then
    CATALYST_PRODUCTS="$DERIVED_DATA/Build/Products/Debug-maccatalyst"
fi

# Entitlements paths (used by both build validation and code signing)
MAIN_ENTITLEMENTS="$PROJECT_ROOT/Resources/HomeKitBridge.entitlements"
HELPER_ENTITLEMENTS="$HELPER_PROJECT/HomeKitHelper.entitlements"

# Map SPM config flag
SPM_CONFIG_FLAG="-c $BUILD_CONFIG"

# Map xcodebuild configuration name
XCODE_CONFIG="Release"
if [[ "$BUILD_CONFIG" == "debug" ]]; then
    XCODE_CONFIG="Debug"
fi

# ─── Detect signing identity ───────────────────────────────────────

detect_signing_identity() {
    local identity
    identity=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)".*/\1/')
    if [[ -z "$identity" ]]; then
        echo "Warning: No Apple Development signing identity found. Skipping code signing." >&2
        echo ""
    else
        echo "$identity"
    fi
}

# ─── Total steps ────────────────────────────────────────────────────

TOTAL_STEPS=5
if $SKIP_HELPER; then
    TOTAL_STEPS=4
fi

CURRENT_STEP=0
next_step() { CURRENT_STEP=$((CURRENT_STEP + 1)); }

# ─── Main ───────────────────────────────────────────────────────────

echo ""
echo "$(bold "Building $APP_NAME...") ($BUILD_CONFIG)"
echo ""

# Clean if requested
if $DO_CLEAN; then
    echo "  Cleaning build artifacts..."
    rm -rf "$PROJECT_ROOT/.build"
    echo ""
fi

# Phase 1: Build SPM targets
next_step
step "$CURRENT_STEP" "$TOTAL_STEPS" "Building homekit-mcp ($BUILD_CONFIG)"
if swift build $SPM_CONFIG_FLAG --package-path "$PROJECT_ROOT" --product homekit-mcp 2>/dev/null; then
    step_done
else
    step_fail "swift build --product homekit-mcp failed"
fi

next_step
step "$CURRENT_STEP" "$TOTAL_STEPS" "Building homekit-cli ($BUILD_CONFIG)"
if swift build $SPM_CONFIG_FLAG --package-path "$PROJECT_ROOT" --product homekit-cli 2>/dev/null; then
    step_done
else
    step_fail "swift build --product homekit-cli failed"
fi

# Phase 2: Build HomeKitHelper (Mac Catalyst)
if ! $SKIP_HELPER; then
    next_step
    step "$CURRENT_STEP" "$TOTAL_STEPS" "Building HomeKitHelper (Catalyst)"

    # Ensure xcodeproj exists (regenerate from project.yml if missing)
    if [[ ! -d "$HELPER_PROJECT/HomeKitHelper.xcodeproj" ]]; then
        if command -v xcodegen &>/dev/null; then
            xcodegen generate --spec "$HELPER_PROJECT/project.yml" --project "$HELPER_PROJECT" 2>/dev/null
        else
            step_fail "HomeKitHelper.xcodeproj missing and xcodegen not installed. Install with: brew install xcodegen"
        fi
    fi

    # Safety check: verify HomeKit entitlement exists before building.
    # XcodeGen can silently strip it if project.yml is misconfigured.
    if ! grep -q 'com.apple.developer.homekit' "$HELPER_ENTITLEMENTS" 2>/dev/null; then
        step_fail "HomeKit entitlement missing from $HELPER_ENTITLEMENTS — readValue() will silently fail. Check project.yml entitlements.properties."
    fi

    if xcodebuild -project "$HELPER_PROJECT/HomeKitHelper.xcodeproj" \
        -scheme HomeKitHelper \
        -configuration "$XCODE_CONFIG" \
        -destination 'platform=macOS,variant=Mac Catalyst' \
        -derivedDataPath "$DERIVED_DATA" \
        ONLY_ACTIVE_ARCH=NO \
        -quiet 2>/dev/null; then
        step_done
    else
        step_fail "xcodebuild HomeKitHelper failed"
    fi
fi

# Phase 3: Assemble .app bundle
next_step
step "$CURRENT_STEP" "$TOTAL_STEPS" "Assembling app bundle"

# Clean previous bundle
rm -rf "$APP_BUNDLE"

# Create directory structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Helpers"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy Info.plist
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copy app icon
if [[ -f "$PROJECT_ROOT/Resources/HomeClaw.icns" ]]; then
    cp "$PROJECT_ROOT/Resources/HomeClaw.icns" "$APP_BUNDLE/Contents/Resources/HomeClaw.icns"
fi

# Copy main executable
cp "$SPM_BUILD_DIR/homekit-mcp" "$APP_BUNDLE/Contents/MacOS/homekit-mcp"

# Copy HomeKitHelper.app (entire bundle)
if ! $SKIP_HELPER; then
    if [[ -d "$CATALYST_PRODUCTS/HomeKitHelper.app" ]]; then
        cp -R "$CATALYST_PRODUCTS/HomeKitHelper.app" "$APP_BUNDLE/Contents/Helpers/HomeKitHelper.app"
    else
        step_fail "HomeKitHelper.app not found at $CATALYST_PRODUCTS/HomeKitHelper.app"
    fi
fi

step_done

# Phase 4: Code sign
next_step
step "$CURRENT_STEP" "$TOTAL_STEPS" "Code signing"

SIGNING_IDENTITY=$(detect_signing_identity)

if [[ -n "$SIGNING_IDENTITY" ]]; then
    # Sign inner-to-outer: helper first, then main executable, then outer bundle.
    # IMPORTANT: The outer bundle must NOT use --deep, otherwise it re-signs the
    # helper with the main app's entitlements, stripping com.apple.developer.homekit.

    if ! $SKIP_HELPER && [[ -d "$APP_BUNDLE/Contents/Helpers/HomeKitHelper.app" ]]; then
        codesign --force --deep --sign "$SIGNING_IDENTITY" \
            --entitlements "$HELPER_ENTITLEMENTS" \
            "$APP_BUNDLE/Contents/Helpers/HomeKitHelper.app" 2>/dev/null
    fi

    codesign --force --sign "$SIGNING_IDENTITY" \
        --entitlements "$MAIN_ENTITLEMENTS" \
        "$APP_BUNDLE/Contents/MacOS/homekit-mcp" 2>/dev/null

    codesign --force --sign "$SIGNING_IDENTITY" \
        --entitlements "$MAIN_ENTITLEMENTS" \
        "$APP_BUNDLE" 2>/dev/null

    step_done
else
    printf "  (skipped — no identity)\n"
fi

# ─── Summary ────────────────────────────────────────────────────────

echo ""
echo "$(bold "Output:") $APP_BUNDLE"
echo ""

# Verify code signature
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    if codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null; then
        echo "  Code signature: valid"
    else
        echo "  Code signature: INVALID (run codesign --verify --deep --strict to diagnose)"
    fi
    echo ""
fi

# ─── Install ────────────────────────────────────────────────────────

if $DO_INSTALL; then
    echo "$(bold "Installing...")"

    # Copy app bundle to /Applications
    if [[ -d "/Applications/$APP_NAME.app" ]]; then
        # Move old version to trash before replacing
        /usr/bin/trash "/Applications/$APP_NAME.app" 2>/dev/null || rm -rf "/Applications/$APP_NAME.app"
    fi
    cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
    echo "  Installed: /Applications/$APP_NAME.app"

    # Symlink CLI to /usr/local/bin (may need sudo)
    if ln -sf "$SPM_BUILD_DIR/homekit-cli" /usr/local/bin/homekit-cli 2>/dev/null; then
        echo "  CLI linked: /usr/local/bin/homekit-cli"
    else
        echo "  CLI symlink needs elevated permissions. Run:"
        echo "    sudo ln -sf '$SPM_BUILD_DIR/homekit-cli' /usr/local/bin/homekit-cli"
    fi

    echo ""
    echo "$(bold "Done!") Launch from /Applications or run: open '/Applications/$APP_NAME.app'"
else
    echo "To install:  scripts/build.sh --install"
    echo "To launch:   open '$APP_BUNDLE'"
fi
echo ""
