import Foundation

// MARK: - Errors

public enum DXFError: Error, LocalizedError, Equatable {
    case empty
    case binaryNotSupported
    case malformed(line: Int, reason: String)
    case notDXF
    case dwgConverterNotFound
    case dwgConversionFailed(String)
    case dwgTimeout
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "The DXF file is empty."
        case .binaryNotSupported: return "Binary DXF files are not supported. Save the drawing as ASCII DXF."
        case let .malformed(line, reason): return "The DXF file is malformed near line \(line): \(reason)"
        case .notDXF: return "The file does not look like a DXF drawing (no SECTION found)."
        case .dwgConverterNotFound:
            return "No DWG converter was found. Install LibreDWG (brew install libredwg) or the ODA File Converter, or save the drawing as DXF."
        case .dwgConversionFailed(let msg): return "DWG conversion failed: \(msg)"
        case .dwgTimeout: return "DWG conversion timed out."
        case .fileNotFound(let p): return "File not found: \(p)"
        }
    }
}

// MARK: - Group code pairs and records

struct DXFPair {
    var code: Int
    var value: String
    var double: Double { Double(value) ?? Double(value.trimmingCharacters(in: .whitespaces)) ?? 0 }
    var int: Int {
        if let v = Int(value) { return v }
        let t = value.trimmingCharacters(in: .whitespaces)
        return Int(t) ?? Int(Double(t) ?? 0)
    }
}

/// One DXF object: the value of group code 0 plus the pairs that follow it.
struct DXFRecord {
    var type: String
    var pairs: [DXFPair]

    func first(_ code: Int) -> DXFPair? { pairs.first { $0.code == code } }
    func has(_ code: Int) -> Bool { first(code) != nil }
    func d(_ code: Int, _ def: Double = 0) -> Double { first(code)?.double ?? def }
    func i(_ code: Int, _ def: Int = 0) -> Int { first(code)?.int ?? def }
    /// String value with \U+XXXX escapes decoded.
    func s(_ code: Int) -> String? { first(code).map { dxfDecodeUnicode($0.value) } }
    func pt(_ code: Int) -> Vec2 { Vec2(d(code), d(code + 10)) }
    func all(_ code: Int) -> [DXFPair] { pairs.filter { $0.code == code } }
    /// Owner handle: the last 330 before the first subclass marker (after any reactors).
    var owner: String? {
        var o: String?
        for p in pairs {
            if p.code == 100 { break }
            if p.code == 330 { o = p.value }
        }
        return o
    }
    /// Splits off an embedded object (R2018 multiline ATTRIB/ATTDEF MTEXT, kept after a
    /// 101 marker pair) from the record's own pairs.
    func splitEmbedded() -> (own: DXFRecord, embedded: DXFRecord?) {
        guard let k = pairs.firstIndex(where: { $0.code == 101 }) else { return (self, nil) }
        return (DXFRecord(type: type, pairs: Array(pairs[..<k])),
                DXFRecord(type: "MTEXT", pairs: Array(pairs[(k + 1)...])))
    }
    /// True when the extrusion direction is -Z (OCS mirrored in X).
    var isMirroredOCS: Bool {
        abs(d(210)) < 1.0 / 64 && abs(d(220)) < 1.0 / 64 && d(230, 1) < 0
    }
}

/// Codes never used by the reader; dropped before decoding to save time and memory
/// (handles, owners, reactors, preview bitmaps, comments, XDATA).
@inline(__always) private func dxfSkipCode(_ c: Int) -> Bool {
    c == 5 || c == 102 || c == 310 || c == 330 || c == 360 || c == 999 || c >= 1000
}

/// Records whose own handle (5) and owner/pointer codes (330) are kept; the layout
/// reader needs them to link layers, block records and LAYOUT objects.
private let dxfRefRecordTypes: Set<String> = ["BLOCK_RECORD", "LAYER", "LAYOUT", "DICTIONARY", "GROUP", "FIELD"]

/// Records whose embedded object (101) is kept, after a 101 marker pair.
private let dxfEmbeddedRecordTypes: Set<String> = ["ATTRIB", "ATTDEF"]

