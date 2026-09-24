import Darwin
import Foundation

/// 本机端口的两个小工具（FR-CONN-18 的 SSH 隧道要用）。
///
/// **为什么在 App 而不是 Core**：Core 不许 `import Darwin`（平台中立性闸门）——
/// 隧道逻辑在 Core，而"端口通不通 / 哪个端口空着"这两件必须用 socket 的事由调用方注入。
/// 命令行侧有一份等价实现（`CLI/main.swift`），因为它不依赖 App target。
enum LocalPort {

    /// 127.0.0.1 的这个端口上有没有人在监听。
    static func isOpen(host: String, port: Int, timeoutMicroseconds: Int32 = 200_000) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr(host == "localhost" ? "127.0.0.1" : host)

        var timeout = timeval(tv_sec: 0, tv_usec: timeoutMicroseconds)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// 让系统分配一个空闲端口（绑到 0 再读回来），随即释放。
    ///
    /// 说明：从"释放"到 `ssh` 真正绑定之间有极小的竞态窗口；隧道侧用
    /// `-o ExitOnForwardFailure=yes` 保证"绑不上就退出"，于是失败会**显式**报出来，而不是静默假成功。
    static func free() -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
