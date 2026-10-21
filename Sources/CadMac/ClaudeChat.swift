import AppKit
import CadCore

// MARK: - Settings

enum ChatPrefs {
    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: "AnthropicAPIKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "AnthropicAPIKey") }
    }
    static var model: String {
        get { UserDefaults.standard.string(forKey: "AnthropicModel") ?? "claude-sonnet-5-5" }
        set { UserDefaults.standard.set(newValue, forKey: "AnthropicModel") }
    }
}

// MARK: - Tool definitions (Anthropic format), bridged to CadMac's automation tools

enum ChatTools {
    /// The same tools the MCP server exposes, as Anthropic tool specs.
    static func specs() -> [[String: Any]] {
        func obj(_ p: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            var s: [String: Any] = ["type": "object", "properties": p]
            if !required.isEmpty { s["required"] = required }
            return s
        }
        let point: [String: Any] = ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2]
        let ids: [String: Any] = ["type": "array", "items": ["type": "string"]]
        let summary: [String: Any] = ["type": "string", "description": "One short sentence describing the change, shown to the user in the approval panel."]
        return [
            ["name": "get_drawing_info", "description": "Overview of the frontmost drawing: units, current layer, active space, extents, entity counts, layers, layouts, blocks. Call this first.", "input_schema": obj()],
            ["name": "list_entities", "description": "List entities of the active space with id, type, layer, geometry and bbox. Filter by layer/type/bbox; paginate with limit/offset.", "input_schema": obj(["layer": ["type": "string"], "type": ["type": "string"], "bbox": ["type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4], "inside_only": ["type": "boolean"], "limit": ["type": "integer"], "offset": ["type": "integer"]])],
            ["name": "get_selection", "description": "Entities currently selected by the user. Use for 'this'/'the selected'.", "input_schema": obj()],
            ["name": "measure", "description": "Distance/angle between two points and/or length/area/perimeter of an entity.", "input_schema": obj(["from": point, "to": point, "id": ["type": "string"]])],
            ["name": "find_closed_areas", "description": "Areas of closed regions. With 'point': the smallest closed boundary around it. Without: lists closed objects by area.", "input_schema": obj(["point": point, "layer": ["type": "string"], "limit": ["type": "integer"]])],
            ["name": "screenshot", "description": "PNG of the current drawing view (pending preview shown in purple). Optionally zoom to extents first.", "input_schema": obj(["zoom_extents": ["type": "boolean"], "max_width": ["type": "integer"]])],
            ["name": "zoom", "description": "Zoom the view: mode 'extents'|'window'|'all'. With 'window', pass bbox [minX,minY,maxX,maxY].", "input_schema": obj(["mode": ["type": "string"], "bbox": ["type": "array", "items": ["type": "number"]]])],
            ["name": "select_entities", "description": "Select entities by id (so the user sees them highlighted).", "input_schema": obj(["ids": ids], required: ["ids"])],
            ["name": "add_entities", "description": "Propose new entities (user must Apply). Each entity has 'type' and fields: line(start,end); polyline(points [[x,y]...],closed?,bulges?,width?); rectangle(corner1,corner2); circle(center,radius); arc(center,radius,start_angle,end_angle degrees CCW); text(position,text,height?,rotation?,align?,valign?); mtext(position,text,height?,width?); point(position); dimension_linear(p1,p2,dim_line_point,direction?); dimension_aligned(p1,p2,dim_line_point); hatch_solid(points [[x,y]...] or boundary_point [x,y]). Optional layer?,color?,linetype?. Points are [x,y] in drawing units.", "input_schema": obj(["summary": summary, "entities": ["type": "array", "items": ["type": "object", "properties": ["type": ["type": "string"]], "required": ["type"]]]], required: ["summary", "entities"])],
            ["name": "delete_entities", "description": "Propose deleting entities by id (user must Apply).", "input_schema": obj(["summary": summary, "ids": ids], required: ["summary", "ids"])],
            ["name": "modify_entities", "description": "Propose changes to entities: layer/color/linetype, replace text, and/or transform (scale then rotate then move). User must Apply.", "input_schema": obj(["summary": summary, "ids": ids, "layer": ["type": "string"], "color": ["type": "string"], "linetype": ["type": "string"], "text": ["type": "string"], "move": ["type": "object", "properties": ["dx": ["type": "number"], "dy": ["type": "number"]]], "rotate": ["type": "object", "properties": ["angle": ["type": "number"], "base": point]], "scale": ["type": "object", "properties": ["factor": ["type": "number"], "base": point]]], required: ["summary", "ids"])],
            ["name": "create_layer", "description": "Propose creating/updating a layer (user must Apply).", "input_schema": obj(["summary": summary, "name": ["type": "string"], "color": ["type": "string"], "linetype": ["type": "string"], "make_current": ["type": "boolean"]], required: ["summary", "name"])],
            ["name": "set_current_layer", "description": "Propose making a layer current (user must Apply).", "input_schema": obj(["summary": summary, "layer": ["type": "string"]], required: ["summary", "layer"])],
            ["name": "run_command", "description": "Propose running a CadMac command line (user must Apply).", "input_schema": obj(["summary": summary, "command": ["type": "string"]], required: ["summary", "command"])],
        ]
    }

    /// Runs one tool in-process against the frontmost window; returns (text, base64PNG?, isError).
    @MainActor
    static func execute(name: String, input: [String: Any]) async -> (text: String, image: String?, isError: Bool) {
        guard let wc = AutomationServer.targetWindow() else {
            return ("No drawing window is open in CadMac. Open or create a drawing first.", nil, true)
        }
        return await withCheckedContinuation { cont in
            AutomationTools(wc: wc).run(name, input) { r in
                if let e = r.error, !e.isEmpty { cont.resume(returning: (e, nil, true)) }
                else { cont.resume(returning: (r.text, r.image, false)) }
            }
        }
    }
}

// MARK: - Anthropic client with an agentic tool loop

@MainActor
final class AnthropicClient {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let system = """
    You are Claude working inside CadMac, a 2D CAD app on macOS. You help the user draw and edit the \
    current drawing using the provided tools. Coordinates and lengths are in the drawing's units — call \
    get_drawing_info first. Drawing changes (add/delete/modify/layer/command) are only previewed; the user \
    must click Apply, and a tool reply tells you if it was applied or rejected. Be concise. Reply in the \
    user's language.
    """
    /// Running conversation in Anthropic message format.
    private var messages: [[String: Any]] = []

    /// Sends a user message and runs the tool loop. `onText` streams assistant text; `onStatus` reports activity.
    func send(_ userText: String,
              onText: @escaping (String) -> Void,
              onStatus: @escaping (String) -> Void,
              onError: @escaping (String) -> Void) async {
        let key = ChatPrefs.apiKey
        guard !key.isEmpty else { onError("Set your Anthropic API key in CadMac ▸ Settings first."); return }
        messages.append(["role": "user", "content": [["type": "text", "text": userText]]])

        for _ in 0..<12 {   // tool-use rounds cap
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            let body: [String: Any] = ["model": ChatPrefs.model, "max_tokens": 4096,
                                       "system": system, "tools": ChatTools.specs(), "messages": messages]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let data: Data, resp: URLResponse
            do { (data, resp) = try await URLSession.shared.data(for: req) }
            catch { onError("Network error: \(error.localizedDescription)"); return }
            guard let http = resp as? HTTPURLResponse else { onError("No response"); return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                onError("Bad response (HTTP \(http.statusCode))"); return
            }
            if http.statusCode != 200 {
                let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(http.statusCode)"
                onError(msg); return
            }
            let content = json["content"] as? [[String: Any]] ?? []
            messages.append(["role": "assistant", "content": content])

            var toolUses: [[String: Any]] = []
            for block in content {
                switch block["type"] as? String {
                case "text": if let t = block["text"] as? String, !t.isEmpty { onText(t) }
                case "tool_use": toolUses.append(block)
                default: break
                }
            }
            if (json["stop_reason"] as? String) != "tool_use" || toolUses.isEmpty { return }

            var results: [[String: Any]] = []
            for tu in toolUses {
                let name = tu["name"] as? String ?? ""
                let input = tu["input"] as? [String: Any] ?? [:]
                let id = tu["id"] as? String ?? ""
                onStatus("⚙︎ \(name)")
                let (text, image, isError) = await ChatTools.execute(name: name, input: input)
                var resContent: [[String: Any]] = [["type": "text", "text": text.isEmpty ? "(done)" : text]]
                if let image { resContent.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": image]]) }
                var block: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": resContent]
                if isError { block["is_error"] = true }
                results.append(block)
            }
            messages.append(["role": "user", "content": results])
        }
        onStatus("(stopped after tool-use limit)")
    }

    func reset() { messages.removeAll() }
}

// MARK: - Chat window

@MainActor
final class ClaudeChatWindow: NSWindowController, NSTextFieldDelegate {
    static let shared = ClaudeChatWindow()
    private let transcript = NSTextView()
    private let input = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let client = AnthropicClient()
    private var busy = false

    init() {
        let win = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                          styleMask: [.titled, .closable, .resizable, .utilityWindow],
                          backing: .buffered, defer: false)
        win.title = "Claude"
        win.isFloatingPanel = true
        win.becomesKeyOnlyIfNeeded = false
        win.hidesOnDeactivate = false
        super.init(window: win)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        transcript.isEditable = false
        transcript.font = NSFont.systemFont(ofSize: 13)
        transcript.textContainerInset = NSSize(width: 10, height: 10)
        scroll.documentView = transcript
        scroll.translatesAutoresizingMaskIntoConstraints = false

        input.placeholderString = "Ask Claude to draw or edit…"
        input.font = NSFont.systemFont(ofSize: 13)
        input.delegate = self
        input.target = self
        input.action = #selector(sendTapped)   // Enter in the field sends
        input.translatesAutoresizingMaskIntoConstraints = false
        let send = NSButton(title: "Send", target: self, action: #selector(sendTapped))
        send.keyEquivalent = "\r"
        send.translatesAutoresizingMaskIntoConstraints = false
        status.font = NSFont.systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        for v in [scroll, input, send, status] { content.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 2),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            input.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4),
            input.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            input.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            send.leadingAnchor.constraint(equalTo: input.trailingAnchor, constant: 8),
            send.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            send.centerYAnchor.constraint(equalTo: input.centerYAnchor),
            send.widthAnchor.constraint(equalToConstant: 64),
        ])
        append("Claude", "Merhaba! Çizim üzerinde ne yapmamı istersiniz? (Önce CadMac ▸ Settings'ten Anthropic API anahtarınızı girin.)")
    }

    func toggle() {
        guard let window else { return }
        if window.isVisible { window.orderOut(nil) }
        else {
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(input)
        }
    }

    @objc private func sendTapped() { submit() }
    func controlTextDidEndEditing(_ obj: Notification) { }

    private func submit() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        input.stringValue = ""
        append("Siz", text)
        busy = true
        status.stringValue = "…"
        Task { @MainActor in
            await client.send(text,
                onText: { [weak self] t in self?.append("Claude", t) },
                onStatus: { [weak self] s in self?.status.stringValue = s },
                onError: { [weak self] e in self?.append("Hata", e) })
            self.busy = false
            self.status.stringValue = ""
        }
    }

    private func append(_ who: String, _ text: String) {
        let head = NSAttributedString(string: "\n\(who): ", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: who == "Siz" ? NSColor.systemBlue : (who == "Hata" ? NSColor.systemRed : NSColor.labelColor)])
        let body = NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        transcript.textStorage?.append(head)
        transcript.textStorage?.append(body)
        transcript.scrollToEndOfDocument(nil)
    }
}
