import Foundation
import Testing
@testable import CadCore

/// The DWG save path must work on a clean Mac: CadMac's own writer is the primary writer and an
/// external converter (LibreDWG, ODA File Converter) is only a fallback.
@Test("DWG save writes a readable native DWG with no converter installed")
func nativeDWGExportNeedsNoConverter() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CadMac-export-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    #expect(DWGExporter.isAvailable)
    for (name, src) in [("basic", dwgwSampleBasic()), ("dims", dwgwSampleDimsHatch()), ("blocks", dwgwSampleBlocks())] {
        let url = dir.appendingPathComponent("\(name).dwg")
        try DWGExporter.write(src, to: url, using: .native)
        // A DWG starts with its version magic; the native writer emits AutoCAD 2000.
        let head = try Data(contentsOf: url).prefix(6)
        #expect(String(decoding: head, as: UTF8.self) == "AC1015", "\(name) is not an AC1015 DWG")
        let back = try NativeDWGReader.read(url: url)
        #expect(back.entities.count == src.entities.count, "\(name) lost entities")
        #expect(back.layers.count == src.layers.count, "\(name) lost layers")
    }
}

@Test("A read reports the entities it could not carry into the drawing model")
func readResultCarriesReport() throws {
    let src = dwgwSampleBlocks()
    let data = try NativeDWGWriter.write(src)

    let r = try NativeDWGReader.readResult(data: data)
    #expect(r.report.version == "AC1015")
    #expect(r.report.formatName == "AutoCAD 2000")
    #expect(r.drawing.entities.count == src.entities.count)
    // CadMac's own writer only emits types the reader can hold, so nothing should be left out.
    #expect(r.report.dropped.isEmpty, "\(r.report.dropped)")
    #expect(!r.report.hasLosses)

    // The tooling entry point converts too, so it reports the same thing.
    let rep = try NativeDWGReader.report(data: data)
    #expect(rep.dropped == r.report.dropped)
    #expect(rep.modelEntityCount == r.report.modelEntityCount)
}

@Test("Dropped types are ranked by count, then by name")
func topDroppedOrder() {
    var rep = NativeDWGReader.Report(version: "AC1032", objectCount: 0, decodedCount: 0, unresolvedHandles: 0,
                                     checksumErrors: 0, crcErrors: 0, misaligned: [:], typeCounts: [:],
                                     modelEntityCount: 0, layerCount: 0, blockCount: 0,
                                     unresolvedLayers: 0, unresolvedOwners: 0, dropped: [:])
    #expect(rep.topDropped.isEmpty)
    rep.dropped = ["WIPEOUT": 814, "IMAGE": 40, "ZEBRA": 814, "MLEADER": 1, "SURFACE": 9, "REGION": 9, "OLE2FRAME": 2]
    #expect(rep.topDropped.map { $0.name } == ["WIPEOUT", "ZEBRA", "IMAGE", "REGION", "SURFACE", "OLE2FRAME"])
    #expect(rep.hasLosses)
    #expect(NativeDWGReader.Report(version: "AC9999", objectCount: 0, decodedCount: 0, unresolvedHandles: 0,
                                   checksumErrors: 0, crcErrors: 0, misaligned: [:], typeCounts: [:],
                                   modelEntityCount: 0, layerCount: 0, blockCount: 0,
                                   unresolvedLayers: 0, unresolvedOwners: 0, dropped: [:]).formatName == "AC9999")
}
