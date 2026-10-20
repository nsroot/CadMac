import Foundation
import Testing
@testable import CadCore

/// Packs a string of '0'/'1' (spaces ignored) into bytes, MSB first.
private func bits(_ s: String) -> [UInt8] {
    let b = s.filter { $0 == "0" || $0 == "1" }
    var out = [UInt8](repeating: 0, count: (b.count + 7) / 8)
    for (i, c) in b.enumerated() where c == "1" { out[i / 8] |= 0x80 >> UInt8(i % 8) }
    return out
}

private func doubleBits(_ d: Double) -> String {
    var v = d.bitPattern
    var s = ""
    for _ in 0..<8 {
        let byte = UInt8(v & 0xFF)
        s += String(byte, radix: 2).leftPad(8)
        v >>= 8
    }
    return s
}

private extension String {
    func leftPad(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self }
}


@Suite("DWG reader: bit codes")
struct DWGReadBitTests {
    @Test func bitShortSpecExample() {
        // Spec 2.2: 257, 0, 256, 15, 0.
        var r = DWGBitReader(bits("00 00000001 00000001 10 11 01 00001111 10"))
        let v1 = r.bs()
        #expect(v1 == 257)
        let v2 = r.bs()
        #expect(v2 == 0)
        let v3 = r.bs()
        #expect(v3 == 256)
        let v4 = r.bs()
        #expect(v4 == 15)
        let v5 = r.bs()
        #expect(v5 == 0)
        #expect(!r.overflow)
    }

    @Test func bitShortNegative() {
        var r = DWGBitReader(bits("00 11111111 11111111"))
        let v6 = r.bs()
        #expect(v6 == -1)
    }

    @Test func bitLongSpecExample() {
        // Spec 2.3: 257, 0, 15, 0.
        var r = DWGBitReader(bits("00 00000001 00000001 00000000 00000000 10 01 00001111 10"))
        let v7 = r.bl()
        #expect(v7 == 257)
        let v8 = r.bl()
        #expect(v8 == 0)
        let v9 = r.bl()
        #expect(v9 == 15)
        let v10 = r.bl()
        #expect(v10 == 0)
    }

    @Test func bitDouble() {
        var r = DWGBitReader(bits("01 10 00" + doubleBits(-12.5)))
        let v11 = r.bd()
        #expect(v11 == 1)
        let v12 = r.bd()
        #expect(v12 == 0)
        let v13 = r.bd()
        #expect(v13 == -12.5)
        #expect(!r.overflow)
    }

    @Test func bitDoubleWithDefault() {
        // 00: default; 01: 4 low bytes patched; 11: full double.
        let def = 100.0
        var patched = def.bitPattern
        patched = (patched & ~0xFFFF_FFFF) | 0x1234_5678
        var r = DWGBitReader(bits("00 01 01111000 01010110 00110100 00010010 11" + doubleBits(2.25)))
        let v14 = r.dd(def)
        #expect(v14 == def)
        let v15 = r.dd(def).bitPattern
        #expect(v15 == patched)
        let v16 = r.dd(def)
        #expect(v16 == 2.25)
    }

    @Test func rawValuesAreLittleEndianAndUnaligned() {
        // One leading bit, then RS 0x1234 and RC 0xAB, all unaligned.
        var r = DWGBitReader(bits("1 00110100 00010010 10101011"))
        let v17 = r.bit()
        #expect(v17)
        let v18 = r.rs()
        #expect(v18 == 0x1234)
        let v19 = r.rc()
        #expect(v19 == 0xAB)
    }

    @Test func bitLongLongAndThreeBit() {
        var r = DWGBitReader(bits("010 00000001 00000010 110 0"))
        let v20 = r.bll()
        #expect(v20 == 0x0201)
        let v21 = r.b3()
        #expect(v21 == 6)
        let v22 = r.b3()
        #expect(v22 == 0)
    }

    @Test func objectType2010() {
        var r = DWGBitReader(bits("00 00010011 01 00000011 10 11110100 00000001"))
        let v23 = r.ot2010()
        #expect(v23 == 0x13)
        let v24 = r.ot2010()
        #expect(v24 == 0x1F3)
        let v25 = r.ot2010()
        #expect(v25 == 0x1F4)
    }

