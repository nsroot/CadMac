import Foundation

/// Errors thrown by `NativeDWGReader`.
public enum DWGReadError: Error, LocalizedError, Equatable {
    case notDWG
    case unsupportedVersion(String)
    case encrypted
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .notDWG: return "The file is not a DWG drawing."
        case .unsupportedVersion(let v): return "DWG version \(v) is not supported yet."
        case .encrypted: return "The DWG file is password protected."
        case .corrupt(let why): return "The DWG file is damaged or uses an unexpected layout: \(why)"
        }
    }
}

/// The raw sections of a DWG file, decompressed and ready for bit-level decoding.
struct DWGReadFile {
    var version: DWGVersion
    /// Maintenance release (file offset 0x0B).
    var maintenance: Int
    var codePage: Int
    /// AcDb:Header (R2004+) or the header-variables block (R13-R15), starting at its sentinel.
    var header: [UInt8] = []
    /// AcDb:Classes, starting at its sentinel.
    var classes: [UInt8] = []
    /// AcDb:Handles (object map).
    var handles: [UInt8] = []
    /// AcDb:AcDbObjects (R2004+) or the whole file (R13-R15, whose object map holds file offsets).
    var objects: [UInt8] = []
    /// Number of page / section checksums that did not match (diagnostics).
    var checksumErrors = 0

    var encoding: String.Encoding { dwgReadEncoding(forCodePage: codePage) }
}

enum DWGReadContainer {
    static let headerSentinel: [UInt8] = [0xCF, 0x7B, 0x1F, 0x23, 0xFD, 0xDE, 0x38, 0xA9, 0x5F, 0x7C, 0x68, 0xB8, 0x4E, 0x6D, 0x33, 0x5F]
    static let classesSentinel: [UInt8] = [0x8D, 0xA1, 0xC4, 0xB8, 0xC4, 0xA9, 0xF8, 0xC5, 0xC0, 0xDC, 0xF4, 0x5F, 0xE7, 0xCF, 0xB6, 0x8A]

    /// Upper bound for decompressed section sizes: protects against absurd allocations from
    /// damaged size fields (real files expand roughly 4x; sambo.dwg 15 MB -> 56 MB objects).
    static func sizeLimit(_ fileSize: Int) -> Int { min(0x4000_0000, max(1 << 24, fileSize * 64)) }

    static func open(_ d: [UInt8]) throws -> DWGReadFile {
        guard d.count >= 0x100 || (d.count >= 0x40 && d.starts(with: Array("AC10".utf8))) else { throw DWGReadError.notDWG }
        guard d.starts(with: Array("AC".utf8)) else { throw DWGReadError.notDWG }
        let tag = String(decoding: d[0..<6], as: UTF8.self)
        guard let v = DWGVersion(rawValue: tag) else {
            if tag.hasPrefix("AC10") || tag.hasPrefix("AC2") || tag.hasPrefix("AC1") {
                throw DWGReadError.unsupportedVersion(tag)
            }
            throw DWGReadError.notDWG
        }
        switch v {
        case .r13, .r14, .r2000: return try openR15(d, v)
        case .r2007: return try DWGReadR2007.open(d)
        default: return try openR2004(d, v)
        }
    }

    // MARK: R13 - R15

    static func openR15(_ d: [UInt8], _ v: DWGVersion) throws -> DWGReadFile {
        guard d.count > 0x19 else { throw DWGReadError.corrupt("file header is truncated") }
        var f = DWGReadFile(version: v, maintenance: Int(d[0x0B]), codePage: Int(dwgReadLE16(d, 0x13)))
        let n = Int(dwgReadLE32(d, 0x15))
        guard n >= 3, n <= 16, 0x19 + n * 9 + 2 <= d.count else { throw DWGReadError.corrupt("bad section locator count") }
        var loc: [Int: (seek: Int, size: Int)] = [:]
        for k in 0..<n {
            let o = 0x19 + k * 9
            loc[Int(d[o])] = (Int(dwgReadLE32(d, o + 1)), Int(dwgReadLE32(d, o + 5)))
        }
        // Header CRC (spec 3.2.6).
        let crcPos = 0x19 + n * 9
        let magic: [Int: UInt16] = [3: 0xA598, 4: 0x8101, 5: 0x3CC4, 6: 0x8461]
        let crc = DWGReadCRC.crc16(d, 0..<crcPos, seed: 0) ^ (magic[n] ?? 0)
        if crc != dwgReadLE16(d, crcPos) { f.checksumErrors += 1 }

        func slice(_ k: Int) throws -> [UInt8] {
            guard let l = loc[k], l.seek >= 0, l.size >= 0, l.seek + l.size <= d.count else {
                throw DWGReadError.corrupt("section \(k) lies outside the file")
            }
            return Array(d[l.seek..<(l.seek + l.size)])
        }
        f.header = try slice(0)
        f.classes = try slice(1)
        f.handles = try slice(2)
        f.objects = d
        guard f.header.starts(with: headerSentinel) else { throw DWGReadError.corrupt("header sentinel not found") }
        guard f.classes.starts(with: classesSentinel) else { throw DWGReadError.corrupt("classes sentinel not found") }
        return f
    }

