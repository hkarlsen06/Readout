import AppKit

struct Window { let name: String; let used: Double; let reset: Date?; var inTitle = true }
struct Usage { var windows: [Window]; var plan: String? = nil; var credits = 0.0; var limitReached = false }
struct Err: LocalizedError { let errorDescription: String?; init(_ s: String) { errorDescription = s } }

let claudeColor = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1), codexColor = NSColor.systemBlue

func shell(_ args: [String]) -> String? {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
}

func json(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }

func getJSON(_ url: String, _ headers: [String: String]) async throws -> [String: Any] {
    var req = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
    headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 { throw Err("Login expired — run the CLI once to refresh") }
    guard code == 200, let j = json(data) else { throw Err("HTTP \(code)") }
    return j
}

// Token lives in the keychain item Claude Code writes; Claude Code refreshes it itself.
func claude() async throws -> Usage {
    guard let raw = shell(["/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", "-w"]),
          let oauth = json(Data(raw.utf8))?["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String
    else { throw Err("Not logged in to Claude Code") }
    let j = try await getJSON("https://api.anthropic.com/api/oauth/usage",
                              ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"])
    let frac = ISO8601DateFormatter(), plain = ISO8601DateFormatter()
    frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let keys = [("five_hour", "5-hour", true), ("seven_day", "Weekly", true),
                ("seven_day_opus", "Weekly Opus", false), ("seven_day_sonnet", "Weekly Sonnet", false)]
    return Usage(windows: keys.compactMap { key, name, inTitle in
        guard let w = j[key] as? [String: Any], let used = w["utilization"] as? Double else { return nil }
        let s = w["resets_at"] as? String ?? ""
        return Window(name: name, used: used, reset: frac.date(from: s) ?? plain.date(from: s), inTitle: inTitle)
    })
}

// Token lives in ~/.codex/auth.json; Codex CLI refreshes it itself.
func codex() async throws -> Usage {
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    guard let data = try? Data(contentsOf: path), let t = json(data)?["tokens"] as? [String: Any],
          let token = t["access_token"] as? String
    else { throw Err("Not logged in to Codex") }
    var h = ["Authorization": "Bearer \(token)", "User-Agent": "codex-cli"]
    if let id = t["account_id"] as? String { h["ChatGPT-Account-Id"] = id }
    let j = try await getJSON("https://chatgpt.com/backend-api/wham/usage", h)
    let rl = j["rate_limit"] as? [String: Any] ?? [:], cr = j["credits"] as? [String: Any] ?? [:]
    let windows: [Window] = ["primary_window", "secondary_window"].compactMap { key in
        guard let w = rl[key] as? [String: Any], let used = w["used_percent"] as? Double else { return nil }
        let hours = Int(((w["limit_window_seconds"] as? Double ?? 0) / 3600).rounded())
        let name = hours < 24 ? "\(hours)-hour" : hours == 168 ? "Weekly" : "\(hours / 24)-day"
        return Window(name: name, used: used, reset: (w["reset_at"] as? Double).map(Date.init(timeIntervalSince1970:)))
    }
    return Usage(windows: windows, plan: j["plan_type"] as? String,
                 credits: cr["has_credits"] as? Bool == true ? Double("\(cr["balance"] ?? 0)") ?? 0 : 0,
                 limitReached: rl["limit_reached"] as? Bool ?? false || windows.contains { left($0) == 0 })
}

func attempt(_ f: () async throws -> Usage) async -> Result<Usage, Error> {
    do { return .success(try await f()) } catch { return .failure(error) }
}

func left(_ w: Window) -> Int { max(0, Int(100 - w.used)) }

func until(_ d: Date?) -> String {
    guard let d else { return "?" }
    let m = max(0, Int(d.timeIntervalSinceNow / 60))
    return m >= 1440 ? "\(m / 1440)d \(m % 1440 / 60)h" : "\(m / 60)h \(m % 60)m"
}

// Menu bar text for one tool: "95/89" (% left, shortest window first), or credits once the limit is hit.
func titleText(_ r: Result<Usage, Error>) -> String {
    guard case .success(let u) = r else { return "!" }
    if u.limitReached && u.credits > 0 {
        return (u.credits >= 1000 ? String(format: "%.1fk", u.credits / 1000) : "\(Int(u.credits))") + " cr"
    }
    let t = u.windows.filter(\.inTitle).map { "\(left($0))" }.joined(separator: "/")
    return t.isEmpty ? "–" : t
}

// MARK: - Dropdown rows

let menuWidth: CGFloat = 280

final class Bar: NSView {
    var fraction = 0.0, color = NSColor.labelColor
    override func draw(_ r: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height), xRadius: 3, yRadius: 3).fill()
    }
}

