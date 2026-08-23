import Foundation

// MARK: - Pfade

enum Paths {
    static let appSupport: URL = {
        let manager = FileManager.default
        let library = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = library.appendingPathComponent("Remacable", isDirectory: true)
        // Die App hiess frueher SendToReMarkable — Einstellungen, Merkzettel und
        // das rmapi-Binary wandern beim ersten Start mit um.
        let legacy = library.appendingPathComponent("SendToReMarkable", isDirectory: true)
        if !manager.fileExists(atPath: base.path), manager.fileExists(atPath: legacy.path) {
            try? manager.moveItem(at: legacy, to: base)
        }
        try? manager.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }
    static var stateFile: URL { appSupport.appendingPathComponent("seen.json") }
    static var rmapiBinary: URL { appSupport.appendingPathComponent("bin/rmapi") }

    /// Gleiche Datei wie beim CLI-Werkzeug — einmal koppeln reicht fuer beides.
    static var rmapiConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rmapi")
    }

    static var logFile: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return dir.appendingPathComponent("Remacable.log")
    }

    static var defaultInbox: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("reMarkable Inbox")
    }

    /// Der launchd-Agent der Skript-Fassung — laeuft der noch, wuerde alles doppelt hochgehen.
    static var legacyAgent: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.send2rm.watch.plist")
    }
}

// MARK: - Protokoll

struct LogEntry: Identifiable, Hashable {
    enum Level: String { case info, success, error }
    let id = UUID()
    let date: Date
    let level: Level
    let message: String
}

/// Schreibt ins Logfile und haelt die letzten Zeilen fuer die Oberflaeche vor.
/// Bewusst nicht an den Main-Actor gebunden: die Upload-Queue protokolliert aus
/// dem Hintergrund, nur die Liste fuer die Oberflaeche wird auf main gepflegt.
final class Log: ObservableObject, @unchecked Sendable {
    static let shared = Log()

    @Published private(set) var entries: [LogEntry] = []
    private let fileQueue = DispatchQueue(label: "de.send2rm.log")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private init() {}

    func info(_ message: String) { append(.info, message) }
    func success(_ message: String) { append(.success, message) }
    func error(_ message: String) { append(.error, message) }

    private func append(_ level: LogEntry.Level, _ message: String) {
        let entry = LogEntry(date: Date(), level: level, message: message)
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > 500 { self.entries.removeFirst(self.entries.count - 500) }
        }
        fileQueue.async { self.writeToFile(entry) }
    }

    private func writeToFile(_ entry: LogEntry) {
        let line = "\(formatter.string(from: entry.date)) \(entry.level.rawValue.uppercased())\t\(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = Paths.logFile
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
}

// MARK: - Prozesse

enum ProcessError: LocalizedError {
    case launchFailed(String)
    case failed(command: String, status: Int32, output: String)
    case timedOut(command: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let msg): return msg
        case .failed(_, _, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? tr("error.process.failed") : String(trimmed.prefix(400))
        case .timedOut(let command): return tr("error.process.timeout", command)
        }
    }
}

enum ProcessRunner {
    @discardableResult
    static func run(_ executable: String,
                    _ arguments: [String],
                    environment: [String: String]? = nil,
                    stdin: String? = nil,
                    timeout: TimeInterval = 900) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            var env = ProcessInfo.processInfo.environment
            environment.forEach { env[$0.key] = $0.value }
            process.environment = env
        }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = Pipe()
        if stdin != nil { process.standardInput = inPipe }

        do { try process.run() } catch {
            throw ProcessError.launchFailed("\(executable): \(error.localizedDescription)")
        }

        if let stdin, let data = stdin.data(using: .utf8) {
            try? inPipe.fileHandleForWriting.write(contentsOf: data)
            try? inPipe.fileHandleForWriting.close()
        }

        // Parallel lesen, sonst blockiert ein volles Pipe-Puffer den Prozess
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "process.io", attributes: .concurrent)
        queue.async(group: group) { outData = outPipe.fileHandleForReading.readDataToEndOfFile() }
        queue.async(group: group) { errData = errPipe.fileHandleForReading.readDataToEndOfFile() }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw ProcessError.timedOut(command: (executable as NSString).lastPathComponent)
        }
        _ = group.wait(timeout: .now() + 10)

        let output = String(decoding: outData, as: UTF8.self)
        let errorOutput = String(decoding: errData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ProcessError.failed(
                command: (executable as NSString).lastPathComponent,
                status: process.terminationStatus,
                output: errorOutput.isEmpty ? output : errorOutput)
        }
        return output
    }
}

// MARK: - Benachrichtigungen

enum Notifier {
    static func send(title: String, body: String) {
        // osascript statt UserNotifications: funktioniert auch bei einer lokal
        // gebauten, nur ad-hoc signierten App ohne Notification-Berechtigung.
        let escape: (String) -> String = { $0.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "display notification \"\(escape(body))\" with title \"\(escape(title))\""
        DispatchQueue.global(qos: .utility).async {
            _ = try? ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 20)
        }
    }
}
