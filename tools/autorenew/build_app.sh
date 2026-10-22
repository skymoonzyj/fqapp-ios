#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:-$ROOT/build/Fqapp Auto Renew.app}"
PYTHON_PATH="${2:-/usr/bin/python3}"
if [[ "$OUTPUT" != *.app ]]; then
  echo 'Output path must end in .app' >&2
  exit 2
fi
if [[ "$PYTHON_PATH" != /* || ! -x "$PYTHON_PATH" ]]; then
  echo 'Python path must be an absolute executable path' >&2
  exit 2
fi
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"
BUILD_DIR="$(mktemp -d "$ROOT/macos/.build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
ARCH="$(uname -m)"
xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macosx13.0" \
  -framework AppKit -framework UserNotifications \
  "$ROOT/macos/Core.swift" "$ROOT/macos/main.swift" -o "$BUILD_DIR/FqappAutoRenew"
PLIST="$BUILD_DIR/Info.plist"
/usr/bin/plutil -create xml1 "$PLIST"
/usr/bin/plutil -insert CFBundleIdentifier -string com.fqapp.autorenew "$PLIST"
/usr/bin/plutil -insert CFBundleName -string 'fqapp 自动续签' "$PLIST"
/usr/bin/plutil -insert CFBundleDisplayName -string 'fqapp 自动续签' "$PLIST"
/usr/bin/plutil -insert CFBundleExecutable -string FqappAutoRenew "$PLIST"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$PLIST"
/usr/bin/plutil -insert CFBundleShortVersionString -string 1.0 "$PLIST"
/usr/bin/plutil -insert CFBundleVersion -string 1 "$PLIST"
/usr/bin/plutil -insert LSMinimumSystemVersion -string 13.0 "$PLIST"
/usr/bin/plutil -insert LSUIElement -bool true "$PLIST"
/usr/bin/plutil -insert NSHighResolutionCapable -bool true "$PLIST"
/usr/bin/plutil -insert NSPrincipalClass -string NSApplication "$PLIST"
/usr/bin/plutil -insert FQPythonPath -string "$PYTHON_PATH" "$PLIST"
/usr/bin/install -m 755 "$BUILD_DIR/FqappAutoRenew" "$OUTPUT/Contents/MacOS/FqappAutoRenew"
/usr/bin/install -m 644 "$PLIST" "$OUTPUT/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier com.fqapp.autorenew "$OUTPUT"
/usr/bin/codesign --verify --strict "$OUTPUT"
printf '%s\n' "$OUTPUT"