/// Tokenizes raw DXF bytes into records in a single pass. Tolerates CR/LF/CRLF line
/// endings and padded codes. Each value is decoded as UTF-8 when valid, otherwise with the
/// file's code page ($DWGCODEPAGE) or Windows-1252. Pairs after an embedded-object
/// marker (101) are dropped (except for ATTRIB/ATTDEF), as are handles/owners except for
/// `dxfRefRecordTypes`. With `keepHandles` every record keeps its handle (5), e.g. so
/// GROUP members can be resolved.
func dxfRecords(from data: Data, keepHandles: Bool = false) throws -> [DXFRecord] {
    if data.isEmpty { throw DXFError.empty }
    if data.starts(with: Array("AutoCAD Binary DXF".utf8)) { throw DXFError.binaryNotSupported }
    let fallback = dxfFallbackEncoding(data)
    return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [DXFRecord] in
        let bytes = raw.bindMemory(to: UInt8.self)
        let n = bytes.count
        var pos = 0
        if n >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF { pos = 3 }
        var lineNo = 0

        func nextLine() -> Range<Int>? {
            guard pos < n else { return nil }
            let start = pos
            while pos < n && bytes[pos] != 0x0A && bytes[pos] != 0x0D { pos += 1 }
            let end = pos
            if pos < n {
                if bytes[pos] == 0x0D && pos + 1 < n && bytes[pos + 1] == 0x0A { pos += 2 } else { pos += 1 }
            }
            lineNo += 1
            return start..<end
        }
        func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 }
        func isBlank(_ r: Range<Int>) -> Bool { r.allSatisfy { isSpace(bytes[$0]) } }
        func parseCode(_ r: Range<Int>) -> Int? {
            var lo = r.lowerBound, hi = r.upperBound
            while lo < hi && isSpace(bytes[lo]) { lo += 1 }
            while hi > lo && isSpace(bytes[hi - 1]) { hi -= 1 }
            var neg = false
            if lo < hi && bytes[lo] == 0x2D { neg = true; lo += 1 }
            guard lo < hi, hi - lo <= 7 else { return nil }
            var v = 0
            for k in lo..<hi {
                let d = Int(bytes[k]) &- 48
                guard d >= 0 && d <= 9 else { return nil }
                v = v * 10 + d
            }
            return neg ? -v : v
        }
        func decode(_ r: Range<Int>) -> String {
            let slice = UnsafeBufferPointer(rebasing: bytes[r])
            var ascii = true
            for b in slice where b >= 0x80 { ascii = false; break }
            if ascii { return String(decoding: slice, as: UTF8.self) }
            let d = Data(slice)
            return String(data: d, encoding: .utf8) ?? String(data: d, encoding: fallback)
                ?? String(data: d, encoding: .isoLatin1) ?? ""
        }

        var out: [DXFRecord] = []
        var current: DXFRecord?
        var embedded = false
        var keepRefs = false
        var keepEmbedded = false
        while let cl = nextLine() {
            let codeLine = lineNo
            guard let code = parseCode(cl) else {
                // Trailing whitespace at the end of the file is fine.
                if isBlank(cl) && (pos..<n).allSatisfy({ isSpace(bytes[$0]) || bytes[$0] == 0x0A || bytes[$0] == 0x0D }) { break }
                let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[cl]).prefix(40), as: UTF8.self)
                throw DXFError.malformed(line: codeLine, reason: "expected a group code, found \"\(text)\"")
            }
            guard let vl = nextLine() else { break }
            if code == 0 {
                if let c = current { out.append(c) }
                let type = decode(vl).trimmingCharacters(in: .whitespaces).uppercased()
                current = DXFRecord(type: type, pairs: [])
                embedded = false
                keepRefs = dxfRefRecordTypes.contains(type)
                keepEmbedded = dxfEmbeddedRecordTypes.contains(type)
                if current?.type == "EOF" { break }
            } else if code == 101 {
                if keepEmbedded && !embedded && current != nil { current!.pairs.append(DXFPair(code: 101, value: "")) }
                embedded = true
            } else if (!embedded || keepEmbedded) && current != nil
                        && (!dxfSkipCode(code) || (code == 5 && (keepHandles || keepRefs)) || (keepRefs && (code == 330 || code == 360))) {
                current!.pairs.append(DXFPair(code: code, value: decode(vl)))
            }
        }
        if let c = current { out.append(c) }
        return out
    }
}

