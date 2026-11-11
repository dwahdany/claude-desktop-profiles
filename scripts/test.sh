#!/bin/zsh
# Release checks: builds the app (skip with --no-build), verifies the bundle,
# then installs the zip the way a download arrives (quarantined) into a
# throwaway HOME and runs the app's first-launch setup there. The real
# ~/Applications, profiles and watchdog are never touched; Claude.app is only
# read for its icon.
#
# The build it makes is ad hoc unless CDP_SIGN_IDENTITY is in the environment.
# To test a signed or notarized build from scripts/build.sh, pass --no-build;
# without it this script stops rather than build over one, whatever is in the
# environment.
set -uo pipefail
cd "${0:A:h:h}"

fails=0
check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    print -- "ok   $name"
  else
    print -- "FAIL $name"
    fails=$((fails + 1))
  fi
}

APP="build/Claude Profiles.app"
HELPER_APP="Contents/Resources/Claude Profiles Helper.app"
HELPER_REL="$HELPER_APP/Contents/MacOS/Claude Profiles Helper"
version=$(zsh bin/cdp version)

# The team a bundle is signed by; empty for an ad hoc signature or none.
team() {
  local t
  t=$(codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [[ "$t" == "not set" ]] || print -r -- "$t"
}
# Not grep -q: it stops reading at the match, and under pipefail a codesign
# still writing would turn that into a failure.
runtime() { codesign -dv "$1" 2>&1 | grep 'flags=.*runtime' >/dev/null }

check "cdp parses" zsh -n bin/cdp
check "unit checks pass (zsh scripts/test-unit.zsh)" zsh scripts/test-unit.zsh
if [[ "${1:-}" != "--no-build" ]]; then
  # The build below takes the place of the one that is there, and it is only
  # as signed and notarized as this shell's environment makes it. A signed
  # build is never replaced unasked.
  if [[ -n "$(team "$APP")" ]]; then
    print -- "build/ holds a build signed by team $(team "$APP"), which a build made here would replace."
    print -- "Test that build as it is:  scripts/test.sh --no-build"
    print -- "Or remove build/ first to have this script make and test its own."
    exit 1
  fi
  scripts/build.sh >/dev/null 2>&1 || { print -- "FAIL build"; exit 1 }
fi

signer=$(team "$APP")
if [[ -n "$signer" ]]; then
  print -- "testing a build signed by team $signer"
  xcrun stapler validate "$APP" >/dev/null 2>&1 &&
    print -- "notarization ticket: stapled" || print -- "notarization ticket: none"
  check "app has the hardened runtime" runtime "$APP"
  check "helper has the hardened runtime" runtime "$APP/$HELPER_APP"
  check "helper is signed by the same team" test "$(team "$APP/$HELPER_APP")" = "$signer"
else
  print -- "testing an ad hoc signed build"
fi

universal() { [[ "$(lipo -archs "$1")" == *arm64* && "$(lipo -archs "$1")" == *x86_64* ]] }
check "app binary is universal" universal "$APP/Contents/MacOS/ClaudeProfiles"
check "helper binary is universal" universal "$APP/$HELPER_REL"
check "signature verifies" codesign --verify --deep --strict "$APP"
check "Info.plist version is $version" test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$version"
check "bundled cdp is bin/cdp" cmp bin/cdp "$APP/Contents/Resources/cdp"
check "app has its icon" cmp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# ---- first launch of a downloaded copy, in a sandbox HOME -------------------

sandbox=${$(mktemp -d):A}
label="com.claude-desktop-profiles.test-$$"
trap 'launchctl bootout "gui/$(id -u)/$label" 2>/dev/null; rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/Applications" "$sandbox/Library/Application Support/Claude-Test" "$sandbox/Applications/Claude Test.app"
cp build/Claude-Profiles.zip "$sandbox/"
xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;$(uuidgen)" "$sandbox/Claude-Profiles.zip"
ditto -x -k "$sandbox/Claude-Profiles.zip" "$sandbox/Applications"
installed="$sandbox/Applications/Claude Profiles.app"
cached="$sandbox/Library/Caches/claude-desktop-profiles/Claude Profiles Helper.app"
launcher="$sandbox/Applications/Claude Test.app"

quarantined() { xattr -p com.apple.quarantine "$1" }
not_quarantined() { ! xattr -rl "$1" | grep -q com.apple.quarantine }
# Exit 3 = no app with that pid; a quarantined helper is SIGKILLed instead.
helper_runs() { "$1" focus 999999; [[ $? == 3 ]] }
setup() { HOME="$sandbox" CDP_WATCH_LABEL="$label" zsh "$installed/Contents/Resources/cdp" setup "$@" }

check "download is quarantined" quarantined "$installed/$HELPER_REL"
check "setup succeeds" setup --if-needed
check "setup records version and location" grep -qxF "$version $installed/Contents/Resources/cdp" "$sandbox/Library/Caches/claude-desktop-profiles/setup"
check "cached helper is not quarantined" not_quarantined "$cached"
# Byte-identical, so not re-signed: the copy that runs keeps the signature the
# app was built with.
check "cached helper is the shipped helper" cmp "$installed/$HELPER_REL" "$cached/Contents/MacOS/Claude Profiles Helper"
check "cached helper signature verifies" codesign --verify "$cached"
check "cached helper keeps the app's signer" test "$(team "$cached")" = "$signer"
check "cached helper runs" helper_runs "$cached/Contents/MacOS/Claude Profiles Helper"
check "launcher rebuilt as an applet" test -x "$launcher/Contents/MacOS/applet"
check "launcher bundles this cdp" cmp bin/cdp "$launcher/Contents/Resources/cdp"
check "launcher cdp is not quarantined" not_quarantined "$launcher/Contents/Resources/cdp"
check "launcher signature verifies" codesign --verify "$launcher"
check "watchdog points at the app's cdp" grep -qF "$installed/Contents/Resources/cdp" "$sandbox/Library/LaunchAgents/$label.plist"
check "setup leaves the app's signature intact" codesign --verify --deep --strict "$installed"
touch -t 200001010000 "$launcher"
setup --if-needed >/dev/null 2>&1
check "setup --if-needed skips when current" test "$(stat -f %Sm -t %Y "$launcher")" = 2000

(( fails == 0 )) && print -- "all passed" || { print -- "$fails failed"; exit 1 }
