#!/usr/bin/env bash
#
# Assembles MoxSpeak.app from the release build.
#
# The bundle is self-contained: the binary, an Info.plist, and everything the native
# speech engine needs — fp16 Kokoro weights, the voice vectors, the MisakiSwift
# phonemizer lexicon and MLX's compiled Metal library. Installing the .app is the whole
# installation; nothing else has to exist on the machine.
#
# There is no entitlements file and no provisioning profile anywhere in this, because the
# app asks for no permissions: Carbon hotkeys, NSStatusItem, MPRemoteCommandCenter and
# NSPasteboard all work without any.
#
# Where each asset goes, and why it is not negotiable:
#
#   Contents/Resources/Models/          weights + voices. Found via Bundle.main.resourceURL
#                                       (NativeModelAssets.bundleModelsDirectory).
#   Contents/Resources/MoxSpeak_*.bundle  SwiftPM resource bundles (lexicon, BART fallback
#                                       net, Kokoro config). SwiftPM's generated
#                                       Bundle.module looks for these at the *root* of the
#                                       bundle, next to Contents/ — codesign refuses to
#                                       sign that ("unsealed contents present in the bundle
#                                       root"), so they ship in the standard location and
#                                       MoxSpeakResourceLocator in each vendored target
#                                       looks there first.
#   Contents/MacOS/mlx.metallib         MLX resolves its Metal library relative to the
#                                       *binary* (dladdr), not the bundle, so this one has
#                                       to sit beside the executable.
#
# Signing identity matters more than it looks, because of how macOS pins permissions.
#
# Ad-hoc signing (`-s -`) has no stable identity, so TCC pins an Accessibility grant to
# the binary's *code hash*. Every rebuild changes that hash and silently voids the grant:
# System Settings still shows the app ticked, the TCC database still says "allowed", and
# AXIsProcessTrusted() correctly returns false. Nothing reports an error; select-to-speak
# just quietly stops working.
#
# A Developer ID identity gives macOS something stable to pin to, so grants survive
# rebuilds and future updates. We use it when it is present and fall back to ad-hoc when
# it is not, so the build still works on a machine without the certificate.
#
# Idempotent: run it as often as you like — with one caveat, printed at the end.
#
# The caveat: select-to-speak is optional and needs Accessibility, and an ad-hoc
# signature has no stable identity for macOS to pin an approval to, so TCC pins
# the code hash instead. Every rebuild changes that hash, which silently voids
# the approval: System Settings goes on showing MoxSpeak ticked while
# AXIsProcessTrusted() returns false and the speak shortcut quietly reads the
# clipboard. That is precisely the kind of looks-fine-isn't failure this project
# exists to avoid, so the script says so out loud rather than leaving it to be
# rediscovered.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

APP_NAME="MoxSpeak"
BUNDLE_ID="com.moxspeak.menubar"
BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"

# --- Version identity ---------------------------------------------------------------
#
# Three numbers, each answering a different question — see Sources/MoxSpeakApp/AppVersion.swift
# for how they are parsed and rendered ("0.4.0 (84) · 1dbb02b"):
#
#   VERSION      human-meaningful release, from the VERSION file at the repo root.
#                Bumped deliberately when something meaningful ships, not on every commit.
#   BUILD_NUMBER git commit count. Automatic and monotonic — this is what macOS requires
#                of CFBundleVersion, which a hand-maintained number is not guaranteed to be.
#   COMMIT_SHA   short commit SHA. This is the part that actually matters in a bug report:
#                it traces a build back to the exact code that produced it.
#
# A tree with uncommitted changes gets "-dirty" appended to the SHA rather than to the
# build number: CFBundleVersion has to stay a plain integer for macOS to treat it as
# monotonic, so the dirty marker lives only in the human-readable custom key and is
# reconstructed for display by AppVersion (a "+" after the build number) from that suffix.
VERSION="$(cat VERSION 2>/dev/null || echo "0.0.0")"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo "0")"
COMMIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
# Untracked files intentionally excluded — a stray scratch file sitting in the tree
# should not brand every build "dirty"; what matters is whether committed content
# differs from what is checked in.
if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  COMMIT_SHA="${COMMIT_SHA}-dirty"
fi
echo "==> version ${VERSION} (${BUILD_NUMBER}) · ${COMMIT_SHA}"

echo "==> swift build -c release"
swift build -c release --product MoxSpeakApp

RELEASE_BIN_DIR="$(swift build -c release --product MoxSpeakApp --show-bin-path)"
BINARY="${RELEASE_BIN_DIR}/MoxSpeakApp"
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

