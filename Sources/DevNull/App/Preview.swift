#if DEBUG
    import AppKit
    import Foundation

    /// A debug-only stand-in for the API, for designing and testing the app without a signed-in account or the Keychain:
    /// the "DevNull Preview" bundle (`sh.dev-null.mac.preview`) answers every request with made-up people and threads,
    /// generates their avatars and images, and every so often has someone type and reply in the open thread.
    enum Preview {
        static let host = "preview.dev-null.invalid"

        static var isEnabled: Bool {
            Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true || ProcessInfo.processInfo.environment["DEVNULL_PREVIEW"] == "1"
        }

        static var me: CurrentUser {
            CurrentUser(id: "u-me", handle: "you", name: "Preview You", avatarUrl: nil, htmlUrl: nil, lane: .palette(0), remotes: RemotesSettings(from: "following", pullReceipts: true, requests: true, everyone: true, unreadCount: 0))
        }
    }

    /// Lets a script drive the preview without focusing it: `open:@maya`, `draft:text`, `send:text`, `bottom`,
    /// `appearance:dark|light`, `size:1100x720`, `lightbox`, `menu`, `hover:<id>`, `scroll:<id>`, `top`, `react:<id>`,
    /// `emoji[:off]`, `record:holding|locked|off`, `paste`, `reply`, `attach:<1-3>`, `info`, `search`, `poll`, `tab:open|fetched|stashed`, posted after the preview's bundle identifier and a space as the
    /// object of the "sh.dev-null.preview.command" distributed notification.
    @MainActor
    enum PreviewCommands {
        private static var observer: NSObjectProtocol?

        static func start(_ session: Session) {
            guard Preview.isEnabled, observer == nil else { return }

            observer = DistributedNotificationCenter.default().addObserver(forName: .init("sh.dev-null.preview.command"), object: nil, queue: .main) { note in
                // Commands name the preview they're for, so two previews can run side by side.
                guard let message = note.object as? String, let space = message.firstIndex(of: " "), message[..<space] == Bundle.main.bundleIdentifier ?? "" else { return }

                MainActor.assumeIsolated { run(String(message[message.index(after: space)...]), session) }
            }
        }

        private static func run(_ command: String, _ session: Session) {
            let (name, argument) = command.firstIndex(of: ":").map { (String(command[..<$0]), String(command[command.index(after: $0)...])) } ?? (command, "")

            guard let inbox = session.inbox else { return }

            let thread = inbox.selection.map { inbox.thread(for: $0) }

            switch name {
            case "open":
                inbox.selection = inbox.conversations.first { $0.reference.id == argument }?.reference
            case "draft":
                thread?.draft = argument
            case "send":
                thread?.draft = argument
                thread?.sendDraft()
            case "tab":
                inbox.tab = InboxTab(rawValue: argument) ?? .open
            case "poll":
                // The preview is never the active app, where threads poll every 15 seconds.
                Task { await thread?.poll() }
            case "bottom":
                NotificationCenter.default.post(name: .scrollToBottom, object: nil)
            case "lightbox", "menu", "hover", "scroll", "top", "react":
                NotificationCenter.default.post(name: .previewChatAction, object: command)
            case "emoji", "record", "paste":
                NotificationCenter.default.post(name: .previewComposerAction, object: command)
            case "reply":
                thread?.replyingTo = thread?.messages.last { !$0.isEvent }
            case "attach":
                let count = max(1, min(3, Int(argument) ?? 1))
                thread?.attachments = (0 ..< count).map { Attachment(data: PreviewImages.image(seed: $0 + 4, width: $0 == 0 ? 1600 : 1000, height: 1000), mimeType: "image/png", filename: "image.png") }
            case "info":
                NotificationCenter.default.post(name: .showInfo, object: nil)
            case "search":
                NotificationCenter.default.post(name: .focusSearch, object: nil)
            case "about":
                AboutWindow.show()
            case "update":
                // `update:available|current|failed` sets what the next check hears, `update:check` checks now.
                if argument == "check" {
                    Task { await Updates.shared.check(unlessCheckedWithin: 0) }
                } else {
                    PreviewStore.shared.update = argument
                }
            case "appearance":
                NSApp.appearance = NSAppearance(named: argument == "dark" ? .darkAqua : .aqua)
            case "size":
                let size = argument.split(separator: "x").compactMap { Double($0) }
                if size.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                    window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: size[0], height: size[1])), display: true, animate: false)
                }
            default:
                break
            }
        }
    }

    extension Notification.Name {
        static let previewChatAction = Notification.Name("devnull.previewChatAction")
        static let previewComposerAction = Notification.Name("devnull.previewComposerAction")
    }

    /// Answers the app's requests from an in-memory store.
    final class PreviewServer: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host() == Preview.host
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            let request = self.request
            let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
            let isWrite = request.httpMethod != "GET"

            DispatchQueue.global().asyncAfter(deadline: .now() + (isWrite ? 0.35 : 0.08)) { [weak self] in
                guard let self, let url = request.url else { return }

                let (status, data, type) = PreviewStore.shared.respond(method: request.httpMethod ?? "GET", url: url, body: body, contentType: request.value(forHTTPHeaderField: "Content-Type") ?? "")
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!

                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }

        override func stopLoading() {}

        private static func read(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)

            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }

            return data
        }
    }

    // MARK: - Store

    final class PreviewStore: @unchecked Sendable {
        static let shared = PreviewStore()

        private let lock = NSLock()
        private var nextId = 5000
        private var reactionsVersion = 1
        private var threads: [String: PreviewThread] = [:]
        private var order: [String] = []
        private var lastScriptAt = Date()
        /// What GET /api/v1/apps/mac answers: "current", "available" or "failed".
        var update = "current"

        private struct PreviewThread {
            var key: String
            var orgId: String?
            var name: String?
            var partner: String?
            var members: [String]
            var roles: [String: String] = [:]
            var messages: [[String: Any]]
            var readThrough: [String: Int] = [:]
            var pinnedAt: String?
            var mutedUntil: String?
            var archived = false
            var access = "open"
            var typingUntil: Date?
            var typingUser: String?
            var reactionChanges: [Int: Int] = [:]
        }

        static let people: [String: (name: String, lane: Int, bio: String)] = [
            "you": ("Preview You", 0, "Building things on /dev/null."),
            "maya": ("Maya Chen", 1, "Design systems, type, and too much coffee."),
            "theo": ("Theo Park", 2, "Backend. Queues. Retries."),
            "rosa": ("Rosa Díaz", 3, "Shipping the iOS app."),
            "sam": ("Sam Okafor", 4, "Infra and late-night deploys."),
            "lena": ("Lena Novak", 5, "Writes the docs nobody reads (you should)."),
            "ivan": ("Ivan Petrov", 2, "Rust, mostly."),
            "zoe": ("Zoë Martin", 4, "Product."),
        ]

        private init() {
            seed()
        }

        // MARK: Fixtures

        private func uid(_ handle: String) -> String {
            handle == "you" ? "u-me" : "u-\(handle)"
        }

        private func user(_ handle: String) -> [String: Any] {
            let person = Self.people[handle] ?? (handle.capitalized, 0, "")

            return [
                "id": uid(handle), "handle": handle, "name": person.name, "bio": person.bio, "lane": person.lane,
                "avatar_url": handle == "you" ? NSNull() : "https://\(Preview.host)/avatar/\(handle).png" as Any,
                "html_url": "https://dev-null.sh/@\(handle)", "is_followed": true, "follows_you": true,
            ]
        }

        private func date(_ minutesAgo: Double) -> String {
            Date(timeIntervalSinceNow: -minutesAgo * 60).formatted(.iso8601)
        }

        private func message(_ id: Int, _ handle: String, _ body: String?, minutesAgo: Double, extra: [String: Any] = [:]) -> [String: Any] {
            var message: [String: Any] = [
                "id": id, "user_id": uid(handle), "client_id": NSNull(), "body": nullable(body), "mentions": [],
                "reply_to_id": NSNull(), "reactions": [], "event": NSNull(), "subject_id": NSNull(),
                "user": user(handle), "created_at": date(minutesAgo),
            ]
            extra.forEach { message[$0.key] = $0.value }
            return message
        }

        private func image(_ seed: Int, _ width: Int, _ height: Int, _ description: String = "") -> [String: Any] {
            ["id": "img-\(seed)", "width": width, "height": height, "description": description, "url": "https://\(Preview.host)/img/\(seed)/\(width)x\(height).png"]
        }

        private func reactions(_ pairs: [(String, String)]) -> [[String: Any]] {
            pairs.map { ["user_id": uid($0.0), "emoji": $0.1] }
        }

        /// A long DM, 320 messages over twelve days, so scrolling up pages through older history 50 at a time.
        private func history() -> [[String: Any]] {
            let lines = [
                "TestFlight build \(Int.random(in: 30 ... 90)) is up 🚀", "Installing now", "Crashes on launch for me 😬", "Fixed, try again?",
                "Works! The new onboarding is so much smoother.", "Can you check the dark mode contrast on the settings screen? Some of the secondary labels are hard to read on the OLED phones.",
                "👍", "Will do after lunch", "Pushed a fix for the keyboard covering the composer on small phones.", "lol", "Shipping it to the beta group tonight.",
                "Do we have a design for the empty state yet?", "Maya is on it", "Merged.",
            ]

            return (0 ..< 320).map { index in
                let id = 1000 + index
                let sender = index % 3 == 0 ? "you" : "rosa"
                var extra: [String: Any] = [:]

                if index % 37 == 5 {
                    extra["images"] = [image(100 + index, index % 2 == 0 ? 1600 : 1000, index % 2 == 0 ? 1000 : 1400, "Screenshot")]
                }

                if index % 11 == 3 {
                    extra["reactions"] = reactions([(sender == "you" ? "rosa" : "you", ["❤️", "😂", "👍", "🔥"][index % 4])])
                }

                if index % 23 == 7, index > 0 {
                    extra["reply_to_id"] = id - 4
                    extra["reply_to"] = ["id": id - 4, "user_id": uid(sender == "you" ? "rosa" : "you"), "body": lines[(index - 4) % lines.count], "images_count": 0, "has_voice": false]
                }

                return message(id, sender, index % 37 == 5 ? nil : lines[index % lines.count], minutesAgo: Double(320 - index) * 54 + 30, extra: extra)
            }
        }

        private func seed() {
            let design = PreviewThread(key: "org:o-design", orgId: "o-design", name: "/dev/null/design", members: ["you", "maya", "theo", "rosa", "lena"], roles: ["you": "maintainer", "maya": "maintainer"], messages: [
                message(100, "maya", nil, minutesAgo: 3000, extra: ["event": "created", "body": "/dev/null/design"]),
                message(101, "maya", nil, minutesAgo: 2990, extra: ["event": "added", "subject": user("theo"), "subject_id": "u-theo"]),
                message(102, "maya", "Morning! I pushed the new type scale to the playground, take a look when you can.", minutesAgo: 1500),
                message(103, "theo", "Looks great. The 15px body reads so much better on Windows.", minutesAgo: 1497, extra: ["reactions": reactions([("maya", "❤️"), ("you", "👍")])]),
                message(104, "you", "Agreed. Shipping it behind the flag today.", minutesAgo: 1490),
                message(105, "rosa", "Screenshots from the iOS build with the new scale:", minutesAgo: 300, extra: ["images": [image(1, 1170, 2532, "iOS inbox with the new type scale"), image(2, 1170, 2532, "iOS thread view")]]),
                message(106, "rosa", "The line height on bubbles is the only thing I'd still tweak.", minutesAgo: 299),
                message(107, "maya", "```swift\nlet bubble = BubbleShape(isOutgoing: true, hasTail: true)\n    .fill(Palette.outgoing)\n```\nThis is all it takes on the Mac side 🎉", minutesAgo: 120, extra: ["body_segments": [
                    ["type": "block", "language": "swift", "html": "let bubble = BubbleShape(isOutgoing: true, hasTail: true)\n    .fill(Palette.outgoing)"],
                    ["type": "text", "text": "\nThis is all it takes on the Mac side 🎉"],
                ]]),
                message(108, "lena", "Wrote it up: https://dev-null.sh/docs/design", minutesAgo: 60, extra: ["link_preview": ["url": "https://dev-null.sh/docs/design", "title": "Design — /dev/null", "description": "Tokens, type and the rules every screen keeps.", "image_url": "https://\(Preview.host)/img/9/1200x630.png", "site_name": "dev-null.sh"]]),
                message(109, "theo", "🔥", minutesAgo: 59),
                message(110, "you", "Love it. @maya can you review the dark palette next?", minutesAgo: 30, extra: ["mentions": [["handle": "maya", "offset": 18, "length": 5]]]),
                message(111, "maya", "On it! Give me an hour.", minutesAgo: 28, extra: ["reply_to_id": 110, "reply_to": ["id": 110, "user_id": "u-me", "body": "Love it. @maya can you review the dark palette next?", "images_count": 0, "has_voice": false], "reactions": reactions([("you", "🙏"), ("rosa", "🙏"), ("theo", "😂")])]),
                message(112, "maya", nil, minutesAgo: 5, extra: ["voice": ["id": "v-1", "duration_ms": 14000, "waveform": (0 ..< 48).map { Int(20 + 70 * abs(sin(Double($0) / 3.1))) }, "url": "https://\(Preview.host)/voice/v-1.wav"]]),
            ], readThrough: ["maya": 112, "theo": 110, "rosa": 109, "lena": 112, "you": 104], pinnedAt: date(10000))

            let maya = PreviewThread(key: "@maya", partner: "maya", members: [], messages: [
                message(200, "maya", "Hey! Do you have a minute for the onboarding flow?", minutesAgo: 2000),
                message(201, "you", "Sure, what's up?", minutesAgo: 1999),
                message(202, "maya", "I think the second step asks too much. Can we drop the bio field?", minutesAgo: 1998),
                message(203, "you", "Yes, let's make it optional and move it to settings.", minutesAgo: 1990, extra: ["reactions": reactions([("maya", "❤️")])]),
                message(204, "you", "👍", minutesAgo: 1989),
                message(205, "maya", "Perfect.", minutesAgo: 400),
                message(206, "maya", "Also, the empty state for the inbox:", minutesAgo: 12, extra: ["images": [image(3, 1600, 1000, "Empty inbox illustration")]]),
                message(207, "maya", "What do you think? Too playful?", minutesAgo: 11),
                message(208, "maya", "I can tone the colors down if it's too much for the dark theme, but I kind of like how it pops against #111112.", minutesAgo: 10),
            ], readThrough: ["maya": 204, "you": 205])

            let theo = PreviewThread(key: "@theo", partner: "theo", members: [], messages: [
                message(300, "theo", "Queue workers are back to normal.", minutesAgo: 800),
                message(301, "you", "Thanks for jumping on it so fast!", minutesAgo: 790),
            ], readThrough: ["theo": 301, "you": 300], mutedUntil: date(-60 * 24 * 365))

            let rosa = PreviewThread(key: "@rosa", partner: "rosa", members: [], messages: history(), readThrough: ["rosa": 1319, "you": 1319])

            let weekend = PreviewThread(key: "org:o-weekend", orgId: "o-weekend", name: nil, members: ["you", "sam", "zoe", "ivan"], roles: ["sam": "maintainer"], messages: [
                message(500, "sam", nil, minutesAgo: 6000, extra: ["event": "created", "body": ""]),
                message(501, "sam", "Hike on Saturday?", minutesAgo: 5000),
                message(502, "zoe", "I'm in!", minutesAgo: 4999),
                message(503, "ivan", "Only if there's coffee at the top ☕", minutesAgo: 4990, extra: ["reactions": reactions([("sam", "😂"), ("zoe", "😂"), ("you", "😂")])]),
            ], readThrough: ["sam": 503, "zoe": 503, "ivan": 503, "you": 503])

            let lena = PreviewThread(key: "@lena", partner: "lena", members: [], messages: [
                message(600, "lena", "Can I quote your post in the newsletter?", minutesAgo: 9000),
            ], readThrough: ["you": 600])

            let sam = PreviewThread(key: "@sam", partner: "sam", members: [], messages: [
                message(700, "sam", "Hi! I'd love to chat about the infra role.", minutesAgo: 50),
            ], readThrough: [:], access: "request")

            for thread in [design, maya, theo, rosa, weekend, lena, sam] {
                threads[thread.key] = thread
                order.append(thread.key)
            }
        }

        // MARK: Routing

        func respond(method: String, url: URL, body: Data, contentType: String) -> (Int, Data, String) {
            lock.lock()
            defer { lock.unlock() }

            let path = url.path()
            let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { first, _ in first })

            if path.hasPrefix("/avatar/") {
                return (200, PreviewImages.avatar(String(path.dropFirst(8).dropLast(4))), "image/png")
            }

            if path.hasPrefix("/img/") {
                let parts = path.split(separator: "/")
                let size = parts.last?.dropLast(4).split(separator: "x").compactMap { Int($0) } ?? [800, 600]
                return (200, PreviewImages.image(seed: Int(parts[1]) ?? 0, width: size.first ?? 800, height: size.last ?? 600), "image/png")
            }

            let route = path.replacingOccurrences(of: "/api/v1/", with: "")
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? Self.multipartPayload(body, contentType: contentType)

            switch (method, route) {
            case ("GET", "me"), ("PUT", "me/remotes"), ("PUT", "me/remote-preferences"):
                return ok(["data": currentUser()])
            case ("GET", "remotes"):
                return ok(inbox(tab: query["tab"] ?? "open", search: query["q"] ?? ""))
            case ("GET", "remotes/candidates"):
                return ok(["candidates": Self.people.keys.sorted().filter { $0 != "you" }.map { ["user": user($0), "reason": NSNull()] }])
            case ("GET", "remotes/reactions"):
                return ok(["usage": []])
            case ("GET", "apps/mac"):
                if update == "failed" {
                    return (503, Data(), "application/json")
                }

                return ok(["data": [
                    "version": update == "available" ? "0.2" : Updates.version,
                    "build": Updates.build + (update == "available" ? 1 : 0),
                    "url": "https://\(Preview.host)/apps",
                ]])
            default:
                break
            }

            if route.hasPrefix("remotes/messages/"), route.hasSuffix("/reactions"), let id = Int(route.split(separator: "/")[2]) {
                return ok(["reactions": react(id, emoji: json["emoji"] as? String ?? "", remove: method == "DELETE")])
            }

            guard let key = threadKey(route), threads[key] != nil else {
                return (404, Data(#"{"message":"Not found."}"#.utf8), "application/json")
            }

            let action = route.split(separator: "/").dropFirst(key.hasPrefix("org:") ? 3 : 2).joined(separator: "/")

            switch (method, action) {
            case ("GET", "messages"):
                return ok(["data": thread(key, after: query["after"].flatMap(Int.init), before: query["before"].flatMap(Int.init))])
            case ("POST", "messages"):
                return ok(["data": push(key, json: json, body: body)])
            case ("PUT", "read"):
                threads[key]?.readThrough["you"] = json["through"] as? Int
                return empty()
            case ("PUT", "pin"):
                threads[key]?.pinnedAt = json["pinned"] as? Bool == true ? date(0) : nil
                return empty()
            case ("PUT", "mute"):
                threads[key]?.mutedUntil = json["duration"] as? String == "off" ? nil : date(-60 * 24)
                return empty()
            case ("POST", "archive"), ("DELETE", "archive"):
                threads[key]?.archived = method == "POST"
                return empty()
            case ("POST", "merge"):
                threads[key]?.access = "open"
                return empty()
            default:
                return empty()
            }
        }

        /// A value for JSON, or null: optionals wrapped in Any can't be serialized.
        private func nullable(_ value: Any?) -> Any {
            value ?? NSNull()
        }

        private func ok(_ object: Any) -> (Int, Data, String) {
            if !JSONSerialization.isValidJSONObject(object) {
                NSLog("Preview response isn't JSON at %@", Self.invalidPath(object, "$") ?? "?")
            }

            return (200, (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), "application/json")
        }

        /// Where a response stops being serializable, to fix fixtures quickly.
        private static func invalidPath(_ value: Any, _ path: String) -> String? {
            switch value {
            case let dictionary as [String: Any]:
                return dictionary.lazy.compactMap { invalidPath($0.value, path + "." + $0.key) }.first
            case let array as [Any]:
                return array.enumerated().lazy.compactMap { invalidPath($0.element, path + "[\($0.offset)]") }.first
            case is String, is NSNumber, is NSNull, is Int, is Bool, is Double:
                return nil
            default:
                return path + " (\(type(of: value)))"
            }
        }

        private func empty() -> (Int, Data, String) {
            (204, Data(), "application/json")
        }

        private func threadKey(_ route: String) -> String? {
            let parts = route.split(separator: "/")

            guard parts.count >= 2, parts[0] == "remotes" else { return nil }

            if parts[1].hasPrefix("@") { return String(parts[1]) }
            if parts[1] == "orgs", parts.count >= 3 { return "org:" + parts[2] }

            return nil
        }

        private func currentUser() -> [String: Any] {
            ["id": "u-me", "handle": "you", "name": "Preview You", "avatar_url": NSNull(), "html_url": NSNull(), "lane": 0,
             "remotes": ["from": "following", "pull_receipts": true, "requests": true, "everyone": true, "unread_count": 0]]
        }

        // MARK: Inbox

        private func inbox(tab: String, search: String) -> [String: Any] {
            scriptIncoming()

            let rows = order.compactMap { threads[$0] }.filter { thread in
                switch tab {
                case "stashed": thread.archived
                case "fetched": thread.access == "request"
                default: !thread.archived && thread.access != "request"
                }
            }.filter { search.isEmpty || ($0.name ?? $0.partner ?? "").localizedCaseInsensitiveContains(search) }
                .sorted { ($0.pinnedAt != nil ? 1 : 0, lastAt($0)) > ($1.pinnedAt != nil ? 1 : 0, lastAt($1)) }

            let data = rows.map(summary)
            let unread = rows.map(ahead).reduce(0, +)

            return ["data": data, "has_more": false, "unread_count": unread, "requests_count": threads.values.filter { $0.access == "request" }.count]
        }

        private func lastAt(_ thread: PreviewThread) -> String {
            thread.messages.last?["created_at"] as? String ?? ""
        }

        private func ahead(_ thread: PreviewThread) -> Int {
            let read = thread.readThrough["you"] ?? 0
            return thread.messages.filter { ($0["id"] as? Int ?? 0) > read && $0["user_id"] as? String != "u-me" && ($0["event"] is NSNull) }.count
        }

        private func summary(_ thread: PreviewThread) -> [String: Any] {
            let incoming = thread.messages.last { $0["user_id"] as? String != "u-me" && ($0["event"] is NSNull) }

            return [
                "id": thread.orgId ?? "c-\(thread.partner ?? "")",
                "kind": thread.orgId == nil ? "direct" : "org",
                "name": nullable(thread.name),
                "partner": nullable(thread.partner.map(user)),
                "members": thread.orgId == nil ? NSNull() : thread.members.map { ["user": user($0), "role": thread.roles[$0] ?? "contributor"] } as Any,
                "last_message": nullable(thread.messages.last),
                "last_message_at": nullable(thread.messages.last?["created_at"]),
                "ahead": ahead(thread),
                "last_incoming_message_id": nullable(incoming?["id"]),
                "last_incoming_sender": nullable((incoming?["user"] as? [String: Any])?["name"]),
                "partner_read_through_id": nullable(thread.partner.flatMap { thread.readThrough[$0] }),
                "is_archived": thread.archived,
                "pinned_at": nullable(thread.pinnedAt),
                "muted_until_at": nullable(thread.mutedUntil),
            ]
        }

        // MARK: Threads

        private func thread(_ key: String, after: Int?, before: Int?) -> [String: Any] {
            scriptIncoming()

            guard let thread = threads[key] else { return [:] }

            var messages = thread.messages
            var hasOlder = false

            if let after {
                messages = messages.filter { ($0["id"] as? Int ?? 0) > after }
            } else if let before {
                messages = messages.filter { ($0["id"] as? Int ?? 0) < before }
            }

            if after == nil, messages.count > 50 {
                hasOlder = true
                messages = Array(messages.suffix(50))
            }

            let typing = thread.typingUntil.map { $0 > Date() } ?? false
            var response: [String: Any] = [
                "messages": messages,
                "has_older": hasOlder,
                "reactions_version": reactionsVersion,
                "reaction_changes": thread.reactionChanges.compactMap { id, _ in thread.messages.first { $0["id"] as? Int == id }.map { ["id": id, "reactions": $0["reactions"] ?? []] } },
                "read_through_id": thread.readThrough["you"] ?? 0,
                "is_archived": thread.archived,
                "pinned_at": nullable(thread.pinnedAt),
                "muted_until_at": nullable(thread.mutedUntil),
                "access": thread.access,
            ]

            if let partner = thread.partner {
                response["partner"] = user(partner)
                response["partner_read_through_id"] = thread.readThrough[partner] ?? 0
                response["partner_typing"] = typing
            } else {
                response["org"] = ["id": thread.orgId ?? "", "name": nullable(thread.name)]
                response["members"] = thread.members.map { ["user": user($0), "role": thread.roles[$0] ?? "contributor", "read_through_id": thread.readThrough[$0] ?? 0] }
                response["typing"] = typing ? [thread.typingUser ?? ""] : []
                response["role"] = thread.roles["you"] ?? "contributor"
            }

            return response
        }

        private func push(_ key: String, json: [String: Any], body: Data) -> [String: Any] {
            nextId += 1

            var extra: [String: Any] = ["client_id": json["client_id"] ?? NSNull()]

            if let reply = json["reply_to_id"] as? Int, let original = threads[key]?.messages.first(where: { $0["id"] as? Int == reply }) {
                extra["reply_to_id"] = reply
                extra["reply_to"] = ["id": reply, "user_id": original["user_id"] ?? "", "body": original["body"] ?? "", "images_count": (original["images"] as? [Any])?.count ?? 0, "has_voice": original["voice"] != nil]
            }

            if let descriptions = json["image_descriptions"] as? [String] {
                extra["images"] = descriptions.enumerated().map { index, description in image(nextId * 10 + index, 1200, 900, description) }
            }

            if let waveform = json["voice_waveform"] as? [Int] {
                extra["voice"] = ["id": "v-\(nextId)", "duration_ms": 4000, "waveform": waveform, "url": "https://\(Preview.host)/voice/\(nextId).wav"]
            }

            var sent = message(nextId, "you", (json["body"] as? String).flatMap { $0.isEmpty ? nil : $0 }, minutesAgo: 0, extra: extra)
            sent["user"] = currentUser()
            threads[key]?.messages.append(sent)
            threads[key]?.readThrough["you"] = nextId

            // Someone answers a little later, so incoming messages can be tried right after sending.
            if let thread = threads[key] {
                let replier = thread.partner ?? thread.members.first { $0 != "you" } ?? "maya"
                threads[key]?.typingUser = replier
                threads[key]?.typingUntil = Date().addingTimeInterval(3)
                pendingReplies.append((key, replier, Date().addingTimeInterval(3)))
            }

            return sent
        }

        private var pendingReplies: [(String, String, Date)] = []

        private static let replies = ["Nice!", "Ha, agreed 😄", "Let me check and get back to you.", "Sounds good to me.", "Can you send a screenshot?", "👍", "Ok, merging it now.", "That's exactly what I meant — thanks for writing it down so clearly, it'll help the others too."]

        /// Delivers the replies that are due, and every 40 seconds has someone write in the first DM, typing first.
        private func scriptIncoming() {
            let now = Date()

            for (index, reply) in pendingReplies.enumerated().reversed() where reply.2 <= now {
                pendingReplies.remove(at: index)
                deliver(reply.0, from: reply.1)
            }

            if now.timeIntervalSince(lastScriptAt) > 40, let key = order.first(where: { $0.hasPrefix("@") }) {
                lastScriptAt = now
                let partner = threads[key]?.partner ?? "maya"
                threads[key]?.typingUser = partner
                threads[key]?.typingUntil = now.addingTimeInterval(3)
                pendingReplies.append((key, partner, now.addingTimeInterval(3)))
            }
        }

        private func deliver(_ key: String, from handle: String) {
            nextId += 1
            threads[key]?.messages.append(message(nextId, handle, Self.replies.randomElement(), minutesAgo: 0))
            threads[key]?.typingUntil = nil

            // Whoever answers has read everything before.
            threads[key]?.readThrough[handle] = nextId
        }

        private func react(_ id: Int, emoji: String, remove: Bool) -> [[String: Any]] {
            for key in threads.keys {
                guard let index = threads[key]?.messages.firstIndex(where: { $0["id"] as? Int == id }) else { continue }

                var reactions = threads[key]?.messages[index]["reactions"] as? [[String: Any]] ?? []
                reactions.removeAll { $0["user_id"] as? String == "u-me" && $0["emoji"] as? String == emoji }

                if !remove {
                    reactions.append(["user_id": "u-me", "emoji": emoji])
                }

                threads[key]?.messages[index]["reactions"] = reactions
                reactionsVersion += 1
                threads[key]?.reactionChanges[id] = reactionsVersion

                return reactions
            }

            return []
        }

        /// The JSON part of a multipart request, which the app names "payload".
        private static func multipartPayload(_ body: Data, contentType: String) -> [String: Any] {
            guard contentType.contains("multipart"),
                  let start = body.range(of: Data("\r\n\r\n{".utf8)),
                  let end = body.range(of: Data("}\r\n--".utf8), in: start.upperBound ..< body.endIndex)
            else { return [:] }

            let json = body[(start.upperBound - 1) ..< (end.lowerBound + 1)]

            return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        }
    }

    /// Avatars and images drawn on the fly, so the preview needs no network.
    enum PreviewImages {
        private static let colors: [(NSColor, NSColor)] = [
            (NSColor(hex: 0x3B6FE0), NSColor(hex: 0x7AA2F7)), (NSColor(hex: 0x2F9E44), NSColor(hex: 0x8CE99A)),
            (NSColor(hex: 0x9C36B5), NSColor(hex: 0xE599F7)), (NSColor(hex: 0x0C8599), NSColor(hex: 0x66D9E8)),
            (NSColor(hex: 0xC2255C), NSColor(hex: 0xFAA2C1)), (NSColor(hex: 0xB7791F), NSColor(hex: 0xFFD43B)),
        ]

        static func avatar(_ handle: String) -> Data {
            let pair = colors[abs(handle.hashValue % colors.count)]
            let initial = String((PreviewStore.people[handle]?.name ?? handle).prefix(1))

            return draw(width: 160, height: 160, pair: pair) { rect in
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 72, weight: .semibold), .foregroundColor: NSColor.white]
                let size = initial.size(withAttributes: attributes)
                initial.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            }
        }

        static func image(seed: Int, width: Int, height: Int) -> Data {
            let scale = min(1, 900 / Double(max(width, height)))

            return draw(width: Int(Double(width) * scale), height: Int(Double(height) * scale), pair: colors[seed % colors.count]) { rect in
                NSColor.white.withAlphaComponent(0.25).setFill()
                for index in 0 ..< 6 {
                    let size = rect.width * (0.15 + 0.1 * Double(index % 3))
                    NSBezierPath(ovalIn: NSRect(x: rect.width * Double((seed + index * 37) % 100) / 100 - size / 2, y: rect.height * Double((seed * 7 + index * 53) % 100) / 100 - size / 2, width: size, height: size)).fill()
                }
            }
        }

        private static func draw(width: Int, height: Int, pair: (NSColor, NSColor), content: @escaping (NSRect) -> Void) -> Data {
            let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
                NSGradient(starting: pair.0, ending: pair.1)?.draw(in: rect, angle: 60)
                content(rect)
                return true
            }

            guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return Data() }

            return png
        }
    }
#endif
