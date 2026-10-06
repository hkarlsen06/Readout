#!/bin/bash
# Usage: ./release.sh 1.2.3
# Builds, signs, notarizes, staples, verifies, tags, and publishes hkarlsen06/UsageBar v1.2.3.
# One-time setup: xcrun notarytool store-credentials usagebar --apple-id ... --team-id 48ZSLD4RMP
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: release.sh <version, e.g. 1.2.3>}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be N.N.N" >&2; exit 1; }
TAG="v$VERSION"
APP=UsageBar.app
ZIP=UsageBar.zip
# Stricter than the bare OU check: Apple Development certs carry the same team OU and would pass that.
REQ='anchor apple generic and identifier "dev.hkarlsen06.usagebar" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "48ZSLD4RMP"'

[ -z "$(git status --porcelain)" ] || { echo "git tree is dirty; commit or stash first" >&2; exit 1; }
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "tag $TAG already exists" >&2; exit 1; }
gh api user --jq .login >/dev/null   # fail now, not after a 10-minute notarization (gh auth status exits 1 over any stale account)

./build.sh "$VERSION"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$TMP/submit.zip"
xcrun notarytool submit "$TMP/submit.zip" --keychain-profile usagebar --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip so the shipped app has the ticket

# Verify the shipped artifact itself, not the build dir.
ditto -x -k "$ZIP" "$TMP/out"
V="$TMP/out/$APP"
spctl -a -vvv -t exec "$V"
codesign --verify --deep --strict "$V"
codesign --verify --deep --strict -R="$REQ" "$V"
xcrun stapler validate "$V"
[ "$(defaults read "$V/Contents/Info" CFBundleShortVersionString)" = "$VERSION" ]

git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --verify-tag --title "UsageBar $VERSION" --generate-notes
echo "Released $TAG"
