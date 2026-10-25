import AppKit
import Foundation
import Observation

/// Whether dev-null.sh publishes a newer Mac app than this one, by build number. It asks the public
/// GET /api/v1/apps/mac, the same release the /apps page shows: unsigned, without cookies or a cache, and with nothing
/// about the user or this Mac in the request. The answer lives in memory only.
@MainActor
@Observable
final class Updates {
    struct Release: Decodable, Equatable {
        let version: String
        let build: Int
        /// The /apps page, where the DMG and the install steps are.
        let url: URL
    }

    enum Status: Equatable {
        case unknown
        case checking
        case current
        case available(Release)
        case failed
    }

    static let shared = Updates()

    nonisolated static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    nonisolated static let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    /// The commit the build was made from, stamped by build.sh.
    nonisolated static let revision = Bundle.main.object(forInfoDictionaryKey: "DevNullRevision") as? String

    private(set) var status: Status = .unknown
    private var checkedAt: Date?

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

    /// Checks a minute after launch, then once a day while the app runs. It never alerts: a newer build only shows in
    /// the app menu and the About window.
    func start() {
        Task {
            try? await Task.sleep(for: .seconds(60))

            while !Task.isCancelled {
                await check(unlessCheckedWithin: 60 * 60)
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    /// "Check for Updates…": opens the download page when there's a newer build, and says so in the About window
    /// when there isn't, or when dev-null.sh can't be reached.
    func checkFromMenu() {
        if let available {
            NSWorkspace.shared.open(available.url)
            return
        }

        AboutWindow.show()

        Task {
            await check(unlessCheckedWithin: 10)

            if let available {
                NSWorkspace.shared.open(available.url)
            }
        }
    }

    func check(unlessCheckedWithin interval: TimeInterval) async {
        guard status != .checking else { return }

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
}
