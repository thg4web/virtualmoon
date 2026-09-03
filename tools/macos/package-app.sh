#!/bin/bash
# package-app.sh - assemble one self-contained "Virtual Moon Atlas.app" (arm64)
# holding the whole 8-program suite over a single Contents/Resources data set,
# then wrap it in a compressed .dmg.
#
# Run tools/macos/build-suite.sh first (builds the binaries + helper dylibs).
#
# Layout:
#   Contents/MacOS/        atlun catlun calclun datlun notelun photlun weblun
#                          cclun  +  libplan404.dylib libcspice.dylib
#   Contents/Frameworks/   libssl.3.dylib libcrypto.3.dylib   (calclun / weblun
#                          Synapse dlopen()s these from ../Frameworks)
#   Contents/Resources/    Textures data Database Encyclopedia Probes Apollo
#                          doc Personnages "My Images" language BaseData
#
# atlun is the main executable; its toolbar / menus reach the others. cclun is
# an alternate launcher; catlun is the catalog editor. Cross-launch works
# because every sibling is a bare name in Contents/MacOS/ next to the running
# binary (11-combined-bundle-macos.patch); each program's GetAppDir probe
# (ParamStr(0)/../Resources) lands on the shared Contents/Resources/.
#
# Also emitted: "VMA Menu" (cclun.app), a few-KB wrapper .app whose compiled
# arm64 stub (vmamenu.c) re-exec()s cclun inside the fat bundle so the hub is
# independently Spotlight-launchable. Both .apps must install into one folder.
#
# Output (staging tree, libs, .dmg) goes under the build workspace, not the
# checkout - default ~/vma-build, prompted, or set VMA_BUILD.
#
# BASE DATA (the ~250 MB texture / database / kernel set) is not in git. Get it
# once (see tools/macos/README.md, step 3) into <workspace>/basedata, or point
# VMA_BASEDATA at the dir that directly contains Textures/ Database/ ... e.g.
#   VMA_BASEDATA=/path/basedata/share/virtualmoon tools/macos/package-app.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"

# --- build workspace ------------------------------------------------------
# Staging, bundled libs and the .dmg land here - out of your home dir and out
# of the git checkout. Use the same dir you gave build-suite.sh.
default_workdir="$HOME/vma-build"
if   [ -n "${VMA_BUILD:-}" ]; then WORKDIR="$VMA_BUILD"
elif [ -t 0 ]; then
  read -r -p "Build workspace [$default_workdir]: " WORKDIR
  WORKDIR="${WORKDIR:-$default_workdir}"
else
  WORKDIR="$default_workdir"
  echo "==> build workspace: $WORKDIR  (set VMA_BUILD to change)"
fi
WORKDIR="${WORKDIR/#\~/$HOME}"
mkdir -p "$WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"

# source root: a bare clone keeps the programs at $REPO; the THG overlay repo
# keeps them under upstream/
if   [ -f "$REPO/virtualmoon/atlun.lpi" ];          then SRC="$REPO"
elif [ -f "$REPO/upstream/virtualmoon/atlun.lpi" ]; then SRC="$REPO/upstream"
else echo "cannot find the VMA source (no virtualmoon/atlun.lpi under $REPO)" >&2; exit 1
fi

# prog : binary path relative to $SRC
BINS=(
  "atlun:virtualmoon/units/aarch64-darwin-cocoa/atlun"
  "catlun:catlun/units/aarch64-darwin-cocoa/catlun"
  "calclun:calclun/calclun"
  "datlun:datlun/units/aarch64-darwin-cocoa/datlun"
  "notelun:notelun/notelun"
  "photlun:photlun/photlun"
  "weblun:weblun/weblun"
  "cclun:cclun/cclun"
)
PLAN404="$SRC/virtualmoon/library/plan404/libplan404.dylib"
CSPICE="$SRC/calclun/cspice/libcspice.dylib"
LANG_DIR="$SRC/language"
BASEDATA="$SRC/BaseData"
ICO="$SRC/virtualmoon/atlun.ico"

DIST="$WORKDIR/dist"
LIBS="$DIST/libs"
SSL="$LIBS/libssl.3.dylib"
CRYPTO="$LIBS/libcrypto.3.dylib"

# base data: explicit override, else probe the two layouts fetched by step 3
# (install_data.sh -> basedata/share/..., the .deb -> basedata/usr/share/...)
if [ -n "${VMA_BASEDATA:-}" ]; then
  DATA="$VMA_BASEDATA"
elif [ -e "$WORKDIR/basedata/share/virtualmoon/Textures" ]; then
  DATA="$WORKDIR/basedata/share/virtualmoon"
