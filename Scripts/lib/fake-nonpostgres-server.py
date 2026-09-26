#!/usr/bin/env python3
"""假服务端：**对端不是 PostgreSQL** 的那个现场（连接失败文案的真证据用）。

为什么需要它：`Scripts/connection-failure-dispositions.json` 里那 9 个「中性归因」的驱动错误码
（用户取消 / 我们主动断开 / 协议层 / LISTEN 通道…）**没有一个能靠真库触发** —— 真库不会
在认证阶段发一个协议外的字节。想让文案有真实现场，只能自己造一个「不是 PostgreSQL 的对端」。

做法：监听一个端口，收到任何东西之后**只回一个字节 `N`** —— 那不是 PostgreSQL 的认证 /
错误消息（认证阶段应当是 `R` / `E` 打头的带长度报文），驱动于是报
`PSQLError(code: unexpectedBackendMessage)`（2026-09-26 实测；等价现场：端口被别的服务占用、
链路上有代理改写了 SSL 协商）。

用法：`python3 Scripts/lib/fake-nonpostgres-server.py <端口>`（只服务一个连接，随后自己退出）
"""

import socket
import sys
import time

port = int(sys.argv[1])

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", port))
server.listen(1)
print(f"fake-non-postgres listening on 127.0.0.1:{port}", flush=True)

connection, _ = server.accept()
received = connection.recv(1024)
print(f"received {received[:16]!r}", flush=True)

# 一个字节，且不是任何合法的 PostgreSQL 报文
connection.sendall(b"N")
time.sleep(0.5)
connection.close()
server.close()
print("done", flush=True)
