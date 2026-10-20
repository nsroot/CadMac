import Foundation

/// Bit-level reader for DWG data (Open Design Specification for .dwg files, chapter 2).
///
/// Bits are read MSB first. Reading past `end` never traps: it yields zeros and sets
/// `overflow`, which callers check after decoding an object.
struct DWGBitReader {
    let data: [UInt8]
    /// Current position in bits.
    var pos: Int
    /// Limit in bits (exclusive).
    var end: Int
    var overflow = false

    init(_ data: [UInt8], bit: Int = 0, end: Int? = nil) {
        self.data = data
        self.pos = max(0, bit)
        self.end = min(end ?? data.count * 8, data.count * 8)
    }

    var bitsLeft: Int { end - pos }
    var byteOffset: Int { pos >> 3 }

    // MARK: Raw bits

    @inline(__always) mutating func bit() -> Bool {
        guard pos < end else { overflow = true; return false }
        let b = data[pos >> 3] & (0x80 >> UInt8(pos & 7))
        pos += 1
        return b != 0
    }

    @inline(__always) mutating func bits(_ n: Int) -> Int {
        var v = 0
        for _ in 0..<n { v = (v << 1) | (bit() ? 1 : 0) }
        return v
    }

    /// RC: one raw byte (not necessarily byte aligned).
    @inline(__always) mutating func rc() -> UInt8 {
        guard pos + 8 <= end else { overflow = true; pos = end; return 0 }
        let i = pos >> 3, s = pos & 7
        pos += 8
        if s == 0 { return data[i] }
        return UInt8(truncatingIfNeeded: (Int(data[i]) << s) | (Int(data[i + 1]) >> (8 - s)))
    }

    mutating func rawBytes(_ n: Int) -> [UInt8] {
        guard n > 0 else { return [] }
        guard pos + n * 8 <= end else { overflow = true; pos = end; return [] }
        if pos & 7 == 0 {
            let i = pos >> 3
            pos += n * 8
            return Array(data[i..<(i + n)])
        }
        var out = [UInt8](repeating: 0, count: n)
        for k in 0..<n { out[k] = rc() }
        return out
    }

    mutating func skipBytes(_ n: Int) {
        guard n > 0 else { return }
        if pos + n * 8 > end { overflow = true; pos = end } else { pos += n * 8 }
    }

    /// RS: raw little-endian short.
    mutating func rs() -> Int16 {
        let a = UInt16(rc()), b = UInt16(rc())
        return Int16(bitPattern: a | b << 8)
    }

