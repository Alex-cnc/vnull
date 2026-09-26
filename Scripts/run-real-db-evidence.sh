#!/bin/bash
# 「要真库的脚本」的证据集复跑器（开发循环 L-06 起）。
#
# **为什么有它**：有 32 个脚本要连**真实 PostgreSQL / MySQL** 才有意义，而它们不在这条闭环里
# （要起集群、要花几分钟），过去只在「改到它们」时才想得起来跑。L-06 把 28 个脚本的连接信息
# 从各自硬编码收到 `Scripts/lib/test-env.sh` 一处 —— **一次改 32 个文件**，然后靠人「觉得没问题」
# 是这批改动最危险的收尾方式。这条命令把它们逐条复跑，并**拿改动前实测的现状做棘轮**：
#
#   · 改前是绿的（`expectExit: 0`）→ 现在必须还绿，且断言数不少于改前；
#   · 改前就红的（`expectExit: 1`，**原因逐条记在基线里**）→ 现在必须**还是同一个原因红着**
#     （日志里得能找到那条关键词），否则一样报红：红了不要紧，**红的原因变了**才要紧；
#   · 忽然转绿（改红为绿）→ 不算失败，但会点名提示「该更新基线了」。
#
# 断言口径与 L-05 一致，共用 `Scripts/count-evidence-assertions.py`。
#
# **故意不进 `verify-all.sh`**：要起三份本机集群、跑十几分钟。按需跑（改动这批脚本之后必跑）。
#
# 用法：
#   ./Scripts/run-real-db-evidence.sh                       # 全部复跑并核对基线
#   DOYAH_EVIDENCE_BASELINE=<文件> ./Scripts/run-real-db-evidence.sh
#   DOYAH_EVIDENCE_OUT=<目录> ./Scripts/run-real-db-evidence.sh
#   DOYAH_EVIDENCE_ONLY=a,b ./Scripts/run-real-db-evidence.sh   # 只跑名字里含 a 或 b 的（调试用）
#
# 注意（bash 3.2 的多字节坑，见 `Scripts/check-shell-locale-safety.py`）：本文件里变量一律写
# `${变量}` —— 裸写 `$变量` 后面紧跟 CJK 字符时会被静默展开成空。
set -uo pipefail

cd "$(dirname "$0")/.."
BASELINE="${DOYAH_EVIDENCE_BASELINE:-Scripts/real-db-evidence-baseline.json}"
OUT="${DOYAH_EVIDENCE_OUT:-.build/real-db-evidence}"
COUNTER="Scripts/count-evidence-assertions.py"
ONLY="${DOYAH_EVIDENCE_ONLY:-}"

[ -f "${BASELINE}" ] || { echo "❌ 找不到基线文件：${BASELINE}"; exit 2; }
[ -f "${COUNTER}" ] || { echo "❌ 找不到计数脚本：${COUNTER}"; exit 2; }
mkdir -p "${OUT}" || exit 2

entries=$(python3 - "${BASELINE}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in data.get("entries", []):
    red = entry.get("knownRed") or {}
    print("\t".join([
        entry["name"], entry["script"], str(entry["expectExit"]), str(entry["minAssertions"]),
        str(entry.get("profile", "session")), red.get("logMustContain", ""), red.get("reason", ""),
    ]))
PY
) || { echo "❌ 基线文件读不了（JSON 格式？）：${BASELINE}"; exit 2; }

echo "== 「要真库的脚本」证据集复跑（基线：${BASELINE}）"
echo "   本机过渡期：连接信息由 Scripts/lib/test-env.sh 按档位给出（档位表就在那个文件里）"
echo
printf '%s\n' "脚本                退出码  期望  断言数  下限  结论"
printf '%s\n' "----                ------  ----  ------  ----  ----"

records="${OUT}/.records.jsonl"
: > "${records}"
failed=0
improved=0

