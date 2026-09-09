#!/usr/bin/env bash
# One-command release: build + package + sign + appcast, then publish EVERYTHING.
#
# Usage: scripts/ship.sh <short-version> [--rebuild]    e.g. scripts/ship.sh 1.1
#
# This is the script to run when asked to "ship the current state as a new version".
# It wraps scripts/release.sh (the builder) and then does every step that used to be
# manual and error-prone:
#
#   1. release.sh <version>  → bumps version, builds, signs, zips, deltas, appcast, dmg.
#   2. De-duplicate dist/appcast.xml (see below).
#   3. Source repo (jorgeMartinez293/sider): commit the version bump + rebuilt app,
#      tag v<version>, push main + tag.
#   4. Release repo (jorgeMartinez293/sider-releases): create GitHub Release v<version>
#      and upload the new .zip, .dmg and .delta assets.
#   5. Publish dist/appcast.xml to the sider-releases gh-pages branch (the SUFeedURL host)
#      AND to its main branch, so live auto-update advertises the new build.
#   6. Verify the live appcast really serves the new build before declaring success.
#
# SAFE TO RE-RUN — that is the whole point of the state checks below. If the script dies
# halfway (failed push, notarization timeout, Ctrl-C), fix the cause and run the SAME
# command again: each step detects whether it is already done and skips it. Re-running is
# how you finish a partial release; there is no separate resume mode.
#
# The failure this guards against, seen for real on the sibling project this script came
# from: a `git push` died with HTTP 408, `set -e` killed the run right after the local tag
# was created, and re-running was refused because that tag existed. The release sat
# unpublished, and the two aborted attempts left TWO <item>s for the same version in the
# appcast (one per bumped build) pointing at the same .zip URL with different lengths and
# signatures — which Sparkle rejects on every client, forever.
#
# Requirements: `gh` authenticated (gh auth status), the private EdDSA key in your
# Keychain (release.sh needs it), and a clean-enough working tree (any local edits you
# want in the release should already be saved to disk — they get committed in step 3).
set -euo pipefail
cd "$(dirname "$0")/.."          # → project root
APP_DIR="$(pwd)"

VERSION=""
FORCE_REBUILD=0
for arg in "$@"; do
  case "$arg" in
    --rebuild) FORCE_REBUILD=1 ;;
    -*) echo "Unknown flag: $arg" >&2; exit 1 ;;
    *) VERSION="$arg" ;;
  esac
done
if [ -z "$VERSION" ]; then echo "Usage: $0 <short-version> [--rebuild]  (e.g. 1.3)" >&2; exit 1; fi

SOURCE_REPO="jorgeMartinez293/sider"           # code + version tag
RELEASE_REPO="jorgeMartinez293/sider-releases" # GH Release assets + gh-pages appcast
DIST="$APP_DIR/dist"
PLIST="$APP_DIR/Info.plist"
APPCAST="$DIST/appcast.xml"
TAG="v$VERSION"
# Anything this big has no business in the source repo. The push that broke a release on the
# sibling project was a 48 MB `rw.*.dmg` left behind by an aborted create-dmg run and swept
# up by `git add -A`; GitHub answered the oversized push with HTTP 408. They are gitignored
# now, but the guard stays: a mystery 408 five minutes into a push is far worse than an
# upfront error.
MAX_COMMIT_FILE_MB=40

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
skip() { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }

# ── Pre-flight ────────────────────────────────────────────────────────────────
gh auth status >/dev/null 2>&1 || { echo "ERROR: run 'gh auth login' first." >&2; exit 1; }

# ── 1. Build + package + appcast + dmg (skipped if already done for this version) ──────
#
# The skip test is deliberately strict, because getting it wrong in either direction is
# expensive: rebuilding needlessly bumps CFBundleVersion again (that is what produced the
# duplicate appcast items), while skipping a build that is not really there publishes
# nothing or, worse, the previous version's bits. All of these must hold:
#
#   - Info.plist already carries this short version,
#   - the .zip and .dmg exist,
#   - the appcast has an item for the current build whose enclosure length matches the
#     .zip on disk byte-for-byte (so appcast, zip and plist describe the same build),
#   - the .app INSIDE THE ZIP is stapled, i.e. notarization actually completed.
CUR_SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
CUR_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
ZIP="$DIST/sider-$VERSION.zip"
DMG="$DIST/sider.dmg"

