// cadmac-mcp: MCP (stdio) bridge between Claude Code and a running CadMac.
//
// Speaks newline-delimited JSON-RPC 2.0 on stdin/stdout and forwards tool calls to the
// CadMac app over a local Unix domain socket (one JSON request / response per line).
// Pure Foundation, no dependencies.

import Foundation

let serverVersion = "1.0.0"
let supportedProtocols = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

// MARK: - Socket path

func socketPath() -> String {
    if let p = ProcessInfo.processInfo.environment["CADMAC_AUTOMATION_SOCKET"], !p.isEmpty { return p }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("CadMac/automation.sock").path
}

// MARK: - Output (serialized)

let outLock = NSLock()
/// Tool calls still running (waited for when stdin closes).
let inFlight = DispatchGroup()

func send(_ obj: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
    data.append(0x0A)
    outLock.lock()
    FileHandle.standardOutput.write(data)
    outLock.unlock()
}

func log(_ s: String) {
    FileHandle.standardError.write(("cadmac-mcp: " + s + "\n").data(using: .utf8)!)
}

func reply(_ id: Any, result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
func replyError(_ id: Any, code: Int, _ message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

// MARK: - App connection

enum BridgeError: Error { case notRunning(String), io(String) }

/// Sends one request to CadMac and waits for the one-line reply.
func callApp(_ request: [String: Any]) throws -> [String: Any] {
    let path = socketPath()
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw BridgeError.io("socket() failed") }
    defer { close(fd) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw BridgeError.io("socket path too long: \(path)") }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = b }
        raw[bytes.count] = 0
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } }
    guard rc == 0 else {
        throw BridgeError.notRunning("CadMac is not running (no automation socket at \(path)). Open CadMac first (with a drawing window), then retry.")
    }
    var payload = try JSONSerialization.data(withJSONObject: request, options: [.withoutEscapingSlashes])
    payload.append(0x0A)
    try payload.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count {
            let n = write(fd, raw.baseAddress! + off, raw.count - off)
            if n <= 0 { throw BridgeError.io("write to CadMac failed") }
            off += n
        }
    }
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        buffer.append(contentsOf: chunk[0..<n])
        if let nl = buffer.firstIndex(of: 0x0A) { buffer = buffer.prefix(upTo: nl); break }
    }
    guard !buffer.isEmpty,
          let obj = try JSONSerialization.jsonObject(with: buffer) as? [String: Any] else {
        throw BridgeError.io("CadMac closed the connection without a reply")
    }
    return obj
}

// MARK: - Tool definitions

let pointSchema = #"{"type":"array","items":{"type":"number"},"minItems":2,"maxItems":2,"description":"[x, y] in drawing units"}"#
let colorSchema = ##"{"description":"ACI color index (1 red, 2 yellow, 3 green, 4 cyan, 5 blue, 6 magenta, 7 white/black, 8 gray, ... 256 = ByLayer, 0 = ByBlock), a \"#rrggbb\" string, or \"ByLayer\"/\"ByBlock\"/a basic color name","anyOf":[{"type":"integer"},{"type":"string"}]}"##
let summarySchema = #"{"type":"string","description":"Short human-readable description of the change, shown to the user in CadMac's approval panel (e.g. \"Add 4 walls on layer A-WALL\")."}"#
let idsSchema = #"{"type":"array","items":{"type":"string"},"description":"Entity ids as returned by list_entities / get_selection (full UUID or a unique prefix of at least 8 characters)"}"#

