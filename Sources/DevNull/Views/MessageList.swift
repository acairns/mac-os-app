import AppKit
import SwiftUI

/// One row of a thread: a message, a day or the "Unread messages" bar, the typing bubble, or the top of the thread.
/// A message keeps the same id from the moment it is pushed to when the API answers, so the list swaps it in place.
struct ChatRow: Identifiable, Equatable {
    enum Kind: Hashable {
        case intro
        case loadingOlder
        case day(Date)
        case unread
        case message(Message, MessageLayout, PendingMessage.Status?)
        case receipt(PullReceipt)
        case typing([String])
        case end
    }

    let id: String
    let kind: Kind

    var isMessage: Bool {
        if case .message = kind { return true }
        return false
    }

    /// Messages grouped like a chat app: a day separator when the day changes, and consecutive messages from the same
    /// person within a few minutes in one group, with the name on the first and the tail and avatar on the last.
    @MainActor static func rows(for thread: ThreadModel, me: String?) -> [ChatRow] {
        let calendar = Calendar.current
        let messages = thread.messages + thread.pending.map { $0.asMessage(userId: me) }
        let statuses = Dictionary(thread.pending.map { ($0.clientId, $0.status) }, uniquingKeysWith: { first, _ in first })
        var rows: [ChatRow] = []

        if !thread.isLoaded {
            return []
        }

        rows.append(thread.hasOlder ? ChatRow(id: "older", kind: .loadingOlder) : ChatRow(id: "intro", kind: .intro))

        for (index, message) in messages.enumerated() {
            let previous = index > 0 ? messages[index - 1] : nil
            let next = index < messages.count - 1 ? messages[index + 1] : nil

            if previous.map({ !calendar.isDate($0.createdAt, inSameDayAs: message.createdAt) }) ?? true {
                let day = calendar.startOfDay(for: message.createdAt)
                rows.append(ChatRow(id: "day-\(Int(day.timeIntervalSince1970))", kind: .day(day)))
            }

            if message.id == thread.unreadMarkerId {
                rows.append(ChatRow(id: "unread", kind: .unread))
            }

            let status = message.id < 0 ? message.clientId.flatMap { statuses[$0] } : nil

            rows.append(ChatRow(id: message.clientId.map { "c-\($0)" } ?? "m-\(message.id)", kind: .message(message, MessageLayout(
                isOutgoing: message.userId == me,
                isFirstInGroup: !(previous.map { groups($0, message) } ?? false),
                isLastInGroup: !(next.map { groups(message, $0) } ?? false),
                showsSender: thread.isOrg
            ), status)))
        }

        if let receipt = PullReceipt.latest(in: thread, me: me) {
            rows.append(ChatRow(id: "receipt", kind: .receipt(receipt)))
        }

        if !thread.typing.isEmpty {
            rows.append(ChatRow(id: "typing", kind: .typing(thread.typing)))
        }

        rows.append(ChatRow(id: "end", kind: .end))

        return rows
    }

    private static func groups(_ first: Message, _ second: Message) -> Bool {
        !first.isEvent && !second.isEvent
            && first.userId == second.userId
            && second.createdAt.timeIntervalSince(first.createdAt) < 600
            && Calendar.current.isDate(first.createdAt, inSameDayAs: second.createdAt)
    }
}

/// Who pulled the latest message, shown under it like the web does: in a DM, when the partner pulled the user's last
/// message; in an org, the avatars of the members who pulled the latest message. Members only count when both they
/// and the user share pulls, since the API reports 0 for everyone else.
struct PullReceipt: Hashable {
    let isOutgoing: Bool
    let readers: [User]
    let total: Int
    let pulledAt: Date?

    @MainActor static func latest(in thread: ThreadModel, me: String?) -> PullReceipt? {
        guard thread.pending.isEmpty, let last = thread.messages.last, !last.isEvent else { return nil }

        if thread.isOrg {
            let readers = thread.readers(of: last)

            guard !readers.isEmpty else { return nil }

            return PullReceipt(isOutgoing: last.userId == me, readers: readers, total: thread.members.filter { $0.user.id != me && $0.user.id != last.userId }.count, pulledAt: nil)
        }

        guard last.userId == me, thread.partnerReadThroughId >= last.id else { return nil }

        return PullReceipt(isOutgoing: true, readers: [thread.partner].compactMap { $0 }, total: 1, pulledAt: thread.partnerReadAt)
    }
}

