#!/bin/bash
# Compiles the app sources (minus the app entry point) together with
# Tests/main.swift into a headless test binary and runs it.
# B-tests assert correct behavior, so they FAIL while the reported bugs exist.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR="${MAC_EXPLORER_BUILD_DIR:-$HOME/Library/Caches/MacExplorerBuild}"
SDK="$(xcrun --show-sdk-path)"
APP="$BUILD_DIR/MacExplorerBugTests.app"
OUT="$APP/Contents/MacOS/mac-explorer-bug-tests"

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find Sources -name '*.swift' ! -path 'Sources/App/main.swift' | sort)

mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>tools.macexplorer.bugtests</string>
    <key>CFBundleName</key><string>MacExplorerBugTests</string>
    <key>CFBundleExecutable</key><string>mac-explorer-bug-tests</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
echo "Compiling ${#SOURCES[@]} app sources + Tests/main.swift…"
swiftc -swift-version 6 -sdk "$SDK" -target arm64-apple-macos14.0 -Onone \
    "${SOURCES[@]}" Tests/main.swift -o "$OUT"

# --ui-test makes AppStore use transient per-process state (no user prefs touched).
# Each test runs in its own process so AppKit/concurrency state cannot leak between tests.
IDS="${*:-S01 S02 S03 B01 B02 B03 B04 B05 B06 B07 B08 B09 B10 B11 B12 B13 B14 B15 B16 R01 R02 R03 R04}"
LOG="$BUILD_DIR/bug-tests-results.txt"
: > "$LOG"
FAILED=0
for ID in $IDS; do
    if OUTPUT=$("$OUT" --ui-test --only "$ID" 2>/dev/null); then STATUS=0; else STATUS=1; fi
    LINE=$(printf '%s\n' "$OUTPUT" | grep -E "^(PASS|FAIL)" | head -1 || true)
    if [ -z "$LINE" ]; then LINE="CRASH $ID — process produced no result"; fi
    printf '%s\n' "$LINE" >> "$LOG"
    printf '%s\n' "$LINE"
    if [ "$STATUS" -ne 0 ]; then FAILED=$((FAILED + 1)); fi
done
echo ""
echo "Results saved to $LOG"
echo "$FAILED test(s) failed."
if [ "$FAILED" -ne 0 ]; then exit 1; fi