import AppKit
import IOKit
import ServiceManagement
import SwiftUI

struct Window {
    let name: String; let used: Double; let reset: Date?; var length: TimeInterval? = nil; var inTitle = true
    // Fraction of the window still to go: where the bar would sit if usage tracked time evenly.
    var pace: Double? {
        guard let reset, let length, length > 0 else { return nil }
        return min(1, max(0, reset.timeIntervalSinceNow / length))
    }
}
struct Usage { var windows: [Window]; var plan: String? = nil; var credits = 0.0; var limitReached = false }
struct Err: LocalizedError {
    let errorDescription: String?
    var transient = false  // network blips: keep showing the last good data instead
    init(_ s: String, transient: Bool = false) { errorDescription = s; self.transient = transient }
}

// OKLCH -> sRGB (Björn Ottosson's OKLab), lowering chroma until the colour fits in sRGB.
func oklch(_ L: Double, _ C: Double, _ hue: Double) -> NSColor {
    func rgb(_ c: Double) -> [Double] {
        let a = c * cos(hue * .pi / 180), b = c * sin(hue * .pi / 180)
        let l = L + 0.3963377774 * a + 0.2158037573 * b, m = L - 0.1055613458 * a - 0.0638541728 * b,
            s = L - 0.0894841775 * a - 1.2914855480 * b
        let (l3, m3, s3) = (l * l * l, m * m * m, s * s * s)
        return [4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
                -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
                -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3]
    }
    var c = C
    while c > 0, rgb(c).contains(where: { $0 < -1e-4 || $0 > 1 + 1e-4 }) { c -= 0.002 }
    let v = rgb(max(c, 0)).map { x in min(max(x, 0), 1) }.map { $0 <= 0.0031308 ? 12.92 * $0 : 1.055 * pow($0, 1 / 2.4) - 0.055 }
    return NSColor(srgbRed: v[0], green: v[1], blue: v[2], alpha: 1)
}

// Brand hue and chroma kept; lightness picked for contrast: light on a dark menu bar/menu, dark on a light one.
func toolColor(chroma: Double, hue: Double) -> NSColor {
    let dark = oklch(0.82, chroma, hue), light = oklch(0.45, chroma, hue)
    return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
}
let claudeColor = toolColor(chroma: 0.14, hue: 39), codexColor = toolColor(chroma: 0.2, hue: 256)
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
    let hour = 3600.0, week = 7 * 24 * hour
    let keys = [("five_hour", "5-hour", 5 * hour, true), ("seven_day", "Weekly", week, true),
                ("seven_day_opus", "Weekly Opus", week, false), ("seven_day_sonnet", "Weekly Sonnet", week, false)]
    let windows = keys.compactMap { key, name, length, inTitle -> Window? in
        guard let w = j[key] as? [String: Any], let used = w["utilization"] as? Double else { return nil }
        return Window(name: name, used: used, reset: date(w["resets_at"]), length: length, inTitle: inTitle)
    }
    // Newer per-model weekly limits only appear in `limits`.
    let scoped = (j["limits"] as? [[String: Any]] ?? []).compactMap { l -> Window? in
        guard l["kind"] as? String == "weekly_scoped", let used = l["percent"] as? Double,
              let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
        else { return nil }
        return Window(name: "Weekly \(model)", used: used, reset: date(l["resets_at"]), length: week, inTitle: false)
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
        let seconds = w["limit_window_seconds"] as? Double ?? 0, hours = Int((seconds / 3600).rounded())
        let name = hours == 0 ? "Limit" : hours < 24 ? "\(hours)-hour" : hours == 168 ? "Weekly" : "\(hours / 24)-day"
        let reset = (w["reset_at"] as? Double).map(Date.init(timeIntervalSince1970:))
            ?? (w["reset_after_seconds"] as? Double).map { Date(timeIntervalSinceNow: $0) }
        return Window(name: name, used: used, reset: reset, length: seconds > 0 ? seconds : nil)
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

let repo = "hkarlsen06/Readout"
// Only bundles signed with our Developer ID are installed.
// Developer ID CA + leaf OIDs (an Apple Development cert from the same team would pass an OU-only check), plus notarized.
// Must match REQ in release.sh.
let signingRequirement = #"anchor apple generic and identifier "dev.hkarlsen06.readout" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "48ZSLD4RMP" and notarized"#

struct Release { let version: String; let zip: URL; let page: URL }

// Returns the latest release if it's newer than the running version.
func newerRelease() async throws -> Release? {
    let j = try await getJSON("https://api.github.com/repos/\(repo)/releases/latest", ["Accept": "application/vnd.github+json"])
    guard let tag = j["tag_name"] as? String, let page = (j["html_url"] as? String).flatMap(URL.init(string:)),
          let asset = (j["assets"] as? [[String: Any]])?.first(where: { $0["name"] as? String == "Readout.zip" }),
          let zip = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
    else { return nil }
    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    return version.compare(currentVersion, options: .numeric) == .orderedDescending ? Release(version: version, zip: zip, page: page) : nil
}

// Downloads, verifies the signature, swaps the bundle in place, then relaunches.
func install(_ r: Release) async throws {
    let app = Bundle.main.bundleURL
    guard !app.path.contains("/AppTranslocation/") else { throw Err("Move Readout to Applications to auto-update") }
    let (zip, _) = try await URLSession.shared.download(from: r.zip)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Readout-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: zip) }
    let new = dir.appendingPathComponent("Readout.app")
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