/// What the chat view asks of its list: scrolling to the bottom or to a message.
@MainActor
final class MessageListController {
    fileprivate weak var coordinator: MessageList.Coordinator?

    func scrollToBottom() {
        coordinator?.scrollToBottom(animated: true)
    }

    func scroll(toMessage id: Int) -> Bool {
        coordinator?.scroll(toMessage: id) ?? false
    }

    /// The window rect of the row of a message, for menus and popovers anchored on it.
    func rowView(forMessage id: Int) -> (NSView, NSRect)? {
        coordinator?.rowView(forMessage: id)
    }

    #if DEBUG
        /// Scrolls the preview like a trackpad would, without the mouse: `top`, `up` or `down` by most of a screenful.
        func previewScroll(_ step: String) {
            coordinator?.previewScroll(step)
        }
    #endif
}

/// The thread's messages in an NSTableView, like Telegram's list: rows are SwiftUI views measured once per content and
/// width, scrolling stays at 60/120 fps, the bottom stays put when rows come in, go or change size, and loading older
/// messages above or new ones below never moves what is being read.
struct MessageList: NSViewRepresentable {
    let thread: ThreadModel
    let rows: [ChatRow]
    let controller: MessageListController
    let content: (ChatRow) -> AnyView
    let menu: (Message) -> NSMenu?
    let onScroll: (_ atBottom: Bool, _ newBelow: Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(thread: thread, content: content)
    }

    func makeNSView(context: Context) -> ChatScrollView {
        let coordinator = context.coordinator
        let table = ChatTableView()
        table.coordinator = coordinator
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.allowsEmptySelection = true
        table.floatsGroupRows = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.gridStyleMask = []
        table.usesAutomaticRowHeights = false
        table.setAccessibilityLabel("Messages")

        let column = NSTableColumn(identifier: .init("message"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scrollView = ChatScrollView()
        let clip = ChatClipView()
        clip.coordinator = coordinator
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.coordinator = coordinator
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = table

        coordinator.table = table
        coordinator.scrollView = scrollView
        coordinator.rows = rows
        coordinator.menu = menu
        coordinator.onScroll = onScroll
        controller.coordinator = coordinator

        table.dataSource = coordinator
        table.delegate = coordinator

        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.didScroll), name: NSView.boundsDidChangeNotification, object: clip)

        return scrollView
    }

    func updateNSView(_ scrollView: ChatScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.content = content
        coordinator.menu = menu
        coordinator.onScroll = onScroll
        controller.coordinator = coordinator
        coordinator.apply(rows)
    }

    static func dismantleNSView(_ scrollView: ChatScrollView, coordinator: Coordinator) {
        coordinator.saveScrollPosition()
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let thread: ThreadModel
        var content: (ChatRow) -> AnyView
        var menu: (Message) -> NSMenu? = { _ in nil }
        var onScroll: (Bool, Int) -> Void = { _, _ in }
        var rows: [ChatRow] = []

        weak var table: ChatTableView?
        weak var scrollView: ChatScrollView?

        /// Rows are measured off screen with the same views the cells show.
        private let sizer = NSHostingController(rootView: AnyView(EmptyView()))
        private var positioned = false
        private var measuredWidth: CGFloat = 0
        private var animatingToBottom = false
        private var appearing: Set<String> = []
        private var newBelow = 0
        private var reportedAtBottom = true
        private var reportedNewBelow = 0

        init(thread: ThreadModel, content: @escaping (ChatRow) -> AnyView) {
            self.thread = thread
            self.content = content
            super.init()
            sizer.sizingOptions = []
        }

        // MARK: Heights

        /// Rows wider than this lay out the same, since bubbles stop growing, so widths past it share measurements.
        private static let widestLayout: CGFloat = 820

        private var layoutWidth: CGFloat {
            min(scrollView?.contentView.bounds.width ?? 0, Self.widestLayout).rounded()
        }

        private func height(of row: ChatRow) -> CGFloat {
            let width = layoutWidth

            guard width > 0 else { return 1 }

            var hasher = Hasher()
            hasher.combine(row.kind)
            let key = "\(row.id)|\(hasher.finalize())|\(Int(width))"

            if let cached = thread.rowHeights[key] {
                return cached
            }

            if thread.rowHeights.count > 4000 {
                thread.rowHeights.removeAll(keepingCapacity: true)
            }

            sizer.rootView = content(row)
            let height = max(1, ceil(sizer.sizeThatFits(in: CGSize(width: width, height: 20000)).height))
            thread.rowHeights[key] = height

            return height
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            height(of: rows[row])
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("row")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? HostingCell ?? HostingCell(identifier: identifier)
            cell.show(rows[row], content: content)

            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            ClearRowView()
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            if case .day = rows[row].kind { return true }
            return false
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            false
        }

        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            guard row < rows.count, appearing.remove(rows[row].id) != nil else { return }

            // New messages rise into place and fade in, like Telegram's.
            rowView.wantsLayer = true
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = min(rowView.frame.height, 36) * (rowView.isFlipped ? 1 : -1)
            rise.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [rise, fade]
            group.duration = 0.28
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            rowView.layer?.add(group, forKey: "appear")
        }

