import Foundation

/// Fixed DWG object type codes (Open Design Specification for .dwg files, 20.3).
/// Types >= 500 are class numbers looked up in AcDb:Classes.
public enum DWGObjectType {
    public static let unused = 0
    public static let text = 1
    public static let attrib = 2
    public static let attdef = 3
    public static let block = 4
    public static let endblk = 5
    public static let seqend = 6
    public static let insert = 7
    public static let minsert = 8
    public static let vertex2D = 0x0A
    public static let vertex3D = 0x0B
    public static let vertexMesh = 0x0C
    public static let vertexPFace = 0x0D
    public static let vertexPFaceFace = 0x0E
    public static let polyline2D = 0x0F
    public static let polyline3D = 0x10
    public static let arc = 0x11
    public static let circle = 0x12
    public static let line = 0x13
    public static let dimOrdinate = 0x14
    public static let dimLinear = 0x15
    public static let dimAligned = 0x16
    public static let dimAng3Pt = 0x17
    public static let dimAng2Ln = 0x18
    public static let dimRadius = 0x19
    public static let dimDiameter = 0x1A
    public static let point = 0x1B
    public static let face3D = 0x1C
    public static let polylinePFace = 0x1D
    public static let polylineMesh = 0x1E
    public static let solid = 0x1F
    public static let trace = 0x20
    public static let shape = 0x21
    public static let viewport = 0x22
    public static let ellipse = 0x23
    public static let spline = 0x24
    public static let region = 0x25
    public static let solid3D = 0x26
    public static let body = 0x27
    public static let ray = 0x28
    public static let xline = 0x29
    public static let dictionary = 0x2A
    public static let oleFrame = 0x2B
    public static let mtext = 0x2C
    public static let leader = 0x2D
    public static let tolerance = 0x2E
    public static let mline = 0x2F
    public static let blockControl = 0x30
    public static let blockHeader = 0x31
    public static let layerControl = 0x32
    public static let layer = 0x33
    public static let styleControl = 0x34
    public static let style = 0x35
    public static let ltypeControl = 0x38
    public static let ltype = 0x39
    public static let viewControl = 0x3C
    public static let view = 0x3D
    public static let ucsControl = 0x3E
    public static let ucs = 0x3F
    public static let vportControl = 0x40
    public static let vport = 0x41
    public static let appidControl = 0x42
    public static let appid = 0x43
    public static let dimstyleControl = 0x44
    public static let dimstyle = 0x45
    public static let vpEntHdrControl = 0x46
    public static let vpEntHdr = 0x47
    public static let group = 0x48
    public static let mlineStyle = 0x49
    public static let ole2Frame = 0x4A
    public static let dummy = 0x4B
    public static let longTransaction = 0x4C
    public static let lwpolyline = 0x4D
    public static let hatch = 0x4E
    public static let xrecord = 0x4F
    public static let placeholder = 0x50
    public static let vbaProject = 0x51
    public static let layout = 0x52
    public static let proxyEntity = 0x1F2
    public static let proxyObject = 0x1F3

    /// DXF names of the fixed types that CadMac converts or needs to know about.
    public static let names: [Int: String] = [
        text: "TEXT", attrib: "ATTRIB", attdef: "ATTDEF", block: "BLOCK", endblk: "ENDBLK", seqend: "SEQEND",
        insert: "INSERT", minsert: "MINSERT", vertex2D: "VERTEX", vertex3D: "VERTEX", vertexMesh: "VERTEX",
        vertexPFace: "VERTEX", vertexPFaceFace: "VERTEX", polyline2D: "POLYLINE", polyline3D: "POLYLINE",
        arc: "ARC", circle: "CIRCLE", line: "LINE", dimOrdinate: "DIMENSION", dimLinear: "DIMENSION",
        dimAligned: "DIMENSION", dimAng3Pt: "DIMENSION", dimAng2Ln: "DIMENSION", dimRadius: "DIMENSION",
        dimDiameter: "DIMENSION", point: "POINT", face3D: "3DFACE", polylinePFace: "POLYLINE",
        polylineMesh: "POLYLINE", solid: "SOLID", trace: "TRACE", shape: "SHAPE", viewport: "VIEWPORT",
        ellipse: "ELLIPSE", spline: "SPLINE", region: "REGION", solid3D: "3DSOLID", body: "BODY", ray: "RAY",
        xline: "XLINE", dictionary: "DICTIONARY", oleFrame: "OLEFRAME", mtext: "MTEXT", leader: "LEADER",
        tolerance: "TOLERANCE", mline: "MLINE", blockControl: "BLOCK_CONTROL", blockHeader: "BLOCK_RECORD",
        layerControl: "LAYER_CONTROL", layer: "LAYER", styleControl: "STYLE_CONTROL", style: "STYLE",
        ltypeControl: "LTYPE_CONTROL", ltype: "LTYPE", viewControl: "VIEW_CONTROL", view: "VIEW",
        ucsControl: "UCS_CONTROL", ucs: "UCS", vportControl: "VPORT_CONTROL", vport: "VPORT",
        appidControl: "APPID_CONTROL", appid: "APPID", dimstyleControl: "DIMSTYLE_CONTROL", dimstyle: "DIMSTYLE",
        vpEntHdrControl: "VP_ENT_HDR_CONTROL", vpEntHdr: "VP_ENT_HDR", group: "GROUP", mlineStyle: "MLINESTYLE",
        ole2Frame: "OLE2FRAME", dummy: "DUMMY", longTransaction: "LONG_TRANSACTION", lwpolyline: "LWPOLYLINE",
        hatch: "HATCH", xrecord: "XRECORD", placeholder: "ACDBPLACEHOLDER", vbaProject: "VBA_PROJECT",
        layout: "LAYOUT", proxyEntity: "ACAD_PROXY_ENTITY", proxyObject: "ACAD_PROXY_OBJECT",
    ]

    /// True for fixed type codes that are entities (graphical objects).
    public static func isEntity(_ t: Int) -> Bool {
        (t >= 1 && t <= 0x29) || t == 0x2B || (t >= 0x2C && t <= 0x2F) || t == 0x4A || t == 0x4D || t == 0x4E
            || t == proxyEntity
    }
}

/// DWG file versions (first six bytes of the file).
public enum DWGVersion: String, CaseIterable, Comparable {
    case r13 = "AC1012", r14 = "AC1014", r2000 = "AC1015", r2004 = "AC1018"
    case r2007 = "AC1021", r2010 = "AC1024", r2013 = "AC1027", r2018 = "AC1032"

    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: DWGVersion, b: DWGVersion) -> Bool { a.order < b.order }

    public var displayName: String {
        switch self {
        case .r13: return "R13"
        case .r14: return "R14"
        case .r2000: return "AutoCAD 2000"
        case .r2004: return "AutoCAD 2004"
        case .r2007: return "AutoCAD 2007"
        case .r2010: return "AutoCAD 2010"
        case .r2013: return "AutoCAD 2013"
        case .r2018: return "AutoCAD 2018"
        }
    }
}

/// DWG lineweight index (entity RC / layer flags) to hundredths of a millimetre;
/// -1 ByLayer, -2 ByBlock, -3 Default.
func dwgReadLineweight(index i: Int) -> Int {
    let table = [0, 5, 9, 13, 15, 18, 20, 25, 30, 35, 40, 50, 53, 60, 70, 80, 90, 100, 106, 120, 140, 158, 200, 211]
    if i >= 0 && i < table.count { return table[i] }
    switch i {
    case 29: return -1
    case 30: return -2
    case 31: return -3
    default: return -1
    }
}
