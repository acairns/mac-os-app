import SwiftUI

struct MainView: View {
    @Environment(Inbox.self) private var inbox
    @State private var showsNewRemote = false
    @State private var showsNewOrg = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var inbox = inbox

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(showsNewRemote: $showsNewRemote, showsNewOrg: $showsNewOrg)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            if let reference = inbox.selection {
                ChatView(thread: inbox.thread(for: reference))
                    .id(reference.id)
            } else {
                EmptyChatView(showsNewRemote: $showsNewRemote)
            }
        }
        .sheet(isPresented: $showsNewRemote) {
            PeoplePicker(mode: .remote) { users, _, _ in
                if let user = users.first {
                    inbox.selection = .direct(user)
                }
            }
        }
        .sheet(isPresented: $showsNewOrg) {
            PeoplePicker(mode: .newOrg) { users, name, _ in
                Task { await createOrg(users, name: name) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newRemote)) { _ in showsNewRemote = true }
        .onReceive(NotificationCenter.default.publisher(for: .newOrg)) { _ in showsNewOrg = true }
        .onAppear {
            if let id = AppDelegate.pendingConversation {
                AppDelegate.pendingConversation = nil
                inbox.open(conversationId: id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openConversation)) { notification in
            if let id = notification.object as? String {
                inbox.open(conversationId: id)
            }
        }
    }

    private func createOrg(_ users: [User], name: String) async {
        struct Created: Decodable { struct Org: Decodable { let id: String }; let org: Org }

        do {
            let created: Created = try await inbox.api.send("POST", "remotes/orgs", json: [
                "name": name.isEmpty ? NSNull() : name,
                "members": users.map(\.username),
            ])

            await inbox.refresh()
            inbox.tab = .open
            inbox.selection = .org(id: created.org.id, name: name.isEmpty ? nil : name)
        } catch {
            presentAlert(error.localizedDescription)
        }
    }
}

struct EmptyChatView: View {
    @Binding var showsNewRemote: Bool

    var body: some View {
        EmptyState(fatal: "fatal: no remote checked out", message: "Pick a remote on the left, or push to someone new.") {
            Button("New Remote…") { showsNewRemote = true }
                .buttonStyle(LinkButtonStyle())
                .padding(.top, DS.Spacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.chat)
    }
}

struct SidebarView: View {
    @Environment(Inbox.self) private var inbox
    @Environment(Session.self) private var session
    @Binding var showsNewRemote: Bool
    @Binding var showsNewOrg: Bool
    @State private var candidates: [Candidate] = []

    var body: some View {
        @Bindable var inbox = inbox

        VStack(spacing: 0) {
            SidebarTabs(tabs: availableTabs, selection: $inbox.tab, requestsCount: inbox.requestsCount)

            // Inset like the selection's rounded rect, with room below so a selected row never touches the field.
            SearchField(prompt: "Search remotes", text: $inbox.search, focusedBy: .focusSearch)
                .padding(.horizontal, DS.Metrics.sidebarInset)
                .padding(.vertical, DS.Spacing.m)

            List(selection: $inbox.selection) {
                if inbox.isLoading {
                    ForEach(0 ..< 8, id: \.self) { _ in
                        SkeletonRow()
                            .selectionDisabled()
                    }
                } else if let error = inbox.error, inbox.conversations.isEmpty {
                    EmptyState(fatal: "fatal: could not fetch remotes", message: error)
                        .frame(maxWidth: .infinity)
                        .selectionDisabled()
                } else if inbox.conversations.isEmpty, suggestedCandidates.isEmpty {
                    EmptyState(fatal: emptyState.fatal, message: emptyState.message)
                        .frame(maxWidth: .infinity)
                        .selectionDisabled()
                }

                ForEach(inbox.conversations) { conversation in
                    ConversationRow(conversation: conversation, me: session.user?.id)
                        .sidebarSelection(inbox.selection == conversation.reference)
                        .tag(conversation.reference)
                        .contextMenu { ConversationMenu(conversation: conversation) }
                        .onHover { $0 ? inbox.prefetch(conversation.reference) : inbox.cancelPrefetch(conversation.reference) }
                        .onAppear {
                            if conversation.id == inbox.conversations.last?.id {
                                Task { await inbox.loadMore() }
                            }
                        }
                }

                if !suggestedCandidates.isEmpty {
                    Section {
                        ForEach(suggestedCandidates) { candidate in
                            CandidateSearchRow(candidate: candidate)
                                .sidebarSelection(inbox.selection == .direct(candidate.user))
                                .tag(ThreadReference.direct(candidate.user))
                                .selectionDisabled(candidate.reason != nil)
                        }
                    } header: {
                        SectionHeader(title: "Start a conversation")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .hidesSystemSelection()
        }
        .background(DS.Colors.surface)
        .task(id: inbox.search) { await searchCandidates() }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Remote…", systemImage: "person") { showsNewRemote = true }
                    Button("New Org…", systemImage: "person.2") { showsNewOrg = true }
                } label: {
                    Label("Compose", systemImage: "square.and.pencil")
                }
                .help("Start a remote or an org")
            }
        }
    }

