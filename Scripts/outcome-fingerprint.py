#!/usr/bin/env python3
"""需求 → 代码的「结果指纹」派生（给「历史方案 + 代码实现」这类资产当样板）。

## 它解决什么问题

把「需求/方案文档 + 代码」当知识资产时，最值钱的字段不是方案文本，而是**结果**：
这套方案后来落地了吗？落地后稳不稳？现在还算数吗？有没有验证？

企业里这类字段通常靠人工回填 —— 于是没人填。这个脚本的立场是：
**能从 git 机械派生的一律派生，人工只补派不出来的部分。**

## 派生哪些信号（每个需求一行）

- **落地度**：文档的证据格里有没有指向代码/脚本的路径（有 → 至少提到过实现）
- **验证度**：引用里有没有 `Tests/` 或 `Scripts/`（有测试或可复跑脚本）
- **存活度**：引用的文件**现在是否还在**（被删了 → 方案提的实现已经不存在）
- **活跃度**：引用的文件近 90 天的提交次数（越高越可能"当时没想清"，或正在演进）
- **最后活动**：引用文件里最近一次提交的日期

## 它真正想抓的是「漂移」

单看一个需求的指纹没意思，有意义的是**文档状态与代码事实不一致**：

- 文档说 ✅（已实现）但**引用文件不存在** → 文档漂移（或实现被删）
- 文档说 ⬜（未开始）却引用了**存在的代码** → 文档落后于代码
- 文档说 ✅ 但近 90 天高频改动 → 稳定度存疑（值得回看当时的方案）

这些才是可以直接排进工作队列的东西 —— 比"再写一份方案"有用得多。

## 用法

    python3 Scripts/outcome-fingerprint.py                 # 人读表（默认只看漂移候选 + 汇总）
    python3 Scripts/outcome-fingerprint.py --all           # 每个需求一行
    python3 Scripts/outcome-fingerprint.py --json          # 给别的脚本/管线用
    python3 Scripts/outcome-fingerprint.py --srs <文件>    # 换一份需求文档（别的项目/别的域）

## 边界（别把它当成"结果"的全部）

- 只认文档里**写出来的路径**。方案里没提文件的条目，这里看不出落地情况（企业里应改为
  用需求号关联 commit / 工单，关联率是第一周该量的指标）。
- 提交次数是**活跃度**不是**质量**：活跃可能是持续演进，也可能是反复返工 ——
  要区分得再看回滚、hotfix、事故记录。
- 时间窗（90 天）是可调口径，不是真理。
"""

from __future__ import annotations

import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_SRS = ROOT / "Docs" / "需求规范书.md"

# 引用路径：文档里用反引号包起来的 `Core/X.swift` 这类写法
PATH_PATTERN = re.compile(r"`([A-Za-z][A-Za-z0-9_]*(?:/[^`\s]+)+\.([a-z]+))`")
# **代码**才算「落地」；`.md` 是参考资料（验证方案、兼容性矩阵…），不能当实现证据。
# 第一版把 `.md` 也算进"实现引用"，结果 3 条 ⬜ 需求被误报成「文档说未开始却引用了代码」——
# 尺子太宽会把参考资料当成实现。
CODE_SUFFIXES = {"swift", "sh", "py", "json"}
ROW_PATTERN = re.compile(r"^\| (FR|NFR)-")
ACTIVITY_WINDOW_DAYS = 90

STATUS_EMOJI = {"✅": "done", "🟡": "partial", "⬜": "todo"}


def git(*arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(ROOT), *arguments],
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def requirements(srs: pathlib.Path) -> list[dict]:
    rows: list[dict] = []
    for line in srs.read_text(encoding="utf-8").splitlines():
        if not ROW_PATTERN.match(line):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) < 5:
            continue
        status = cells[4]
        emoji = status[0] if status else "?"
        rows.append(
            {
                "id": cells[0],
                "status": STATUS_EMOJI.get(emoji, "unknown"),
                "status_emoji": emoji,
                "evidence": cells[-1],
            }
        )
    return rows


class PathStats:
    """按路径缓存 git 统计（一个路径可能被多个需求引用）。"""

    def __init__(self) -> None:
        self._cache: dict[str, dict] = {}

    def get(self, path: str) -> dict:
        if path in self._cache:
            return self._cache[path]
        exists = (ROOT / path).exists()
        last = git("log", "-1", "--format=%ad", "--date=short", "--", path)
        recent = git("log", f"--since={ACTIVITY_WINDOW_DAYS}.days", "--oneline", "--", path)
        deleted = git("log", "-1", "--format=%ad", "--date=short", "--diff-filter=D", "--", path)
        stats = {
            "exists": exists,
            "last_commit": last or None,
            "recent_commits": len([line for line in recent.splitlines() if line.strip()]),
            "deleted_at": deleted or None,
        }
        self._cache[path] = stats
        return stats


