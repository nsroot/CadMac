import AppKit
import CadCore

/// Periodic background backups of edited drawings and crash recovery on the next launch.
@MainActor
final class AutoSaveManager {
    static let shared = AutoSaveManager()

    /// Minutes between automatic saves (AutoCAD SAVETIME); 0 disables.
    var interval: Double {
        get { UserDefaults.standard.object(forKey: "AutoSaveMinutes") as? Double ?? 5 }
        set { UserDefaults.standard.set(max(0, newValue), forKey: "AutoSaveMinutes"); restartTimer() }
    }

    private var timer: Timer?
    private let queue = DispatchQueue(label: "cadmac.autosave", qos: .utility)

    struct Info: Codable {
        var displayName: String
        var originalPath: String?
        var date: Date
    }

    static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["CADMAC_AUTOSAVE_DIR"] { return URL(fileURLWithPath: custom, isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CadMac/AutoSave", isDirectory: true)
    }

    func start() {
        try? FileManager.default.createDirectory(at: AutoSaveManager.directory, withIntermediateDirectories: true)
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        guard interval > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval * 60, repeats: true) { _ in
            MainActor.assumeIsolated { AutoSaveManager.shared.saveAll() }
        }
    }

    /// Backs up every document changed since its last backup.
    func saveAll() {
        for case let doc as CadDocument in NSDocumentController.shared.documents where doc.needsBackup {
            backup(doc)
        }
    }

    func backup(_ doc: CadDocument) {
        let drawing = doc.history.drawing
        let id = doc.autosaveID
        let info = Info(displayName: doc.displayName, originalPath: doc.fileURL?.path, date: Date())
        doc.backupVersion = doc.history.version
        queue.async {
            let dir = AutoSaveManager.directory
            let dxf = dir.appendingPathComponent("\(id).dxf")
            let meta = dir.appendingPathComponent("\(id).json")
            do {
                try DXFWriter.write(drawing).data(using: .utf8)?.write(to: dxf, options: .atomic)
                try JSONEncoder().encode(info).write(to: meta, options: .atomic)
            } catch {
                NSLog("CadMac autosave failed: \(error)")
            }
        }
    }

    /// Removes a document's backup after a normal save or close.
    func discard(_ id: UUID) {
        queue.async {
            let dir = AutoSaveManager.directory
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).dxf"))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
        }
    }

    /// Backups left behind by a crash or forced quit, newest first.
    func leftovers() -> [(URL, Info)] {
        let dir = AutoSaveManager.directory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { meta in
            guard let data = try? Data(contentsOf: meta), let info = try? JSONDecoder().decode(Info.self, from: data) else { return nil }
            let dxf = meta.deletingPathExtension().appendingPathExtension("dxf")
            return FileManager.default.fileExists(atPath: dxf.path) ? (dxf, info) : nil
        }.sorted { $0.1.date > $1.1.date }
    }

    /// Offers to reopen drawings that were not saved before the app ended unexpectedly.
    func offerRecovery() {
        let items = leftovers()
        guard !items.isEmpty else { return }
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        let alert = NSAlert()
        alert.messageText = "Recover unsaved drawings?"
        alert.informativeText = "CadMac did not close normally. Automatic backups were found:\n\n"
            + items.map { "• \($0.1.displayName) — \(df.string(from: $0.1.date))" }.joined(separator: "\n")
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Delete Backups")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for (url, info) in items { recover(url, info) }
        case .alertSecondButtonReturn:
            for (url, _) in items {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("json"))
            }
        default:
            break
        }
    }

    private func recover(_ url: URL, _ info: Info) {
        do {
            let drawing = try DXFReader.read(data: try Data(contentsOf: url))
            let doc = CadDocument()
            doc.history.reset(drawing)
            doc.recoveredName = "\((info.displayName as NSString).deletingPathExtension) (Recovered)"
            NSDocumentController.shared.addDocument(doc)
            doc.makeWindowControllers()
            doc.showWindows()
            doc.updateChangeCount(.changeDone)
            // The new document gets its own backup; the old one is no longer needed.
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("json"))
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