let toolsJSON = """
[
 {"name":"get_drawing_info","description":"Overview of the drawing in the frontmost CadMac window: file name, drawing units (all coordinates and lengths are in these units), current layer, active space (Model or a paper layout), extents, entity counts by type, layers (color/on/frozen/locked), layouts and blocks. Call this first.","inputSchema":{"type":"object","properties":{}}},
 {"name":"list_entities","description":"List entities of the active space with their id, type, layer, color, key geometry (line endpoints, circle center/radius, polyline vertices, text content, block name/attributes, dimension measurement) and bounding box [minX, minY, maxX, maxY]. Filter by layer, type and/or bbox; paginate with limit/offset.","inputSchema":{"type":"object","properties":{"layer":{"type":"string","description":"Only entities on this layer (case-insensitive)"},"type":{"type":"string","description":"Entity type: line, polyline, circle, arc, ellipse, text, mtext, point, dimension, insert (block reference), hatch, spline, viewport"},"bbox":{"type":"array","items":{"type":"number"},"minItems":4,"maxItems":4,"description":"[minX, minY, maxX, maxY]; entities whose bounding box intersects it"},"inside_only":{"type":"boolean","description":"With bbox: only entities completely inside it"},"limit":{"type":"integer","description":"Max entities to return (default 200, max 2000)"},"offset":{"type":"integer","description":"Skip this many matches (default 0)"}}}},
 {"name":"get_selection","description":"Entities currently selected by the user in CadMac (same format as list_entities). Use this when the user says 'this', 'the selected ...'.","inputSchema":{"type":"object","properties":{}}},
 {"name":"measure","description":"Measure the distance/angle between two points, and/or the length, area and perimeter of an entity. Results include units.","inputSchema":{"type":"object","properties":{"from":\(pointSchema),"to":\(pointSchema),"id":{"type":"string","description":"Entity id to measure (area/perimeter/length)"}}}},
 {"name":"find_closed_areas","description":"Areas of closed regions. With 'point': detects the smallest closed boundary formed by surrounding geometry (like HATCH/BOUNDARY pick point) and returns its area, perimeter, centroid and outline. Without 'point': lists closed objects (closed polylines, circles, ellipses, closed splines, hatches) sorted by area, with area, perimeter and centroid.","inputSchema":{"type":"object","properties":{"point":\(pointSchema),"layer":{"type":"string","description":"Without point: only objects on this layer"},"limit":{"type":"integer","description":"Without point: max results (default 100)"}}}},
 {"name":"screenshot","description":"PNG image of what the CadMac drawing window currently shows (including any pending Claude preview, drawn in purple). Optionally zoom to extents first.","inputSchema":{"type":"object","properties":{"zoom_extents":{"type":"boolean","description":"Zoom to drawing extents before capturing (default false)"},"max_width":{"type":"integer","description":"Max image width in pixels (default 1600)"}}}},
 {"name":"add_entities","description":"Propose new entities. The user sees a preview in CadMac and must click Apply; the reply says whether it was applied (with the new ids) or rejected. Each entity is an object with 'type' and fields:\\n- line: start, end\\n- polyline: points [[x,y],...], closed?, bulges? (per-vertex arc bulge), width?\\n- rectangle: corner1, corner2\\n- circle: center, radius\\n- arc: center, radius, start_angle, end_angle (degrees, counter-clockwise)\\n- text: position, text, height?, rotation? (deg), align? (left|center|right), valign? (baseline|bottom|middle|top)\\n- mtext: position (top-left), text (\\\\n for new lines), height?, width? (wrap width)\\n- point: position\\n- dimension_linear: p1, p2, dim_line_point, direction? (horizontal|vertical|auto)\\n- dimension_aligned: p1, p2, dim_line_point\\n- hatch_solid: points [[x,y],...] boundary loop, OR boundary_point [x,y] to fill the closed region around that point (sees existing geometry and entities earlier in this list)\\nAll may have layer? (created on apply if missing; default current layer), color?, linetype?. Points are [x, y] in drawing units. Text height defaults to the drawing's text height.","inputSchema":{"type":"object","properties":{"summary":\(summarySchema),"entities":{"type":"array","description":"Entities to add (max 20000)","items":{"type":"object","properties":{"type":{"type":"string","enum":["line","polyline","rectangle","circle","arc","text","mtext","point","dimension_linear","dimension_aligned","hatch_solid"]},"layer":{"type":"string"},"color":\(colorSchema),"linetype":{"type":"string"}},"required":["type"]}}},"required":["summary","entities"]}},
 {"name":"delete_entities","description":"Propose deleting entities by id. Requires the user's approval in CadMac.","inputSchema":{"type":"object","properties":{"summary":\(summarySchema),"ids":\(idsSchema)},"required":["summary","ids"]}},
 {"name":"modify_entities","description":"Propose changes to existing entities: set layer/color/linetype, replace text content (text, mtext, dimension override), and/or transform (scale, then rotate, then move). Requires the user's approval.","inputSchema":{"type":"object","properties":{"summary":\(summarySchema),"ids":\(idsSchema),"layer":{"type":"string","description":"Move to this layer (created if missing)"},"color":\(colorSchema),"linetype":{"type":"string"},"text":{"type":"string","description":"New text content for text/mtext entities, or override text for dimensions"},"move":{"type":"object","properties":{"dx":{"type":"number"},"dy":{"type":"number"}}},"rotate":{"type":"object","properties":{"angle":{"type":"number","description":"Degrees, counter-clockwise"},"base":\(pointSchema)},"required":["angle"]},"scale":{"type":"object","properties":{"factor":{"type":"number"},"base":\(pointSchema)},"required":["factor"]}},"required":["summary","ids"]}},
 {"name":"create_layer","description":"Propose creating a layer (or updating its color/linetype if it exists). Requires the user's approval.","inputSchema":{"type":"object","properties":{"summary":\(summarySchema),"name":{"type":"string"},"color":\(colorSchema),"linetype":{"type":"string","description":"Continuous, DASHED, HIDDEN, CENTER, DASHDOT, DOT, PHANTOM, BORDER"},"make_current":{"type":"boolean"}},"required":["summary","name"]}},
 {"name":"set_current_layer","description":"Propose making a layer current (new objects drawn by the user go on it). Created if missing. Requires the user's approval.","inputSchema":{"type":"object","properties":{"summary":\(summarySchema),"name":{"type":"string"}},"required":["summary","name"]}},
 {"name":"run_command","description":"Run a CadMac/AutoCAD-style command script exactly as if typed into the command line; ';' (or a newline) = Enter. Examples: \\"LINE;0,0;100,0;100,50;;\\"  \\"CIRCLE;50,50;25\\"  \\"OFFSET;10;<pick point>;<side point>;;\\"  \\"FILLET;R;5;...\\". Points: x,y  @dx,dy  @dist<angle. Command-line output (e.g. from LIST, DIST, AREA) is returned. Any drawing change is shown as a preview and applied only after the user approves (as one undo step). Commands needing dialogs (MTEXT editor, print, block editor, layout tabs) are not supported here; prefer add_entities/modify_entities for simple geometry.","inputSchema":{"type":"object","properties":{"summary":\(summarySchema),"script":{"type":"string"}},"required":["summary","script"]}},
 {"name":"zoom","description":"Change the CadMac view (no approval needed): zoom to drawing extents or to a window.","inputSchema":{"type":"object","properties":{"mode":{"type":"string","enum":["extents","window"]},"bbox":{"type":"array","items":{"type":"number"},"minItems":4,"maxItems":4,"description":"[minX, minY, maxX, maxY] for mode=window"}},"required":["mode"]}},
 {"name":"select_entities","description":"Select (highlight) entities in CadMac so the user can see them (no approval needed). Empty ids clears the selection.","inputSchema":{"type":"object","properties":{"ids":\(idsSchema),"add":{"type":"boolean","description":"Add to the current selection instead of replacing it"}},"required":["ids"]}}
]
"""

