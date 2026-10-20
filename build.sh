#!/bin/bash
# 构建 随手记.app：./build.sh  （需要 macOS 13+，Xcode 15+ 或 Command Line Tools）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="QuickNote"
DISPLAY_NAME="随手记"
BUNDLE_ID="com.local.quicknote"
# 版本号 1.0.<构建号>：在 GitHub Actions 上构建号就是运行编号（运行页面标题里的 #N）
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-0}"
VERSION="1.0.$BUILD_NUMBER"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"

# 通用二进制：同时支持 Apple 芯片（arm64）和 Intel 芯片（x86_64）
ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/$APP_NAME"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# App 图标：由 Resources/AppIcon.iconset 生成 .icns
if [ -d Resources/AppIcon.iconset ]; then
    iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>QNCommit</key><string>$COMMIT</string>
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
