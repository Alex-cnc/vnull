#!/bin/bash
set -euo pipefail

# 不依赖 Xcode GUI：用 SwiftPM 编译 App 源码，然后组装成 .app 包并做 ad-hoc 签名。
#
#   ./Scripts/build-app.sh            # Debug
#   ./Scripts/build-app.sh release    # Release
#
#   DOYAH_ARCH=x86_64 ./Scripts/build-app.sh    # 单架构 Intel
#   DOYAH_ARCH=universal ./Scripts/build-app.sh # 通用二进制（arm64 + x86_64）
#
# 为什么需要架构选项（NFR-COMP-02）：默认产物是**单架构 arm64**，
# 实测 `lipo -info` 为 `Non-fat file … arm64` —— 在 Intel 机上**根本起不来**。
# 需求要求"支持 Apple Silicon 与 Intel"，所以构建侧必须能产出 x86_64 / universal。
# Intel 实机与 Rosetta 的启动验证仍需真机（构建通过 ≠ 真机可跑）。
#
# 产物：dist/DoyahStudio.app
#
# 说明：ad-hoc 签名 + entitlements 足以在本机运行（App Sandbox + 网络客户端）。
# 如果要分发或使用钥匙串的持久授权，请换用自己的开发者证书签名。

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CONFIGURATION="${1:-debug}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFT="${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
SCRATCH="${ROOT}/.build"
SCRATCH_X86="${ROOT}/.build-x86"
CACHE="${ROOT}/.build-cache"
APP="${ROOT}/dist/DoyahStudio.app"
DOYAH_ARCH="${DOYAH_ARCH:-}"

export DEVELOPER_DIR
export CLANG_MODULE_CACHE_PATH="${SCRATCH}/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="${SCRATCH}/swift-module-cache"
mkdir -p "${SCRATCH}" "${CACHE}" "${CLANG_MODULE_CACHE_PATH}" "${SWIFT_MODULE_CACHE_PATH}"

# 独立 scratch 需要自己那份依赖检出。沙箱里没有网络，让 SwiftPM 现拉会**卡死**
# （实测：新 scratch 里 checkouts 一直是空的）。所以从主 scratch 复制一份检出。
seed_scratch() {
  local scratch="$1"
  if [ -d "${scratch}/checkouts" ] && [ -n "$(ls -A "${scratch}/checkouts" 2>/dev/null)" ]; then
    return
  fi
  if [ -d "${SCRATCH}/checkouts" ]; then
    mkdir -p "${scratch}"
    cp -R "${SCRATCH}/checkouts" "${scratch}/" 2>/dev/null || true
    cp -R "${SCRATCH}/repositories" "${scratch}/" 2>/dev/null || true
  fi
}

# 编译并回显可执行文件路径。`$2` 为空表示本机原生架构（保持历史行为）。
#
# 注意 `${arch_args[@]+…}` 这个写法：macOS 自带的是 bash 3.2，在 `set -u` 下
# 展开**空数组**会报 `unbound variable` —— 原生架构那条路径正是空数组（踩过一次）。
build_product() {
  local scratch="$1" arch="$2"
  seed_scratch "${scratch}"
  local arch_args=()
  if [ -n "${arch}" ]; then arch_args=(--arch "${arch}"); fi
  echo "==> 编译 DoyahStudioApp (${CONFIGURATION}${arch:+, ${arch}})" >&2
  "${SWIFT}" build \
    --product DoyahStudioApp \
    --configuration "${CONFIGURATION}" \
    --disable-sandbox \
    --package-path "${ROOT}" \
    --cache-path "${CACHE}" \
    --scratch-path "${scratch}" \
    --manifest-cache local \
    ${arch_args[@]+"${arch_args[@]}"} \
    -Xswiftc -disable-sandbox >&2
  local bin_dir
  bin_dir="$("${SWIFT}" build \
    --configuration "${CONFIGURATION}" \
    --disable-sandbox \
    --package-path "${ROOT}" \
    --cache-path "${CACHE}" \
    --scratch-path "${scratch}" \
    --manifest-cache local \
    ${arch_args[@]+"${arch_args[@]}"} \
    --show-bin-path)"
  echo "${bin_dir}/DoyahStudioApp"
}

BIN=""
BIN_X86=""
case "${DOYAH_ARCH}" in
  ""|"$(uname -m)")
    BIN="$(build_product "${SCRATCH}" "")"
    ;;
  arm64|x86_64)
    if [ "${DOYAH_ARCH}" = "x86_64" ]; then
      BIN="$(build_product "${SCRATCH_X86}" "x86_64")"
    else
      BIN="$(build_product "${SCRATCH}" "arm64")"
    fi
    ;;
  universal)
    BIN="$(build_product "${SCRATCH}" "arm64")"
    BIN_X86="$(build_product "${SCRATCH_X86}" "x86_64")"
    ;;
  *)
    echo "未知 DOYAH_ARCH：${DOYAH_ARCH}（可用：arm64 / x86_64 / universal）"
    exit 64
    ;;
esac

if [ ! -x "${BIN}" ]; then
  echo "未找到可执行文件：${BIN}"
  exit 1
fi

echo "==> 组装 ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
if [ -n "${BIN_X86}" ]; then
  echo "==> lipo 合成通用二进制（arm64 + x86_64）"
  lipo -create -output "${APP}/Contents/MacOS/DoyahStudio" "${BIN}" "${BIN_X86}"
else
  cp "${BIN}" "${APP}/Contents/MacOS/DoyahStudio"
fi
echo "==> 架构：$(lipo -info "${APP}/Contents/MacOS/DoyahStudio" 2>&1 | sed 's/^.*: //')"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>DoyahStudio</string>
    <key>CFBundleIdentifier</key>
    <string>studio.doyah.DoyahStudio</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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

# 应用图标（法斗 Doyah）：App/Resources/AppIcon.icns。
# 用 sips/iconutil 校验过含全部 10 个尺寸；缺了它 Dock 与访达里就是白纸图标。
ICON="${ROOT}/App/Resources/AppIcon.icns"
if [ -f "${ICON}" ]; then
  cp "${ICON}" "${APP}/Contents/Resources/AppIcon.icns"
else
  echo "警告：缺少 ${ICON}，应用将没有图标（可用 Scripts/make-app-icon.swift 重新生成）"
fi

# 第三方许可声明随产品分发（审核与合规都要能随包拿到）
echo "==> 附带第三方许可声明"
cp "${ROOT}/THIRD-PARTY-NOTICES.md" "${APP}/Contents/Resources/THIRD-PARTY-NOTICES.md"

# 是否带 App 沙箱：默认带。DOYAH_NO_SANDBOX=1 产出**本地用**的非沙箱构建，
# 内嵌终端才是完整 shell（R-18 路线③的局部验证）；分发构建务必保持默认。
if [ "${DOYAH_NO_SANDBOX:-0}" = "1" ]; then
  ENTITLEMENTS="${ROOT}/App/DoyahStudio-unsandboxed.entitlements"
  echo "==> 注意：本次为**非沙箱**构建（仅供本机使用，不要拿去分发）"
else
  ENTITLEMENTS="${ROOT}/App/DoyahStudio.entitlements"
fi

echo "==> ad-hoc 签名"
codesign --force --sign - \
  --entitlements "${ENTITLEMENTS}" \
  --timestamp=none \
  "${APP}" 2>&1 | tail -3

echo ""
echo "完成：${APP}"
echo "运行：open \"${APP}\""
