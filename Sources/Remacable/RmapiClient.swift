import Foundation

/// Duenne Huelle um das rmapi-Binary (ddvk/rmapi), das die inoffizielle
/// reMarkable-Cloud-API spricht.
enum RmapiClient {

    static let connectURL = URL(string: "https://my.remarkable.com/device/desktop/connect")!
    private static let releaseAPI = URL(string: "https://api.github.com/repos/ddvk/rmapi/releases/latest")!

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Paths.rmapiBinary.path)
    }

    // MARK: Aufrufe

    @discardableResult
    static func run(_ arguments: [String], stdin: String = "", timeout: TimeInterval = 900) throws -> String {
        guard isInstalled else { throw RmapiError.notInstalled }
        return try ProcessRunner.run(
            Paths.rmapiBinary.path, arguments,
            environment: ["RMAPI_CONFIG": Paths.rmapiConfig.path],
            stdin: stdin, timeout: timeout)
    }

    static func version() -> String? {
        guard let output = try? run(["version"], timeout: 30) else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first
    }

    static func isPaired() -> Bool {
        (try? run(["ls", "/"], timeout: 60)) != nil
    }

    /// Koppelt das Konto mit dem 8-stelligen Einmalcode von `connectURL`.
    static func pair(code: String) throws {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw RmapiError.invalidCode }
        // rmapi fragt beim ersten Start nach dem Code und liest ihn von stdin.
        _ = try run(["ls", "/"], stdin: cleaned + "\n", timeout: 120)
    }

    static func unpair() {
        try? FileManager.default.removeItem(at: Paths.rmapiConfig)
    }

    // MARK: Ordner und Upload

    /// Legt den Zielordner Ebene fuer Ebene an; existiert er, meldet rmapi einen
    /// Fehler, den wir ignorieren.
    static func ensureFolder(_ folder: String) {
        var path = ""
        for part in folder.split(separator: "/") where !part.isEmpty {
            path += "/" + part
            _ = try? run(["mkdir", path], timeout: 60)
        }
    }

    /// Namen im Zielordner — damit lassen sich Kollisionen abfangen, bevor
    /// `put` daran scheitert.
    static func entries(in folder: String) -> Set<String> {
        guard let output = try? run(["ls", folder], timeout: 120) else { return [] }
        var names = Set<String>()
        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            let name = parts[parts.count - 1].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.insert(name) }
        }
        return names
    }

    static func put(file: URL, folder: String) throws {
        _ = try run(["put", file.path, folder], timeout: 1800)
    }

    // MARK: Versionen

    private static func fetchLatestRelease() async throws -> [String: Any] {
        var request = URLRequest(url: releaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RmapiError.download(String(localized: "GitHub did not respond as expected"))
        }
        return json
    }

    /// Neueste veroeffentlichte Version — nur die Nummer, ohne Download.
    static func latestVersion() async throws -> String {
        guard let tag = try await fetchLatestRelease()["tag_name"] as? String else {
            throw RmapiError.download(String(localized: "Release has no version number"))
        }
        return tag
    }

    /// Zieht "0.0.35" aus Angaben wie "v0.0.35" oder "rmapi version v0.0.35".
    static func versionNumber(_ raw: String?) -> String? {
        guard let raw,
              let range = raw.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
        return String(raw[range])
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let new = candidate.split(separator: ".").compactMap { Int($0) }
        let old = current.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: Installation

    /// Laedt das aktuelle Release von GitHub und legt das Binary bereit.
    static func install(progress: @escaping (String) -> Void) async throws -> String {
        progress(String(localized: "Looking for the latest release…"))
        let json = try await fetchLatestRelease()

        #if arch(arm64)
        let assetName = "rmapi-macos-arm64.zip"
        #else
        let assetName = "rmapi-macos-intel.zip"
        #endif

        guard let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
              let urlString = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: urlString) else {
            throw RmapiError.download(String(format: String(localized: "No matching package (%@) in the release"), assetName))
        }
        let tag = (json["tag_name"] as? String) ?? "?"

        progress(String(format: String(localized: "Downloading %@ (%@)…"), assetName, tag))
        let (tempFile, _) = try await URLSession.shared.download(from: downloadURL)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("send2rm-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let zipFile = workDir.appendingPathComponent(assetName)
        try FileManager.default.moveItem(at: tempFile, to: zipFile)

        progress(String(localized: "Extracting…"))
        _ = try ProcessRunner.run("/usr/bin/unzip", ["-o", "-j", "-q", zipFile.path, "-d", workDir.path],
                                  timeout: 120)

        guard let extracted = try FileManager.default
            .contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent == "rmapi" }) else {
            throw RmapiError.download(String(localized: "The archive contained no rmapi binary"))
        }

        let binDir = Paths.rmapiBinary.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: Paths.rmapiBinary)
        try FileManager.default.moveItem(at: extracted, to: Paths.rmapiBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: Paths.rmapiBinary.path)
        // Quarantaene entfernen, sonst verweigert Gatekeeper den Start
        _ = try? ProcessRunner.run("/usr/bin/xattr",
                                   ["-dr", "com.apple.quarantine", Paths.rmapiBinary.path],
                                   timeout: 30)

        let installed = version() ?? tag
        progress(String(format: String(localized: "Installed: %@"), installed))
        return installed
    }
}

enum RmapiError: LocalizedError {
    case notInstalled
    case notPaired
    case invalidCode
    case download(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return String(localized: "rmapi is not installed yet.")
        case .notPaired: return String(localized: "The account is not paired yet.")
        case .invalidCode: return String(localized: "Please enter the 8-character code.")
        case .download(let message): return message
        }
    }
}