        // MARK: Applying rows

        func apply(_ next: [ChatRow]) {
            guard let table else {
                rows = next
                return
            }

            guard next != rows else { return }

            let previous = rows

            // Until there are messages to show, there's nothing to keep in place: lay the thread out from scratch.
            guard positioned, previous.contains(where: \.isMessage) else {
                rows = next
                table.reloadData()
                positionInitially()
                return
            }

            let atBottom = isAtBottom
            let anchor = atBottom ? nil : captureAnchor()
            let difference = next.map(\.id).difference(from: previous.map(\.id))
            var removals = IndexSet()
            var insertions = IndexSet()

            for change in difference {
                switch change {
                case let .remove(offset, _, _): removals.insert(offset)
                case let .insert(offset, _, _): insertions.insert(offset)
                }
            }

            let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var changed = IndexSet()

            for (index, row) in next.enumerated() where !insertions.contains(index) {
                if let old = before[row.id], old != row {
                    changed.insert(index)
                }
            }

            // Messages added after the last one that was there: they animate in when the bottom is in view, and are
            // counted on the "new messages" button when it isn't.
            let lastKnown = previous.lastIndex(where: \.isMessage).map { previous[$0].id }
            let lastKnownIndex = lastKnown.flatMap { id in next.firstIndex { $0.id == id } } ?? -1
            let arrived = insertions.filter { $0 > lastKnownIndex && next[$0].isMessage }

            if atBottom {
                appearing.formUnion(arrived.map { next[$0].id })
            } else {
                newBelow += arrived.filter { index in
                    if case let .message(_, layout, _) = next[index].kind { return !layout.isOutgoing }
                    return false
                }.count
            }

            rows = next

            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            table.beginUpdates()
            if !removals.isEmpty { table.removeRows(at: removals, withAnimation: []) }
            if !insertions.isEmpty { table.insertRows(at: insertions, withAnimation: []) }
            table.endUpdates()

            for index in changed {
                (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? HostingCell)?.show(next[index], content: content)
            }

            if !changed.isEmpty {
                table.noteHeightOfRows(withIndexesChanged: changed)
            }
            NSAnimationContext.endGrouping()
            updateRestingInset()

            // Sending from anywhere in the thread goes down to the message, as Telegram does.
            let sent = arrived.contains { index in
                if case let .message(_, layout, status) = next[index].kind { return layout.isOutgoing && status != nil }
                return false
            }

            if atBottom || sent {
                // Sending or receiving while at the bottom follows the message down; anything else stays pinned there.
                scrollToBottom(animated: !arrived.isEmpty)
            } else if let anchor {
                restore(anchor)
            }

            reportScroll()
        }

        // MARK: Positions

        /// A thread shorter than the view rests on the composer, as chat apps lay it out: the room above it becomes a
        /// top inset, since AppKit stretches a table to fill its clip view and would leave the rows at the top.
        private func updateRestingInset() {
            guard let table, let scrollView else { return }

            let rowsHeight = table.numberOfRows > 0 ? table.rect(ofRow: table.numberOfRows - 1).maxY : 0
            let inset = max(0, scrollView.frame.height - rowsHeight).rounded()

            guard abs(scrollView.contentInsets.top - inset) > 0.5 else { return }

            scrollView.contentInsets = NSEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
        }

        var isAtBottom: Bool {
            guard let scrollView, let table else { return true }

            return animatingToBottom || scrollView.contentView.bounds.maxY >= table.frame.height - 2
        }

