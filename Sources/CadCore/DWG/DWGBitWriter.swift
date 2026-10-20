import Foundation

/// Bit-level writer for the R13-R2000 DWG encodings (Open Design Specification for .dwg files,
/// chapter 2 "Bit codes and data definitions"). Bits are written most significant first.
struct DWGBitWriter {
    private(set) var bytes: [UInt8] = []
    /// Number of bits written.
    private(set) var bitCount = 0

    init() {}

    // MARK: Raw bits

    mutating func bit(_ b: Bool) {
        let byte = bitCount >> 3
        if byte == bytes.count { bytes.append(0) }
        if b { bytes[byte] |= UInt8(0x80 >> (bitCount & 7)) }
        bitCount += 1
    }

    /// Writes the low `n` bits of `v`, most significant first.
    mutating func bits(_ v: UInt64, _ n: Int) {
        var i = n - 1
        while i >= 0 {
            bit((v >> UInt64(i)) & 1 == 1)
            i -= 1
        }
    }

    mutating func rc(_ v: UInt8) {
        if bitCount & 7 == 0 {
            bytes.append(v)
            bitCount += 8
        } else {
            bits(UInt64(v), 8)
        }
    }

    mutating func rawBytes(_ b: [UInt8]) { for x in b { rc(x) } }

    mutating func rs(_ v: UInt16) { rc(UInt8(v & 0xFF)); rc(UInt8(v >> 8)) }
    mutating func rs(_ v: Int) { rs(UInt16(truncatingIfNeeded: v)) }
    mutating func rl(_ v: UInt32) { rs(UInt16(v & 0xFFFF)); rs(UInt16(v >> 16)) }
    mutating func rl(_ v: Int) { rl(UInt32(truncatingIfNeeded: v)) }

    mutating func rd(_ v: Double) {
        var x = v.isFinite ? v : 0
        if x == 0 { x = 0 } // no negative zero
        let b = x.bitPattern
        for i in 0..<8 { rc(UInt8((b >> UInt64(i * 8)) & 0xFF)) }
    }

    mutating func rd2(_ p: Vec2) { rd(p.x); rd(p.y) }

    // MARK: Compressed forms

    /// 2-bit code (BB).
    mutating func bb(_ v: Int) { bits(UInt64(v & 3), 2) }

    mutating func b(_ v: Bool) { bit(v) }

    /// BITSHORT.
    mutating func bs(_ v: Int) {
        let s = Int16(truncatingIfNeeded: v)
        if s == 0 { bb(2) }
        else if s == 256 { bb(3) }
        else if s > 0 && s < 256 { bb(1); rc(UInt8(s)) }
        else { bb(0); rs(UInt16(bitPattern: s)) }
    }

    /// BITLONG.
    mutating func bl(_ v: Int) {
        let l = Int32(truncatingIfNeeded: v)
        if l == 0 { bb(2) }
        else if l > 0 && l < 256 { bb(1); rc(UInt8(l)) }
        else { bb(0); rl(UInt32(bitPattern: l)) }
    }

    /// BITDOUBLE.
    mutating func bd(_ v: Double) {
        let x = v.isFinite ? v : 0
        if x == 0 { bb(2) }
        else if x == 1 { bb(1) }
        else { bb(0); rd(x) }
    }

    mutating func bd2(_ p: Vec2) { bd(p.x); bd(p.y) }
    /// 3BD with z = 0.
    mutating func bd3(_ p: Vec2, z: Double = 0) { bd(p.x); bd(p.y); bd(z) }
    mutating func bd3(_ x: Double, _ y: Double, _ z: Double) { bd(x); bd(y); bd(z) }

    /// BitDouble With Default (DD).
    mutating func dd(_ v: Double, default def: Double) {
        var x = v.isFinite ? v : 0
        if x == 0 { x = 0 }
        let a = x.bitPattern, d = def.bitPattern
        if a == d { bb(0); return }
        func byte(_ p: UInt64, _ i: Int) -> UInt8 { UInt8((p >> UInt64(i * 8)) & 0xFF) }
        if (a >> 32) == (d >> 32) {
            bb(1)
            for i in 0..<4 { rc(byte(a, i)) }
        } else if (a >> 48) == (d >> 48) {
            bb(2)
            rc(byte(a, 4)); rc(byte(a, 5))
            for i in 0..<4 { rc(byte(a, i)) }
        } else {
            bb(3); rd(x)
        }
    }

    /// BitExtrusion (R2000): always the default (0,0,1).
    mutating func beDefault() { bit(true) }

    /// BitThickness (R2000): always 0.
    mutating func btZero() { bit(true) }

    /// CMC for R15 and earlier: a BS color index.
    mutating func cmc(_ index: Int) { bs(index) }

