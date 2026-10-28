import AppKit
import SwiftUI

// MARK: - Replies pane: thread mode

/// A commit's thread beside a list: the commit, its replies, and the reply composer pinned to the bottom.
struct ThreadPane: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation

    let commitId: String

    private var store: ThreadStore { workspace.thread(commitId) }

    var body: some View {
        let box = store.commit

        VStack(spacing: 0) {
            PaneHeader(title: "Thread") {
                if let box {
                    Text(box.commit.hash)
                        .font(DS.Fonts.monoCaption)
                        .foregroundStyle(DS.Colors.inkMuted)
                }
                if let context {
                    Text("in \(context)")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(DS.Colors.inkMuted)
                        .lineLimit(1)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let box {
                        ThreadCommit(box: box, stamp: .pane)
                            .padding(DS.Spacing.l)

                        RepliesSection(store: store, depth: 0)
                    } else if let error = store.error {
                        EmptyState(fatal: "fatal: could not fetch the thread", message: error) {
                            Button("Try Again") { Task { await store.load() } }
                                .buttonStyle(LinkButtonStyle())
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ThreadSkeleton()
                            .padding(DS.Spacing.l)
                    }
                }
            }

            if let box, !box.commit.isTombstone, let handle = box.commit.author?.handle {
                CommitComposer(
                    presentation: .reply(parentId: commitId, handle: handle),
                    draft: replyDraft,
                    isRestored: workspace.drafts.replies[commitId].map { !$0.isEmpty } ?? false,
                    autofocus: navigation.focusReplyComposer
                )
                .padding(DS.Spacing.l)
                .overlay(alignment: .top) { DS.Colors.hairline.frame(height: 1) }
                .onAppear { navigation.focusReplyComposer = false }
            }
        }
        .task(id: commitId) { await store.load() }
    }

    private var replyDraft: Binding<DraftStore.CommitDraft> {
        Binding(get: { workspace.drafts.replies[commitId] ?? DraftStore.CommitDraft() }, set: { workspace.drafts.replies[commitId] = $0 })
    }

    /// Where the list beside the pane is: "Following", "Starred", "@maya".
    private var context: String? {
        if let route = navigation.route {
            return route.title
        }

        return navigation.item.map(\.title)
    }
}

// MARK: - Commit page

/// A commit's own page: its visible ancestors on one rail, the commit, the reply composer, its replies three levels
/// deep, and related commits by meaning.
struct CommitPageView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation

    let commitId: String

    @State private var highlight = RailHighlight()

    private var store: ThreadStore { workspace.thread(commitId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let box = store.commit, store.hasLoaded || box.commit.body != nil {
                    page(box)
                } else if let error = store.error {
                    EmptyState(fatal: "fatal: commit not found", message: error) {
                        Button("Try Again") { Task { await store.load() } }
                            .buttonStyle(LinkButtonStyle())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, DS.Spacing.xxxl)
                } else {
                    ThreadSkeleton()
                        .padding(DS.Spacing.xl)
                }
            }
            .padding(.bottom, DS.Spacing.xxl)
            // One reading column, however wide the window: the rail, the measure and the gutter.
            .frame(maxWidth: DS.Metrics.railWidth + DS.Metrics.bodyIndent + DS.Metrics.readingMeasure + DS.Metrics.commitGutter * 2, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Colors.surface)
        .environment(highlight)
        .task(id: commitId) {
            await store.load()
            await store.loadRelated()
        }
        .onReceive(NotificationCenter.default.publisher(for: .reloadDestination)) { note in
            guard note.object as? Navigation === navigation else { return }
            Task { await store.load() }
        }
    }

    @ViewBuilder
    private func page(_ box: CommitBox) -> some View {
        let ancestors = store.ancestors.compactMap { workspace.existingBox($0) }

        ForEach(Array(ancestors.enumerated()), id: \.element.id) { index, ancestor in
            let previous = index > 0 ? ancestors[index - 1] : nil
            CommitRow(box: ancestor, above: previous.map { (LaneColor.of($0.commit.author), $0.commit.author?.id) } ?? (.clear, nil), showsReplyContext: false)
        }

        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: DS.Metrics.railWidth)
            ThreadCommit(box: box, stamp: .page)
                .padding(.vertical, 12)
                .padding(.leading, DS.Spacing.xs)
                .padding(.trailing, DS.Metrics.commitGutter)
        }
        .background(alignment: .topLeading) {
            GraphRail(above: ancestors.last.map { LaneColor.of($0.commit.author) } ?? .clear, lane: LaneColor.of(box.commit.author), hasTail: false)
                .frame(height: 44)
        }

        if !box.commit.isTombstone, let handle = box.commit.author?.handle {
            CommitComposer(
                presentation: .reply(parentId: commitId, handle: handle),
                draft: Binding(get: { workspace.drafts.replies[commitId] ?? DraftStore.CommitDraft() }, set: { workspace.drafts.replies[commitId] = $0 }),
                isRestored: workspace.drafts.replies[commitId].map { !$0.isEmpty } ?? false,
                autofocus: navigation.focusReplyComposer
            )
            .padding(.leading, DS.Metrics.railWidth + DS.Metrics.bodyIndent)
            .padding(.trailing, DS.Metrics.commitGutter)
            .padding(.bottom, DS.Spacing.l)
            .onAppear { navigation.focusReplyComposer = false }
        }

        RepliesSection(store: store, depth: 0)
            .padding(.leading, DS.Metrics.railWidth)

        if !store.related.isEmpty {
            SectionLabel(text: "related · by meaning")
                .padding(.top, DS.Spacing.xl)

            ForEach(store.related.compactMap { workspace.existingBox($0) }) { related in
                CompactCommitRow(box: related)
            }
        }
    }
}

