import Foundation

/// Native DWG reader, implemented from the Open Design Specification for .dwg files (v5.4.1).
///
/// Supports R13/R14/2000 (AC1012/AC1014/AC1015), 2004 (AC1018), 2007 (AC1021),
/// 2010 (AC1024), 2013 (AC1027) and 2018 (AC1032) files. The decoded objects are handed to
/// `DXFReader` as an in-memory DXF stream so that DWG and DXF files produce the same model.
public enum NativeDWGReader {
    public static func read(url: URL) throws -> Drawing { try readResult(url: url).drawing }

    public static func read(data: Data) throws -> Drawing { try readResult(data: data).drawing }

    /// Diagnostics for tests and tooling.
    public struct Report {
        public var version: String
        public var objectCount: Int
        public var decodedCount: Int
        public var unresolvedHandles: Int
        public var checksumErrors: Int
        public var crcErrors: Int
        /// Objects whose data stream was not consumed exactly (by DXF type name).
        public var misaligned: [String: Int]
        public var typeCounts: [String: Int]
        public var modelEntityCount: Int
        public var layerCount: Int
        public var blockCount: Int
        public var unresolvedLayers: Int
        public var unresolvedOwners: Int
        /// Entities the file contains but the drawing model cannot hold (by DXF type name).
        /// Filled when the drawing was converted, i.e. by `read` / `readResult`.
        public var dropped: [String: Int]

        /// True when the conversion left something out or met bytes it did not expect.
        public var hasLosses: Bool { !dropped.isEmpty || !misaligned.isEmpty || unresolvedHandles > 0 }

        /// "AutoCAD 2018" for AC1032; the tag itself for an unknown version.
        public var formatName: String { DWGVersion(rawValue: version)?.displayName ?? version }

        /// Top dropped types, most frequent first: `("MLEADER", 12)`, `("IMAGE", 2)`, ...
        public var topDropped: [(name: String, count: Int)] {
            dropped.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                .prefix(6).map { (name: $0.key, count: $0.value) }
        }
    }

    /// A drawing plus the statistics of the run that produced it (one decode pass for both).
    public struct ReadResult {
        public var drawing: Drawing
        public var report: Report
    }

    /// Decodes the file once and returns both the drawing and its report.
    public static func readResult(url: URL) throws -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { throw DXFError.fileNotFound(url.path) }
        return try readResult(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func readResult(data: Data) throws -> ReadResult {
        let session = try DWGReadSession(data: data)
        let dxf = Data(session.dxf())
        let report = session.report()
        do {
            return ReadResult(drawing: try DXFReader.read(data: dxf), report: report)
        } catch {
            throw DWGReadError.corrupt("the decoded drawing could not be converted (\(error.localizedDescription))")
        }
    }

    /// Decodes the DWG and returns the intermediate DXF bytes.
    static func convertToDXF(data: Data) throws -> Data {
        try Data(DWGReadSession(data: data).dxf())
    }

    /// Decodes the file and reports internal consistency statistics, including dropped entity types.
    public static func report(data: Data) throws -> Report {
        let session = try DWGReadSession(data: data)
        _ = session.dxf()
        return session.report()
    }
}

/// One decoding run: container, classes, header, all objects.
final class DWGReadSession {
    let file: DWGReadFile
    var decoder: DWGRDecoder
    let header: DWGRHeader
    let map: [UInt64: Int]
    let order: [UInt64]
    let mapCRCErrors: Int
    var objects: [UInt64: DWGRObject] = [:]
    /// Entity types the conversion could not carry into the drawing model; filled by `dxf()`.
    private(set) var dropped: [String: Int] = [:]

    init(data: Data) throws {
        guard data.count >= 6 else { throw DWGReadError.notDWG }
        let bytes = [UInt8](data)
        file = try DWGReadContainer.open(bytes)
        decoder = DWGRDecoder(file: file)
        decoder.readClasses()
        header = decoder.readHeader()
        (map, order, mapCRCErrors) = DWGRDecoder.objectMap(file.handles)
        guard !map.isEmpty else { throw DWGReadError.corrupt("the object map is empty") }
        decodeAll()
        guard objects.values.contains(where: { if case .blockHeader = $0.data { return true }; return false }) else {
            throw DWGReadError.corrupt("no block records could be decoded")
        }
    }

