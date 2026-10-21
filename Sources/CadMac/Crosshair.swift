import Foundation
import CadCore

enum CrosshairStyle: String, CaseIterable {
    case solid, dashed, dotted

    var title: String {
        switch self {
        case .solid: return "Solid"
        case .dashed: return "Dashed"
        case .dotted: return "Dotted"
        }
    }

    /// Dash pattern in view points (empty = solid).
    var dash: [CGFloat] {
        switch self {
        case .solid: return []
        case .dashed: return [8, 5]
        case .dotted: return [1.5, 3.5]
        }
    }
}

/// App-wide crosshair settings (the horizontal/vertical lines that follow the cursor).
enum CrosshairPrefs {
    /// Long lines on/off. Off leaves a small cross at the cursor.
    static var visible: Bool {
        get { UserDefaults.standard.object(forKey: "CrosshairVisible") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "CrosshairVisible") }
    }

    static var style: CrosshairStyle {
        get { CrosshairStyle(rawValue: UserDefaults.standard.string(forKey: "CrosshairStyle") ?? "") ?? .solid }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "CrosshairStyle") }
    }

    /// Line length as a percent of the canvas (100 = edge to edge), like AutoCAD's CURSORSIZE.
    static var size: Double {
        get { UserDefaults.standard.object(forKey: "CrosshairSize") as? Double ?? 100 }
        set { UserDefaults.standard.set(min(max(newValue, 1), 100), forKey: "CrosshairSize") }
    }
}

/// CROSSHAIR: turns the crosshair lines on/off and sets their style and size.
final class CrosshairCommand: CadCommand {
    private var askingSize = false

    override func start() {
        keepsSelection = true
        let cur = "\(CrosshairPrefs.visible ? "ON" : "OFF"), \(CrosshairPrefs.style.title), \(fmt(CrosshairPrefs.size))%"
        ask("Enter crosshair option <\(cur)>", .text, keywords: ["ON", "OFF", "soLid", "Dashed", "dOtted", "Size"])
    }

    override func keyword(_ k: String) {
        switch k {
        case "ON": CrosshairPrefs.visible = true
        case "OFF": CrosshairPrefs.visible = false
        case "soLid": CrosshairPrefs.style = .solid; CrosshairPrefs.visible = true
        case "Dashed": CrosshairPrefs.style = .dashed; CrosshairPrefs.visible = true
        case "dOtted": CrosshairPrefs.style = .dotted; CrosshairPrefs.visible = true
        case "Size":
            askingSize = true
            ask("Crosshair size in percent of the screen (100 = full) <\(fmt(CrosshairPrefs.size))>", .text)
            return
        default: return
        }
        done()
    }

    override func value(_ s: String) -> Bool {
        guard askingSize else { return false }
        guard let v = Double(s.replacingOccurrences(of: ",", with: ".")), v >= 1, v <= 100 else { return false }
        CrosshairPrefs.size = v
        CrosshairPrefs.visible = true
        done()
        return true
    }

    private func done() {
        c.message("Crosshair: \(CrosshairPrefs.visible ? "on" : "off"), \(CrosshairPrefs.style.title), \(fmt(CrosshairPrefs.size))%")
        c.delegate?.needsRedraw(drawingChanged: false)
        finish()
    }
}
