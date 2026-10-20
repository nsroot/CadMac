import AppKit
import CadCore

/// Local control endpoint used by the `cadmac-mcp` helper (Claude Code integration).
///
/// Listens on a Unix domain socket (default ~/Library/Application Support/CadMac/automation.sock,
/// override with CADMAC_AUTOMATION_SOCKET; mode 0600, same-user peers only). Protocol: one JSON
/// request per line `{"tool": "...", "args": {...}}`, one JSON response per line
/// `{"ok": Bool, "text": String, "image"?: base64 PNG, "error"?: String}`.
@MainActor
final class AutomationServer {
    static let shared = AutomationServer()
    private var listener: AutomationSocketListener?

    static var socketPath: String {
        if let p = ProcessInfo.processInfo.environment["CADMAC_AUTOMATION_SOCKET"], !p.isEmpty { return p }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CadMac/automation.sock").path
    }

    func start() {
        guard listener == nil, ProcessInfo.processInfo.environment["CADMAC_AUTOMATION_DISABLE"] == nil else { return }
        let l = AutomationSocketListener(path: AutomationServer.socketPath) { line, reply in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AutomationServer.shared.handle(line) { reply($0) }
                }
            }
        }
        do {
            try l.start()
            listener = l
        } catch {
            FileHandle.standardError.write("CadMac automation: \(error)\n".data(using: .utf8)!)
        }
    }

    // MARK: Request dispatch

    struct Response {
        var ok: Bool
        var text: String
        var image: String? = nil
        var error: String? = nil

        static func success(_ obj: Any) -> Response { Response(ok: true, text: obj as? String ?? AutomationJSON.string(obj)) }
        static func failure(_ msg: String) -> Response { Response(ok: false, text: "", error: msg) }

        var data: Data {
            var o: [String: Any] = ["ok": ok, "text": text]
            if let image { o["image"] = image }
            if let error { o["error"] = error }
            return (try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])) ?? Data(#"{"ok":false,"error":"encoding failed"}"#.utf8)
        }
    }

    func handle(_ line: Data, reply: @escaping (Data) -> Void) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let tool = obj["tool"] as? String else {
            reply(Response.failure("Malformed request").data)
            return
        }
        let args = obj["args"] as? [String: Any] ?? [:]
        guard let wc = AutomationServer.targetWindow() else {
            reply(Response.failure("No drawing window is open in CadMac. Open or create a drawing (File ▸ New) first.").data)
            return
        }
        AutomationTools(wc: wc).run(tool, args) { reply($0.data) }
    }

    /// Frontmost drawing window; Block Editor windows only when they are in front.
    static func targetWindow() -> CadWindowController? {
        var wcs = NSApp.orderedWindows.compactMap { $0.windowController as? CadWindowController }
        if wcs.isEmpty { wcs = NSApp.windows.compactMap { $0.windowController as? CadWindowController } }
        if let first = wcs.first, first.blockEdit != nil, first.window?.isMainWindow == true || first.window?.isKeyWindow == true {
            return first
        }
        return wcs.first { $0.blockEdit == nil } ?? wcs.first
    }
}

// MARK: - Socket listener (background threads)

/// Accepts clients on a Unix domain socket; each client is served on its own thread, requests
/// sequentially (the next line is read only after the previous reply was written).
final class AutomationSocketListener: @unchecked Sendable {
    typealias Handler = @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void

    struct SocketError: Error, CustomStringConvertible { let description: String }

    let path: String
    let handler: Handler
    private var fd: Int32 = -1
    static let maxLine = 64 << 20

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard path.utf8.count < 104 else { throw SocketError(description: "socket path too long: \(path)") }
        if FileManager.default.fileExists(atPath: path) {
            // Another live CadMac owns the socket: leave it alone.
            if Self.canConnect(path) { throw SocketError(description: "\(path) is in use by another CadMac instance; automation disabled in this one") }
            unlink(path)
        }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw SocketError(description: "socket() failed: \(errno)") }
        var addr = Self.address(path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let old = umask(0o177)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) } }
        umask(old)
        guard rc == 0 else { close(s); throw SocketError(description: "bind(\(path)) failed: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard listen(s, 8) == 0 else { close(s); throw SocketError(description: "listen failed") }
        fd = s
        let t = Thread { [self] in acceptLoop() }
        t.name = "CadMac automation"
        t.start()
    }

    static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.prefix(raw.count - 1).enumerated() { raw[i] = b }
            raw[min(bytes.count, raw.count - 1)] = 0
        }
        return addr
    }

    static func canConnect(_ path: String) -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var addr = address(path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, len) } } == 0
    }

    private func acceptLoop() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            // Only the same user may drive the app.
            var uid: uid_t = 0, gid: gid_t = 0
            if getpeereid(c, &uid, &gid) != 0 || uid != getuid() { close(c); continue }
            var on: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let t = Thread { [self] in serve(c) }
            t.start()
        }
    }

    private final class Box: @unchecked Sendable { var data = Data() }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) else { continue }
                let box = Box()
                let sem = DispatchSemaphore(value: 0)
                handler(Data(line)) { resp in box.data = resp; sem.signal() }
                sem.wait()
                var out = box.data
                out.append(0x0A)
                guard writeAll(c, out) else { return }
            }
            let n = read(c, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > Self.maxLine {
                _ = writeAll(c, Data(#"{"ok":false,"text":"","error":"request too large"}"#.utf8 + [0x0A]))
                return
            }
        }
    }

    private func writeAll(_ c: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(c, raw.baseAddress! + off, raw.count - off)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }
}
