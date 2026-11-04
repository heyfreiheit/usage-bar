#!/bin/zsh
# Baut Usage Bar aus dem Quellcode und installiert die App nach ~/Applications.
#
#   zsh scripts/install.sh            bauen, installieren, starten
#   NO_OPEN=1 zsh scripts/install.sh  nur bauen und installieren
#   APP_DIR=/pfad zsh scripts/install.sh   anderer Zielordner
#
# Exit-Codes: 0 ok, 2 macOS zu alt, 3 Command Line Tools fehlen, 4 Swift zu alt, 5 Build fehlgeschlagen
set -uo pipefail

SRC="${0:A:h:h}"
APP_DIR="${APP_DIR:-$HOME/Applications}"
APP="$APP_DIR/Usage Bar.app"
SCRATCH="$HOME/Library/Caches/usage-bar-build"

say() { print -- "[usage-bar] $*"; }

# 1. macOS 15 oder neuer
major=$(sw_vers -productVersion | cut -d. -f1)
if (( major < 15 )); then
  say "FEHLER macOS $(sw_vers -productVersion) ist zu alt, Usage Bar braucht macOS 15 (Sequoia) oder neuer."
  exit 2
fi

# 2. Command Line Tools (bringen swift und git mit)
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
  say "FEHLER Die Xcode Command Line Tools fehlen. Installieren mit: xcode-select --install"
  exit 3
fi

# 3. Swift 6 oder neuer
swift_major=$(xcrun swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | head -1)
if [[ -z "$swift_major" ]] || (( swift_major < 6 )); then
  say "FEHLER Swift ${swift_major:-?} ist zu alt, nötig ist Swift 6. Command Line Tools aktualisieren: softwareupdate --list, dann das Paket 'Command Line Tools' installieren."
  exit 4
fi

# 4. Bauen
say "Baue Usage Bar (dauert beim ersten Mal 1 bis 2 Minuten) ..."
if ! xcrun swift build -c release --package-path "$SRC" --scratch-path "$SCRATCH"; then
  say "FEHLER Build fehlgeschlagen, Ausgabe siehe oben."
  exit 5
fi
BIN="$SCRATCH/release/UsageBar"

# 5. App-Paket zusammensetzen
pkill -x UsageBar 2>/dev/null || true
mkdir -p "$APP_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UsageBar"
version=$(git -C "$SRC" describe --tags --always 2>/dev/null || echo "1.0")

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Usage Bar</string>
  <key>CFBundleDisplayName</key><string>Usage Bar</string>
  <key>CFBundleIdentifier</key><string>com.heyfreiheit.usagebar</string>
  <key>CFBundleExecutable</key><string>UsageBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1
say "Installiert: $APP"

# 6. Starten
if [[ "${NO_OPEN:-0}" != "1" ]]; then
  open "$APP"
  say "Gestartet. Oben rechts in der Menüleiste steht jetzt 'Login', das Anmeldefenster für claude.ai geht automatisch auf."
fi
say "FERTIG"
