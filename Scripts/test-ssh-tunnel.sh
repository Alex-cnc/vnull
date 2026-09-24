#!/bin/bash
# SSH 隧道的可复跑证据（FR-CONN-18）。
#
# **这一套验的是"我们这一侧"**：参数拼得对不对、就绪判定准不准、清场干不干净、
# 以及"隧道真的能把 TCP 转过去"（用一个**替身 ssh** 做真实转发，连到本机临时 PG 上跑一条查询）。
# 真的 SSH 握手（密钥交换 / 认证）是 `ssh` 自己的事，不在这里验 —— 那需要一台跳板机；
# 真跳板机的手工步骤写在 `Docs/design/待人工验收清单.md`。
#
# 用法：./Scripts/test-ssh-tunnel.sh
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
PGBIN="$HOME/tools/pgserver/pgserver/pginstall/bin"
DATADIR="$PWD/.build/pgdata-session-test"
PGPORT_TEST=55433
STUB_DIR="$PWD/.build/stub-ssh"
STUB_LOG="$STUB_DIR/argv.log"
TUNNEL_LOG="$STUB_DIR/tunnel.out"
STARTED_PG=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() {
    pkill -f "doyah-tunnel-$$" 2>/dev/null
    [ -n "${TUNNEL_PID:-}" ] && kill "$TUNNEL_PID" 2>/dev/null
    [ "$STARTED_PG" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1
}
trap cleanup EXIT

echo "== 0) 构建 CLI 与准备替身 ssh =="
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
if swift build --disable-sandbox --cache-path "$PWD/.build-cache" --scratch-path "$PWD/.build" \
    --manifest-cache local -Xswiftc -disable-sandbox --product DoyahCLI > /tmp/ssh-tunnel-build.log 2>&1; then
    check "CLI 构建成功" 0
else
    check "CLI 构建成功" 1
    tail -5 /tmp/ssh-tunnel-build.log
    exit 1
fi

mkdir -p "$STUB_DIR"
rm -f "$STUB_LOG" "$TUNNEL_LOG"
cat > "$STUB_DIR/forward.py" <<'PY'
import socket, sys, threading
local_port, target_host, target_port = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    server.bind(("127.0.0.1", local_port))
except OSError:
    sys.exit(1)          # 等价于 ssh -o ExitOnForwardFailure=yes 的"建不起来就退出"
server.listen(16)

def pipe(source, sink):
    try:
        while True:
            chunk = source.recv(65536)
            if not chunk:
                break
            sink.sendall(chunk)
    except OSError:
        pass
    finally:
        for sock in (source, sink):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

while True:
    connection, _ = server.accept()
    upstream = socket.create_connection((target_host, target_port))
    threading.Thread(target=pipe, args=(connection, upstream), daemon=True).start()
    threading.Thread(target=pipe, args=(upstream, connection), daemon=True).start()
PY
cat > "$STUB_DIR/ssh" <<'SH2'
#!/bin/bash
# 替身 ssh：记 argv、按 -L 真起一个 TCP 转发、像 ssh 一样挂着。
LOG="${STUB_SSH_LOG:-/tmp/stub-ssh.log}"
echo "argv: $*" >> "$LOG"
if [ -n "${SSH_ASKPASS:-}" ]; then
    echo "askpass: $("$SSH_ASKPASS" 'alice@jump password:')" >> "$LOG"
fi
forward=""
while [ $# -gt 0 ]; do
    case "$1" in
        -L) forward="$2"; shift 2 ;;
        *) shift ;;
    esac
done
local_port="${forward%%:*}"
rest="${forward#*:}"
target_host="${rest%%:*}"
target_port="${rest##*:}"
exec python3 "$(dirname "$0")/forward.py" "$local_port" "$target_host" "$target_port"
SH2
chmod +x "$STUB_DIR/ssh"
export STUB_SSH_LOG="$STUB_LOG"
export DOYAH_SSH_BINARY="$STUB_DIR/ssh"
check "替身 ssh 已就位（可执行）" "$([ -x "$STUB_DIR/ssh" ] && echo 0 || echo 1)"

