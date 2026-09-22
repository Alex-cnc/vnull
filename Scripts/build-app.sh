#!/bin/bash
set -euo pipefail

# 不依赖 Xcode GUI：用 SwiftPM 编译 App 源码，然后组装成 .app 包并做 ad-hoc 签名。
#
#   ./Scripts/build-app.sh            # Debug
#   ./Scripts/build-app.sh release    # Release
#
# 产物：dist/DoyahStudio.app
#
# 说明：ad-hoc 签名 + entitlements 足以在本机运行（App Sandbox + 网络客户端）。
# 如果要分发或使用钥匙串的持久授权，请换用自己的开发者证书签名。

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFT="${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
SCRATCH="${ROOT}/.build"
CACHE="${ROOT}/.build-cache"
APP="${ROOT}/dist/DoyahStudio.app"

export DEVELOPER_DIR
export CLANG_MODULE_CACHE_PATH="${SCRATCH}/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="${SCRATCH}/swift-module-cache"
mkdir -p "${SCRATCH}" "${CACHE}" "${CLANG_MODULE_CACHE_PATH}" "${SWIFT_MODULE_CACHE_PATH}"

echo "==> 编译 DoyahStudioApp (${CONFIGURATION})"
"${SWIFT}" build \
  --product DoyahStudioApp \
  --configuration "${CONFIGURATION}" \
  --disable-sandbox \
  --package-path "${ROOT}" \
  --cache-path "${CACHE}" \
  --scratch-path "${SCRATCH}" \
  --manifest-cache local \
  -Xswiftc -disable-sandbox

BIN_DIR="$("${SWIFT}" build \
  --configuration "${CONFIGURATION}" \
  --disable-sandbox \
  --package-path "${ROOT}" \
  --cache-path "${CACHE}" \
  --scratch-path "${SCRATCH}" \
  --manifest-cache local \
  --show-bin-path)"

BIN="${BIN_DIR}/DoyahStudioApp"
if [ ! -x "${BIN}" ]; then
  echo "未找到可执行文件：${BIN}"
  exit 1
fi

echo "==> 组装 ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/DoyahStudio"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>DoyahStudio</string>
    <key>CFBundleIdentifier</key>
    <string>studio.doyah.DoyahStudio</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Doyah Studio</string>
    <key>CFBundleDisplayName</key>
    <string>Doyah Studio</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# 第三方许可声明随产品分发（审核与合规都要能随包拿到）
echo "==> 附带第三方许可声明"
cp "${ROOT}/THIRD-PARTY-NOTICES.md" "${APP}/Contents/Resources/THIRD-PARTY-NOTICES.md"

echo "==> ad-hoc 签名"
codesign --force --sign - \
  --entitlements "${ROOT}/App/DoyahStudio.entitlements" \
  --timestamp=none \
  "${APP}" 2>&1 | tail -3

echo ""
echo "完成：${APP}"
echo "运行：open \"${APP}\""