    // MARK: R2004 / R2010 / R2013 / R2018

    static let magicSequence: [UInt8] = {
        var out = [UInt8](repeating: 0, count: 0x100)
        var seed: UInt32 = 1
        for i in 0..<0x100 {
            seed = seed &* 0x343FD &+ 0x269EC3
            out[i] = UInt8((seed >> 16) & 0xFF)
        }
        return out
    }()

    struct SectionInfo {
        var name: String
        var size: Int
        var maxPageSize: Int
        var compressed: Bool
        var encrypted: Int
        var pages: [(number: Int, dataSize: Int, start: Int)]
    }

    static func openR2004(_ d: [UInt8], _ v: DWGVersion) throws -> DWGReadFile {
        guard d.count >= 0x100 else { throw DWGReadError.corrupt("file header is truncated") }
        var f = DWGReadFile(version: v, maintenance: Int(d[0x0B]), codePage: Int(dwgReadLE16(d, 0x13)))
        if dwgReadLE32(d, 0x18) & 1 != 0 { throw DWGReadError.encrypted }
        var hdr = [UInt8](repeating: 0, count: 0x6C)
        for i in 0..<0x6C { hdr[i] = d[0x80 + i] ^ magicSequence[i] }
        guard hdr.starts(with: Array("AcFssFcAJMB".utf8)) else { throw DWGReadError.corrupt("file header signature not found") }
        var check = hdr
        for i in 0x68..<0x6C { check[i] = 0 }
        if DWGReadCRC.crc32(check, 0..<0x6C) != dwgReadLE32(hdr, 0x68) { f.checksumErrors += 1 }

        let pageMapAddr = Int(truncatingIfNeeded: dwgReadLE64(hdr, 0x54)) + 0x100
        let sectionMapId = Int(dwgReadLE32(hdr, 0x5C))
        let pageMap = try systemPage(d, at: pageMapAddr, type: 0x4163_0E3B, errors: &f.checksumErrors)

        // Section page map: page number -> file address.
        var pages: [Int: (addr: Int, size: Int)] = [:]
        var addr = 0x100, k = 0
        while k + 8 <= pageMap.count {
            let num = Int(Int32(bitPattern: dwgReadLE32(pageMap, k)))
            let size = Int(dwgReadLE32(pageMap, k + 4))
            k += 8
            if num < 0 { k += 16 } else { pages[num] = (addr, size) }
            addr += size
            if size < 0 || addr > d.count + 0x10000_0000 { break }
        }
        guard let sm = pages[sectionMapId] else { throw DWGReadError.corrupt("section map page missing") }
        let sectionMap = try systemPage(d, at: sm.addr, type: 0x4163_003B, errors: &f.checksumErrors)

        // Data section map.
        guard sectionMap.count >= 20 else { throw DWGReadError.corrupt("section map is truncated") }
        let count = Int(dwgReadLE32(sectionMap, 0))
        var sections: [String: SectionInfo] = [:]
        var p = 20
        for _ in 0..<min(count, 1000) {
            guard p + 96 <= sectionMap.count else { break }
            let size = Int(truncatingIfNeeded: dwgReadLE64(sectionMap, p))
            let pageCount = Int(dwgReadLE32(sectionMap, p + 8))
            let maxSize = Int(dwgReadLE32(sectionMap, p + 12))
            let compressed = dwgReadLE32(sectionMap, p + 20) == 2
            let encrypted = Int(dwgReadLE32(sectionMap, p + 28))
            let nameBytes = sectionMap[(p + 32)..<(p + 96)].prefix { $0 != 0 }
            let name = String(decoding: nameBytes, as: UTF8.self)
            p += 96
            var list: [(Int, Int, Int)] = []
            for _ in 0..<max(0, min(pageCount, 1_000_000)) {
                guard p + 16 <= sectionMap.count else { break }
                list.append((Int(dwgReadLE32(sectionMap, p)), Int(dwgReadLE32(sectionMap, p + 4)), Int(truncatingIfNeeded: dwgReadLE64(sectionMap, p + 8))))
                p += 16
            }
            sections[name] = SectionInfo(name: name, size: size, maxPageSize: maxSize, compressed: compressed,
                                         encrypted: encrypted, pages: list)
        }

        func load(_ name: String, required: Bool = true) throws -> [UInt8] {
            guard let s = sections[name] else {
                if required { throw DWGReadError.corrupt("section \(name) is missing") }
                return []
            }
            if s.encrypted == 1 { throw DWGReadError.encrypted }
            return try readSection(d, s, pages: pages, errors: &f.checksumErrors)
        }
        f.header = try load("AcDb:Header")
        f.classes = try load("AcDb:Classes")
        f.handles = try load("AcDb:Handles")
        f.objects = try load("AcDb:AcDbObjects")
        guard f.header.starts(with: headerSentinel) else { throw DWGReadError.corrupt("header sentinel not found") }
        guard f.classes.starts(with: classesSentinel) else { throw DWGReadError.corrupt("classes sentinel not found") }
        return f
    }