    /// Text (T/TV for R2000): BS length + bytes (Windows-1252, no terminator).
    mutating func t(_ s: String) {
        var b = DWGBitWriter.encodeText(s)
        if b.count > 32767 { b = Array(b.prefix(32767)) }
        bs(b.count)
        rawBytes(b)
    }

    /// Handle reference: |code(4)|counter(4)|handle bytes (MSB first)|.
    mutating func h(_ code: Int, _ handle: UInt32) {
        var hb: [UInt8] = []
        var v = handle
        while v != 0 { hb.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        bits(UInt64(code & 0xF), 4)
        bits(UInt64(hb.count), 4)
        for x in hb { rc(x) }
    }

    // MARK: Composition

    /// Appends all bits of another writer.
    mutating func append(_ o: DWGBitWriter) {
        if bitCount & 7 == 0 {
            bytes.append(contentsOf: o.bytes)
            bitCount += o.bitCount
            // Trim to exact bit count (o.bytes may contain a partial last byte, already counted).
            return
        }
        let full = o.bitCount >> 3
        for i in 0..<full { rc(o.bytes[i]) }
        let rem = o.bitCount & 7
        if rem > 0 { bits(UInt64(o.bytes[full] >> UInt8(8 - rem)), rem) }
    }

    /// Overwrites 32 bits at `bitPos` with a raw long (little-endian bytes, MSB-first bits).
    mutating func patchRL(at bitPos: Int, _ v: UInt32) {
        var pos = bitPos
        for i in 0..<4 {
            let byte = UInt8((v >> UInt32(i * 8)) & 0xFF)
            for k in 0..<8 {
                let on = (byte >> UInt8(7 - k)) & 1 == 1
                let idx = pos >> 3, mask = UInt8(0x80 >> (pos & 7))
                if on { bytes[idx] |= mask } else { bytes[idx] &= ~mask }
                pos += 1
            }
        }
    }

    // MARK: Helpers

    /// Windows-1252 bytes; characters outside it become `\U+XXXX` escapes (AutoCAD's convention).
    static func encodeText(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            let v = ch.value
            if v < 0x80 { out.append(UInt8(v)); continue }
            if let b = cp1252Reverse[v] { out.append(b); continue }
            if v <= 0xFFFF {
                out.append(contentsOf: Array(String(format: "\\U+%04X", v).utf8))
            } else {
                // Outside the BMP: write the UTF-16 surrogate pair as two escapes.
                let u = v - 0x10000
                let hi = 0xD800 + (u >> 10), lo = 0xDC00 + (u & 0x3FF)
                out.append(contentsOf: Array(String(format: "\\U+%04X\\U+%04X", hi, lo).utf8))
            }
        }
        return out
    }

    private static let cp1252Reverse: [UInt32: UInt8] = {
        var m: [UInt32: UInt8] = [:]
        for b in 0xA0...0xFF { m[UInt32(b)] = UInt8(b) }
        let high: [(UInt8, UInt32)] = [
            (0x80, 0x20AC), (0x82, 0x201A), (0x83, 0x0192), (0x84, 0x201E), (0x85, 0x2026), (0x86, 0x2020), (0x87, 0x2021),
            (0x88, 0x02C6), (0x89, 0x2030), (0x8A, 0x0160), (0x8B, 0x2039), (0x8C, 0x0152), (0x8E, 0x017D),
            (0x91, 0x2018), (0x92, 0x2019), (0x93, 0x201C), (0x94, 0x201D), (0x95, 0x2022), (0x96, 0x2013), (0x97, 0x2014),
            (0x98, 0x02DC), (0x99, 0x2122), (0x9A, 0x0161), (0x9B, 0x203A), (0x9C, 0x0153), (0x9E, 0x017E), (0x9F, 0x0178),
        ]
        for (b, u) in high { m[u] = b }
        return m
    }()

    // MARK: CRC (spec 2.14.1)