# Check the bundle that actually ships, not the loose app/sider.app in the tree: any later
# `make build` (a plain dev build, no notarization) overwrites that one and strips its
# staple, while the .app inside the .zip is still perfectly notarized. Testing the loose
# bundle therefore reported "not built yet" for a release that was complete — and the
# needless rebuild bumps CFBundleVersion, which is exactly what produces the duplicate
# appcast items step 2 exists to clean up.
zip_is_stapled() {
  [ "${NOTARIZE:-1}" = "1" ] || return 0
  local tmp ok=1
  tmp=$(mktemp -d)
  if ditto -x -k "$ZIP" "$tmp" >/dev/null 2>&1 \
     && xcrun stapler validate "$tmp/sider.app" >/dev/null 2>&1; then
    ok=0
  fi
  rm -rf "$tmp"
  return $ok
}

artifacts_ready() {
  [ "$CUR_SHORT" = "$VERSION" ] || return 1
  [ -f "$ZIP" ] && [ -f "$DMG" ] && [ -f "$APPCAST" ] || return 1
  grep -q "<sparkle:version>$CUR_BUILD</sparkle:version>" "$APPCAST" || return 1
  grep -q "sider-$VERSION.zip\" length=\"$(stat -f%z "$ZIP")\"" "$APPCAST" || return 1
  zip_is_stapled || return 1
  return 0
}

if [ "$FORCE_REBUILD" = "0" ] && artifacts_ready; then
  say "Build v$VERSION (build $CUR_BUILD)"
  skip "already built, signed, notarized and in the appcast — skipping (pass --rebuild to force)"
  BUILD="$CUR_BUILD"
  BUILT_THIS_RUN=0
else
  say "Building & packaging v$VERSION"
  "$APP_DIR/scripts/release.sh" "$VERSION"
  BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")   # new integer build
  BUILT_THIS_RUN=1
fi

[ -f "$ZIP" ] || { echo "ERROR: $ZIP missing after build." >&2; exit 1; }
[ -f "$DMG" ] || { echo "ERROR: $DMG missing after build." >&2; exit 1; }
# Deltas produced for THIS build are named sider<BUILD>-<prev>.delta.
DELTAS=("$DIST"/sider"$BUILD"-*.delta)
[ -e "${DELTAS[0]}" ] || DELTAS=()   # first release ever has no delta

# ── 2. De-duplicate the appcast ────────────────────────────────────────────────
# generate_appcast MERGES into the existing appcast: items it did not regenerate this run
# are carried over verbatim. So every aborted attempt at the same version leaves its own
# item behind — same <sparkle:shortVersionString>, same enclosure URL (the URL has no build
# number in it), but a stale length and EdDSA signature, plus deltas that no longer exist
# on disk. Publishing that hands Sparkle an item whose file will never match.
#
# Keep the highest <sparkle:version> per short version, drop the rest, and delete the
# orphaned .delta files that belonged to the dropped builds. Text is spliced rather than
# re-serialized so the surviving items stay byte-identical (and the sparkle: prefixes with
# them — an XML round-trip that renames them to ns0: breaks every client).
say "Checking appcast for duplicate versions"
PRUNED=$(python3 - "$APPCAST" <<'PY'
import re, sys

path = sys.argv[1]
xml = open(path, encoding="utf-8").read()
items = [(m.start(), m.end(), m.group(0)) for m in re.finditer(r"(?s)[ \t]*<item>.*?</item>\n", xml)]

def field(text, tag):
    m = re.search(r"<%s>(.*?)</%s>" % (tag, tag), text)
    return m.group(1) if m else None

best = {}
for start, end, text in items:
    short = field(text, "sparkle:shortVersionString")
    build = int(field(text, "sparkle:version") or 0)
    if short is None:
        continue
    if short not in best or build > best[short][0]:
        best[short] = (build, start, end)

keep = {v[1] for v in best.values()}
dropped = [(field(t, "sparkle:version"), field(t, "sparkle:shortVersionString"))
           for s, e, t in items if s not in keep]
if dropped:
    out, cursor = [], 0
    for start, end, _ in items:
        if start in keep:
            continue
        out.append(xml[cursor:start])
        cursor = end
    out.append(xml[cursor:])
    open(path, "w", encoding="utf-8").write("".join(out))
print(" ".join("%s/%s" % (b, s) for b, s in dropped))
PY
)
if [ -n "$PRUNED" ]; then
  for entry in $PRUNED; do
    STALE_BUILD="${entry%%/*}"
    echo "  dropped stale appcast item: build $STALE_BUILD (${entry##*/})"
    rm -f "$DIST"/sider"$STALE_BUILD"-*.delta
  done
  python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "$APPCAST" \
    || { echo "ERROR: appcast is not well-formed after pruning — fix it by hand." >&2; exit 1; }
