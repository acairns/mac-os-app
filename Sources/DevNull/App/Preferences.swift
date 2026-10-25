import Foundation
import ServiceManagement

/// What this Mac remembers for itself. None of it reaches the server.
enum Preferences {
    private static let defaults = UserDefaults.standard

    static var notificationsEnabled: Bool {
        get { defaults.object(forKey: "notifications") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notifications") }
    }

    static var soundEnabled: Bool {
        get { defaults.object(forKey: "sound") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sound") }
    }

    /// Opening the app when the user logs in, which macOS keeps in Login Items, not here.
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Login item: %@", error.localizedDescription)
            }
        }
    }

    /// The conversation open when the app quit ("@username" or "org:id"), opened again on launch.
    static var lastConversation: String? {
        get { defaults.string(forKey: "last-conversation") }
        set { defaults.set(newValue, forKey: "last-conversation") }
    }
}

/// The emoji a message can be reacted with: exactly the set the server accepts, searchable by shortcode, with the ones
/// this Mac used most first.
enum Reactions {
    /// The web's starting quick reactions, before the user has favorites of their own.
    static let quick = ["😂", "✅", "❤️"]

    /// Double-clicking a message reacts with this, as on the web.
    static let doubleTap = "❤️"

    /// The emoji the user reacts with most, as the server counts them, loaded when the inbox opens.
    @MainActor static var serverUsage: [String] = []

    /// Shortcode and emoji, alphabetical by shortcode, one entry per emoji.
    static let all: [(name: String, emoji: String)] = {
        guard let data = try? Data(contentsOf: emojiFile),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return []
        }

        var seen = Set<String>()

        return map.sorted { $0.key < $1.key }.compactMap { name, emoji in
            seen.insert(emoji).inserted ? (name, emoji) : nil
        }
    }()

    /// The app bundle's copy, or the source tree's when running from `swift run` or `swift test`.
    private static var emojiFile: URL {
        Bundle.main.url(forResource: "emoji-shortcodes", withExtension: "json")
            ?? URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources/emoji-shortcodes.json")
    }

    /// The quick reactions on a message's menu: the ones this Mac uses most, topped up with the defaults.
    @MainActor static var strip: [String] {
        Array((serverUsage + recent + quick + ["👍", "🔥", "🎉", "👀", "🙏", "😮"]).reduce(into: [String]()) { result, emoji in
            if !result.contains(emoji), all.contains(where: { $0.emoji == emoji }) { result.append(emoji) }
        }.prefix(7))
    }

    static var recent: [String] {
        let usage = UserDefaults.standard.dictionary(forKey: "reaction-usage") as? [String: Int] ?? [:]

        return usage.sorted { $0.value > $1.value }.prefix(16).map(\.key)
    }

    static func recordUse(_ emoji: String) {
        var usage = UserDefaults.standard.dictionary(forKey: "reaction-usage") as? [String: Int] ?? [:]
        usage[emoji, default: 0] += 1
        UserDefaults.standard.set(usage, forKey: "reaction-usage")
    }

    static func search(_ term: String) -> [String] {
        let term = term.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": "))

        guard !term.isEmpty else { return all.map(\.emoji) }

        return all.filter { $0.name.contains(term) }.map(\.emoji)
    }
}

/// Every emoji by category, as the picker lists them, from the catalog's categories file.
enum EmojiCatalog {
    struct Category: Decodable {
        let name: String
        let emoji: [String]
    }

    static let categories: [Category] = {
        let file = Bundle.main.url(forResource: "emoji-categories", withExtension: "json")
            ?? URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources/emoji-categories.json")

        guard let data = try? Data(contentsOf: file) else { return [] }

        return (try? JSONDecoder().decode([Category].self, from: data)) ?? []
    }()
}
