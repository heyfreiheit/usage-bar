import ServiceManagement
import SwiftUI
import WebKit

private let de = Locale(identifier: "de_DE")

// MARK: Menüleiste

struct MenuLabel: View {
    @EnvironmentObject var s: UsageStore
    @AppStorage("showFree") private var showFree = false
    @Environment(\.openWindow) private var openWindow
    @State private var didAutoOpen = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).monospacedDigit()
        }
        .onChange(of: s.needsLogin) { _, needs in
            // Beim ersten Start ohne Login gleich das Anmeldefenster zeigen.
            if needs, !didAutoOpen, s.windows.isEmpty {
                didAutoOpen = true
                openWindow(id: "login")
                NSApp.activate()
            }
        }
    }

    private var five: LimitWindow? { s.windows.first { $0.id == "five_hour" } }
    private var week: LimitWindow? { s.windows.first { $0.id == "seven_day" } }

    private var text: String {
        if s.windows.isEmpty { return s.needsLogin ? "Login" : "…" }
        func v(_ w: LimitWindow?) -> String {
            guard let w else { return "–" }
            return "\(Int((showFree ? w.free : w.used).rounded())) %"
        }
        return "5h \(v(five))  W \(v(week))"
    }

    private var icon: String {
        if s.needsLogin && s.windows.isEmpty { return "person.crop.circle.badge.exclamationmark" }
        let peak = max(five?.used ?? 0, week?.used ?? 0)
        switch peak {
        case 90...: return "exclamationmark.triangle.fill"
        case 67..<90: return "gauge.with.dots.needle.67percent"
        case 33..<67: return "gauge.with.dots.needle.50percent"
        default: return "gauge.with.dots.needle.33percent"
        }
    }
}

// MARK: Menü

struct MenuContent: View {
    @EnvironmentObject var s: UsageStore
    @AppStorage("showFree") private var showFree = false
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            VStack(alignment: .leading, spacing: 14) {
                header

                if s.needsLogin {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Melde dich einmal bei claude.ai an, dann zeigt die App deine Limits.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Bei claude.ai anmelden") {
                            openWindow(id: "login")
                            NSApp.activate()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                ForEach(s.windows) { w in
                    LimitRow(window: w, now: ctx.date)
                }

                if !s.shares.isEmpty {
                    Text("Woche verteilt auf " + s.shares.map { "\($0.name) \(Int($0.percent.rounded())) %" }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let e = s.extra, e.enabled, let used = e.usedCents, let limit = e.limitCents, limit > 0 {
                    HStack {
                        Text("Extra-Nutzung").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(euro(used)) von \(euro(limit))").monospacedDigit()
                    }
                    .font(.caption)
                }

                if let err = s.error {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                settings
            }
            .padding(16)
            .frame(width: 310)
        }
        .onAppear {
            s.refreshIfStale()
            loginItem = SMAppService.mainApp.status == .enabled
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Usage Bar").font(.headline)
            Spacer()
            if let u = s.updatedAt {
                Text(u.formatted(.dateTime.hour().minute().locale(de)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Zuletzt aktualisiert")
            }
            Button {
                Task { await s.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: s.loading)
            }
            .buttonStyle(.borderless)
            .help("Jetzt aktualisieren")
            .disabled(s.loading)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Menüleiste zeigt", selection: $showFree) {
                Text("Verbraucht").tag(false)
                Text("Noch frei").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle("Beim Anmelden am Mac starten", isOn: $loginItem)
                .toggleStyle(.checkbox)
                .onChange(of: loginItem) { _, on in
                    if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                }

            HStack {
                if !s.needsLogin {
                    Button("Abmelden") { Task { await s.logout() } }
                }
                Spacer()
                Button("Beenden") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func euro(_ cents: Double) -> String {
        (cents / 100).formatted(.currency(code: "EUR").locale(de))
    }
}

struct LimitRow: View {
    let window: LimitWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(window.used.rounded())) %")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            UsageBar(used: window.used / 100, elapsed: window.elapsed(at: now), tint: tint)
            HStack {
                Text("\(Int(window.free.rounded())) % frei")
                Spacer()
                Text(resetText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private var tint: Color {
        switch window.used {
        case 90...: .red
        case 70..<90: .orange
        default: .accentColor
        }
    }

    private var resetText: String {
        guard let r = window.resetsAt else { return "Fenster läuft noch nicht" }
        let secs = r.timeIntervalSince(now)
        if secs <= 0 { return "wird gerade zurückgesetzt" }
        let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
        if secs < 86400 {
            return h > 0 ? "Reset in \(h) Std. \(m) Min." : "Reset in \(max(1, m)) Min."
        }
        let day = r.formatted(.dateTime.weekday(.abbreviated).locale(de))
        let time = r.formatted(.dateTime.hour().minute().locale(de))
        return "Reset \(day) \(time) Uhr"
    }
}

/// Balken für den Verbrauch, der feine Strich zeigt, wie weit das Zeitfenster schon gelaufen ist.
struct UsageBar: View {
    let used: Double
    let elapsed: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: max(used > 0 ? 6 : 0, geo.size.width * min(1, used)))
                if let e = elapsed {
                    Rectangle()
                        .fill(.secondary)
                        .frame(width: 1.5, height: geo.size.height + 6)
                        .offset(x: geo.size.width * e - 0.75)
                        .help("So weit ist das Zeitfenster schon gelaufen")
                }
            }
        }
        .frame(height: 7)
    }
}

// MARK: Login

struct LoginView: View {
    @EnvironmentObject var s: UsageStore
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            Text("Melde dich mit deinem Claude-Konto an. Die App liest danach nur deine Nutzungsanzeige aus, der Login bleibt auf diesem Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            Divider()
            LoginWebView()
        }
        .onChange(of: s.updatedAt) { _, new in
            if new != nil, !s.needsLogin { dismissWindow(id: "login") }
        }
    }
}

struct LoginWebView: NSViewRepresentable {
    @EnvironmentObject var s: UsageStore

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = UsageStore.userAgent
        web.uiDelegate = context.coordinator
        web.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        context.coordinator.watch(web)
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, WKUIDelegate {
        private var timer: Timer?
        private var reported = false

        /// Prüft regelmäßig, ob der Session-Cookie gesetzt ist und die Login-Seite verlassen wurde.
        func watch(_ web: WKWebView) {
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self, weak web] _ in
                Task { @MainActor in
                    guard let self, let web, !self.reported else { return }
                    let path = web.url?.path() ?? ""
                    guard !path.contains("login"), !path.contains("magic-link") else { return }
                    if await UsageStore.shared.hasSession() {
                        self.reported = true
                        UsageStore.shared.loginDetected()
                    }
                }
            }
        }

        func stop() { timer?.invalidate() }

        /// Pop-ups (z. B. Google-Login) im selben Fenster öffnen.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            webView.load(navigationAction.request)
            return nil
        }
    }
}