func text(_ parts: (String, NSFont, NSColor)...) -> NSTextField {
    let s = NSMutableAttributedString()
    for (str, font, color) in parts { s.append(NSAttributedString(string: str, attributes: [.font: font, .foregroundColor: color])) }
    let l = NSTextField(labelWithAttributedString: s)
    l.lineBreakMode = .byTruncatingTail
    l.sizeToFit()
    l.frame.size.width = min(l.frame.width, menuWidth - 28)
    return l
}

// Left text, optional right-aligned text, optional bar underneath.
func row(_ leftText: NSTextField, _ right: NSTextField? = nil, bar: (Double, NSColor)? = nil) -> NSMenuItem {
    let h: CGFloat = bar == nil ? 24 : 38
    let v = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: h))
    let y = h - 21
    leftText.setFrameOrigin(NSPoint(x: 14, y: y))
    v.addSubview(leftText)
    if let right {
        right.setFrameOrigin(NSPoint(x: menuWidth - 14 - right.frame.width, y: y))
        v.addSubview(right)
    }
    if let bar {
        let b = Bar(frame: NSRect(x: 14, y: 7, width: menuWidth - 28, height: 6))
        (b.fraction, b.color) = bar
        v.addSubview(b)
    }
    let item = NSMenuItem()
    item.view = v
    return item
}

let body = NSFont.systemFont(ofSize: 13), small = NSFont.systemFont(ofSize: 12)
let digits = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

@MainActor final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let tools = [("Claude Code", claudeColor), ("Codex", codexColor)]
    var results: [Result<Usage, Error>] = []
    var updated = Date()

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.title = "…"
        item.menu = NSMenu()
        item.menu?.autoenablesItems = false
        item.menu?.delegate = self
        refresh()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Task { @MainActor in self.refresh() } }
    }

    @objc func refresh() {
        Task {
            async let c = attempt(claude), x = attempt(codex)
            results = [await c, await x]
            updated = Date()
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            let title = NSMutableAttributedString()
            for ((_, color), r) in zip(tools, results) {
                if title.length > 0 { title.append(NSAttributedString(string: " ")) }
                title.append(NSAttributedString(string: titleText(r), attributes: [.foregroundColor: color, .font: font]))
            }
            item.button?.attributedTitle = title
        }
    }

    // Rebuilt on open so the reset countdowns are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for ((name, color), r) in zip(tools, results) {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            let plan = (try? r.get())?.plan.map { text(($0.capitalized, small, .secondaryLabelColor)) }
            menu.addItem(row(text((name, .systemFont(ofSize: 13, weight: .semibold), color)), plan))
            switch r {
            case .success(let u):
                for w in u.windows {
                    menu.addItem(row(text((w.name, body, .labelColor)),
                                     text(("\(left(w))%", digits, .labelColor), ("  ↻ \(until(w.reset))", small, .secondaryLabelColor)),
                                     bar: (Double(left(w)) / 100, color)))
                }
                if u.credits > 0 {
                    menu.addItem(row(text(("Credits", body, .labelColor)), text((Int(u.credits).formatted(), digits, .labelColor))))
                }
                if u.windows.isEmpty && u.credits == 0 { menu.addItem(row(text(("No limits reported", small, .secondaryLabelColor)))) }
            case .failure(let e):
                menu.addItem(row(text((e.localizedDescription, small, .secondaryLabelColor))))
            }
        }
        menu.addItem(.separator())
        menu.addItem(row(text(("Updated \(updated.formatted(date: .omitted, time: .shortened))", .systemFont(ofSize: 11), .tertiaryLabelColor))))
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