    /// Reads and decompresses a system section page (page map or section map).
    static func systemPage(_ d: [UInt8], at a: Int, type: UInt32, errors: inout Int) throws -> [UInt8] {
        guard a >= 0, a + 20 <= d.count, dwgReadLE32(d, a) == type else { throw DWGReadError.corrupt("system section page not found") }
        let dsize = Int(dwgReadLE32(d, a + 4)), csize = Int(dwgReadLE32(d, a + 8))
        guard csize >= 0, a + 20 + csize <= d.count, dsize >= 0, dsize <= max(1 << 20, csize * 1100) else {
            throw DWGReadError.corrupt("system section page is truncated")
        }
        var head = Array(d[a..<(a + 20)])
        for i in 16..<20 { head[i] = 0 }
        let seed = DWGReadCRC.pageChecksum(head, 0..<20, seed: 0)
        if DWGReadCRC.pageChecksum(d, (a + 20)..<(a + 20 + csize), seed: seed) != dwgReadLE32(d, a + 16) { errors += 1 }
        return try DWGReadLZ77.decompress(d, (a + 20)..<(a + 20 + csize), size: dsize)
    }

    /// Concatenates the pages of a data section (spec 4.5 / 4.6).
    static func readSection(_ d: [UInt8], _ s: SectionInfo, pages: [Int: (addr: Int, size: Int)], errors: inout Int) throws -> [UInt8] {
        guard s.size >= 0, s.size <= sizeLimit(d.count) else { throw DWGReadError.corrupt("section \(s.name) has an invalid size") }
        var out = [UInt8](repeating: 0, count: s.size)
        guard s.maxPageSize > 0, s.maxPageSize <= 0x10_0000 else { throw DWGReadError.corrupt("section \(s.name) has an invalid page size") }
        let pageSize = s.maxPageSize
        for pg in s.pages {
            guard let loc = pages[pg.number] else { throw DWGReadError.corrupt("page \(pg.number) of \(s.name) is missing") }
            let a = loc.addr
            guard a >= 0, a + 32 <= d.count else { throw DWGReadError.corrupt("page of \(s.name) lies outside the file") }
            // Unmask the 32-byte page header.
            let mask = 0x4164_536B ^ UInt32(truncatingIfNeeded: a)
            var head = [UInt8](repeating: 0, count: 32)
            for j in 0..<8 {
                let w = dwgReadLE32(d, a + j * 4) ^ mask
                head[j * 4] = UInt8(w & 0xFF); head[j * 4 + 1] = UInt8((w >> 8) & 0xFF)
                head[j * 4 + 2] = UInt8((w >> 16) & 0xFF); head[j * 4 + 3] = UInt8(w >> 24)
            }
            guard dwgReadLE32(head, 0) == 0x4163_043B else { throw DWGReadError.corrupt("bad data page header in \(s.name)") }
            let dataSize = Int(dwgReadLE32(head, 8))
            let start = Int(truncatingIfNeeded: dwgReadLE64(head, 16))
            guard dataSize >= 0, a + 32 + dataSize <= d.count else { throw DWGReadError.corrupt("data page of \(s.name) is truncated") }
            let dataRange = (a + 32)..<(a + 32 + dataSize)
            let dataSum = DWGReadCRC.pageChecksum(d, dataRange, seed: 0)
            if dataSum != dwgReadLE32(head, 0x1C) { errors += 1 }
            guard start >= 0, start < s.size else { continue }
            let n = min(pageSize, s.size - start)
            if s.compressed {
                let page = try DWGReadLZ77.decompress(d, dataRange, size: pageSize)
                let m = min(n, page.count)
                if m > 0 { out.replaceSubrange(start..<(start + m), with: page[0..<m]) }
            } else {
                let m = min(n, dataSize)
                if m > 0 { out.replaceSubrange(start..<(start + m), with: d[dataRange.lowerBound..<(dataRange.lowerBound + m)]) }
            }
        }
        return out
    }
}

