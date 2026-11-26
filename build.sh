#!/bin/bash
set -euo pipefail

APP="BetterFinder"
DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="/Applications/Better Finder.app"
OLD="$DIR/$APP.app"
BUILD="$DIR/.build"
TARGET="26.0"
KC="$DIR/.signing/betterfinder.keychain-db"
KCPASS="betterfinder-local"
IDENTITY="Better Finder Local Signing"

if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
	export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$BUILD"
echo "› Compiling (arm64, macOS $TARGET)…"
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$DIR/Sources" -name "*.swift" | sort)
swiftc -O \
	-target "arm64-apple-macos$TARGET" \
	-sdk "$SDK" \
	-framework AppKit -framework CoreServices -framework IOKit -framework Security \
	"${SOURCES[@]}" \
	-o "$BUILD/$APP"

ICNS="$DIR/Resources/AppIcon.icns"
if [[ ! -f "$ICNS" ]]; then
	echo "› Drawing the icon…"
	mkdir -p "$DIR/Resources"
	rm -rf "$BUILD/AppIcon.iconset"
	"$BUILD/$APP" icon "$BUILD/AppIcon.iconset" >/dev/null
	iconutil -c icns "$BUILD/AppIcon.iconset" -o "$ICNS"
fi

STAGE="$BUILD/$APP.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$DIR/Info.plist" "$STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :BFProjectFolder string $DIR" "$STAGE/Contents/Info.plist"
cp "$BUILD/$APP" "$STAGE/Contents/MacOS/$APP"
cp "$ICNS" "$STAGE/Contents/Resources/AppIcon.icns"

if [[ ! -f "$KC" ]]; then
	echo "› Making the private signing identity (once)…"
	mkdir -p "$DIR/.signing"
	T="$(mktemp -d)"
	cat > "$T/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CFG
	openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" -days 3650 -config "$T/cfg" 2>/dev/null
	openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout "pass:$KCPASS" -name "$IDENTITY" 2>/dev/null
	BEFORE="$(security list-keychains -d user | xargs)"
	security create-keychain -p "$KCPASS" "$KC"
	eval "security list-keychains -d user -s $BEFORE"
	security set-keychain-settings "$KC"
	security unlock-keychain -p "$KCPASS" "$KC"
	security import "$T/id.p12" -k "$KC" -P "$KCPASS" -T /usr/bin/codesign >/dev/null
	security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null
	rm -rf "$T"
fi

echo "› Signing…"
security unlock-keychain -p "$KCPASS" "$KC"
ORIG="$(security list-keychains -d user | xargs)"
restore() { eval "security list-keychains -d user -s $ORIG"; }
trap restore EXIT
eval "security list-keychains -d user -s $ORIG \"$KC\""
codesign --force --timestamp=none -s "$IDENTITY" -i com.ilya.betterfinder "$STAGE"
restore
trap - EXIT

rm -rf "$BUNDLE"
ditto "$STAGE" "$BUNDLE"
rm -rf "$BUILD"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -d "$OLD" ]]; then
	"$LSREGISTER" -u "$OLD" 2>/dev/null || true
	rm -rf "$OLD"
fi
touch "$BUNDLE"
"$LSREGISTER" -f "$BUNDLE" 2>/dev/null || true
echo "✓ Built and installed $BUNDLE"

if [[ $# -gt 0 ]]; then
	"$BUNDLE/Contents/MacOS/$APP" "$@"
fi
