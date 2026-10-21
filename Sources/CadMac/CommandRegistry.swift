import AppKit
import CadCore

struct CommandInfo {
    let name: String
    let aliases: [String]
    let summary: String
    let factory: (CommandController) -> CadCommand
}

@MainActor
enum CommandRegistry {
    static let all: [CommandInfo] = build()

    private static func info(_ name: String, _ aliases: [String], _ summary: String, _ f: @escaping (CommandController, String) -> CadCommand) -> CommandInfo {
        CommandInfo(name: name, aliases: aliases, summary: summary) { f($0, name) }
    }

    private static func action(_ name: String, _ aliases: [String], _ summary: String, keep: Bool = false, _ body: @escaping (CommandController) -> Void) -> CommandInfo {
        CommandInfo(name: name, aliases: aliases, summary: summary) { ActionCommand($0, name: name, keepSelection: keep, body) }
    }

    private static func build() -> [CommandInfo] {
        [
            // Draw
            info("LINE", ["L"], "Creates straight line segments", { LineCommand($0, name: $1) }),
            info("PLINE", ["PL"], "Creates a 2D polyline", { PolylineCommand($0, name: $1) }),
            info("RECTANG", ["REC", "RECTANGLE"], "Creates a rectangular polyline", { RectangleCommand($0, name: $1) }),
            info("CIRCLE", ["C"], "Creates a circle", { CircleCommand($0, name: $1) }),
            info("ARC", ["A"], "Creates an arc", { ArcCommand($0, name: $1) }),
            info("ELLIPSE", ["EL"], "Creates an ellipse", { EllipseCommand($0, name: $1) }),
            info("POLYGON", ["POL"], "Creates an equilateral closed polyline", { PolygonCommand($0, name: $1) }),
            info("POINT", ["PO"], "Creates a point object", { PointCommand($0, name: $1) }),
            info("SPLINE", ["SPL"], "Creates a smooth curve through points", { SplineCommand($0, name: $1) }),
            info("DONUT", ["DO"], "Creates a filled ring", { DonutCommand($0, name: $1) }),
            info("XLINE", ["XL"], "Creates a construction line", { ConstructionLineCommand($0, name: $1, ray: false) }),
            info("RAY", [], "Creates a ray", { ConstructionLineCommand($0, name: $1, ray: true) }),
            info("REVCLOUD", [], "Creates a revision cloud", { RevcloudCommand($0, name: $1) }),
            info("HATCH", ["H", "BH"], "Fills an enclosed area with a hatch pattern", { HatchCommand($0, name: $1) }),
            info("TEXT", ["DT", "DTEXT"], "Creates single-line text", { TextCommand($0, name: $1) }),
            info("MTEXT", ["T", "MT"], "Creates multiline text", { MTextCommand($0, name: $1) }),
            // Modify
            info("ERASE", ["E"], "Removes objects", { EraseCommand($0, name: $1) }),
            info("MOVE", ["M"], "Moves objects", { MoveCommand($0, name: $1, copy: false) }),
            info("COPY", ["CO", "CP"], "Copies objects", { MoveCommand($0, name: $1, copy: true) }),
            info("ROTATE", ["RO"], "Rotates objects around a base point", { RotateCommand($0, name: $1) }),
            info("SCALE", ["SC"], "Scales objects", { ScaleCommand($0, name: $1) }),
            info("MIRROR", ["MI"], "Creates a mirrored copy", { MirrorCommand($0, name: $1) }),
            info("STRETCH", ["S"], "Stretches objects crossed by a window", { StretchCommand($0, name: $1) }),
            info("OFFSET", ["O"], "Creates parallel copies", { OffsetCommand($0, name: $1) }),
            info("TRIM", ["TR"], "Trims objects to meet edges", { TrimExtendCommand($0, name: $1, extend: false) }),
            info("EXTEND", ["EX"], "Extends objects to meet edges", { TrimExtendCommand($0, name: $1, extend: true) }),
            info("FILLET", ["F"], "Rounds the corner between two objects", { FilletChamferCommand($0, name: $1, chamfer: false) }),
            info("CHAMFER", ["CHA"], "Bevels the corner between two lines", { FilletChamferCommand($0, name: $1, chamfer: true) }),
            info("BREAK", ["BR"], "Breaks an object between two points", { BreakCommand($0, name: $1) }),
            info("JOIN", ["J"], "Joins objects into one", { JoinCommand($0, name: $1) }),
            info("EXPLODE", ["X"], "Breaks a compound object into its parts", { ExplodeCommand($0, name: $1) }),
            info("LENGTHEN", ["LEN"], "Changes the length of objects", { LengthenCommand($0, name: $1) }),
            info("ARRAY", ["AR"], "Creates copies in a pattern", { ArrayCommand($0, name: $1, kind: .ask) }),
            info("ARRAYRECT", [], "Rectangular array", { ArrayCommand($0, name: $1, kind: .rectangular) }),
            info("ARRAYPOLAR", [], "Polar array", { ArrayCommand($0, name: $1, kind: .polar) }),
            info("ARRAYPATH", [], "Path array", { ArrayCommand($0, name: $1, kind: .path) }),
            info("MATCHPROP", ["MA", "PAINTER"], "Copies properties from one object to others", { MatchPropCommand($0, name: $1) }),
            info("DIVIDE", ["DIV"], "Places points at equal intervals", { DivideMeasureCommand($0, name: $1, measure: false) }),
            info("MEASURE", ["ME"], "Places points at measured intervals", { DivideMeasureCommand($0, name: $1, measure: true) }),
            // Annotate
            info("DIMLINEAR", ["DLI", "DIMLIN"], "Creates a linear dimension", { DimLinearCommand($0, name: $1, aligned: false) }),
            info("DIMALIGNED", ["DAL", "DIMALI"], "Creates an aligned dimension", { DimLinearCommand($0, name: $1, aligned: true) }),
            info("DIMRADIUS", ["DRA", "DIMRAD"], "Creates a radius dimension", { DimRadialCommand($0, name: $1, diameter: false) }),
            info("DIMDIAMETER", ["DDI", "DIMDIA"], "Creates a diameter dimension", { DimRadialCommand($0, name: $1, diameter: true) }),
            info("DIMANGULAR", ["DAN", "DIMANG"], "Creates an angular dimension", { DimAngularCommand($0, name: $1) }),
            info("DIMCONTINUE", ["DCO", "DIMCONT"], "Continues a linear dimension", { DimContinueCommand($0, name: $1, baseline: false) }),
            info("DIMBASELINE", ["DBA", "DIMBASE"], "Creates baseline dimensions", { DimContinueCommand($0, name: $1, baseline: true) }),
            info("QLEADER", ["LE", "LEADER", "MLEADER", "MLD"], "Creates a leader with text", { LeaderCommand($0, name: $1) }),
            // Blocks
            info("BLOCK", ["B"], "Creates a block definition from objects", { BlockCommand($0, name: $1) }),
            info("INSERT", ["I"], "Inserts a block", { InsertCommand($0, name: $1) }),
            info("LAYOUT", ["LO"], "Creates, renames, deletes or switches layouts", { LayoutCommand($0, name: $1) }),
            info("MVIEW", ["MV"], "Creates a viewport in a layout", { MViewCommand($0, name: $1) }),
            action("MODEL", [], "Switches to the Model tab", keep: true) { $0.delegate?.layout(.set(nil)) },
            action("COMMANDLINE", ["CLI"], "Shows the command line", keep: true) { $0.delegate?.setCommandLineVisible(true) },
            action("COMMANDLINEHIDE", ["CLIHIDE"], "Hides the command line (input appears at the cursor)", keep: true) { $0.delegate?.setCommandLineVisible(false) },
            action("PAGESETUP", [], "Sets the paper size of the current layout", keep: true) { $0.delegate?.layout(.pageSetup) },
            info("BEDIT", ["BE", "REFEDIT"], "Opens a block definition in the Block Editor", { BlockEditCommand($0, name: $1) }),
            action("BSAVE", [], "Saves the block being edited", keep: true) { $0.delegate?.blockEditor(.save) },
            action("BCLOSE", [], "Closes the Block Editor", keep: true) { $0.delegate?.blockEditor(.close) },
            // Inquiry
            info("DIST", ["DI"], "Measures distance and angle", { DistCommand($0, name: $1) }),
            info("AREA", ["AA"], "Calculates area and perimeter", { AreaCommand($0, name: $1) }),
            info("ID", [], "Displays point coordinates", { IdCommand($0, name: $1) }),
            info("UNITS", ["UN", "INSUNITS"], "Sets the drawing units (mm, cm, m, inch, feet)", { UnitsCommand($0, name: $1) }),
            info("LIST", ["LI", "LS"], "Displays object properties", { ListCommand($0, name: $1) }),
            // View
            info("ZOOM", ["Z"], "Zooms the view", { ZoomCommand($0, name: $1) }),
            action("REGEN", ["RE", "REGENALL", "REA", "REDRAW", "R"], "Regenerates the display", keep: true) { $0.delegate?.needsRedraw(drawingChanged: true) },
            action("PAN", ["P"], "Pan: use two-finger scroll, middle mouse or Space+drag", keep: true) { $0.message("Pan with two-finger scroll or middle mouse drag. Zoom with pinch or mouse wheel.") },
            // Layers
            action("LAYER", ["LA"], "Opens the Layer Properties panel", keep: true) { $0.delegate?.showPanel("layers") },
            action("TEXTFONT", ["TF"], "Choose the font for new text", keep: true) { $0.delegate?.runModal(.textFont) },
            action("CHAT", ["CLAUDE", "ASK"], "Open the Claude chat panel", keep: true) { $0.delegate?.runModal(.chat) },
            info("LAYOFF", [], "Turns off the layer of a selected object", { LayerPickCommand($0, name: $1, action: .off) }),
            info("LAYFRZ", [], "Freezes the layer of a selected object", { LayerPickCommand($0, name: $1, action: .freeze) }),
            info("LAYLCK", [], "Locks the layer of a selected object", { LayerPickCommand($0, name: $1, action: .lock) }),
            info("LAYULK", [], "Unlocks the layer of a selected object", { LayerPickCommand($0, name: $1, action: .unlock) }),
            info("LAYMCUR", [], "Makes the layer of a selected object current", { LayerPickCommand($0, name: $1, action: .makeCurrent) }),
            info("LAYISO", [], "Isolates the layer of a selected object", { LayerPickCommand($0, name: $1, action: .isolate) }),
            action("LAYON", ["LAYUNISO"], "Turns on all layers") { c in c.perform("Layers On") { d in for i in d.layers.indices { d.layers[i].isOn = true } } },
            action("LAYTHW", [], "Thaws all layers") { c in c.perform("Layers Thaw") { d in for i in d.layers.indices { d.layers[i].isFrozen = false } } },
            // Properties
            action("PROPERTIES", ["PR", "CH", "MO", "PROPS"], "Opens the Properties inspector", keep: true) { $0.delegate?.showPanel("properties") },
            // Utilities
            action("UNDO", ["U"], "Reverses the last action") { $0.undo() },
            action("REDO", ["MREDO"], "Reverses the last undo") { $0.redo() },
            action("PURGE", ["PU"], "Removes unused layers, blocks and linetypes") { c in
                var n = 0
                c.perform("Purge") { n = $0.purge() }
                c.message("\(n) unused item(s) purged")
            },
            action("SELECTALL", ["AI_SELALL"], "Selects all objects", keep: true) { $0.selectAll() },
            action("COPYCLIP", [], "Copies objects to the clipboard", keep: true) { c in copyToClipboard(c) },
            action("CUTCLIP", [], "Cuts objects to the clipboard") { c in copyToClipboard(c); c.eraseSelection() },
            info("PASTECLIP", [], "Pastes objects from the clipboard", { PasteCommand($0, name: $1) }),
            action("ORTHO", [], "Toggles orthogonal mode", keep: true) { c in c.orthoOn.toggle(); c.message("<Ortho \(c.orthoOn ? "on" : "off")>") },
            action("GRID", [], "Toggles grid display", keep: true) { c in c.gridOn.toggle(); c.message("<Grid \(c.gridOn ? "on" : "off")>") },
            action("SNAP", ["SN"], "Toggles snap mode", keep: true) { c in c.snapOn.toggle(); c.message("<Snap \(c.snapOn ? "on" : "off")>") },
            action("OSNAP", ["OS", "DSETTINGS", "DS"], "Object snap settings", keep: true) { $0.delegate?.runModal(.osnapSettings) },
            action("PLOT", ["PRINT"], "Prints the drawing", keep: true) { $0.delegate?.runModal(.print) },
            action("EXPORTPDF", ["PDF"], "Exports the drawing to PDF", keep: true) { $0.delegate?.runModal(.exportPDF) },
            action("PUBLISH", ["PUB"], "Publishes all layouts to one multi-page PDF", keep: true) { $0.delegate?.runModal(.publish) },
            info("SETVAR", ["SET"], "Changes a system variable", { SetvarCommand($0, name: $1) }),
            info("SAVETIME", [], "Sets the automatic backup interval in minutes (0 = off)", { SaveTimeCommand($0, name: $1) }),
            action("HELP", ["?", "F1"], "Opens the user guide", keep: true) { _ in HelpWindowController.shared.show() },
            action("COMMANDS", [], "Lists available commands in the command line", keep: true) { c in
                for i in CommandRegistry.all {
                    let alias = i.aliases.isEmpty ? "" : " (\(i.aliases.joined(separator: ", ")))"
                    c.message("\(i.name)\(alias) — \(i.summary)")
                }
            },
        ] + AttributeCommands.all + ToolCommands.all + SetvarCommand.variables.keys.sorted().map { v in
            info(v, [], "System variable \(v)", { SetvarCommand($0, name: $1, variable: v) })
        }
    }

