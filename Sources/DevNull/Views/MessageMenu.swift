import AppKit
import SwiftUI

/// A message's right-click menu, like Telegram's: a strip of quick reactions on top, with a button for every other
/// emoji, then replying, copying and saving.
@MainActor
enum MessageMenu {
    static func make(thread: ThreadModel, message: Message, me: String?, chat: ChatState) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if thread.canPush {
            let selected = Set((message.reactions ?? []).filter { $0.userId == me }.map(\.emoji))
            let strip = NSHostingView(rootView: ReactionStrip(selected: selected) { [weak menu] emoji in
                menu?.cancelTracking()
                thread.toggleReaction(emoji, on: message)
            } more: { [weak menu] in
                menu?.cancelTracking()
                DispatchQueue.main.async { showPicker(thread: thread, message: message, selected: selected, chat: chat) }
            })
            strip.frame = NSRect(origin: .zero, size: strip.fittingSize)

            let item = NSMenuItem()
            item.view = strip
            menu.addItem(item)
            menu.addItem(.separator())

            menu.addItem(ActionItem("Reply", symbol: "arrowshape.turn.up.left", key: "") { thread.replyingTo = message })
        }

        if let body = message.body, !body.isEmpty {
            menu.addItem(ActionItem("Copy Text", symbol: "doc.on.doc", key: "") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(MessageText.emojify(body), forType: .string)
            })
        }

        if let images = message.images, let image = images.first {
            menu.addItem(ActionItem(images.count == 1 ? "Copy Image" : "Copy First Image", symbol: "photo.on.rectangle", key: "") { LightboxActions.copy(image) })
            menu.addItem(ActionItem(images.count == 1 ? "Save Image…" : "Save First Image…", symbol: "square.and.arrow.down", key: "") { LightboxActions.save(image) })
        }

        if let preview = message.linkPreview, let url = URL(string: preview.url) {
            menu.addItem(ActionItem("Copy Link", symbol: "link", key: "") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            })
        }

        // Who pulled the user's own message, like Telegram's "Seen by" in groups.
        let receiptCount = menu.items.count

        if message.userId == me {
            if thread.isOrg {
                let readers = thread.readers(of: message)
                let total = thread.members.filter { $0.user.id != me }.count
                let item = NSMenuItem(title: readers.isEmpty ? "Not pulled yet" : "Pulled by \(readers.count) of \(total)", action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: readers.isEmpty ? "checkmark" : "checkmark.circle", accessibilityDescription: nil)

                if !readers.isEmpty {
                    item.submenu = peopleMenu(readers.map { ($0, nil) })
                } else {
                    item.isEnabled = false
                }

                menu.addItem(.separator())
                menu.addItem(item)
            } else if thread.partnerReadThroughId >= message.id {
                let item = NSMenuItem(title: thread.partnerReadAt.map { "Pulled \(Formatting.pulledTime($0))" } ?? "Pulled", action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
                item.isEnabled = false
                menu.addItem(.separator())
                menu.addItem(item)
            }
        }

        // Everyone who reacted, with what.
        if let reactions = message.reactions, !reactions.isEmpty {
            let item = NSMenuItem(title: reactions.count == 1 ? "1 Reaction" : "\(reactions.count) Reactions", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: nil)
            item.submenu = peopleMenu(reactions.map { (thread.user($0.userId) ?? User(id: $0.userId, username: "someone", name: nil, avatarUrl: nil, bio: nil, htmlUrl: nil, lane: nil, isFollowed: nil, followsYou: nil), $0.emoji) })

            if menu.items.count == receiptCount {
                menu.addItem(.separator())
            }

            menu.addItem(item)
        }

        if let sender = message.user ?? thread.user(message.userId), sender.id != me {
            menu.addItem(.separator())
            menu.addItem(ActionItem("View @\(sender.username)", symbol: "person.crop.circle", key: "") {
                NSWorkspace.shared.open(APIClient.baseURL.appending(path: "@" + sender.username))
            })
        }

        return menu
    }

    /// People, each with their avatar when it's loaded and an emoji when they reacted, opening their profile.
    private static func peopleMenu(_ people: [(User, String?)]) -> NSMenu {
        let menu = NSMenu()

        for (user, emoji) in people {
            let item = ActionItem((emoji.map { $0 + "  " } ?? "") + user.displayName, symbol: "person.crop.circle", key: "") {
                NSWorkspace.shared.open(APIClient.baseURL.appending(path: "@" + user.username))
            }

            if let url = user.avatarURL, let avatar = ImageLoader.shared.cached(url) {
                item.image = avatar.circular(diameter: 18)
            }

            item.toolTip = "@" + user.username
            menu.addItem(item)
        }

        return menu
    }

    /// Every emoji, in a popover on the message.
    static func showPicker(thread: ThreadModel, message: Message, selected: Set<String>, chat: ChatState) {
        guard let (view, rect) = chat.list.rowView(forMessage: message.id) else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: EmojiPicker(mode: .reaction(selected: selected)) { [weak popover] emoji in
            popover?.performClose(nil)
            thread.toggleReaction(emoji, on: message)
        })

        let outgoing = message.userId == thread.me
        let anchor = NSRect(x: outgoing ? rect.maxX - 120 : rect.minX + 60, y: rect.minY, width: 60, height: rect.height)
        popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, symbol: String, key: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: key)
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError()
    }

    @objc private func runAction() {
        run()
    }
}

/// The quick reactions at the top of a message's menu: the ones used most on this Mac, then a button for all of them.
struct ReactionStrip: View {
    let selected: Set<String>
    let pick: (String) -> Void
    let more: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Reactions.strip, id: \.self) { emoji in
                StripButton(emoji: emoji, isSelected: selected.contains(emoji)) { pick(emoji) }
            }

            Button(action: more) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DS.Colors.inkMuted)
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("More reactions")
            .accessibilityLabel("More reactions")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

private struct StripButton: View {
    let emoji: String
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(.system(size: 21))
                .frame(width: 32, height: 32)
                .background(isSelected ? DS.Colors.primarySoft : hovering ? DS.Colors.wash : .clear, in: Circle())
                .scaleEffect(hovering ? 1.18 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.6), value: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(isSelected ? "Remove \(emoji)" : "React with \(emoji)")
    }
}

extension NSImage {
    /// The image cropped to a circle of a diameter, for avatars in menus.
    func circular(diameter: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            self.draw(in: rect)
            return true
        }
    }
}