    private var availableTabs: [InboxTab] {
        session.user?.remotes?.requests == false ? [.open, .stashed] : InboxTab.allCases
    }

    /// People matching the search who have no conversation in the list yet, at most five, like the web inbox.
    private var suggestedCandidates: [Candidate] {
        guard !inbox.search.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        return Array(candidates.filter { candidate in !inbox.conversations.contains { $0.partner?.id == candidate.user.id } }.prefix(5))
    }

    /// Looks people up 250ms after the search stops changing; a new keystroke cancels the previous lookup, and the old
    /// results stay until new ones arrive so the section doesn't flash.
    private func searchCandidates() async {
        struct Response: Decodable { let candidates: [Candidate] }

        let term = inbox.search.trimmingCharacters(in: .whitespaces)

        guard !term.isEmpty else {
            candidates = []
            return
        }

        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }

        let query: [String: String?] = ["q": term, "for": "remote"]
        let response: Response? = try? await inbox.api.get("remotes/candidates", query: query)

        guard !Task.isCancelled else { return }

        candidates = response?.candidates ?? []
    }

    private var emptyState: (fatal: String, message: String) {
        if !inbox.search.isEmpty { return ("fatal: no remotes match “\(inbox.search)”", "Try a name or an @handle.") }

        return switch inbox.tab {
        case .open: ("no remotes yet", "Press ⌘N to push to someone.")
        case .fetched: ("fatal: nothing fetched", "No requests waiting.")
        case .stashed: ("fatal: stash is empty", "Stashed remotes land here.")
        }
    }
}

/// The inbox's tabs as the web draws page tabs: equal cells, muted labels, and a Commit Blue underline that slides to
/// the picked one. The requests count sits beside its label without moving it.
struct SidebarTabs: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var underline
    let tabs: [InboxTab]
    @Binding var selection: InboxTab
    let requestsCount: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let isSelected = tab == selection

                Button {
                    withAnimation(DS.Motion.respecting(reduceMotion, DS.Motion.slide)) { selection = tab }
                } label: {
                    Text(tab.title)
                        .font(DS.Fonts.bodyMedium)
                        .foregroundStyle(isSelected ? DS.Colors.ink : DS.Colors.inkMuted)
                        .overlay(alignment: .trailing) {
                            if tab == .fetched, requestsCount > 0 {
                                // A zero-width slot at the label's end: the badge hangs past it, the label stays centered.
                                CountBadge(count: requestsCount, muted: !isSelected)
                                    .scaleEffect(0.82, anchor: .leading)
                                    .frame(width: 0, alignment: .leading)
                                    .offset(x: 4)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .overlay(alignment: .bottom) {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(DS.Colors.primary)
                                    .frame(height: 2.5)
                                    .padding(.horizontal, DS.Spacing.l)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityLabel(tab == .fetched && requestsCount > 0 ? "\(tab.title), \(requestsCount) requests" : tab.title)
            }
        }
        .padding(.horizontal, DS.Spacing.s)
        .overlay(alignment: .bottom) { DS.Colors.hairline.frame(height: 1) }
    }
}

/// A conversation row's exact box while the inbox loads: same avatar, same line count, same height.
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(DS.Colors.wash).frame(width: DS.Metrics.avatarRow, height: DS.Metrics.avatarRow)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    SkeletonBar(width: 110, height: 12)
                    Spacer()
                    SkeletonBar(width: 32, height: 10)
                }
                SkeletonBar(height: 10)
                SkeletonBar(width: 120, height: 10)
            }
        }
        .frame(height: DS.Metrics.rowHeight)
        .padding(.vertical, DS.Metrics.rowPadding)
        .skeleton()
    }
}

