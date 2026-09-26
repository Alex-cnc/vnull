#!/bin/bash
# 「无端点 / 无实例在途项」的证据集复跑器（开发循环 L-05 起）。
#
# **为什么有它**：`FR-AI-03 / FR-AI-04 / FR-AI-10 / FR-DRV-09` 这四条**不依赖真实模型端点、也不依赖
# 真实 MySQL 实例**的断言散在四个脚本里（本机真库 + 假模型回复 / 假 MCP 对端 / 假 MySQL 服务器），
# 过去每轮靠人记得跑、再人工数一遍条数；文档里写的「N 项断言全过」一旦和脚本脱钩，就没有任何东西
# 会发现（与 L-04 查出的 `verify-all.sh` 假绿是同一类病）。这一条命令把四份证据一起复跑，
# 并**拿文档里的数字当下限做棘轮**：断言被删、判据失效、脚本跑不过 → 非零退出并指名。
#
# **故意不进 `verify-all.sh`**：它要构建 CLI、要起本机 PostgreSQL，约 3~4 分钟，太慢；
# 按需跑（每轮验证类条目、或改动这四个脚本之后）。闭环是十二项（这条不在其中）。
#
# 用法：
#   ./Scripts/run-no-endpoint-evidence.sh                      # 复跑全部并核对下限
#   DOYAH_EVIDENCE_BASELINE=<文件> ./Scripts/run-no-endpoint-evidence.sh   # 换基线（负例测试用）
#   DOYAH_EVIDENCE_OUT=<目录> ./Scripts/run-no-endpoint-evidence.sh        # 换输出目录
#
# 计数口径见 `Scripts/count-evidence-assertions.py` 的 docstring；负例见
# `python3 Scripts/test-no-endpoint-evidence.py`。
#
# 注意（bash 3.2 的多字节坑，见 `Scripts/check-shell-locale-safety.py`）：本文件里变量一律写
# `${变量}` —— 裸写 `$变量` 后面紧跟 CJK 字符时，macOS 自带 bash 3.2 会把变量静默展开成空。
set -uo pipefail

cd "$(dirname "$0")/.."
BASELINE="${DOYAH_EVIDENCE_BASELINE:-Scripts/no-endpoint-evidence-baseline.json}"
OUT="${DOYAH_EVIDENCE_OUT:-.build/no-endpoint-evidence}"
COUNTER="Scripts/count-evidence-assertions.py"

[ -f "${BASELINE}" ] || { echo "❌ 找不到基线文件：${BASELINE}"; exit 2; }
[ -f "${COUNTER}" ] || { echo "❌ 找不到计数脚本：${COUNTER}"; exit 2; }
mkdir -p "${OUT}" || exit 2

entries=$(python3 - "${BASELINE}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in data.get("entries", []):
    covered = ",".join(entry.get("covers", []))
    print("\t".join([
        entry["name"], entry["script"], str(entry["minAssertions"]), covered,
    ]))
PY
) || { echo "❌ 基线文件读不了（JSON 格式？）：${BASELINE}"; exit 2; }

echo "== 「无端点在途项」证据集复跑（基线：${BASELINE}）"
echo
printf '%s\n' "脚本             退出码  断言数  文档下限  结论"
printf '%s\n' "----             ------  ------  --------  ----"

records="${OUT}/.records.jsonl"
: > "${records}"
failed=0

while IFS=$'\t' read -r name script minimum covers; do
    [ -z "${name:-}" ] && continue
    log="${OUT}/${name}.log"

    if [ ! -f "${script}" ]; then
        printf '%-16s %-8s %-10s %-12s %s\n' "${name}" "-" "-" "${minimum}" "❌ 缺脚本 ${script}"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${name}" "${script}" "-" "${minimum}" "${covers}" "missing" "-" >> "${records}"
        failed=1
        continue
    fi

    bash "${script}" >"${log}" 2>&1
    code=$?
    assertions=$(python3 "${COUNTER}" "${log}" --json 2>/dev/null \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["assertions"])' 2>/dev/null)
    assertions=${assertions:-0}

    verdict="✅"
    if [ "${code}" -ne 0 ]; then
        verdict="❌ 退出码 ${code}"
        failed=1
    elif [ "${assertions}" -lt "${minimum}" ]; then
        verdict="❌ 断言 ${assertions} < 文档 ${minimum}（有断言被删或失效）"
        failed=1
    elif [ "${assertions}" -gt "${minimum}" ]; then
        verdict="✅（断言 ${assertions} 已多于文档 ${minimum} —— 该更新文档与下限了）"
    fi

    printf '%-16s %-8s %-10s %-12s %s\n' "${name}" "${code}" "${assertions}" "${minimum}" "${verdict}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${name}" "${script}" "${code}" "${minimum}" "${covers}" "${assertions}" "${log}" >> "${records}"

    if [ "${verdict}" != "✅" ]; then
        echo "        ↳ 日志：${log}（最后 3 行）"
        tail -3 "${log}" | sed 's/^/          /'
    fi
done <<< "${entries}"

python3 - "${records}" "${OUT}/summary.json" "${BASELINE}" <<'PY'
import json, sys, datetime

records, dest, baseline = sys.argv[1], sys.argv[2], sys.argv[3]
entries = []
for line in open(records, encoding="utf-8"):
    line = line.rstrip("\n")
    if not line:
        continue
    name, script, code, minimum, covers, assertions, log = line.split("\t")
    entries.append({
        "name": name,
        "script": script,
        "exitCode": int(code) if code.lstrip("-").isdigit() else None,
        "assertions": int(assertions) if assertions.isdigit() else None,
        "minAssertions": int(minimum),
        "covers": [c for c in covers.split(",") if c],
        "log": log,
    })
    entries[-1]["verdict"] = "ok" if (code == "0" and assertions.isdigit()
                                     and int(assertions) >= int(minimum)) else "failed"
summary = {
    "generatedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "baseline": baseline,
    "ok": bool(entries) and all(e["verdict"] == "ok" for e in entries),
    "entries": entries,
}
json.dump(summary, open(dest, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print()
print("清单：%s（复跑结果落在这里，可逐条回看）" % dest)
PY

echo
if [ "${failed}" -ne 0 ]; then
    echo "❌ 证据集复跑**未全过** —— 见上面指名的那几行；文档里「N 项断言全过」的说法此刻不成立。"
    exit 1
fi
echo "✅ 四条「无端点 / 无实例」在途项的既有断言全部复跑通过（下限已核对）。"
echo "   注意：这只证明**我们这一侧**（真库取证 / 假模型回复 / 假对端 / 假 MySQL 服务器）成立；"
echo "   真实模型端点、真实 MCP 对端、真实 MySQL 多版本实例仍是登记在案的环境阻塞项。"
