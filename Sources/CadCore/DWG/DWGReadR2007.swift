import Foundation

/// AutoCAD 2007 (AC1021) container (spec chapter 5): Reed-Solomon protected pages and
/// a different LZ77 variant. Error correction is not attempted: the data bytes of each
/// RS code word are taken as stored, which is exact for undamaged files.
enum DWGReadR2007 {
    static func open(_ d: [UInt8]) throws -> DWGReadFile {
        guard d.count >= 0x480 else { throw DWGReadError.corrupt("file header is truncated") }
        var f = DWGReadFile(version: .r2007, maintenance: Int(d[0x0B]), codePage: Int(dwgReadLE16(d, 0x13)))
        if dwgReadLE32(d, 0x18) & 1 != 0 { throw DWGReadError.encrypted }

        // File header: 3 interleaved RS(255,239) blocks at 0x80.
        let hdr = deinterleave(Array(d[0x80..<(0x80 + 3 * 255)]), blocks: 3, k: 239)
        let comprLen = Int(Int32(bitPattern: dwgReadLE32(hdr, 24)))
        let fh: [UInt8]
        if comprLen > 0 {
            guard 32 + comprLen <= hdr.count else { throw DWGReadError.corrupt("file header is damaged") }
            fh = try decompress(Array(hdr[32..<(32 + comprLen)]), size: 0x110)
        } else {
            let n = -comprLen
            guard n > 0, 32 + n <= hdr.count else { throw DWGReadError.corrupt("file header is damaged") }
            fh = Array(hdr[32..<(32 + n)])
        }
        guard fh.count >= 0x110 else { throw DWGReadError.corrupt("file header is truncated") }
        func q(_ i: Int) -> Int { Int(truncatingIfNeeded: dwgReadLE64(fh, i)) }
        guard q(0) == 0x70 else { throw DWGReadError.corrupt("file header signature not found") }

        // Page map.
        let pageMap = try systemPage(d, offset: q(0x38), compressed: q(0x50), size: q(0x58), factor: q(0x18))
        var pages: [Int: (offset: Int, size: Int)] = [:]
        var off = 0, k = 0
        while k + 16 <= pageMap.count {
            let size = Int(truncatingIfNeeded: dwgReadLE64(pageMap, k))
            let id = Int(truncatingIfNeeded: dwgReadLE64(pageMap, k + 8))
            k += 16
            guard size >= 0, size < 0x4000_0000 else { break }
            pages[abs(id)] = (off, size)
            off += size
        }
        guard let sm = pages[q(0xC0)] else { throw DWGReadError.corrupt("section map page missing") }
        let sectionMap = try systemPage(d, offset: sm.offset, compressed: q(0xB0), size: q(0xC8), factor: q(0xD8))

        // Section map.
        struct Section { var size: Int; var encoding: Int; var encrypted: Int; var pages: [[Int]] }
        var sections: [String: Section] = [:]
        k = 0
        while k + 64 <= sectionMap.count {
            func v(_ i: Int) -> Int { Int(truncatingIfNeeded: dwgReadLE64(sectionMap, k + i * 8)) }
            let size = v(0), encrypted = v(2), nameLen = v(4), encoding = v(6), n = v(7)
            k += 64
            guard nameLen >= 0, nameLen < 1024, k + nameLen <= sectionMap.count, n >= 0, n < 1_000_000 else { break }
            var units: [UInt16] = []
            var j = k
            while j + 1 < k + nameLen { units.append(dwgReadLE16(sectionMap, j)); j += 2 }
            let name = String(decoding: units.prefix { $0 != 0 }, as: UTF16.self)
            k += nameLen
            var list: [[Int]] = []
            for _ in 0..<n {
                guard k + 56 <= sectionMap.count else { break }
                list.append((0..<7).map { Int(truncatingIfNeeded: dwgReadLE64(sectionMap, k + $0 * 8)) })
                k += 56
            }
            sections[name] = Section(size: size, encoding: encoding, encrypted: encrypted, pages: list)
        }

        func load(_ name: String) throws -> [UInt8] {
            guard let s = sections[name] else { throw DWGReadError.corrupt("section \(name) is missing") }
            if s.encrypted == 1 { throw DWGReadError.encrypted }
            guard s.size >= 0, s.size <= DWGReadContainer.sizeLimit(d.count) else { throw DWGReadError.corrupt("section \(name) has an invalid size") }
            var out = [UInt8](repeating: 0, count: s.size)
            for p in s.pages {
                let dataOffset = p[0], id = p[2], usize = p[3], csize = p[4]
                guard let loc = pages[id], csize >= 0, usize >= 0, usize <= 0x10_0000 else {
                    throw DWGReadError.corrupt("page of \(name) is missing")
                }
                let padded = (csize + 7) & ~7
                let blocks = (padded + 250) / 251
                let start = 0x480 + loc.offset
                guard start >= 0, start + blocks * 255 <= d.count else { throw DWGReadError.corrupt("page of \(name) lies outside the file") }
                let raw = Array(d[start..<(start + blocks * 255)])
                var data = s.encoding == 4 ? deinterleave(raw, blocks: blocks, k: 251) : plain(raw, blocks: blocks, k: 251)
                if data.count > csize { data.removeSubrange(csize...) }
                if csize < usize { data = try decompress(data, size: usize) }
                guard dataOffset >= 0, dataOffset < s.size else { continue }
                let m = min(data.count, s.size - dataOffset)
                if m > 0 { out.replaceSubrange(dataOffset..<(dataOffset + m), with: data[0..<m]) }
            }
            return out
        }
        f.header = try load("AcDb:Header")
        f.classes = try load("AcDb:Classes")
        f.handles = try load("AcDb:Handles")
        f.objects = try load("AcDb:AcDbObjects")
        guard f.header.starts(with: DWGReadContainer.headerSentinel) else { throw DWGReadError.corrupt("header sentinel not found") }
        guard f.classes.starts(with: DWGReadContainer.classesSentinel) else { throw DWGReadError.corrupt("classes sentinel not found") }
        return f
    }