/// A muted mono label above a group of rows on the commit page.
private struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Fonts.monoCaption)
            .foregroundStyle(DS.Colors.inkMuted)
            .padding(.horizontal, DS.Metrics.railWidth + DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { RowHairline() }
    }
}

// MARK: - The commit itself

/// The commit at the top of a thread: 40pt avatar with its lane ring, Follow, the body at 15, the stamp and the full
/// action row.
struct ThreadCommit: View {
    enum Stamp {
        case pane
        case page
    }

    @Environment(Workspace.self) private var workspace
    @Environment(\.workspaceActions) private var actions

    let box: CommitBox
    let stamp: Stamp

    private var commit: Commit { box.commit }

    var body: some View {
        if commit.isTombstone {
            TombstoneRow(box: box, hasTail: false)
        } else {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                HStack(spacing: DS.Spacing.m) {
                    Button {
                        if let handle = commit.author?.handle { actions?.openProfile(handle) }
                    } label: {
                        HStack(spacing: DS.Spacing.m) {
                            Avatar(user: commit.author, size: DS.Metrics.threadAvatar)
                                .laneRing(commit.author)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(commit.author?.displayName ?? "")
                                    .font(DS.Fonts.commitAuthor)
                                    .foregroundStyle(DS.Colors.ink)
                                    .lineLimit(1)
                                Text("@\(commit.author?.handle ?? "")")
                                    .font(DS.Fonts.monoHandle)
                                    .foregroundStyle(DS.Colors.inkMuted)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: DS.Spacing.m)

                    if let author = commit.author, author.id != workspace.session.user?.id {
                        FollowButton(user: author)
                    }
                }

                if !commit.text.isEmpty {
                    CommitBodyView(commit: commit, size: 15, foldable: false)
                }

                TranslationView(box: box)
                CommitEmbeds(commit: commit)

                Text(stampText)
                    .font(DS.Fonts.monoMeta)
                    .foregroundStyle(DS.Colors.inkFaint)
                    .textSelection(.enabled)

                CommitActionRow(box: box, full: true)
            }
            .contextMenu { CommitMenuItems(box: box) }
        }
    }

    private var stampText: String {
        switch stamp {
        case .pane:
            let day = commit.createdAt.map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? ""
            return "\(Formatting.relative(commit.createdAt)) · \(day) · commit \(commit.hash)"
        case .page:
            return "\(Formatting.stamp(commit.createdAt)) · commit \(commit.hash)"
        }
    }
}

/// Follow or Following. Following never flips to "Unfollow" under the pointer; unfollowing is its menu.
struct FollowButton: View {
    @Environment(Workspace.self) private var workspace
    let user: User

    @State private var isFollowing: Bool?
    @State private var isBusy = false

    var body: some View {
        let following = isFollowing ?? user.isFollowed ?? false

        Group {
            if following {
                Menu("Following") {
                    Button("Unfollow @\(user.handle)") { toggle(to: false) }
                }
                .menuStyle(.button)
                .buttonStyle(DSButtonStyle(kind: .outline))
                .menuIndicator(.hidden)
            } else {
                Button(user.followsYou == true ? "Follow Back" : "Follow") { toggle(to: true) }
                    .buttonStyle(.dsPrimary)
            }
        }
        .fixedSize()
        .disabled(isBusy)
    }

