import AppKit
import SwiftUI
import UserNotifications

@main
struct DevNullApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var session = Session()

    var body: some Scene {
        WindowGroup("/dev/null", id: "main") {
            RootView()
                .environment(session)
                .onOpenURL { session.handle(url: $0) }
                .frame(minWidth: 760, minHeight: 480)
                // The sign-in callback goes to the open window instead of opening another.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(session: session) }

        Settings {
            SettingsView()
                .environment(session)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Updates.shared.start()

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Reply and mark as pulled right from the banner, as in Telegram. The banner still never shows the message.
        center.setNotificationCategories([UNNotificationCategory(identifier: "message", actions: [
            UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [], textInputButtonTitle: "Push", textInputPlaceholder: "Push a reply"),
            UNNotificationAction(identifier: "read", title: "Mark as Pulled", options: []),
        ], intentIdentifiers: [])])
    }

    /// Banners show while the app is in front too, unless the conversation is the one being read (the inbox skips those).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["conversation"] as? String else { return }

        let reply = (response as? UNTextInputNotificationResponse)?.userText

        await MainActor.run {
            switch response.actionIdentifier {
            case "reply":
                NotificationCenter.default.post(name: .replyFromBanner, object: id, userInfo: ["text": reply ?? ""])
            case "read":
                NotificationCenter.default.post(name: .markReadFromBanner, object: id)
            default:
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .openConversation, object: id)
            }
        }
    }
}

extension Notification.Name {
    static let openConversation = Notification.Name("devnull.openConversation")
    static let newRemote = Notification.Name("devnull.newRemote")
    static let newOrg = Notification.Name("devnull.newOrg")
    static let focusSearch = Notification.Name("devnull.focusSearch")
    static let showInfo = Notification.Name("devnull.showInfo")
    static let replyFromBanner = Notification.Name("devnull.replyFromBanner")
    static let markReadFromBanner = Notification.Name("devnull.markReadFromBanner")
}

struct AppCommands: Commands {
    let session: Session

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About /dev/null") { AboutWindow.show() }
            Button(Updates.shared.available.map { "Get /dev/null \($0.version)…" } ?? "Check for Updates…") { Updates.shared.checkFromMenu() }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Remote…") { NotificationCenter.default.post(name: .newRemote, object: nil) }
                .keyboardShortcut("n")
            Button("New Org…") { NotificationCenter.default.post(name: .newOrg, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .textEditing) {
            // ⌘K, Telegram's quick search.
            Button("Search Remotes") { NotificationCenter.default.post(name: .focusSearch, object: nil) }
                .keyboardShortcut("k")
        }

        CommandMenu("Conversation") {
            Button("Show Info") { NotificationCenter.default.post(name: .showInfo, object: nil) }
                .keyboardShortcut("i")

            Divider()

            // Moving between remotes from the keyboard, as Telegram does with ⌥↑ and ⌥↓.
            Button("Previous Remote") { session.inbox?.selectAdjacent(-1) }
                .keyboardShortcut(.upArrow, modifiers: .option)
            Button("Next Remote") { session.inbox?.selectAdjacent(1) }
                .keyboardShortcut(.downArrow, modifiers: .option)
            Button("Next Remote") { session.inbox?.selectAdjacent(1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Remote") { session.inbox?.selectAdjacent(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

            Divider()

            Button("Jump to Newest Message") { NotificationCenter.default.post(name: .scrollToBottom, object: nil) }
                .keyboardShortcut(.downArrow, modifiers: .command)
        }

        CommandGroup(replacing: .help) {
            Button("/dev/null on the Web") { NSWorkspace.shared.open(APIClient.baseURL) }
            Button("Manage Devices…") { NSWorkspace.shared.open(APIClient.baseURL.appending(path: "settings/devices")) }
        }
    }
}