    /// Decodes every object in the map, in parallel chunks.
    func decodeAll() {
        let handles = order
        let n = handles.count
        let chunks = max(1, min(16, n / 2000))
        var results = [[DWGRObject]](repeating: [], count: chunks)
        let dec = decoder
        let map = self.map
        results.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * n / chunks, hi = (c + 1) * n / chunks
                var local: [DWGRObject] = []
                local.reserveCapacity(hi - lo)
                for k in lo..<hi {
                    let h = handles[k]
                    guard let off = map[h], let o = dec.decode(handle: h, at: off) else { continue }
                    local.append(o)
                }
                (base + c).initialize(to: local)
            }
        }
        objects.reserveCapacity(n)
        for list in results { for o in list { objects[o.handle] = o } }
    }

    /// Block records in a stable order: model space, paper spaces, then the others by handle.
    var blockHeaders: [DWGRObject] {
        objects.values.filter { if case .blockHeader = $0.data { return true }; return false }.sorted { $0.handle < $1.handle }
    }

    /// Entities of a block record, in drawing order.
    func entities(of b: DWGRObject, _ bh: DWGRBlockHeader, emitter: DWGRDXFEmitter) -> [DWGRObject] {
        if file.version >= .r2004 { return bh.entities.compactMap { objects[$0] }.filter(\.isEntity) }
        var list = emitter.chain(first: bh.firstEntity, last: bh.lastEntity).filter(\.isEntity)
        if list.isEmpty || (bh.lastEntity != 0 && list.last?.handle != bh.lastEntity) {
            // Fall back to ownership: block entities name their owner; model / paper space
            // entities are marked by their entity mode.
            let isModel = b.handle == header.modelSpace || bh.name.uppercased() == "*MODEL_SPACE"
            let isPaper = b.handle == header.paperSpace || bh.name.uppercased() == "*PAPER_SPACE"
            list = objects.values.filter { o in
                guard o.isEntity else { return false }
                if o.type == DWGObjectType.vertex2D || o.type == DWGObjectType.vertex3D || o.type == DWGObjectType.attrib
                    || o.type == DWGObjectType.seqend || o.type == DWGObjectType.block || o.type == DWGObjectType.endblk { return false }
                if o.entmode == 0 { return o.owner == b.handle }
                return (isModel && o.entmode == 2) || (isPaper && o.entmode == 1)
            }.sorted { $0.handle < $1.handle }
        }
        return list
    }

    func dxf() -> [UInt8] {
        var em = DWGRDXFEmitter(objects: objects, header: header, r2004: file.version >= .r2004)
        let sorted = objects.values.sorted { $0.handle < $1.handle }
        em.emitHeader(currentLayer: em.layerNames[header.clayer] ?? "0")
        em.emitTables(sorted)

        var model: DWGRObject?
        em.pair(0, "SECTION"); em.pair(2, "BLOCKS")
        for b in blockHeaders {
            guard case .blockHeader(let bh) = b.data else { continue }
            if b.handle == header.modelSpace || bh.name.uppercased() == "*MODEL_SPACE" {
                if model == nil { model = b }
                continue
            }
            var flags = 0
            if bh.anonymous { flags |= 1 }
            if bh.hasAttdefs { flags |= 2 }
            if bh.isXref { flags |= 4 }
            if bh.overlaid { flags |= 8 }
            if bh.xdep { flags |= 16 }
            em.pair(0, "BLOCK")
            em.pair(8, "0")
            let name = em.blockNames[b.handle] ?? bh.name
            em.pair(2, name)
            em.pair(70, flags)
            em.p3(10, bh.base)
            em.pair(3, name)
            var vpIndex = 0
            if !bh.isXref {
                for e in entities(of: b, bh, emitter: em) { em.entity(e, viewportIndex: &vpIndex) }
            }
            em.pair(0, "ENDBLK")
        }
        em.pair(0, "ENDSEC")

        em.pair(0, "SECTION"); em.pair(2, "ENTITIES")
        if let m = model, case .blockHeader(let bh) = m.data {
            var vpIndex = 0
            for e in entities(of: m, bh, emitter: em) where e.type != DWGObjectType.viewport {
                em.entity(e, viewportIndex: &vpIndex)
            }
        }
        em.pair(0, "ENDSEC")
        em.emitObjects(sorted)
        em.pair(0, "EOF")
        dropped = em.dropped
        return em.out
    }

    func report() -> NativeDWGReader.Report {
        var misaligned: [String: Int] = [:]
        var types: [String: Int] = [:]
        var crc = 0
        var unresolvedLayers = 0, unresolvedOwners = 0
        for o in objects.values {
            types[o.name, default: 0] += 1
            if !o.crcOK { crc += 1 }
            if o.slack < 0 || o.slack > 7 {
                switch o.data {
                case .none, .block: break
                default: misaligned[o.name, default: 0] += 1
                }
            }
            if o.isEntity && o.layer != 0 && objects[o.layer] == nil { unresolvedLayers += 1 }
            if o.owner != 0 && objects[o.owner] == nil { unresolvedOwners += 1 }
        }
        var unresolved = 0
        for h in order where objects[h] == nil { unresolved += 1 }
        let em = DWGRDXFEmitter(objects: objects, header: header, r2004: file.version >= .r2004)
        var modelCount = 0
        if let m = objects[header.modelSpace], case .blockHeader(let bh) = m.data {
            modelCount = entities(of: m, bh, emitter: em).count
        }
        return NativeDWGReader.Report(
            version: file.version.rawValue, objectCount: map.count, decodedCount: objects.count,
            unresolvedHandles: unresolved, checksumErrors: file.checksumErrors, crcErrors: crc + mapCRCErrors,
            misaligned: misaligned, typeCounts: types, modelEntityCount: modelCount,
            layerCount: em.layerNames.count, blockCount: em.blockNames.count,
            unresolvedLayers: unresolvedLayers, unresolvedOwners: unresolvedOwners, dropped: dropped)
    }
}
