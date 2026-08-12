#!/bin/bash
set -euo pipefail

# Build script for AgentUsageBar.
#
# Signing: when AgentUsageBar Dev exists, the default uses it so rebuilt apps keep the
# same Keychain identity. Set CODESIGN_IDENTITY to a Developer ID for distribution, or
# to "-" to request an ad-hoc build explicitly. Ad-hoc signatures cannot be notarized.
#
# Pass --no-launch to skip opening the app at the end (useful in a build loop).

APP_NAME="AgentUsageBar"
BUNDLE="${APP_NAME}.app"
APP_PATH="build/${BUNDLE}"
DEPLOYMENT_TARGET="14.0"
LOCAL_SIGNING_IDENTITY="AgentUsageBar Dev"
if [ -z "${CODESIGN_IDENTITY+x}" ]; then
    signing_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    case "$signing_identities" in
        *\"$LOCAL_SIGNING_IDENTITY\"*) CODESIGN_IDENTITY="$LOCAL_SIGNING_IDENTITY" ;;
        *) CODESIGN_IDENTITY="-" ;;
    esac
fi
LAUNCH=1
[ "${1:-}" = "--no-launch" ] && LAUNCH=0

SOURCES=(
    AgentUsageBar.swift
    AppState.swift
    Models.swift
    Support.swift
    StatusManager.swift
    MenuBarController.swift
    UsageView.swift
    Providers/ClaudeProvider.swift
    Providers/CodexProvider.swift
)

FRAMEWORKS=(AppKit Carbon UserNotifications ServiceManagement Security)

cd "$(dirname "$0")"

echo "Building ${APP_NAME}..."

# Fresh build dir: stale bundles accumulate extended attributes from prior signings,
# which codesign then rejects as "resource fork / detritus".
rm -rf build
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

cp Info.plist "$APP_PATH/Contents/"

if [ -f "${APP_NAME}.icns" ]; then
    cp "${APP_NAME}.icns" "$APP_PATH/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile ${APP_NAME}" "$APP_PATH/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string ${APP_NAME}" "$APP_PATH/Contents/Info.plist"
fi

framework_flags=()
for fw in "${FRAMEWORKS[@]}"; do framework_flags+=(-framework "$fw"); done

for arch in arm64 x86_64; do
    echo "  compiling ${arch}..."
    swiftc -parse-as-library -O \
        -o "$APP_PATH/Contents/MacOS/${APP_NAME}_${arch}" \
        "${SOURCES[@]}" \
        "${framework_flags[@]}" \
        -target "${arch}-apple-macos${DEPLOYMENT_TARGET}"
done

lipo -create -output "$APP_PATH/Contents/MacOS/${APP_NAME}" \
    "$APP_PATH/Contents/MacOS/${APP_NAME}_arm64" \
    "$APP_PATH/Contents/MacOS/${APP_NAME}_x86_64"
rm "$APP_PATH/Contents/MacOS/${APP_NAME}_arm64" "$APP_PATH/Contents/MacOS/${APP_NAME}_x86_64"

printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"
chmod 755 "$APP_PATH/Contents/MacOS/${APP_NAME}"

# Strip anything codesign treats as detritus.
xattr -cr "$APP_PATH"
find "$APP_PATH" -name '._*' -delete 2>/dev/null || true
find "$APP_PATH" -name '.DS_Store' -delete 2>/dev/null || true

if [ "$CODESIGN_IDENTITY" = "-" ]; then
    echo "  signing ad-hoc (run make_signing_cert.sh for stable Keychain access)"
    codesign --force --options runtime --sign - "$APP_PATH"
else
    echo "  signing as ${CODESIGN_IDENTITY}"
    # An explicitly requested identity that cannot be used is a hard error: silently
    # falling back to ad-hoc would only surface later, at notarization.
    if ! codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$APP_PATH"; then
        echo "!! Signing with '${CODESIGN_IDENTITY}' failed. Not falling back to ad-hoc." >&2
        exit 1
    fi
fi
# Captured rather than piped: `| grep -q` closes the pipe early, and under pipefail
# codesign's resulting SIGPIPE reads as a verification failure.
verify_output="$(codesign --verify --verbose=2 "$APP_PATH" 2>&1 || true)"
case "$verify_output" in
    *"valid on disk"*) ;;
    *)
        echo "!! Signature verification failed:" >&2
        echo "$verify_output" >&2
        exit 1
        ;;
esac

echo "Built ${APP_PATH}"
[ "$LAUNCH" = "1" ] && open "$APP_PATH"
exit 0
