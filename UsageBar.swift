import AppKit
import ServiceManagement

struct Window { let name: String; let used: Double; let reset: Date?; var inTitle = true }
struct Usage { var windows: [Window]; var plan: String? = nil; var credits = 0.0; var limitReached = false }
struct Err: LocalizedError {
    let errorDescription: String?
    var transient = false  // network blips: keep showing the last good data instead
    init(_ s: String, transient: Bool = false) { errorDescription = s; self.transient = transient }
}

let claudeColor = NSColor(name: nil) { ap in
    ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        : NSColor(srgbRed: 0.72, green: 0.32, blue: 0.19, alpha: 1)  // darker so it stays readable on a light menu bar
}, codexColor = NSColor.systemBlue
let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

// Killed after 30 s so a stuck keychain prompt can't wedge refreshes forever.
func shell(_ args: [String]) -> String? {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if p.isRunning { p.terminate() } }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
}

func json(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }

// `security -w` prints the secret hex-encoded when it contains non-ASCII bytes.
func keychainJSON(_ raw: String) -> [String: Any]? {
    let u = Array(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    if let j = json(Data(u)) { return j }
    return json(Data(stride(from: 0, to: u.count - 1, by: 2).compactMap { UInt8(String(decoding: u[$0...$0 + 1], as: UTF8.self), radix: 16) }))
}

func getJSON(_ url: String, _ headers: [String: String]) async throws -> [String: Any] {
    var req = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
    headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
    let data: Data, resp: URLResponse
    do { (data, resp) = try await URLSession.shared.data(for: req) }
    catch { throw Err((error as? URLError)?.code == .timedOut ? "Timed out" : "Offline or network error", transient: true) }
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 { throw Err("Login expired — open the CLI once") }
    if code == 429 { throw Err("Rate limited — will retry", transient: true) }
    if code >= 500 { throw Err("Server error (HTTP \(code))", transient: true) }
    guard code == 200 else { throw Err("HTTP \(code)") }
    guard let j = json(data) else { throw Err("Unexpected response", transient: true) }
    return j
}

// Token lives in the keychain item Claude Code writes; Claude Code refreshes it itself.
func claude() async throws -> Usage {
    guard let raw = shell(["/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", "-w"]),
          let oauth = keychainJSON(raw)?["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String
    else { throw Err("Not logged in to Claude Code") }
    let j = try await getJSON("https://api.anthropic.com/api/oauth/usage",
                              ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"])
    let frac = ISO8601DateFormatter(), plain = ISO8601DateFormatter()
    frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = { (s: Any?) in (s as? String).flatMap { frac.date(from: $0) ?? plain.date(from: $0) } }
    let keys = [("five_hour", "5-hour", true), ("seven_day", "Weekly", true),
                ("seven_day_opus", "Weekly Opus", false), ("seven_day_sonnet", "Weekly Sonnet", false)]
    let windows = keys.compactMap { key, name, inTitle -> Window? in
        guard let w = j[key] as? [String: Any], let used = w["utilization"] as? Double else { return nil }
        return Window(name: name, used: used, reset: date(w["resets_at"]), inTitle: inTitle)
    }
    // Newer per-model weekly limits only appear in `limits`.
    let scoped = (j["limits"] as? [[String: Any]] ?? []).compactMap { l -> Window? in
        guard l["kind"] as? String == "weekly_scoped", let used = l["percent"] as? Double,
              let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
        else { return nil }
        return Window(name: "Weekly \(model)", used: used, reset: date(l["resets_at"]), inTitle: false)
    }
    return Usage(windows: windows + scoped.filter { s in !windows.contains { $0.name == s.name } })
}

// Token lives in ~/.codex/auth.json; Codex CLI refreshes it itself.
func codex() async throws -> Usage {
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    guard let data = try? Data(contentsOf: path), let auth = json(data) else { throw Err("Not logged in to Codex") }
    guard let t = auth["tokens"] as? [String: Any], let token = t["access_token"] as? String
    else { throw Err(auth["OPENAI_API_KEY"] is String ? "Codex uses an API key — no plan limits" : "Not logged in to Codex") }
    var h = ["Authorization": "Bearer \(token)", "User-Agent": "codex-cli"]
    if let id = t["account_id"] as? String { h["ChatGPT-Account-Id"] = id }
    let j = try await getJSON("https://chatgpt.com/backend-api/wham/usage", h)
    let rl = j["rate_limit"] as? [String: Any] ?? [:], cr = j["credits"] as? [String: Any] ?? [:]
    let windows: [Window] = ["primary_window", "secondary_window"].compactMap { key in
        guard let w = rl[key] as? [String: Any], let used = w["used_percent"] as? Double else { return nil }
        let hours = Int(((w["limit_window_seconds"] as? Double ?? 0) / 3600).rounded())
        let name = hours == 0 ? "Limit" : hours < 24 ? "\(hours)-hour" : hours == 168 ? "Weekly" : "\(hours / 24)-day"
        let reset = (w["reset_at"] as? Double).map(Date.init(timeIntervalSince1970:))
            ?? (w["reset_after_seconds"] as? Double).map { Date(timeIntervalSinceNow: $0) }
        return Window(name: name, used: used, reset: reset)
    }
    let balance = Double("\(cr["balance"] ?? 0)") ?? 0
    return Usage(windows: windows,
                 plan: (j["plan_type"] as? String).map { String($0.replacingOccurrences(of: "_", with: " ").capitalized.prefix(16)) },
                 credits: cr["has_credits"] as? Bool == true && balance.isFinite ? min(max(0, balance), 1e12) : 0,
                 limitReached: rl["limit_reached"] as? Bool ?? false || windows.contains { left($0) == 0 })
}

func attempt(_ f: () async throws -> Usage) async -> Result<Usage, Error> {
    do { return .success(try await f()) } catch { return .failure(error) }
}

// Rounded up so 0% only shows when the limit is truly exhausted.
func left(_ w: Window) -> Int { min(100, max(0, Int((100 - w.used).rounded(.up)))) }

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

// MARK: - Auto-update from GitHub Releases

let repo = "hkarlsen06/UsageBar"
// Only bundles signed with our Developer ID are installed.
// Developer ID CA + leaf OIDs (an Apple Development cert from the same team would pass an OU-only check), plus notarized.
// Must match REQ in release.sh.
let signingRequirement = #"anchor apple generic and identifier "dev.hkarlsen06.usagebar" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "48ZSLD4RMP" and notarized"#

struct Release { let version: String; let zip: URL; let page: URL }

// Returns the latest release if it's newer than the running version.
func newerRelease() async throws -> Release? {
    let j = try await getJSON("https://api.github.com/repos/\(repo)/releases/latest", ["Accept": "application/vnd.github+json"])
    guard let tag = j["tag_name"] as? String, let page = (j["html_url"] as? String).flatMap(URL.init(string:)),
          let asset = (j["assets"] as? [[String: Any]])?.first(where: { $0["name"] as? String == "UsageBar.zip" }),
          let zip = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
    else { return nil }
    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    return version.compare(currentVersion, options: .numeric) == .orderedDescending ? Release(version: version, zip: zip, page: page) : nil
}

// Downloads, verifies the signature, swaps the bundle in place, then relaunches.
func install(_ r: Release) async throws {
    let app = Bundle.main.bundleURL
    guard !app.path.contains("/AppTranslocation/") else { throw Err("Move UsageBar to Applications to auto-update") }
    let (zip, _) = try await URLSession.shared.download(from: r.zip)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("UsageBar-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: zip) }
    let new = dir.appendingPathComponent("UsageBar.app")
    guard shell(["/usr/bin/ditto", "-x", "-k", zip.path, dir.path]) != nil,
          (try? FileManager.default.attributesOfItem(atPath: new.path)[.type] as? FileAttributeType) == .typeDirectory,  // no symlinks
          shell(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R=\(signingRequirement)", new.path]) != nil,
          // Info.plist is sealed by the signature, so this blocks rollbacks to an older signed build under a newer tag.
          let v = Bundle(url: new)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
          v == r.version, v.compare(currentVersion, options: .numeric) == .orderedDescending
    else { throw Err("Update failed verification") }
    _ = try FileManager.default.replaceItemAt(app, withItemAt: new)
    let relaunch = Process()
    relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
    relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
    try relaunch.run()
    await NSApp.terminate(nil)
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

@MainActor func text(_ parts: (String, NSFont, NSColor)...) -> NSTextField {
    let s = NSMutableAttributedString(), ps = NSMutableParagraphStyle()
    ps.lineBreakMode = .byTruncatingTail  // NSTextField.lineBreakMode is ignored for attributed strings
    for (str, font, color) in parts { s.append(NSAttributedString(string: str, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: ps])) }
    let l = NSTextField(labelWithAttributedString: s)
    l.sizeToFit()
    l.frame.size.width = min(l.frame.width, menuWidth - 28)
    return l
}

// Left text, optional right-aligned text, optional bar underneath.
@MainActor func row(_ leftText: NSTextField, _ right: NSTextField? = nil, bar: (Double, NSColor)? = nil) -> NSMenuItem {
    let h: CGFloat = bar == nil ? 24 : 38
    let v = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: h))
    v.autoresizingMask = .width  // the menu stretches rows to its full width (e.g. for the ⌘R column)
    let y = h - 21
    if let right {
        right.frame.size.width = min(right.frame.width, 150)
        leftText.frame.size.width = min(leftText.frame.width, menuWidth - 36 - right.frame.width)
    }
    leftText.setFrameOrigin(NSPoint(x: 14, y: y))
    v.addSubview(leftText)
    if let right {
        right.setFrameOrigin(NSPoint(x: menuWidth - 14 - right.frame.width, y: y))
        right.autoresizingMask = .minXMargin
        v.addSubview(right)
    }
    if let bar {
        let b = Bar(frame: NSRect(x: 14, y: 7, width: menuWidth - 28, height: 6))
        (b.fraction, b.color) = bar
        b.autoresizingMask = .width
        v.addSubview(b)
    }
    let item = NSMenuItem()
    let spoken = [leftText, right].compactMap { $0?.stringValue }.joined(separator: ", ")
        .replacingOccurrences(of: "%  ↻", with: "% left, resets in")
    item.title = spoken
    v.setAccessibilityElement(true)
    v.setAccessibilityLabel(spoken)
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
    var available: Release?   // newer release we couldn't install automatically
    var updateNote: String?
    var refreshing = false, installing = false

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.title = "…"
        item.menu = NSMenu()
        item.menu?.autoenablesItems = false
        item.menu?.delegate = self
        refresh()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Task { @MainActor in self.refresh() } }.tolerance = 30
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in Task { @MainActor in self.update(manual: false) } }
        update(manual: false)
    }

    // Network usually isn't up the instant we wake.
    @objc func woke() { Task { try? await Task.sleep(for: .seconds(10)); refresh() } }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        try? s.status == .enabled ? s.unregister() : s.register()
    }

    @objc func refresh() {
        guard !refreshing else { return }  // overlapping fetches could finish out of order
        refreshing = true
        Task {
            defer { refreshing = false }
            async let c = attempt(claude), x = attempt(codex)
            let new = [await c, await x]
            results = new.indices.map { i in
                if case .failure(let e as Err) = new[i], e.transient, i < results.count, case .success = results[i] { return results[i] }
                return new[i]
            }
            updated = Date()
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            let title = NSMutableAttributedString()
            for ((_, color), r) in zip(tools, results) {
                if title.length > 0 { title.append(NSAttributedString(string: " ")) }
                title.append(NSAttributedString(string: titleText(r), attributes: [.foregroundColor: color, .font: font]))
            }
            item.button?.attributedTitle = title
            // Colour alone tells the numbers apart, so spell it out for hover and VoiceOver.
            let tip = zip(tools, results).map { t, r -> String in
                guard case .success(let u) = r else { return "\(t.0): error" }
                return "\(t.0): " + u.windows.map { "\(left($0))% \($0.name) left" }.joined(separator: ", ")
            }.joined(separator: "\n")
            item.button?.toolTip = tip
            item.button?.setAccessibilityLabel(tip.replacingOccurrences(of: "\n", with: ". "))
        }
    }

    @objc func checkForUpdates() { update(manual: true) }

    func update(manual: Bool) {
        guard !installing, currentVersion != "0.0.0" else { return }  // 0.0.0 = local dev build
        installing = true
        Task {
            defer { installing = false }
            let r: Release?
            do { r = try await newerRelease() } catch { if manual { updateNote = "Update check failed" }; return }
            guard let r else { if manual { updateNote = "Up to date" }; return }
            updateNote = "Installing v\(r.version)…"
            do { try await install(r) } catch { available = r; updateNote = error.localizedDescription }
        }
    }

    @objc func openRelease() { if let available { NSWorkspace.shared.open(available.page) } }

    // Rebuilt on open so the reset countdowns are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for ((name, color), r) in zip(tools, results) {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            let plan = (try? r.get())?.plan.map { text(($0, small, .secondaryLabelColor)) }
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
        let footer = "v\(currentVersion) · Updated \(updated.formatted(date: .omitted, time: .shortened))" + (updateNote.map { " · \($0)" } ?? "")
        menu.addItem(row(text((footer, .systemFont(ofSize: 11), .tertiaryLabelColor))))
        if let available {
            menu.addItem(withTitle: "Download v\(available.version)…", action: #selector(openRelease), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}

MainActor.assumeIsolated {
    if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count > 1 { exit(0) }
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
