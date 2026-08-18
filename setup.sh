#!/bin/bash
set -euo pipefail

# Builds AgentUsageBar, installs it to /Applications, and clears the state that
# earlier builds and test bundles leave behind. Re-running it is the update
# path: it replaces the installed copy in place and keeps your settings, which
# live in the com.andrewcho.agentusagebar defaults domain rather than in the
# bundle.
#
#   ./setup.sh          build, install, clean, launch
#   ./setup.sh --clean  clean only, touching neither the build nor the install
#
# The cleanup targets suffixed siblings of the real bundle id. Every test build
# in this project's history took a bundle id like com.andrewcho.agentusagebar
# .panel-harness, and each one made macOS create a shader cache and a defaults
# domain that outlive the build that caused them.

APP_NAME="AgentUsageBar"
BUNDLE_ID="com.andrewcho.agentusagebar"
INSTALL_DIR="/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
SIGNING_IDENTITY="AgentUsageBar Dev"
# Defaults keys the app no longer reads. Add to this list when a feature that
# owned a key is removed, so the next run sweeps it off machines that ran the
# version which wrote it.
DEAD_KEYS=(
    last_effective_indicator
    claude_plan_label
    claude_plan_label_stamp
)

cd "$(dirname "$0")"
CLEAN_ONLY=false
case "${1-}" in
    --clean) CLEAN_ONLY=true ;;
    "") ;;
    *) echo "usage: $0 [--clean]" >&2; exit 2 ;;
esac

say() { printf '\n== %s\n' "$1"; }

clean() {
    local removed=0 cache_dir domain plist key

    # Shader and font caches macOS created for bundle ids that no longer exist.
    # Matching directories alone leaves the live snapshot cache, which is a file
    # named com.andrewcho.agentusagebar.snapshot-v1 in this same directory.
    cache_dir="$(getconf DARWIN_USER_CACHE_DIR)"
    for stale in "$cache_dir$BUNDLE_ID".*/; do
        [ -d "$stale" ] || continue
        rm -rf "$stale"
        echo "  cache   $(basename "$stale")"
        removed=$((removed + 1))
    done

    # Preferences written by those same test bundles. cfprefsd owns the live
    # copy, so the domain goes first and the file after it.
    while read -r domain; do
        [ -n "$domain" ] || continue
        defaults delete "$domain" 2>/dev/null || true
        plist="$HOME/Library/Preferences/$domain.plist"
        [ -f "$plist" ] && rm -f "$plist"
        echo "  domain  $domain"
        removed=$((removed + 1))
    done < <(defaults domains | tr ',' '\n' | sed 's/^ *//' |
        grep -E "^($BUNDLE_ID\.|${APP_NAME}[A-Za-z]+$)" || true)

    # Keys the current app never reads, left in the live domain by features that
    # have since been removed.
    for key in "${DEAD_KEYS[@]}"; do
        if defaults read "$BUNDLE_ID" "$key" >/dev/null 2>&1; then
            defaults delete "$BUNDLE_ID" "$key"
            echo "  key     $key"
            removed=$((removed + 1))
        fi
    done

    while read -r junk; do
        rm -f "$junk"
        echo "  file    ${junk#./}"
        removed=$((removed + 1))
    done < <(find . -name .DS_Store -type f)

    [ "$removed" -eq 0 ] && echo "  nothing stale"
    return 0
}

if [ "$CLEAN_ONLY" = true ]; then
    say "Cleaning"
    clean
    exit 0
fi

say "Checking prerequisites"
xcode-select --print-path >/dev/null 2>&1 ||
    { echo "Xcode command line tools missing: run xcode-select --install" >&2; exit 1; }
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGNING_IDENTITY\""; then
    echo "  signing identity present"
else
    echo "  creating the $SIGNING_IDENTITY signing identity"
    app/make_signing_cert.sh
fi

say "Building"
app/build.sh

say "Installing to $INSTALL_DIR"
# Any running copy, including one launched straight out of app/build during
# development, holds the bundle this replaces.
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
for attempt in 1 2 3 4 5; do
    pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null || break
    sleep 1
done
rm -rf "$INSTALLED_APP"
cp -R "app/build/$APP_NAME.app" "$INSTALL_DIR/"
codesign --verify --deep --strict "$INSTALLED_APP"
echo "  signature valid"

say "Cleaning"
clean

say "Launching"
open "$INSTALLED_APP"
echo "  $APP_NAME is in the menu bar"
