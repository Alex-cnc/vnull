#!/usr/bin/env python3
"""`check-shell-locale-safety.py` 的负例验证（开发循环 L-05）。

两件事：
1. **证前提**：在本机 bash 上真跑一遍，证明「裸写 `$X` 紧跟 CJK」真的会丢值（bash ≥ 4 时跳过并说明）；
2. **证门禁**：造几种写法，断言门禁该红的红、该绿的绿。

故意不进闭环（`verify-all.sh` 里跑的是门禁本身，不是它的负例）。

用法：`python3 Scripts/test-shell-locale-safety.py`
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECKER = os.path.join("Scripts", "check-shell-locale-safety.py")

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


def bash_major(executable="/bin/bash"):
    try:
        out = subprocess.run([executable, "--version"], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, errors="replace").stdout
    except OSError:
        return None
    match = re.search(r"version (\d+)\.", out)
    return int(match.group(1)) if match else None


def run_checker(paths, workdir):
    """把待检脚本放进一个临时仓库根里跑门禁（门禁按自身位置的上级当仓库根）。"""
    shim_root = os.path.join(workdir, "repo")
    shutil.rmtree(shim_root, ignore_errors=True)  # 每次全新，免得上一轮的坏文件留在里面
    os.makedirs(os.path.join(shim_root, "Scripts"), exist_ok=True)
    checker = os.path.join(shim_root, "Scripts", "check-shell-locale-safety.py")
    shutil.copy2(os.path.join(ROOT, CHECKER), checker)
    for name, content in paths.items():
        with open(os.path.join(shim_root, "Scripts", name), "w", encoding="utf-8") as handle:
            handle.write(content)
    proc = subprocess.run([sys.executable, checker], stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, errors="replace")
    return proc.returncode, proc.stdout


def main():
    workdir = tempfile.mkdtemp(prefix="doyah-shell-locale-")
    try:
        print("== 1) 前提实证：本机 bash 上，裸写变量紧跟 CJK 到底会不会丢值")
        major = bash_major()
        print(f"    /bin/bash 主版本：{major}")
        sample = os.path.join(workdir, "sample.sh")
        with open(sample, "w", encoding="utf-8") as handle:
            handle.write('#!/bin/bash\nX=VALUE\necho "中文：$X）"\necho "中文：${X}）"\n')
        out = subprocess.run(["/bin/bash", sample], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, errors="replace").stdout
        first, second = out.splitlines()[0], out.splitlines()[1]
        check("花括号写法保住值（`${X}）`）", "VALUE" in second, second)
        if major == 3:
            check("裸写写法**丢了值**（bash 3 上真的丢）", "VALUE" not in first, first)
        else:
            print(f"    （bash {major} 不丢值 —— 门禁的前提只对 bash 3.x 成立，这里如实说明而不是假装通过）")

        print()
        print("== 2) 门禁：坏写法必须报红")
        code, out = run_checker({
            "bad_paren.sh": '#!/bin/bash\nX=1\necho "拿到了（$X）"\n',
            "bad_chinese.sh": '#!/bin/bash\nCOUNT=1\necho "共 $COUNT 条" | sed "s/共/$COUNT项/"\n',
        }, workdir)
        check("裸写 + 全角括号 → exit 1", code == 1, f"exit {code}")
        check("指名了文件与行号", "bad_paren.sh:3" in out, out.strip()[:300])
        check("给了修法提示", "${" in out, out.strip()[:300])

        print()
        print("== 3) 门禁：好写法必须放行")
        code, out = run_checker({
            "good_brace.sh": '#!/bin/bash\nX=1\necho "拿到了（${X}）"\n',
            "good_ascii.sh": '#!/bin/bash\nX=1\necho "拿到了（$X)"\necho "共 $X 条"\n',
            "good_comment.sh": '#!/bin/bash\n# 说明：以前写成（$X）会丢值，别改回去\nX=1\necho $X\n',
        }, workdir)
        check("花括号 / ASCII 结尾 / 注释 → exit 0", code == 0, f"exit {code}")
        check("打印了通过语", "✅" in out, out.strip()[:200])

        print()
        print("== 4) 门禁：真仓库当前是干净的")
        real = subprocess.run([sys.executable, os.path.join(ROOT, CHECKER)],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, errors="replace")
        check("本仓库 exit 0", real.returncode == 0, real.stdout.strip()[:400])
        check("扫描了脚本数量", "扫描" in real.stdout and ".sh" in real.stdout)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print()
    print(f"结果：{passed} 项通过 / {failed} 项失败")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