elif [ -e "$WORKDIR/basedata/usr/share/virtualmoon/Textures" ]; then
  DATA="$WORKDIR/basedata/usr/share/virtualmoon"
else
  DATA="$WORKDIR/basedata/share/virtualmoon"   # nonexistent - the check below reports it
fi

STAGE="$DIST/pkg-stage"
APP="$STAGE/Virtual Moon Atlas.app"
DMG="$DIST/Virtual-Moon-Atlas-arm64.dmg"
VERSION="9.1"

# --- binaries / helper dylibs present? ------------------------------------
miss=0
for kv in "${BINS[@]}"; do
  [ -f "$SRC/${kv#*:}" ] || { echo "missing binary: ${kv#*:}" >&2; miss=1; }
done
for f in "$PLAN404" "$CSPICE"; do
  [ -f "$f" ] || { echo "missing: ${f#"$SRC"/}" >&2; miss=1; }
done
[ "$miss" = 0 ] || { echo "-> run tools/macos/build-suite.sh first" >&2; exit 1; }

# --- base data present? -------------------------------------------------
if [ ! -e "$DATA/Textures/WAC_LOWSUN/L1/0.jpg" ]; then
  cat >&2 <<EOF
base data not found under:
  $WORKDIR/basedata   (checked share/virtualmoon and usr/share/virtualmoon)

Get it once - either:
  A) mkdir -p "$WORKDIR/basedata" && cd "$WORKDIR/basedata"
     curl -L -o basedata.deb "https://sourceforge.net/projects/virtualmoon/files/1-%20virtualmoon/Version%209.0/virtualmoon-basedata_9.0_all.deb/download"
     ar x basedata.deb && tar xf data.tar.zst
  B) brew install wget && bash "$REPO/install_data.sh" "$WORKDIR/basedata"
Or set VMA_BASEDATA to a dir that directly contains Textures/ Database/ ...
See tools/macos/README.md step 3.
EOF
  exit 1
fi
for f in "$LANG_DIR" "$BASEDATA"; do
  [ -e "$f" ] || { echo "missing (should be in the checkout): $f" >&2; exit 1; }
done

# --- OpenSSL 3: derive the bundled pair if not supplied ----------------
if [ ! -f "$SSL" ] || [ ! -f "$CRYPTO" ]; then
  echo "==> deriving libssl/libcrypto from Homebrew openssl@3"
  command -v brew >/dev/null || { echo "need 'brew install openssl@3' (or drop a fixed pair in $LIBS/)" >&2; exit 1; }
  KEG="$(brew --prefix openssl@3 2>/dev/null || true)/lib"
  [ -f "$KEG/libssl.3.dylib" ] || { echo "openssl@3 not installed: brew install openssl@3" >&2; exit 1; }
  mkdir -p "$LIBS"
  cp "$KEG/libssl.3.dylib" "$KEG/libcrypto.3.dylib" "$LIBS/"
  chmod u+w "$SSL" "$CRYPTO"
  install_name_tool -id @loader_path/libssl.3.dylib    "$SSL"
  install_name_tool -id @loader_path/libcrypto.3.dylib "$CRYPTO"
  old_crypto="$(otool -L "$SSL" | awk '/libcrypto\.3\.dylib/{print $1; exit}')"
  install_name_tool -change "$old_crypto" @loader_path/libcrypto.3.dylib "$SSL"
  codesign -s - -f "$CRYPTO" "$SSL"
fi

echo "==> clean stage"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

echo "==> 8 binaries -> Contents/MacOS"
for kv in "${BINS[@]}"; do
  name="${kv%%:*}"
  cp "$SRC/${kv#*:}" "$APP/Contents/MacOS/$name"
  chmod +x "$APP/Contents/MacOS/$name"
done

echo "==> dylibs"
cp "$PLAN404" "$APP/Contents/MacOS/libplan404.dylib"
cp "$CSPICE"  "$APP/Contents/MacOS/libcspice.dylib"
chmod +w "$APP/Contents/MacOS/libplan404.dylib" "$APP/Contents/MacOS/libcspice.dylib"
install_name_tool -id @executable_path/libplan404.dylib "$APP/Contents/MacOS/libplan404.dylib"
install_name_tool -id @executable_path/libcspice.dylib  "$APP/Contents/MacOS/libcspice.dylib"
cp "$SSL"    "$APP/Contents/Frameworks/libssl.3.dylib"
cp "$CRYPTO" "$APP/Contents/Frameworks/libcrypto.3.dylib"

