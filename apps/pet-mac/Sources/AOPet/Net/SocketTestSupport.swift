import Foundation
import Darwin

/// Real socket round-trip exercised from both the embedded `--self-test`
/// runner and the XCTest target. Binds a listener at a temp path, connects
/// a client, writes a JSON envelope, and verifies the listener surfaces it
/// via its callback.
///
/// Lives in the production module (instead of in tests) so both runners can
/// share a single implementation without duplication.
enum SocketTestSupport {
    /// Returns nil on success, a human-readable error string on failure.
    static func roundTrip() -> String? {
        let tmp = NSTemporaryDirectory()
            + "aopet-test-\(UUID().uuidString).sock"
        let received = DispatchSemaphore(value: 0)
        let recvLock = NSLock()
        var receivedId: String?
        let deliveryQueue = DispatchQueue(label: "aopet.test.delivery")

        let listener = SocketListener(
            path: tmp,
            deliveryQueue: deliveryQueue
        ) { env in
            recvLock.lock()
            receivedId = env.event.id
            recvLock.unlock()
            received.signal()
        }
        listener.start()
        defer {
            listener.stop()
            unlink(tmp)
        }

        // start() dispatches async, so poll briefly until bind/listen
        // completes. 2s is generous on macOS — bind on a Unix socket is
        // typically sub-millisecond.
        let bindDeadline = Date(timeIntervalSinceNow: 2.0)
        while !listener.isReady() {
            if Date() > bindDeadline {
                return "listener did not become ready within 2s"
            }
            usleep(10_000)
        }

        let client = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if client < 0 {
            return "client socket() failed: \(String(cString: strerror(errno)))"
        }
        defer { Darwin.close(client) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(tmp.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: 104) { cPtr in
                let maxLen = min(pathBytes.count, 103)
                for i in 0..<maxLen {
                    cPtr[i] = CChar(bitPattern: pathBytes[i])
                }
                cPtr[maxLen] = 0
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(client, sockPtr, addrLen)
            }
        }
        if connectResult != 0 {
            return "client connect() failed: \(String(cString: strerror(errno)))"
        }

        let envelope = #"""
        {"v":1,"kind":"event","event":{"id":"e-test","type":"pr_merged","priority":"info","message":"round-trip"}}
        """# + "\n"
        let bytes = Array(envelope.utf8)
        let written = bytes.withUnsafeBufferPointer { buf -> Int in
            Darwin.write(client, buf.baseAddress, bytes.count)
        }
        if written != bytes.count {
            return "write() short: wrote \(written) of \(bytes.count) (\(String(cString: strerror(errno))))"
        }

        if received.wait(timeout: .now() + 2.0) == .timedOut {
            return "did not receive event within 2s"
        }
        recvLock.lock()
        let observed = receivedId
        recvLock.unlock()
        if observed != "e-test" {
            return "wrong event id: \(observed ?? "nil")"
        }
        return nil
    }
}
