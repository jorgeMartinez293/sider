#!/usr/bin/env bash
# Build, package and sign a distributable release, then generate/refresh the Sparkle appcast.
#
# Usage: scripts/release.sh <short-version>   e.g. scripts/release.sh 1.1
#
# What it does:
#   1. Bumps CFBundleShortVersionString to <version> and CFBundleVersion to the next integer.
#   2. `make release` (universal build + embed Sparkle + sign without the debug entitlement).
#   3. Notarizes and staples the .app.
#   4. Zips it with `ditto` (preserves framework symlinks/permissions — a plain zip breaks
#      Sparkle).
#   5. Runs generate_appcast over dist/, producing dist/appcast.xml + .delta files, each
#      signed with the private EdDSA key from your Keychain.
#   6. Builds and notarizes the DMG for first-time downloads.
#
# Publishing is scripts/ship.sh's job — run that instead unless you specifically want the
# build without the git/GitHub half.
#
# IMPORTANT: dist/ keeps the FULL history of past .zips — generate_appcast needs them to
# compute deltas between versions. Do not delete old zips.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then echo "Usage: $0 <short-version>  (e.g. 1.1)" >&2; exit 1; fi

PLIST=Info.plist
DIST=dist
# Base URL where the .zip / .delta assets will live (GitHub Release download prefix).
# generate_appcast writes this into the appcast <enclosure> URLs.
DOWNLOAD_URL_PREFIX="https://github.com/jorgeMartinez293/sider-releases/releases/latest/download/"

# 0. Preflight. Every credential this script needs is checked UP FRONT, because the expensive
# steps (universal build, then a notarization round-trip that can sit in Apple's queue for
# over an hour) all happen before the appcast is signed at the very end. Failing there wastes
# the whole run.

# A build with an empty SUPublicEDKey installs fine and then refuses every update it is ever
# offered, silently, forever — the single worst thing that can ship in this file.
PUBKEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST" 2>/dev/null || echo "")
if [ -z "$PUBKEY" ]; then
  echo "ERROR: Info.plist has no SUPublicEDKey." >&2
  echo "       Run scripts/setup-keys.sh and paste the public key in, or this build can" >&2
  echo "       never be updated." >&2
  exit 1
fi

# Reading the private key needs Keychain authorization, which needs a GUI prompt — so on a
# Mac in dark wake (display asleep, unattended, SSH) it fails with -25320 "In dark wake, no
# UI possible". Sparkle misreports that as "Private key ... not found in the Keychain. Please
# run the generate_keys tool", which is dangerously wrong advice: generating new keys orphans
# every installed user. Never do that in response to this error — wake the Mac and rerun.
# Output goes to /dev/null so the private key never lands in a log.
if ! security find-generic-password -s "https://sparkle-project.org" -a ed25519 -w >/dev/null 2>&1; then
  echo "ERROR: cannot read the Sparkle EdDSA private key from the Keychain." >&2
  echo "       The key is almost certainly still there — wake the Mac (real GUI session," >&2
  echo "       display on), approve the Keychain prompt, and rerun." >&2
  echo "       Do NOT run setup-keys.sh/generate_keys: new keys break every install." >&2
  exit 1
fi

if [ "${NOTARIZE:-1}" = "1" ]; then
  security find-identity -v -p codesigning 2>/dev/null | grep -v CSSMERR_TP_CERT_REVOKED \
    | grep -q "Developer ID Application" || {
      echo "ERROR: no valid Developer ID Application identity — cannot notarize." >&2; exit 1; }
  xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-vaho-notary}" >/dev/null 2>&1 || {
    echo "ERROR: notarytool profile '${NOTARY_PROFILE:-vaho-notary}' missing or invalid." >&2
    echo "       Create it with: xcrun notarytool store-credentials" >&2; exit 1; }
fi

# 1. Bump versions. CFBundleVersion must increase monotonically (Sparkle compares by it).
CUR_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
NEW_BUILD=$((CUR_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
echo "Version: $VERSION (build $NEW_BUILD)"

# 2. Build + sign for distribution.
make release

# 2b. Notarize + staple the .app. Must happen BEFORE the zip and the dmg below, so both carry
# a bundle with the ticket already attached and first launch works offline.
# Set NOTARIZE=0 to skip (local test builds only — anything published must be notarized).
if [ "${NOTARIZE:-1}" = "1" ]; then
  make notarize-app
else
  echo "WARNING: skipping notarization (NOTARIZE=0) — do NOT publish this build."
fi

# 3. Zip with ditto (keepParent → archive contains sider.app at its root).
mkdir -p "$DIST"
ZIP="$DIST/sider-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent sider.app "$ZIP"
echo "Packaged $ZIP"

# 4. Appcast + deltas.
# Remove the previous run's dmg first: it carries the PRIOR build's bundle version, and
# generate_appcast (Sparkle 2) treats .dmg as an update archive too — leaving it here makes it
# collide with that version's .zip ("Duplicate updates are not supported"). The dmg is rebuilt
# fresh below and is not needed for delta computation (only the .zips are).
rm -f "$DIST/sider.dmg"
GEN_APPCAST=$(find .build -maxdepth 8 -name generate_appcast -type f -perm -u+x 2>/dev/null | head -1)
if [ -z "$GEN_APPCAST" ]; then echo "ERROR: generate_appcast not found under .build" >&2; exit 1; fi
"$GEN_APPCAST" --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$DIST"

# 5. DMG for first-time downloads from the website. Built AFTER generate_appcast so the tool
# never scans it. Unversioned name on purpose: the landing page links the stable URL
# ${DOWNLOAD_URL_PREFIX}sider.dmg, which GitHub resolves against the latest release as long as
# every release uploads an asset called exactly sider.dmg.
make dmg
# The disk image is downloaded as its own file, so Gatekeeper checks it separately from the
# app inside — it needs its own stapled ticket.
if [ "${NOTARIZE:-1}" = "1" ]; then make notarize-dmg; fi
mv -f sider.dmg "$DIST/sider.dmg"
echo "Packaged $DIST/sider.dmg"

echo
echo "Done. Next steps (or just run scripts/ship.sh, which does all of them):"
echo "  1. Create GitHub Release tag v$VERSION and upload: $DIST/sider-$VERSION.zip, $DIST/sider.dmg and any new $DIST/*.delta"
echo "  2. Publish $DIST/appcast.xml to GitHub Pages (the SUFeedURL host)."
echo "  3. Commit the Info.plist version bump."
