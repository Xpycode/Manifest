#!/bin/bash
#
# package-dmg.sh — build a distributable Manifest DMG, then sign, notarize, and
# staple it. The .app inside is expected to ALREADY be Developer ID-signed,
# notarized, and stapled (see scripts/sign-app.sh / Xcode Organizer export).
# This wraps it in a drag-to-Applications disk image and notarizes the image.
#
# Usage:
#   scripts/package-dmg.sh [VERSION] [APP_PATH] [NOTARY_PROFILE]
#
# Defaults:
#   VERSION        1.0.0
#   APP_PATH       04_Exports/Manifest v1.0.0/Manifest.app
#   NOTARY_PROFILE Manifest   (an xcrun notarytool keychain profile — see below)
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in your login keychain.
#      Create/download via Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸
#      "+" ▸ Developer ID Application. Verify with:
#          security find-identity -v -p codesigning | grep "Developer ID Application"
#   2. A notarytool credential profile. Create it once with an App Store Connect
#      API key (recommended) or an app-specific password:
#          xcrun notarytool store-credentials "Manifest" \
#              --key /path/AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
#      (Credential fields are in ~/.claude/apple-developer.md.)
#
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root

VERSION="${1:-1.0.0}"
APP_PATH="${2:-04_Exports/Manifest v1.0.0/Manifest.app}"
NOTARY_PROFILE="${3:-Manifest}"
SIGN_ID="Developer ID Application"   # matched by codesign against the keychain

VOL_NAME="Manifest ${VERSION}"
OUT_DIR="04_Exports"
DMG_PATH="${OUT_DIR}/Manifest-${VERSION}.dmg"
STAGING="$(mktemp -d)"

cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

echo "==> Packaging Manifest ${VERSION}"
echo "    app:   $APP_PATH"
echo "    dmg:   $DMG_PATH"

# --- sanity checks -----------------------------------------------------------
if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: app not found at: $APP_PATH" >&2
    exit 1
fi

echo "==> Verifying the app is signed, notarized, and stapled"
spctl -a -vvv -t install "$APP_PATH" || {
    echo "ERROR: the app is not accepted by Gatekeeper. Sign + notarize the app first." >&2
    exit 1
}
xcrun stapler validate "$APP_PATH" || {
    echo "WARNING: app has no stapled ticket (it may still notarize online)." >&2
}

# --- build the DMG -----------------------------------------------------------
echo "==> Staging disk image contents"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_PATH"

if command -v create-dmg >/dev/null 2>&1; then
    echo "==> Building DMG with create-dmg (styled)"
    create-dmg \
        --volname "$VOL_NAME" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 110 \
        --icon "Manifest.app" 150 190 \
        --app-drop-link 450 190 \
        --hide-extension "Manifest.app" \
        --no-internet-enable \
        "$DMG_PATH" \
        "$STAGING" || {
            echo "create-dmg failed; falling back to hdiutil" >&2
            hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGING" \
                -ov -format UDZO "$DMG_PATH"
        }
else
    echo "==> Building DMG with hdiutil (plain — 'brew install create-dmg' for a styled image)"
    hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGING" \
        -ov -format UDZO "$DMG_PATH"
fi

# --- sign the DMG ------------------------------------------------------------
echo "==> Signing the DMG"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG_PATH"
codesign --verify --verbose "$DMG_PATH"

# --- notarize + staple -------------------------------------------------------
echo "==> Submitting to notary service (profile: $NOTARY_PROFILE)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling the ticket"
xcrun stapler staple "$DMG_PATH"

echo "==> Final Gatekeeper check"
spctl -a -vvv -t install "$DMG_PATH" || true

echo ""
echo "✅ Done: $DMG_PATH"
echo "   Upload it to a GitHub Release:"
echo "     gh release create v${VERSION} \"$DMG_PATH\" -R Xpycode/Manifest \\"
echo "       --title \"Manifest ${VERSION}\" --notes \"…\""