/// Encoding for non-UTF-8 values, from $DWGCODEPAGE near the start of the file.
private func dxfFallbackEncoding(_ data: Data) -> String.Encoding {
    let head = String(decoding: data.prefix(256 * 1024), as: UTF8.self)
    guard let r = head.range(of: "$DWGCODEPAGE") else { return .windowsCP1252 }
    let lines = head[r.upperBound...].split(whereSeparator: \.isNewline).prefix(2)
    guard lines.count == 2 else { return .windowsCP1252 }
    return encoding(forCodePage: lines[lines.startIndex + 1].trimmingCharacters(in: .whitespaces).uppercased())
}

private func encoding(forCodePage cp: String) -> String.Encoding {
    func cf(_ e: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
    }
    switch cp {
    case "ANSI_1250": return .windowsCP1250
    case "ANSI_1251": return .windowsCP1251
    case "ANSI_1253": return .windowsCP1253
    case "ANSI_1254": return .windowsCP1254
    case "ANSI_1255": return cf(.windowsHebrew)
    case "ANSI_1256": return cf(.windowsArabic)
    case "ANSI_1257": return cf(.windowsBalticRim)
    case "ANSI_1258": return cf(.windowsVietnamese)
    case "ANSI_874": return cf(.dosThai)
    case "ANSI_932": return .shiftJIS
    case "ANSI_936": return cf(.GB_18030_2000)
    case "ANSI_949": return cf(.dosKorean)
    case "ANSI_950": return cf(.big5)
    default: return .windowsCP1252
    }
}

// MARK: - String escapes

/// Decodes AutoCAD `\U+XXXX` escapes (UTF-16 code units; surrogate pairs combined).
func dxfDecodeUnicode(_ s: String) -> String {
    guard s.contains("\\U+") || s.contains("\\u+") else { return s }
    var units: [UInt16] = []
    let u = Array(s.utf16)
    var i = 0
    func hex(_ c: UInt16) -> UInt16? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }
    while i < u.count {
        if u[i] == 92, i + 7 <= u.count, u[i + 1] == 85 || u[i + 1] == 117, u[i + 2] == 43 {
            var v: UInt16 = 0
            var ok = true
            for k in 3..<7 {
                guard let h = hex(u[i + k]) else { ok = false; break }
                v = v << 4 | h
            }
            if ok {
                units.append(v)
                i += 7
                continue
            }
        }
        units.append(u[i])
        i += 1
    }
    return String(decoding: units, as: UTF16.self)
}

/// Encodes non-ASCII characters as `\U+XXXX` so the output is pure ASCII.
func dxfEncodeUnicode(_ s: String) -> String {
    if s.utf8.allSatisfy({ $0 < 0x80 }) { return s }
    var out = ""
    for scalar in s.unicodeScalars {
        if scalar.value < 0x80 {
            out.unicodeScalars.append(scalar)
        } else {
            for unit in String(scalar).utf16 { out += String(format: "\\U+%04X", unit) }
        }
    }
    return out
}

/// Converts TEXT control codes (%%c, %%d, %%p, %%u ...) to plain characters.
func dxfDecodeTextControls(_ s: String) -> String {
    guard s.contains("%%") else { return s }
    var out = ""
    var chars = Array(s)[...]
    while let c = chars.first {
        if c == "%", chars.count >= 3, chars[chars.startIndex + 1] == "%" {
            let k = chars[chars.startIndex + 2]
            switch k {
            case "c", "C": out += "Ø"; chars = chars.dropFirst(3); continue
            case "d", "D": out += "°"; chars = chars.dropFirst(3); continue
            case "p", "P": out += "±"; chars = chars.dropFirst(3); continue
            case "%": out += "%"; chars = chars.dropFirst(3); continue
            case "u", "U", "o", "O", "k", "K": chars = chars.dropFirst(3); continue
            default:
                // %%nnn: character code.
                let digits = chars.dropFirst(2).prefix(3)
                if digits.count == 3, let v = Int(String(digits)), let sc = Unicode.Scalar(v) {
                    out.unicodeScalars.append(sc); chars = chars.dropFirst(5); continue
                }
            }
        }
        out.append(c)
        chars = chars.dropFirst()
    }
    return out
}

