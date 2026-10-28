import SwiftUI

/// The keys every commit list shares beyond j/k: `g` then l/e/p/s to jump, and `?` for the shortcuts sheet.
@MainActor
enum ListKeys {
    private static var chordStarted: Date?

    static func handle(_ press: KeyPress, navigation: Navigation, actions: WorkspaceActions?) -> KeyPress.Result {
        if let started = chordStarted {
            chordStarted = nil
            navigation.isChordPending = false

            let targets: [String: SidebarItem] = ["l": .log(.following), "e": .log(.latest), "p": .profile, "s": .starred]

            if Date.now.timeIntervalSince(started) < 1.5, let item = targets[press.characters] {
                navigation.select(item)
                return .handled
            }
        }

        switch press.characters {
        case "g":
            chordStarted = .now
            // While a chord waits, the menu's single letters stand aside, so "g s" goes to Starred rather than starring.
            navigation.isChordPending = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if chordStarted != nil, Date.now.timeIntervalSince(chordStarted!) >= 1.5 {
                    chordStarted = nil
                    navigation.isChordPending = false
                }
            }
            return .handled
        case "?":
            actions?.showShortcuts()
            return .handled
        default:
            return .ignored
        }
    }
}

/// `?`: the web's keymap in bordered mono caps, in groups.
struct KeyboardShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        ("Lists", [("j / k", "Next / previous commit"), ("Return", "Open the commit page"), ("o", "Show or hide replies"), ("Esc", "Close the pane, or clear the focus")]),
        ("Commits", [("c", "Focus the composer"), ("r", "Reply"), ("q", "Quote"), ("s", "Star or unstar"), ("y", "Copy link"), ("K", "Show the author's preview"), ("⌘↩", "Commit or reply")]),
        ("Go", [("g l", "Following"), ("g e", "Latest"), ("g p", "Your profile"), ("g s", "Starred"), ("⌘1 – ⌘5", "Following, Latest, Trending, Notifications, Remotes"), ("⌘[ / ⌘]", "Back / forward")]),
        ("Workspace", [("⌘K", "Search"), ("⌘N", "New commit"), ("⇧⌘N", "New remote"), ("⌥⌘0", "Show or hide the replies pane"), ("⌘R", "Reload"), ("⌘Z", "Undo delete")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xl) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(DS.Fonts.section)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Grid(alignment: .topLeading, horizontalSpacing: DS.Spacing.xxl, verticalSpacing: DS.Spacing.xl) {
                GridRow {
                    group(groups[0])
                    group(groups[1])
                }
                GridRow {
                    group(groups[2])
                    group(groups[3])
                }
            }

            Text("Single letters work while a list has the focus, never inside a text field.")
                .font(DS.Fonts.caption)
                .foregroundStyle(DS.Colors.inkMuted)
        }
        .padding(DS.Spacing.xl)
        .frame(width: 640)
    }

    private func group(_ group: (String, [(String, String)])) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(group.0)
                .font(DS.Fonts.label)
                .foregroundStyle(DS.Colors.inkFaint)
            ForEach(group.1, id: \.0) { key, action in
                HStack(spacing: DS.Spacing.m) {
                    HStack(spacing: 3) {
                        ForEach(key.split(separator: " ").map(String.init), id: \.self) { part in
                            if part == "/" || part == "–" {
                                Text(part).font(DS.Fonts.monoMeta).foregroundStyle(DS.Colors.inkFaint)
                            } else {
                                Kbd(part)
                            }
                        }
                    }
                    .frame(width: 92, alignment: .leading)
                    Text(action)
                        .font(DS.Fonts.body)
                        .foregroundStyle(DS.Colors.ink)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
