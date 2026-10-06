# Releasing

## One command

```bash
scripts/ship.sh 1.1
```

Builds, notarizes, signs the appcast, commits, tags, pushes, creates the GitHub Release,
uploads the assets, publishes the appcast, and verifies the live feed actually serves the new
build before it says DONE.

**It is safe to re-run.** Every step checks whether it is already done. If the run dies
halfway — a failed push, a notarization timeout, Ctrl-C — fix the cause and run the *same*
command again. That is the resume path; there is no separate flag.

Add `--rebuild` to force a rebuild of a version that is already packaged.

## First-time setup

Once per machine, in this order.

### 1. Sparkle keys

```bash
scripts/setup-keys.sh
```

Prints a public key. Paste it into `Info.plist` under `SUPublicEDKey`. The private half stays
in the login Keychain — **back it up**, see [DISTRIBUTION.md](DISTRIBUTION.md#the-key).

### 2. Developer ID

A "Developer ID Application" certificate in the login keychain. Check with:

```bash
security find-identity -v -p codesigning
```

### 3. notarytool profile

```bash
xcrun notarytool store-credentials vaho-notary --apple-id <apple-id> --team-id <team-id>
```

Uses an app-specific password, stored in the Keychain. Never in a file in this repo.

### 4. The two repos

`jorgeMartinez293/sider` (this one) and `jorgeMartinez293/sider-releases` with a `gh-pages`
branch containing `appcast.xml`, and Pages enabled on that branch. And `gh auth login`.

### 5. create-dmg

```bash
brew install create-dmg
```

Needs a logged-in GUI session — it drives Finder over AppleScript to bake the window layout
into the disk image, so it cannot run headless.

## Things that will bite

- **A dark-wake Mac cannot sign the appcast.** Reading the private key needs a Keychain
  prompt, which needs a real GUI session. Sparkle reports the failure as "Private key not
  found — run the generate_keys tool". Do **not** do that; it orphans every install. Wake the
  Mac and re-run.
- **Releases ship from `main`.** `ship.sh` refuses any other branch (`ALLOW_ANY_BRANCH=1` to
  override deliberately). Every installed user auto-updates to whatever that run publishes.
- **Old zips in `dist/` are load-bearing.** They are what deltas are computed from.
- **`NOTARIZE=0`** exists for local test builds only. Never publish one.