    /// RL: raw little-endian long.
    mutating func rl() -> Int32 {
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(rc()) << (8 * UInt32(k)) }
        return Int32(bitPattern: v)
    }

    /// RD: raw little-endian double.
    mutating func rd() -> Double {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(rc()) << (8 * UInt64(k)) }
        return Double(bitPattern: v)
    }

    // MARK: Compressed forms

    /// BB: two-bit code.
    @inline(__always) mutating func bb() -> Int { bits(2) }

    /// 3B: one to three bits, stopping at the first zero bit.
    mutating func b3() -> Int {
        var v = 0
        for _ in 0..<3 {
            let b = bit()
            v = (v << 1) | (b ? 1 : 0)
            if !b { break }
        }
        return v
    }

    /// BS: bitshort.
    mutating func bs() -> Int {
        switch bb() {
        case 0: return Int(rs())
        case 1: return Int(rc())
        case 2: return 0
        default: return 256
        }
    }

    /// BL: bitlong.
    mutating func bl() -> Int {
        switch bb() {
        case 0: return Int(rl())
        case 1: return Int(rc())
        default: return 0
        }
    }

    /// BLL: bitlonglong (3-bit byte count, then that many little-endian bytes).
    mutating func bll() -> UInt64 {
        let n = bits(3)
        var v: UInt64 = 0
        for k in 0..<n { v |= UInt64(rc()) << (8 * UInt64(k)) }
        return v
    }

    /// BD: bitdouble.
    mutating func bd() -> Double {
        switch bb() {
        case 0: return rd()
        case 1: return 1
        default: return 0
        }
    }

    /// DD: bitdouble with default.
    mutating func dd(_ def: Double) -> Double {
        switch bb() {
        case 0: return def
        case 1:
            var v = def.bitPattern
            v &= ~UInt64(0xFFFF_FFFF)
            for k in 0..<4 { v |= UInt64(rc()) << (8 * UInt64(k)) }
            return Double(bitPattern: v)
        case 2:
            var v = def.bitPattern
            let b5 = UInt64(rc()), b6 = UInt64(rc())
            v &= ~UInt64(0x0000_FFFF_FFFF_FFFF)
            v |= b5 << 32 | b6 << 40
            for k in 0..<4 { v |= UInt64(rc()) << (8 * UInt64(k)) }
            return Double(bitPattern: v)
        default:
            return rd()
        }
    }

    /// 2RD / 2BD / 3BD helpers.
    mutating func rd2() -> (Double, Double) { let x = rd(); return (x, rd()) }
    mutating func bd2() -> (Double, Double) { let x = bd(); return (x, bd()) }
    mutating func bd3() -> (Double, Double, Double) { let x = bd(), y = bd(); return (x, y, bd()) }

    /// BT: thickness (R2000+: bit flag then optional BD).
    mutating func bt(r2000: Bool) -> Double {
        if !r2000 { return bd() }
        return bit() ? 0 : bd()
    }

    /// BE: extrusion (R2000+: bit flag then optional 3BD).
    mutating func be(r2000: Bool) -> (Double, Double, Double) {
        if !r2000 { return bd3() }
        return bit() ? (0, 0, 1) : bd3()
    }

    /// OT: object type (R2010+ encoding).
    mutating func ot2010() -> Int {
        switch bb() {
        case 0: return Int(rc())
        case 1: return Int(rc()) + 0x1F0
        default:
            let a = Int(rc()), b = Int(rc())
            return a | b << 8
        }
    }

    // MARK: Handles

    /// H: handle reference; returns the code and raw value.
    mutating func handleRef() -> (code: Int, value: UInt64) {
        let code = bits(4)
        let n = bits(4)
        var v: UInt64 = 0
        for _ in 0..<n { v = (v << 8) | UInt64(rc()) }
        return (code, v)
    }

    /// H resolved against the referencing object's handle (offset codes 6, 8, A, C).
    mutating func handle(relativeTo ref: UInt64) -> UInt64 {
        let (code, v) = handleRef()
        switch code {
        case 6: return ref &+ 1
        case 8: return ref &- 1
        case 0xA: return ref &+ v
        case 0xC: return ref &- v
        default: return v
        }
    }

    // MARK: Text

    /// T / TV for R2004 and earlier: BS length then 8-bit characters in the drawing code page.
    mutating func text8(_ encoding: String.Encoding) -> String {
        let n = bs()
        guard n > 0 else { return "" }
        guard n * 8 <= bitsLeft else { overflow = true; pos = end; return "" }
        var bytes = rawBytes(n)
        if let z = bytes.firstIndex(of: 0) { bytes.removeSubrange(z...) }
        return dwgReadDecode8(bytes, encoding)
    }

    /// TU: BS length then UTF-16LE characters.
    mutating func textU() -> String {
        let n = bs()
        guard n > 0 else { return "" }
        guard n * 16 <= bitsLeft else { overflow = true; pos = end; return "" }
        var units = [UInt16]()
        units.reserveCapacity(n)
        for _ in 0..<n {
            let a = UInt16(rc()), b = UInt16(rc())
            units.append(a | b << 8)
        }
        if let z = units.firstIndex(of: 0) { units.removeSubrange(z...) }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: Colors

    /// CMC for R2004+ (table records): BS index, BL RGB, RC flags (+ names).
    mutating func cmc2004(strings: (inout DWGBitReader) -> String) -> DWGReadColor {
        let index = bs()
        let rgb = UInt32(truncatingIfNeeded: bl())
        let flags = rc()
        if flags & 1 != 0 { _ = strings(&self) }
        if flags & 2 != 0 { _ = strings(&self) }
        return DWGReadColor(fromCMC: rgb, index: index)
    }

    /// ENC (entity color, R2004+). Returns the color and whether a DBCOLOR handle follows.
    mutating func enc() -> (color: DWGReadColor, hasBook: Bool) {
        let v = bs()
        let flags = v & 0xFF00
        var color = DWGReadColor.index(v & 0x1FF)
        if flags & 0x8000 != 0 {
            let rgb = UInt32(truncatingIfNeeded: bl())
            color = DWGReadColor(fromCMC: rgb, index: v & 0xFF)
        }
        if flags & 0x2000 != 0 { _ = bl() }
        return (color, flags & 0x4000 != 0)
    }
}

/// Entity / layer color as stored in DWG.
enum DWGReadColor: Equatable {
    case byLayer, byBlock
    case aci(Int)
    case rgb(Int)

    static func index(_ i: Int) -> DWGReadColor {
        switch i {
        case 0: return .byBlock
        case 256: return .byLayer
        case 1...255: return .aci(i)
        default: return .byLayer
        }
    }

    /// From a CmColor RGB long: high byte 0xC0 ByLayer, 0xC1 ByBlock, 0xC2 true color, 0xC3 ACI.
    init(fromCMC rgb: UInt32, index: Int) {
        switch rgb >> 24 {
        case 0xC0: self = .byLayer
        case 0xC1: self = .byBlock
        case 0xC2: self = .rgb(Int(rgb & 0xFF_FFFF))
        case 0xC3: self = DWGReadColor.index(Int(rgb & 0xFF))
        case 0xC8: self = .byLayer
        default: self = DWGReadColor.index(index)
        }
    }
}

// MARK: - Byte-level helpers

/// Modular char (MC) at byte offset `i`; returns value and next offset. `signed` honours the
/// 0x40 negation flag of the final byte.
func dwgReadModularChar(_ d: [UInt8], _ i: inout Int, signed: Bool) -> Int? {
    var v = 0, shift = 0
    while i < d.count {
        let b = Int(d[i])
        i += 1
        if b & 0x80 != 0 {
            v |= (b & 0x7F) << shift
            shift += 7
            if shift > 56 { return nil }
        } else {
            if signed {
                v |= (b & 0x3F) << shift
                return b & 0x40 != 0 ? -v : v
            }
            v |= (b & 0x7F) << shift
            return v
        }
    }
    return nil
}

