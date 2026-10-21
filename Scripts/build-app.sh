#!/bin/bash
#
# Builds Presentify.app and packages it into a DMG.
#
# The app bundle is what makes the macOS permission system work: TCC keys
# permissions on the bundle identifier, so a bare executable can never appear
# in "Privacy & Security". Shipping a bundle with a stable identifier is what
# lets the user grant Screen Recording and Accessibility to Presentify itself
# instead of to the terminal that launched it.
#
# Usage:
#   Scripts/build-app.sh [--debug] [--sign "Developer ID Application: ..."]
#
# Without a signing identity the app is signed ad-hoc, which is enough to run
# it locally but not to distribute it: macOS will still ask the user to
# confirm an unidentified developer.

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APP_NAME="Presentify"
readonly BUNDLE_ID="com.presentify.app"
readonly SIGNING_IDENTITY="${PRESENTIFY_SIGN_IDENTITY:-}"

CONFIGURATION="release"
IDENTITY="-"

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
		-h | --help)
			sed -n '2,20p' "${BASH_SOURCE[0]}"
			exit 0
			;;
		*)
			echo "unknown option: $1" >&2
			exit 1
			;;
	esac
done

if [[ -n "$SIGNING_IDENTITY" ]]; then
	IDENTITY="$SIGNING_IDENTITY"
fi

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
ENTITLEMENTS="$ROOT/Support/Presentify.entitlements"
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

echo
echo "Done."
echo "  App:  $APP_BUNDLE"
echo "  DMG:  $DMG"
if [[ "$IDENTITY" == "-" ]]; then
	echo
	echo "Signed ad-hoc. macOS will ask you to confirm an unidentified developer"
	echo "the first time you open it. For distribution, sign with:"
	echo "  Scripts/build-app.sh --sign \"Developer ID Application: YOUR NAME (TEAMID)\""
fi