let tools: [[String: Any]] = {
    guard let data = toolsJSON.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        fatalError("cadmac-mcp: invalid built-in tool schema JSON")
    }
    return arr
}()

let toolNames = Set(tools.compactMap { $0["name"] as? String })

// MARK: - Request handling

func handleToolCall(id: Any, params: [String: Any]) {
    guard let name = params["name"] as? String else { replyError(id, code: -32602, "Missing tool name"); return }
    guard toolNames.contains(name) else { replyError(id, code: -32602, "Unknown tool: \(name)"); return }
    let args = params["arguments"] as? [String: Any] ?? [:]
    func textResult(_ s: String, error: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": s]], "isError": error]
    }
    do {
        let resp = try callApp(["tool": name, "args": args])
        let ok = resp["ok"] as? Bool ?? false
        var content: [[String: Any]] = []
        if let t = resp["text"] as? String, !t.isEmpty { content.append(["type": "text", "text": t]) }
        if let img = resp["image"] as? String { content.append(["type": "image", "data": img, "mimeType": "image/png"]) }
        if !ok, let e = resp["error"] as? String { content.insert(["type": "text", "text": "Error: " + e], at: 0) }
        if content.isEmpty { content.append(["type": "text", "text": ok ? "OK" : "Error"]) }
        reply(id, result: ["content": content, "isError": !ok])
    } catch BridgeError.notRunning(let m) {
        reply(id, result: textResult(m, error: true))
    } catch BridgeError.io(let m) {
        reply(id, result: textResult("Communication with CadMac failed: \(m)", error: true))
    } catch {
        reply(id, result: textResult("Communication with CadMac failed: \(error.localizedDescription)", error: true))
    }
}

func handle(_ msg: [String: Any]) {
    let method = msg["method"] as? String ?? ""
    let id = msg["id"]
    let params = msg["params"] as? [String: Any] ?? [:]
    guard let id, !(id is NSNull) else { return }   // notifications (initialized, cancelled, ...) need no reply
    switch method {
    case "initialize":
        let requested = params["protocolVersion"] as? String ?? ""
        let version = supportedProtocols.contains(requested) ? requested : supportedProtocols[2]
        reply(id, result: [
            "protocolVersion": version,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "cadmac", "version": serverVersion],
            "instructions": "Controls the CadMac 2D CAD app. Call get_drawing_info first to learn units, layers and extents. Read-only tools run immediately; drawing changes (add/delete/modify entities, layers, run_command) are previewed in CadMac and only applied when the user clicks Apply — always pass a clear 'summary'. If a change is rejected, ask the user what to do differently.",
        ])
    case "ping":
        reply(id, result: [:])
    case "tools/list":
        reply(id, result: ["tools": tools])
    case "tools/call":
        // Approval can take minutes; handle calls concurrently so pings etc. still get answers.
        nonisolated(unsafe) let p = params
        nonisolated(unsafe) let i = id
        inFlight.enter()
        DispatchQueue.global().async { handleToolCall(id: i, params: p); inFlight.leave() }
    case "resources/list":
        reply(id, result: ["resources": [Any]()])
    case "prompts/list":
        reply(id, result: ["prompts": [Any]()])
    default:
        replyError(id, code: -32601, "Method not found: \(method)")
    }
}

// MARK: - Main loop

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IONBF, 0)
while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }
    guard let data = trimmed.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) else {
        send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        continue
    }
    if let batch = obj as? [[String: Any]] {
        batch.forEach(handle)
    } else if let msg = obj as? [String: Any] {
        handle(msg)
    }
}
// stdin closed: let in-flight tool calls (possibly waiting for approval) finish before exiting.
_ = inFlight.wait(timeout: .now() + 660)