// MARK: - System stats

// CPU % from tick deltas since the previous call.
let host = mach_host_self()  // each mach_host_self() call adds a port reference, so fetch it once
var prevTicks: [UInt32] = [0, 0, 0, 0]
func cpuUsage() -> Double {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
    }
    let t = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]  // user, system, idle, nice
    let d = zip(t, prevTicks).map { Double($0 &- $1) }
    prevTicks = t
    let total = d.reduce(0, +)
    return total > 0 ? (total - d[2]) / total * 100 : 0
}

// Average of the SoC die sensors via the private HID event API (nil on Intel).
// ponytail: matches M2+ ("PMU tdie") and M1 ("MTR Temp Sensor") names; extend if a new chip renames them.
let hid = IOHIDEventSystemClientCreate(kCFAllocatorDefault)!
let dieSensors: [IOHIDServiceClient] = {
    _ = IOHIDEventSystemClientSetMatching(hid, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
    return (IOHIDEventSystemClientCopyServices(hid) as? [IOHIDServiceClient] ?? []).filter {
        let name = IOHIDServiceClientCopyProperty($0, "Product" as CFString) as? String ?? ""
        return name.hasPrefix("PMU tdie") || name.contains("MTR Temp Sensor")
    }
}()
func cpuTemp() -> Double? {
    let temps = dieSensors.compactMap { s in IOHIDServiceClientCopyEvent(s, 15, 0, 0).map { IOHIDEventGetFloatValue($0, 15 << 16) } }
    return temps.isEmpty ? nil : temps.reduce(0, +) / Double(temps.count)
}

// Whole-system power draw as reported by the battery controller (nil on desktops).
let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
func watts() -> Double? {
    let t = IORegistryEntryCreateCFProperty(battery, "PowerTelemetryData" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any]
    return (t?["SystemLoad"] as? Int).map { Double($0) / 1000 }
}

func sysctlInt(_ name: String) -> Int {
    var v: Int32 = 0, size = MemoryLayout<Int32>.size
    sysctlbyname(name, &v, &size, nil, 0)
    return Int(v)
}
// Same source as `memory_pressure`: the kernel's "free" level, inverted.
func memoryPressure() -> Double { Double(100 - sysctlInt("kern.memorystatus_level")) }
func swapUsedGB() -> Double {
    var s = xsw_usage(), size = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &s, &size, nil, 0)
    return Double(s.xsu_used) / 1_073_741_824
}

// MARK: - Model

