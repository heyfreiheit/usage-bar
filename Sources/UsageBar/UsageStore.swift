import AppKit
import Foundation
import WebKit

/// Ein Limit-Fenster, z. B. die 5-Stunden-Session oder die Woche.
struct LimitWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let used: Double          // Prozent 0...100
    let resetsAt: Date?
    let length: TimeInterval  // Länge des Fensters

    var free: Double { max(0, 100 - used) }

    /// Wie weit das Zeitfenster schon gelaufen ist (0...1). Nil, wenn kein Fenster läuft.
    func elapsed(at now: Date = .now) -> Double? {
        guard let r = resetsAt else { return nil }
        let start = r.addingTimeInterval(-length)
        return min(1, max(0, now.timeIntervalSince(start) / length))
    }
}

struct ExtraUsage: Equatable {
    let enabled: Bool
    let usedCents: Double?
    let limitCents: Double?
}

/// Anteil am Wochenverbrauch, z. B. Claude Code 99 %.
struct Share: Equatable, Hashable {
    let name: String
    let percent: Double
}

/// Holt die Limits über claude.ai, so wie es die Nutzungsanzeige in der Claude-App macht.
/// Der Login liegt im WebKit-Speicher dieser App, es werden keine Tokens kopiert.
@MainActor
final class UsageStore: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = UsageStore()

    @Published private(set) var windows: [LimitWindow] = []
    @Published private(set) var extra: ExtraUsage?
    @Published private(set) var shares: [Share] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var loading = false
    @Published private(set) var needsLogin = false
    @Published private(set) var error: String?

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
    private static let base = URL(string: "https://claude.ai/robots.txt")!

    private var webView: WKWebView!
    private var pageReady = false
    private var pageLoading = false
    private var pageWaiters: [CheckedContinuation<Bool, Never>] = []
    private var timer: Timer?

    private var orgId: String? {
        get { UserDefaults.standard.string(forKey: "orgId") }
        set { UserDefaults.standard.set(newValue, forKey: "orgId") }
    }

    private override init() { super.init() }

    func start() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self

        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            Task { @MainActor in await UsageStore.shared.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                UsageStore.shared.pageReady = false
                await UsageStore.shared.refresh()
            }
        }
        Task { await refresh() }
    }

    private var demo = false

    func startDemo() {
        demo = true
        let now = Date()
        windows = [
            LimitWindow(id: "five_hour", label: "Session · 5 Stunden", used: 38,
                        resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60), length: 5 * 3600),
            LimitWindow(id: "seven_day", label: "Woche · alle Modelle", used: 52,
                        resetsAt: now.addingTimeInterval(3 * 86400 + 5 * 3600), length: 7 * 86400),
            LimitWindow(id: "weekly_scoped-2", label: "Woche · Fable", used: 12,
                        resetsAt: now.addingTimeInterval(3 * 86400 + 5 * 3600), length: 7 * 86400),
        ]
        shares = [Share(name: "Claude Code", percent: 81), Share(name: "Chats", percent: 19)]
        extra = ExtraUsage(enabled: true, usedCents: 0, limitCents: 4000)
        updatedAt = now
    }

    /// Beim Öffnen des Menüs nachladen, wenn die Werte älter als 30 Sekunden sind.
    func refreshIfStale() {
        if let u = updatedAt, Date().timeIntervalSince(u) < 30 { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !loading, !demo else { return }
        loading = true
        defer { loading = false }

        guard await hasSession() else {
            needsLogin = true
            error = nil
            return
        }
        guard await ensurePage() else {
            error = "claude.ai ist gerade nicht erreichbar."
            return
        }
        do {
            let raw = try await webView.callAsyncJavaScript(
                Self.script, arguments: ["hint": orgId ?? ""], in: nil, contentWorld: .defaultClient)
            handle(raw as? [String: Any] ?? [:])
        } catch {
            pageReady = false
            self.error = "Abruf fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func handle(_ r: [String: Any]) {
        switch r["status"] as? String {
        case "ok":
            guard let text = r["usage"] as? String,
                  let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                error = "Antwort von claude.ai nicht lesbar."
                return
            }
            orgId = r["org"] as? String
            (windows, extra, shares) = Self.parse(json)
            updatedAt = Date()
            needsLogin = false
            error = nil
            Self.saveRaw(data)
        case "auth":
            needsLogin = true
            error = nil
        case "blocked":
            pageReady = false
            error = "claude.ai blockt den Abruf gerade, nächster Versuch in 2 Minuten."
        case "nousage":
            error = "Kein Konto mit Plan-Limits gefunden."
        default:
            pageReady = false
            error = "claude.ai antwortet mit Fehler \(r["code"] ?? "?")."
        }
    }

    // MARK: Login

    func hasSession() async -> Bool {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cookies.contains { $0.name == "sessionKey" && $0.domain.hasSuffix("claude.ai") && ($0.expiresDate ?? .distantFuture) > Date() }
    }

    /// Wird vom Login-Fenster aufgerufen, sobald der Session-Cookie da ist.
    func loginDetected() {
        needsLogin = false
        pageReady = false
        Task { await refresh() }
    }

    func logout() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let claude = records.filter { $0.displayName.contains("claude.ai") || $0.displayName.contains("anthropic") }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: claude)
        for c in await store.httpCookieStore.allCookies() where c.domain.hasSuffix("claude.ai") {
            await store.httpCookieStore.deleteCookie(c)
        }
        orgId = nil
        windows = []
        extra = nil
        shares = []
        updatedAt = nil
        pageReady = false
        needsLogin = true
    }

    // MARK: Seite für den Abruf

    /// Eine kleine Seite auf claude.ai, damit fetch() mit den Cookies dieser App läuft.
    private func ensurePage() async -> Bool {
        if pageReady { return true }
        return await withCheckedContinuation { cont in
            pageWaiters.append(cont)
            guard !pageLoading else { return }
            pageLoading = true
            webView.load(URLRequest(url: Self.base))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(25))
                if self.pageLoading { self.finishPage(false) }
            }
        }
    }

    private func finishPage(_ ok: Bool) {
        pageLoading = false
        pageReady = ok
        let waiters = pageWaiters
        pageWaiters = []
        waiters.forEach { $0.resume(returning: ok) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishPage(webView.url?.host()?.hasSuffix("claude.ai") == true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishPage(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishPage(false)
    }

    private static let script = """
    const opts = { credentials: 'include', headers: { 'accept': 'application/json' } };
    const isJson = (r) => (r.headers.get('content-type') || '').includes('json');
    async function usage(id) {
      const r = await fetch(`/api/organizations/${id}/usage`, opts);
      if (!r.ok || !isJson(r)) return null;
      const u = await r.json();
      return (u && typeof u === 'object' && 'five_hour' in u) ? u : null;
    }
    if (hint) {
      const u = await usage(hint);
      if (u) return { status: 'ok', org: hint, usage: JSON.stringify(u) };
    }
    const o = await fetch('/api/organizations', opts);
    if ((o.status === 401 || o.status === 403) && isJson(o)) return { status: 'auth', code: o.status };
    if (!isJson(o)) return { status: 'blocked', code: o.status };
    if (!o.ok) return { status: 'error', code: o.status };
    const orgs = await o.json();
    for (const org of orgs) {
      const u = await usage(org.uuid);
      if (u) return { status: 'ok', org: org.uuid, usage: JSON.stringify(u) };
    }
    return { status: 'nousage', code: orgs.length };
    """

    // MARK: Auswerten

    static func parse(_ json: [String: Any]) -> ([LimitWindow], ExtraUsage?, [Share]) {
        var out = parseLimits(json["limits"])
        // Fallback auf die alten Felder, falls die Liste fehlt. Nur bekannte Namen,
        // die Antwort enthält auch interne Felder mit Codenamen.
        if out.isEmpty { out = parseLegacy(json) }

        var extra: ExtraUsage?
        if let e = json["extra_usage"] as? [String: Any] {
            extra = ExtraUsage(
                enabled: e["is_enabled"] as? Bool ?? false,
                usedCents: number(e["used_credits"]),
                limitCents: number(e["monthly_limit"]))
        }

        var shares: [Share] = []
        if let b = json["seven_day_breakdown"] as? [String: Any], let rows = b["rows"] as? [[String: Any]] {
            shares = rows.compactMap { r in
                guard let name = r["display_name"] as? String, let p = number(r["percent"]), p >= 1 else { return nil }
                return Share(name: name, percent: p)
            }
            .sorted { $0.percent > $1.percent }
        }
        return (out, extra, shares)
    }

    /// Die Liste, die auch die Nutzungsanzeige in der Claude-App verwendet.
    private static func parseLimits(_ v: Any?) -> [LimitWindow] {
        guard let list = v as? [[String: Any]] else { return [] }
        return list.enumerated().compactMap { i, d in
            guard let kind = d["kind"] as? String, let used = number(d["percent"]) else { return nil }
            let isSession = (d["group"] as? String) == "session" || kind.hasPrefix("session")
            let id: String
            let label: String
            switch kind {
            case "session":
                id = "five_hour"; label = "Session · 5 Stunden"
            case "weekly_all":
                id = "seven_day"; label = "Woche · alle Modelle"
            default:
                let scope = d["scope"] as? [String: Any]
                let name = ((scope?["model"] as? [String: Any])?["display_name"] as? String)
                    ?? ((scope?["surface"] as? [String: Any])?["display_name"] as? String)
                    ?? "Teilbereich"
                id = "\(kind)-\(i)"
                label = isSession ? "Session · \(name)" : "Woche · \(name)"
            }
            return LimitWindow(id: id, label: label, used: used, resetsAt: date(d["resets_at"]),
                               length: isSession ? 5 * 3600 : 7 * 86400)
        }
    }

    private static func parseLegacy(_ json: [String: Any]) -> [LimitWindow] {
        var out: [LimitWindow] = []
        for (key, value) in json {
            guard key == "five_hour" || key.hasPrefix("seven_day_") || key == "seven_day",
                  !key.contains("oauth"), key != "seven_day_breakdown",
                  let d = value as? [String: Any], let used = number(d["utilization"]) else { continue }
            let isFive = key.hasPrefix("five_hour")
            out.append(LimitWindow(
                id: key,
                label: label(for: key),
                used: used,
                resetsAt: date(d["resets_at"]),
                length: isFive ? 5 * 3600 : 7 * 86400))
        }
        out.sort { rank($0.id) == rank($1.id) ? $0.id < $1.id : rank($0.id) < rank($1.id) }
        return out
    }

    private static func rank(_ key: String) -> Int {
        switch key {
        case "five_hour": 0
        case "seven_day": 1
        default: key.hasPrefix("five_hour") ? 0 : 2
        }
    }

    private static func label(for key: String) -> String {
        switch key {
        case "five_hour": return "Session · 5 Stunden"
        case "seven_day": return "Woche · alle Modelle"
        default:
            let parts = key.split(separator: "_").map(String.init)
            let model = parts.dropFirst(2).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            return key.hasPrefix("five_hour") ? "Session · \(model)" : "Woche · \(model)"
        }
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Letzte Rohantwort zum Nachsehen (enthält nur Prozentwerte und Zeiten).
    private static func saveRaw(_ data: Data) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsageBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("last-usage.json"))
    }
}
