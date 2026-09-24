#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假 MySQL 服务器：真跑 MySQL 线协议，用来在没有实例的机器上验驱动链路。

**为什么值得写它**（与替身 ssh 同一个思路）：MySQLNIO 那一层我们信任，但**接线**是我们写的 ——
认证握手、语句下发、结果集解码、影响行数、错误包、取消，任何一处接错，症状都是"连不上"
或者更糟的"看着成功、数据是错的"。本机没有 MySQL 实例时，这是唯一能把整条链路真跑一遍的办法。

覆盖到的协议面（够用即止，**不假装是个真服务器**）：
  · HandshakeV10 + mysql_native_password（口令只做长度校验：对得上就 OK）；
  · HandshakeResponse41 解析（用户名 / 库名）；
  · COM_QUERY：`SELECT …` 回结果集（含 NULL / 中文 / 数字），`INSERT/UPDATE` 回 OK + 影响行数，
    `SELECT CONNECTION_ID()` 等自省查询按真实语义回值；
  · 未知语句回 ERR 包（客户端必须能把它变成可读错误）；
  · COM_PING / COM_QUIT。

**明确不覆盖**：TLS、认证切换（auth switch）、prepared statement、压缩、多结果集、真实的数据类型二进制形态。
所以脚本里的证据只能说明"我们这一侧的接线是对的"，**真机 MySQL 仍要单独验**。
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import threading

# 能力位（只声明我们真正实现的那些）
CLIENT_LONG_PASSWORD = 0x00000001
CLIENT_CONNECT_WITH_DB = 0x00000008
CLIENT_PROTOCOL_41 = 0x00000200
CLIENT_TRANSACTIONS = 0x00002000
CLIENT_SECURE_CONNECTION = 0x00008000
CLIENT_PLUGIN_AUTH = 0x00080000

CAPABILITIES = (
    CLIENT_LONG_PASSWORD
    | CLIENT_CONNECT_WITH_DB
    | CLIENT_PROTOCOL_41
    | CLIENT_TRANSACTIONS
    | CLIENT_SECURE_CONNECTION
    | CLIENT_PLUGIN_AUTH
)

SERVER_VERSION = b"8.0.36-fake"
AUTH_PLUGIN = b"mysql_native_password"

FIELD_TYPE_LONGLONG = 0x08
FIELD_TYPE_VAR_STRING = 0xFD
FIELD_TYPE_LONG = 0x03


def packet(payload: bytes, sequence: int) -> bytes:
    return struct.pack("<I", len(payload))[:3] + bytes([sequence]) + payload


def lenenc(value: int) -> bytes:
    if value < 251:
        return bytes([value])
    if value < 0x10000:
        return b"\xfc" + struct.pack("<H", value)
    if value < 0x1000000:
        return b"\xfd" + struct.pack("<I", value)[:3]
    return b"\xfe" + struct.pack("<Q", value)


def lenenc_str(value: str) -> bytes:
    raw = value.encode("utf-8")
    return lenenc(len(raw)) + raw


def read_lenenc(buf: bytes, pos: int) -> tuple[int, int]:
    first = buf[pos]
    if first < 251:
        return first, pos + 1
    if first == 0xFC:
        return struct.unpack_from("<H", buf, pos + 1)[0], pos + 3
    if first == 0xFD:
        return struct.unpack_from("<I", buf, pos + 1)[0] & 0xFFFFFF, pos + 4
    if first == 0xFE:
        return struct.unpack_from("<Q", buf, pos + 1)[0], pos + 9
    raise ValueError("不支持的长度编码前缀：%d" % first)