/// A conversation in the inbox, Telegram-dense: avatar, name with its muted and org marks, the receipt and time, then
/// a two-line preview (or a draft, or who is typing) with the unread badge or the pin. Its height never changes, and on
/// a filled selection every color switches to white.
struct ConversationRow: View {
    @Environment(Inbox.self) private var inbox
    @Environment(\.backgroundProminence) private var prominence
    let conversation: ConversationSummary
    let me: String?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if conversation.isOrg {
                    OrgAvatar(members: (conversation.members ?? []).map(\.user).filter { $0.id != me }, size: DS.Metrics.avatarRow)
                } else {
                    Avatar(user: conversation.partner, size: DS.Metrics.avatarRow)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if conversation.isOrg {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(faintColor)
                    }

                    Text(title)
                        .font(DS.Fonts.rowTitle)
                        .foregroundStyle(inkColor)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if conversation.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(faintColor)
                    }

                    Spacer(minLength: 6)

                    if let receipt {
                        ReceiptMark(state: receipt)
                            .foregroundStyle(receipt == .pulled ? accentColor : mutedColor)
                    }

                    Text(Formatting.inboxTime(conversation.lastMessageAt))
                        .font(DS.Fonts.monoCaption)
                        .foregroundStyle(conversation.ahead > 0 && !conversation.isMuted ? accentColor : mutedColor)
                        .fixedSize()
                }

                HStack(alignment: .center, spacing: 6) {
                    preview
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                    if conversation.ahead > 0 {
                        CountBadge(count: conversation.ahead, muted: conversation.isMuted)
                    } else if conversation.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(faintColor)
                            .rotationEffect(.degrees(45))
                            .frame(width: DS.Metrics.badgeHeight, height: DS.Metrics.badgeHeight)
                    }
                }
            }
        }
        .frame(height: DS.Metrics.rowHeight)
        .padding(.vertical, DS.Metrics.rowPadding)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Content

    private var title: String {
        conversation.title(excluding: me)
    }

    private var typing: [String] {
        inbox.loadedThread(conversation.reference)?.typing ?? []
    }

    private var draft: String? {
        inbox.draft(for: conversation.reference)
    }

    private var people: [User] {
        (conversation.members ?? []).map(\.user) + [conversation.partner].compactMap { $0 }
    }

    /// Whether the partner pulled the user's last message, for one-to-one remotes only.
    private var receipt: ReceiptMark.State? {
        guard !conversation.isOrg, let message = conversation.lastMessage, message.userId == me, !message.isEvent, typing.isEmpty, draft == nil else {
            return nil
        }

        return (conversation.partnerReadThroughId ?? 0) >= message.id ? .pulled : .pushed
    }

    private var typingText: String {
        guard conversation.isOrg else { return "typing" }

        if typing.count > 1 { return "\(typing.count) people are typing" }

        let name = people.first { $0.username == typing.first }.map { firstName($0) } ?? typing.first ?? ""

        return "\(name) is typing"
    }

    /// Who wrote the last message, as the preview's prefix: "You" for the user, a first name in orgs, nobody otherwise.
    private var author: String? {
        guard let message = conversation.lastMessage, !message.isEvent else { return nil }

        if message.userId == me { return "You" }

        guard conversation.isOrg else { return nil }

        return (message.user ?? people.first { $0.id == message.userId }).map { firstName($0) }
    }

    private var previewText: String {
        guard let message = conversation.lastMessage else { return "No messages yet" }

        return MessageText.preview(message, members: people, me: me)
    }

    @ViewBuilder
    private var preview: some View {
        if !typing.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(typingText)
                    .font(DS.Fonts.preview)
                    .foregroundStyle(accentColor)
                    .lineLimit(1)
                TypingDots(color: accentColor, size: 3)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else if let draft {
            (Text("Draft: ").foregroundStyle(isSelected ? DS.Colors.onPrimary : DS.Colors.destructive) + Text(draft).foregroundStyle(mutedColor))
                .font(DS.Fonts.preview)
                .lineLimit(2, reservesSpace: true)
        } else if let author {
            (Text("\(author): ").foregroundStyle(inkColor) + Text(previewText).foregroundStyle(mutedColor))
                .font(DS.Fonts.preview)
                .lineLimit(2, reservesSpace: true)
        } else {
            Text(previewText)
                .font(DS.Fonts.preview)
                .foregroundStyle(mutedColor)
                .lineLimit(2, reservesSpace: true)
        }
    }

    private func firstName(_ user: User) -> String {
        user.displayName.split(separator: " ").first.map(String.init) ?? user.displayName
    }

    private var help: String {
        var lines = [conversation.partner.map { "\(title) · @\($0.username)" } ?? title]

        if receipt == .pulled, let pulledAt = conversation.partnerReadAt {
            lines.append("Pulled \(Formatting.pulledTime(pulledAt))")
        }

        return lines.joined(separator: "\n")
    }

    private var accessibilityText: String {
        var parts = [title]

        if conversation.ahead > 0 { parts.append("\(conversation.ahead) unread") }
        if conversation.isMuted { parts.append("muted") }
        if conversation.isPinned { parts.append("pinned") }

        if !typing.isEmpty {
            parts.append(typingText)
        } else if let draft {
            parts.append("draft: \(draft)")
        } else {
            parts.append("last message: " + (author.map { "\($0): " } ?? "") + previewText)
        }

        if receipt == .pulled { parts.append("pulled") }
        if let date = conversation.lastMessageAt { parts.append(Formatting.inboxTime(date)) }

        return parts.joined(separator: ", ")
    }

    // MARK: Colors

    private var isSelected: Bool { prominence == .increased }
    private var inkColor: Color { isSelected ? DS.Colors.onPrimary : DS.Colors.ink }
    private var mutedColor: Color { isSelected ? DS.Colors.onPrimary.opacity(0.8) : DS.Colors.inkMuted }
    private var faintColor: Color { isSelected ? DS.Colors.onPrimary.opacity(0.7) : DS.Colors.inkFaint }
    private var accentColor: Color { isSelected ? DS.Colors.onPrimary : DS.Colors.primary }
}

