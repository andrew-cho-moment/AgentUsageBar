#!/bin/bash
set -euo pipefail

APP_NAME="AgentUsageBar"
BUNDLE_ID="com.andrewcho.agentusagebar"
APP_PATH="build/${APP_NAME}.app"
EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_NAME"
FETCHER="$APP_PATH/Contents/Helpers/AgentUsageFetcher"
CREDENTIAL_HELPER="$APP_PATH/Contents/Helpers/CredentialHelper"
LOGIN_ITEM_HELPER="$APP_PATH/Contents/Helpers/LoginItemHelper"
LOCAL_SIGNING_IDENTITY="AgentUsageBar Dev"

if [ -z "${CODESIGN_IDENTITY+x}" ]; then
    signing_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    case "$signing_identities" in
        *\"$LOCAL_SIGNING_IDENTITY\"*) CODESIGN_IDENTITY="$LOCAL_SIGNING_IDENTITY" ;;
        *) CODESIGN_IDENTITY="-" ;;
    esac
fi

cd "$(dirname "$0")"
rm -rf build
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Helpers" \
    "$APP_PATH/Contents/Resources" build/tests

xcrun clang \
    -arch arm64 \
    -mmacosx-version-min=14.0 \
    -fobjc-arc \
    -Oz \
    -flto \
    -fvisibility=hidden \
    -Wall \
    -Wextra \
    -Werror \
    -framework AppKit \
    -framework Carbon \
    -Wl,-dead_strip \
    -Wl,-x \
    -o "$EXECUTABLE" \
    AgentUsageBar.m \
    FetcherProtocol.m \
    SnapshotCache.c \
    UsagePanelView.m

swiftc \
    -parse-as-library \
    -Osize \
    -whole-module-optimization \
    -lto=llvm-full \
    -Xfrontend -disable-reflection-metadata \
    -Xfrontend -disable-reflection-names \
    -target arm64-apple-macos14.0 \
    -Xlinker -dead_strip \
    -Xlinker -x \
    -o "$FETCHER" \
    FetcherMain.swift \
    StatusFetcher.swift \
    Models.swift \
    FetcherSupport.swift \
    Providers/ClaudeProvider.swift \
    Providers/CodexProvider.swift

xcrun clang \
    -arch arm64 \
    -mmacosx-version-min=14.0 \
    -Oz \
    -flto \
    -fvisibility=hidden \
    -Wall \
    -Wextra \
    -Werror \
    -framework CoreFoundation \
    -framework Security \
    -Wl,-dead_strip \
    -Wl,-x \
    -o "$CREDENTIAL_HELPER" \
    CredentialMain.c

xcrun clang \
    -arch arm64 \
    -mmacosx-version-min=14.0 \
    -fobjc-arc \
    -Oz \
    -flto \
    -fvisibility=hidden \
    -Wall \
    -Wextra \
    -Werror \
    -framework Foundation \
    -framework ServiceManagement \
    -Wl,-dead_strip \
    -Wl,-x \
    -o "$LOGIN_ITEM_HELPER" \
    LoginItemMain.m

xcrun clang \
    -arch arm64 \
    -mmacosx-version-min=14.0 \
    -Oz \
    -Wall \
    -Wextra \
    -Werror \
    -o build/tests/OversizedFetcher \
    tests/OversizedFetcher.c
xcrun clang \
    -arch arm64 \
    -mmacosx-version-min=14.0 \
    -Oz \
    -Wall \
    -Wextra \
    -Werror \
    -o build/tests/ProtocolTests \
    tests/ProtocolTests.m \
    FetcherProtocol.m
build/tests/ProtocolTests build/tests/OversizedFetcher
xcrun clang \
    -arch arm64 \
    -mmacosx-version-min=14.0 \
    -Oz \
    -Wall \
    -Wextra \
    -Werror \
    -o build/tests/SnapshotCacheTests \
    tests/SnapshotCacheTests.c \
    SnapshotCache.c
build/tests/SnapshotCacheTests
xcrun clang \
    -arch arm64 \
    -mmacosx-version-min=14.0 \
    -Oz \
    -Wall \
    -Wextra \
    -Werror \
    -o build/tests/FetcherProtocolHarness \
    tests/FetcherProtocolHarness.m \
    FetcherProtocol.m

cp Info.plist "$APP_PATH/Contents/Info.plist"
cp AgentUsageBar.icns "$APP_PATH/Contents/Resources/AgentUsageBar.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AgentUsageBar" \
    "$APP_PATH/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AgentUsageBar" \
        "$APP_PATH/Contents/Info.plist"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"

xattr -cr "$APP_PATH"
codesign --force --options runtime --identifier "$BUNDLE_ID" \
    --sign "$CODESIGN_IDENTITY" "$FETCHER"
codesign --force --options runtime --identifier "$BUNDLE_ID.credential-helper" \
    --sign "$CODESIGN_IDENTITY" "$CREDENTIAL_HELPER"
codesign --force --options runtime --identifier "$BUNDLE_ID.login-item-helper" \
    --sign "$CODESIGN_IDENTITY" "$LOGIN_ITEM_HELPER"
codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Built $APP_PATH for Apple silicon"
