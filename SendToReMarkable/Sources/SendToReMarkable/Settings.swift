import Foundation

// MARK: - Modell

struct RenameRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var match: String = ""
    var title: String = ""
}

struct WatchSource: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var targetFolder: String = "/Inbox"
    /// Neue Ordner starten bewusst inaktiv: erst konfigurieren, dann einschalten.
    var enabled: Bool = false
    /// true: Datei wandert nach dem Upload nach Uploaded/ — false: sie bleibt liegen.
    var move: Bool = true
    var subfolders: Bool = true
    var patterns: [String] = ["*"]
    var maxAgeDays: Double = 0
    var stableWait: Double = 2
    var renameRules: [RenameRule] = []

    var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
    var displayName: String { url.lastPathComponent }

    var patternText: String {
        get { patterns.joined(separator: ", ") }
        set {
            let parts = newValue.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            patterns = parts.isEmpty ? ["*"] : parts
        }
    }

    static func inbox() -> WatchSource {
        WatchSource(path: Paths.defaultInbox.path, targetFolder: "/Inbox", enabled: true)
    }
}

struct AppSettings: Codable {
    var sources: [WatchSource] = [.inbox()]
    var watchingEnabled: Bool = true
    var keepUploaded: Bool = true
    var cleanupUploadedDays: Double = 30
    var notify: Bool = true
    var maxMB: Double = 200
    var launchAtLogin: Bool = false
    var sofficePath: String = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
    var ebookConvertPath: String = "/Applications/calibre.app/Contents/MacOS/ebook-convert"
    var defaultTargetFolder: String = "/Inbox"
}

// MARK: - Speicher

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: AppSettings {
        didSet { scheduleSave() }
    }

    private var saveWorkItem: DispatchWorkItem?

    private init() {
        if let data = try? Data(contentsOf: Paths.settingsFile),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
        ensureInboxExists()
    }

    func ensureInboxExists() {
        for source in settings.sources where source.move {
            try? FileManager.default.createDirectory(
                at: source.url.appendingPathComponent("Uploaded"), withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(
                at: source.url.appendingPathComponent("Failed"), withIntermediateDirectories: true)
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = settings
        let item = DispatchWorkItem { SettingsStore.write(snapshot) }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    func saveNow() { SettingsStore.write(settings) }

    private nonisolated static func write(_ settings: AppSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        let tmp = Paths.settingsFile.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(Paths.settingsFile, withItemAt: tmp)
        } catch {
            try? data.write(to: Paths.settingsFile)
        }
    }
}