        /// The lowest row in view and how far its bottom is above the bottom of the visible area.
        func captureAnchor() -> ScrollAnchor? {
            guard let table, let scrollView else { return nil }

            let visible = scrollView.contentView.bounds
            let range = table.rows(in: visible)

            guard range.length > 0 else { return nil }

            for index in stride(from: range.location + range.length - 1, through: range.location, by: -1) where index < rows.count {
                let rect = table.rect(ofRow: index)

                if rect.minY < visible.maxY - 1 {
                    return ScrollAnchor(rowId: rows[index].id, offset: rect.maxY - visible.maxY)
                }
            }

            return nil
        }

        func restore(_ anchor: ScrollAnchor) {
            guard let table, let index = rows.firstIndex(where: { $0.id == anchor.rowId }) else { return }

            let rect = table.rect(ofRow: index)
            scroll(toY: rect.maxY - anchor.offset - visibleHeight)
        }

        private var visibleHeight: CGFloat {
            scrollView?.contentView.bounds.height ?? 0
        }

        private func scroll(toY y: CGFloat, animated: Bool = false, completion: (() -> Void)? = nil) {
            guard let scrollView else { return }

            let clip = scrollView.contentView
            let target = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin

            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.26
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                    clip.animator().setBoundsOrigin(target)
                } completionHandler: {
                    completion?()
                }
            } else {
                clip.setBoundsOrigin(target)
                completion?()
            }

            scrollView.reflectScrolledClipView(clip)
        }

        func scrollToBottom(animated: Bool) {
            guard let table else { return }

            let bottom = table.frame.height - visibleHeight
            newBelow = 0

            guard animated else {
                scroll(toY: bottom)
                reportScroll()
                return
            }

            // From far up, jump most of the way first so the animation is short, as Telegram does.
            if let clip = scrollView?.contentView, bottom - clip.bounds.minY > visibleHeight * 2 {
                scroll(toY: bottom - visibleHeight * 1.5)
            }

            animatingToBottom = true
            scroll(toY: bottom, animated: true) { [weak self] in
                guard let self else { return }
                self.animatingToBottom = false
                // Rows that arrived during the animation may have grown the list.
                if let table = self.table, let clip = self.scrollView?.contentView, clip.bounds.maxY < table.frame.height - 2 {
                    self.scroll(toY: table.frame.height - self.visibleHeight)
                }
                self.reportScroll()
            }
        }

        func scroll(toMessage id: Int) -> Bool {
            guard let table, let index = rows.firstIndex(where: {
                if case let .message(message, _, _) = $0.kind { return message.id == id }
                return false
            }) else { return false }

            let rect = table.rect(ofRow: index)
            scroll(toY: rect.midY - visibleHeight / 2, animated: true)

            return true
        }

        func rowView(forMessage id: Int) -> (NSView, NSRect)? {
            guard let table, let index = rows.firstIndex(where: {
                if case let .message(message, _, _) = $0.kind { return message.id == id }
                return false
            }) else { return nil }

            return (table, table.rect(ofRow: index))
        }

        /// Opens the thread where the user left it, at the "Unread messages" bar, or at the bottom.
        func positionInitially() {
            guard let table, visibleHeight > 0, layoutWidth > 0 else { return }

            // Heights asked for before the list had its width are measured again at the real one.
            if measuredWidth != layoutWidth {
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< rows.count))
                NSAnimationContext.endGrouping()
            }

            table.layoutSubtreeIfNeeded()
            updateRestingInset()

            if let index = rows.firstIndex(where: { $0.id == "unread" }), table.frame.height - table.rect(ofRow: index).minY > visibleHeight {
                // Room above the bar for the day floating at the top.
                scroll(toY: table.rect(ofRow: index).minY - 40)
            } else if let anchor = thread.scrollAnchor, rows.contains(where: { $0.id == anchor.rowId }) {
                restore(anchor)
            } else {
                scroll(toY: table.frame.height - visibleHeight)
            }

            positioned = rows.contains(where: \.isMessage)
            measuredWidth = layoutWidth
            newBelow = 0
            reportScroll()
        }

        /// The first layout with a size positions the thread before anything is drawn, so it never opens at the top.
        func layoutChanged() {
            if !positioned {
                positionInitially()
            }
        }

        func saveScrollPosition() {
            thread.scrollAnchor = isAtBottom ? nil : captureAnchor()
        }

        // MARK: Resizing

        /// The visible area is about to change size (window resize, composer growing): keep its bottom where it is.
        func clipWillResize() -> (atBottom: Bool, anchor: ScrollAnchor?) {
            (isAtBottom, isAtBottom ? nil : captureAnchor())
        }

        func clipDidResize(_ state: (atBottom: Bool, anchor: ScrollAnchor?)) {
            guard let table, positioned else {
                positionInitially()
                return
            }

            if layoutWidth != measuredWidth {
                measuredWidth = layoutWidth
                // While dragging, only the rows in view are measured again; the rest follow when the drag ends.
                let all = IndexSet(integersIn: 0 ..< rows.count)
                let visible = IndexSet(integersIn: Range(table.rows(in: table.visibleRect)) ?? 0 ..< 0)
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                table.noteHeightOfRows(withIndexesChanged: table.inLiveResize ? visible : all)
                NSAnimationContext.endGrouping()
            }

            updateRestingInset()

            if state.atBottom {
                scroll(toY: table.frame.height - visibleHeight)
            } else if let anchor = state.anchor {
                restore(anchor)
            }
        }

        func liveResizeEnded() {
            guard let table else { return }

            let state = clipWillResize()
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< rows.count))
            NSAnimationContext.endGrouping()
            clipDidResize(state)
        }

        // MARK: Scrolling

        @objc func didScroll() {
            reportScroll()

            guard let table, positioned, thread.hasOlder, !thread.isLoadingOlder else { return }

            // Older messages load well before the top comes into view.
            if table.visibleRect.minY < max(900, visibleHeight * 1.5) {
                Task { await thread.loadOlder() }
            }
        }

        private func reportScroll() {
            let atBottom = isAtBottom

            if atBottom { newBelow = 0 }

            guard atBottom != reportedAtBottom || newBelow != reportedNewBelow else { return }

            reportedAtBottom = atBottom
            reportedNewBelow = newBelow
            onScroll(atBottom, newBelow)
        }

        #if DEBUG
            func previewScroll(_ step: String) {
                guard let clip = scrollView?.contentView else { return }

                switch step {
                case "top": scroll(toY: 0)
                case "up": scroll(toY: clip.bounds.minY - visibleHeight * 0.8)
                case "down": scroll(toY: clip.bounds.minY + visibleHeight * 0.8)
                default: break
                }
            }
        #endif

        // MARK: Menu

        func menu(forRow index: Int) -> NSMenu? {
            guard index >= 0, index < rows.count, case let .message(message, _, status) = rows[index].kind, status == nil else { return nil }

            return menu(message)
        }
    }
}