/// Someone the search found who has no remote with the user yet; greyed out with the reason when they can't be pushed to.
struct CandidateSearchRow: View {
    @Environment(\.backgroundProminence) private var prominence
    let candidate: Candidate

    var body: some View {
        let isSelected = prominence == .increased

        HStack(spacing: 10) {
            Avatar(user: candidate.user, size: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.user.displayName)
                    .font(DS.Fonts.rowTitle)
                    .foregroundStyle(isSelected ? DS.Colors.onPrimary : DS.Colors.ink)
                    .lineLimit(1)

                Text(candidate.reason ?? "@" + candidate.user.username)
                    .font(candidate.reason == nil ? DS.Fonts.monoHandle : DS.Fonts.caption)
                    .foregroundStyle(isSelected ? DS.Colors.onPrimary.opacity(0.8) : DS.Colors.inkMuted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .opacity(candidate.reason == nil ? 1 : 0.5)
        .help(candidate.reason.map { "@\(candidate.user.username) \($0)" } ?? "@" + candidate.user.username)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(candidate.reason.map { "\(candidate.user.displayName), unavailable: \($0)" } ?? "\(candidate.user.displayName), start a remote")
    }
}

struct ConversationMenu: View {
    @Environment(Inbox.self) private var inbox
    let conversation: ConversationSummary

    var body: some View {
        let reference = conversation.reference

        if conversation.ahead > 0 {
            Button("Mark as Pulled", systemImage: "checkmark.message") { Task { await inbox.markRead(conversation) } }
        }

        Button(conversation.isPinned ? "Unpin" : "Pin", systemImage: conversation.isPinned ? "pin.slash" : "pin") {
            Task { await inbox.setPinned(!conversation.isPinned, reference) }
        }

        Menu("Mute", systemImage: "bell.slash") {
            ForEach(MuteDuration.allCases.filter { $0 != .off }, id: \.self) { duration in
                Button(duration.title) { Task { await inbox.mute(duration, reference) } }
            }
        }

        if conversation.isMuted {
            Button("Unmute", systemImage: "bell") { Task { await inbox.mute(.off, reference) } }
        }

        Divider()

        Button(conversation.isArchived ? "Pop Back to Open" : "Stash", systemImage: "archivebox") {
            Task { await inbox.setStashed(!conversation.isArchived, reference) }
        }
    }
}
