#!/bin/bash
#
# Builds Overmark.app and packages it into a DMG.
#
# The app bundle is what makes the macOS permission system work: TCC keys
# permissions on the bundle identifier, so a bare executable can never appear
# in "Privacy & Security". Shipping a bundle with a stable identifier is what
# lets the user grant Screen Recording and Accessibility to Overmark itself
# instead of to the terminal that launched it.
#
# Usage:
#   Scripts/build-app.sh [--debug] [--sign "Developer ID Application: ..."]
#                        [--notary-profile MY_PROFILE]
#
# Signing is automatic when the keychain holds a "Developer ID Application"
# certificate: the script picks the first one. Force ad-hoc signing (e.g. in
# CI) with OVERMARK_SIGN_IDENTITY="-". Without any Developer ID certificate
# the app is signed ad-hoc, which is enough to run it locally but not to
# distribute it: macOS will still ask the user to confirm an unidentified
# developer.
#
# After the DMG is built, a Developer ID app can be notarized when a keychain
# profile was stored with `xcrun notarytool store-credentials`, passed as
# OVERMARK_NOTARY_PROFILE (or --notary-profile). See Support/DISTRIBUTION.md.

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APP_NAME="Overmark"
readonly BUNDLE_ID="com.overmark.app"
readonly SIGNING_IDENTITY="${OVERMARK_SIGN_IDENTITY:-}"
readonly NOTARY_PROFILE="${OVERMARK_NOTARY_PROFILE:-}"

CONFIGURATION="release"
IDENTITY="-"
NOTARY_PROFILE_OPT=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--debug)
			CONFIGURATION="debug"
			shift
			;;
		--sign)
			IDENTITY="$2"
			shift 2
			;;
		--notary-profile)
			NOTARY_PROFILE_OPT="$2"
			shift 2
			;;
		-h | --help)
			sed -n '2,22p' "${BASH_SOURCE[0]}"
			exit 0
			;;
		*)
			echo "unknown option: $1" >&2
			exit 1
			;;
	esac
done

if [[ -n "$NOTARY_PROFILE_OPT" ]]; then
	NOTARY_ID="$NOTARY_PROFILE_OPT"
elif [[ -n "$NOTARY_PROFILE" ]]; then
	NOTARY_ID="$NOTARY_PROFILE"
else
	NOTARY_ID=""
fi

# Automatic signing: when the user did not pick an identity, look for a
# Developer ID certificate in the keychain and use the first one. This keeps
# local builds frictionless once the certificate exists, and still falls back
# to ad-hoc (with its stable pinned requirement) before that.
if [[ -z "$SIGNING_IDENTITY" && "$IDENTITY" == "-" ]]; then
	DETECTED="$(security find-identity -v -p codesigning 2>/dev/null \
		| sed -n 's/^[[:space:]]*[0-9][0-9]*) .*"\(Developer ID Application: .*\)"/\1/p' \
		| head -n1 || true)"
	if [[ -n "$DETECTED" ]]; then
		IDENTITY="$DETECTED"
		echo "==> Signing identity found: $IDENTITY"
	fi
elif [[ -n "$SIGNING_IDENTITY" ]]; then
	IDENTITY="$SIGNING_IDENTITY"
fi
readonly IS_DEVELOPER_ID="$([[ "$IDENTITY" == "Developer ID Application:"* ]] && echo yes || echo no)"

readonly DIST="$ROOT/build"
readonly APP_BUNDLE="$DIST/$APP_NAME.app"
readonly CONTENTS="$APP_BUNDLE/Contents"
readonly MACOS_DIR="$CONTENTS/MacOS"
readonly RESOURCES_DIR="$CONTENTS/Resources"

echo "==> Building ($CONFIGURATION)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
	swift build --package-path "$ROOT" -c "$CONFIGURATION"

case "$CONFIGURATION" in
	release) BINARY="$ROOT/.build/release/$APP_NAME" ;;
	*) BINARY="$ROOT/.build/debug/$APP_NAME" ;;
esac

if [[ ! -x "$BINARY" ]]; then
	echo "error: the binary was not produced at $BINARY" >&2
	exit 1
fi

echo "==> Assembling the bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BINARY" "$MACOS_DIR/$APP_NAME"
cp "$ROOT/Support/Info.plist" "$CONTENTS/Info.plist"

# `PkgInfo` is optional but expected by some macOS tooling.
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> Drawing the icon"
readonly ICONSET="$DIST/$APP_NAME.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# The sizes `iconutil` expects for an .icns file.
render_icon() {
	local size="$1"
	local name="$2"
	DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
		swift "$ROOT/Scripts/make-icon.swift" "$size" "$ICONSET/$name" >/dev/null
}

