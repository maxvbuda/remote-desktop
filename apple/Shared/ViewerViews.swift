import SwiftUI

struct ConnectView: View {
    var onConnect: (ViewerSession) -> Void
    var openSettings: () -> Void

    @AppStorage("lastRoom") private var room = ""
    @State private var pin = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Connect to a computer", systemImage: "arrow.down.right.and.arrow.up.left")
                .font(.title2.bold())
            Text("Enter the ID and PIN shown on the Mac you want to reach.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Computer ID").font(.caption).foregroundStyle(.secondary)
                TextField("123 456 789", text: $room)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.monospaced())
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("PIN").font(.caption).foregroundStyle(.secondary)
                TextField("ABC234", text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .onSubmit(connect)
            }

            Button(action: connect) {
                Text("Connect").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
    }

    private func connect() {
        let r = RoomFormat.normalizeRoom(room)
        let p = RoomFormat.normalizePin(pin)
        guard r.count == 9 else { error = "The computer ID has 9 digits."; return }
        guard p.count >= 4 else { error = "Enter the PIN shown on the other computer."; return }
        guard let server = AppConfig.serverURL else {
            error = "Set the server address in Settings first."
            openSettings()
            return
        }
        error = nil
        room = RoomFormat.display(r)
        onConnect(ViewerSession(room: r, pin: p, server: server))
    }
}

struct ViewerScreen: View {
    @ObservedObject var session: ViewerSession
    var onClose: () -> Void

    @State private var showText = false
    @State private var text = ""
    @State private var showKeyboard = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack {
                #if os(macOS)
                RemoteVideo(session: session)
                #else
                RemoteVideo(session: session, showKeyboard: $showKeyboard)
                #endif
                if session.phase != .live {
                    overlay
                }
            }
            .background(Color.black)
        }
        .sheet(isPresented: $showText) { textSheet }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(RoomFormat.display(session.room)).font(.headline.monospaced())
            badge
            Spacer()
            Button { showText = true } label: { Label("Send text", systemImage: "text.cursor") }
                .disabled(!session.canControl)
            #if os(iOS)
            Button { showKeyboard.toggle() } label: { Label("Keyboard", systemImage: "keyboard") }
                .disabled(!session.canControl)
            #endif
            Button(role: .destructive) {
                session.disconnect()
                onClose()
            } label: { Label("Disconnect", systemImage: "xmark.circle") }
        }
        #if os(iOS)
        .labelStyle(.iconOnly)
        #endif
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var badge: some View {
        let on = session.canControl
        return Text(on ? "Control on" : "View only")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(on ? Color.green.opacity(0.2) : Color.secondary.opacity(0.2)))
            .foregroundStyle(on ? Color.green : Color.secondary)
    }

    private var overlay: some View {
        VStack(spacing: 16) {
            if case .ended = session.phase {
                Text(session.statusText).multilineTextAlignment(.center)
                Button("Back", action: onClose).buttonStyle(.borderedProminent)
            } else {
                ProgressView().controlSize(.large).tint(.white)
                Text(session.statusText)
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.75))
    }

    private var textSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Type text on the remote computer").font(.headline)
            TextEditor(text: $text)
                .frame(minWidth: 320, minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
            HStack {
                Spacer()
                Button("Cancel") { showText = false }
                Button("Type it") {
                    session.send(["t": "text", "s": String(text.prefix(5000))])
                    text = ""
                    showText = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.isEmpty)
            }
        }
        .padding(20)
    }
}

struct ServerSettingsView: View {
    @AppStorage(AppConfig.serverKey) private var server = ""

    var body: some View {
        Form {
            Section {
                TextField("remote-desktop.example.workers.dev", text: $server)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            } header: {
                Text("Server address")
            } footer: {
                Text(AppConfig.builtInServer.isEmpty
                     ? "The address of your Cloudflare Worker. Both computers must use the same server."
                     : "Leave empty to use the built-in server (\(AppConfig.builtInServer)).")
            }
        }
        #if os(macOS)
        .padding(20)
        .frame(width: 460)
        #endif
    }
}