else
  skip "no duplicates"
fi

# ── 3. Commit + tag + push source repo ─────────────────────────────────────────
say "Committing & tagging source repo ($SOURCE_REPO)"

# Releases ship from main. `git push origin HEAD` pushes the CURRENT branch, so running
# this from a feature branch would tag the release off that branch and push it to
# origin/<feature> — while the skip test below compares against origin/main and so would
# never see itself as done. Every installed user auto-updates from what this run publishes;
# doing that from a half-finished branch is not a mistake worth making silently.
# Escape hatch for a deliberate off-main release: ALLOW_ANY_BRANCH=1 scripts/ship.sh X.Y
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ] && [ "${ALLOW_ANY_BRANCH:-0}" != "1" ]; then
  echo "ERROR: on branch '$BRANCH', not main — refusing to publish a release from it." >&2
  echo "       Merge to main and re-run, or force with ALLOW_ANY_BRANCH=1." >&2
  exit 1
fi

# Upfront size guard — see MAX_COMMIT_FILE_MB.
BIG=$(git status --porcelain | sed 's/^...//' | tr -d '"' | while IFS= read -r f; do
        [ -f "$f" ] || continue
        sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
        # `if`, not `[ … ] && echo`: the latter leaves the loop with a non-zero status on
        # its last iteration, which `set -e` turns into a silent death of the whole script.
        if [ "$sz" -gt $((MAX_COMMIT_FILE_MB * 1024 * 1024)) ]; then
          echo "  $((sz / 1024 / 1024)) MB  $f"
        fi
      done)
if [ -n "$BIG" ]; then
  echo "ERROR: files over ${MAX_COMMIT_FILE_MB} MB are about to be committed:" >&2
  echo "$BIG" >&2
  echo "       Delete them or add them to .gitignore, then re-run. Pushing them will" >&2
  echo "       stall and fail with HTTP 408." >&2
  exit 1
fi

if [ "$BUILT_THIS_RUN" = "1" ]; then
  # Fresh build: the whole tree is what was just built and signed, so commit all of it.
  git add -A
else
  # Resuming: the build was skipped, so the tree may have moved on since — work started
  # after the failed attempt is NOT in the binaries being published. Staging it would
  # commit unrelated work-in-progress under "release: vX" and describe a release that
  # does not contain it. Only the release record goes in: the version bump and dist/
  # (zip, dmg, deltas, appcast). Not sider.app — by now it can be a newer local build,
  # and the artifact that actually ships is the zip in dist/.
  git add Info.plist dist 2>/dev/null || true
  OTHER=$(git status --porcelain -- . ':!Info.plist' ':!dist' | head -5)
  if [ -n "$OTHER" ]; then
    echo "  note: leaving unrelated working-tree changes uncommitted (build was skipped):"
    printf '%s\n' "$OTHER" | sed 's/^/    /'
  fi
fi
if git diff --cached --quiet; then
  skip "nothing new to commit"
else
  git commit -q -m "release: v$VERSION"
fi

