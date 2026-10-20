import Foundation

// MARK: - ALIGN

/// Transform used by ALIGN.
/// - One pair: translation `src1 → dst1`.
/// - Two pairs: rotation about `src1` so `src1→src2` points along `dst1→dst2`, optional uniform
///   scale `|dst2-dst1| / |src2-src1|`, then translation `src1 → dst1`.
public func alignTransform(source src1: Vec2, destination dst1: Vec2,
                           source2 src2: Vec2? = nil, destination2 dst2: Vec2? = nil,
                           scale: Bool = false) -> Transform2D {
    guard let s2 = src2, let d2 = dst2 else { return .translation(dst1 - src1) }
    let sv = s2 - src1, dv = d2 - dst1
    guard sv.length > geomEps, dv.length > geomEps else { return .translation(dst1 - src1) }
    var t = Transform2D.rotation(dv.angle - sv.angle, about: src1)
    if scale { t = t.then(.scale(dv.length / sv.length, about: src1)) }
    return t.then(.translation(dst1 - src1))
}
