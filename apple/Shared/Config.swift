import Foundation

enum AppConfig {
    static let serverKey = "serverURL"

    /// Built in at compile time (RD_SERVER_URL); can be overridden in Settings.
    static var builtInServer: String {
        (Bundle.main.object(forInfoDictionaryKey: "RDServerURL") as? String) ?? ""
    }

    static var serverURL: URL? {
        let stored = UserDefaults.standard.string(forKey: serverKey) ?? ""
        return normalize(stored) ?? normalize(builtInServer)
    }

    static func normalize(_ value: String) -> URL? {
        var s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }
}

enum RoomFormat {
    static func display(_ room: String) -> String {
        var out = ""
        for (i, c) in room.enumerated() {
            if i > 0 && i % 3 == 0 { out.append(" ") }
            out.append(c)
        }
        return out
    }

    static func normalizeRoom(_ s: String) -> String { s.filter(\.isNumber) }

    static func normalizePin(_ s: String) -> String {
        s.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
