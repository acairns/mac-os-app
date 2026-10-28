import AppKit
import SwiftUI

/// Following, Latest or Trending: the staged composer, then the commits on one rail, with day markers, the HEAD marker,
/// paging, and the root at the end of history.
struct LogView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workspaceActions) private var actions

    let kind: LogKind

    @State private var highlight = RailHighlight()
    @State private var composer = ComposerHandle()
    @State private var isRestored = false
    /// The row at the top of the view, which polling keeps in place when arrivals are inserted above.
    @State private var anchor: String?
    @State private var width: CGFloat = 800
    @FocusState private var listFocused: Bool

    private var log: LogStore { workspace.log(kind) }

    init(kind: LogKind, anchor: String? = nil) {
        self.kind = kind
        _anchor = State(initialValue: anchor)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    CommitComposer(presentation: .staged, draft: Bindable(workspace.drafts).commit, isRestored: isRestored, handle: composer)
                        .id(Self.top)

                    content
                }
                .scrollTargetLayout()
                .padding(.bottom, DS.Spacing.xl)
            }
            .scrollPosition(id: $anchor, anchor: .top)
            .background(DS.Colors.surface)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { width = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, value in width = value }
                }
            }
            .overlay(alignment: .top) { newCommitsButton(proxy) }
            // Images dropped anywhere on the log go to the staged composer, as on the web.
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                guard workspace.drafts.commit.pollOptions == nil else { return false }

                AttachmentLoader.load(providers) { attachments in
                    workspace.drafts.commit.images.append(contentsOf: attachments.prefix(3 - workspace.drafts.commit.images.count))
                    proxy.scrollTo(Self.top, anchor: .top)
                }
                return true
            }
            .animation(DS.Motion.respecting(reduceMotion, DS.Motion.standard), value: log.commits.map(\.id))
            .animation(DS.Motion.respecting(reduceMotion, DS.Motion.standard), value: showsNewCommits)
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(phases: .down) { press in handleKey(press, proxy: proxy) }
            .onReceive(NotificationCenter.default.publisher(for: .moveFocus)) { note in
                guard let step = note.object as? Int else { return }
                moveFocus(step, proxy: proxy)
            }
        }
        .environment(highlight)
        .onAppear {
            isRestored = !workspace.drafts.commit.isEmpty
            log.open()
        }
        .onChange(of: listFocused) { _, focused in navigation.listHasFocus = focused }
        // Trending is drawn again on each open, so only Following and Latest come back to where they were.
        .onChange(of: anchor) { _, anchor in if kind != .trending { navigation.logAnchors[kind] = anchor } }
        // Seeing the top of the log moves HEAD@{last visit}; the marker itself stays where it was on opening.
        .onChange(of: isAtTop) { _, top in if top, NSApp.isActive { log.markSeen() } }
        .onChange(of: log.commits.first?.id) { if isAtTop, NSApp.isActive { log.markSeen() } }
        .onReceive(NotificationCenter.default.publisher(for: .reloadDestination)) { note in
            guard note.object as? Navigation === navigation else { return }
            if kind == .trending { navigation.trendingSeed = Int.random(in: 0 ..< 1_000_000) }
            Task { await log.reload() }
        }
    }

    private static let top = "log-top"

    private var isAtTop: Bool { anchor == nil || anchor == Self.top || anchor == log.commits.first?.id }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !log.hasLoaded, log.error == nil {
            ForEach(0 ..< 6, id: \.self) { _ in SkeletonCommitRow() }
        } else if let error = log.error, log.commits.isEmpty {
            EmptyState(fatal: "fatal: could not fetch the log", message: error) {
                Button("Try Again") { Task { await log.reload() } }
                    .buttonStyle(LinkButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .padding(.top, DS.Spacing.xxxl)
        } else if log.commits.isEmpty {
            emptyLog
        } else {
            rows

            if log.isLoadingMore {
                ForEach(0 ..< 3, id: \.self) { _ in SkeletonCommitRow() }
            } else if log.reachedRoot {
                RootNodeRow(above: LaneColor.of(log.commits.last?.commit.author))
            } else {
                Color.clear
                    .frame(height: 1)
                    .onAppear { Task { await log.loadMore() } }
            }
        }
    }

    private var rows: some View {
        let commits = log.commits
        let marker = kind == .trending ? nil : log.markerAt

        return ForEach(Array(commits.enumerated()), id: \.element.id) { index, box in
            let previous = index > 0 ? commits[index - 1] : nil
            let above: (lane: Color, authorId: String?) = previous.map { (LaneColor.of($0.commit.author), $0.commit.author?.id) } ?? (DS.Colors.rail, nil)

            VStack(alignment: .leading, spacing: 0) {
                if let marker, let previousDate = previous?.commit.createdAt, let date = box.commit.createdAt, previousDate > marker, date <= marker {
                    MarkerRow(kind: .head, lane: above.lane)
                }

                if kind != .trending, let date = box.commit.createdAt, previous.flatMap({ $0.commit.createdAt }).map({ !Calendar.current.isDate($0, inSameDayAs: date) }) ?? !Calendar.current.isDateInToday(date) {
                    MarkerRow(kind: .day(date), lane: above.lane)
                }

                CommitRow(box: box, above: above, showsHash: width >= 520)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var emptyLog: some View {
        VStack(spacing: 0) {
            switch kind {
            case .following:
                EmptyState(fatal: "fatal: your log is empty", message: "Follow a few developers and their commits land here.")
                    .frame(maxWidth: .infinity)
                    .padding(.top, DS.Spacing.xxl)

                ForEach(log.suggestions.compactMap { workspace.existingBox($0) }) { box in
                    SuggestionRow(box: box)
                }
            case .latest:
                EmptyState(fatal: "fatal: nothing committed yet", message: "Be the first: commit something above.")
                    .frame(maxWidth: .infinity)
                    .padding(.top, DS.Spacing.xxl)
            case .trending:
                EmptyState(fatal: "fatal: nothing trending", message: "Nothing has caught on this week yet.")
                    .frame(maxWidth: .infinity)
                    .padding(.top, DS.Spacing.xxl)
            }
        }
    }

    // MARK: New commits

    private var showsNewCommits: Bool { !log.unseen.isEmpty && !isAtTop }

    @ViewBuilder
    private func newCommitsButton(_ proxy: ScrollViewProxy) -> some View {
        if showsNewCommits {
            let authors = log.unseen.compactMap { workspace.existingBox($0)?.commit.author }
            var seen = Set<String>()
            let unique = authors.filter { seen.insert($0.id).inserted }

            Button {
                withAnimation(DS.Motion.respecting(reduceMotion, DS.Motion.standard)) { proxy.scrollTo(Self.top, anchor: .top) }
                log.unseen = []
            } label: {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                    HStack(spacing: -4) {
                        ForEach(unique.prefix(3)) { user in
                            Avatar(user: user, size: 18)
                                .overlay(Circle().strokeBorder(DS.Colors.primaryFill, lineWidth: 1.5))
                        }
                        if unique.count > 3 {
                            Text("+\(unique.count - 3)")
                                .font(DS.Fonts.monoMeta)
                                .frame(width: 18, height: 18)
                                .background(DS.Colors.primaryHover, in: Circle())
                        }
                    }
                    Text(verbatim: "\(log.unseen.count)")
                        .font(DS.Fonts.monoBadge)
                    + Text(log.unseen.count == 1 ? " new commit" : " new commits")
                }
            }
            .buttonStyle(.dsPrimary)
            .elevation(DS.Elevation.floating)
            .padding(.top, 52 - DS.Metrics.controlHeight / 2)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel("\(log.unseen.count) new commits. Scroll to the newest.")
        }
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }

        if ListKeys.handle(press, navigation: navigation, actions: actions) == .handled { return .handled }

        switch press.key {
        case "j":
            moveFocus(1, proxy: proxy)
        case "k":
            moveFocus(-1, proxy: proxy)
        case "K":
            guard let id = navigation.focusedRow else { return .ignored }
            NotificationCenter.default.post(name: .showUserPreview, object: id)
        case "c":
            proxy.scrollTo(Self.top, anchor: .top)
            composer.focus()
        case .return:
            guard let id = navigation.focusedRow else { return .ignored }
            navigation.push(.commit(id))
        case .escape:
            if navigation.isPaneVisible {
                navigation.closePane()
            } else if navigation.focusedRow != nil {
                navigation.focusedRow = nil
            } else {
                return .ignored
            }
        default:
            return .ignored
        }

        return .handled
    }

    private func moveFocus(_ step: Int, proxy: ScrollViewProxy) {
        let ids = log.commits.map(\.id)

        guard !ids.isEmpty else { return }

        let current = navigation.focusedRow.flatMap { ids.firstIndex(of: $0) }
        let next = current.map { max(0, min(ids.count - 1, $0 + step)) } ?? 0
        navigation.focusedRow = ids[next]
        listFocused = true

        withAnimation(DS.Motion.respecting(reduceMotion, DS.Motion.quick)) { proxy.scrollTo(ids[next], anchor: .center) }
    }
}

/// A starter suggestion while Following is empty: the commit, with a Follow button for its author.
private struct SuggestionRow: View {
    @Environment(Workspace.self) private var workspace
    let box: CommitBox

    @State private var isFollowing = false
    @State private var isBusy = false

    var body: some View {
        CommitRow(box: box, showsReplyContext: false)
            .overlay(alignment: .topTrailing) {
                if let author = box.commit.author {
                    Button(isFollowing ? "Following" : "Follow") {
                        isBusy = true
                        Task {
                            if await workspace.setFollowing(!isFollowing, author) { isFollowing.toggle() }
                            isBusy = false
                        }
                    }
                    .buttonStyle(isFollowing ? DSButtonStyle(kind: .outline) : DSButtonStyle(kind: .primary))
                    .disabled(isBusy)
                    .frame(minWidth: 96)
                    .padding(.top, 12)
                    .padding(.trailing, DS.Metrics.commitGutter)
                }
            }
    }
}
