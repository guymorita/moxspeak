#!/usr/bin/env bash
#
# Builds the disk image people actually download: MoxSpeak.app beside an Applications
# alias, with a backdrop whose arrow says what to do with them.
#
# Why a DMG rather than the ZIP this used to ship: Safari auto-expands a ZIP, so the
# user ends up with a loose .app in Downloads, usually runs it from there, and never
# moves it to /Applications. Every later confusion — a permission grant that does not
# stick, an update that leaves two copies — starts there. The drag-to-Applications
# window is the convention every Mac user already knows.
#
# Notarization: staple the .app BEFORE calling this. A DMG made from a stapled app
# carries the ticket inside it, so the download works offline and on a machine that
# cannot reach Apple. Stapling the DMG itself as well is belt and braces and is what
# build-app.sh does.
#
#   Scripts/make-dmg.sh build/MoxSpeak.app build/MoxSpeak.dmg
set -euo pipefail

APP="${1:?usage: make-dmg.sh <app> <output.dmg>}"
OUT="${2:?usage: make-dmg.sh <app> <output.dmg>}"
VOLUME="MoxSpeak"
BACKGROUND="Assets/dmg-background.tiff"

[[ -d "${APP}" ]] || { echo "error: ${APP} not found" >&2; exit 1; }

STAGE="$(mktemp -d)"
RW="$(mktemp -d)/rw.dmg"
trap 'rm -rf "${STAGE}" "$(dirname "${RW}")"; [[ -n "${MOUNT:-}" ]] && hdiutil detach "${MOUNT}" -quiet 2>/dev/null || true' EXIT

echo "==> staging"
# ditto, not cp -R: cp does not reliably preserve the signature and the stapled ticket,
# and an unsigned-looking app inside a signed DMG is rejected with no useful message.
ditto "${APP}" "${STAGE}/$(basename "${APP}")"
ln -s /Applications "${STAGE}/Applications"
mkdir -p "${STAGE}/.background"
[[ -f "${BACKGROUND}" ]] && cp "${BACKGROUND}" "${STAGE}/.background/background.tiff"

# Size the image from the payload plus headroom for the filesystem's own overhead.
SIZE_KB=$(( $(du -sk "${STAGE}" | cut -f1) + 40000 ))

echo "==> creating read-write image"
hdiutil create -srcfolder "${STAGE}" -volname "${VOLUME}" -fs HFS+ \
  -format UDRW -size "${SIZE_KB}k" "${RW}" -quiet

# A unique mountpoint, not /Volumes/${VOLUME}.
#
# The obvious mountpoint is already taken whenever a copy of the shipped DMG is mounted,
# which is exactly what happens on the machine that builds releases: open the download to
# check it, leave it mounted, and the next build silently attaches somewhere else while
# the Finder step drives the OTHER volume. Observed as a build that produced no disk image
# and reported success, leaving the previous release's DMG in place with its old contents.
MOUNT="/Volumes/${VOLUME}-build-$$"
hdiutil attach "${RW}" -mountpoint "${MOUNT}" -nobrowse -quiet

echo "==> setting the window layout"
# Finder is the only thing that can write these window attributes. It can fail — no
# Automation permission, no window server on a build box — and a DMG with default
# layout still installs perfectly well, so this is advisory rather than fatal.
# Referenced by path rather than by name, for the same reason. `disk "MoxSpeak"` is
# ambiguous the moment two volumes share the name, and Finder picks one of them.
#
# Wrapped in a timeout: a Finder that is waiting on something never returns, and the
# layout is cosmetic. A DMG with the default view installs perfectly well.
if ! perl -e 'alarm shift; exec @ARGV' 60 osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Finder"
  tell folder (POSIX file "${MOUNT}" as alias)
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 160, 840, 560}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 112
    set background picture of theViewOptions to file ".background:background.tiff"
    set position of item "$(basename "${APP}")" of container window to {170, 205}
    set position of item "Applications" of container window to {470, 205}
    update without registering applications
    close
  end tell
end tell
APPLESCRIPT
then
  echo "    warning: Finder would not set the layout — shipping the default view" >&2
fi

sync
hdiutil detach "${MOUNT}" -quiet
MOUNT=""

echo "==> compressing"
rm -f "${OUT}"
hdiutil convert "${RW}" -format UDZO -imagekey zlib-level=9 -o "${OUT}" -quiet

echo "    $(basename "${OUT}")  $(( $(stat -f%z "${OUT}") / 1048576 )) MiB"
