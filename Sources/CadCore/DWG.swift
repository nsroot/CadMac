import Foundation

/// Imports DWG by converting it to DXF with an external tool, then reading the DXF.
/// Supported converters, in order of preference: LibreDWG `dwg2dxf`, ODA File Converter.
public enum DWGImporter {
    enum Converter {
        case libreDWG(String)
        case oda(String)
    }

    static let libreDWGPaths = ["/opt/homebrew/bin/dwg2dxf", "/usr/local/bin/dwg2dxf"]
    static let odaPath = "/Applications/ODAFileConverter.app/Contents/MacOS/ODAFileConverter"
    /// Converter time limit in seconds. Large drawings (tens of MB) can take over a minute.
    public static var timeout: TimeInterval = 300

    static var converter: Converter? {
        let fm = FileManager.default
        if let p = libreDWGPaths.first(where: { fm.isExecutableFile(atPath: $0) }) { return .libreDWG(p) }
        if fm.isExecutableFile(atPath: odaPath) { return .oda(odaPath) }
        return nil
    }

    /// True if a DWG converter is installed.
    public static var isAvailable: Bool { converter != nil }

    public static func read(url: URL) throws -> Drawing {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw DXFError.fileNotFound(url.path) }
        guard let conv = converter else { throw DXFError.dwgConverterNotFound }
        let tmp = fm.temporaryDirectory.appendingPathComponent("CadMac-dwg-\(UUID().uuidString)", isDirectory: true)
        let inDir = tmp.appendingPathComponent("in", isDirectory: true)
        let outDir = tmp.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: inDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        // Work on a copy with a plain ASCII name (converters can choke on unusual paths).
        let input = inDir.appendingPathComponent("input.dwg")
        try fm.copyItem(at: url, to: input)

        let output: URL
        let result: (status: Int32, log: String)
        switch conv {
        case .libreDWG(let tool):
            output = outDir.appendingPathComponent("input.dxf")
            result = try run(tool, ["-y", "-o", output.path, input.path], cwd: outDir)
        case .oda(let tool):
            output = outDir.appendingPathComponent("input.dxf")
            // ODAFileConverter <in dir> <out dir> <version> <type> <recurse> <audit> [filter]
            result = try run(tool, [inDir.path, outDir.path, "ACAD2018", "DXF", "0", "1", "*.DWG"], cwd: outDir)
        }
        // LibreDWG often exits non-zero on recoverable errors but still writes usable output.
        guard let data = try? Data(contentsOf: output), !data.isEmpty else {
            let msg = result.log.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DXFError.dwgConversionFailed(msg.isEmpty ? "converter exited with status \(result.status) and produced no output" : String(msg.suffix(600)))
        }
        do {
            return try DXFReader.read(data: data)
        } catch {
            throw DXFError.dwgConversionFailed("the converted DXF could not be read (\(error.localizedDescription))")
        }
    }

    /// Runs a tool with a timeout; returns its exit status and combined output (truncated).
    static func run(_ tool: String, _ args: [String], cwd: URL) throws -> (status: Int32, log: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = cwd
        let logURL = cwd.deletingLastPathComponent().appendingPathComponent("log.txt")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        p.standardOutput = log
        p.standardError = log
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { throw DXFError.dwgConversionFailed("could not launch \(tool): \(error.localizedDescription)") }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 5)
            throw DXFError.dwgTimeout
        }
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return (p.terminationStatus, String(text.suffix(4000)))
    }
}

/// Writes DWG files. CadMac's own writer (AutoCAD 2000 / AC1015) is used first and needs nothing
/// installed. An external converter — LibreDWG `dxf2dwg` or ODA File Converter — is used when the
/// native writer refuses the drawing, or when `CADMAC_DWG_WRITER=converter` asks for it.
public enum DWGExporter {
    enum Converter { case libreDWG(String), oda(String) }

    /// Which writer a save uses.
    public enum Writer: String { case native, converter }

    static var converter: Converter? {
        let fm = FileManager.default
        for p in ["/opt/homebrew/bin/dxf2dwg", "/usr/local/bin/dxf2dwg"] where fm.isExecutableFile(atPath: p) { return .libreDWG(p) }
        let oda = "/Applications/ODAFileConverter.app/Contents/MacOS/ODAFileConverter"
        if fm.isExecutableFile(atPath: oda) { return .oda(oda) }
        return nil
    }

    /// True if a DWG can be written. CadMac always writes one with its own writer.
    public static var isAvailable: Bool { true }

    /// The writer a save would pick on this machine right now.
    public static var preferredWriter: Writer {
        if let forced = ProcessInfo.processInfo.environment["CADMAC_DWG_WRITER"], Writer(rawValue: forced) == .converter {
            return converter == nil ? .native : .converter
        }
        return .native
    }

    public static func write(_ drawing: Drawing, to url: URL) throws { try write(drawing, to: url, using: nil) }

    /// Writes a DWG. `writer` overrides the choice for tests and bug reports.
    public static func write(_ drawing: Drawing, to url: URL, using writer: Writer?) throws {
        if (writer ?? preferredWriter) == .converter, let conv = converter {
            try writeWithConverter(drawing, to: url, conv, note: nil)
            return
        }
        do {
            try NativeDWGWriter.write(drawing, to: url)
        } catch {
            // The native writer refused the drawing (too large for AutoCAD 2000, say); use an
            // installed converter when there is one, otherwise report the native failure.
            guard let conv = converter else { throw error }
            try writeWithConverter(drawing, to: url, conv, note: error.localizedDescription)
        }
    }

    /// Legacy path: write DXF, then convert it to DWG with an external tool.
    private static func writeWithConverter(_ drawing: Drawing, to url: URL, _ conv: Converter, note: String?) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("CadMac-dwgout-\(UUID().uuidString)", isDirectory: true)
        let inDir = tmp.appendingPathComponent("in", isDirectory: true)
        let outDir = tmp.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: inDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let dxf = inDir.appendingPathComponent("drawing.dxf")
        guard let data = DXFWriter.write(drawing).data(using: .utf8) else {
            throw DXFError.dwgConversionFailed("could not encode the drawing as DXF")
        }
        try data.write(to: dxf)

        let output: URL
        let result: (status: Int32, log: String)
        switch conv {
        case .libreDWG(let tool):
            output = outDir.appendingPathComponent("drawing.dwg")
            result = try DWGImporter.run(tool, ["-y", "--as", "r2000", "-o", output.path, dxf.path], cwd: outDir)
        case .oda(let tool):
            output = outDir.appendingPathComponent("drawing.dwg")
            result = try DWGImporter.run(tool, [inDir.path, outDir.path, "ACAD2000", "DWG", "0", "1", "*.DXF"], cwd: outDir)
        }
        // A DWG starts with its version magic, e.g. "AC1015".
        guard let out = try? Data(contentsOf: output), out.count > 6, out.prefix(4) == Data("AC10".utf8) else {
            let msg = result.log.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = msg.isEmpty ? "converter exited with status \(result.status) and produced no DWG" : String(msg.suffix(600))
            throw DXFError.dwgConversionFailed(note == nil ? reason : "\(note!) — and the fallback failed too: \(reason)")
        }
        // Replace the destination only after a successful conversion.
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: output)
        } else {
            try fm.moveItem(at: output, to: url)
        }
    }
}
