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
mkdir -p "$APP/Contents/Resources/Logos"
cp Resources/Logos/*.svg "$APP/Contents/Resources/Logos/"
# Apple Silicon과 인텔용을 각각 빌드해서 하나로 합침 (유니버설)
TMP=$(mktemp -d)
for ARCH in arm64 x86_64; do
  swiftc -O *.swift -target "$ARCH-apple-macos14.0" -o "$TMP/$ARCH" -framework Cocoa
done
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/ClaudeUsageBar"
rm -rf "$TMP"
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
# 이 맥에 "UsageBar Local" 인증서가 있으면 그것으로 서명 (빌드가 바뀌어도 같은 앱으로 인식돼
# 키체인이 다시 묻지 않음). 없으면(GitHub 빌드 등) 임시 서명
SIGN="-"
if security find-identity -p codesigning 2>/dev/null | grep -q '"UsageBar Local"'; then SIGN="UsageBar Local"; fi
codesign --force --sign "$SIGN" "$APP"
echo "Built $APP ($VERSION, signed: $SIGN)"
