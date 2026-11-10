#!/bin/sh
# Builds the release: build/Claude Profiles.app (universal) and
# build/Claude-Profiles.zip, the asset attached to the GitHub release.
#
# Signing is ad hoc unless these are set in the environment:
#   CDP_SIGN_IDENTITY   a signing identity in this Mac's keychain, e.g.
#                       "Developer ID Application: Example Org (TEAMID1234)".
#                       The app and its helper are then signed with it, with
#                       the hardened runtime and a secure timestamp.
#   CDP_NOTARY_PROFILE  a notarytool keychain profile
#                       (xcrun notarytool store-credentials <name> ...).
#                       The zip is then notarized, the ticket is stapled to
#                       the app, and the zip is made again from the stapled app.
set -eu
cd "$(dirname "$0")/.."

APP="build/Claude Profiles.app"
ZIP="build/Claude-Profiles.zip"

if [ -n "${CDP_NOTARY_PROFILE:-}" ] && [ -z "${CDP_SIGN_IDENTITY:-}" ]; then
    echo "CDP_NOTARY_PROFILE needs CDP_SIGN_IDENTITY: an ad hoc build cannot be notarized." >&2
    exit 1
fi

CDP_ARCHS="arm64 x86_64" bin/cdp build "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "${CDP_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$CDP_NOTARY_PROFILE" --wait
    # Fails, and stops the build, when the submission was not accepted: there
    # is then no ticket to staple.
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo "Built $APP and $ZIP ($(bin/cdp version))"