HEAD_SHA=$(git rev-parse HEAD)
REMOTE_TAG=$(git ls-remote --tags origin "refs/tags/$TAG" 2>/dev/null | awk '{print $1}' | head -1)
if [ -n "$REMOTE_TAG" ]; then
  # Already published: never move a tag other clones may have fetched.
  if [ "$REMOTE_TAG" = "$HEAD_SHA" ]; then skip "tag $TAG already pushed"
  else echo "  WARNING: $TAG already exists on origin at ${REMOTE_TAG:0:7}, not HEAD (${HEAD_SHA:0:7}). Leaving it alone."; fi
else
  # Local-only tag from an aborted run: safe to move onto the current commit.
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    if [ "$(git rev-parse "$TAG^{commit}")" != "$HEAD_SHA" ]; then
      git tag -f "$TAG" >/dev/null
      echo "  moved local tag $TAG onto ${HEAD_SHA:0:7} (it was never pushed)"
    else
      skip "local tag $TAG already on HEAD"
    fi
  else
    git tag "$TAG"
  fi
fi

# A push can die on a flaky link; retry before giving up so a transient blip does not
# strand the release half-published.
push_with_retry() {
  local what="$1"; shift
  for attempt in 1 2 3; do
    if git push "$@"; then return 0; fi
    echo "  push of $what failed (attempt $attempt/3), retrying in 10s…" >&2
    sleep 10
  done
  echo "ERROR: could not push $what after 3 attempts. Fix the cause and re-run this script -" >&2
  echo "       it will resume from here without rebuilding." >&2
  return 1
}
# Refresh the remote-tracking ref first: a stale origin/$BRANCH makes the skip test below
# answer from whenever this clone last fetched, not from what the remote actually holds.
git fetch -q origin "$BRANCH" >/dev/null 2>&1 || true
if [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo none)" ]; then
  skip "origin/$BRANCH already at HEAD"
else
  push_with_retry "$BRANCH" origin "HEAD:refs/heads/$BRANCH"
fi
if [ -n "$(git ls-remote --tags origin "refs/tags/$TAG" 2>/dev/null)" ]; then
  skip "tag $TAG already on origin"
else
  push_with_retry "tag $TAG" origin "$TAG"
fi

