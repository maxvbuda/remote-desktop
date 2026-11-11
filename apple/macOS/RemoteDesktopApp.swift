import AppKit
import SwiftUI

@main
struct RemoteDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var host = HostSession()

    var body: some Scene {
        WindowGroup("Remote Desktop") {
            RootView()
                .environmentObject(host)
                .frame(minWidth: 760, minHeight: 540)
        }
        Settings {
            ServerSettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RootView: View {
    @State private var viewer: ViewerSession?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let viewer {
            ViewerScreen(session: viewer) { self.viewer = nil }
        } else {
            TabView {
                ScrollView { HostView().frame(maxWidth: .infinity) }
                    .tabItem { Label("Share this Mac", systemImage: "rectangle.on.rectangle") }
                ConnectView(onConnect: { viewer = $0 }, openSettings: { openSettings() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tabItem { Label("Connect", systemImage: "display") }
            }
            .padding(.top, 8)
        }
    }
}