    @Test func modularCharsSpecExamples() {
        var i = 0
        #expect(dwgReadModularChar([0x82, 0x24], &i, signed: true) == 4610)
        #expect(i == 2)
        i = 0
        #expect(dwgReadModularChar([0xE9, 0x97, 0xE6, 0x35], &i, signed: true) == 112_823_273)
        i = 0
        #expect(dwgReadModularChar([0x85, 0x4B], &i, signed: true) == -1413)
        i = 0
        #expect(dwgReadModularChar([0x85, 0x4B], &i, signed: false) == 0x4B << 7 | 5)
        i = 0
        #expect(dwgReadModularChar([0x80, 0x80], &i, signed: true) == nil)
    }

    @Test func modularShortSpecExample() {
        var i = 0
        #expect(dwgReadModularShort([0x31, 0xF4, 0x8D, 0x00], &i) == 4_650_033)
        #expect(i == 4)
        i = 0
        #expect(dwgReadModularShort([0x31], &i) == nil)
    }

    @Test func handles() {
        // Spec 2.13: 5.2.05E7 (hard pointer to layer 0x5E7).
        var r = DWGBitReader(bits("0101 0010 00000101 11100111"))
        let h = r.handleRef()
        #expect(h.code == 5 && h.value == 0x5E7)
        // Offset codes relative to handle 0x100.
        var o = DWGBitReader(bits("0110 0000 1000 0000 1010 0001 00000100 1100 0001 00000010"))
        let v26 = o.handle(relativeTo: 0x100)
        #expect(v26 == 0x101)
        let v27 = o.handle(relativeTo: 0x100)
        #expect(v27 == 0xFF)
        let v28 = o.handle(relativeTo: 0x100)
        #expect(v28 == 0x104)
        let v29 = o.handle(relativeTo: 0x100)
        #expect(v29 == 0xFE)
    }

    @Test func texts() {
        // TV: BS length 3 + "Abc"; TU: length 2 + "Ğx" in UTF-16LE.
        var r = DWGBitReader(bits("01 00000011 01000001 01100010 01100011"))
        let v30 = r.text8(.windowsCP1252)
        #expect(v30 == "Abc")
        var u = DWGBitReader(bits("01 00000010 00011110 00000001 01111000 00000000"))
        let v31 = u.textU()
        #expect(v31 == "Ğx")
        // A length beyond the data overflows instead of trapping.
        var bad = DWGBitReader(bits("01 11111111 0100"))
        let v32 = bad.text8(.windowsCP1252)
        #expect(v32 == "")
        #expect(bad.overflow)
    }

    @Test func readingPastTheEndIsSafe() {
        var r = DWGBitReader([0xFF])
        _ = r.rd()
        _ = r.bl()
        _ = r.rawBytes(100)
        r.skipBytes(1 << 40)
        #expect(r.overflow)
        #expect(r.pos <= r.end)
    }

    @Test func colors() {
        #expect(DWGReadColor(fromCMC: 0xC300_0007, index: 0) == .aci(7))
        #expect(DWGReadColor(fromCMC: 0xC212_3456, index: 0) == .rgb(0x123456))
        #expect(DWGReadColor(fromCMC: 0xC000_0000, index: 0) == .byLayer)
        #expect(DWGReadColor(fromCMC: 0xC100_0000, index: 0) == .byBlock)
        var r = DWGBitReader(bits("01 00000101"))           // ENC: plain ACI 5
        let v33 = r.enc().color
        #expect(v33 == .aci(5))
        #expect(dwgReadLineweight(index: 7) == 25)
        #expect(dwgReadLineweight(index: 29) == -1)
    }
}

@Suite("DWG reader: compression and checksums")
struct DWGReadCompressionTests {
    @Test func lz77LiteralAndShortCopy() throws {
        // Literal length 4 ("abcd"), copy 4 bytes from 4 back (op 0x5C, offset 3), end.
        let src: [UInt8] = [0x01, 0x61, 0x62, 0x63, 0x64, 0x5C, 0x00, 0x11]
        let out = try DWGReadLZ77.decompress(src, 0..<src.count, size: 8)
        #expect(String(decoding: out, as: UTF8.self) == "abcdabcd")
    }