// MARK: - AppKit pieces

/// The list's table: a right click opens the message's menu, and nothing is ever selected or focused, so the composer
/// keeps the keyboard.
final class ChatTableView: NSTableView {
    weak var coordinator: MessageList.Coordinator?

    override var acceptsFirstResponder: Bool { false }

    override func menu(for event: NSEvent) -> NSMenu? {
        coordinator?.menu(forRow: row(at: convert(event.locationInWindow, from: nil)))
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        coordinator?.liveResizeEnded()
    }

    // The table never draws its own background or grid.
    override func drawBackground(inClipRect clipRect: NSRect) {}
}

/// Keeps a short thread at the bottom of the view instead of the top, and the bottom in place as the view resizes.
final class ChatClipView: NSClipView {
    weak var coordinator: MessageList.Coordinator?

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)

        if let height = documentView?.frame.height, height < rect.height {
            rect.origin.y = height - rect.height
        }

        return rect
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard newSize != frame.size, let coordinator else {
            super.setFrameSize(newSize)
            return
        }

        let state = coordinator.clipWillResize()
        super.setFrameSize(newSize)
        coordinator.clipDidResize(state)
    }
}

final class ChatScrollView: NSScrollView {
    weak var coordinator: MessageList.Coordinator?

    override func layout() {
        super.layout()
        coordinator?.layoutChanged()
    }
}

/// A row that draws nothing itself, so floating day headers and highlights come from the SwiftUI content only.
final class ClearRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// A cell showing a row's SwiftUI view, reused as the list scrolls. It only rebuilds the view when its row changed.
final class HostingCell: NSTableCellView {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var shown: ChatRow?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func show(_ row: ChatRow, content: (ChatRow) -> AnyView) {
        guard row != shown else { return }

        shown = row
        host.rootView = content(row)
    }
}