    private func toggle(to value: Bool) {
        isBusy = true

        Task {
            if await workspace.setFollowing(value, user) { isFollowing = value }
            isBusy = false
        }
    }
}

// MARK: - Replies

/// The divider reading `3 replies`, then the replies, loading more at the end.
struct RepliesSection: View {
    @Environment(Workspace.self) private var workspace
    let store: ThreadStore
    let depth: Int

    var body: some View {
        let replies = store.replies.compactMap { workspace.existingBox($0) }.filter { !$0.isRemoved }
        let count = max(store.commit?.commit.replies ?? 0, replies.count)

        VStack(alignment: .leading, spacing: 0) {
            if depth == 0, count > 0 {
                HStack(spacing: DS.Spacing.m) {
                    DS.Colors.hairline.frame(height: 1)
                    Text("\(count) \(count == 1 ? "reply" : "replies")")
                        .font(DS.Fonts.monoCaption)
                        .foregroundStyle(DS.Colors.inkMuted)
                        .fixedSize()
                    DS.Colors.hairline.frame(height: 1)
                }
                .padding(.horizontal, DS.Spacing.l)
                .padding(.vertical, DS.Spacing.s)
            }

            if store.isLoading, replies.isEmpty {
                ForEach(0 ..< min(max(count, 1), 3), id: \.self) { _ in ReplySkeleton() }
            }

            ForEach(Array(replies.enumerated()), id: \.element.id) { index, reply in
                ReplyRow(box: reply, depth: depth, isLast: index == replies.count - 1 && !store.hasMoreReplies)
            }

            if store.hasMoreReplies {
                Button("Show more replies") { Task { await store.loadMoreReplies() } }
                    .buttonStyle(LinkButtonStyle())
                    .padding(.leading, DS.Spacing.l + DS.Metrics.replyAvatar + DS.Spacing.m)
                    .padding(.vertical, DS.Spacing.s)
            }
        }
    }
}

