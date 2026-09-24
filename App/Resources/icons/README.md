# 应用图标资产（法斗 Doyah）

同一幅画在两套桌面环境里需要**两种容器**，这个目录负责把「Linux 那一半」备齐。
需求提出者 2026-09-24 问：「应用图标能用在 Linux 版吗？如果可以，看下这个文件有没有上传 GitHub，
我同步到 Linux 版本上去。」

## 目录里有什么

| 文件 | 平台 | 在 Git 里 | 说明 |
|---|---|---|---|
| `AppIcon-source.png` | 通用（源画） | ✅ 已提交 | 2048×2048，**全出血方形**（实测内容覆盖 0%…100%，四角也是画面的一部分）。Linux 侧要出任何尺寸都从这份派生 |
| `AppIcon.icns` | 仅 macOS | ✅ 已提交 | Apple 专用容器，装进 `.app` 供 Dock / 访达用。**Linux 桌面不认这个格式** |
| `AppIcon-1024.png` | 仅 macOS | ❌ 被 `.gitignore` 排除 | 由 `Scripts/make-app-icon.swift` 生成的 macOS 观感成品：内容只占约 80%（实测像素包围盒 100…922），四角是透明圆角 —— 这正是 Linux 上**不该**用的那一版 |
| `icons/hicolor/**/doyahstudio.png` | 仅 Linux | ✅ 已提交 | 8 档尺寸（16/24/32/48/64/128/256/512），真 PNG、方形全出血，直接可装进图标主题 |

## 为什么不能直接把 `.icns` 拷到 Linux

macOS 的应用图标是 `.icns`（Apple 专用容器，内部按尺寸分档存放 16…1024 的位图），GNOME / KDE / XFCE
找图标时**只看** `hicolor/<N>x<N>/apps/` 下的 PNG 或矢量图。把 `.icns` 放进
`~/.local/share/icons/` 的结果是：桌面拿不到图标，回退成一个默认方块 —— 不报错，但也没效果。
另外 macOS 的成品图标按系统观感做了 10% 留白 + 圆角，Linux 侧通常要**方形全出血**，
由桌面环境自己决定要不要加形状；所以这里是从源画重新出，不是从 `.icns` 转换。

## 在 Linux 上安装

用户级（无需 root，重建图标缓存即可生效）：

```bash
# 把 hicolor 目录整体拷进用户的图标主题目录
cp -R App/Resources/icons/hicolor ~/.local/share/icons/
gtk-update-icon-cache -f -t ~/.local/share/icons/hicolor 2>/dev/null || true
```

系统级则拷到 `/usr/share/icons/`（多数发行包会把这份资产直接装到那里）。

`.desktop` 里按名字引用，**不需要写绝对路径**：

```ini
[Desktop Entry]
Type=Application
Name=DoyahStudio
Exec=/path/to/doyahstudio
Icon=doyahstudio
Categories=Development;Database;
```

`Icon=` 的值必须与本目录里的文件名（`doyahstudio.png`）以及
`Scripts/make-linux-icons.sh --name` 一致；Linux 侧若已定了别的应用 id，改名字更省事 ——
把 PNG 改名、或重跑脚本时加 `--name <新名字>`。

## 重新生成

两个平台都能跑同一个脚本（优先 ImageMagick，macOS 上退回系统自带 `sips`）：

```bash
./Scripts/make-linux-icons.sh                        # 默认 8 档到 App/Resources/icons/hicolor
./Scripts/make-linux-icons.sh --sizes 16,32,512      # 只要几档
./Scripts/make-linux-icons.sh --name doyahstudio     # 换名字
```

脚本对每个产物按 **PNG 魔数 + IHDR 宽高**逐个核对（不信缩放工具自己的说法），
实测重跑产物逐字节一致（不会每次改一点、在 diff 里制造噪音）。

不用脚本的话，Linux 侧一行 ImageMagick 也能出：

```bash
for s in 16 24 32 48 64 128 256 512; do
  mkdir -p ~/.local/share/icons/hicolor/${s}x${s}/apps
  convert App/Resources/AppIcon-source.png -resize ${s}x${s} \
    ~/.local/share/icons/hicolor/${s}x${s}/apps/doyahstudio.png
done
```

## 两个已登记的坑

1. **`AppIcon-source.png` 的实际内容是 JPEG**（JFIF，后缀却是 `.png`）。缩放不受影响
   （`sips` 与 ImageMagick 都按内容识别），但假如 Linux 侧的打包流程按后缀做严格校验，
   会在这里挑刺。要彻底干净就用本目录生成的真 PNG，或先把源画转成真 PNG 再入仓。
2. **图标名与 `.desktop` 的 `Icon=` 必须一致**，否则同样是"装了但看不见"——排查时先跑
   `gtk-update-icon-cache`，再看 `Icon=` 是否拼错。

平台差异本身已登记在 `Docs/需求规范书.md` §10.9（P-08 打包与分发）：跨平台必须一致的是
**同一品牌图形与同一个图标名**，允许不同的是**容器格式与尺寸集**。
