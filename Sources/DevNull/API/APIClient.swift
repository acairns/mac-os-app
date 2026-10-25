import CryptoKit
import Foundation

/// An error the API answered with, in its own words, or a failure to reach it.
struct APIError: LocalizedError {
    let status: Int
    let code: String?
    let message: String

    var errorDescription: String? { message }

    /// The device was revoked on the web, or the key was never approved: the user has to sign in again.
    var requiresSignIn: Bool {
        code == "device_not_approved" || code == "invalid_signature" && status == 401
    }
}

/// A file sent beside the JSON payload of a multipart request.
struct Upload {
    let data: Data
    let filename: String
    let mimeType: String
}

/// Sends requests to /api/v1, each signed with the device key as SignedRequests on the server expects:
/// "<timestamp>\n<nonce>\n<METHOD>\n<path and query>\n<body>", or with one more line of SHA-256 hashes before the body
/// when files ride along as multipart.
final class APIClient: @unchecked Sendable {
    static let baseURL: URL = {
        #if DEBUG
            if Preview.isEnabled { return URL(string: "https://\(Preview.host)")! }
        #endif

        return URL(string: ProcessInfo.processInfo.environment["DEVNULL_URL"] ?? "https://dev-null.sh")!
    }()

    private let key: DeviceKey
    private let session: URLSession
    private let budget = RequestBudget()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)

            guard let date = parseDate(string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown date \(string)"))
            }

            return date
        }

        return decoder
    }()

    /// Laravel sends "…Z" (toIso8601ZuluString) or "….000000Z" (toJSON). The fraction is dropped either way.
    static func parseDate(_ string: String) -> Date? {
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)

        return try? Date(trimmed, strategy: .iso8601)
    }

    init(key: DeviceKey) {
        self.key = key

        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": "DevNull-Mac/1.0"]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Responses carry message bodies, which must never land in ~/Library/Caches.
        configuration.urlCache = nil
        #if DEBUG
            if Preview.isEnabled { configuration.protocolClasses = [PreviewServer.self] }
        #endif
        session = URLSession(configuration: configuration)
    }

    // MARK: - Requests

    func get<T: Decodable>(_ path: String, query: [String: String?] = [:], as type: T.Type = T.self) async throws -> T {
        try await decode(send("GET", path, query: query, json: nil))
    }

    @discardableResult
    func send<T: Decodable>(_ method: String, _ path: String, json: [String: Any]?, as type: T.Type = T.self) async throws -> T {
        try await decode(send(method, path, query: [:], json: json))
    }

    func perform(_ method: String, _ path: String, json: [String: Any]? = nil) async throws {
        _ = try await send(method, path, query: [:], json: json)
    }

    /// A multipart request: the JSON as the `payload` part, the files under `field`, signed with their hashes.
    func sendMultipart<T: Decodable>(_ method: String, _ path: String, json: [String: Any], field: String, files: [Upload], as type: T.Type = T.self) async throws -> T {
        let payload = try JSONSerialization.data(withJSONObject: json)
        let hashes = files.map { Data(SHA256.hash(data: $0.data)).hexString }.joined(separator: ",")
        let boundary = "devnull-" + UUID().uuidString

        var body = Data()
        body.appendPart(boundary: boundary, name: "payload", filename: "payload.json", mimeType: "application/json", data: payload)

        for file in files {
            body.appendPart(boundary: boundary, name: files.count > 1 || field == "images" ? "\(field)[]" : field, filename: file.filename, mimeType: file.mimeType, data: file.data)
        }

        body.append(Data("--\(boundary)--\r\n".utf8))

        let target = Self.target(path, query: [:])
        var signed = Data(hashes.utf8)
        signed.append(Data("\n".utf8))
        signed.append(payload)

        var request = try signedRequest(method, target: target, body: signed, namespace: "devnull-api-images")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        return try await decode(execute(request))
    }

    /// Redeems the code the web handed back for this key, which isn't approved yet, so the answer is the signed-in user.
    func redeem(code: String, verifier: String) async throws -> CurrentUser {
        let response: DataEnvelope<CurrentUser> = try await send("POST", "devices", json: ["code": code, "code_verifier": verifier])

        return response.data
    }

    // MARK: - Plumbing

    private func send(_ method: String, _ path: String, query: [String: String?], json: [String: Any]?) async throws -> Data {
        let target = Self.target(path, query: query)
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()

        var request = try signedRequest(method, target: target, body: body, namespace: "devnull-api")

        if json != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        return try await execute(request)
    }

    /// The exact path and query the server reads back with getRequestUri(), so both sides sign the same bytes.
    static func target(_ path: String, query: [String: String?]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")

        let pairs = query
            .compactMapValues { $0 }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }

        let encodedPath = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String($0) }
            .joined(separator: "/")

        return "/api/v1/" + encodedPath + (pairs.isEmpty ? "" : "?" + pairs.joined(separator: "&"))
    }

    private func signedRequest(_ method: String, target: String, body: Data, namespace: String) throws -> URLRequest {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) }).hexString

        var message = Data([timestamp, nonce, method, target].joined(separator: "\n").utf8)
        message.append(Data("\n".utf8))
        message.append(body)

        var request = URLRequest(url: URL(string: target, relativeTo: Self.baseURL)!.absoluteURL)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(timestamp, forHTTPHeaderField: "X-Devnull-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Devnull-Nonce")
        request.setValue(try key.sign(message, namespace: namespace), forHTTPHeaderField: "X-SSH-Signature")

        return request
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        await budget.take()

        let (data, response): (Data, URLResponse)

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError(status: 0, code: nil, message: "Couldn't reach /dev/null. Check your connection.")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200 ..< 300).contains(status) else {
            throw Self.error(status: status, data: data)
        }

        return data
    }

    private static func error(status: Int, data: Data) -> APIError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let errors = json?["errors"] as? [String: [String]]
        let message = errors?.values.first?.first
            ?? json?["message"] as? String
            ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized

        return APIError(status: status, code: json?["code"] as? String, message: message.isEmpty ? "Something went wrong." : message)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        if T.self == Empty.self {
            return Empty() as! T
        }

        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            #if DEBUG
                NSLog("Decoding %@ failed: %@", String(describing: T.self), String(describing: error))
            #endif
            throw APIError(status: 200, code: nil, message: "/dev/null answered in a way this version of the app doesn't understand. Check for an update.")
        }
    }
}

struct Empty: Decodable {}

/// Keeps the app under the API's 120 signed requests a minute: past 110 in the last minute, the next request waits
/// for the oldest to age out instead of being refused.
actor RequestBudget {
    private let limit = 110
    private var sent: [Date] = []

    func take() async {
        while true {
            let now = Date()
            sent.removeAll { now.timeIntervalSince($0) >= 60 }

            if sent.count < limit {
                sent.append(now)
                return
            }

            try? await Task.sleep(for: .seconds(60 - now.timeIntervalSince(sent[0]) + 0.05))
        }
    }
}

struct DataEnvelope<T: Decodable>: Decodable {
    let data: T
}

private extension Data {
    mutating func appendPart(boundary: String, name: String, filename: String, mimeType: String, data: Data) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        append(data)
        append(Data("\r\n".utf8))
    }
}