let tools = [("Claude Code", claudeColor), ("Codex", codexColor)]
let historyLen = 60  // 2 min of samples at 2 s

@MainActor final class Model: ObservableObject {
    @Published var results: [Result<Usage, Error>] = []
    @Published var updated = Date()
    @Published var updateNote: String?
    @Published var cpu: [Double] = []
    @Published var temp: [Double] = []
    @Published var power: [Double] = []
    @Published var mem: [Double] = []
    @Published var pressureLevel = 1  // 1 normal, 2 warning, 4 critical
    @Published var swap = 0.0

    func sample() {
        func push(_ h: inout [Double], _ v: Double?) { if let v { h = (h + [v]).suffix(historyLen) } }
        push(&cpu, cpuUsage())
        push(&temp, cpuTemp())
        push(&power, watts())
        push(&mem, memoryPressure())
        pressureLevel = sysctlInt("kern.memorystatus_vm_pressure_level")
        swap = swapUsedGB()
    }
}

// MARK: - Menu bar

let labelFont = NSFont.systemFont(ofSize: 7, weight: .bold)
let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)

// Two stacked rows: coloured usage numbers, then a grid of dim label + value.
// Drawn in draw() rather than as an image so the dynamic colours follow the menu bar's appearance.
final class StatusView: NSView {
    var usage: [(String, NSColor)] = []
    var stats: [[(String, String)]] = []  // rows of (label, value) columns
    let pad: CGFloat = 2.5, gap: CGFloat = 6, inset: CGFloat = 4

    override func hitTest(_ p: NSPoint) -> NSView? { nil }  // clicks go to the status button

    private func w(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) }
    private var cols: Range<Int> { 0..<(stats.first?.count ?? 0) }
    private func labelW(_ c: Int) -> CGFloat { stats.map { w($0[c].0, labelFont) }.max() ?? 0 }
    private func valueW(_ c: Int) -> CGFloat { stats.map { w($0[c].1, valueFont) }.max() ?? 0 }
    private var usageW: CGFloat { usage.map { w($0.0, valueFont) }.max() ?? 0 }

    var contentWidth: CGFloat {
        inset * 2 + usageW + cols.map { gap * 1.5 + labelW($0) + pad + valueW($0) }.reduce(0, +)
    }

    override func draw(_ r: NSRect) {
        let base = floor(bounds.midY - 11)
        let rowY = [base + 11, base + 0.5]
        for (i, (s, color)) in usage.prefix(2).enumerated() {
            (s as NSString).draw(at: NSPoint(x: inset, y: rowY[i]), withAttributes: [.font: valueFont, .foregroundColor: color])
        }
        var x = inset + usageW
        for c in cols {
            x += gap * 1.5
            let lw = labelW(c), vw = valueW(c)
            for (i, row) in stats.prefix(2).enumerated() {
                (row[c].0 as NSString).draw(at: NSPoint(x: x, y: rowY[i] + 1.6),
                                            withAttributes: [.font: labelFont, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.75)])
                (row[c].1 as NSString).draw(at: NSPoint(x: x + lw + pad + vw - w(row[c].1, valueFont), y: rowY[i]),
                                            withAttributes: [.font: valueFont, .foregroundColor: NSColor.labelColor])
            }
            x += lw + pad + vw
        }
    }
}

// MARK: - Dropdown

let cardBackground = RoundedRectangle(cornerRadius: 9)

// Tick marks the pace: bar past it = under pace, short of it = burning faster than time.
struct Meter: View {
    let fraction: Double, color: Color, pace: Double?
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: g.size.width * fraction)
                if let pace {
                    Capsule().fill(.primary).frame(width: 2).padding(.vertical, -2)
                        .offset(x: min(max(0, g.size.width * pace - 1), g.size.width - 2))
                }
            }
        }
        .frame(height: 5)
    }
}

