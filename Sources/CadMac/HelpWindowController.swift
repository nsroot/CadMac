import AppKit
import WebKit

/// Shows the bundled HTML user guide and fills its command table from the registry.
@MainActor
final class HelpWindowController: NSWindowController, WKNavigationDelegate {
    static let shared = HelpWindowController()

    private let webView: WKWebView

    private init() {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 780))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "CadMac Kullanım Kılavuzu"
        window.contentView = webView
        window.minSize = NSSize(width: 640, height: 400)
        window.setFrameAutosaveName("CadMacHelpWindow")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        webView.navigationDelegate = self
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The guide inside the app bundle, or the source tree when running unbundled (swift run).
    static var guideURL: URL? {
        if let u = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Help") { return u }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Support/Help/index.html").standardized
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    private func load() {
        if let url = HelpWindowController.guideURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.loadHTMLString("<h2 style='font-family:-apple-system'>Kılavuz dosyası bulunamadı (Help/index.html).</h2>", baseURL: nil)
        }
    }

    /// Opens the guide, optionally scrolled to a section anchor.
    func show(anchor: String? = nil) {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let anchor { webView.evaluateJavaScript("location.hash = '\(anchor)'") }
    }

    /// Test hook: writes a PNG of the rendered guide (optionally after a search query).
    func snapshot(to path: String, search: String?, completion: @escaping () -> Void) {
        if let a = ProcessInfo.processInfo.environment["CADMAC_HELPANCHOR"] { webView.evaluateJavaScript("location.hash='\(a)'") }
        if let q = search { webView.evaluateJavaScript("document.getElementById('cmdsearch').value='\(q)'; filterCommands('\(q)'); location.hash='komutlar'") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.webView.takeSnapshot(with: nil) { image, _ in
                if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                completion()
            }
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let list = CommandRegistry.all.map { ["name": $0.name, "aliases": $0.aliases, "summary": $0.summary] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: list),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("renderCommands(\(json))")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.allow); return }
        if url.scheme == "cadmac" {
            // cadmac://run/LINE starts the command in the frontmost drawing window.
            let cmd = url.lastPathComponent
            if let wc = NSApp.orderedWindows.compactMap({ $0.windowController as? CadWindowController }).first {
                wc.window?.makeKeyAndOrderFront(nil)
                wc.controller.run(cmd)
                wc.window?.makeFirstResponder(wc.canvas)
            }
            decisionHandler(.cancel)
            return
        }
        if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