    @Test func lz77LongLiteralAndFarCopy() throws {
        // 40000-byte literal, then opcode 0x1A: 4 bytes copied from 0x8010 back (bit 3 adds 0x4000).
        var literal = [UInt8](repeating: 0, count: 40000)
        var seed: UInt32 = 7
        for i in literal.indices { seed = seed &* 1_103_515_245 &+ 12345; literal[i] = UInt8(truncatingIfNeeded: seed >> 16) }
        var src: [UInt8] = [0x00] + [UInt8](repeating: 0, count: 156) + [0xCA]
        src += literal
        src += [0x1A, 0x40, 0x00, 0x11]
        let out = try DWGReadLZ77.decompress(src, 0..<src.count, size: 40004)
        #expect(out.count == 40004)
        #expect(Array(out[0..<40000]) == literal)
        #expect(Array(out[40000...]) == Array(literal[(40000 - 0x8010)..<(40000 - 0x8010 + 4)]))
    }

    @Test func lz77RejectsBackReferenceBeforeStart() {
        let src: [UInt8] = [0x01, 0x61, 0x62, 0x63, 0x64, 0x5C, 0x40, 0x11]
        #expect(throws: DWGReadError.self) { try DWGReadLZ77.decompress(src, 0..<src.count, size: 8) }
    }

    @Test func r2007LiteralOrderAndCopy() throws {
        // A 10-byte literal is stored as [9], [1...8], [0].
        let lit: [UInt8] = [0x02] + Array(0...9)
        #expect(try DWGReadR2007.decompress(lit, size: 10) == [9, 1, 2, 3, 4, 5, 6, 7, 8, 0])
        // Start of a real AC1021 file header: "70 00", then 6 zeros copied from 1 back.
        let hdr: [UInt8] = [0x20, 0x00, 0x00, 0x02, 0x00, 0x70, 0x60, 0x02]
        #expect(try DWGReadR2007.decompress(hdr, size: 8) == [0x70, 0, 0, 0, 0, 0, 0, 0])
        #expect(DWGReadR2007.literalOrder[32] == Array(24..<32) + Array(16..<24) + Array(8..<16) + Array(0..<8))
    }

    @Test func reedSolomonDeinterleave() {
        // Three interleaved code words: data byte j of block b sits at j * 3 + b.
        var raw = [UInt8](repeating: 0, count: 3 * 255)
        for b in 0..<3 { for j in 0..<255 { raw[j * 3 + b] = UInt8((b * 100 + j) & 0xFF) } }
        let data = DWGReadR2007.deinterleave(raw, blocks: 3, k: 239)
        #expect(data.count == 717)
        #expect(data[0] == 0 && data[239] == 100 && data[478] == 200 && data[240] == 101)
        let flat = DWGReadR2007.plain(Array(0..<255) + Array(0..<255), blocks: 2, k: 251)
        #expect(flat.count == 502 && flat[251] == 0 && flat[250] == 250)
    }

    @Test func crcs() {
        let check = Array("123456789".utf8)
        #expect(DWGReadCRC.crc16(check, 0..<9, seed: 0) == 0xBB3D)
        #expect(DWGReadCRC.crc32(check, 0..<9) == 0xCBF4_3926)
        #expect(DWGReadCRC.pageChecksum([1, 2, 3], 0..<3, seed: 0) == 0x000A_0006)
        // R2004 header magic sequence (spec 4.1) starts 29 23 BE 84.
        #expect(Array(DWGReadContainer.magicSequence.prefix(4)) == [0x29, 0x23, 0xBE, 0x84])
    }
}

@Suite("DWG reader: files")
struct DWGReadFileTests {
    /// The real-file tests below are `.enabled(if:)` on a corpus folder. Without a corpus they would
    /// vanish from the run and the suite would look green, so say out loud that they did not run.
    @Test func missingCorpusIsReported() {
        let missing = ["poker.dwg", "sambo.dwg", "brkline.dwg"].filter { !Corpus.has($0) }
        guard !missing.isEmpty else { return }
        let names = missing.joined(separator: ", ")
        Issue.record("DWG corpus incomplete: no \(names). Set CADMAC_DWG_CORPUS to a folder of real DWG/DWT files to run the reader file tests.", severity: .warning)
    }

