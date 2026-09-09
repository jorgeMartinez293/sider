#!/usr/bin/env bash
# One-time setup: generate the Sparkle EdDSA signing key pair.
#
# The PRIVATE key is stored in your login Keychain (item "https://sparkle-project.org"),
# NEVER written to disk or committed. The PUBLIC key is printed below — paste it into
# Info.plist under SUPublicEDKey.
#
# If you lose the private key you cannot sign further updates for existing users, and
# generating a NEW pair does not fix that: every installed copy only trusts the old public
# key baked into its own Info.plist, so it will refuse every future update and those users
# have to reinstall by hand. Keep a Keychain / Time Machine backup.
#
# Run once per project. Safe to re-run: if a key already exists, Sparkle's tool prints the
# existing public key instead of overwriting it.
set -euo pipefail
cd "$(dirname "$0")/.."

# Sparkle's tools appear under .build only after a build has resolved the package.
if [ ! -d .build ]; then
    echo "Building first to fetch Sparkle's tools..."
    swift build -c release >/dev/null
fi

GEN_KEYS=$(find .build -maxdepth 8 -name generate_keys -type f -perm -u+x 2>/dev/null | head -1)
if [ -z "$GEN_KEYS" ]; then
    echo "ERROR: generate_keys not found under .build. Run 'swift build -c release' first." >&2
    exit 1
fi

echo "Using $GEN_KEYS"
echo
"$GEN_KEYS"
echo
echo "→ Copy the SUPublicEDKey value above into Info.plist."
echo "  Until it is filled in, Sparkle refuses every update (it cannot verify a signature)."
