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
#                       The app is then notarized and the ticket stapled to
#                       it before the zip is made.
#
# The zip exists only after a run that finished: a build that fails, or is
# not accepted by the notary service, leaves nothing at that path.
set -eu
cd "$(dirname "$0")/.."

APP="build/Claude Profiles.app"
ZIP="build/Claude-Profiles.zip"
SUBMISSION="build/notary-submission.zip"

# bin/cdp reads an empty identity and "-" as ad hoc; so does this script.
IDENTITY="${CDP_SIGN_IDENTITY:-}"
[ "$IDENTITY" != "-" ] || IDENTITY=""
PROFILE="${CDP_NOTARY_PROFILE:-}"

if [ -n "$PROFILE" ] && [ -z "$IDENTITY" ]; then
    echo "CDP_NOTARY_PROFILE needs CDP_SIGN_IDENTITY: an ad hoc build cannot be notarized." >&2
    exit 1
fi

rm -f "$ZIP" "$SUBMISSION"
CDP_ARCHS="arm64 x86_64" bin/cdp build "$APP"

if [ -n "$PROFILE" ]; then
    trap 'rm -f "$SUBMISSION"' EXIT
    ditto -c -k --keepParent "$APP" "$SUBMISSION"
    xcrun notarytool submit "$SUBMISSION" --keychain-profile "$PROFILE" --wait
    # The gate: there is a ticket to staple only when the submission was
    # accepted, whatever notarytool's own exit status was.
    xcrun stapler staple "$APP" || {
        echo "No notarization ticket for $APP: the submission above was not accepted." >&2
        echo "Details: xcrun notarytool log <submission id> --keychain-profile \"$PROFILE\"" >&2
        exit 1
    }
    SIGNED="signed by $IDENTITY, notarized"
elif [ -n "$IDENTITY" ]; then
    SIGNED="signed by $IDENTITY, not notarized"
else
    SIGNED="ad hoc signed"
fi

ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $APP and $ZIP ($(bin/cdp version), $SIGNED)"