    @Test func nativeSampleRoundTripNeedsNoCorpus() throws {
        // The committed writer samples are corpus-free coverage for reading real-shaped DWG files.
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("DWG-Test", isDirectory: true)
        let names = ["01-basic.dwg", "02-blocks-attributes.dwg", "03-dimensions-hatch.dwg", "04-layouts.dwg", "05-poker-roundtrip.dwg"]
        for n in names where FileManager.default.fileExists(atPath: dir.appendingPathComponent(n).path) {
            let r = try NativeDWGReader.read(url: dir.appendingPathComponent(n))
            #expect(r.layers.contains { $0.name == "0" }, "\(n): no layer 0")
        }
    }

    @Test func rejectsNonDWG() {
        #expect(throws: DWGReadError.notDWG) { try NativeDWGReader.read(data: Data("hello world".utf8)) }
        #expect(throws: DWGReadError.self) { try NativeDWGReader.read(data: Data("AC1009".utf8) + Data(count: 400)) }
        #expect(throws: DWGReadError.self) { try NativeDWGReader.read(data: Data("AC1032".utf8) + Data(count: 400)) }
        #expect(throws: DWGReadError.self) { try NativeDWGReader.read(data: Data("AC1015".utf8) + Data(count: 400)) }
        #expect(throws: DWGReadError.self) { try NativeDWGReader.read(data: Data("AC1021".utf8) + Data(count: 2000)) }
    }

