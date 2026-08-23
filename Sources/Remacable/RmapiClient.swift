import Foundation

/// Duenne Huelle um das rmapi-Binary (ddvk/rmapi), das die inoffizielle
/// reMarkable-Cloud-API spricht.
enum RmapiClient {

    typealias CommandRunner = (_ arguments: [String], _ timeout: TimeInterval) throws -> String
    typealias RetryWaiter = (_ delay: TimeInterval) -> Void

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

    /// Legt den Zielordner Ebene fuer Ebene an und wartet, bis ein neuer Ordner
    /// in einem frisch aufgebauten rmapi-Dateibaum sichtbar ist.
    @discardableResult
    static func ensureFolder(_ folder: String) throws -> String {
        try ensureFolder(
            folder,
            command: { arguments, timeout in try run(arguments, timeout: timeout) },
            wait: { Thread.sleep(forTimeInterval: $0) })
    }

    @discardableResult
    static func ensureFolder(_ folder: String,
                             command: CommandRunner,
                             wait: RetryWaiter) throws -> String {
        let parts = folder.split(separator: "/").filter { !$0.isEmpty }
        guard !parts.isEmpty else { return try command(["ls", "/"], 120) }

        var path = ""
        var listing = ""
        for part in parts {
            path += "/" + part

            if let existing = try? command(["ls", path], 120) {
                listing = existing
                continue
            }

            var lastError: Error?
            do {
                _ = try command(["mkdir", path], 60)
            } catch {
                lastError = error
            }

            var visible = false
            for attempt in 0..<4 {
                do {
                    listing = try command(["ls", path], 120)
                    visible = true
                    break
                } catch {
                    lastError = error
                    if attempt < 3 { wait(0.25 * pow(2, Double(attempt))) }
                }
            }
            if !visible, let lastError { throw lastError }
        }
        return listing
    }

    /// Namen im Zielordner — damit lassen sich Kollisionen abfangen, bevor
    /// `put` daran scheitert.
    static func entries(in folder: String) throws -> Set<String> {
        let output = try ensureFolder(folder)
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
        try put(
            file: file,
            folder: folder,
            command: { arguments, timeout in try run(arguments, timeout: timeout) },
            wait: { Thread.sleep(forTimeInterval: $0) })
    }

    static func put(file: URL,
                    folder: String,
                    command: CommandRunner,
                    wait: RetryWaiter) throws {
        do {
            _ = try command(["put", file.path, folder], 1800)
        } catch {
            guard isMissingDirectory(error) else { throw error }
            _ = try ensureFolder(folder, command: command, wait: wait)
            _ = try command(["put", file.path, folder], 1800)
        }
    }

    static func isMissingDirectory(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("directory doesn't exist")
            || message.contains("directory does not exist")
    }

    // MARK: Versionen

    private static func fetchLatestRelease() async throws -> [String: Any] {
        var request = URLRequest(url: releaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RmapiError.download("GitHub antwortet nicht wie erwartet")
        }
        return json
    }

    /// Neueste veroeffentlichte Version — nur die Nummer, ohne Download.
    static func latestVersion() async throws -> String {
        guard let tag = try await fetchLatestRelease()["tag_name"] as? String else {
            throw RmapiError.download("Release ohne Versionsangabe")
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
        progress("Suche aktuelles Release …")
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
