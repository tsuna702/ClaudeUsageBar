#!/bin/zsh
# ClaudeUsageBar.app 빌드
set -e
cd "$(dirname "$0")"
APP=ClaudeUsageBar.app
VERSION="${VERSION:-$(cat VERSION)}"
VERSION="${VERSION#v}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
swiftc -O *.swift -o "$APP/Contents/MacOS/ClaudeUsageBar" -framework Cocoa
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClaudeUsageBar</string>
  <key>CFBundleIdentifier</key><string>local.claude-usage-bar</string>
  <key>CFBundleExecutable</key><string>ClaudeUsageBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP ($VERSION)"