    @Test func roundTripThroughNativeWriter() throws {
        var d = Drawing()
        d.layers.append(Layer(name: "Walls", color: .aci(1), lineweight: 0.35, isLocked: true))
        d.layers.append(Layer(name: "Hidden", color: .aci(3), isOn: false))
        d.modelEntities = [
            Entity(.line(LineGeom(start: Vec2(0, 0), end: Vec2(100, 50))), layer: "Walls"),
            Entity(.circle(CircleGeom(center: Vec2(10, 10), radius: 5)), color: .aci(5)),
            Entity(.arc(ArcGeom(center: Vec2(0, 0), radius: 20, startAngle: 0, endAngle: .pi / 2)), layer: "Hidden"),
            Entity(.polyline(PolylineGeom(vertices: [PolyVertex(Vec2(0, 0), bulge: 0.5), PolyVertex(Vec2(10, 0)), PolyVertex(Vec2(10, 10))], closed: true))),
            Entity(.text(TextGeom(position: Vec2(5, 5), height: 2.5, text: "Merhaba Dünya"))),
        ]
        d.blocks["DOOR"] = BlockDef(name: "DOOR", entities: [Entity(.line(LineGeom(start: .zero, end: Vec2(1, 0))))])
        d.modelEntities.append(Entity(.insert(InsertGeom(blockName: "DOOR", position: Vec2(30, 30), scaleX: 2, scaleY: 2, rotation: 0.5))))
        let back = try NativeDWGReader.read(data: try NativeDWGWriter.write(d))
        #expect(back.modelEntities.count == d.modelEntities.count)
        for (a, b) in zip(d.modelEntities, back.modelEntities) {
            #expect(a.kind.typeName == b.kind.typeName)
            #expect(a.layer == b.layer)
        }
        if case .line(let l) = back.modelEntities[0].kind { #expect(l.end.isClose(to: Vec2(100, 50), tol: 1e-9)) }
        if case .text(let t) = back.modelEntities[4].kind { #expect(t.text == "Merhaba Dünya") }
        if case .insert(let g) = back.modelEntities[5].kind {
            #expect(g.blockName == "DOOR" && abs(g.scaleX - 2) < 1e-12 && abs(g.rotation - 0.5) < 1e-12)
        }
        #expect(back.blocks["DOOR"]?.entities.count == 1)
        let walls = back.layer(named: "Walls")
        #expect(walls?.isLocked == true && walls?.color == .aci(1) && walls?.lineweight == 0.35)
        #expect(back.layer(named: "Hidden")?.isOn == false)
    }

    @Test(.enabled(if: Corpus.has("poker.dwg"))) func poker2018() throws {
        let data = try Corpus.load("poker.dwg")
        let r = try NativeDWGReader.report(data: data)
        #expect(r.version == "AC1032")
        #expect(r.decodedCount == r.objectCount && r.unresolvedHandles == 0)
        #expect(r.crcErrors == 0 && r.checksumErrors == 0)
        #expect(r.misaligned.isEmpty)
        #expect(r.unresolvedLayers == 0)
        let d = try NativeDWGReader.read(data: data)
        #expect(d.modelEntities.count == 284)
        #expect(d.layers.count == 53)
        #expect(d.blocks.count == 33)
        #expect(d.settings.insUnits == .millimeters)
        #expect(d.layouts.map(\.name) == ["PLAN"])
        let plan = try #require(d.layouts.first)
        #expect(abs(plan.paper.width - 420) < 1 && abs(plan.paper.height - 297) < 1)
        let vps = plan.entities.compactMap { e -> ViewportGeom? in if case .viewport(let v) = e.kind { return v }; return nil }
        #expect(vps.count == 1)
        if let v = vps.first {
            #expect(v.isLocked)
            #expect(abs(1 / v.scale - 65.3) < 0.5)
            #expect(v.viewCenter.isClose(to: Vec2(11576, 2468), tol: 5))
        }
    }

    @Test(.enabled(if: Corpus.has("poker.dwg"))) func pokerRoundTripsAsR2000() throws {
        let src = try NativeDWGReader.read(data: try Corpus.load("poker.dwg"))
        let dwg = try NativeDWGWriter.write(src)
        let r = try NativeDWGReader.report(data: dwg)
        #expect(r.version == "AC1015" && r.crcErrors == 0 && r.misaligned.isEmpty && r.unresolvedHandles == 0)
        let back = try NativeDWGReader.read(data: dwg)
        #expect(back.modelEntities.count == src.modelEntities.count)
        #expect(back.layers.count == src.layers.count && back.blocks.count == src.blocks.count)
        #expect(zip(src.modelEntities, back.modelEntities).allSatisfy { "\($0.kind)" == "\($1.kind)" && $0.layer == $1.layer })
    }

    @Test(.enabled(if: Corpus.has("sambo.dwg"))) func sambo2018() throws {
        let data = try Corpus.load("sambo.dwg")
        let d = try NativeDWGReader.read(data: data)
        #expect(d.modelEntities.count > 90_000)
        #expect(d.layers.count == 175)
        #expect(d.layouts.count == 53)
        #expect(d.layouts.first?.name == "A001" && d.layouts.last?.name == "A604")
        #expect(d.layouts.allSatisfy { abs($0.paper.width - 594) < 1 && abs($0.paper.height - 420) < 1 })
        let vps = d.layouts.flatMap(\.entities).filter { if case .viewport = $0.kind { return true }; return false }
        #expect(vps.count >= 70)
        #expect(d.groups.count > 0)
    }

    @Test(.enabled(if: Corpus.has("brkline.dwg") && Corpus.has("Architectural Title Block.dwg") && Corpus.has("Generic 24in x 36in Title Block.dwg")))
    func autocad2007Files() throws {
        for (name, count) in [("brkline.dwg", 3), ("Architectural Title Block.dwg", 32), ("Generic 24in x 36in Title Block.dwg", 23)] {
            let data = try Corpus.load(name)
            let r = try NativeDWGReader.report(data: data)
            #expect(r.version == "AC1021")
            #expect(r.crcErrors == 0 && r.misaligned.isEmpty && r.unresolvedHandles == 0)
            #expect(try NativeDWGReader.read(data: data).modelEntities.count == count)
        }
    }

    @Test(.enabled(if: Corpus.has("acadltiso.dwt") && Corpus.has("Tutorial-iArch.dwt")))
    func templates() throws {
        let iso = try NativeDWGReader.read(data: try Corpus.load("acadltiso.dwt"))
        #expect(iso.settings.insUnits == .millimeters)
        #expect(iso.layouts.count == 2)
        let arch = try NativeDWGReader.read(data: try Corpus.load("Tutorial-iArch.dwt"))
        #expect(arch.settings.insUnits == .inches)
        #expect(arch.settings.ltScale == 48)
        #expect(arch.layers.count == 15)
    }

    @Test(.enabled(if: Corpus.has("brkline.dwg") && Corpus.has("acadlt.dwt")))
    func damagedFilesNeverCrash() throws {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return Int(seed >> 33) }
        for name in ["brkline.dwg", "acadlt.dwt"] {
            let base = [UInt8](try Corpus.load(name))
            for it in 0..<60 {
                var b = base
                if it % 3 == 0 {
                    b = Array(b.prefix(next() % b.count))
                } else {
                    for _ in 0..<(1 + next() % 12) { b[next() % b.count] = UInt8(truncatingIfNeeded: next()) }
                }
                _ = try? NativeDWGReader.read(data: Data(b))
            }
        }
    }
}