def fingerprint(requirement: dict, paths: PathStats) -> dict:
    # 两个捕获组：整条路径 + 后缀（后缀只用来分类，不要拼回去 —— 拼了会变成 `X.swift.swift`）
    matches = PATH_PATTERN.findall(requirement["evidence"])
    referenced = sorted({path for path, suffix in matches if suffix in CODE_SUFFIXES})
    documents = sorted({path for path, suffix in matches if suffix == "md"})
    details = {path: paths.get(path) for path in referenced}
    missing = [path for path, stat in details.items() if not stat["exists"]]
    tested = [path for path in referenced if path.startswith(("Tests/", "Scripts/"))]
    activity = sum(stat["recent_commits"] for stat in details.values())
    last_dates = [stat["last_commit"] for stat in details.values() if stat["last_commit"]]

    drift: list[str] = []
    if requirement["status"] == "done" and missing:
        drift.append("文档说已实现，但引用的文件不存在")
    if requirement["status"] == "todo" and referenced and not missing:
        drift.append("文档说未开始，却引用了存在的代码")
    if requirement["status"] == "done" and activity >= 10:
        drift.append(f"文档说已实现，但近 {ACTIVITY_WINDOW_DAYS} 天被改了 {activity} 次（稳定度存疑）")
    if referenced and not tested:
        drift.append("有实现引用但没有测试/脚本引用")

    return {
        "id": requirement["id"],
        "status": requirement["status"],
        "statusEmoji": requirement["status_emoji"],
        "referencedPaths": referenced,
        "referenceDocuments": documents,
        "missingPaths": missing,
        "testedPaths": tested,
        "activity": activity,
        "lastActivity": max(last_dates) if last_dates else None,
        "drift": drift,
        "hasImplementation": bool(referenced) and len(missing) < len(referenced),
        "verified": bool(tested),
    }


def main() -> int:
    arguments = sys.argv[1:]
    flags = {argument for argument in arguments}
    srs = DEFAULT_SRS
    if "--srs" in arguments:
        index = arguments.index("--srs")
        if index + 1 < len(arguments):
            srs = pathlib.Path(arguments[index + 1]).resolve()
    if not srs.exists():
        print(f"❌ 找不到需求文档：{srs}")
        return 2

    paths = PathStats()
    fingerprints = [fingerprint(requirement, paths) for requirement in requirements(srs)]

    with_impl = [item for item in fingerprints if item["hasImplementation"]]
    verified = [item for item in with_impl if item["verified"]]
    drifting = [item for item in fingerprints if item["drift"]]

    if "--json" in flags:
        print(json.dumps(fingerprints, ensure_ascii=False, indent=2, sort_keys=True))
        return 0

    repo_commits = len([line for line in git("log", f"--since={ACTIVITY_WINDOW_DAYS}.days", "--oneline").splitlines() if line.strip()])
    print("=" * 78)
    print(f"需求 → 代码 结果指纹（{len(fingerprints)} 条需求，活跃度窗口 {ACTIVITY_WINDOW_DAYS} 天）")
    print("=" * 78)
    print(f"  仓库基线          近 {ACTIVITY_WINDOW_DAYS} 天共 {repo_commits} 次提交（用来校准「活跃」那一列）")
    print(f"  有实现引用        {len(with_impl)} 条")
    print(f"  其中带测试/脚本   {len(verified)} 条（占 {len(verified) * 100 // max(1, len(with_impl))}%）")
    print(f"  漂移或稳定度存疑  {len(drifting)} 条")
    print()

    print("── 漂移 / 稳定度候选（按活跃度降序）" + "─" * 30)
    for item in sorted(drifting, key=lambda entry: -entry["activity"]):
        print(f"  {item['id']:<14} {item['statusEmoji']} 活跃 {item['activity']:>2} · {item['lastActivity'] or '—'}")
        for reason in item["drift"]:
            print(f"      · {reason}")
        if item["missingPaths"]:
            print(f"      缺失：{', '.join(item['missingPaths'][:3])}")

    if "--all" in flags:
        print()
        print("── 全部需求" + "─" * 58)
        for item in fingerprints:
            mark = "✅" if item["verified"] else ("◐" if item["hasImplementation"] else "·")
            print(
                f"  {mark} {item['id']:<14} {item['statusEmoji']} "
                f"引用 {len(item['referencedPaths']):>2} · 活跃 {item['activity']:>2} · {item['lastActivity'] or '—'}"
            )

    print()
    print("注 1：活跃度是「近期改动次数」，不等于质量（演进与返工都算改动）；")
    print("      请对照上面的「仓库基线」看 —— 一个被每个提交都碰到的构建脚本，活跃度必然高。")
    print("注 2：「带测试/脚本引用」只看**文档里有没有写**，不等于真的没有测试。")
    print("注 3：只认文档里写出来的路径；方案没写路径的条目，请改用需求号↔commit 关联（关联率先行）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
