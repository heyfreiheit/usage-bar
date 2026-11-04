import ServiceManagement
import SwiftUI

@main
struct UsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = UsageStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(store)
        } label: {
            MenuLabel().environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Window("Bei claude.ai anmelden", id: "login") {
            LoginView()
                .environmentObject(store)
                .frame(minWidth: 460, minHeight: 600)
        }
        .defaultSize(width: 520, height: 720)
        .defaultLaunchBehavior(.suppressed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // USAGE_BAR_DEMO=1 zeigt Beispielwerte, ohne Login und ohne Anmeldeobjekt (für Screenshots).
        if ProcessInfo.processInfo.environment["USAGE_BAR_DEMO"] == "1" {
            Task { @MainActor in UsageStore.shared.startDemo() }
            return
        }
        // Beim ersten Start als Anmeldeobjekt eintragen, danach entscheidet der Schalter im Menü.
        if !UserDefaults.standard.bool(forKey: "didSetupLogin") {
            UserDefaults.standard.set(true, forKey: "didSetupLogin")
            try? SMAppService.mainApp.register()
        }
        Task { @MainActor in UsageStore.shared.start() }
    }
}
