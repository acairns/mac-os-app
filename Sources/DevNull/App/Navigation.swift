import Foundation
import Observation

/// The three logs the web shows, by the name the API knows them by.
enum LogKind: String, Codable, Hashable, CaseIterable {
    case following
    case latest
    case trending

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .following: "point.3.connected.trianglepath.dotted"
        case .latest: "clock"
        case .trending: "chart.line.uptrend.xyaxis"
        }
    }
}

/// Everything the sidebar lists. Each item has one destination in the center, and can open in a window of its own.
enum SidebarItem: Hashable, Codable, Identifiable {
    case log(LogKind)
    case remote(ThreadReference)
    case allRemotes
    case stashed
    case notifications
    case starred
    case scheduled
    case profile

    static let following = SidebarItem.log(.following)
    static let latest = SidebarItem.log(.latest)
    static let trending = SidebarItem.log(.trending)

    var id: String {
        switch self {
        case let .log(kind): "log:" + kind.rawValue
        case let .remote(reference): "remote:" + reference.id
        case .allRemotes: "all-remotes"
        case .stashed: "stashed"
        case .notifications: "notifications"
        case .starred: "starred"
        case .scheduled: "scheduled"
        case .profile: "profile"
        }
    }

    var title: String {
        switch self {
        case let .log(kind): kind.title
        case let .remote(reference): reference.title
        case .allRemotes: "All Remotes"
        case .stashed: "Stashed"
        case .notifications: "Notifications"
        case .starred: "Starred"
        case .scheduled: "Scheduled"
        case .profile: "Profile"
        }
    }

    var symbol: String {
        switch self {
        case let .log(kind): kind.symbol
        case .remote: "bubble.left"
        case .allRemotes: "ellipsis.bubble"
        case .stashed: "archivebox"
        case .notifications: "bell"
        case .starred: "star"
        case .scheduled: "calendar.badge.clock"
        case .profile: "person"
        }
    }

    /// Whether the center shows a list of commits, where the replies pane holds a thread and the single-letter
    /// commands act on the focused row.
    var listsCommits: Bool {
        switch self {
        case .log, .starred, .profile, .notifications: true
        default: false
        }
    }
}

/// A page pushed over a sidebar item's destination, walked with Back and Forward.
enum Route: Hashable, Codable {
    case profile(String)
    case commit(String)
    case search(String)
    case followers(String)
    case following(String)
}

/// What the replies pane shows: a commit's thread, or the info of the remote in the center.
enum PaneTarget: Hashable {
    case thread(String)
    case info
}

/// One window's place in the workspace: the sidebar selection, the pages pushed over it, Back and Forward, the replies
/// pane and the row the keyboard is on. Never saved to disk.
@MainActor
@Observable
final class Navigation {
    var item: SidebarItem? {
        didSet {
            guard item != oldValue else { return }

            path = []
            forwardStack = []
            focusedRow = nil

            if case .remote = item {
                if case .thread = pane { pane = nil }
            } else if pane == .info {
                pane = nil
            }
        }
    }

    /// The pages pushed over the item's destination, oldest first.
    var path: [Route] = []
    private(set) var forwardStack: [Route] = []
    /// The commit whose thread is open, or the remote's info.
    var pane: PaneTarget?
    /// Whether the user wants the replies pane shown, which survives switching items.
    var isPaneVisible = false
    /// The commit row last clicked, by commit id.
    var focusedRow: String?
    /// Where the pane's reply composer should take the focus as soon as it shows.
    var focusReplyComposer = false
    /// The row each log was scrolled to, so coming back to a log finds the place it was left at.
    @ObservationIgnored var logAnchors: [LogKind: String] = [:]
    /// The log Trending shuffles on each open and on ⌘R.
    var trendingSeed = Int.random(in: 0 ..< 1_000_000)

    init(item: SidebarItem? = .following) {
        self.item = item
    }

    var canGoBack: Bool { !path.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var route: Route? { path.last }

    func push(_ route: Route) {
        guard path.last != route else { return }

        path.append(route)
        forwardStack = []
        focusedRow = nil
    }

    func back() {
        guard let route = path.popLast() else { return }

        forwardStack.append(route)
    }

    func forward() {
        guard let route = forwardStack.popLast() else { return }

        path.append(route)
    }

    /// Selects a sidebar item, or goes back to its root when it is already selected.
    func select(_ item: SidebarItem) {
        if self.item == item {
            path = []
            forwardStack = []
        } else {
            self.item = item
        }
    }

    func openThread(_ commitId: String, focusComposer: Bool = false) {
        pane = .thread(commitId)
        isPaneVisible = true
        focusReplyComposer = focusComposer
    }

    /// `o`: shows the commit's thread, or hides it when it is the one already shown.
    func toggleThread(_ commitId: String) {
        if pane == .thread(commitId), isPaneVisible {
            closePane()
        } else {
            openThread(commitId)
        }
    }

    func closePane() {
        isPaneVisible = false

        if case .thread = pane { pane = nil }
    }

    func togglePane() {
        if isPaneVisible {
            closePane()
        } else {
            if case .remote = item { pane = .info }
            isPaneVisible = pane != nil || item.map { if case .remote = $0 { true } else { false } } ?? false
        }
    }

    /// The commit whose thread is open in the pane, which the log tints.
    var selectedCommit: String? {
        guard isPaneVisible, case let .thread(id) = pane else { return nil }

        return id
    }
}

extension ThreadReference: Codable {
    private enum CodingKeys: String, CodingKey { case direct, orgId, orgName }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let user = try container.decodeIfPresent(User.self, forKey: .direct) {
            self = .direct(user)
        } else {
            self = .org(id: try container.decode(String.self, forKey: .orgId), name: try container.decodeIfPresent(String.self, forKey: .orgName))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .direct(user): try container.encode(user, forKey: .direct)
        case let .org(id, name):
            try container.encode(id, forKey: .orgId)
            try container.encodeIfPresent(name, forKey: .orgName)
        }
    }

    var title: String {
        switch self {
        case let .direct(user): user.displayName
        case let .org(_, name): name ?? "Org"
        }
    }
}