# --- MLX Metal library -------------------------------------------------------------
#
# `swift build` has no Metal compilation rule, so this is produced by a script rather than
# by the build. Built on demand rather than assumed present: a missing metallib does not
# fail the app build, it fails at the first kernel launch with a C++ abort inside mlx-c,
# which is exactly the kind of obscure runtime failure this script should be preventing.
METALLIB="${RELEASE_BIN_DIR}/mlx.metallib"
if [[ ! -f "${METALLIB}" ]]; then
  echo "==> mlx.metallib missing, building it (Scripts/build-metallib.sh)"
  Scripts/build-metallib.sh >/dev/null
fi
if [[ ! -f "${METALLIB}" ]]; then
  echo "error: Scripts/build-metallib.sh did not produce ${METALLIB}" >&2
  exit 1
fi
cp "${METALLIB}" "${APP}/Contents/MacOS/mlx.metallib"

# --- SwiftPM resource bundles ------------------------------------------------------
#
# The phonemizer lexicon (us_gold/us_silver), the BART fallback network and Kokoro's
# config.json. ~9 MB, and the engine produces nonsense phonemes without them.
mkdir -p "${APP}/Contents/Resources"
for bundle_name in MoxSpeak_MisakiSwift.bundle MoxSpeak_KokoroSwift.bundle; do
  src="${RELEASE_BIN_DIR}/${bundle_name}"
  if [[ ! -d "${src}" ]]; then
    echo "error: ${src} not found — the release build should have produced it" >&2
    exit 1
  fi
  cp -R "${src}" "${APP}/Contents/Resources/${bundle_name}"
done

# --- Model weights and voices ------------------------------------------------------
#
# fp16, not f32: measured acoustically indistinguishable from our own f32 conversion
# (0.85 dB mel log-spectral distance, 0.9994 cosine) at half the size — 156 MB against
# 312 MB. On a menu bar utility the download size is a real cost and this one is free.
#
# Not in git (Models/ is gitignored, see Sources/Vendor/VENDORED.md for the fetch recipe),
# so their absence is a normal thing to hit on a fresh checkout and gets a real message.
MODEL_SRC="${MOXSPEAK_MODEL_DIR:-Models}"
WEIGHTS="${MODEL_SRC}/kokoro-v1_0-fp16.safetensors"
if [[ ! -f "${WEIGHTS}" ]]; then
  echo "error: no fp16 weights at ${WEIGHTS}" >&2
  echo "       Set MOXSPEAK_MODEL_DIR, or see Sources/Vendor/VENDORED.md to fetch them." >&2
  exit 1
fi
if [[ ! -d "${MODEL_SRC}/voices" ]]; then
  echo "error: no voices directory at ${MODEL_SRC}/voices" >&2
  exit 1
fi

echo "==> copying model assets from ${MODEL_SRC}"
mkdir -p "${APP}/Contents/Resources/Models"
cp "${WEIGHTS}" "${APP}/Contents/Resources/Models/"
cp -R "${MODEL_SRC}/voices" "${APP}/Contents/Resources/Models/voices"
VOICE_COUNT=$(find "${APP}/Contents/Resources/Models/voices" -name '*.safetensors' | wc -l | tr -d ' ')
echo "    $(basename "${WEIGHTS}") + ${VOICE_COUNT} voices"

# Licences travel with the binary, not just with the repo. Apache-2.0 section 4(a)
# requires it of anyone redistributing the components MoxSpeak bundles, and a repo
# nobody downloaded is not a copy given to the recipient. The app's Advanced menu
# opens THIRD-PARTY-NOTICES.md from here.
# --- app icon ---------------------------------------------------------------------
#
# Regenerated from the artwork every build rather than committed as a binary blob, so
# the .icns can never drift from Assets/icon-source.png. `Scripts/make-icon.py` masks
# it into Apple's squircle grid and crops in for the small sizes; see that file.
#
# LSUIElement means there is no Dock icon, but this is still what shows in Finder, in
# Get Info, in the installer window, and as the DMG's volume icon.
if [[ -f Assets/icon-source.png ]]; then
  echo "==> building app icon"
  if python3 Scripts/make-icon.py Assets/icon-source.png "${APP}/Contents/Resources/${APP_NAME}.icns"; then
    ICON_KEYS=$'\t<key>CFBundleIconFile</key>\n\t<string>'"${APP_NAME}"$'</string>\n\t<key>CFBundleIconName</key>\n\t<string>'"${APP_NAME}"$'</string>'
  else
    echo "    warning: icon generation failed — shipping without one" >&2
    ICON_KEYS=""
  fi