struct Spark: View {
    let data: [Double], lo: Double?, hi: Double?, color: Color
    var body: some View {
        GeometryReader { g in
            let lo = self.lo ?? (data.min() ?? 0) - 1
            let hi = max(self.hi ?? (data.max() ?? 0) + 1, lo + 1)
            let pts = data.enumerated().map { i, v in
                CGPoint(x: g.size.width * CGFloat(i + historyLen - data.count) / CGFloat(historyLen - 1),
                        y: g.size.height * (1 - CGFloat((min(v, hi) - lo) / (hi - lo))))
            }
            if let first = pts.first, let last = pts.last {
                Path { p in
                    p.addLines(pts)
                    p.addLine(to: CGPoint(x: last.x, y: g.size.height))
                    p.addLine(to: CGPoint(x: first.x, y: g.size.height))
                }
                .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                Path { $0.addLines(pts) }.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .frame(height: 26)
    }
}

struct UsageCard: View {
    let name: String, color: Color, result: Result<Usage, Error>?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
                Spacer()
                if let plan = (try? result?.get())?.plan { Text(plan).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            switch result {
            case nil:
                Text("Loading…").font(.system(size: 11)).foregroundStyle(.secondary)
            case .success(let u):
                ForEach(u.windows.indices, id: \.self) { i in
                    let w = u.windows[i]
                    VStack(spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(w.name).font(.system(size: 12))
                            Spacer()
                            Text("\(left(w))%").font(.system(size: 12, weight: .medium)).monospacedDigit()
                            Text("↻ \(until(w.reset))").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Meter(fraction: Double(left(w)) / 100, color: color, pace: w.pace)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(w.name): \(left(w))% left, resets in \(until(w.reset))")
                }
                if u.credits > 0 {
                    HStack {
                        Text("Credits").font(.system(size: 12))
                        Spacer()
                        Text(Int(u.credits).formatted()).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    }
                }
                if u.windows.isEmpty && u.credits == 0 {
                    Text("No limits reported").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case .failure(let e):
                Text(e.localizedDescription).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: cardBackground)
    }
}

struct StatCard: View {
    let title: String, value: Double?, format: String, unit: String, data: [Double], color: Color
    var lo: Double? = nil, hi: Double? = nil, badge: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value.map { String(format: format, $0) } ?? "–")
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if let badge {
                    Text(badge).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(color.opacity(0.18), in: Capsule())
                }
            }
            Spark(data: data, lo: lo, hi: hi, color: color)
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: cardBackground)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value.map { String(format: format, $0) } ?? "unavailable") \(unit) \(badge ?? "")")
    }
}

struct Panel: View {
    @ObservedObject var m: Model
    var body: some View {
        let (level, levelColor): (String, Color) = [2: ("Warning", .yellow), 4: ("Critical", .red)][m.pressureLevel] ?? ("Normal", .green)
        VStack(spacing: 8) {
            ForEach(tools.indices, id: \.self) { i in
                UsageCard(name: tools[i].0, color: Color(nsColor: tools[i].1), result: m.results.indices.contains(i) ? m.results[i] : nil)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    StatCard(title: "CPU", value: m.cpu.last, format: "%.0f", unit: "%", data: m.cpu, color: .blue, lo: 0, hi: 100)
                    StatCard(title: "TEMPERATURE", value: m.temp.last, format: "%.0f", unit: "°C", data: m.temp, color: .orange)
                }
                GridRow {
                    StatCard(title: "POWER", value: m.power.last, format: "%.1f", unit: "W", data: m.power, color: .purple, lo: 0)
                    StatCard(title: "MEMORY PRESSURE", value: m.mem.last, format: "%.0f", unit: "%", data: m.mem, color: levelColor,
                             lo: 0, hi: 100, badge: level)
                }
            }
            HStack {
                Text("v\(currentVersion) · Updated \(m.updated.formatted(date: .omitted, time: .shortened))" + (m.updateNote.map { " · \($0)" } ?? ""))
                    .lineLimit(1)
                Spacer()
                Text(String(format: "Swap %.1f GB", m.swap))
            }
            .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 2)
        }
        .padding(10)
        .frame(width: 300)
    }
}

