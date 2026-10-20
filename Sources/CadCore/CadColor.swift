import Foundation

public struct RGB: Hashable, Codable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }

    /// 24-bit value as used by DXF group code 420.
    public var packed: Int { Int(r) << 16 | Int(g) << 8 | Int(b) }
    public init(packed: Int) {
        self.init(UInt8((packed >> 16) & 0xFF), UInt8((packed >> 8) & 0xFF), UInt8(packed & 0xFF))
    }
}

/// Entity or layer color. Index 7 renders white on dark backgrounds and black on light ones.
public enum CadColor: Hashable, Codable {
    case byLayer
    case byBlock
    case aci(Int)
    case rgb(RGB)

    public static let white = CadColor.aci(7)

    public var displayName: String {
        switch self {
        case .byLayer: return "ByLayer"
        case .byBlock: return "ByBlock"
        case .aci(let i):
            switch i {
            case 1: return "Red"
            case 2: return "Yellow"
            case 3: return "Green"
            case 4: return "Cyan"
            case 5: return "Blue"
            case 6: return "Magenta"
            case 7: return "White"
            default: return "Color \(i)"
            }
        case .rgb(let c): return "\(c.r),\(c.g),\(c.b)"
        }
    }

    /// Resolved RGB, ignoring ByLayer/ByBlock (caller resolves those first).
    public func rgb(darkBackground: Bool = true) -> RGB {
        switch self {
        case .byLayer, .byBlock: return darkBackground ? RGB(255, 255, 255) : RGB(0, 0, 0)
        case .rgb(let c): return c
        case .aci(let i):
            if i == 7 { return darkBackground ? RGB(255, 255, 255) : RGB(0, 0, 0) }
            return aciToRGB(i)
        }
    }
}

/// Approximation of the AutoCAD Color Index palette.
public func aciToRGB(_ index: Int) -> RGB {
    switch index {
    case 1: return RGB(255, 0, 0)
    case 2: return RGB(255, 255, 0)
    case 3: return RGB(0, 255, 0)
    case 4: return RGB(0, 255, 255)
    case 5: return RGB(0, 0, 255)
    case 6: return RGB(255, 0, 255)
    case 7: return RGB(255, 255, 255)
    case 8: return RGB(128, 128, 128)
    case 9: return RGB(192, 192, 192)
    case 10...249:
        let hue = Double((index - 10) / 10) * 15.0
        let variant = index % 10
        let values: [Double] = [1.0, 0.65, 0.5, 0.3, 0.15]
        let v = values[variant / 2]
        let s = variant % 2 == 0 ? 1.0 : 0.5
        return hsvToRGB(h: hue, s: s, v: v)
    case 250...255:
        let g: [UInt8] = [51, 91, 132, 173, 214, 255]
        let x = g[index - 250]
        return RGB(x, x, x)
    default:
        return RGB(255, 255, 255)
    }
}

/// Nearest ACI index for an RGB value (used when only an index can be stored).
public func nearestACI(_ c: RGB) -> Int {
    var best = 7, bestD = Int.max
    for i in 1...255 where i != 7 {
        let p = aciToRGB(i)
        let d = (Int(p.r) - Int(c.r)) * (Int(p.r) - Int(c.r)) + (Int(p.g) - Int(c.g)) * (Int(p.g) - Int(c.g)) + (Int(p.b) - Int(c.b)) * (Int(p.b) - Int(c.b))
        if d < bestD { bestD = d; best = i }
    }
    if c == RGB(255, 255, 255) || c == RGB(0, 0, 0) { return 7 }
    return best
}

func hsvToRGB(h: Double, s: Double, v: Double) -> RGB {
    let c = v * s
    let hp = h / 60.0
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    var r = 0.0, g = 0.0, b = 0.0
    switch hp {
    case 0..<1: (r, g, b) = (c, x, 0)
    case 1..<2: (r, g, b) = (x, c, 0)
    case 2..<3: (r, g, b) = (0, c, x)
    case 3..<4: (r, g, b) = (0, x, c)
    case 4..<5: (r, g, b) = (x, 0, c)
    default: (r, g, b) = (c, 0, x)
    }
    let m = v - c
    func u(_ f: Double) -> UInt8 { UInt8(max(0, min(255, ((f + m) * 255).rounded()))) }
    return RGB(u(r), u(g), u(b))
}
