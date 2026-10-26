import AppKit
import CryptoKit
import Foundation
import Observation
import Security

/// Whether dev-null.sh publishes a newer Mac app than this one, by build number, and installing it. It asks the public
/// GET /api/v1/apps/mac, the same release the /apps page shows: unsigned, without cookies or a cache, and with nothing
/// about the user or this Mac in the request. The answer lives in memory only.
///
/// Updating downloads the release's DMG, checks it against the release's SHA-256, and only installs the app inside when
/// it is signed by the same developer as this one, then swaps it in place and relaunches. When it can't, like a build
/// signed ad hoc, a copy run from the DMG, or an /Applications the user can't write to, the download page opens instead.
@MainActor
@Observable
final class Updates {
    struct Release: Decodable, Equatable {
        let version: String
        let build: Int
        /// The /apps page, where the DMG and the install steps are.
        let url: URL
        let downloadUrl: URL?
        let sha256: String?
    }

    enum Status: Equatable {
        case unknown
        case checking
        case current
        case available(Release)
        case installing(Release)
        case failed
    }

    static let shared = Updates()

    nonisolated static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    nonisolated static let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    /// The commit the build was made from, stamped by build.sh.
    nonisolated static let revision = Bundle.main.object(forInfoDictionaryKey: "DevNullRevision") as? String

    private(set) var status: Status = .unknown
    private var checkedAt: Date?
    private var hasSuggested = false

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": "DevNull-Mac"]
        #if DEBUG
            if Preview.isEnabled { configuration.protocolClasses = [PreviewServer.self] }
        #endif

        return URLSession(configuration: configuration)
    }()

    var available: Release? {
        if case let .available(release) = status { release } else { nil }
    }

    var isInstalling: Bool {
        if case .installing = status { true } else { false }
    }

    /// Checks as the app opens, offering a newer build once per launch, then once a day while it runs, which only
    /// updates the app menu and the About window.
    func start() {
        Task {
            while !Task.isCancelled {
                await check(unlessCheckedWithin: 60 * 60)

                if let available, !hasSuggested {
                    hasSuggested = true
                    suggest(available)
                }

                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    /// "Check for Updates…": updates when there's a newer build, and says so in the About window when there isn't, or
    /// when dev-null.sh can't be reached.
    func checkFromMenu() {
        if let available {
            update(to: available)
            return
        }

        AboutWindow.show()

        Task {
            await check(unlessCheckedWithin: 10)

            if let available {
                suggest(available)
            }
        }
    }

    func check(unlessCheckedWithin interval: TimeInterval) async {
        guard status != .checking, !isInstalling else { return }

        if let checkedAt, status != .failed, Date().timeIntervalSince(checkedAt) < interval {
            return
        }

        status = .checking

        do {
            let (data, response) = try await session.data(from: APIClient.baseURL.appending(path: "api/v1/apps/mac"))

            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }

            let release = try APIClient.decoder.decode(DataEnvelope<Release?>.self, from: data).data

            status = release.map { $0.build > Self.build ? .available($0) : .current } ?? .current
            checkedAt = Date()
        } catch {
            status = .failed
        }
    }

    private func suggest(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "/dev/null \(release.version) is available"
        alert.informativeText = "Build \(release.build) is ready, and you have build \(Self.build). /dev/null reopens when it's done."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            update(to: release)
        }
    }

    func update(to release: Release) {
        let target = Bundle.main.bundleURL

        guard !isInstalling else { return }

        guard let downloadUrl = release.downloadUrl, let sha256 = release.sha256, target.pathExtension == "app",
              !target.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path)
        else {
            NSWorkspace.shared.open(release.url)
            return
        }

        status = .installing(release)

        Task {
            do {
                let (download, response) = try await session.download(from: downloadUrl)

                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }

                try await Task.detached { try Self.install(download, sha256: sha256, over: target) }.value
                Self.relaunch(target)
            } catch {
                status = .available(release)

                let alert = NSAlert()
                alert.messageText = "Couldn't update /dev/null"
                alert.informativeText = "\(error.localizedDescription) You can download it from dev-null.sh instead."
                alert.addButton(withTitle: "Open Download Page")
                alert.addButton(withTitle: "Cancel")

                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(release.url)
                }
            }
        }
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
    }

    /// Checks the DMG, copies the app out of it, checks its signature, and swaps it for this one. Work happens beside
    /// the app, on its volume, so the swap is a rename.
    nonisolated private static func install(_ download: URL, sha256: String, over target: URL) throws {
        let files = FileManager.default
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? files.removeItem(at: work) }

        let dmg = work.appending(path: "DevNull.dmg")
        try files.moveItem(at: download, to: dmg)

        let digest = SHA256.hash(data: try Data(contentsOf: dmg, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256.lowercased() else {
            throw UpdateError(errorDescription: "The download doesn't match the release.")
        }

        let volume = work.appending(path: "volume")
        try run("/usr/bin/hdiutil", "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", volume.path)
        defer { try? run("/usr/bin/hdiutil", "detach", volume.path, "-force") }

        let app = work.appending(path: "DevNull.app")
        try run("/usr/bin/ditto", volume.appending(path: "DevNull.app").path, app.path)

        guard isSignedLikeThisApp(app) else {
            throw UpdateError(errorDescription: "The new version isn't signed by the developer of this one.")
        }

        _ = try files.replaceItemAt(target, withItemAt: app)
    }

    /// Whether the app meets this one's designated requirement: for a Developer ID build, its bundle identifier and team.
    nonisolated private static func isSignedLikeThisApp(_ app: URL) -> Bool {
        var running: SecCode?
        var current: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?

        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &current) == errSecSuccess, let current,
              SecCodeCopyDesignatedRequirement(current, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate
        else { return false }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)

        return SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess
    }

    nonisolated private static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError(errorDescription: "The update couldn't be installed.")
        }
    }

    /// Opens the new version once this one has quit.
    private static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? process.run()

        NSApp.terminate(nil)
    }
}
