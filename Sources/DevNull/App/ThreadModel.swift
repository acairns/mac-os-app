import AppKit
import Foundation
import Observation

/// A message on its way out: shown at once, swapped for the real one when the API answers, and retried with the same
/// client_id if it failed, which the API answers with the message it already made instead of a second one.
struct PendingMessage: Identifiable, Hashable {
    enum Status: Hashable {
        case sending
        case failed(String)
    }

    let clientId: String
    let body: String
    let replyTo: Message?
    let images: [Attachment]
    let voice: VoiceRecording?
    let createdAt: Date
    /// Which link gets the card: nil for the first one, "" for none.
    var linkPreviewURL: String? = nil
    var status: Status = .sending

    var id: String { clientId }
}

/// An image picked for a message, re-encoded on the server, with the description screen readers get.
struct Attachment: Identifiable, Hashable {
    let id = UUID()
    let data: Data
    let mimeType: String
    let filename: String
    var description: String = ""

    /// Decoded once, since previews and the pending bubble draw it on every pass.
    let image: NSImage?

    init(data: Data, mimeType: String, filename: String) {
        self.data = data
        self.mimeType = mimeType
        self.filename = filename
        image = NSImage(data: data)
    }

    static func == (lhs: Attachment, rhs: Attachment) -> Bool {
        lhs.id == rhs.id && lhs.description == rhs.description
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(description)
    }
}

/// One thread, loaded and polled like the web's: the latest page, older pages as the user scrolls up, and every few
/// seconds whatever came after the newest message, with the reactions that changed since the last version seen.
@MainActor
@Observable
final class ThreadModel {
    let reference: ThreadReference
    unowned let inbox: Inbox

    private(set) var messages: [Message] = []
    private(set) var pending: [PendingMessage] = []
    private(set) var hasOlder = false
    private(set) var isLoaded = false
    private(set) var isLoadingOlder = false
    private(set) var access: PushAccess = .open
    private(set) var partner: User?
    private(set) var orgName: String?
    private(set) var members: [Member] = []
    private(set) var role: OrgRole?
    private(set) var readThroughId = 0
    private(set) var partnerReadThroughId = 0
    private(set) var partnerReadAt: Date?
    private(set) var typing: [String] = []
    private(set) var isArchived = false
    private(set) var pinnedAt: Date?
    private(set) var mutedUntilAt: Date?
    var error: String?

    /// The message the composer replies to, and the draft, kept per thread like a chat app does.
    var replyingTo: Message?
    var draft = ""
    var attachments: [Attachment] = []

    /// Which link of the draft gets a card: nil for the first one, as the server picks by default, "" for none.
    var linkCard: String?

    /// The first message that was unread when the thread was opened, where the "Unread messages" bar sits until the
    /// thread is closed again.
    private(set) var unreadMarkerId: Int?

    /// Where the list was scrolled when the user left the thread, or nil at the bottom, so coming back lands there.
    @ObservationIgnored var scrollAnchor: ScrollAnchor?

    /// Row heights measured by the message list, per row content and width, kept while the app runs so reopening a
    /// thread lays it out without measuring again.
    @ObservationIgnored var rowHeights: [String: CGFloat] = [:]

    @ObservationIgnored private var isViewing = false
    @ObservationIgnored private var placesMarker = false
    @ObservationIgnored private var lastActivityAt = Date()

    @ObservationIgnored private var reactionsVersion = 0
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var lastTypingSentAt = Date.distantPast
    @ObservationIgnored private var isPolling = false
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var lastFetchedAt = Date.distantPast

    var api: APIClient { inbox.api }
    var me: String? { inbox.session.user?.id }

    init(reference: ThreadReference, inbox: Inbox) {
        self.reference = reference
        self.inbox = inbox

        if case let .direct(user) = reference {
            partner = user
        }

        if case let .org(_, name) = reference {
            orgName = name
        }
    }

    var isOrg: Bool {
        if case .org = reference { return true }
        return false
    }

    var newestId: Int { messages.last?.id ?? 0 }

    func user(_ id: String?) -> User? {
        guard let id else { return nil }

        if partner?.id == id { return partner }
        if id == me { return inbox.session.user?.asUser }

        return members.first { $0.user.id == id }?.user
    }

    // MARK: - Polling

