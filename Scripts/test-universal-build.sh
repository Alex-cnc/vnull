#!/bin/bash
# 验证：跨架构构建（NFR-COMP-02「支持 Apple Silicon 与 Intel」）。
#
# 为什么需要这个脚本：
#   需求要求同时支持 Apple Silicon 与 Intel，但 2026-09-23 取证发现 ——
#   发布的 `dist/DoyahStudio.app` 可执行文件实测是 `Non-fat file … arm64`，
#   也就是**在 Intel 机上根本起不来**。构建侧此前没有任何跨架构参数。
#
#   本脚本断言三件事：
#     1. 默认（原生）产物是 arm64；
#     2. `DOYAH_ARCH=x86_64` 能构建出**纯 x86_64** 产物；
#     3. `DOYAH_ARCH=universal` 能构建出 **arm64 + x86_64 都在**的产物。
#
#   **边界（如实写在脚本里）**：构建通过 ≠ 真机可跑。Intel 实机启动仍是人工项，
#   Rosetta 下运行 x86_64 切片也只能算"近似证据"，不能替代 Intel 机器。
set -uo pipefail

cd "$(dirname "$0")/.."

APP="dist/DoyahStudio.app"
BINARY="${APP}/Contents/MacOS/DoyahStudio"

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

arch_report() { lipo -info "${BINARY}" 2>&1; }

echo "== 1) 默认构建：产物必须是本机原生架构（arm64）=="
./Scripts/build-app.sh >/dev/null 2>&1 || { check "默认构建" 1; exit 1; }
REPORT="$(arch_report)"
echo "  $REPORT"
echo "$REPORT" | grep -q "arm64" && check "默认产物含 arm64" 0 || check "默认产物应含 arm64" 1

echo ""
echo "== 2) DOYAH_ARCH=x86_64：必须产出纯 x86_64 切片 =="
DOYAH_ARCH=x86_64 ./Scripts/build-app.sh >/dev/null 2>&1 || { check "x86_64 构建" 1; exit 1; }
REPORT="$(arch_report)"
echo "  $REPORT"
echo "$REPORT" | grep -q "x86_64" && check "x86_64 产物含 x86_64" 0 || check "x86_64 产物应含 x86_64" 1
# 纯 x86_64：不应同时含 arm64（否则说明 --arch 没生效、编的还是本机架构）
echo "$REPORT" | grep -q "arm64" && check "x86_64 产物不该混入 arm64" 1 || check "x86_64 产物是纯 x86_64" 0

echo ""
echo "== 3) DOYAH_ARCH=universal：两个架构都要在 =="
DOYAH_ARCH=universal ./Scripts/build-app.sh >/dev/null 2>&1 || { check "universal 构建" 1; exit 1; }
REPORT="$(arch_report)"
echo "  $REPORT"
echo "$REPORT" | grep -q "arm64" && echo "$REPORT" | grep -q "x86_64" \
    && check "通用二进制同时含 arm64 与 x86_64" 0 || check "通用二进制应同时含两个架构" 1
# 真·universal：`lipo -info` 会写 "Architectures in the fat file: … arm64 x86_64"
echo "$REPORT" | grep -q "fat file" && check "确实是 fat（universal）文件" 0 || check "应为 fat 文件" 1

echo ""
echo "== 4) 恢复默认（原生）产物，别把 dist 留在别的架构上 =="
./Scripts/build-app.sh >/dev/null 2>&1 && check "已恢复默认构建" 0 || check "恢复默认构建" 1
echo "  $(arch_report)"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：默认 arm64 / x86_64 单架构 / universal 三种产物都能产出且架构正确"
    echo "（**边界**：构建通过 ≠ 真机可跑；Intel 实机与 Rosetta 启动仍是人工项）"
else
    echo "有失败项，见上"
fi
exit "$fail"
