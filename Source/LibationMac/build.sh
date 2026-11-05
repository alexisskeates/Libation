#!/usr/bin/env bash
# Builds Libation.app (native SwiftUI shell + bundled .NET LibationHost) into ./dist.
#   ./build.sh              build + sign (Developer ID if available, else ad-hoc)
#   ./build.sh install      ...and copy to /Applications
#   SKIP_HOST=1 ./build.sh  reuse the previously published host
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Libation"
DIST="dist"
APP="$DIST/$APP_NAME.app"
RID="${RID:-osx-$( [ "$(uname -m)" = arm64 ] && echo arm64 || echo x64 )}"
DOTNET="${DOTNET:-$(command -v dotnet || echo "$HOME/.dotnet/dotnet")}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"

if [ "${SKIP_HOST:-}" != "1" ]; then
  echo "▸ dotnet publish LibationHost ($RID)"
  "$DOTNET" publish ../LibationHost/LibationHost.csproj -c Release -r "$RID" --self-contained true \
    -p:PublishReadyToRun=true -o "$DIST/host" 2>&1 | grep -E "error|warn" || true
fi
[ -x "$DIST/host/LibationHost" ] || { echo "host publish failed"; exit 1; }

echo "▸ swift build (release)"
swift build -c release 2>&1 | grep -vE '^\[|Compiling|Emitting|Linking|Build complete' || true
BIN="$(swift build -c release --show-bin-path)/LibationMac"
[ -x "$BIN" ] || { echo "swift build failed"; exit 1; }

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/host"
cp "$BIN" "$APP/Contents/MacOS/LibationMac"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
[ -f Packaging/AppIcon.icns ] && cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R "$DIST/host/." "$APP/Contents/Resources/host/"

if [ -n "$IDENTITY" ]; then
  echo "▸ signing with: $IDENTITY"
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  echo "▸ no Developer ID found; ad-hoc signing"
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "▸ signature OK"

if [ "${1:-}" = "install" ]; then
  echo "▸ installing to /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
fi
echo "done: $APP"
