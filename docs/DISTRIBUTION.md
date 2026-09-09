# Distribution

How a build gets from this repo onto someone's Mac, and how it updates afterwards.

## The shape of it

```
  jorgeMartinez293/sider              source. tagged v<version> per release.
  jorgeMartinez293/sider-releases     everything users download:
    ├─ Releases/v<version>/           sider-<version>.zip, sider.dmg, sider<n>-<m>.delta
    ├─ gh-pages/appcast.xml           the Sparkle feed (SUFeedURL points here)
    └─ main/appcast.xml               same file, so the feed is diffable in the repo view
```

Two repos on purpose. Release assets and the appcast are pushed on every release; keeping
them out of the source repo means its history stays code, and a bad upload never needs a
force-push over the code.

## First download

The website links a stable URL:

```
https://github.com/jorgeMartinez293/sider-releases/releases/latest/download/sider.dmg
```

GitHub resolves `latest` at request time, so the link never changes. That works only because
**every** release uploads an asset named exactly `sider.dmg` — an unversioned name is
required here, not a stylistic choice.

The DMG is signed with a Developer ID identity, notarized, and stapled. All three matter:

- **signed** — Gatekeeper will not open an unsigned or ad-hoc app from a download at all.
- **notarized** — without the ticket the user gets "Apple could not verify…" and has to
  right-click → Open, which most people read as "this app is broken".
- **stapled** — the ticket is attached to the file on disk, so first launch works offline.
  Without stapling Gatekeeper has to reach Apple, and an offline user sees the block again.

The `.app` inside is notarized and stapled separately from the `.dmg`, because the disk image
is its own downloaded file and Gatekeeper checks it on mount.

## Updates

Sparkle, configured entirely from `Info.plist`:

| Key | What it does |
|---|---|
| `SUFeedURL` | `https://jorgeMartinez293.github.io/sider-releases/appcast.xml` |
| `SUPublicEDKey` | EdDSA public key. Every download is verified against it before install. |
| `SUEnableAutomaticChecks` | Background checks on. |
| `SUScheduledCheckInterval` | 86400 — once a day. |

`UpdaterService.shared` starts the updater; there is no other call to make.

`generate_appcast` also produces **delta** files (`sider<new>-<old>.delta`) so an existing
install downloads only what changed, usually a fraction of the full zip. Deltas are computed
from the previous `.zip`s, which is why:

> **`dist/` keeps every past `.zip`. Do not delete them.**

Without an old zip on disk, that version's users silently fall back to the full download.

### The key

The private EdDSA key lives in the login Keychain and nowhere else. Losing it does **not**
mean "generate a new pair": every installed copy trusts only the public key baked into its
own `Info.plist`, so a new pair means every existing user stops receiving updates forever and
has to reinstall by hand. Back up the Keychain item.

`scripts/release.sh` refuses to run if `SUPublicEDKey` is empty, for the mirror reason — a
build shipped with a blank key can never be updated.

## Version numbers

- `CFBundleShortVersionString` — what people see (`1.4`).
- `CFBundleVersion` — a plain increasing integer. **This is what Sparkle compares.** It must
  never go backwards or repeat, which is why `scripts/release.sh` bumps it rather than anyone
  typing it.

## Permissions are not covered by any of this

Notarization does not grant Accessibility or Screen Recording, and neither survives a change
of code-signing identity. An ad-hoc build has a *new* identity on every rebuild, so both
grants reset each time — the `Makefile` refuses to sign ad-hoc unless explicitly asked
precisely because the symptom (empty panel, no previews, both switches still on in System
Settings) points nowhere near the cause.
