import Foundation

/// `OrcaFind --mcp` — a Model Context Protocol server over stdio so Claude (Desktop, Code, or any MCP client)
/// can search what you saved and read why you saved it. Read-only; works whether or not the app is open.
enum MCPServer {
    static let serverName = "orca"

    static func runIfRequested() {
        guard CommandLine.arguments.contains("--mcp") else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let reply = handle(msg) { send(reply) }
        }
        exit(0)
    }

    private static func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
    }

    static func handle(_ msg: [String: Any]) -> [String: Any]? {
        let method = msg["method"] as? String ?? ""
        let id = msg["id"]
        guard let id else { return nil } // notifications need no reply
        let params = msg["params"] as? [String: Any] ?? [:]

        func ok(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        func fail(_ code: Int, _ message: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
        }

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let version = ["2025-06-18", "2025-03-26", "2024-11-05"].contains(asked) ? asked : "2025-06-18"
            return ok([
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": serverName, "title": "Orca captures", "version": "1.0.0"],
                "instructions": """
                Orca holds the user's captures: screenshots they grabbed from anywhere on their Mac, each with what they \
                said out loud (or typed) about why they saved it, the page link, the text visible in the picture, and \
                a collection. Use search_captures to find them (natural words work: what it was, why it mattered, \
                the site, the collection). The user's own words in "note" are the most important signal of intent. \
                Use get_capture to see the picture itself.
                """
            ])
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            switch name {
            case "search_captures": return ok(searchCaptures(args))
            case "get_capture": return ok(getCapture(args))
            case "list_collections": return ok(listCollections())
            default: return fail(-32602, "Unknown tool: \(name)")
            }
        case "resources/list": return ok(["resources": []])
        case "prompts/list": return ok(["prompts": []])
        default:
            return fail(-32601, "Method not found: \(method)")
        }
    }

    // MARK: Tools

    static let tools: [[String: Any]] = [
        [
            "name": "search_captures",
            "title": "Search Orca captures",
            "description": "Find things the user saved with Orca. Matches what they said about it, the page title and link, the text in the screenshot, the collection and tags. Leave query empty to list the most recent. Returns id, title, the user's note, collection, tags, source, links, date, any reminder, and clip length when the capture is a short video.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Words to look for, e.g. 'pricing thread newsletter'"],
                    "collection": ["type": "string", "description": "Only captures in this collection, e.g. 'Newsletter'"],
                    "tag": ["type": "string", "description": "Only captures with this tag, across all collections, e.g. 'design'"],
                    "since": ["type": "string", "description": "Only captures saved after this: 'today', 'this week', 'this month', '14d', or a date like 2026-11-01"],
                    "limit": ["type": "integer", "description": "Max results (default 10, max 50)"]
                ]
            ],
            "annotations": ["readOnlyHint": true]
        ],
        [
            "name": "get_capture",
            "title": "Open one Orca capture",
            "description": "Everything about one capture: the user's note, links, tags, full text read from the picture, and the screenshot itself. For a clip (short video), four key frames are attached instead of one picture.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Capture id from search_captures"],
                    "include_image": ["type": "boolean", "description": "Attach the screenshot (default true)"]
                ],
                "required": ["id"]
            ],
            "annotations": ["readOnlyHint": true]
        ],
        [
            "name": "list_collections",
            "title": "List Orca collections",
            "description": "The collections the user's captures are filed in (made from what they said, e.g. 'for the newsletter') and the tags they use across collections, with counts.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true]
        ]
    ]

    static func searchCaptures(_ args: [String: Any]) -> [String: Any] {
        let store = CaptureStore.shared
        let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = min(50, max(1, (args["limit"] as? Int) ?? Int((args["limit"] as? Double) ?? 10)))
        var list = query.isEmpty ? store.all() : store.search(query, matchAll: false, limit: 300)
        if let col = args["collection"] as? String, !col.isEmpty {
            list = list.filter { $0.collection.map { SpokenIntent.same($0, col) } ?? false }
        }
        if let tag = args["tag"] as? String, let t = CaptureTags.normalize(tag) {
            list = list.filter { $0.hasTag(t) }
        }
        if let since = args["since"] as? String, let start = parseSince(since) {
            list = list.filter { $0.created >= start }
        }
        let shown = Array(list.prefix(limit))
        if shown.isEmpty {
            return ["content": [["type": "text", "text": "No captures matched. Try fewer or different words, or call search_captures with no query to see the latest."]]]
        }
        let iso = ISO8601DateFormatter()
        let rows: [[String: Any]] = shown.map { c in
            var r: [String: Any] = ["id": c.id, "title": c.title, "note": c.note, "source": c.sourceLabel,
                                    "saved": iso.string(from: c.created), "links": c.links]
            if let col = c.collection { r["collection"] = col }
            if !c.tagList.isEmpty { r["tags"] = c.tagList }
            if let s = c.clipSeconds, s > 0 { r["clip_seconds"] = Int(s.rounded()) }
            if let d = c.reminderDate { r["reminder"] = iso.string(from: d) }
            if !c.ocr.isEmpty { r["text_in_picture"] = String(c.ocr.replacingOccurrences(of: "\n", with: " ").prefix(400)) }
            return r
        }
        let json = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let header = "\(shown.count) of \(list.count) capture\(list.count == 1 ? "" : "s"). \"note\" is what the user said about why they saved it."
        return ["content": [["type": "text", "text": header + "\n" + json]], "structuredContent": ["captures": rows]]
    }

    static func getCapture(_ args: [String: Any]) -> [String: Any] {
        guard let id = args["id"] as? String, let c = CaptureStore.shared.get(id) else {
            return ["content": [["type": "text", "text": "No capture with that id."]], "isError": true]
        }
        var content: [[String: Any]] = [["type": "text", "text": c.asText]]
        let wantImages = (args["include_image"] as? Bool) ?? true
        if wantImages, c.hasClip {
            let frames = ClipFrames.framesSync(c.clipURL, count: 4, maxPixel: 1000)
            if !frames.isEmpty {
                content.append(["type": "text", "text": "This capture is a \(Int((c.clipSeconds ?? 0).rounded())) s clip. Key frames at " +
                                frames.map { String(format: "%.1f s", $0.time) }.joined(separator: ", ") + ":"])
                for f in frames {
                    if let png = ClipFrames.pngData(f.image) {
                        content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"])
                    }
                }
                return ["content": content]
            }
        }
        if wantImages, let png = CaptureStore.pngData(c.imageURL, maxPixel: 1400) {
            content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"])
        }
        return ["content": content]
    }

    static func listCollections() -> [String: Any] {
        let cols = CaptureStore.shared.collections()
        let total = CaptureStore.shared.all().count
        var text = "\(total) captures in total.\n"
        text += cols.isEmpty ? "No collections yet." : "Collections:\n" + cols.map { "- \($0.name) (\($0.count))" }.joined(separator: "\n")
        let tags = CaptureLibrary.countTags(CaptureStore.shared.all())
        if !tags.isEmpty { text += "\nTags (across collections):\n" + tags.map { "- #\($0.name) (\($0.count))" }.joined(separator: "\n") }
        return ["content": [["type": "text", "text": text]]]
    }

    static func parseSince(_ raw: String, now: Date = Date()) -> Date? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        let cal = Calendar.current
        switch s {
        case "today": return cal.startOfDay(for: now)
        case "yesterday": return cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))
        case "this week", "week", "last week", "past week": return cal.date(byAdding: .day, value: -7, to: now)
        case "this month", "month", "last month", "past month": return cal.date(byAdding: .day, value: -31, to: now)
        case "this year", "year": return cal.date(byAdding: .year, value: -1, to: now)
        default: break
        }
        if let m = s.range(of: #"^(\d+)\s*(d|day|days)$"#, options: .regularExpression) {
            let n = Int(s[m].prefix { $0.isNumber }) ?? 0
            return cal.date(byAdding: .day, value: -n, to: now)
        }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withFullDate]
        return iso.date(from: raw)
    }

    // MARK: Hooking up Claude

    /// Path of this executable — what Claude launches with `--mcp`.
    static var executablePath: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    static var claudeCodeCommand: String { "claude mcp add orca -- \"\(executablePath)\" --mcp" }

    static var desktopConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    static var isInClaudeDesktop: Bool {
        guard let data = try? Data(contentsOf: desktopConfigURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any] else { return false }
        return servers[serverName] != nil
    }

    /// Adds Orca to Claude Desktop's config (keeps everything else in the file). Returns an error message on failure.
    static func addToClaudeDesktop() -> String? {
        let url = desktopConfigURL
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "Claude’s config file isn’t valid JSON, so Orca left it alone."
            }
            obj = parsed
            try? data.write(to: url.deletingLastPathComponent().appendingPathComponent("claude_desktop_config.backup.json"))
        }
        var servers = obj["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": executablePath, "args": ["--mcp"]]
        obj["mcpServers"] = servers
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