/// R2004 LZ77 variant (spec 4.7).
enum DWGReadLZ77 {
    static func decompress(_ src: [UInt8], _ range: Range<Int>, size: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(max(0, size))
        var i = range.lowerBound
        let end = min(range.upperBound, src.count)
        func fail() -> DWGReadError { .corrupt("compressed data is damaged") }

        func byte() throws -> Int {
            guard i < end else { throw fail() }
            let b = Int(src[i]); i += 1
            return b
        }
        func literalLength() throws -> Int {
            guard i < end else { return 0 }
            let b = Int(src[i])
            if b == 0 {
                i += 1
                var total = 0x0F
                var c = try byte()
                while c == 0 { total += 0xFF; c = try byte() }
                return total + c + 3
            }
            if b & 0xF0 != 0 { return 0 }
            i += 1
            return b + 3
        }
        func longCompressionOffset() throws -> Int {
            var b = try byte()
            if b != 0 { return b }
            var total = 0xFF
            b = try byte()
            while b == 0 { total += 0xFF; b = try byte() }
            return total + b
        }
        func twoByteOffset() throws -> (Int, Int) {
            let a = try byte(), b = try byte()
            return ((a >> 2) | (b << 6), a & 3)
        }
        func copyLiteral(_ n: Int) throws {
            guard n >= 0, i + n <= end else { throw fail() }
            out.append(contentsOf: src[i..<(i + n)])
            i += n
        }

        try copyLiteral(literalLength())
        while i < end {
            let op = try byte()
            if op == 0x11 { break }
            var count = 0, offset = 0, lit = 0
            switch op {
            case 0x10, 0x12...0x1F:
                // The spec gives (op & 0x0F) + 2, but bit 3 actually extends the offset by
                // 0x4000 (as in LZO); only the low 3 bits are the length (0 = long length).
                count = (op & 7) + 2
                if count == 2 { count = try longCompressionOffset() + 9 }
                (offset, lit) = try twoByteOffset()
                offset += 0x3FFF + ((op & 8) << 11)
            case 0x20:
                count = try longCompressionOffset() + 0x21
                (offset, lit) = try twoByteOffset()
            case 0x21...0x3F:
                count = op - 0x1E
                (offset, lit) = try twoByteOffset()
            case 0x40...0xFF:
                count = ((op & 0xF0) >> 4) - 1
                let op2 = try byte()
                offset = (op2 << 2) | ((op & 0x0C) >> 2)
                lit = op & 3
            default:
                throw fail()
            }
            if lit == 0 { lit = try literalLength() }
            let from = out.count - offset - 1
            guard from >= 0, count >= 0, out.count + count <= max(size, 0) + 0x10000 else { throw fail() }
            // Overlapping copies are allowed (count may exceed offset).
            for k in 0..<count { out.append(out[from + k]) }
            try copyLiteral(lit)
            if out.count > size + 0x10000 { throw fail() }
        }
        if out.count < size { out.append(contentsOf: repeatElement(0, count: size - out.count)) }
        return out
    }
}