render_icon 16 "icon_16x16.png"
render_icon 32 "icon_16x16@2x.png"
render_icon 32 "icon_32x32.png"
render_icon 64 "icon_32x32@2x.png"
render_icon 128 "icon_128x128.png"
render_icon 256 "icon_128x128@2x.png"
render_icon 256 "icon_256x256.png"
render_icon 512 "icon_256x256@2x.png"
render_icon 512 "icon_512x512.png"
render_icon 1024 "icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/$APP_NAME.icns"

echo "==> Signing"
# The entitlement is what lets the app move the cursor, which the Accessibility
# permission covers. `get-task-allow` is only wanted in debug builds.
ENTITLEMENTS="$ROOT/Support/Overmark.entitlements"
# An ad-hoc signature gets a designated requirement of `cdhash <hash>`, which
# changes on every rebuild. macOS keys the Screen Recording and Accessibility
# permissions on that requirement, so a rebuilt app stops matching the row the
# user already granted and the permission silently reads as "not set up".
#
# Pinning the requirement to the bundle identifier keeps it stable across
# rebuilds, so the permissions the user granted survive them.
#
# A real Developer ID signature already has a stable requirement
# (`identifier ... and anchor apple`), so it is left untouched.
REQUIREMENTS=()
if [[ "$IDENTITY" == "-" ]]; then
    # The requirement is written to a file rather than passed with `-r`,
    # because the quoted `designated => identifier "..."` form is easy to
    # mangle through the shell.
    REQUIREMENTS_FILE="$DIST/$APP_NAME.requirements"
    printf 'designated => identifier "%s"\n' "$BUNDLE_ID" > "$REQUIREMENTS_FILE"
    REQUIREMENTS=(--requirements "$REQUIREMENTS_FILE")
fi

if [[ "$CONFIGURATION" == "release" ]]; then
	codesign --force --options runtime --timestamp \
		--entitlements "$ENTITLEMENTS" \
		--sign "$IDENTITY" \
		${REQUIREMENTS[@]+"${REQUIREMENTS[@]}"} \
		"$APP_BUNDLE"
else
	codesign --force --entitlements "$ENTITLEMENTS" \
		--sign "$IDENTITY" \
		${REQUIREMENTS[@]+"${REQUIREMENTS[@]}"} \
		"$APP_BUNDLE"
fi

codesign --verify --verbose=2 "$APP_BUNDLE"

echo "==> Packaging the DMG"
readonly DMG="$DIST/$APP_NAME.dmg"
readonly STAGING="$DIST/dmg-staging"

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"

# A symlink to /Applications turns the window into a drag-and-drop target.
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
	-volname "$APP_NAME" \
	-srcfolder "$STAGING" \
	-ov -format UDZO \
	"$DMG"

rm -rf "$STAGING" "$ICONSET"

# Notarization is only meaningful for a Developer ID signature, and it needs
# a profile stored once with `xcrun notarytool store-credentials`. The app
# itself is already signed with `--options runtime --timestamp`, which is
# what Gatekeeper checks.
if [[ "$IS_DEVELOPER_ID" == "yes" && "$CONFIGURATION" == "release" ]]; then
	if [[ -n "$NOTARY_ID" ]]; then
		echo "==> Notarizing the DMG (profile: $NOTARY_ID)"
		xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_ID" --wait
		xcrun stapler staple "$DMG"
		echo "==> Notarization stapled."
	else
		echo
		echo "Signed with a Developer ID certificate, but not notarized."
		echo "Store a credentials profile once with:"
		echo '  xcrun notarytool store-credentials OVERMARK_NOTARY'
		echo "and re-run with:"
		echo "  OVERMARK_NOTARY_PROFILE=OVERMARK_NOTARY Scripts/build-app.sh"
		echo "Guide: Support/DISTRIBUTION.md"
	fi
fi

echo
echo "Done."
echo "  App:  $APP_BUNDLE"
echo "  DMG:  $DMG"
if [[ "$IS_DEVELOPER_ID" == "yes" ]]; then
	echo
	echo "Signed with \"$IDENTITY\". Ready for distribution once notarized"
	echo "(Gatekeeper accepts Developer ID apps after notarization)."
elif [[ "$IDENTITY" == "-" ]]; then
	echo
	echo "Signed ad-hoc. macOS will ask you to confirm an unidentified developer"
	echo "the first time you open it. Once you have a Developer ID certificate"
	echo "the script picks it up automatically; you can also pass one with:"
	echo "  Scripts/build-app.sh --sign \"Developer ID Application: YOUR NAME (TEAMID)\""
fi
