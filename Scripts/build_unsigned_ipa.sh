#!/bin/sh

set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_ROOT"

BUILD_DIR="$PROJECT_ROOT/.build"
OUTPUT_DIR="$BUILD_DIR/unsigned"
DERIVED_DATA_PATH="$BUILD_DIR/DerivedData"
ARCHIVE_PATH="$OUTPUT_DIR/SimpleReader.xcarchive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/SimpleReader.app"
IPA_PATH="$OUTPUT_DIR/SimpleReader-unsigned.ipa"
STAGE_DIR=

cleanup() {
	if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
		rm -rf "$STAGE_DIR"
	fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if ! command -v xcodebuild >/dev/null 2>&1; then
	echo "error: xcodebuild not found; install and select full Xcode." >&2
	exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$ARCHIVE_PATH" "$IPA_PATH"

echo "Building unsigned iOS archive..."
xcodebuild \
	-project "$PROJECT_ROOT/SimpleReader.xcodeproj" \
	-scheme SimpleReader \
	-configuration Release \
	-destination 'generic/platform=iOS' \
	-derivedDataPath "$DERIVED_DATA_PATH" \
	-archivePath "$ARCHIVE_PATH" \
	CODE_SIGNING_ALLOWED=NO \
	CODE_SIGNING_REQUIRED=NO \
	CODE_SIGN_IDENTITY='' \
	DEVELOPMENT_TEAM='' \
	archive

if [ ! -d "$APP_PATH" ]; then
	echo "error: archive succeeded but app bundle was not found at: $APP_PATH" >&2
	exit 1
fi

STAGE_DIR=$(mktemp -d "$OUTPUT_DIR/ipa-stage.XXXXXX")
mkdir -p "$STAGE_DIR/Payload"
ditto "$APP_PATH" "$STAGE_DIR/Payload/SimpleReader.app"
(
	cd "$STAGE_DIR"
	ditto -c -k --sequesterRsrc --keepParent Payload "$IPA_PATH"
)

if command -v unzip >/dev/null 2>&1; then
	unzip -tq "$IPA_PATH" >/dev/null
fi

echo "Unsigned IPA created: $IPA_PATH"
