import Foundation

/// Real AutoCAD drawings are not committed with the sources, so the file-based reader tests read a
/// folder the developer points at:
///
/// ```
/// CADMAC_DWG_CORPUS=~/cadmac-corpus swift test          // folder of .dwg / .dwt files
/// CADMAC_DWG_SAMPLE_DXF=~/cadmac-corpus/saved_as.dxf swift test
/// ```
///
/// Without those, the tests that need real files report a warning (`corpusWarning`) instead of
/// passing silently, which is what a hardcoded path to a deleted folder used to hide.
enum Corpus {
    static let dir = ProcessInfo.processInfo.environment["CADMAC_DWG_CORPUS"] ?? ""
    static let sampleDXF = ProcessInfo.processInfo.environment["CADMAC_DWG_SAMPLE_DXF"] ?? ""

    static func path(_ name: String) -> String { dir.isEmpty ? name : dir + "/" + name }
    static func has(_ name: String) -> Bool { !dir.isEmpty && FileManager.default.fileExists(atPath: path(name)) }
    static func load(_ name: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path(name))) }
    static var hasSampleDXF: Bool { !sampleDXF.isEmpty && FileManager.default.fileExists(atPath: sampleDXF) }
}