/// Strips MTEXT inline formatting, returning plain text with "\n" line breaks.
func dxfStripMText(_ s: String) -> String {
    let c = Array(s)
    var out = ""
    var i = 0
    func skipToSemicolon() {
        while i < c.count && c[i] != ";" { i += 1 }
        i += 1
    }
    while i < c.count {
        let ch = c[i]
        if ch == "\\" && i + 1 < c.count {
            let k = c[i + 1]
            i += 2
            switch k {
            case "P", "X", "N": out += "\n"
            case "~": out += " "
            case "\\", "{", "}": out.append(k)
            case "L", "l", "O", "o", "K", "k": break
            case "f", "F", "H", "h", "C", "c", "A", "a", "T", "t", "Q", "q", "W", "w", "p": skipToSemicolon()
            case "S":
                // Stacked fraction: \Snum/den; (also ^ and #).
                var frac = ""
                while i < c.count && c[i] != ";" {
                    let f = c[i]
                    frac.append(f == "^" || f == "#" ? "/" : f)
                    i += 1
                }
                i += 1
                out += frac.trimmingCharacters(in: .whitespaces)
            default: out.append(k)
            }
        } else if ch == "{" || ch == "}" {
            i += 1
        } else if ch == "^" && i + 1 < c.count && c[i + 1] == "I" {
            out += "\t"; i += 2
        } else {
            out.append(ch); i += 1
        }
    }
    return out
}

/// Escapes plain text for MTEXT content (newline -> \P).
func dxfEscapeMText(_ s: String) -> String {
    var out = ""
    for ch in s {
        switch ch {
        case "\\": out += "\\\\"
        case "{": out += "\\{"
        case "}": out += "\\}"
        case "\n": out += "\\P"
        case "\r": break
        default: out.append(ch)
        }
    }
    return out
}

// MARK: - Shared helpers

/// Hatch pattern names drawn as two perpendicular line families.
let dxfCrossPatterns: Set<String> = ["ANSI37", "NET", "SQUARE", "BOX", "ANSI38", "NET3"]

/// Angle of the pattern's base line family (ANSI hatches run at 45 degrees).
func dxfPatternBaseAngle(_ name: String) -> Double {
    name.uppercased().hasPrefix("ANSI3") ? 45 : 0
}

/// Valid DXF lineweight values (hundredths of mm).
let dxfLineweights = [0, 5, 9, 13, 15, 18, 20, 25, 30, 35, 40, 50, 53, 60, 70, 80, 90, 100, 106, 120, 140, 158, 200, 211]

/// Bezier control polygon of the Catmull-Rom curve used for fit-point splines,
/// i.e. an exactly equivalent cubic B-spline with triple interior knots.
func catmullRomControlPoints(_ pts: [Vec2], closed: Bool) -> (cps: [Vec2], knots: [Double]) {
    let count = closed ? pts.count : pts.count - 1
    var cps: [Vec2] = [pts[0]]
    var knots: [Double] = [0, 0, 0, 0]
    for i in 0..<count {
        let p0 = pts[closed ? (i - 1 + pts.count) % pts.count : max(0, i - 1)]
        let p1 = pts[i]
        let p2 = pts[(i + 1) % pts.count]
        let p3 = pts[closed ? (i + 2) % pts.count : min(pts.count - 1, i + 2)]
        cps += [p1 + (p2 - p0) / 6, p2 - (p3 - p1) / 6, p2]
        let k = Double(i + 1)
        knots += i == count - 1 ? [k, k, k, k] : [k, k, k]
    }
    return (cps, knots)
}