// MARK: - App

@MainActor final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let model = Model()
    let statusView = StatusView()
    lazy var panel: NSMenuItem = {
        let i = NSMenuItem()
        i.view = NSHostingView(rootView: Panel(m: model))
        return i
    }()
    var available: Release?   // newer release we couldn't install automatically
    var refreshing = false, installing = false

    func applicationDidFinishLaunching(_ n: Notification) {
        if let b = item.button {
            statusView.frame = b.bounds
            statusView.autoresizingMask = [.width, .height]
            b.addSubview(statusView)
        }
        item.menu = NSMenu()
        item.menu?.autoenablesItems = false
        item.menu?.delegate = self
        _ = cpuUsage()  // prime the tick counters
        tick()
        // .common so the dropdown keeps updating while it's open.
        RunLoop.main.add(Timer(timeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { self.tick() } }, forMode: .common)
        refresh()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Task { @MainActor in self.refresh() } }.tolerance = 30
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in Task { @MainActor in self.update(manual: false) } }
        update(manual: false)
    }

    func tick() {
        model.sample()
        redraw()
    }

    func redraw() {
        let f = { (fmt: String, v: Double?) in v.map { String(format: fmt, $0) } ?? "–" }
        statusView.usage = tools.indices.map { i in
            (model.results.indices.contains(i) ? titleText(model.results[i]) : "…", tools[i].1)
        }
        statusView.stats = [
            [("CPU", f("%.0f%%", model.cpu.last)), ("PWR", f("%.0fW", model.power.last))],
            [("TMP", f("%.0f°", model.temp.last)), ("MEM", f("%.0f%%", model.mem.last))],
        ]
        item.length = statusView.contentWidth
        statusView.needsDisplay = true
        // Colour alone tells the usage numbers apart, so spell everything out for hover and VoiceOver.
        let usage = zip(tools, model.results).map { t, r -> String in
            guard case .success(let u) = r else { return "\(t.0): error" }
            return "\(t.0): " + u.windows.map { "\(left($0))% \($0.name) left" }.joined(separator: ", ")
        }
        item.button?.toolTip = usage.joined(separator: "\n")
        item.button?.setAccessibilityLabel((usage + ["CPU \(f("%.0f", model.cpu.last))%", "temperature \(f("%.0f", model.temp.last))°C",
                                                     "power \(f("%.0f", model.power.last)) watts",
                                                     "memory pressure \(f("%.0f", model.mem.last))%"]).joined(separator: ". "))
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
            let new = [await c, await x], old = model.results
            model.results = new.indices.map { i in
                if case .failure(let e as Err) = new[i], e.transient, i < old.count, case .success = old[i] { return old[i] }
                return new[i]
            }
            model.updated = Date()
            fitPanel()  // usage rows may have appeared while the menu is open
            redraw()
        }
    }

    @objc func checkForUpdates() { update(manual: true) }

    func update(manual: Bool) {
        guard !installing, currentVersion != "0.0.0" else { return }  // 0.0.0 = local dev build
        installing = true
        Task {
            defer { installing = false }
            let r: Release?
            do { r = try await newerRelease() } catch { if manual { model.updateNote = "Update check failed" }; return }
            guard let r else { if manual { model.updateNote = "Up to date" }; return }
            model.updateNote = "Installing v\(r.version)…"
            do { try await install(r) } catch { available = r; model.updateNote = error.localizedDescription }
        }
    }

    @objc func openRelease() { if let available { NSWorkspace.shared.open(available.page) } }

    @objc func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    func fitPanel() { if let v = panel.view { v.frame.size = v.fittingSize } }

    // Rebuilt on open so the panel is sized to its current content and the toggles are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fitPanel()
        menu.addItem(panel)
        menu.addItem(.separator())
        if let available {
            menu.addItem(withTitle: "Download v\(available.version)…", action: #selector(openRelease), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "").target = self
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
