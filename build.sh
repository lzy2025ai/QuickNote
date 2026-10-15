#!/bin/bash
# 构建 随手记.app：./build.sh  （需要 macOS 13+，Xcode 15+ 或 Command Line Tools）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="QuickNote"
DISPLAY_NAME="随手记"
BUNDLE_ID="com.local.quicknote"
VERSION="1.0.0"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

# 本地 ad-hoc 签名，便于“登录时启动”等系统功能识别
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "✅ 已生成 $APP"
echo "   运行：open \"$APP\"    安装：cp -R \"$APP\" /Applications/"
