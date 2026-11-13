#!/bin/zsh
# Checks a release DMG before it is published (or signed for in-app updates). Fails on the first problem.
#
#   scripts/verify-release.sh DMG --version 1.4.0 --team TEAMID [--no-sig]    production release
#   scripts/verify-release.sh DMG --version 1.4.0 --dev [--no-sig] [--public-key KEY]
#                                                                             local/ad-hoc build: skips the
#                                                                             Developer ID, notarization and
#                                                                             Gatekeeper checks, and says so
# Checks: DMG.sha256 matches; DMG.sig is a valid Ed25519 signature by the release key (unless --no-sig);
# the DMG is signed by TEAMID, notarized (stapled) and accepted by Gatekeeper; the app inside has the right
# bundle ID and version, a valid deep code signature with hardened runtime, the expected entitlements only
# (no get-task-allow, no runtime exceptions), the same team, a stapled ticket, and Gatekeeper accepts it.
set -euo pipefail
cd "$(dirname "$0")/.."

DMG=""; VERSION=""; TEAM=""; DEV=0; NOSIG=0; PUBKEY=""
while (( $# )); do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --team) TEAM="$2"; shift 2 ;;
    --dev) DEV=1; shift ;;
    --no-sig) NOSIG=1; shift ;;
    --public-key) PUBKEY="$2"; shift 2 ;;
    -*) echo "Unknown option $1" >&2; exit 64 ;;
    *) DMG="$1"; shift ;;
  esac
done
[[ -f "$DMG" && -n "$VERSION" ]] || { echo "Usage: scripts/verify-release.sh DMG --version X.Y.Z (--team TEAMID | --dev) [--no-sig]" >&2; exit 64; }
(( DEV )) || [[ -n "$TEAM" ]] || { echo "A production check needs --team TEAMID (or --dev for a local build)." >&2; exit 64; }

BUNDLE_ID="io.github.wahdanz.maccleaner"
EXPECTED_ENTITLEMENTS="com.apple.security.automation.apple-events"
ok()   { print "  ✓ $1"; }
bad()  { print "  ✗ $1" >&2; exit 1; }
skip() { print "  – skipped (--dev): $1"; }

print "Verifying $DMG (version $VERSION$( (( DEV )) && print ', DEV mode: no Developer ID/notarization checks'))"

# 1. Checksum and release-key signature
[[ -f "$DMG.sha256" ]] || bad "missing $DMG.sha256"
(cd "$(dirname "$DMG")" && shasum -a 256 -c "$(basename "$DMG").sha256" >/dev/null) && ok "SHA-256 matches" || bad "SHA-256 does not match"
if (( NOSIG )); then
  print "  – not checked yet: $DMG.sig (made later by scripts/sign-release.sh)"
else
  [[ -f "$DMG.sig" ]] || bad "missing $DMG.sig — the app won't offer this release as an update"
  swift scripts/release-key.swift verify "$DMG" "$DMG.sig" "$PUBKEY" >/dev/null && ok "Ed25519 release signature is valid" || bad "release signature is not valid"
fi

# 2. The DMG itself
if (( DEV )); then
  skip "DMG Developer ID signature, notarization ticket, Gatekeeper"
else
  codesign --verify --strict "$DMG" 2>/dev/null && ok "DMG signature is valid" || bad "DMG is not signed (or the signature is broken)"
  DMG_TEAM=$(codesign -dv "$DMG" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [[ "$DMG_TEAM" == "$TEAM" ]] && ok "DMG signed by team $TEAM" || bad "DMG signed by team '$DMG_TEAM', expected $TEAM"
  xcrun stapler validate "$DMG" >/dev/null 2>&1 && ok "DMG has a stapled notarization ticket" || bad "DMG is not notarized/stapled"
  spctl --assess --type open --context context:primary-signature "$DMG" 2>/dev/null && ok "Gatekeeper accepts the DMG" || bad "Gatekeeper rejects the DMG"
fi

# 3. The app inside
MNT=$(mktemp -d); trap 'hdiutil detach -quiet -force "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null || true' EXIT
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$DMG" || bad "the DMG can't be mounted"
APP="$MNT/Mac Cleaner.app"
[[ -d "$APP" ]] || bad "no 'Mac Cleaner.app' in the DMG"
PLIST="$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == "$BUNDLE_ID" ]] && ok "bundle ID $BUNDLE_ID" || bad "wrong bundle ID"
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
[[ "$APP_VERSION" == "$VERSION" ]] && ok "app version $VERSION" || bad "app version is $APP_VERSION, expected $VERSION"
codesign --verify --deep --strict "$APP" 2>/dev/null && ok "app code signature is valid (deep, strict)" || bad "app code signature is not valid"
FLAGS=$(codesign -dv "$APP" 2>&1 | sed -n 's/.*flags=\(0x[0-9a-f]*\)(\(.*\)).*/\2/p')
[[ "$FLAGS" == *runtime* ]] && ok "hardened runtime is on" || bad "hardened runtime is off (flags: $FLAGS)"
ENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - - 2>/dev/null \
       | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(sorted(k for k,v in d.items() if v)))' 2>/dev/null || true)
[[ "$ENTS" == "$EXPECTED_ENTITLEMENTS" ]] && ok "entitlements: $ENTS" || bad "unexpected entitlements: '$ENTS' (expected: $EXPECTED_ENTITLEMENTS)"
if (( DEV )); then
  skip "app Developer ID team, notarization ticket, Gatekeeper"
else
  APP_TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [[ "$APP_TEAM" == "$TEAM" ]] && ok "app signed by team $TEAM" || bad "app signed by team '$APP_TEAM', expected $TEAM"
  codesign -dv "$APP" 2>&1 | grep -q '^Timestamp=' && ok "secure timestamp present" || bad "no secure timestamp (sign with --timestamp)"
  xcrun stapler validate "$APP" >/dev/null 2>&1 && ok "app has a stapled notarization ticket" || bad "app is not notarized/stapled"
  spctl --assess --type execute "$APP" 2>/dev/null && ok "Gatekeeper accepts the app" || bad "Gatekeeper rejects the app"
fi
print "All checks passed$( (( DEV )) && print ' (DEV mode: this is NOT a releasable build)')."
