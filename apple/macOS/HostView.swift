import AppKit
import SwiftUI

struct HostView: View {
    @EnvironmentObject private var host: HostSession
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if host.isSharing { sharing } else { idle }
        }
        .padding(24)
        .frame(maxWidth: 640, alignment: .leading)
        .task { await host.loadDisplays() }
    }

    // MARK: Not sharing

    private var idle: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Share this Mac", systemImage: "rectangle.on.rectangle").font(.title2.bold())
            Text("You'll get an ID and PIN to give to the person connecting. You approve every connection.")
                .foregroundStyle(.secondary)

            if host.displays.count > 1 {
                Picker("Screen", selection: $host.selectedDisplayID) {
                    ForEach(host.displays, id: \.displayID) { d in
                        Text("Display \(d.displayID) — \(d.width)×\(d.height)").tag(Optional(d.displayID))
                    }
                }
                .frame(maxWidth: 360)
            }

            Button {
                Task { await host.start() }
            } label: {
                Text(host.isStarting ? "Starting…" : "Start sharing").frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(host.isStarting)

            if host.needsScreenPermission {
                permissionBox(
                    "Remote Desktop needs Screen Recording permission. Turn it on in System Settings, then quit and reopen the app.",
                    pane: "Privacy_ScreenCapture")
            }
            if let error = host.error {
                Text(error).foregroundStyle(.red)
                if AppConfig.serverURL == nil {
                    Button("Open Settings") { openSettings() }
                }
            }
        }
    }

    // MARK: Sharing

    private var sharing: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Circle().fill(host.online ? Color.green : Color.orange).frame(width: 9, height: 9)
                        Text(host.online ? "Online — waiting for connections" : "Connecting…")
                    }
                    credential("Computer ID", RoomFormat.display(host.room), copy: host.room)
                    credential("PIN", host.pin, copy: host.pin)
                    if host.locked {
                        Text("Someone entered the wrong PIN too many times, so new connections are blocked. Click “New ID & PIN”.")
                            .foregroundStyle(.red)
                    }
                    HStack {
                        Button("New ID & PIN") { host.resetCredentials() }
                        Spacer()
                        Button("Stop sharing", role: .destructive) { host.stop() }
                    }
                }
                .padding(8)
            }

            GroupBox("Viewers") {
                VStack(alignment: .leading, spacing: 10) {
                    if host.viewers.isEmpty {
                        Text("No one is connected. Share the ID and PIN to let someone in.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(host.viewers) { viewer in viewerRow(viewer) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            GroupBox("Remote control") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Allow viewers to control this Mac", isOn: $host.allowControl)
                        .toggleStyle(.switch)
                    if host.allowControl && !host.accessibilityTrusted {
                        permissionBox(
                            "To be controlled, Remote Desktop needs Accessibility permission. Turn it on in System Settings. If it's already on, turn it off and on again.",
                            pane: "Privacy_Accessibility")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }

    private func credential(_ label: String, _ value: String, copy: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(value).font(.system(size: 30, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copy, forType: .string)
                }
            }
        }
    }

    private func viewerRow(_ viewer: HostSession.Viewer) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(viewer.place)
                Text([stateText(viewer.state), viewer.ip].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if viewer.state == .pending {
                Button("Decline") { host.disconnect(viewer.id) }
                Button("Accept") { host.accept(viewer.id) }.buttonStyle(.borderedProminent)
            } else {
                Button("Disconnect", role: .destructive) { host.disconnect(viewer.id) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(viewer.state == .pending ? Color.orange : .clear))
    }

    private func stateText(_ s: HostSession.Viewer.State) -> String {
        switch s {
        case .pending: return "Wants to connect"
        case .connecting: return "Connecting…"
        case .connected: return "Watching"
        case .relayed: return "Watching (relayed)"
        case .failed: return "Connection failed"
        }
    }

    private func permissionBox(_ text: String, pane: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).foregroundStyle(.orange)
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
            }
        }
    }
}