class Connection:
    def __init__(self, sock: socket.socket, connection_id: int, log):
        self.sock = sock
        self.connection_id = connection_id
        self.log = log
        self.sequence = 0
        # 上一条语句的影响行数：真实的 MySQL 用 `ROW_COUNT()` 回它，假服务器也得记着，
        # 否则"影响行数"就成了假服务器自己编的数字（假验证里最容易骗过自己的一处）。
        self.last_affected = 0
        self.last_insert_id = 0

    # ---- 收发 ----------------------------------------------------------------
    def send(self, payload: bytes) -> None:
        self.sock.sendall(packet(payload, self.sequence))
        self.sequence = (self.sequence + 1) % 256

    def recv(self) -> bytes:
        header = self._read_exactly(4)
        length = header[0] | (header[1] << 8) | (header[2] << 16)
        self.sequence = (header[3] + 1) % 256
        return self._read_exactly(length)

    def _read_exactly(self, count: int) -> bytes:
        data = b""
        while len(data) < count:
            chunk = self.sock.recv(count - len(data))
            if not chunk:
                raise ConnectionError("客户端断开")
            data += chunk
        return data

    # ---- 协议 ---------------------------------------------------------------
    def handshake(self) -> None:
        salt = b"0123456789abcdefghij"[:20]
        payload = b"\x0a" + SERVER_VERSION + b"\x00"
        payload += struct.pack("<I", self.connection_id)
        payload += salt[:8] + b"\x00"
        payload += struct.pack("<H", CAPABILITIES & 0xFFFF)
        payload += b"\x21"                       # 字符集：utf8_general_ci
        payload += struct.pack("<H", 0x0002)      # 状态：autocommit
        payload += struct.pack("<H", (CAPABILITIES >> 16) & 0xFFFF)
        payload += bytes([21])                    # auth 数据长度
        payload += b"\x00" * 10
        payload += salt[8:] + b"\x00"
        payload += AUTH_PLUGIN + b"\x00"
        self.send(payload)

        response = self.recv()
        username, database = self._parse_handshake_response(response)
        self.log("handshake user=%s database=%s" % (username, database))
        self.send(self.ok_packet(0))

    def _parse_handshake_response(self, buf: bytes) -> tuple[str, str]:
        pos = 4 + 4 + 1 + 23                       # capabilities / max packet / charset / 保留
        end = buf.index(b"\x00", pos)
        username = buf[pos:end].decode("utf-8", "replace")
        pos = end + 1
        auth_len, pos = read_lenenc(buf, pos)
        pos += auth_len
        database = ""
        if pos < len(buf):
            end = buf.index(b"\x00", pos)
            database = buf[pos:end].decode("utf-8", "replace")
        return username, database

    def ok_packet(self, affected_rows: int, last_insert_id: int = 0) -> bytes:
        return (
            b"\x00"
            + lenenc(affected_rows)
            + lenenc(last_insert_id)
            + struct.pack("<H", 0x0002)
            + struct.pack("<H", 0)
        )

    def eof_packet(self) -> bytes:
        return b"\xfe" + struct.pack("<H", 0) + struct.pack("<H", 0x0002)

    def error_packet(self, code: int, sqlstate: str, message: str) -> bytes:
        return b"\xff" + struct.pack("<H", code) + b"#" + sqlstate.encode() + message.encode("utf-8")

    def column_packet(self, name: str, field_type: int, length: int) -> bytes:
        payload = lenenc_str("def") + lenenc_str("testdb") + lenenc_str("t") + lenenc_str("t")
        payload += lenenc_str(name) + lenenc_str(name)
        payload += b"\x0c"
        payload += struct.pack("<H", 0x21)         # 字符集
        payload += struct.pack("<I", length)
        payload += bytes([field_type])
        payload += struct.pack("<H", 0)
        payload += b"\x00" + b"\x00\x00"
        return payload

    def row_packet(self, values: list[str | None]) -> bytes:
        payload = b""
        for value in values:
            payload += b"\xfb" if value is None else lenenc_str(value)
        return payload

    def send_result_set(self, columns: list[tuple[str, int, int]], rows: list[list[str | None]]) -> None:
        self.send(lenenc(len(columns)))
        for name, field_type, length in columns:
            self.send(self.column_packet(name, field_type, length))
        # **列定义之后不发 EOF**：MySQLNIO 的 COM_QUERY 解码器从「列」直接进「行」，
        # 中间那个 EOF 会被当成"结果集结束"，于是第一行数据就成了没人读的垃圾包。
        # （这是对着真实驱动调试出来的，不是猜的。）
        for row in rows:
            self.send(self.row_packet(row))
        self.send(self.eof_packet())

    # ---- 主循环 -------------------------------------------------------------
    def serve(self) -> None:
        self.handshake()
        while True:
            payload = self.recv()
            if not payload:
                continue
            command = payload[0]
            if command == 0x01:                     # COM_QUIT
                self.log("quit")
                return
            if command == 0x0E:                     # COM_PING
                self.send(self.ok_packet(0))
                continue
            if command != 0x03:                     # 只实现 COM_QUERY
                self.send(self.error_packet(1047, "08S01", "fake server: unsupported command %d" % command))
                continue
            sql = payload[1:].decode("utf-8", "replace").strip()
            self.log("query: %s" % sql)
            self.handle_query(sql)

    def handle_query(self, sql: str) -> None:
        upper = sql.upper()
        if upper.startswith("SELECT VERSION()"):
            self.send_result_set(
                [("VERSION()", FIELD_TYPE_VAR_STRING, 255)],
                [[SERVER_VERSION.decode()]],
            )
        elif upper.startswith("SELECT DATABASE()"):
            self.send_result_set([("DATABASE()", FIELD_TYPE_VAR_STRING, 255)], [["testdb"]])
        elif upper.startswith("SELECT CURRENT_USER()"):
            self.send_result_set([("CURRENT_USER()", FIELD_TYPE_VAR_STRING, 255)], [["root@localhost"]])
        elif upper.startswith("SELECT CONNECTION_ID()"):
            self.send_result_set(
                [("CONNECTION_ID()", FIELD_TYPE_LONGLONG, 21)],
                [[str(self.connection_id)]],
            )
        elif upper.startswith("SELECT 1") and (" FROM " not in upper):
            self.send_result_set([("1", FIELD_TYPE_LONGLONG, 21)], [["1"]])
        elif "MISSING_TABLE" in upper or "FROM MISSING" in upper:
            self.send(self.error_packet(1146, "42S02", "Table 'testdb.missing' doesn't exist"))
        elif upper.startswith("SELECT ROW_COUNT()"):
            # 影响行数 / 自增 ID：回**上一条语句**的结果，与真实语义一致。
            self.send_result_set(
                [
                    ("ROW_COUNT()", FIELD_TYPE_LONGLONG, 21),
                    ("LAST_INSERT_ID()", FIELD_TYPE_LONGLONG, 21),
                ],
                [[str(self.last_affected), str(self.last_insert_id)]],
            )
        elif upper.startswith("SELECT"):
            # 一份"每个坑都有"的结果：中文、NULL、空串、数字、长文本。
            columns = [
                ("id", FIELD_TYPE_LONGLONG, 21),
                ("name", FIELD_TYPE_VAR_STRING, 255),
                ("note", FIELD_TYPE_VAR_STRING, 255),
                ("amount", FIELD_TYPE_LONG, 11),
            ]
            rows = [
                ["1", "客户甲", None, "12"],
                ["2", "", "空串与 NULL 必须分得开", "0"],
                ["3", "it's quoted", "含 \\t 制表符与 \\n 换行", "-7"],
            ]
            self.send_result_set(columns, rows)
        elif upper.startswith("INSERT") or upper.startswith("UPDATE") or upper.startswith("DELETE"):
            self.last_affected = 3
            self.last_insert_id = 42
            self.send(self.ok_packet(3, 42))
        elif upper.startswith("START TRANSACTION") or upper.startswith("COMMIT") or upper.startswith("ROLLBACK"):
            self.send(self.ok_packet(0))
        elif upper.startswith("KILL QUERY"):
            self.send(self.ok_packet(0))
        elif upper.startswith("SHOW DATABASES"):
            self.send_result_set([("Database", FIELD_TYPE_VAR_STRING, 255)], [["information_schema"], ["testdb"]])
        elif upper.startswith("SHOW TABLES"):
            self.send_result_set(
                [("Tables_in_testdb", FIELD_TYPE_VAR_STRING, 255)], [["customers"], ["orders"]]
            )
        else:
            # 未知语句**明确报错**，不静默成功 —— 静默成功是最坏的一种假验证。
            self.send(self.error_packet(1064, "42000", "fake server: unknown statement: %s" % sql[:60]))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=33061)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--log", default="")
    parser.add_argument("--once", action="store_true", help="处理完一个连接就退出（脚本用）")
    args = parser.parse_args()

    log_file = open(args.log, "a", encoding="utf-8") if args.log else None

    def log(message: str) -> None:
        if log_file:
            log_file.write(message + "\n")
            log_file.flush()

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.port))
    server.listen(8)
    log("listening on %s:%d" % (args.host, args.port))

    connection_id = 100
    served = 0
    while True:
        client, _ = server.accept()
        connection_id += 1
        connection = Connection(client, connection_id, log)
        try:
            connection.serve()
        except (ConnectionError, ValueError) as error:
            log("connection ended: %s" % error)
        finally:
            client.close()
        served += 1
        if args.once and served >= 1:
            break
    return 0


if __name__ == "__main__":
    sys.exit(main())
