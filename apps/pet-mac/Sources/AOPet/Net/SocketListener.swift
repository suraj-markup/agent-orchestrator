import Foundation
import Darwin

/// Listens for line-delimited JSON envelopes on a Unix domain socket.
///
/// AOPet **owns** the socket: it bind/listen/accepts and the notifier plugin
/// connects as a client and writes envelopes. The previous client-role
/// implementation could not work because nothing else in the system was
/// listening on `~/.agent-orchestrator/pet.sock`.
///
/// The listener supports many concurrent clients (the dashboard may run
/// several notifier processes). Each accepted connection gets its own read
/// loop on a concurrent queue. On `stop()` the listening fd is closed (which
/// unblocks `accept()` with EBADF) and the socket file is unlinked so a
/// fresh start does not collide.
final class SocketListener {
    static let defaultPath: String = {
        let home = NSHomeDirectory()
        return "\(home)/.agent-orchestrator/pet.sock"
    }()

    private let socketPath: String
    private let deliveryQueue: DispatchQueue
    private let onEvent: (SocketEnvelope) -> Void
    private let acceptQueue = DispatchQueue(label: "dev.composio.aopet.socket.accept")
    private let clientQueue = DispatchQueue(
        label: "dev.composio.aopet.socket.clients",
        attributes: .concurrent
    )
    private let stateLock = NSLock()
    private var listenFd: Int32 = -1
    private var clientFds: Set<Int32> = []
    private var stopped = true
    private var backoff: TimeInterval = 1

    init(
        path: String = SocketListener.defaultPath,
        deliveryQueue: DispatchQueue = .main,
        onEvent: @escaping (SocketEnvelope) -> Void
    ) {
        self.socketPath = path
        self.deliveryQueue = deliveryQueue
        self.onEvent = onEvent
    }

    func start() {
        stateLock.lock(); stopped = false; stateLock.unlock()
        acceptQueue.async { [weak self] in self?.bindLoop() }
    }

    func stop() {
        stateLock.lock()
        stopped = true
        let lfd = listenFd
        listenFd = -1
        let cfds = clientFds
        clientFds.removeAll()
        stateLock.unlock()

        // Closing the listening fd unblocks accept() with EBADF; closing
        // each client fd unblocks read() with EBADF in the read loops.
        if lfd >= 0 { Darwin.close(lfd) }
        for f in cfds { Darwin.close(f) }
        unlink(socketPath)
    }

    /// True once the listener is bound and accepting (used by tests to know
    /// when to connect a client without race).
    func isReady() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return listenFd >= 0
    }

    // MARK: - Bind / accept

    private func bindLoop() {
        while !isStopped() {
            // Ensure parent dir (~/.agent-orchestrator/) exists.
            let parent = (socketPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: parent,
                withIntermediateDirectories: true
            )

            // Best-effort: remove any stale file at the bind path. bind()
            // fails with EADDRINUSE otherwise, even when no process holds it.
            unlink(socketPath)

            let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            if s < 0 {
                OneShotLogger.shared.once(
                    "sock.create",
                    "socket() failed: \(String(cString: strerror(errno)))"
                )
                sleepBackoff()
                continue
            }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socketPath.utf8)
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

            let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.bind(s, sockPtr, addrLen)
                }
            }
            if bindResult != 0 {
                OneShotLogger.shared.once(
                    "sock.bind",
                    "bind(\(socketPath)) failed: \(String(cString: strerror(errno)))"
                )
                Darwin.close(s)
                sleepBackoff()
                continue
            }

            // Owner-only access — the socket lives under $HOME so that's
            // already implied, but make it explicit.
            chmod(socketPath, S_IRUSR | S_IWUSR)

            if Darwin.listen(s, 4) != 0 {
                OneShotLogger.shared.once(
                    "sock.listen",
                    "listen() failed: \(String(cString: strerror(errno)))"
                )
                Darwin.close(s)
                unlink(socketPath)
                sleepBackoff()
                continue
            }

            stateLock.lock()
            listenFd = s
            stateLock.unlock()
            OneShotLogger.shared.clear("sock.bind")
            OneShotLogger.shared.clear("sock.listen")
            OneShotLogger.shared.clear("sock.create")
            backoff = 1

            acceptLoop(listenSocket: s)

            // acceptLoop returned: listening fd closed (stop or error).
            stateLock.lock()
            listenFd = -1
            stateLock.unlock()
            Darwin.close(s)
            unlink(socketPath)
            if isStopped() { return }
        }
    }

    private func acceptLoop(listenSocket: Int32) {
        while !isStopped() {
            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(listenSocket, sockPtr, &len)
                }
            }
            if client < 0 {
                let err = errno
                if err == EINTR { continue }
                if err == EBADF || err == EINVAL {
                    // Listening fd was closed (stop() or rebind needed).
                    return
                }
                OneShotLogger.shared.once(
                    "sock.accept",
                    "accept() failed: \(String(cString: strerror(err)))"
                )
                return
            }

            stateLock.lock()
            clientFds.insert(client)
            stateLock.unlock()

            clientQueue.async { [weak self] in
                self?.readClient(fd: client)
            }
        }
    }

    private func readClient(fd: Int32) {
        defer {
            stateLock.lock()
            clientFds.remove(fd)
            stateLock.unlock()
            Darwin.close(fd)
        }

        var buffer = Data()
        let bufSize = 4096
        var rawBuf = [UInt8](repeating: 0, count: bufSize)
        while !isStopped() {
            let n = rawBuf.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress, bufSize)
            }
            if n <= 0 {
                if n < 0 {
                    let err = errno
                    if err != EBADF && err != EINTR {
                        OneShotLogger.shared.once(
                            "sock.read",
                            "read() failed: \(String(cString: strerror(err)))"
                        )
                    }
                }
                return
            }
            buffer.append(rawBuf, count: n)
            drainLines(buffer: &buffer)
        }
    }

    private func drainLines(buffer: inout Data) {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty else { continue }
            do {
                let env = try WireDecoder.decodeEvent(line)
                guard env.kind == "event" else { continue }
                deliveryQueue.async { [weak self] in
                    self?.onEvent(env)
                }
            } catch {
                OneShotLogger.shared.once(
                    "sock.parse",
                    "Failed to decode socket line: \(error)"
                )
            }
        }
    }

    private func isStopped() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopped
    }

    private func sleepBackoff() {
        let secs = UInt32(min(30, max(1, Int(backoff * 2))))
        sleep(secs)
        backoff = min(30, backoff * 2)
    }
}