echo "==> icon"
if command -v magick >/dev/null && [ -f "$ICO" ]; then
  magick "$ICO" -resize 512x512 "$STAGE/icon.png" 2>/dev/null || magick "${ICO}[0]" "$STAGE/icon.png"
  sips -s format icns "$STAGE/icon.png" --out "$APP/Contents/Resources/atlun.icns" >/dev/null 2>&1 || true
  rm -f "$STAGE/icon.png"
else
  echo "    (ImageMagick 'magick' not found - skipping icon, app gets the generic one)"
fi

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Virtual Moon Atlas</string>
  <key>CFBundleDisplayName</key>     <string>Virtual Moon Atlas</string>
  <key>CFBundleIdentifier</key>      <string>org.virtualmoon.suite</string>
  <key>CFBundleVersion</key>         <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleSignature</key>       <string>????</string>
  <key>CFBundleExecutable</key>      <string>atlun</string>
  <key>CFBundleIconFile</key>        <string>atlun.icns</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>LSMinimumSystemVersion</key>  <string>11.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key> <string>Virtual Moon Atlas by Christian Legrand and Patrick Chevalley. GPL.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> data -> Contents/Resources (copies ~250 MB)"
for d in Textures Database Encyclopedia data Probes Apollo doc Personnages "My Images"; do
  [ -e "$DATA/$d" ] && cp -R "$DATA/$d" "$APP/Contents/Resources/"
done
cp -R "$LANG_DIR" "$APP/Contents/Resources/language"
cp -R "$BASEDATA" "$APP/Contents/Resources/BaseData"

# catlun hard-errors ("Missing L1 slices") without Textures/WAC; the base data
# ships WAC_LOWSUN only. Point WAC at it (see PORT_REPORT sec 7).
if [ ! -e "$APP/Contents/Resources/Textures/WAC" ] && [ -e "$APP/Contents/Resources/Textures/WAC_LOWSUN" ]; then
  ln -s WAC_LOWSUN "$APP/Contents/Resources/Textures/WAC"
fi

echo "==> adhoc sign"
codesign --force --deep --sign - "$APP" >/dev/null
codesign --verify --deep "$APP" && echo "    signature OK"

echo "==> sidecar: cclun.app  (Spotlight: \"VMA Menu\")"
SIDE="$STAGE/cclun.app"
mkdir -p "$SIDE/Contents/MacOS" "$SIDE/Contents/Resources"
cc -arch arm64 -O2 -Wall -o "$SIDE/Contents/MacOS/vmamenu" "$HERE/vmamenu.c"
[ -f "$APP/Contents/Resources/atlun.icns" ] && cp "$APP/Contents/Resources/atlun.icns" "$SIDE/Contents/Resources/atlun.icns"
cat > "$SIDE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>VMA Menu</string>
  <key>CFBundleDisplayName</key>     <string>VMA Menu</string>
  <key>CFBundleIdentifier</key>      <string>org.virtualmoon.vmamenu</string>
  <key>CFBundleVersion</key>         <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleSignature</key>       <string>????</string>
  <key>CFBundleExecutable</key>      <string>vmamenu</string>
  <key>CFBundleIconFile</key>        <string>atlun.icns</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>LSMinimumSystemVersion</key>  <string>11.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$SIDE/Contents/PkgInfo"
codesign --force --deep --sign - "$SIDE" >/dev/null
codesign --verify --deep "$SIDE" && echo "    sidecar signature OK"

echo "==> drop-to-install layout + README"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
Virtual Moon Atlas - native macOS (Apple Silicon)

One app, the whole suite: atlun (3D Moon globe), plus calclun, datlun,
notelun, photlun, weblun, cclun and catlun. Open atlun and reach the
others from its toolbar and menus.

Install:  drag BOTH "Virtual Moon Atlas.app" and "VMA Menu" (cclun.app)
onto the Applications folder, keeping them together. "VMA Menu" is a small
wrapper so the launcher/hub also shows up in Spotlight; it needs the main
app beside it in the same folder.

First launch:  this build is ad-hoc signed, not notarized, so macOS
Gatekeeper will refuse the first open. Either:
  * Right-click (Control-click) the app -> Open -> Open, once, OR
  * Terminal:  xattr -dr com.apple.quarantine "/Applications/Virtual Moon Atlas.app"

Requires Apple Silicon and macOS 11 or later. The Moon texture and
database set is bundled inside the app.
TXT

echo "==> build dmg"
rm -f "$DMG"
hdiutil create -volname "Virtual Moon Atlas" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null

echo "==> done"
du -sh "$APP"
ls -lh "$DMG"
echo
echo "    run in place:  open \"$APP\""
echo "    staging tree (keep or delete):  $STAGE"
