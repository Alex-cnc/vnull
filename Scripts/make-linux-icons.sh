#!/usr/bin/env bash
# 从源画生成 **Linux 桌面**用的应用图标尺寸集（hicolor 约定）。
#
# 为什么需要这个脚本：macOS 的应用图标是 `.icns` —— Apple 专用容器，里面还要按
# macOS 的观感约定做 10% 留白 + 圆角。把这套东西拷到 Linux 上**没有任何作用**：
# GNOME / KDE / XFCE 只认 PNG 尺寸集（`hicolor/<N>x<N>/apps/`）或 SVG。
# 同一幅画、两种容器，所以这里从**源画**重新出一套方形全出血 PNG。
#
# 用法：
#   ./Scripts/make-linux-icons.sh                     # 生成到 App/Resources/icons/hicolor
#   ./Scripts/make-linux-icons.sh --source <图>       # 换源画
#   ./Scripts/make-linux-icons.sh --out <目录>        # 换输出根
#   ./Scripts/make-linux-icons.sh --sizes 16,32,512   # 只出指定尺寸
#   ./Scripts/make-linux-icons.sh --name doyahstudio  # 换图标名（须与 .desktop 的 Icon= 一致）
#
# 默认尺寸 16 / 24 / 32 / 48 / 64 / 128 / 256 / 512 —— freedesktop hicolor 的常规档，
# 512 已覆盖 HiDPI，**不进 1024**（那会让仓库多背一兆；要大的自己往 --sizes 里加）。
#
# 依赖：ImageMagick（`magick` / `convert`，Linux 侧常见）或 macOS 自带的 `sips`；
#       校验用 `python3`（本仓门禁本来就依赖它）。
# 校验：每个产物按 **PNG 魔数 + IHDR 宽高**逐个核对，不信工具自己的说法。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${ROOT}/App/Resources/AppIcon-source.png"
OUT="${ROOT}/App/Resources/icons/hicolor"
SIZES="16,24,32,48,64,128,256,512"
NAME="doyahstudio"

while [ $# -gt 0 ]; do
    case "$1" in
        --source) SOURCE="$2"; shift 2 ;;
        --out)    OUT="$2";    shift 2 ;;
        --sizes)  SIZES="$2";  shift 2 ;;
        --name)   NAME="$2";   shift 2 ;;
        -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1（--help 看用法）" >&2; exit 64 ;;
    esac
done

[ -f "${SOURCE}" ] || { echo "源画不存在：${SOURCE}" >&2; exit 66; }

# 工具探测：Linux 侧优先 ImageMagick，macOS 侧退回 sips（本机实测没有 ImageMagick）。
TOOL=""
if command -v magick >/dev/null 2>&1; then TOOL="magick"
elif command -v convert >/dev/null 2>&1; then TOOL="convert"
elif command -v sips >/dev/null 2>&1; then TOOL="sips"
else
    echo "既没有 ImageMagick（magick / convert）也没有 sips。" >&2
    echo "Linux 侧：apt install imagemagick   /   dnf install ImageMagick" >&2
    exit 69
fi
echo "源画：${SOURCE}"
echo "输出：${OUT}"
echo "工具：${TOOL}"

# 如实提示源画的**真实**格式：本仓的 AppIcon-source.png 其实是 JPEG 内容套着 .png 后缀。
# 缩放本身不受影响（两边都按内容识别），但打包流程若按后缀严格校验会挑刺，先说清楚。
if [ "$(head -c 3 "${SOURCE}" | od -An -tx1 | tr -d ' \n')" = "ffd8ff" ]; then
    echo "提示：源画内容是 JPEG（后缀 .png），缩放不受影响，但严格的打包校验可能报格式不符。"
fi

if [ -z "${SIZES}" ]; then
    echo "尺寸列表为空（--sizes 后面要跟逗号分隔的像素尺寸）" >&2
    exit 64
fi
IFS=',' read -r -a SIZE_LIST <<< "${SIZES}"
mkdir -p "${OUT}"

count=0
total_bytes=0
for size in "${SIZE_LIST[@]}"; do
    case "${size}" in
        ''|*[!0-9]*) echo "非法尺寸：${size}" >&2; exit 64 ;;
    esac
    dest_dir="${OUT}/${size}x${size}/apps"
    dest="${dest_dir}/${NAME}.png"
    mkdir -p "${dest_dir}"
    case "${TOOL}" in
        magick)  magick "${SOURCE}" -resize "${size}x${size}" -strip PNG32:"${dest}" ;;
        convert) convert "${SOURCE}" -resize "${size}x${size}" -strip PNG32:"${dest}" ;;
        sips)    sips -s format png -z "${size}" "${size}" "${SOURCE}" --out "${dest}" >/dev/null ;;
    esac
    # 校验：PNG 魔数 + IHDR 宽高必须正好是目标尺寸（不看工具自报）。
    python3 - "${dest}" "${size}" <<'PY'
import struct, sys, pathlib
path, want = pathlib.Path(sys.argv[1]), int(sys.argv[2])
data = path.read_bytes()
if data[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit(f"{path}: 不是 PNG（魔数不符）")
width, height = struct.unpack(">II", data[16:24])
if (width, height) != (want, want):
    sys.exit(f"{path}: 实际 {width}x{height}，期望 {want}x{want}")
PY
    bytes_here=$(wc -c < "${dest}" | tr -d ' ')
    total_bytes=$((total_bytes + bytes_here))
    count=$((count + 1))
    printf '  %4sx%-4s  %8s 字节  %s\n' "${size}" "${size}" "${bytes_here}" "${dest#${ROOT}/}"
done

echo "完成：${count} 个尺寸，共 $((total_bytes / 1024)) KB（全部通过魔数与尺寸校验）"
cat <<EOF

在 Linux 上安装（用户级，无需 root）：
  cp -R ${OUT#${ROOT}/} ~/.local/share/icons/     # 或在仓库里直接
  gtk-update-icon-cache -f -t ~/.local/share/icons/hicolor 2>/dev/null || true
  # 系统级则是 /usr/share/icons/，之后 .desktop 里写 Icon=${NAME}
EOF
