#!/usr/bin/env python3
"""门禁：连真库的脚本**不许自己写死连接信息**（开发循环 L-06 起，闭环第 13 项）。

**为什么有它**：L-06 之前，本机集群的端口 55433、PG 二进制路径、数据目录、217 的地址与账号
在 32 个脚本里各写一遍（`grep -c 55433 Scripts/*.sh` 就是这份「事实」的分布）。这有两个后果：
迁移到 217 时要手改 32 份、且**改漏一个没人发现**（脚本照样能跑、照样打勾，只是连的是本机）。

**为什么门禁不能自己去 grep 端口**：迁移改完之后 `55433` 就没了 —— 那时 `grep` 返回空，
门禁「永远通过」，而新写的脚本照样可以再写死一次。所以做法反过来：**清单是声明**，
门禁拿四组判据跟事实对账（见 `Scripts/real-db-scripts.txt` 的头注释）：

  ① 清单里的脚本：存在 + `source` 了 lib + 调了 `doyah_test_env_summary`；
  ② 清单之外的任何 `Scripts/*.sh`：不许出现连接字面量（新脚本要么用 lib、要么登记进清单）；
  ③ lib **自己**必须持有那三档集群与本机二进制路径的默认值（不许把字面量搬到"没有"里去）；
  ④ 清单与 `Scripts/real-db-evidence-baseline.json` 对账（两份事实不许各说各话）。

用法：
    python3 Scripts/check-script-env-parameterization.py            # 人读结论，失败非零退出
    python3 Scripts/check-script-env-parameterization.py --json     # 机器读
"""

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "Scripts"
LIB = SCRIPTS / "lib" / "test-env.sh"
MANIFEST = SCRIPTS / "real-db-scripts.txt"
BASELINE = SCRIPTS / "real-db-evidence-baseline.json"

# 连接字面量：谁都不许在 lib 之外写
FORBIDDEN_TOKENS = [
    ("55432", "本机 querytest 档端口"),
    ("55433", "本机 session 档端口"),
    ("55434", "本机 slowquery 档端口"),
    ("tools/pgserver", "本机 PG 二进制路径"),
    ("pgdata-", "本机集群数据目录"),
    ("192.168.5.217", "217 的地址"),
]

# 端点字面量（赋值形态）：账号 / 库名也不许写死（负例里**故意**用的坏值不在此列 ——
# 那些是坏主机名 / 坏端口 / 陌生账号，正是断言的现场）
FORBIDDEN_ASSIGNMENTS = [
    (re.compile(r"PGUSER=(postgres|zxvmax)(?![a-z_])"), "写死的账号（应为 ${DOYAH_TEST_PGUSER}）"),
    (re.compile(r"PGDATABASE=postgres(?![a-z_])"), "写死的维护库（应为 ${DOYAH_TEST_ADMIN_DB}）"),
]

# lib 必须真的持有的事实（正面判据：挡住「把字面量删干净」这条捷径）。
# 只在**代码行**上匹配（注释不算）—— 否则把值改成 0、注释里还留着旧数字，门禁照样绿。
LIB_MUST_HAVE = [
    (re.compile(r"_doyah_test_profile_port=55433"), "session 档端口"),
    (re.compile(r"_doyah_test_profile_port=55434"), "slowquery 档端口"),
    (re.compile(r"_doyah_test_profile_port=55432"), "querytest 档端口"),
    (re.compile(r"pgdata-session-test"), "session 档数据目录"),
    (re.compile(r"pgdata-slowquery"), "slowquery 档数据目录"),
    (re.compile(r"tools/pgserver/pgserver/pginstall/bin"), "本机 PG 二进制默认路径"),
    (re.compile(r"192\.168\.5\.217"), "217 的地址"),
    (re.compile(r"DOYAH_TEST_LOCAL_PROFILE"), "档位开关"),
    (re.compile(r"DOYAH_TEST_EXIT_CONFIG=78"), "配置不全的退出码"),
    (re.compile(r"DOYAH_TEST_EXIT_REFUSE=77"), "安全拒绝的退出码"),
]


def code_lines(text):
    """去掉整行注释后剩下的「代码行」。"""
    return [line for line in text.splitlines() if not line.strip().startswith("#")]


def load_manifest():
    """清单 -> (名字列表, 分组字典)。`# [组名]` 行开一个新组。"""
    names, groups, group = [], {}, None
    for line in MANIFEST.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        marker = re.match(r"^#\s*\[(\w[\w-]*)\]$", stripped)
        if marker:
            group = marker.group(1)
            continue
        if stripped.startswith("#"):
            continue
        names.append(stripped)
        groups.setdefault(group or "未分组", []).append(stripped)
    return names, groups