    /// System page (spec 5.3): data repeated `factor` times, RS(255,239) interleaved.
    static func systemPage(_ d: [UInt8], offset: Int, compressed: Int, size: Int, factor: Int) throws -> [UInt8] {
        guard compressed > 0, size > 0, size <= max(1 << 20, compressed * 1100), factor > 0, factor < 0x10000, offset >= 0 else {
            throw DWGReadError.corrupt("system page has invalid parameters")
        }
        let aligned = (compressed + 7) & ~7
        let blocks = (aligned * factor + 238) / 239
        let start = 0x480 + offset
        guard start + blocks * 255 <= d.count else { throw DWGReadError.corrupt("system page lies outside the file") }
        var data = deinterleave(Array(d[start..<(start + blocks * 255)]), blocks: blocks, k: 239)
        if data.count > compressed { data.removeSubrange(compressed...) }
        return compressed < size ? try decompress(data, size: size) : data
    }

    /// Data bytes of `blocks` interleaved RS code words.
    static func deinterleave(_ raw: [UInt8], blocks: Int, k: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: blocks * k)
        for b in 0..<blocks {
            for j in 0..<k {
                let src = j * blocks + b
                if src < raw.count { out[b * k + j] = raw[src] }
            }
        }
        return out
    }

    /// Data bytes of `blocks` consecutive RS code words.
    static func plain(_ raw: [UInt8], blocks: Int, k: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(blocks * k)
        for b in 0..<blocks {
            let s = b * 255
            guard s < raw.count else { break }
            out.append(contentsOf: raw[s..<min(raw.count, s + k)])
        }
        return out
    }

    // MARK: Decompression (spec 5.10)

    /// Byte order of literal runs of 1...32 bytes (spec 5.10.1). Sub-blocks are themselves
    /// copied with the function of their size.
    static let literalOrder: [[Int]] = {
        let table: [Int: [(Int, Int)]] = [
            1: [], 2: [(1, 1), (1, 0)], 3: [(1, 2), (1, 1), (1, 0)], 4: [(1, 0), (1, 1), (1, 2), (1, 3)],
            5: [(1, 4), (4, 0)], 6: [(1, 5), (4, 1), (1, 0)], 7: [(2, 5), (4, 1), (1, 0)], 8: [(4, 0), (4, 4)],
            9: [(1, 8), (8, 0)], 10: [(1, 9), (8, 1), (1, 0)], 11: [(2, 9), (8, 1), (1, 0)], 12: [(4, 8), (8, 0)],
            13: [(1, 12), (4, 8), (8, 0)], 14: [(1, 13), (4, 9), (8, 1), (1, 0)], 15: [(2, 13), (4, 9), (8, 1), (1, 0)],
            16: [(8, 8), (8, 0)], 17: [(8, 9), (1, 8), (8, 0)], 18: [(1, 17), (16, 1), (1, 0)], 19: [(3, 16), (16, 0)],
            20: [(4, 16), (16, 0)], 21: [(1, 20), (4, 16), (16, 0)], 22: [(2, 20), (4, 16), (16, 0)],
            23: [(3, 20), (4, 16), (16, 0)], 24: [(8, 16), (16, 0)], 25: [(8, 17), (1, 16), (16, 0)],
            26: [(1, 25), (8, 17), (1, 16), (16, 0)], 27: [(2, 25), (8, 17), (1, 16), (16, 0)],
            28: [(4, 24), (8, 16), (16, 0)], 29: [(1, 28), (4, 24), (8, 16), (16, 0)],
            30: [(2, 28), (4, 24), (8, 16), (16, 0)], 31: [(1, 30), (4, 26), (8, 18), (16, 2), (2, 0)],
            32: [(16, 16), (16, 0)],
        ]
        func order(_ n: Int) -> [Int] {
            if n == 1 { return [0] }
            return table[n]!.flatMap { c, o in order(c).map { $0 + o } }
        }
        return [[]] + (1...32).map(order)
    }()

    static func decompress(_ src: [UInt8], size: Int) throws -> [UInt8] {
        func fail() -> DWGReadError { .corrupt("compressed data is damaged") }
        var out = [UInt8]()
        out.reserveCapacity(size)
        let end = src.count
        guard end > 0 else { return [UInt8](repeating: 0, count: size) }
        var i = 0
        func byte() throws -> Int {
            guard i < end else { throw fail() }
            let b = Int(src[i]); i += 1
            return b
        }
        var op = try byte()
        var length = 0
        if op & 0xF0 == 0x20 {
            i += 2
            length = try byte() & 7
        }
        func copyLiteral(_ n: Int) throws {
            guard n >= 0, i + n <= end else { throw fail() }
            var left = n
            while left > 0 {
                let c = min(left, 32)
                let order = literalOrder[c]
                if c == 32 {
                    for k in order { out.append(src[i + k]) }
                } else {
                    for k in order { out.append(src[i + k]) }
                }
                i += c
                left -= c
            }
        }
        func instructions() throws -> (offset: Int, length: Int) {
            var offset = 0, len = 0
            switch op >> 4 {
            case 0:
                len = (op & 0x0F) + 0x13
                offset = try byte()
                op = try byte()
                len += (op >> 3) & 0x10
                offset = ((op & 0x78) << 5) + 1 + offset
            case 1:
                len = (op & 0x0F) + 3
                offset = try byte()
                op = try byte()
                offset = ((op & 0xF8) << 5) + 1 + offset
            case 2:
                offset = try byte()
                offset |= try byte() << 8
                len = op & 7
                if op & 8 == 0 {
                    op = try byte()
                    len += op & 0xF8
                } else {
                    offset += 1
                    len += try byte() << 3
                    op = try byte()
                    len += ((op & 0xF8) << 8) + 0x100
                }
            default:
                len = op >> 4
                offset = op & 0x0F
                op = try byte()
                offset = ((op & 0xF8) << 1) + offset + 1
            }
            return (offset, len)
        }
        while i < end {
            if length == 0 {
                length = op + 8
                if length == 0x17 {
                    var n = try byte()
                    length += n
                    if n == 0xFF {
                        repeat {
                            n = try byte()
                            n |= try byte() << 8
                            length += n
                        } while n == 0xFFFF
                    }
                }
            }
            try copyLiteral(length)
            if i >= end { break }
            op = try byte()
            var (offset, len) = try instructions()
            while true {
                let from = out.count - offset
                guard from >= 0, offset > 0, out.count + len <= size + 0x10000 else { throw fail() }
                for k in 0..<len { out.append(out[from + k]) }
                length = op & 7
                if length != 0 || i >= end { break }
                op = try byte()
                if op >> 4 == 0 { break }
                if op >> 4 == 15 { op &= 15 }
                (offset, len) = try instructions()
            }
        }
        if out.count < size { out.append(contentsOf: repeatElement(0, count: size - out.count)) }
        if out.count > size { out.removeSubrange(size...) }
        return out
    }
}
