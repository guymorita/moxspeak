#!/usr/bin/env bash
#
# Assembles Speakeasy.app from the release build.
#
# The bundle is deliberately minimal — a binary and an Info.plist. There is no
# Apple Developer account, no entitlements file and no provisioning profile
# anywhere in this, because the app asks for no permissions: Carbon hotkeys,
# NSStatusItem, MPRemoteCommandCenter and NSPasteboard all work without any.
# Ad-hoc signing (`-s -`) is enough to satisfy Gatekeeper for a locally built app.
#
# Idempotent: run it as often as you like.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

APP_NAME="Speakeasy"
BUNDLE_ID="com.speakeasy.menubar"
VERSION="0.1.0"
BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"

echo "==> swift build -c release"
swift build -c release --product SpeakeasyApp

BINARY="$(swift build -c release --product SpeakeasyApp --show-bin-path)/SpeakeasyApp"
if [[ ! -x "${BINARY}" ]]; then
  echo "error: release binary not found at ${BINARY}" >&2
  exit 1
fi

echo "==> assembling ${APP}"
# Remove rather than overwrite. A stale Mach-O left inside a bundle that is then
# re-signed is exactly the kind of thing that "works on my machine" and nowhere
# else, and the bundle is cheap to rebuild from scratch.
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"

cp "${BINARY}" "${APP}/Contents/MacOS/${APP_NAME}"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<!-- Menu bar only: no Dock icon, no app switcher entry. -->
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc signing"
codesign -s - --force "${APP}"
codesign --verify --verbose=1 "${APP}" 2>&1 | sed 's/^/    /'

echo
echo "Built: $(cd "${BUILD_DIR}" && pwd)/${APP_NAME}.app"
echo "Run it:  open -a \"$(cd "${BUILD_DIR}" && pwd)/${APP_NAME}.app\""
echo "Logs:    ~/Library/Logs/Speakeasy.log"
