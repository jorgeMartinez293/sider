
# Makefile for sider

APP_NAME = sider
# Universal (arm64 + x86_64) products land here instead of .build/release.
# One binary runs on Apple Silicon and Intel, so the download is a single DMG and
# nothing ever has to detect the visitor's architecture.
BUILD_DIR = .build/apple/Products/Release
APP_BUNDLE = $(APP_NAME).app
EXECUTABLE = $(APP_NAME)
PLIST = Info.plist
ICON = Resources/AppIcon.icns
# Entitlements used for signing. `make` (dev) keeps get-task-allow for debugging;
# `make release` uses sider.release.entitlements (no get-task-allow) for public builds.
ENTITLEMENTS ?= sider.entitlements

# Signing identity, in order of preference:
#
#   1. Developer ID Application — the only identity other Macs accept and the only one
#      Apple will notarize. Everything we ship must use it.
#   2. Apple Development — local fallback so `make` still works on a machine without the
#      Developer ID cert. Fine for development, useless for distribution.
#   3. Ad-hoc ("-") — last resort. Its designated requirement is a bare cdhash that CHANGES
#      on every build, so each rebuild silently voids the TCC grants. For sider that is
#      brutal: Accessibility AND Screen Recording both reset, so a rebuilt app comes up
#      with an empty panel and no previews while System Settings still shows both
#      toggles ON. Certificate-based identities are stable across builds, so grants stick.
#
# `find-identity -v` still lists REVOKED certs (flagged CSSMERR_TP_CERT_REVOKED) — filter
# them or codesign fails late with a confusing error. Override with `make SIGN_IDENTITY=-`
# to force ad-hoc on purpose.
IDENTITIES = security find-identity -v -p codesigning 2>/dev/null | grep -v CSSMERR_TP_CERT_REVOKED
SIGN_IDENTITY ?= $(shell $(IDENTITIES) | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"')
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY := $(shell $(IDENTITIES) | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"')
endif
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY := -
# No usable identity was FOUND — as opposed to `make SIGN_IDENTITY=-`, where ad-hoc is what
# the caller asked for. The two must not look the same: silently going ad-hoc is a different
# TCC identity, and the failure shows up much later as "the app stopped working".
ADHOC_FALLBACK := 1
endif

# Hardened runtime + secure timestamp. BOTH are hard requirements for notarization.
#
# Skipped for ad-hoc: --timestamp round-trips to Apple's timestamp server, which is slow and
# simply fails offline, and an ad-hoc build is never going to be notarized anyway.
ifeq ($(SIGN_IDENTITY),-)
CODESIGN_FLAGS =
else
CODESIGN_FLAGS = --options runtime --timestamp
endif

all: build package

# Public/distribution build: strip the debug entitlement, otherwise identical.
release: ENTITLEMENTS = sider.release.entitlements
release: build package

build:
	swift build -c release --arch arm64 --arch x86_64

# Regenerates the app icon from scripts/make-icon.swift. Not part of `all` — the .icns is
# committed, and rebuilding it on every build would churn a 900 KB binary in git.
icon:
	swift scripts/make-icon.swift

package:
ifdef ADHOC_FALLBACK
	@echo "ERROR: no signing identity found — this build would be AD-HOC signed."; \
	 echo "       macOS treats an ad-hoc bundle as a different app: Accessibility and Screen"; \
	 echo "       Recording are forgotten, so the panel comes up empty with no previews and"; \
	 echo "       every permission is re-asked on launch."; \
	 echo "       Fix: unlock the login keychain (security unlock-keychain) so"; \
	 echo "       'security find-identity -v -p codesigning' lists the Developer ID cert."; \
	 echo "       To build ad-hoc on purpose: make SIGN_IDENTITY=-"; \
	 exit 1
endif
	@echo "Packaging $(APP_BUNDLE)..."
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	cp $(BUILD_DIR)/$(EXECUTABLE) $(APP_BUNDLE)/Contents/MacOS/
	cp $(PLIST) $(APP_BUNDLE)/Contents/
	# Keep-alive LaunchAgent (relaunch after a crash, start at login). SMAppService only
	# accepts a plist that lives here AND is sealed into the app's signature, so it must be
	# copied before codesign runs — see Services/LoginItemService.swift.
	mkdir -p $(APP_BUNDLE)/Contents/Library/LaunchAgents
	cp Resources/LaunchAgents/com.jorge.sider.keepalive.plist $(APP_BUNDLE)/Contents/Library/LaunchAgents/
	@if [ -f $(ICON) ]; then cp $(ICON) $(APP_BUNDLE)/Contents/Resources/; fi
	chmod +x $(APP_BUNDLE)/Contents/MacOS/$(EXECUTABLE)
	# Embed Sparkle.framework (auto-update). swift build links against it but does not copy it
	# into the bundle. Use `cp -R` (NOT plain cp/zip) to preserve the framework's Versions/
	# symlinks and the executable bits of its nested XPC services — flattening them is the
	# nº1 cause of "Sparkle won't launch".
	install_name_tool -add_rpath @executable_path/../Frameworks $(APP_BUNDLE)/Contents/MacOS/$(EXECUTABLE) 2>/dev/null || true
	@SPARKLE_FW=$$(find .build -maxdepth 8 -name 'Sparkle.framework' -type d | head -1); \
	if [ -z "$$SPARKLE_FW" ]; then echo "ERROR: Sparkle.framework not found in .build — run 'swift build -c release' first"; exit 1; fi; \
	echo "Embedding $$SPARKLE_FW"; \
	cp -R "$$SPARKLE_FW" $(APP_BUNDLE)/Contents/Frameworks/
	xattr -cr $(APP_BUNDLE)
	# Sign inner-out: every nested executable MUST be signed before the bundle that contains
	# it, or the outer signature seals unsigned nested code.
	#
	# Deliberately NOT `--deep`. Apple documents --deep as unsuitable for distribution: it
	# re-signs nested code with the OUTER bundle's entitlements and options, which here would
	# hand Sparkle's XPC services sider's entitlements. Notarization rejects the result.
	# Sign each piece explicitly instead, deepest first.
	@set -e; SPK=$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework/Versions/B; \
	for xpc in "$$SPK"/XPCServices/*.xpc; do \
	  echo "  signing $$xpc"; \
	  codesign --force $(CODESIGN_FLAGS) --sign "$(SIGN_IDENTITY)" "$$xpc"; \
	done; \
	codesign --force $(CODESIGN_FLAGS) --sign "$(SIGN_IDENTITY)" "$$SPK/Updater.app"; \
	codesign --force $(CODESIGN_FLAGS) --sign "$(SIGN_IDENTITY)" "$$SPK/Autoupdate"; \
	codesign --force $(CODESIGN_FLAGS) --sign "$(SIGN_IDENTITY)" "$$SPK"
	codesign --force $(CODESIGN_FLAGS) --sign "$(SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(APP_BUNDLE)
	@echo "Verifying signature..."
	codesign --verify --deep --strict $(APP_BUNDLE)
# An ad-hoc signature passes the verify above, which is how a build whose SIGN_IDENTITY
# lookup came back EMPTY (locked login keychain, a `security find-identity` hiccup) would
# sail straight through. Fail loudly instead — for sider an ad-hoc bundle means a new TCC
# identity, which means an empty panel and no previews with no obvious cause.
ifneq ($(SIGN_IDENTITY),-)
	@codesign -dv $(APP_BUNDLE) 2>&1 | grep -q '^TeamIdentifier=[A-Z0-9]' || { \
	  echo "ERROR: $(APP_BUNDLE) ended up AD-HOC signed (no TeamIdentifier) — TCC will treat it"; \
	  echo "       as a brand-new app and re-ask for every permission. Unlock the login keychain"; \
	  echo "       (security unlock-keychain) and re-run make. To do it on purpose: make SIGN_IDENTITY=-"; \
	  exit 1; }
endif
	@echo "Done! App bundle created at $(APP_BUNDLE) (entitlements: $(ENTITLEMENTS))"

# Wrap the signed .app in a DMG with the usual "drag to Applications" layout.
# The DMG keeps a stable, unversioned name so the website can always link
# https://github.com/jorgeMartinez293/sider-releases/releases/latest/download/sider.dmg
#
# create-dmg (brew install create-dmg) drives Finder via AppleScript to bake the icon layout
# into the volume's .DS_Store, so this target needs a logged-in GUI session — it cannot run
# headless in CI.
DMG = $(APP_NAME).dmg

dmg:
	@test -d $(APP_BUNDLE) || { echo "ERROR: $(APP_BUNDLE) not found — run 'make release' first"; exit 1; }
	rm -f $(DMG)
	create-dmg \
	  --volname "$(APP_NAME)" \
	  --volicon $(ICON) \
	  --window-pos 200 120 \
	  --window-size 515 380 \
	  --icon-size 128 \
	  --text-size 12 \
	  --icon "$(APP_NAME).app" 130 190 \
	  --hide-extension "$(APP_NAME).app" \
	  --app-drop-link 385 190 \
	  --format UDZO \
	  $(DMG) $(APP_BUNDLE)
	codesign --force $(CODESIGN_FLAGS) --sign "$(SIGN_IDENTITY)" $(DMG)
	@echo "Done! $(DMG) ready for upload."

# ── Notarization ──────────────────────────────────────────────────────────────
# Apple scans the build and issues a "ticket" Gatekeeper trusts, so users can open the app
# straight from a download: no right-click→Open, no `xattr -dr com.apple.quarantine`, no
# "Apple could not verify..." panel. Needs hardened runtime + secure timestamp (see
# CODESIGN_FLAGS) and a Developer ID Application identity.
#
# NOTE: notarization does NOT grant Accessibility or Screen Recording. Those are TCC
# permissions the user always approves by hand — notarized or not.
#
# NOTARY_PROFILE names a Keychain item created ONCE with:
#   xcrun notarytool store-credentials sider-notary \
#     --apple-id <apple-id> --team-id <team-id>
# The app-specific password lives in the Keychain. Never put a credential in this file.
NOTARY_PROFILE ?= sider-notary
NOTARIZE_ZIP = .notarize-upload.zip

# Guard: refuse to "notarize" something signed with an identity Apple will reject, instead of
# failing minutes later inside the submission.
check-devid:
	@case "$(SIGN_IDENTITY)" in \
	  "Developer ID Application"*) ;; \
	  *) echo "ERROR: notarization requires a Developer ID Application identity."; \
	     echo "       Current SIGN_IDENTITY: $(SIGN_IDENTITY)"; exit 1 ;; \
	esac

# Staple the app BEFORE it is zipped for Sparkle or copied into the DMG: stapling attaches
# the ticket to the bundle on disk, so first launch works with no network. Without it
# Gatekeeper must reach Apple, and an offline user sees the block again.
notarize-app: check-devid
	@test -d $(APP_BUNDLE) || { echo "ERROR: $(APP_BUNDLE) not found — run 'make release' first"; exit 1; }
	rm -f $(NOTARIZE_ZIP)
	ditto -c -k --keepParent $(APP_BUNDLE) $(NOTARIZE_ZIP)
	@echo "Submitting $(APP_BUNDLE) to Apple (this takes a few minutes)..."
	xcrun notarytool submit $(NOTARIZE_ZIP) --keychain-profile $(NOTARY_PROFILE) --wait
	rm -f $(NOTARIZE_ZIP)
	xcrun stapler staple $(APP_BUNDLE)
	@echo "Verifying Gatekeeper acceptance..."
	spctl -a -vvv -t exec $(APP_BUNDLE)

# The DMG needs its own ticket: the one stapled into the .app rides along inside it, but the
# disk image itself is a separate downloaded file that Gatekeeper checks on mount.
notarize-dmg: check-devid
	@test -f $(DMG) || { echo "ERROR: $(DMG) not found — run 'make dmg' first"; exit 1; }
	@echo "Submitting $(DMG) to Apple..."
	xcrun notarytool submit $(DMG) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(DMG)
	xcrun stapler validate $(DMG)

test:
	swift test

clean:
	rm -rf .build $(APP_BUNDLE) $(DMG)

.PHONY: all release build icon package dmg check-devid notarize-app notarize-dmg test clean
