#!/usr/bin/env bash
#
# Assembles MoxSpeak.app from the release build.
#
# The bundle is deliberately minimal — a binary and an Info.plist. There is no
# Apple Developer account, no entitlements file and no provisioning profile
# anywhere in this, because the app asks for no permissions: Carbon hotkeys,
# NSStatusItem, MPRemoteCommandCenter and NSPasteboard all work without any.
# Ad-hoc signing (`-s -`) is enough to satisfy Gatekeeper for a locally built app.
#
# Idempotent: run it as often as you like — with one caveat, printed at the end.
#
# The caveat: select-to-speak is optional and needs Accessibility, and an ad-hoc
# signature has no stable identity for macOS to pin an approval to, so TCC pins
# the code hash instead. Every rebuild changes that hash, which silently voids
# the approval: System Settings goes on showing MoxSpeak ticked while
# AXIsProcessTrusted() returns false and ⌥⇧S quietly reads the clipboard. That
# is precisely the kind of looks-fine-isn't failure this project exists to
# avoid, so the script says so out loud rather than leaving it to be
# rediscovered.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

APP_NAME="MoxSpeak"
BUNDLE_ID="com.moxspeak.menubar"
VERSION="0.1.0"
BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"

echo "==> swift build -c release"
swift build -c release --product MoxSpeakApp

BINARY="$(swift build -c release --product MoxSpeakApp --show-bin-path)/MoxSpeakApp"
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
echo "Logs:    ~/Library/Logs/MoxSpeak.log"
echo
echo "Note: this rebuild changed the app's code hash, which voids any existing"
echo "      Accessibility approval — System Settings will still show MoxSpeak"
echo "      ticked, but select-to-speak will be off and ⌥⇧S will read the"
echo "      clipboard. If you had it enabled, re-approve it:"
echo
echo "        tccutil reset Accessibility ${BUNDLE_ID}"
echo
echo "      then click \"Enable Select-to-Speak…\" in the menu and approve."
echo "      Nothing else in the app is affected; it needs no permissions."
