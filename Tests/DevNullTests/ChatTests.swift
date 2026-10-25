import AppKit
@testable import DevNull
import Foundation
import Testing

@Suite struct ChatTests {
    @Test(arguments: ["👍", "🔥🔥", "❤️", "👨‍👩‍👧", "🇵🇹", "😂👍🎉"])
    func emojiOnlyMessagesShowBig(_ body: String) {
        #expect(MessageText.isOnlyEmoji(body))
    }

    @Test(arguments: ["ok", "👍 ok", "1", "#", ":)", ""])
    func textMessagesStayInBubbles(_ body: String) {
        #expect(!MessageText.isOnlyEmoji(body))
    }

    @Test func recordingsCountInTenths() {
        #expect(Formatting.preciseDuration(0) == "0:00,0")
        #expect(Formatting.preciseDuration(9.96) == "0:09,9")
        #expect(Formatting.preciseDuration(61.25) == "1:01,2")
    }

    /// The picker only offers emoji the server takes as reactions, every one of them once.
    @Test func everyCategorizedEmojiIsInTheCatalog() {
        let catalog = Set(Reactions.all.map(\.emoji))
        let categorized = EmojiCatalog.categories.flatMap(\.emoji)

        #expect(EmojiCatalog.categories.count == 8)
        #expect(Set(categorized) == catalog)
        #expect(categorized.count == catalog.count)
    }

    /// The web's new-message sound ships with the app and decodes.
    @Test func newMessageSoundLoads() throws {
        let file = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources/DevNull/Resources/remote.mp3")
        let sound = try #require(NSSound(contentsOf: file, byReference: false))

        #expect(sound.duration > 0)
    }

    @MainActor @Test func quickReactionsAreAcceptedReactions() {
        let catalog = Set(Reactions.all.map(\.emoji))

        #expect(Reactions.strip.count == 7)
        #expect(Reactions.strip.allSatisfy(catalog.contains))
        #expect(catalog.contains(Reactions.doubleTap))
    }
}
