#!/bin/bash
set -euo pipefail

# 界面快照：把**真视图树**离屏渲染成 PNG，供助理逐张判定（队列 L-01）。
#
#   ./Scripts/make-ui-snapshots.sh              # 渲染全部，产物在 .build/ui-snapshots/
#   DOYAH_SNAPSHOT_DIR=/tmp/x ./Scripts/make-ui-snapshots.sh
#   ./Scripts/make-ui-snapshots.sh --filter testActivityBarAcrossEditions   # 只渲染一组
#
# 为什么不进 `verify-all.sh`：快照是**取证工具**，不是回归门禁 —— 塞进每轮门禁只会拖慢门禁。
# 它证明的是"界面长这样"，用例本身另有断言（档位生效 / 非空白）。
#
# **队列 L-13（2026-09-27）起：每张图都出中英两份**（`-zh` / `-en`），语言是**宿主参数**
# （`UISnapshot.writeBothLanguages` → `LocalizationManager.beginHostLanguage`：只覆盖、不落盘，
# 不动用户偏好）。脚本末尾会跑 `Scripts/check-ui-snapshot-languages.py` 把两件事判住：
# 成对齐全 + **语言确实到了像素上**（未注册为语言无关的图，中英两张必须逐字节不同）。
#
# 前置：`TestsUISnapshot/` 是独立 test target，依赖 `DoyahStudioApp`（SwiftPM 允许测试目标依赖可执行目标），
# 所以这里不碰生产代码、也不给 App 开任何测试后门。

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFT="${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
SCRATCH="${ROOT}/.build"
CACHE="${ROOT}/.build-cache"
OUT="${DOYAH_SNAPSHOT_DIR:-${SCRATCH}/ui-snapshots}"

export DEVELOPER_DIR
export CLANG_MODULE_CACHE_PATH="${SCRATCH}/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="${SCRATCH}/swift-module-cache"
export DOYAH_UI_SNAPSHOT=1
mkdir -p "${SCRATCH}" "${CACHE}" "${CLANG_MODULE_CACHE_PATH}" "${SWIFT_MODULE_CACHE_PATH}" "${OUT}"

cd "${ROOT}"

# 渲染前清一遍旧图：留着上一轮的文件，`ls` 会把"这次没渲染出来的"也列成绿。
rm -f "${OUT}"/*.png "${OUT}/manifest.json"

FILTER="UISnapshotTests"
if [ "${1:-}" = "--filter" ] && [ -n "${2:-}" ]; then
    FILTER="$2"
fi

echo "==> 渲染界面快照 → ${OUT}"
"${SWIFT}" test \
    --disable-sandbox \
    --package-path . \
    --cache-path "${CACHE}" \
    --scratch-path "${SCRATCH}" \
    --manifest-cache local \
    -Xswiftc -disable-sandbox \
    --filter "${FILTER}"

echo
echo "==> 产物清单"
python3 - "${OUT}" <<'PY'
import json
import os
import sys

out = sys.argv[1]
manifest = os.path.join(out, "manifest.json")
if os.path.exists(manifest):
    with open(manifest, encoding="utf-8") as handle:
        payload = json.load(handle)
    print(f"生成时间：{payload.get('generatedAt')}")
    for item in payload.get("snapshots", []):
        print(f"  · {item['name']:<28} {item['width']}×{item['height']}px "
              f"{item['bytes']:>7} B  内容占比 {item['contentRatio']:.3f}  {item['scheme']}")
    print(f"共 {len(payload.get('snapshots', []))} 张")
else:
    print("⚠️ 没有 manifest.json —— 用例可能全被跳过（检查 DOYAH_UI_SNAPSHOT）")

files = sorted(f for f in os.listdir(out) if f.endswith(".png"))
print("PNG：" + "、".join(files) if files else "⚠️ 一张 PNG 都没有")
PY

# 语言覆盖（队列 L-13）：每张图都有中英两份，且**语言真的到了像素上**。
# 为什么放在这里而不是 verify-all.sh：快照是取证工具、不进每轮门禁 ——
# 但**取证那一刻**必须把这件事判住（两份都生成了 ≠ 语言进了像素；第 10/11 轮两次
# 「判据太松」就是这么漏过去的）。判据与理由见 Scripts/check-ui-snapshot-languages.py。
echo
echo "==> 语言覆盖（中英成对 + 语言到像素）"
python3 Scripts/check-ui-snapshot-languages.py --manifest "${OUT}/manifest.json"
