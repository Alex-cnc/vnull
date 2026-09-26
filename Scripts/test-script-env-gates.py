#!/usr/bin/env python3
"""负例 + 行为验证：`Scripts/check-script-env-parameterization.py` 与 `Scripts/lib/test-env.sh`。

两件事，一件都不能少：

**A. 门禁的负例**（写坏 → 门禁必须报红 → 还原）：门禁绿着不代表它看得见问题 ——
本工程的规矩是「红要能红出来」（L-04 查出的"失败只记进没人读的变量"就是反面例子）。

**B. lib 的行为**（不需要数据库）：`test-env.sh` 是**唯一**决定「这轮连哪台库」的地方，
它的分支必须是机械可验的 —— 尤其是「只给一半连接信息时不许猜」，那是过渡期最容易出事的地方。

用法：`python3 Scripts/test-script-env-gates.py`
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "Scripts"
GATE = SCRIPTS / "check-script-env-parameterization.py"
LIB = SCRIPTS / "lib" / "test-env.sh"
MANIFEST = SCRIPTS / "real-db-scripts.txt"

SAMPLE = SCRIPTS / "test-er-diagram.sh"
passed = []
failed = []


def record(ok, label, detail=""):
    (passed if ok else failed).append(label)
    print(f"  {'✅' if ok else '❌'} {label}" + (f"  —— {detail}" if detail and not ok else ""))


def run_gate():
    proc = subprocess.run([sys.executable, str(GATE), "--json"], capture_output=True, text=True)
    try:
        return proc.returncode, json.loads(proc.stdout)
    except json.JSONDecodeError:
        return proc.returncode, {"problems": [proc.stdout + proc.stderr]}


def expect_gate_red(label, needle=""):
    code, data = run_gate()
    problems = "；".join(data.get("problems", []))
    if code == 0:
        record(False, label, "门禁没报红")
        return
    if needle and needle not in problems:
        record(False, label, f"报红了但没提到「{needle}」：{problems[:200]}")
        return
    record(True, label)


def expect_gate_green(label):
    code, data = run_gate()
    if code != 0:
        record(False, label, "；".join(data.get("problems", []))[:300])
        return
    record(True, label)


# ---------------------------------------------------------------- A. 门禁负例

def gate_negatives():
    print("\n== A) 门禁负例（写坏 → 报红 → 还原）")

    with tempfile.TemporaryDirectory() as tmp:
        text = SAMPLE.read_text(encoding="utf-8")

        # N-01 端口又写死回脚本
        SAMPLE.write_text(text.replace('PORT="${DOYAH_TEST_PGPORT}"', "PORT=55433"), encoding="utf-8")
        expect_gate_red("N-01 脚本里又写死本机端口 55433 → 门禁报红", "55433")
        SAMPLE.write_text(text, encoding="utf-8")

        # N-02 去掉 source 行
        SAMPLE.write_text(text.replace('source "$(cd "$(dirname "$0")" && pwd)/lib/test-env.sh"', ""),
                          encoding="utf-8")
        expect_gate_red("N-02 去掉 source lib 那一行 → 门禁报红", "source")
        SAMPLE.write_text(text, encoding="utf-8")

        # N-03 不再打印目标摘要
        SAMPLE.write_text(text.replace("doyah_test_env_summary", "# 不打印了"), encoding="utf-8")
        expect_gate_red("N-03 不再打印「连的是谁」→ 门禁报红", "目标摘要")
        SAMPLE.write_text(text, encoding="utf-8")

        # N-04 账号 / 维护库又写死
        SAMPLE.write_text(text.replace("doyah_test_env_export_connection",
                                       'export PGUSER=postgres PGDATABASE=postgres'), encoding="utf-8")
        expect_gate_red("N-04 又写死 PGUSER=postgres / PGDATABASE=postgres → 门禁报红", "写死的账号")
        SAMPLE.write_text(text, encoding="utf-8")

        # N-05 新脚本（不在清单里）里写死 217
        rogue = SCRIPTS / "test-env-gate-rogue.sh"
        rogue.write_text('#!/bin/bash\nexport PGHOST=192.168.5.217 PGUSER=zxvmax\n',
                         encoding="utf-8")
        expect_gate_red("N-05 未登记的新脚本里写死 217 → 门禁报红", "不在 Scripts/real-db-scripts.txt")
        rogue.unlink()

        # N-06 把字面量从 lib 里搬走（"删干净"式作弊）
        lib_text = LIB.read_text(encoding="utf-8")
        LIB.write_text(lib_text.replace("_doyah_test_profile_port=55434", "_doyah_test_profile_port=0"),
                       encoding="utf-8")
        expect_gate_red("N-06 lib 里的档位端口被改掉 → 门禁报红（正面判据挡住了「删干净」）", "slowquery")
        LIB.write_text(lib_text, encoding="utf-8")

        # N-07 清单里加一条不存在的脚本
        MANIFEST.write_text(MANIFEST.read_text(encoding="utf-8") + "test-no-such-script\n",
                            encoding="utf-8")
        expect_gate_red("N-07 清单登记了不存在的脚本 → 门禁报红", "不存在")
        MANIFEST.write_text(MANIFEST.read_text(encoding="utf-8").replace("test-no-such-script\n", ""),
                            encoding="utf-8")

    expect_gate_green("还原后门禁全绿")


# ---------------------------------------------------------------- B. lib 行为

PROBE = """{extra}source "{lib}"
echo "MODE=${{DOYAH_TEST_MODE}}"
echo "HOST=${{DOYAH_TEST_PGHOST}} PORT=${{DOYAH_TEST_PGPORT}} USER=${{DOYAH_TEST_PGUSER}} DB=${{DOYAH_TEST_PGDATABASE}}"
echo "BIN=${{DOYAH_TEST_PG_BIN}} DATADIR=${{DOYAH_TEST_LOCAL_DATADIR}} ADMIN=${{DOYAH_TEST_ADMIN_DB}}"
"""


def probe(env=None, extra="", after=""):
    """extra 在 source **之前**（脚本「报到」与档位声明就是那个位置），after 在之后。"""
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False, encoding="utf-8") as handle:
        handle.write(PROBE.format(lib=LIB, extra=extra) + after)
        path = handle.name
    base = {k: v for k, v in os.environ.items()
            if not k.startswith(("DOYAH_TEST_", "PG", "TEST_PGPORT", "PGSERVER_"))}
    base["PATH"] = os.environ.get("PATH", "/usr/bin:/bin")
    if env:
        base.update(env)
    proc = subprocess.run(["/bin/bash", path], capture_output=True, text=True, env=base, cwd=str(ROOT))
    os.unlink(path)
    return proc.returncode, proc.stdout + proc.stderr


REMOTE_ENV = {
    "DOYAH_TEST_PGHOST": "192.168.5.217",
    "DOYAH_TEST_PGPORT": "5432",
    "DOYAH_TEST_PGUSER": "doyah",
    "DOYAH_TEST_PGDATABASE": "doyah_test",
}


def lib_behavior():
    print("\n== B) lib 行为（不需要数据库）")

    code, out = probe()
    record(code == 0 and "MODE=local" in out and "PORT=55433" in out
           and "DB=doyah_manual_test" in out and "ADMIN=postgres" in out,
           "B-01 什么都不给 → 本机过渡模式（55433 / doyah_manual_test）", out.strip()[:160])

    code, out = probe({"DOYAH_TEST_LOCAL_PROFILE": "slowquery"})
    record(code == 0 and "PORT=55434" in out and "pgdata-slowquery" in out,
           "B-02 slowquery 档 → 55434 + 自己的数据目录", out.strip()[:160])

    code, out = probe({"DOYAH_TEST_LOCAL_PROFILE": "querytest"})
    record(code == 0 and "PORT=55432" in out and "pgdata-querytest" in out,
           "B-03 querytest 档 → 55432 + 外部数据目录", out.strip()[:160])

    code, out = probe({"DOYAH_TEST_LOCAL_PROFILE": "no-such-profile"})
    record(code == 78, "B-04 未知档位 → 拒绝开工（exit 78）", out.strip()[:160])

    code, out = probe(REMOTE_ENV)
    record(code == 78 and "报到" in out,
           "B-05 给齐四项但脚本没报到 → 拒绝开工（不制造假红）", out.strip()[:160])

    code, out = probe(REMOTE_ENV, "DOYAH_TEST_SCRIPT_READY_FOR_REMOTE=1\n")
    record(code == 0 and "MODE=remote" in out and "BIN=" in out and "192.168.5.217" in out,
           "B-06 报到的脚本 + 四项齐全 → 远程模式，且本机二进制为空", out.strip()[:200])

    code, out = probe({"DOYAH_TEST_PGHOST": "192.168.5.217"})
    record(code == 78 and "还缺" in out and "DOYAH_TEST_PGUSER" in out and "DOYAH_TEST_PGDATABASE" in out,
           "B-07 只给一半 → 拒绝并**点名**缺哪几项（不猜、不回落本机）", out.strip()[:200])

    business = dict(REMOTE_ENV, DOYAH_TEST_PGDATABASE="zxvmax")
    code, out = probe(business, "DOYAH_TEST_SCRIPT_READY_FOR_REMOTE=1\n")
    record(code == 77 and "业务库" in out,
           "B-08 远程模式下指向业务库 zxvmax → 安全拒绝（exit 77，SRS §0.9 E3）", out.strip()[:200])

    maintenance = dict(REMOTE_ENV, DOYAH_TEST_PGDATABASE="postgres")
    code, out = probe(maintenance, "DOYAH_TEST_SCRIPT_READY_FOR_REMOTE=1\n")
    record(code == 77, "B-09 远程模式下指向维护库 postgres → 同样拒绝", out.strip()[:160])

    code, out = probe(REMOTE_ENV, "DOYAH_TEST_SCRIPT_READY_FOR_REMOTE=1\n",
                      after="doyah_test_env_scratch_db whatever\n")
    record(code == 77 and "自建库" in out,
           "B-10 报到的脚本想自建库 → 拒绝并指路（迁移第 2 步未做）", out.strip()[:200])

    code, out = probe(after='doyah_test_env_export_connection\necho "PG=$PGHOST/$PGPORT/$PGUSER/${PGDATABASE:-未导出}"\n')
    record(code == 0 and "PG=127.0.0.1/55433/postgres/未导出" in out,
           "B-11 导出的标准变量正确，且**不**替脚本定库名（库名各脚本自定）", out.strip()[:200])

    code, out = probe({"DOYAH_TEST_LOCAL_PORT": "55999"})
    record(code == 0 and "PORT=55999" in out, "B-12 端口可被 DOYAH_TEST_LOCAL_PORT 覆盖", out.strip()[:160])

    code, out = probe({"TEST_PGPORT": "55888"})
    record(code == 0 and "PORT=55888" in out, "B-13 旧名 TEST_PGPORT 仍认（对外承诺过）", out.strip()[:160])

    code, out = probe(REMOTE_ENV, "DOYAH_TEST_SCRIPT_READY_FOR_REMOTE=1\n",
                      after='echo "R=$DOYAH_TEST_REMOTE_HOST/$DOYAH_TEST_REMOTE_PORT/$DOYAH_TEST_REMOTE_USER"\n')
    record(code == 0 and "R=192.168.5.217/5432/zxvmax" in out,
           "B-14 217 只读段的连接信息也来自 lib", out.strip()[:160])


def main():
    print("== 门禁与 lib 的自检（负例 + 行为）")
    gate_negatives()
    lib_behavior()
    print()
    print(f"通过 {len(passed)} 项，失败 {len(failed)} 项")
    if failed:
        for label in failed:
            print(f"  ❌ {label}")
        return 1
    print("✅ 门禁的每条判据都能红出来，lib 的每个分支都按说好的走。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
