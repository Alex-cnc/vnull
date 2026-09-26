#!/usr/bin/env python3
"""`run-no-endpoint-evidence.sh` 的负例验证（开发循环 L-05）。

**为什么要有负例**：棘轮这类东西最坏的失效方式是「永远绿」—— 报红逻辑写错了也没人发现
（L-04 查出的 `verify-all.sh` 假绿就是这么来的）。所以这里故意造几种坏情况，断言复跑器
**真的报红并指名**，再断言好情况是绿的。

**故意不进闭环**（`verify-all.sh` 仍 11 项）：它要构建、起库，属于按需跑的验证工具。

用法：`python3 Scripts/test-no-endpoint-evidence.py`
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNNER = os.path.join("Scripts", "run-no-endpoint-evidence.sh")
COUNTER = os.path.join("Scripts", "count-evidence-assertions.py")

passed = 0
failed = 0


def check(what, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ✅ {what}")
    else:
        failed += 1
        print(f"  ❌ {what}{('  —— ' + detail) if detail else ''}")


def write(path, text, executable=False):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    if executable:
        os.chmod(path, 0o755)


def stub(assertions, exit_code=0, setup=True, summary=True):
    """造一个假证据脚本：`assertions` 条真断言 + 第 0 节前置检查 + 每节末尾汇总行。"""
    lines = ["#!/bin/bash"]
    if setup:
        lines += ['echo "== 0) 构建 CLI =="', 'echo "  ✅ CLI 构建成功"', "echo"]
    lines += ['echo "== 1) 检查 =="']
    lines += [f'echo "  ✅ 第 {i} 条断言"' for i in range(1, assertions + 1)]
    if summary and assertions:
        lines.append(f'echo "  ✅ 全部 {assertions} 项（详见上）"')
    lines.append("")
    lines.append(f"exit {exit_code}")
    return "\n".join(lines)


def run_runner(baseline, outdir, extra_env=None):
    env = dict(os.environ)
    env["DOYAH_EVIDENCE_BASELINE"] = baseline
    env["DOYAH_EVIDENCE_OUT"] = outdir
    if extra_env:
        env.update(extra_env)
    proc = subprocess.run(
        ["bash", RUNNER], cwd=ROOT, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        encoding="utf-8", errors="replace",
    )
    return proc.returncode, proc.stdout


def baseline(entries):
    return {"entries": entries}


def main():
    workdir = tempfile.mkdtemp(prefix="doyah-no-endpoint-evidence-")
    try:
        print("== 0) 计数口径本身（✅ 行 − 汇总行 − 第 0 节）")
        log = os.path.join(workdir, "count.log")
        stub_path = os.path.join(workdir, "stub_count.sh")
        write(stub_path, stub(3), executable=True)
        with open(log, "w", encoding="utf-8") as handle:
            subprocess.run(["/bin/bash", stub_path], stdout=handle, stderr=subprocess.STDOUT)
        out = subprocess.run(
            ["python3", COUNTER, log, "--json"], cwd=ROOT,
            stdout=subprocess.PIPE, text=True, check=True,
        ).stdout
        data = json.loads(out)
        check("三条真断言被数成 3（前置与汇总行不计）", data["assertions"] == 3, f"得到 {data['assertions']}")
        check("汇总行确实出现在输出里（否则这条负例无意义）", data["allOkLines"] == 5, f"得到 {data['allOkLines']}")

        print()
        print("== 1) 好情况：断言数达标 → 绿")
        ok_script = os.path.join(workdir, "stub_ok.sh")
        write(ok_script, stub(2), executable=True)
        ok_baseline = os.path.join(workdir, "baseline_ok.json")
        write(ok_baseline, json.dumps(baseline([
            {"name": "ok", "script": ok_script, "minAssertions": 2, "covers": []},
        ])))
        code, out = run_runner(ok_baseline, os.path.join(workdir, "out_ok"))
        check("复跑器 exit 0", code == 0, f"exit {code}")
        check("打印了断言数与下限", "2" in out and "文档下限" in out, out.strip()[:200])
        summary = json.load(open(os.path.join(workdir, "out_ok", "summary.json"), encoding="utf-8"))
        check("清单里 ok = true", summary["ok"] is True)

        print()
        print("== 2) 坏情况：断言被删掉一条（棘轮要报红）")
        short_script = os.path.join(workdir, "stub_short.sh")
        write(short_script, stub(1), executable=True)
        short_baseline = os.path.join(workdir, "baseline_short.json")
        write(short_baseline, json.dumps(baseline([
            {"name": "short", "script": short_script, "minAssertions": 2, "covers": []},
        ])))
        code, out = run_runner(short_baseline, os.path.join(workdir, "out_short"))
        check("复跑器 exit 1", code == 1, f"exit {code}")
        check("指名了「断言 1 < 文档 2」", "断言 1 < 文档 2" in out, out.strip()[:300])
        check("落库清单里 ok = false",
              json.load(open(os.path.join(workdir, "out_short", "summary.json"), encoding="utf-8"))["ok"] is False)

        print()
        print("== 3) 坏情况：脚本自己跑不过（退出码非零）")
        fail_script = os.path.join(workdir, "stub_fail.sh")
        write(fail_script, stub(2, exit_code=3), executable=True)
        fail_baseline = os.path.join(workdir, "baseline_fail.json")
        write(fail_baseline, json.dumps(baseline([
            {"name": "fail", "script": fail_script, "minAssertions": 2, "covers": []},
        ])))
        code, out = run_runner(fail_baseline, os.path.join(workdir, "out_fail"))
        check("复跑器 exit 1", code == 1, f"exit {code}")
        check("指名了退出码 3", "退出码 3" in out, out.strip()[:300])

        print()
        print("== 4) 坏情况：基线指了一个不存在的脚本")
        missing_baseline = os.path.join(workdir, "baseline_missing.json")
        write(missing_baseline, json.dumps(baseline([
            {"name": "ghost", "script": os.path.join(workdir, "nope.sh"), "minAssertions": 1, "covers": []},
        ])))
        code, out = run_runner(missing_baseline, os.path.join(workdir, "out_missing"))
        check("复跑器 exit 1", code == 1, f"exit {code}")
        check("指名了「缺脚本」", "缺脚本" in out, out.strip()[:300])

        print()
        print("== 5) 断言多于下限：绿，但要求更新文档")
        more_script = os.path.join(workdir, "stub_more.sh")
        write(more_script, stub(4), executable=True)
        more_baseline = os.path.join(workdir, "baseline_more.json")
        write(more_baseline, json.dumps(baseline([
            {"name": "more", "script": more_script, "minAssertions": 3, "covers": []},
        ])))
        code, out = run_runner(more_baseline, os.path.join(workdir, "out_more"))
        check("复跑器 exit 0（多于下限不算失败）", code == 0, f"exit {code}")
        check("提示「该更新文档与下限了」", "该更新文档与下限了" in out, out.strip()[:300])

        print()
        print("== 6) 真实基线可解析、条目齐全（不真跑四个脚本，只看基线本身）")
        real = json.load(open(os.path.join(ROOT, "Scripts", "no-endpoint-evidence-baseline.json"), encoding="utf-8"))
        names = [e["name"] for e in real["entries"]]
        check("基线含四条在途项", names == ["diagnosis", "maintenance", "mcp", "mysql-driver"], str(names))
        check("每条都写了覆盖的需求号与出处",
              all(e.get("covers") and e.get("documentedIn") for e in real["entries"]))
        check("基线里的脚本都在仓库里",
              all(os.path.exists(os.path.join(ROOT, e["script"])) for e in real["entries"]))
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print()
    print(f"结果：{passed} 项通过 / {failed} 项失败")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