/// Modular short (MS) at byte offset `i`.
func dwgReadModularShort(_ d: [UInt8], _ i: inout Int) -> Int? {
    var v = 0, shift = 0
    while i + 1 < d.count {
        let w = Int(d[i]) | Int(d[i + 1]) << 8
        i += 2
        v |= (w & 0x7FFF) << shift
        if w & 0x8000 == 0 { return v }
        shift += 15
        if shift > 45 { return nil }
    }
    return nil
}

@inline(__always) func dwgReadLE32(_ d: [UInt8], _ i: Int) -> UInt32 {
    guard i >= 0, i + 4 <= d.count else { return 0 }
    return UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
}

@inline(__always) func dwgReadLE64(_ d: [UInt8], _ i: Int) -> UInt64 {
    UInt64(dwgReadLE32(d, i)) | UInt64(dwgReadLE32(d, i + 4)) << 32
}

@inline(__always) func dwgReadLE16(_ d: [UInt8], _ i: Int) -> UInt16 {
    guard i >= 0, i + 2 <= d.count else { return 0 }
    return UInt16(d[i]) | UInt16(d[i + 1]) << 8
}

/// Decodes 8-bit text, honouring AutoCAD's \U+XXXX escapes (left for the DXF layer) and
/// falling back to Latin-1 when the code page cannot decode the bytes.
func dwgReadDecode8(_ bytes: [UInt8], _ enc: String.Encoding) -> String {
    if bytes.allSatisfy({ $0 < 0x80 }) { return String(decoding: bytes, as: UTF8.self) }
    return String(data: Data(bytes), encoding: enc) ?? String(data: Data(bytes), encoding: .isoLatin1) ?? ""
}

/// String encoding for a DWG code page number (header offset 0x13 / $DWGCODEPAGE).
func dwgReadEncoding(forCodePage cp: Int) -> String.Encoding {
    func cf(_ e: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
    }
    switch cp {
    case 1, 2: return .isoLatin1
    case 3: return .isoLatin2
    case 11: return cf(.dosLatinUS)
    case 12: return cf(.dosLatin1)
    case 13: return cf(.dosLatin2)
    case 22, 38: return .shiftJIS
    case 23: return .macOSRoman
    case 24, 41: return cf(.big5)
    case 25, 40: return cf(.dosKorean)
    case 27: return cf(.dosRussian)
    case 28: return .windowsCP1250
    case 29: return .windowsCP1251
    case 31, 39: return cf(.GB_18030_2000)
    case 32: return .windowsCP1253
    case 33: return .windowsCP1254
    case 34: return cf(.windowsHebrew)
    case 35: return cf(.windowsArabic)
    case 36: return cf(.windowsBalticRim)
    case 37: return cf(.dosThai)
    case 44: return cf(.windowsVietnamese)
    default: return .windowsCP1252
    }
}

// MARK: - CRCs and checksums

enum DWGReadCRC {
    /// 16-bit CRC table (spec 2.14.1).
    static let table16: [UInt16] = {
        (0..<256).map { i -> UInt16 in
            var c = UInt16(i)
            for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0xA001 : c >> 1 }
            return c
        }
    }()

    /// The "8-bit" CRC of the spec (16-bit result), starting from `seed`.
    static func crc16(_ d: [UInt8], _ range: Range<Int>, seed: UInt16) -> UInt16 {
        var dx = seed
        let lo = max(0, range.lowerBound), hi = min(d.count, range.upperBound)
        guard lo < hi else { return dx }
        for i in lo..<hi {
            let al = d[i] ^ UInt8(dx & 0xFF)
            dx = (dx >> 8) ^ table16[Int(al)]
        }
        return dx
    }

    static let table32: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
            return c
        }
    }()

    /// 32-bit CRC (spec 2.14.2).
    static func crc32(_ d: [UInt8], _ range: Range<Int>, seed: UInt32 = 0) -> UInt32 {
        var c = ~seed
        let lo = max(0, range.lowerBound), hi = min(d.count, range.upperBound)
        guard lo < hi else { return ~c }
        for i in lo..<hi { c = (c >> 8) ^ table32[Int((c ^ UInt32(d[i])) & 0xFF)] }
        return ~c
    }

    /// Section page checksum (spec 4.2).
    static func pageChecksum(_ d: [UInt8], _ range: Range<Int>, seed: UInt32) -> UInt32 {
        var sum1 = seed & 0xFFFF, sum2 = seed >> 16
        var i = max(0, range.lowerBound)
        let hi = min(d.count, range.upperBound)
        while i < hi {
            let n = min(0x15B0, hi - i)
            for k in i..<(i + n) {
                sum1 &+= UInt32(d[k])
                sum2 &+= sum1
            }
            sum1 %= 0xFFF1
            sum2 %= 0xFFF1
            i += n
        }
        return sum2 << 16 | (sum1 & 0xFFFF)
    }
}