# ── 4. GitHub Release on the release repo ──────────────────────────────────────
say "Publishing GitHub Release $TAG on $RELEASE_REPO"
# ${x[@]+"${x[@]}"} — bash 3.2 (what macOS ships) treats an empty array as unset under
# `set -u`, so a first-ever release with no deltas would abort here.
ASSETS=("$ZIP" "$DMG" ${DELTAS[@]+"${DELTAS[@]}"})
if gh release view "$TAG" -R "$RELEASE_REPO" >/dev/null 2>&1; then
  # Upload ONLY what is missing or the wrong size. `--clobber` deletes the existing asset
  # before sending the new one, so blindly re-uploading a byte-identical file takes the
  # download URL offline for the length of the upload — and if the run is interrupted in
  # that window, the asset is simply gone. That is exactly how the landing's stable
  # sider.dmg link and the appcast enclosures got a 404 once. Sizes are what Sparkle
  # validates against the appcast, so a size match is the right test.
  REMOTE=$(gh release view "$TAG" -R "$RELEASE_REPO" --json assets \
             -q '.assets[] | "\(.name) \(.size)"' 2>/dev/null || true)
  MISSING=()
  for a in "${ASSETS[@]}"; do
    if printf '%s\n' "$REMOTE" | grep -qxF "$(basename "$a") $(stat -f%z "$a")"; then
      skip "$(basename "$a") already uploaded"
    else
      MISSING+=("$a")
    fi
  done
  if [ ${#MISSING[@]} -eq 0 ]; then
    skip "all assets already match"
  else
    # One file per call: a single multi-file upload that fails partway (GitHub answers
    # HTTP 422 for an asset whose delete has not landed yet) leaves the rest unsent.
    for a in "${MISSING[@]}"; do
      echo "  uploading $(basename "$a")…"
      gh release upload "$TAG" "$a" -R "$RELEASE_REPO" --clobber
    done
  fi
else
  gh release create "$TAG" "${ASSETS[@]}" -R "$RELEASE_REPO" \
    --title "$TAG" --notes "sider $VERSION"
  echo "Uploaded:$(for a in "${ASSETS[@]}"; do printf ' %s' "$(basename "$a")"; done)"
fi

# ── 5. Publish appcast to gh-pages (the SUFeedURL host) ─────────────────────────
say "Publishing appcast.xml to $RELEASE_REPO (gh-pages + main)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$RELEASE_REPO" "$WORK" -- -q
cd "$WORK"
git config user.email "$(cd "$APP_DIR" && git config user.email)"
git config user.name  "$(cd "$APP_DIR" && git config user.name)"
for BR in gh-pages main; do
  git checkout -q "$BR"
  cp "$APPCAST" appcast.xml
  if ! git diff --quiet; then
    git add appcast.xml
    git commit -q -m "Publish $TAG appcast (build $BUILD)"
    git push -q origin "$BR"
    echo "  pushed appcast → $BR"
  else
    skip "$BR already up to date"
  fi
done
cd "$APP_DIR"

# ── 6. Verify the live appcast serves the new build ────────────────────────────
say "Verifying live appcast (GitHub Pages may take up to ~1 min to rebuild)"
FEED=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$PLIST")
for i in $(seq 1 12); do
  LIVE=$(curl -s -H 'Cache-Control: no-cache' "$FEED?nocache=$RANDOM" || true)
  if printf '%s' "$LIVE" | grep -q "<sparkle:version>$BUILD</sparkle:version>"; then
    echo "  ✅ Live appcast advertises build $BUILD (v$VERSION)."
    # Sparkle refuses an enclosure whose size does not match what it downloaded, so the
    # only verification worth anything compares three things: what the live feed promises,
    # what is on disk here, and what the CDN actually hands out. This used to just print
    # the numbers, which meant a 404 or a truncated asset still ended in "DONE" — the
    # exact failure it was added to catch. A full GET (not HEAD) on purpose: it proves the
    # bytes are really servable, and that is what broke last time.
    BAD=0
    for f in "sider-$VERSION.zip" "sider.dmg"; do
      # The .dmg is not in the appcast (release.sh removes it before generate_appcast runs,
      # so the tool never lists it as an update enclosure) — its reference size is the file
      # we just uploaded. The .zip's reference is the length the feed advertises.
      case "$f" in
        *.zip) WANT=$(printf '%s' "$LIVE" | sed -n "s/.*$f\" length=\"\([0-9]*\)\".*/\1/p" | head -1) ;;
        *)     WANT=$(stat -f%z "$DMG") ;;
      esac
      # The \n matters: `read` returns non-zero on EOF without a delimiter, which under
      # `set -e` would kill the run one line short of DONE.
      read -r code size < <(curl -s -o /dev/null -w '%{http_code} %{size_download}\n' -L \
        "https://github.com/$RELEASE_REPO/releases/latest/download/$f")
      if [ "$code" = "200" ] && [ -n "$WANT" ] && [ "$size" = "$WANT" ]; then
        echo "  ✓ $f → HTTP $code, $size bytes (matches)"
      else
        echo "  ✗ $f → HTTP $code, $size bytes, expected ${WANT:-<not in appcast>}" >&2
        BAD=1
      fi
    done
    if [ "$BAD" = "1" ]; then
      echo "ERROR: the live appcast is published but its assets do not check out." >&2
      echo "       Sparkle will reject an enclosure whose size differs — do not leave this." >&2
      echo "       Re-run this script: it re-uploads any asset whose size is wrong." >&2
      exit 1
    fi
    say "DONE — v$VERSION is live. Users on build $((BUILD-1)) will auto-update."
    exit 0
  fi
  echo "  attempt $i/12: not live yet, waiting 10s…"; sleep 10
done
echo "WARNING: live appcast did not show build $BUILD within ~2 min." >&2
echo "Assets and git are pushed; Pages may just be slow. Re-check: $FEED" >&2
echo "Re-running this script is safe and will skip straight to the verification." >&2
exit 1