/// A reply: 28pt avatar on a 1pt rail guide, the name, handle and time, a `bot` chip, the body at 13.5, and a compact
/// action row. Its own replies open in place, three levels deep, then "Continue thread →".
struct ReplyRow: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.workspaceActions) private var actions

    let box: CommitBox
    let depth: Int
    var isLast = false

    @State private var showsReplies = false
    @State private var isHovered = false

    private var commit: Commit { box.commit }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: DS.Spacing.m) {
                VStack(spacing: 0) {
                    if commit.isTombstone {
                        Circle()
                            .strokeBorder(DS.Colors.rail, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                            .frame(width: DS.Metrics.replyAvatar, height: DS.Metrics.replyAvatar)
                    } else {
                        Button {
                            if let handle = commit.author?.handle { actions?.openProfile(handle) }
                        } label: {
                            Avatar(user: commit.author, size: DS.Metrics.replyAvatar)
                        }
                        .buttonStyle(.plain)
                    }

                    if !isLast || showsReplies {
                        DS.Colors.rail
                            .frame(width: 1)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(width: DS.Metrics.replyAvatar)

                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    if commit.isTombstone {
                        Text("[deleted]")
                            .font(DS.Fonts.monoCaption)
                            .foregroundStyle(DS.Colors.inkMuted)
                        Text("This commit was deleted.")
                            .font(DS.Fonts.body)
                            .foregroundStyle(DS.Colors.inkMuted)
                    } else if box.isDeleting {
                        Text("rm \(commit.hash)")
                            .font(DS.Fonts.monoCaption)
                            .foregroundStyle(DS.Colors.destructive)
                    } else {
                        header

                        if !commit.text.isEmpty {
                            CommitBodyView(commit: commit, size: 13.5)
                        }

                        TranslationView(box: box)
                        CommitEmbeds(commit: commit)
                        actionRow
                    }

                    if commit.replies > 0 {
                        nestedToggle
                    }
                }
                .padding(.bottom, DS.Spacing.l)
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.top, DS.Spacing.s)
            .background(isHovered ? DS.Colors.wash : .clear)
            .onHover { isHovered = $0 }
            .contextMenu { if !commit.isTombstone { CommitMenuItems(box: box) } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Reply by \(commit.author?.displayName ?? "someone"), \(Formatting.relative(commit.createdAt)): \(commit.text)")

            if showsReplies {
                RepliesSection(store: workspace.thread(box.id), depth: depth + 1)
                    .padding(.leading, DS.Metrics.replyAvatar + DS.Spacing.m)
                    .task { await workspace.thread(box.id).load() }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            Text(commit.author?.displayName ?? "")
                .font(DS.Fonts.commitAuthor)
                .foregroundStyle(DS.Colors.ink)
                .lineLimit(1)
            if commit.author?.isBot == true {
                StatusLabel(text: "bot")
            }
            Text("@\(commit.author?.handle ?? "") · \(Formatting.relative(commit.createdAt))")
                .font(DS.Fonts.monoCaption)
                .foregroundStyle(DS.Colors.inkMuted)
                .lineLimit(1)
                .help(Formatting.stamp(commit.createdAt))
            Spacer(minLength: 0)
        }
    }

    private var actionRow: some View {
        HStack(spacing: DS.Spacing.l) {
            Button {
                workspace.toggleStar(box.id)
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: commit.isStarred ? "star.fill" : "star")
                        .foregroundStyle(commit.isStarred ? DS.Colors.primary : DS.Colors.inkMuted)
                    if commit.stars > 0 {
                        Text(verbatim: "\(commit.stars)")
                            .font(DS.Fonts.monoCaption)
                            .foregroundStyle(commit.isStarred ? DS.Colors.primary : DS.Colors.inkMuted)
                    }
                }
                .font(.system(size: 12))
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(commit.author?.id == workspace.session.user?.id)
            .help(commit.isStarred ? "Unstar" : "Star")
            .accessibilityLabel(commit.isStarred ? "Unstar, \(commit.stars) stars" : "Star, \(commit.stars) stars")

            Button {
                navigation.openThread(box.id, focusComposer: true)
            } label: {
                Image(systemName: "bubble.left")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.inkMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reply")
            .accessibilityLabel("Reply")

            Button {
                workspace.copyLink(box.id)
            } label: {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.inkMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy Link")
            .accessibilityLabel("Copy link")
        }
    }

    @ViewBuilder
    private var nestedToggle: some View {
        if depth >= 2 {
            Button("Continue thread →") { navigation.push(.commit(box.id)) }
                .buttonStyle(LinkButtonStyle())
        } else {
            Button(showsReplies ? "Hide replies" : "\(commit.replies) \(commit.replies == 1 ? "reply" : "replies")") {
                showsReplies.toggle()
            }
            .buttonStyle(LinkButtonStyle())
        }
    }
}

/// A related commit: one compact line of who and when, then two lines of the body; the whole row opens its page.
struct CompactCommitRow: View {
    @Environment(Navigation.self) private var navigation
    let box: CommitBox

    @State private var isHovered = false

    var body: some View {
        Button {
            navigation.push(.commit(box.id))
        } label: {
            HStack(alignment: .top, spacing: DS.Spacing.m) {
                Avatar(user: box.commit.author, size: 20)
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    HStack(spacing: DS.Spacing.xs) {
                        Text(box.commit.author?.displayName ?? "")
                            .font(DS.Fonts.commitAuthor)
                            .foregroundStyle(DS.Colors.ink)
                            .lineLimit(1)
                        Text("@\(box.commit.author?.handle ?? "") · \(Formatting.relative(box.commit.createdAt))")
                            .font(DS.Fonts.monoCaption)
                            .foregroundStyle(DS.Colors.inkMuted)
                            .lineLimit(1)
                    }
                    Text(box.commit.text)
                        .font(DS.Fonts.body)
                        .foregroundStyle(DS.Colors.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, DS.Spacing.m)
            .padding(.leading, DS.Metrics.railWidth + DS.Spacing.xs)
            .padding(.trailing, DS.Metrics.commitGutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? DS.Colors.wash : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottom) { RowHairline() }
        .accessibilityLabel("Related commit by \(box.commit.author?.displayName ?? "someone"): \(box.commit.text)")
    }
}

// MARK: - Skeletons

/// The thread's shape while the commit loads.
private struct ThreadSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(spacing: DS.Spacing.m) {
                Circle().fill(DS.Colors.wash).frame(width: DS.Metrics.threadAvatar, height: DS.Metrics.threadAvatar)
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    SkeletonBar(width: 120, height: 10)
                    SkeletonBar(width: 80, height: 10)
                }
            }
            SkeletonBar(width: 280, height: 12)
            SkeletonBar(width: 220, height: 12)
            SkeletonBar(width: 160, height: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .skeleton()
    }
}

private struct ReplySkeleton: View {
    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            Circle().fill(DS.Colors.wash).frame(width: DS.Metrics.replyAvatar, height: DS.Metrics.replyAvatar)
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                SkeletonBar(width: 140, height: 9)
                SkeletonBar(width: 220, height: 9)
            }
        }
        .padding(DS.Spacing.l)
        .skeleton()
    }
}
