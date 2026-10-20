import AppKit
import CadCore
import UniformTypeIdentifiers

extension UTType {
    static let dxf = UTType(importedAs: "com.autodesk.dxf", conformingTo: .data)
    static let dwg = UTType(importedAs: "com.autodesk.dwg", conformingTo: .data)
}

@objc(CadDocument)
final class CadDocument: NSDocument {
    let history = DrawingHistory()
    /// Identifies this document's automatic backup file.
    let autosaveID = UUID()
    /// History version at the last backup (or save).
    var backupVersion = 0
    /// Title used for drawings restored from a backup.
    var recoveredName: String?
    /// Statistics of the DWG read that produced this document, nil for DXF and new drawings.
    private(set) var importReport: NativeDWGReader.Report?

    var needsBackup: Bool { isDocumentEdited && history.version != backupVersion }

    override var displayName: String! {
        get { fileURL == nil ? (recoveredName ?? super.displayName) : super.displayName }
        set { super.displayName = newValue }
    }

    override init() {
        super.init()
        hasUndoManager = false
    }

    override class var autosavesInPlace: Bool { false }
    /// AutoCAD declares its own DWG type on Macs where it is installed.
    static let autocadDWG = "com.autodesk.autocad.dwg"
    /// Our declared DWG type. Note `UTType(importedAs:)` may resolve to AutoCAD's type on Macs
    /// where AutoCAD is installed, so DWG is recognised by both identifiers explicitly.
    static let cadmacDWG = "com.autodesk.dwg"
    static func isDWG(_ type: String) -> Bool {
        type == cadmacDWG || type == autocadDWG || UTType(type)?.preferredFilenameExtension == "dwg"
    }

    /// AutoCAD drawing templates are DWG files too (opened read-only; saving goes through Save As).
    static let dwtTypes = ["com.autodesk.dwt", "com.autodesk.autocad.dwt"]
    override class var readableTypes: [String] { [UTType.dxf.identifier, UTType.dwg.identifier, autocadDWG] + dwtTypes }
    override class var writableTypes: [String] { [UTType.dxf.identifier, UTType.dwg.identifier] }
    /// DWG counts as native too (otherwise AppKit turns every ⌘S on a DWG into Save As);
    /// the first save of a DWG opened from disk is still routed to Save As by `save(_:)`.
    override class func isNativeType(_ type: String) -> Bool {
        type == UTType.dxf.identifier || (isDWG(type) && DWGExporter.isAvailable)
    }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        var types = DWGExporter.isAvailable ? [UTType.dxf.identifier, UTType.dwg.identifier] : [UTType.dxf.identifier]
        // A .dwg opened on a Mac with AutoCAD installed carries AutoCAD's own type id; it must count as
        // writable or AppKit disables Save (⌘S) for the document.
        if saveOperation == .saveOperation, let ft = fileType, CadDocument.isDWG(ft), !types.contains(ft) { types.append(ft) }
        return types
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(save(_:)) || item.action == #selector(saveAs(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        CadDocument.isDWG(typeName) ? "dwg" : "dxf"
    }

    /// The current .dwg file was written by CadMac in this session, so ⌘S may overwrite it.
    private(set) var ownsDWGFile = false

    override func write(to url: URL, ofType typeName: String) throws {
        // The file extension decides the format, so a .dwg never contains DXF text (and vice versa).
        let ext = url.pathExtension.lowercased()
        if ext == "dwg" || (ext != "dxf" && CadDocument.isDWG(typeName)) {
            try DWGExporter.write(history.drawing, to: url)
        } else {
            try super.write(to: url, ofType: typeName)
        }
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if error == nil, let self {
                if CadDocument.isDWG(typeName), saveOperation != .saveToOperation { self.ownsDWGFile = true }
                if !CadDocument.isDWG(typeName), saveOperation != .saveToOperation { self.ownsDWGFile = false }
                self.backupVersion = self.history.version
                AutoSaveManager.shared.discard(self.autosaveID)
            }
            completionHandler(error)
        }
    }

    override func close() {
        AutoSaveManager.shared.discard(autosaveID)
        super.close()
    }

    override func makeWindowControllers() {
        let wc = CadWindowController(history: history, importReport: importReport)
        addWindowController(wc)
        // Once the window is on screen, say what the DWG read could not carry in.
        if importReport != nil { DispatchQueue.main.async { wc.announceImport() } }
    }

    // MARK: Reading

    override func read(from url: URL, ofType typeName: String) throws {
        let drawing: Drawing
        // Decide by content, not extension: real DWG files start with "AC10…"; DXF is text.
        let head = (try? FileHandle(forReadingFrom: url).read(upToCount: 6)) ?? nil
        let looksLikeDWG = head.map { $0.count >= 4 && $0.prefix(4) == Data("AC10".utf8) } ?? false
        let looksLikeText = head.map { $0.allSatisfy { $0 == 9 || $0 == 10 || $0 == 13 || ($0 >= 32 && $0 < 127) } } ?? false
        if looksLikeDWG || (!looksLikeText && (CadDocument.isDWG(typeName) || url.pathExtension.lowercased() == "dwg")) {
            // CadMac's own DWG reader (AutoCAD 2000–2018 formats); no external converter.
            let r = try NativeDWGReader.readResult(url: url)
            drawing = r.drawing
            importReport = r.report
        } else {
            drawing = try DXFReader.read(data: try Data(contentsOf: url))
        }
        history.reset(drawing)
    }

    /// A DWG opened from disk may contain objects CadMac doesn't keep (MLEADER, images, 3D…),
    /// so ⌘S never silently overwrites it: the first save goes through Save As.
    override func save(_ sender: Any?) {
        let isDWGFile = fileURL?.pathExtension.lowercased() == "dwg" || CadDocument.isDWG(fileType ?? "")
        if isDWGFile && !ownsDWGFile {
            saveAs(sender)
        } else {
            super.save(sender)
        }
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.isExtensionHidden = false
        savePanel.message = Loc.t("Choose DXF or DWG under File Format. DWG is written by CadMac in AutoCAD 2000 format: true colors become the nearest indexed color and objects CadMac cannot hold are left out. Keep a copy of important originals.")
        return true
    }

    // MARK: Writing

    override func data(ofType typeName: String) throws -> Data {
        let text = DXFWriter.write(history.drawing)
        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: "CadMac", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode DXF"])
        }
        return data
    }
}
