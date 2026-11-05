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

sign_nested() {
  # --deep does not reliably reach Mach-O files under Resources, and notarisation requires every one
  # of them to carry the identity and the hardened runtime. Sign the host's binaries first, innermost out.
  # Only Mach-O files: the .NET publish also contains PE .dll assemblies, which codesign cannot sign and
  # notarisation does not need.
  local id="$1" n=0
  while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q "Mach-O"; then
      codesign --force --options runtime --entitlements Packaging/entitlements.plist --sign "$id" "$f" 2>/dev/null || echo "  ! could not sign $f"
      n=$((n+1))
    fi
  done < <(find "$APP/Contents/Resources/host" -type f \( -name "*.dylib" -o -perm -u+x \) -print0)
  echo "▸ signed $n nested Mach-O files"
}

if [ -n "$IDENTITY" ]; then
  echo "▸ signing with: $IDENTITY"
  sign_nested "$IDENTITY"
  if ! codesign --force --deep --options runtime --timestamp --entitlements Packaging/entitlements.plist --sign "$IDENTITY" "$APP" 2>/dev/null; then
    echo "▸ timestamp service unavailable; signing without a secure timestamp (fine for local use, re-sign before notarising)"
    codesign --force --deep --options runtime --entitlements Packaging/entitlements.plist --sign "$IDENTITY" "$APP"
  fi
else
  echo "▸ no Developer ID found; ad-hoc signing"
  codesign --force --deep --entitlements Packaging/entitlements.plist --sign - "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "▸ signature OK"

if [ "${1:-}" = "install" ]; then
  echo "▸ installing to /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
fi
echo "done: $APP"
