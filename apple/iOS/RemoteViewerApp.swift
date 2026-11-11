import SwiftUI

@main
struct RemoteViewerApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @State private var viewer: ViewerSession?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                ConnectView(onConnect: { viewer = $0 }, openSettings: { showSettings = true })
                    .frame(maxWidth: .infinity)
                TouchHelp().padding(.horizontal, 24)
            }
            .navigationTitle("Remote Desktop")
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                ServerSettingsView()
                    .navigationTitle("Settings")
                    .toolbar { Button("Done") { showSettings = false } }
            }
        }
        .fullScreenCover(item: $viewer) { session in
            ViewerScreen(session: session) { viewer = nil }
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}

private struct TouchHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Controls").font(.headline)
            Text("Tap to click · Double-tap to double-click · Touch and hold to right-click · Drag to click and drag · Two fingers to scroll")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 420, alignment: .leading)
    }
}