echo ""
echo "== 1) 准备本机 PG（隧道另一端要有真东西可连）=="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PGPORT_TEST} -k /tmp" -l /tmp/doyah-ssh-tunnel-pg.log start >/dev/null 2>&1
    STARTED_PG=1
    sleep 2
fi
"$PGBIN/psql" -h 127.0.0.1 -p "$PGPORT_TEST" -U postgres -d postgres -tAc "SELECT 1" >/dev/null 2>&1
check "本机 PG 在 127.0.0.1:${PGPORT_TEST} 可连" $?

echo ""
echo "== 2) 私钥模式：起隧道 → 通过隧道真连一次库 =="
"$CLI" tunnel --ssh-host jump.example.com --ssh-port 2222 --ssh-user alice \
    --ssh-key /tmp/fake_ed25519 --target-host 127.0.0.1 --target-port "$PGPORT_TEST" \
    --local-port 55901 --hold 12 > "$TUNNEL_LOG" 2>&1 &
TUNNEL_PID=$!
for _ in $(seq 1 60); do grep -q "隧道就绪" "$TUNNEL_LOG" 2>/dev/null && break; sleep 0.2; done
grep -q "隧道就绪：127.0.0.1:55901" "$TUNNEL_LOG" && check "隧道报出本地端点" 0 || { cat "$TUNNEL_LOG"; check "隧道报出本地端点" 1; }
RESULT="$("$PGBIN/psql" -h 127.0.0.1 -p 55901 -U postgres -d postgres -tAc "SELECT 42" 2>&1)"
[ "$RESULT" = "42" ] && check "通过隧道查到数据（真转发：psql → 隧道 → PG）" 0 || { echo "  实际：$RESULT"; check "通过隧道查到数据（真转发：psql → 隧道 → PG）" 1; }
grep -q -- "-N" "$STUB_LOG" && check "argv 带 -N（只转发、不开远端 shell）" 0 || check "argv 带 -N（只转发、不开远端 shell）" 1
grep -q -- "-i /tmp/fake_ed25519" "$STUB_LOG" && check "私钥模式下 -i 指向指定私钥" 0 || check "私钥模式下 -i 指向指私钥" 1
grep -q "IdentitiesOnly=yes" "$STUB_LOG" && check "只用指定钥匙（不去翻 agent / 默认钥匙）" 0 || check "只用指定钥匙（不去翻 agent / 默认钥匙）" 1
grep -q "ExitOnForwardFailure=yes" "$STUB_LOG" && check "建不起转发就退出（不假成功）" 0 || check "建不起转发就退出（不假成功）" 1
grep -q "StrictHostKeyChecking=accept-new" "$STUB_LOG" && check "指纹策略：首次信任、之后变了就拒" 0 || check "指纹策略：首次信任、之后变了就拒" 1
grep -q "UserKnownHostsFile=.*DoyahStudio/known_hosts" "$STUB_LOG" && check "known_hosts 用我们自己的（不动用户的 ~/.ssh）" 0 || { grep -o "UserKnownHostsFile=[^ ]*" "$STUB_LOG"; check "known_hosts 用我们自己的（不动用户的 ~/.ssh）" 1; }

wait "$TUNNEL_PID" 2>/dev/null
check "隧道按 --hold 自己收工（退出码 0）" $?
sleep 0.5
"$PGBIN/psql" -h 127.0.0.1 -p 55901 -U postgres -d postgres -tAc "SELECT 1" >/dev/null 2>&1
[ $? -ne 0 ] && check "收工后本地端口已释放" 0 || check "收工后本地端口已释放" 1