    static let crcTable: [UInt16] = [
        0x0000, 0xC0C1, 0xC181, 0x0140, 0xC301, 0x03C0, 0x0280, 0xC241, 0xC601, 0x06C0, 0x0780, 0xC741, 0x0500, 0xC5C1, 0xC481, 0x0440,
        0xCC01, 0x0CC0, 0x0D80, 0xCD41, 0x0F00, 0xCFC1, 0xCE81, 0x0E40, 0x0A00, 0xCAC1, 0xCB81, 0x0B40, 0xC901, 0x09C0, 0x0880, 0xC841,
        0xD801, 0x18C0, 0x1980, 0xD941, 0x1B00, 0xDBC1, 0xDA81, 0x1A40, 0x1E00, 0xDEC1, 0xDF81, 0x1F40, 0xDD01, 0x1DC0, 0x1C80, 0xDC41,
        0x1400, 0xD4C1, 0xD581, 0x1540, 0xD701, 0x17C0, 0x1680, 0xD641, 0xD201, 0x12C0, 0x1380, 0xD341, 0x1100, 0xD1C1, 0xD081, 0x1040,
        0xF001, 0x30C0, 0x3180, 0xF141, 0x3300, 0xF3C1, 0xF281, 0x3240, 0x3600, 0xF6C1, 0xF781, 0x3740, 0xF501, 0x35C0, 0x3480, 0xF441,
        0x3C00, 0xFCC1, 0xFD81, 0x3D40, 0xFF01, 0x3FC0, 0x3E80, 0xFE41, 0xFA01, 0x3AC0, 0x3B80, 0xFB41, 0x3900, 0xF9C1, 0xF881, 0x3840,
        0x2800, 0xE8C1, 0xE981, 0x2940, 0xEB01, 0x2BC0, 0x2A80, 0xEA41, 0xEE01, 0x2EC0, 0x2F80, 0xEF41, 0x2D00, 0xEDC1, 0xEC81, 0x2C40,
        0xE401, 0x24C0, 0x2580, 0xE541, 0x2700, 0xE7C1, 0xE681, 0x2640, 0x2200, 0xE2C1, 0xE381, 0x2340, 0xE101, 0x21C0, 0x2080, 0xE041,
        0xA001, 0x60C0, 0x6180, 0xA141, 0x6300, 0xA3C1, 0xA281, 0x6240, 0x6600, 0xA6C1, 0xA781, 0x6740, 0xA501, 0x65C0, 0x6480, 0xA441,
        0x6C00, 0xACC1, 0xAD81, 0x6D40, 0xAF01, 0x6FC0, 0x6E80, 0xAE41, 0xAA01, 0x6AC0, 0x6B80, 0xAB41, 0x6900, 0xA9C1, 0xA881, 0x6840,
        0x7800, 0xB8C1, 0xB981, 0x7940, 0xBB01, 0x7BC0, 0x7A80, 0xBA41, 0xBE01, 0x7EC0, 0x7F80, 0xBF41, 0x7D00, 0xBDC1, 0xBC81, 0x7C40,
        0xB401, 0x74C0, 0x7580, 0xB541, 0x7700, 0xB7C1, 0xB681, 0x7640, 0x7200, 0xB2C1, 0xB381, 0x7340, 0xB101, 0x71C0, 0x7080, 0xB041,
        0x5000, 0x90C1, 0x9181, 0x5140, 0x9301, 0x53C0, 0x5280, 0x9241, 0x9601, 0x56C0, 0x5780, 0x9741, 0x5500, 0x95C1, 0x9481, 0x5440,
        0x9C01, 0x5CC0, 0x5D80, 0x9D41, 0x5F00, 0x9FC1, 0x9E81, 0x5E40, 0x5A00, 0x9AC1, 0x9B81, 0x5B40, 0x9901, 0x59C0, 0x5880, 0x9841,
        0x8801, 0x48C0, 0x4980, 0x8941, 0x4B00, 0x8BC1, 0x8A81, 0x4A40, 0x4E00, 0x8EC1, 0x8F81, 0x4F40, 0x8D01, 0x4DC0, 0x4C80, 0x8C41,
        0x4400, 0x84C1, 0x8581, 0x4540, 0x8701, 0x47C0, 0x4680, 0x8641, 0x8201, 0x42C0, 0x4380, 0x8341, 0x4100, 0x81C1, 0x8081, 0x4040,
    ]

    /// The 16-bit DWG CRC ("8-bit CRC" in the spec) with a start value.
    static func crc(_ seed: UInt16, _ data: [UInt8]) -> UInt16 { crc(seed, data[...]) }

    static func crc(_ seed: UInt16, _ data: ArraySlice<UInt8>) -> UInt16 {
        var dx = seed
        for p in data {
            let al = p ^ UInt8(dx & 0xFF)
            dx = (dx >> 8) & 0xFF
            dx ^= crcTable[Int(al)]
        }
        return dx
    }

    // MARK: Byte-level encodings (object map / object size)

    /// Modular short (object sizes).
    static func modularShort(_ v: Int) -> [UInt8] {
        var out: [UInt8] = []
        var x = v
        repeat {
            var s = x & 0x7FFF
            x >>= 15
            if x > 0 { s |= 0x8000 }
            out.append(UInt8(s & 0xFF)); out.append(UInt8(s >> 8))
        } while x > 0
        return out
    }

    /// Signed modular char (object map offsets). The final byte's 0x40 bit carries the sign,
    /// so positive values whose top group would set it get an extra byte.
    static func modularChar(_ v: Int) -> [UInt8] {
        var out: [UInt8] = []
        let neg = v < 0
        var x = abs(v)
        while true {
            let group = x & 0x7F
            x >>= 7
            if x == 0 && group & 0x40 == 0 {
                out.append(UInt8(group | (neg ? 0x40 : 0)))
                return out
            }
            out.append(UInt8(group | 0x80))
            if x == 0 {
                out.append(neg ? 0x40 : 0)
                return out
            }
        }
    }
}
