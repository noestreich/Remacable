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

    // MARK: Installation

    /// Laedt das aktuelle Release von GitHub und legt das Binary bereit.
    static func install(progress: @escaping (String) -> Void) async throws -> String {
        progress("Suche aktuelles Release …")
        var request = URLRequest(url: releaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RmapiError.download("GitHub antwortet nicht wie erwartet")
        }

        #if arch(arm64)
        let assetName = "rmapi-macos-arm64.zip"
        #else
        let assetName = "rmapi-macos-intel.zip"
        #endif

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
              let urlString = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: urlString) else {
            throw RmapiError.download("Kein passendes Paket (\(assetName)) im Release gefunden")
        }
        let tag = (json["tag_name"] as? String) ?? "?"

        progress("Lade \(assetName) (\(tag)) …")
        let (tempFile, _) = try await URLSession.shared.download(from: downloadURL)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("send2rm-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let zipFile = workDir.appendingPathComponent(assetName)
        try FileManager.default.moveItem(at: tempFile, to: zipFile)

        progress("Entpacke …")
        _ = try ProcessRunner.run("/usr/bin/unzip", ["-o", "-j", "-q", zipFile.path, "-d", workDir.path],
                                  timeout: 120)

        guard let extracted = try FileManager.default
            .contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent == "rmapi" }) else {
            throw RmapiError.download("Im Archiv war kein rmapi-Binary")
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
        progress("Installiert: \(installed)")
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
        case .notInstalled: return "rmapi ist noch nicht installiert."
        case .notPaired: return "Das Konto ist noch nicht gekoppelt."
        case .invalidCode: return "Bitte den 8-stelligen Code eingeben."
        case .download(let message): return message
        }
    }
}