echo ""
echo "== 3) 口令模式：口令经 SSH_ASKPASS 交给 ssh，且临时文件立刻删掉 =="
rm -f "$STUB_LOG"
BEFORE_TMP=$(ls -d "${TMPDIR:-/tmp}"/doyah-tunnel-* 2>/dev/null | wc -l | tr -d ' ')
"$CLI" tunnel --ssh-host jump --ssh-user alice --ssh-password 'Corr3ct-Horse' \
    --target-host 127.0.0.1 --target-port "$PGPORT_TEST" --local-port 55902 --hold 4 > "$TUNNEL_LOG" 2>&1
check "口令模式隧道建立成功（退出码 0）" $?
grep -q "askpass: Corr3ct-Horse" "$STUB_LOG" && check "ssh 通过 SSH_ASKPASS 拿到了口令（不经 argv/环境变量本体）" 0 || { cat "$STUB_LOG"; check "ssh 通过 SSH_ASKPASS 拿到了口令（不经 argv/环境变量本体）" 1; }
grep -q "Corr3ct-Horse" "$TUNNEL_LOG" && check "口令没有出现在隧道自己的输出里" 1 || check "口令没有出现在隧道自己的输出里" 0
AFTER_TMP=$(ls -d "${TMPDIR:-/tmp}"/doyah-tunnel-* 2>/dev/null | wc -l | tr -d ' ')
[ "$AFTER_TMP" = "$BEFORE_TMP" ] && check "askpass 临时目录已清理" 0 || { ls -d "${TMPDIR:-/tmp}"/doyah-tunnel-*; check "askpass 临时目录已清理" 1; }

echo ""
echo "== 4) 转发建不起来时：快速失败、不说假话 =="
python3 - "$STUB_DIR" <<'PY' &
import socket, sys, time
sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 55903))
sock.listen(1)
time.sleep(15)
PY
BLOCKER=$!
sleep 1
"$CLI" tunnel --ssh-host jump --ssh-user alice --ssh-agent \
    --target-host 127.0.0.1 --target-port "$PGPORT_TEST" --local-port 55903 --hold 2 > "$TUNNEL_LOG" 2>&1
CODE=$?
[ "$CODE" -ne 0 ] && check "端口被占用时退出码非 0（实际 ${CODE}）" 0 || check "端口被占用时退出码非 0（实际 ${CODE}）" 1
grep -q "隧道起不来" "$TUNNEL_LOG" && check "如实说明隧道起不来（附 ssh 输出）" 0 || { cat "$TUNNEL_LOG"; check "如实说明隧道起不来（附 ssh 输出）" 1; }
kill "$BLOCKER" 2>/dev/null

echo ""
echo "== 5) --json（脚本用）=="
"$CLI" tunnel --ssh-host jump --ssh-user alice --ssh-agent --target-host 127.0.0.1 \
    --target-port "$PGPORT_TEST" --local-port 55904 --hold 3 --json > "$TUNNEL_LOG" 2>&1
grep -q '"localPort":55904' "$TUNNEL_LOG" && check "--json 里带 localPort" 0 || { cat "$TUNNEL_LOG"; check "--json 里带 localPort" 1; }
grep -q '"targetPort":' "$TUNNEL_LOG" && check "--json 里带 targetPort" 0 || check "--json 里带 targetPort" 1

echo ""
echo "== 6) 参数不全时：说清用法、退出码 2 =="
"$CLI" tunnel --ssh-host jump > "$TUNNEL_LOG" 2>&1
[ $? -eq 2 ] && check "缺参数退出码 2" 0 || check "缺参数退出码 2" 1
grep -q "用法：tunnel" "$TUNNEL_LOG" && check "给了用法" 0 || check "给了用法" 1

echo ""
if [ "$fail" -eq 0 ]; then
    echo "全部通过：隧道参数 / 就绪判定 / 真转发 / 清场 / 快速失败 都对。"
    echo "（**边界**：真的 SSH 握手需要一台跳板机 —— 手工步骤见 Docs/design/待人工验收清单.md）"
else
    echo "有失败项，见上"
fi
exit "$fail"