else
  echo "    warning: Assets/icon-source.png missing — shipping without an icon" >&2
  ICON_KEYS=""
fi

echo "==> copying licences"
mkdir -p "${APP}/Contents/Resources/licenses"
cp LICENSE "${APP}/Contents/Resources/"
cp THIRD-PARTY-NOTICES.md "${APP}/Contents/Resources/"
cp licenses/*.txt "${APP}/Contents/Resources/licenses/"
echo "    LICENSE, THIRD-PARTY-NOTICES.md, $(ls licenses | wc -l | tr -d ' ') licence texts"

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
	<string>${BUILD_NUMBER}</string>
	<key>MoxSpeakCommitSHA</key>
	<string>${COMMIT_SHA}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<!-- Menu bar only: no Dock icon, no app switcher entry. -->
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
${ICON_KEYS}
</dict>
</plist>
PLIST

echo "==> signing"
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | awk '{print $2}')"
# Inside out: mlx.metallib is a Mach-O-ish MetalLib executable, so codesign treats it as a
# nested code object and refuses to seal the app around an unsigned one ("code object is
# not signed at all"). Nested code gets signed before the bundle that contains it.
NESTED=("${APP}/Contents/MacOS/mlx.metallib")

if [ -n "${SIGN_ID}" ]; then
    if [ -n "${MOXSPEAK_NO_TIMESTAMP:-}" ]; then
        codesign -s "${SIGN_ID}" --force --options runtime --timestamp=none "${NESTED[@]}"
    else
        codesign -s "${SIGN_ID}" --force --options runtime --timestamp "${NESTED[@]}"
    fi
    # A secure timestamp is required for notarization — Apple rejects unstamped
    # signatures outright. It needs network access to Apple's timestamp server,
    # so MOXSPEAK_NO_TIMESTAMP=1 is available for offline builds that will never
    # be notarized.
    if [ -n "${MOXSPEAK_NO_TIMESTAMP:-}" ]; then
        codesign -s "${SIGN_ID}" --force --options runtime --timestamp=none "${APP}"
        echo "    signed WITHOUT a timestamp — this build cannot be notarized"
    else
        codesign -s "${SIGN_ID}" --force --options runtime --timestamp "${APP}"
    fi
    echo "    signed with Developer ID ${SIGN_ID} — Accessibility grants survive rebuilds"
else
    codesign -s - --force "${NESTED[@]}"
    codesign -s - --force "${APP}"
    echo "    ad-hoc signed (no Developer ID found)"
    echo "    NOTE: this rebuild voided any Accessibility grant. To re-grant:"
    echo "          tccutil reset Accessibility com.moxspeak.menubar"
fi
codesign --verify --verbose=1 "${APP}" 2>&1 | sed 's/^/    /'

# Notarization. Optional, because it needs the network and an Apple round trip of a
# couple of minutes — but required for the app to open on any Mac other than the one that
# built it. Without it Gatekeeper shows "cannot verify it is free of malware" with no
# Open Anyway button on macOS 15+, which is a dead end for whoever you gave it to.
#
# Set up once with:
#   xcrun notarytool store-credentials "moxspeak-notary" \
#     --apple-id <apple-id> --team-id 9F9SXNU23N
#
# Note the ticket is stapled into the bundle, so copy the result with `ditto`, never
# `rsync` — rsync does not faithfully preserve a signed bundle and strips the signature.
if [ -n "${MOXSPEAK_NOTARIZE:-}" ]; then
    echo "==> notarizing (a few minutes)"
    NOTARIZE_ZIP="$(mktemp -d)/MoxSpeak.zip"
    ditto -c -k --keepParent "${APP}" "${NOTARIZE_ZIP}"
    if xcrun notarytool submit "${NOTARIZE_ZIP}" \
           --keychain-profile "${MOXSPEAK_NOTARY_PROFILE:-moxspeak-notary}" \
           --wait --timeout 20m; then
        xcrun stapler staple "${APP}"
        spctl -a -vv "${APP}" 2>&1 | sed 's/^/    /'
    else
        echo "    notarization failed — the app still runs here, but not on other Macs"
        exit 1
    fi
    rm -rf "$(dirname "${NOTARIZE_ZIP}")"
fi

# --- the disk image people download ------------------------------------------------
#
# Built after stapling so the app inside carries its own ticket, which is what lets a
# first launch succeed on a Mac with no network. The DMG is then notarized and stapled
# in its own right: Gatekeeper checks the ticket on the container the user actually
# double-clicks, and a stapled DMG means that check never has to reach Apple either.
if [ -z "${MOXSPEAK_NO_DMG:-}" ]; then
    echo
    echo "==> disk image"
    DMG="${BUILD_DIR}/${APP_NAME}.dmg"
    Scripts/make-dmg.sh "${APP}" "${DMG}" | sed 's/^/    /'

    if [ -n "${MOXSPEAK_NOTARIZE:-}" ]; then
        codesign -s "${SIGN_ID}" --force --timestamp "${DMG}"
        echo "==> notarizing the disk image (a few minutes)"
        if xcrun notarytool submit "${DMG}" \
               --keychain-profile "${MOXSPEAK_NOTARY_PROFILE:-moxspeak-notary}" \
               --wait --timeout 20m; then
            xcrun stapler staple "${DMG}"
            spctl -a -vv -t open --context context:primary-signature "${DMG}" 2>&1 | sed 's/^/    /'
        else
            echo "    disk image notarization failed" >&2
            exit 1
        fi
    fi
fi

echo
echo "==> size"
# MiB throughout (du reports 1024-byte blocks); the zipped line also gives the decimal MB
# a download indicator would show, because that is the number the size argument is about.
mib() { printf "%d" "$(( $(du -sk "$1" | cut -f1) / 1024 ))"; }
printf "    bundle      %s MiB\n" "$(mib "${APP}")"
printf "      weights   %s MiB\n" "$(mib "${APP}/Contents/Resources/Models/kokoro-v1_0-fp16.safetensors")"
printf "      voices    %s MiB (%s voices)\n" "$(mib "${APP}/Contents/Resources/Models/voices")" "${VOICE_COUNT}"
printf "      lexicon   %s MiB\n" "$(( ($(du -sk "${APP}/Contents/Resources/MoxSpeak_MisakiSwift.bundle" | cut -f1) + $(du -sk "${APP}/Contents/Resources/MoxSpeak_KokoroSwift.bundle" | cut -f1)) / 1024 ))"
printf "      binary    %s MiB\n" "$(mib "${APP}/Contents/MacOS/${APP_NAME}")"
printf "      metallib  %s KiB\n" "$(du -sk "${APP}/Contents/MacOS/mlx.metallib" | cut -f1)"

# The number that actually matters for a download. `ditto` is what `zip` should have been
# on macOS: it preserves the bundle and its signature.
ZIP="${BUILD_DIR}/${APP_NAME}.app.zip"
rm -f "${ZIP}"
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP}"
ZIP_BYTES=$(stat -f%z "${ZIP}")
printf "    zipped      %s MiB (%s MB)\n" "$((ZIP_BYTES / 1048576))" "$((ZIP_BYTES / 1000000))"

echo
echo "Built: $(cd "${BUILD_DIR}" && pwd)/${APP_NAME}.app"
# Installing a local build over a copy that came from a download leaves the downloaded
# copy's com.apple.quarantine attribute sitting on the directory. Quarantined plus
# unnotarized is precisely what Gatekeeper refuses, so the next launch says "Apple cannot
# check it for malicious software" about a build that never left the machine. Costs an
# afternoon to diagnose and looks exactly like a broken release.
echo "Install: pkill -x ${APP_NAME}; ditto ${APP} /Applications/${APP_NAME}.app \\"
echo "         && xattr -d -r com.apple.quarantine /Applications/${APP_NAME}.app 2>/dev/null; true"
echo "Run it:  open -a \"$(cd "${BUILD_DIR}" && pwd)/${APP_NAME}.app\""
echo "Check:   MOXSPEAK_SELFTEST=1 \"$(cd "${BUILD_DIR}" && pwd)/${APP_NAME}.app/Contents/MacOS/${APP_NAME}\""
echo "         (loads and speaks using only what is inside the bundle, then exits)"
echo "Logs:    ~/Library/Logs/MoxSpeak.log"
echo
echo "Note: this rebuild changed the app's code hash, which voids any existing"
echo "      Accessibility approval — System Settings will still show MoxSpeak"
echo "      ticked, but select-to-speak will be off and the speak shortcut"
echo "      will read the clipboard. If you had it enabled, re-approve it:"
echo
echo "        tccutil reset Accessibility ${BUNDLE_ID}"
echo
echo "      then click \"Enable Select-to-Speak…\" in the menu and approve."
echo "      Nothing else in the app is affected; it needs no permissions."