while IFS=$'\t' read -r name script expect_exit minimum profile red_marker red_reason; do
    [ -z "${name:-}" ] && continue
    if [ -n "${ONLY}" ]; then
        case ",${ONLY}," in
            *",${name},"*) ;;
            *) continue ;;
        esac
    fi
    log="${OUT}/${name}.log"

    if [ ! -f "${script}" ]; then
        printf '%-20s %-7s %-5s %-7s %-5s %s\n' "${name}" "-" "${expect_exit}" "-" "${minimum}" "❌ 缺脚本 ${script}"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${name}" "${script}" "-" "${expect_exit}" "${minimum}" "-" "missing" >> "${records}"
        failed=1
        continue
    fi

    bash "${script}" >"${log}" 2>&1
    code=$?
    assertions=$(python3 "${COUNTER}" "${log}" --json 2>/dev/null \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["assertions"])' 2>/dev/null)
    assertions=${assertions:-0}

    verdict=""
    if [ "${code}" -eq 0 ] && [ "${expect_exit}" -ne 0 ]; then
        verdict="✅ 已转绿（基线记的是红 —— 请更新基线）"
        improved=1
    elif [ "${code}" -ne "${expect_exit}" ]; then
        verdict="❌ 退出码 ${code} ≠ 基线 ${expect_exit}（回归或红的原因变了）"
        failed=1
    elif [ "${assertions}" -lt "${minimum}" ]; then
        verdict="❌ 断言 ${assertions} < 基线 ${minimum}（有断言被删或失效）"
        failed=1
    elif [ "${code}" -ne 0 ] && [ -n "${red_marker}" ]; then
        if grep -q -- "${red_marker}" "${log}"; then
            verdict="✅ 仍按基线记的原因红着"
        else
            verdict="❌ 红着但**不是**基线记的原因（找不到「${red_marker}」）"
            failed=1
        fi
    elif [ "${assertions}" -gt "${minimum}" ]; then
        verdict="✅（断言 ${assertions} > 基线 ${minimum} —— 该更新基线了）"
    else
        verdict="✅"
    fi

    printf '%-20s %-7s %-5s %-7s %-5s %s\n' "${name}" "${code}" "${expect_exit}" "${assertions}" "${minimum}" "${verdict}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${name}" "${script}" "${code}" "${expect_exit}" "${minimum}" "${assertions}" "${verdict}" >> "${records}"
    if [ "${verdict}" != "✅" ]; then
        echo "        ↳ 日志：${log}（最后 3 行）"
        tail -3 "${log}" | sed 's/^/          /'
    fi
done <<< "${entries}"

python3 - "${records}" "${OUT}/summary.json" "${BASELINE}" <<'PY'
import json, sys, datetime

records, dest, baseline = sys.argv[1], sys.argv[2], sys.argv[3]
items = []
for line in open(records, encoding="utf-8"):
    line = line.rstrip("\n")
    if not line:
        continue
    name, script, code, expect, minimum, assertions, verdict = line.split("\t")
    items.append({
        "name": name, "script": script,
        "exitCode": int(code) if code.lstrip("-").isdigit() else None,
        "expectedExit": int(expect),
        "assertions": int(assertions) if assertions.isdigit() else None,
        "minAssertions": int(minimum),
        "verdict": verdict,
        "log": ".build/real-db-evidence/%s.log" % name,
    })
data = json.load(open(baseline, encoding="utf-8"))
summary = {
    "generatedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "baseline": baseline,
    "ok": bool(items) and all(i["verdict"].startswith("✅") for i in items),
    "ran": len(items),
    "entries": items,
    "skippedDueToEnvironment": data.get("skippedDueToEnvironment", []),
}
json.dump(summary, open(dest, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print()
print("清单：%s（逐条结果可回看）" % dest)
print("因环境跳过（不在本次证据里）：%d 条" % len(summary["skippedDueToEnvironment"]))
for item in summary["skippedDueToEnvironment"]:
    print("  · %s —— %s" % (item["script"], item["reason"]))
PY

echo
if [ "${failed}" -ne 0 ]; then
    echo "❌ 证据集复跑**未全过** —— 见上面指名的那几行。"
    exit 1
fi
echo "✅ 与基线一致：绿的仍绿、红的仍按记录的原因红着，断言数一条没少。"
echo "   注意：这只覆盖**本机过渡集群**能验的部分；对 217 / MySQL 的段落在环境卡点里（见上面跳过的清单）。"
exit "${improved}"