def check():
    problems = []
    notes = []
    lib_code = code_lines(LIB.read_text(encoding="utf-8"))

    # ---- ③ lib 必须持有那些事实（先查这个：否则 ① ② 都可能是「删干净」骗过去的）----
    for pattern, what in LIB_MUST_HAVE:
        if not any(pattern.search(line) for line in lib_code):
            problems.append(f"lib 里找不到 {what}（{pattern.pattern}）—— 连接信息不能搬去「没有」的地方")

    names, groups = load_manifest()
    if not names:
        problems.append("清单里一条脚本都没有")

    # ---- ① 清单里的脚本 ----
    for name in names:
        path = SCRIPTS / f"{name}.sh"
        if not path.exists():
            problems.append(f"清单登记了 {name}，但 Scripts/{name}.sh 不存在")
            continue
        text = path.read_text(encoding="utf-8")
        if 'source "$(cd "$(dirname "$0")" && pwd)/lib/test-env.sh"' not in text:
            problems.append(f"{name}.sh 没有 source Scripts/lib/test-env.sh（连接信息应只有一处出处）")
        if "doyah_test_env_summary" not in text:
            problems.append(f"{name}.sh 没有打印目标摘要（doyah_test_env_summary）—— 日志里看不出连的是谁")
        for pattern, what in FORBIDDEN_ASSIGNMENTS:
            for i, line in enumerate(text.splitlines(), 1):
                if line.strip().startswith("#"):
                    continue
                if pattern.search(line):
                    problems.append(f"{name}.sh:{i} 有{what} → {line.strip()[:80]}")

    # ---- ② 连接字面量：**所有** Scripts/*.sh 都不许写（清单里的也要查 ——
    #         迁移最容易出事的正是"清单里那个脚本漏改了一处"）----
    declared = set(names)
    for path in sorted(SCRIPTS.glob("*.sh")):
        in_manifest = path.stem in declared
        for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for token, what in FORBIDDEN_TOKENS:
                if token not in line:
                    continue
                if in_manifest:
                    problems.append(
                        f"{path.name}:{i} 出现 {what}（{token}）—— 清单里的脚本一律从 "
                        f"Scripts/lib/test-env.sh 取值（三档与 217 的地址只写在它里面）")
                else:
                    problems.append(
                        f"{path.name}:{i} 出现 {what}（{token}）但不在 Scripts/real-db-scripts.txt 里 —— "
                        f"要么改用 Scripts/lib/test-env.sh，要么登记进清单并 source 它")

    # ---- ④ 清单 ↔ 证据基线 ----
    if BASELINE.exists():
        data = json.loads(BASELINE.read_text(encoding="utf-8"))
        baseline_names = {e["script"].split("/")[-1][:-3] for e in data.get("entries", [])}
        skipped_names = {e["script"].split("/")[-1][:-3] for e in data.get("skippedDueToEnvironment", [])}
        missing = baseline_names - declared
        if missing:
            problems.append("证据基线里跑这些脚本，但清单里没有它们：" + "、".join(sorted(missing)))
        extra_skipped = skipped_names - declared
        if extra_skipped:
            notes.append("基线里按环境跳过、且未进清单（属正常）：" + "、".join(sorted(extra_skipped)))
        unaccounted = declared - baseline_names - skipped_names
        if unaccounted:
            problems.append("清单里的这些脚本既不在证据基线里、也没登记为环境跳过："
                            + "、".join(sorted(unaccounted)))

    return problems, notes, names, groups


def main():
    parser = argparse.ArgumentParser(description="连真库的脚本不许写死连接信息")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    problems, notes, names, groups = check()

    if args.json:
        print(json.dumps({
            "ok": not problems,
            "problems": problems,
            "notes": notes,
            "declared": names,
            "groups": groups,
        }, ensure_ascii=False, indent=2))
        return 1 if problems else 0

    print(f"清单 Scripts/real-db-scripts.txt：{len(names)} 个脚本", end="")
    if groups:
        detail = "、".join(f"{g} {len(v)}" for g, v in groups.items())
        print(f"（{detail}）")
    else:
        print()
    for name in notes:
        print(f"  · {name}")

    if problems:
        print(f"\n❌ {len(problems)} 处不合规：")
        for problem in problems:
            print(f"  · {problem}")
        return 1
    print("\n✅ 连真库的脚本一律从 Scripts/lib/test-env.sh 取连接信息，清单与证据基线对得上。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