    private static func copyToClipboard(_ c: CommandController) {
        let ents = c.drawing.entities.filter { c.selection.contains($0.id) }
        guard !ents.isEmpty else { c.message("Nothing selected"); return }
        CadClipboard.entities = ents
        CadClipboard.blocks = c.drawing.blocks
        CadClipboard.base = c.drawing.extents(of: ents).min
        c.message("\(ents.count) object(s) copied")
    }

    static func lookup(_ name: String) -> CommandInfo? {
        let n = name.uppercased()
        return all.first { $0.name == n } ?? all.first { $0.aliases.contains(n) }
    }

    static func make(_ name: String, _ c: CommandController) -> CadCommand? {
        lookup(name)?.factory(c)
    }

    /// Commands that can run inside another command ('ZOOM etc.).
    static func transparent(_ name: String, _ c: CommandController) -> (() -> Void)? {
        switch lookup(name)?.name {
        case "ZOOM": return { c.delegate?.zoom(.extents) }
        case "ORTHO": return { c.orthoOn.toggle() }
        case "GRID": return { c.gridOn.toggle() }
        case "SNAP": return { c.snapOn.toggle() }
        case "DIST": return { c.message("DIST is not transparent in this version") }
        default: return nil
        }
    }

    /// Autocomplete candidates for a partial command name.
    static func suggestions(for prefix: String, limit: Int = 8) -> [CommandInfo] {
        let p = prefix.uppercased()
        guard !p.isEmpty else { return [] }
        let exactAlias = all.filter { $0.aliases.contains(p) }
        let starts = all.filter { info in info.name.hasPrefix(p) && !exactAlias.contains(where: { $0.name == info.name }) }
        return Array((exactAlias + starts).prefix(limit))
    }
}