    /// A window shows the thread: it polls while at least one does, and stops when the last one moves on, so going
    /// through threads doesn't leave each one polling behind.
    func activate() {
        viewers += 1
        startPolling()
    }

    func deactivate() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { stop() }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    private func startPolling() {
        guard poller == nil else { return }

        poller = Task { [weak self] in
            if self?.isLoaded != true { await self?.load() }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.nextPollDelay ?? 15))
                guard let self, !Task.isCancelled else { return }
                await self.poll()
            }
        }
    }

    /// What's left of the interval since the last fetch, so a thread opened again right after it was read, or right
    /// after a hover loaded it, waits its turn instead of asking at once.
    private var nextPollDelay: Double {
        max(0, pollInterval - Date().timeIntervalSince(lastFetchedAt))
    }

    /// Polls unless the thread was fetched in the last moments, as switching back to the app over and over would.
    func pollIfStale() async {
        guard Date().timeIntervalSince(lastFetchedAt) >= 1.5 else { return }
        await poll()
    }

    /// Every 1.5 seconds while someone is typing or the user was active in the last minute, every 3 while the app is in
    /// front, and every 15 behind other windows. With the inbox's polls and typing pings that stays well under the
    /// API's 120 requests a minute.
    private var pollInterval: Double {
        guard NSApp.isActive else { return 15 }

        return !typing.isEmpty || Date().timeIntervalSince(lastActivityAt) < 60 ? 1.5 : 3
    }

    /// The user did something in the thread: polling speeds up for the next minute.
    func noteActivity() {
        lastActivityAt = Date()
    }

    /// The thread came on screen: the next read places the "Unread messages" bar at the first message it pulls.
    func beginViewing() {
        isViewing = true
        placesMarker = true
        unreadMarkerId = nil
        noteActivity()
    }

    func endViewing() {
        isViewing = false
        placesMarker = false
        unreadMarkerId = nil
    }

    /// Loads the latest page without polling, so the thread opens with its messages already there.
    func prefetch() async {
        guard !isLoaded else { return }
        await load()
    }

    func reload() {
        stop()
        messages = []
        isLoaded = false
        if viewers > 0 { startPolling() }
    }

    @ObservationIgnored private var loading: Task<Void, Never>?

    /// One load at a time: a hover, the prefetch and opening the thread can all ask for it at once.
    private func load() async {
        if let loading {
            return await loading.value
        }

        let task = Task { await fetchLatest() }
        loading = task
        await task.value
        loading = nil
    }

    private func fetchLatest() async {
        lastFetchedAt = Date()

        do {
            let thread: DataEnvelope<ChatThread> = try await api.get(reference.path + "/messages")
            apply(thread.data)
            messages = thread.data.messages
            hasOlder = thread.data.hasOlder
            reactionsVersion = thread.data.reactionsVersion
            isLoaded = true
            error = nil
            markRead()
            refreshPendingCards()
        } catch let error as APIError where error.requiresSignIn {
            inbox.session.expire(error)
        } catch {
            self.error = error.localizedDescription
            isLoaded = true
        }
    }

    func poll() async {
        guard isLoaded, !isPolling else {
            if !isLoaded { await load() }
            return
        }

        isPolling = true
        lastFetchedAt = Date()
        defer { isPolling = false }

        do {
            let thread: DataEnvelope<ChatThread> = try await api.get(reference.path + "/messages", query: [
                "after": String(newestId),
                "reactions_after": String(reactionsVersion),
            ])

            apply(thread.data)
            append(thread.data.messages)
            reactionsVersion = thread.data.reactionsVersion
            refreshPendingCards()

            for change in thread.data.reactionChanges where messages.first(where: { $0.id == change.id })?.reactions != change.reactions {
                if let index = messages.firstIndex(where: { $0.id == change.id }) {
                    messages[index].reactions = change.reactions
                }
            }

            if error != nil { error = nil }
            markRead()
        } catch let error as APIError where error.requiresSignIn {
            inbox.session.expire(error)
        } catch {
            // A missed poll is caught up by the next one.
        }
    }

    @ObservationIgnored private var fetchingCards: Set<Int> = []

    /// A link card the server is still fetching is asked for again, a little later each time, until it's ready.
    private func refreshPendingCards() {
        for message in messages where message.linkPreview?.isPending == true && !fetchingCards.contains(message.id) {
            fetchingCards.insert(message.id)

            Task {
                struct Card: Decodable { let linkPreview: LinkPreview? }

                for delay in [1.5, 3, 6, 12, 24] {
                    try? await Task.sleep(for: .seconds(delay))

                    guard let card: Card = try? await api.get("remotes/messages/\(message.id)/link-preview") else { continue }

                    if card.linkPreview?.isPending != true {
                        if let index = messages.firstIndex(where: { $0.id == message.id }) {
                            messages[index].linkPreview = card.linkPreview
                        }
                        break
                    }
                }

                fetchingCards.remove(message.id)
            }
        }
    }

    /// Loads older pages until a message is there, for jumping to the original of a reply far back in the thread.
    func loadUntil(_ id: Int) async -> Bool {
        var pages = 0

        while !messages.contains(where: { $0.id == id }), hasOlder, pages < 40 {
            await loadOlder()
            pages += 1
        }

        return messages.contains { $0.id == id }
    }

    func loadOlder() async {
        guard hasOlder, !isLoadingOlder, let first = messages.first else { return }

        isLoadingOlder = true
        defer { isLoadingOlder = false }

        if let thread: DataEnvelope<ChatThread> = try? await api.get(reference.path + "/messages", query: ["before": String(first.id)]) {
            let known = Set(messages.map(\.id))
            messages.insert(contentsOf: thread.data.messages.filter { !known.contains($0.id) }, at: 0)
            hasOlder = thread.data.hasOlder
        }
    }

    /// Assigns only what changed, so a poll that brings nothing new doesn't redraw the thread.
    private func apply(_ thread: ChatThread) {
        set(\.access, thread.access)
        set(\.readThroughId, max(readThroughId, thread.readThroughId))
        set(\.isArchived, thread.isArchived)
        set(\.pinnedAt, thread.pinnedAt)
        set(\.mutedUntilAt, thread.mutedUntilAt)

        if let partner = thread.partner {
            set(\.partner, partner)
            set(\.partnerReadThroughId, max(partnerReadThroughId, thread.partnerReadThroughId ?? 0))
            set(\.partnerReadAt, thread.partnerReadAt)
            set(\.typing, thread.partnerTyping == true ? [partner.username] : [])
        }

        if let org = thread.org {
            set(\.orgName, org.name)
            set(\.members, thread.members ?? [])
            set(\.role, thread.role)
            set(\.typing, (thread.typing ?? []).filter { $0 != inbox.session.user?.username })
        }
    }

    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<ThreadModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    private func append(_ incoming: [Message]) {
        let known = Set(messages.map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) }

        guard !fresh.isEmpty else { return }

        // A message from someone else arriving in the open thread chimes, unless the thread is muted.
        let chimes = isViewing && isLoaded && fresh.contains(where: { $0.userId != me && !$0.isEvent }) && !(mutedUntilAt.map { $0 > .now } ?? false)
        if chimes {
            Sounds.newMessage()
        }

        let delivered = Set(fresh.compactMap(\.clientId))
        pending.removeAll { delivered.contains($0.clientId) }
        messages.append(contentsOf: fresh)
        messages.sort { $0.id < $1.id }

        if let last = messages.last, isLoaded {
            inbox.showLocally(last, in: reference, alerted: chimes)
        }
    }

    // MARK: - Reading

    /// Pulls the thread through the newest message, once the user can actually see it.
    func markRead() {
        guard NSApp.isActive, inbox.selection?.id == reference.id, newestId > readThroughId else {
            if isLoaded, inbox.selection?.id == reference.id { placesMarker = false }
            return
        }

        if placesMarker {
            placesMarker = false
            unreadMarkerId = messages.first { $0.id > readThroughId && $0.userId != me && !$0.isEvent }?.id
        }

        let through = newestId
        readThroughId = through
        inbox.markLocallyRead(reference, through: through)

        Task { try? await api.perform("PUT", reference.path + "/read", json: ["through": through]) }
    }

    // MARK: - Writing

    var canPush: Bool { access == .open }

    var accessNotice: String? {
        let name = partner.map { "@" + $0.username } ?? "They"

        switch access {
        case .open: return nil
        case .request: return "\(name) wants to push to you. Merge to reply, or drop it without telling them."
        case .waiting: return "\(name) hasn't merged your request yet."
        case .restricted: return "\(name) doesn't follow you, so you can't push to them yet."
        case .closed: return isOrg ? "You're no longer in this org." : "\(name) isn't taking remotes."
        }
    }

    /// Says the user is typing, at most every few seconds, as the web's composer does while it has text.
    func userTyped() {
        guard canPush, !draft.isEmpty, Date().timeIntervalSince(lastTypingSentAt) > 3, !(partner != nil && messages.isEmpty) else { return }

        lastTypingSentAt = Date()
        noteActivity()
        Task { try? await api.perform("PUT", reference.path + "/typing") }
    }

    func sendDraft() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty || !attachments.isEmpty else { return }

        var message = PendingMessage(clientId: UUID().uuidString.lowercased(), body: body, replyTo: replyingTo, images: attachments, voice: nil, createdAt: Date())
        message.linkPreviewURL = linkCard.flatMap { $0.isEmpty || body.contains($0) ? $0 : nil }

        draft = ""
        attachments = []
        replyingTo = nil
        linkCard = nil
        lastTypingSentAt = .distantPast

        deliver(message)
    }

    /// Pushes text that didn't come from the composer, like a reply typed in a notification, leaving the draft alone.
    func send(_ text: String) {
        let body = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))

        guard !body.isEmpty else { return }

        deliver(PendingMessage(clientId: UUID().uuidString.lowercased(), body: body, replyTo: nil, images: [], voice: nil, createdAt: Date()))
    }

    func sendVoice(_ recording: VoiceRecording) {
        let message = PendingMessage(clientId: UUID().uuidString.lowercased(), body: "", replyTo: replyingTo, images: [], voice: recording, createdAt: Date())
        replyingTo = nil

        deliver(message)
    }

    func retry(_ message: PendingMessage) {
        pending.removeAll { $0.clientId == message.clientId }

        var again = message
        again.status = .sending
        deliver(again)
    }

    func discard(_ message: PendingMessage) {
        pending.removeAll { $0.clientId == message.clientId }
    }

    private func deliver(_ message: PendingMessage) {
        noteActivity()
        message.seedImages()
        pending.append(message)

        Task {
            do {
                var json: [String: Any] = ["client_id": message.clientId]

                if let reply = message.replyTo {
                    json["reply_to_id"] = reply.id
                }

                if let card = message.linkPreviewURL {
                    json["link_preview_url"] = card
                }

                let sent: DataEnvelope<Message>

                if let voice = message.voice {
                    json["voice_waveform"] = voice.waveform
                    sent = try await api.sendMultipart("POST", reference.path + "/messages", json: json, field: "voice", files: [
                        Upload(data: voice.data, filename: "voice.wav", mimeType: "audio/wav"),
                    ])
                } else if !message.images.isEmpty {
                    json["body"] = message.body
                    json["image_descriptions"] = message.images.map(\.description)
                    sent = try await api.sendMultipart("POST", reference.path + "/messages", json: json, field: "images", files: message.images.map {
                        Upload(data: $0.data, filename: $0.filename, mimeType: $0.mimeType)
                    })
                } else {
                    json["body"] = message.body
                    sent = try await api.send("POST", reference.path + "/messages", json: json)
                }

                // The delivered images show the picked ones until their own load, so nothing flashes.
                for (image, attachment) in zip(sent.data.images ?? [], message.images) {
                    if let url = URL(string: image.url), let picked = attachment.image {
                        ImageLoader.shared.seed(picked, for: url)
                    }
                }

                append([sent.data])
                pending.removeAll { $0.clientId == message.clientId }
                readThroughId = max(readThroughId, sent.data.id)
            } catch let error as APIError where error.requiresSignIn {
                inbox.session.expire(error)
            } catch {
                if let index = pending.firstIndex(where: { $0.clientId == message.clientId }) {
                    pending[index].status = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// The members other than the author and the user who pulled a message, as far as pulls are shared.
    func readers(of message: Message) -> [User] {
        members.filter { $0.user.id != me && $0.user.id != message.userId && ($0.readThroughId ?? 0) >= message.id }.map(\.user)
    }

    /// The voice notes after a message, oldest first, which play one after another.
    func voiceNotes(after id: Int) -> [MessageVoice] {
        messages.filter { $0.id > id }.compactMap(\.voice)
    }

    // MARK: - Reactions

    func hasReacted(_ message: Message, with emoji: String) -> Bool {
        (message.reactions ?? []).contains { $0.emoji == emoji && $0.userId == me }
    }

    func toggleReaction(_ emoji: String, on message: Message) {
        guard let me, let index = messages.firstIndex(where: { $0.id == message.id }) else { return }

        let removing = hasReacted(message, with: emoji)
        let before = messages[index].reactions

        if removing {
            messages[index].reactions?.removeAll { $0.emoji == emoji && $0.userId == me }
        } else {
            messages[index].reactions = (before ?? []) + [Reaction(userId: me, emoji: emoji)]
        }

        Task {
            do {
                let response: ReactionsResponse = try await api.send(removing ? "DELETE" : "POST", "remotes/messages/\(message.id)/reactions", json: ["emoji": emoji])

                if let index = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[index].reactions = response.reactions
                }

                Reactions.recordUse(emoji)
            } catch {
                if let index = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[index].reactions = before
                }

                presentAlert(error.localizedDescription)
            }
        }
    }

    // MARK: - Orgs

    var orgId: String? {
        if case let .org(id, _) = reference { return id }
        return nil
    }

    func rename(to name: String) async {
        await inbox.run { try await self.api.perform("PUT", self.reference.path, json: ["name": name.isEmpty ? NSNull() : name]) }
        await poll()
    }

    func add(_ usernames: [String], shareHistory: Bool) async {
        await inbox.run { try await self.api.perform("POST", self.reference.path + "/members", json: ["members": usernames, "share_history": shareHistory]) }
        await poll()
    }

    func setRole(_ role: OrgRole, of user: User) async {
        await inbox.run { try await self.api.perform("PUT", self.reference.path + "/members/\(user.username)", json: ["role": role.rawValue]) }
        await poll()
    }

    func remove(_ user: User) async {
        await inbox.run { try await self.api.perform("DELETE", self.reference.path + "/members/\(user.username)") }

        if user.id == me {
            inbox.selection = nil
        } else {
            await poll()
        }
    }
}

struct ReactionsResponse: Decodable {
    let reactions: [Reaction]
}

/// A row of the message list and how far its bottom edge was above the bottom of the visible area.
struct ScrollAnchor {
    let rowId: String
    let offset: CGFloat
}

extension PendingMessage {
    /// A pending message drawn exactly like the message it becomes: its id is negative so it can't match a real one,
    /// and its images and voice note point at the picked data, held by the image cache under local URLs.
    func asMessage(userId: String?) -> Message {
        let id = -Int(clientId.utf8.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) } & 0x7FFF_FFFF) - 1

        return Message(
            id: id,
            userId: userId,
            clientId: clientId,
            body: body,
            bodySegments: nil,
            replyToId: replyTo?.id,
            replyTo: replyTo.map { ReplyGhost(id: $0.id, userId: $0.userId, body: $0.body, imagesCount: $0.images?.count, hasVoice: $0.voice != nil) },
            linkPreview: nil,
            images: images.isEmpty ? nil : images.enumerated().map { index, attachment in
                let size = attachment.image?.pixelSize
                return MessageImage(id: "\(clientId)-\(index)", width: size.map { Int($0.width) }, height: size.map { Int($0.height) }, description: attachment.description, url: localURL(index).absoluteString)
            },
            voice: voice.map { MessageVoice(id: clientId, durationMs: Int($0.duration * 1000), waveform: $0.waveform, url: "") },
            reactions: nil,
            event: nil,
            subjectId: nil,
            user: nil,
            subject: nil,
            createdAt: createdAt
        )
    }

    func localURL(_ index: Int) -> URL {
        URL(string: "devnull-local://\(clientId)/\(index)")!
    }

    @MainActor func seedImages() {
        for (index, attachment) in images.enumerated() {
            if let image = attachment.image {
                ImageLoader.shared.seed(image, for: localURL(index))
            }
        }
    }
}

extension NSImage {
    /// The size in pixels of the image's first bitmap, which is what the API reports for images it stored.
    var pixelSize: CGSize {
        guard let rep = representations.first, rep.pixelsWide > 0 else { return size }

        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}
