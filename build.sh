#!/bin/zsh
# Builds Kestrel.app next to this script.
set -e
cd "$(dirname "$0")"
APP=Kestrel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -j"$(sysctl -n hw.ncpu)" -swift-version 5 -parse-as-library ColorMath.swift CubeLUT.swift ExifInfo.swift Metering.swift Histogram.swift XMPEdit.swift Store.swift Engine.swift Render.swift Storage.swift Notices.swift Shortcuts.swift Welcome.swift Keys.swift Commands.swift Layout.swift Undo.swift Chrome.swift Cells.swift FolderTree.swift ContentView.swift ContentView+Left.swift ContentView+Center.swift ContentView+Right.swift ContentView+Filter.swift ContentView+Bars.swift Views.swift App.swift -o "$APP/Contents/MacOS/Kestrel"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/"
ditto LUTs "$APP/Contents/Resources/LUTs"            # the built-in LUTs (V-Log Alchemy, Apache-2.0)
# Sign with the self-signed "Yohoa Studio" certificate when this Mac has it (a stable identity keeps macOS
# privacy permissions across rebuilds); otherwise ad-hoc.
if security find-identity -p codesigning | grep -q '"Yohoa Studio"'; then
  codesign -s "Yohoa Studio" --force "$APP" >/dev/null
else
  codesign -s - --force "$APP" >/dev/null
fi
echo "Built $PWD/$APP"
