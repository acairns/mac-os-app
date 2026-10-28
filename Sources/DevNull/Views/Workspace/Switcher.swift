import AppKit
import SwiftUI

/// ⌘K: people, remotes and logs by name, and commits by meaning, from one field under the toolbar.
struct SwitcherPanel: View {
    @Environment(Session.self) private var session
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.workspaceActions) private var actions

    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var index = 0
    @FocusState private var isFocused: Bool

    private enum Entry: Identifiable {
        case person(User)
        case item(SidebarItem)
        case commit(CommitBox)
        case searchCommits(String)
        case recent(String)

        var id: String {
            switch self {
            case let .person(user): "person-\(user.id)"
            case let .item(item): "item-\(item.id)"
            case let .commit(box): "commit-\(box.id)"
            case let .searchCommits(query): "search-\(query)"
            case let .recent(query): "recent-\(query)"
            }
        }
    }

    private struct Section: Identifiable {
        let title: String
        let entries: [Entry]

        var id: String { title }
    }

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var sections: [Section] {
        let items = SidebarOrder.items(session)

        guard !term.isEmpty else {
            return [
                Section(title: "Recent", entries: workspace.search.recent.map(Entry.recent)),
                Section(title: "Go to", entries: items.map(Entry.item)),
            ].filter { !$0.entries.isEmpty }
        }

        let matches = items.filter { title($0).localizedCaseInsensitiveContains(term) }
        let commits = workspace.search.commits.prefix(3).compactMap { workspace.existingBox($0) }

        return [
            Section(title: "People", entries: workspace.search.people.prefix(5).map(Entry.person)),
            Section(title: "Remotes and logs", entries: matches.map(Entry.item)),
            Section(title: "Commits by meaning", entries: commits.map(Entry.commit) + [.searchCommits(term)]),
        ].filter { !$0.entries.isEmpty }
    }

    private var entries: [Entry] { sections.flatMap(\.entries) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DS.Colors.inkMuted)
                TextField("Search people, commits, remotes", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($isFocused)
                    .onKeyPress(phases: .down, action: key)
                if workspace.search.isSearchingCommits {
                    ProgressView().controlSize(.small)
                }
                Kbd("esc")
            }
            .padding(.horizontal, DS.Spacing.l)
            .frame(height: 48)
            .overlay(alignment: .bottom) { DS.Colors.hairline.frame(height: 1) }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let all = entries

                        ForEach(sections) { section in
                            Text(section.title)
                                .font(DS.Fonts.label)
                                .foregroundStyle(DS.Colors.inkFaint)
                                .padding(.horizontal, DS.Spacing.l)
                                .padding(.top, DS.Spacing.m)
                                .padding(.bottom, DS.Spacing.xs)

                            ForEach(section.entries) { entry in
                                let position = all.firstIndex { $0.id == entry.id } ?? 0

                                Button { open(entry, modifiers: []) } label: {
                                    row(entry)
                                        .padding(.horizontal, DS.Spacing.m)
                                        .frame(minHeight: 36)
                                        .background(position == index ? DS.Colors.selectionSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                                        .padding(.horizontal, DS.Spacing.xs)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(entry.id)
                                .onHover { if $0 { index = position } }
                            }
                        }

                        if !term.isEmpty, !SearchStore.isSearchable(term) {
                            Text("Commits by meaning need 3 to 100 characters.")
                                .font(DS.Fonts.caption)
                                .foregroundStyle(DS.Colors.inkFaint)
                                .padding(DS.Spacing.l)
                        }
                    }
                    .padding(.bottom, DS.Spacing.s)
                }
                .onChange(of: index) { _, value in
                    if entries.indices.contains(value) { proxy.scrollTo(entries[value].id) }
                }
            }

            HStack(spacing: DS.Spacing.l) {
                hint("↑↓", "move")
                hint("↩", "open")
                hint("⌘↩", "in the pane")
                Spacer()
            }
            .padding(.horizontal, DS.Spacing.l)
            .frame(height: 32)
            .overlay(alignment: .top) { DS.Colors.hairline.frame(height: 1) }
        }
        .frame(width: DS.Metrics.switcherWidth)
        .frame(maxHeight: (NSApp.keyWindow?.frame.height ?? 800) * 0.6)
        .fixedSize(horizontal: false, vertical: true)
        .background(DS.Colors.popover, in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous).strokeBorder(DS.Colors.hairline))
        .elevation(DS.Elevation.popover)
        .onAppear { isFocused = true }
        .onChange(of: isFocused) { _, focused in if !focused { isPresented = false } }
        .onChange(of: query) { index = 0 }
        .task(id: term) { await workspace.search.update(term) }
        .onExitCommand { isPresented = false }
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        HStack(spacing: DS.Spacing.m) {
            switch entry {
            case let .person(user):
                Avatar(user: user, size: 28)
                Text(user.displayName)
                    .font(DS.Fonts.body.weight(.medium))
                    .foregroundStyle(DS.Colors.ink)
                LaneDot(user: user)
                Text("@\(user.handle)")
                    .font(DS.Fonts.monoHandle)
                    .foregroundStyle(DS.Colors.inkMuted)
                if user.followsYou == true {
                    Text("follows you")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(DS.Colors.inkFaint)
                }
            case let .item(item):
                Image(systemName: item.symbol)
                    .frame(width: 28)
                    .foregroundStyle(DS.Colors.inkMuted)
                Text(title(item))
                    .font(DS.Fonts.body)
                    .foregroundStyle(DS.Colors.ink)
            case let .commit(box):
                Circle()
                    .strokeBorder(LaneColor.of(box.commit.author), lineWidth: 2)
                    .frame(width: 12, height: 12)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(box.commit.text)
                        .font(DS.Fonts.body)
                        .foregroundStyle(DS.Colors.ink)
                        .lineLimit(1)
                    Text("@\(box.commit.author?.handle ?? "") · \(Formatting.relative(box.commit.createdAt))")
                        .font(DS.Fonts.monoMeta)
                        .foregroundStyle(DS.Colors.inkMuted)
                }
            case let .searchCommits(query):
                Image(systemName: "text.magnifyingglass")
                    .frame(width: 28)
                    .foregroundStyle(DS.Colors.primary)
                Text("Search commits for “\(query)”")
                    .font(DS.Fonts.body)
                    .foregroundStyle(DS.Colors.primary)
                Spacer(minLength: 0)
                Kbd("⌘↩")
            case let .recent(query):
                Image(systemName: "clock.arrow.circlepath")
                    .frame(width: 28)
                    .foregroundStyle(DS.Colors.inkMuted)
                Text(query)
                    .font(DS.Fonts.body)
                    .foregroundStyle(DS.Colors.ink)
            }
            Spacer(minLength: 0)
        }
    }

    /// A remote's title as the sidebar shows it: an unnamed org reads as its members.
    private func title(_ item: SidebarItem) -> String {
        guard case let .remote(reference) = item, let inbox = session.inbox,
              let conversation = (inbox.sidebarOpen + inbox.conversations + inbox.requests).first(where: { $0.reference == reference })
        else { return item.title }

        return conversation.title(excluding: session.user?.id)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Kbd(keys)
            Text(label)
                .font(DS.Fonts.caption)
                .foregroundStyle(DS.Colors.inkFaint)
        }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        let count = entries.count

        switch press.key {
        case .downArrow:
            guard count > 0 else { return .handled }
            index = (index + 1) % count
        case .upArrow:
            guard count > 0 else { return .handled }
            index = (index - 1 + count) % count
        case .return:
            if press.modifiers.contains(.command), !entries.indices.contains(index) || !isCommit(entries[index]) {
                guard SearchStore.isSearchable(term) else { return .handled }
                open(.searchCommits(term), modifiers: [])
            } else if entries.indices.contains(index) {
                open(entries[index], modifiers: press.modifiers)
            }
        case .escape:
            isPresented = false
        default:
            return .ignored
        }

        return .handled
    }

    private func isCommit(_ entry: Entry) -> Bool {
        if case .commit = entry { true } else { false }
    }

    private func open(_ entry: Entry, modifiers: EventModifiers) {
        switch entry {
        case let .person(user):
            workspace.search.remember(term)
            actions?.openProfile(user.handle)
        case let .item(item):
            navigation.select(item)
        case let .commit(box):
            workspace.search.remember(term)
            if modifiers.contains(.command) { navigation.openThread(box.id) } else { navigation.push(.commit(box.id)) }
        case let .searchCommits(query):
            guard SearchStore.isSearchable(query) else { return }
            navigation.push(.search(query))
        case let .recent(query):
            self.query = query
            return
        }

        isPresented = false
    }
}
