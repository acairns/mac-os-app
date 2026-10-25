import CryptoKit
@testable import DevNull
import Foundation
import Testing

@Suite struct DeviceKeyTests {
    let key = DeviceKey(privateKey: Curve25519.Signing.PrivateKey())

    @Test func fingerprintHasTheFormatTheAuthorizePageValidates() {
        #expect(key.fingerprint.wholeMatch(of: #/SHA256:[A-Za-z0-9+\/]{43}/#) != nil)
    }

    @Test func fingerprintMatchesSshKeygen() throws {
        let directory = try temporaryDirectory()
        let publicKey = directory.appending(path: "key.pub")
        try "ssh-ed25519 \(key.publicKeyBlob.base64EncodedString())\n".write(to: publicKey, atomically: true, encoding: .utf8)

        let output = try run("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", publicKey.path()])

        #expect(output.contains(key.fingerprint))
    }

    /// The signature verifies with OpenSSH itself, which is the format the server's SshSignature parses.
    @Test(arguments: ["devnull-api", "devnull-api-images"])
    func signatureVerifiesWithSshKeygen(namespace: String) throws {
        let directory = try temporaryDirectory()
        let message = Data("1730000000\n0123456789abcdef0123456789abcdef\nPOST\n/api/v1/remotes/@nunomaduro/messages\n{\"body\":\"hi\"}".utf8)
        let signature = try key.sign(message, namespace: namespace)

        let signatureFile = directory.appending(path: "message.sig")
        let armored = "-----BEGIN SSH SIGNATURE-----\n" + signature.chunked(70).joined(separator: "\n") + "\n-----END SSH SIGNATURE-----\n"
        try armored.write(to: signatureFile, atomically: true, encoding: .utf8)

        let messageFile = directory.appending(path: "message")
        try message.write(to: messageFile)

        let output = try run("/bin/sh", ["-c", "/usr/bin/ssh-keygen -Y check-novalidate -n \(namespace) -s '\(signatureFile.path())' < '\(messageFile.path())'"])

        #expect(output.contains("Good \"\(namespace)\" signature"))
    }

    @Test func targetKeepsPathAndSortedEncodedQuery() {
        #expect(APIClient.target("remotes/@nuno/messages", query: ["reactions_after": "3", "after": "10"]) == "/api/v1/remotes/@nuno/messages?after=10&reactions_after=3")
        #expect(APIClient.target("remotes", query: ["q": "a b&c", "tab": nil]) == "/api/v1/remotes?q=a%20b%26c")
    }

    @Test func parsesLaravelDates() {
        #expect(APIClient.parseDate("2026-10-24T10:11:12Z") != nil)
        #expect(APIClient.parseDate("2026-10-24T10:11:12.000000Z") == APIClient.parseDate("2026-10-24T10:11:12Z"))
    }

    @Test func voiceNotesAreSixteenKilohertzMonoWav() {
        let samples = (0 ..< 16000).map { Int16(truncatingIfNeeded: $0 % 2000 - 1000) }
        let wav = VoiceRecorder.wav(samples)
        let waveform = VoiceRecorder.waveform(samples)

        #expect(wav.count == 44 + samples.count * 2)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(waveform.count == 48)
        #expect(waveform.allSatisfy { (0 ... 100).contains($0) })
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

private extension String {
    func chunked(_ size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map {
            let start = index(startIndex, offsetBy: $0)
            return String(self[start ..< (index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex)])
        }
    }
}
