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
    /// Standard ist false, damit fremde Archive unangetastet bleiben; nur der
    /// mitgelieferte Haupt-Watch-Ordner legt Uploaded/ und Failed/ an.
    var move: Bool = false
    var subfolders: Bool = true
    var patterns: [String] = ["*"]
    var maxAgeDays: Double = 0
    var stableWait: Double = 2
    var renameRules: [RenameRule] = []

    var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

    /// Aendert sich das, muss die Vorschau neu gezaehlt werden.
    var filterKey: String {
        "\(path)|\(patterns.joined(separator: ","))|\(maxAgeDays)|\(subfolders)|\(move)"
    }
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
        WatchSource(path: Paths.defaultInbox.path, targetFolder: "/Inbox",
                    enabled: true, move: true)
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
    var language: AppLanguage = .system

    init() {}

    init(from decoder: Decoder) throws {
        let defaults = AppSettings()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sources = try values.decodeIfPresent([WatchSource].self, forKey: .sources) ?? defaults.sources
        watchingEnabled = try values.decodeIfPresent(Bool.self, forKey: .watchingEnabled)
            ?? defaults.watchingEnabled
        keepUploaded = try values.decodeIfPresent(Bool.self, forKey: .keepUploaded)
            ?? defaults.keepUploaded
        cleanupUploadedDays = try values.decodeIfPresent(Double.self, forKey: .cleanupUploadedDays)
            ?? defaults.cleanupUploadedDays
        notify = try values.decodeIfPresent(Bool.self, forKey: .notify) ?? defaults.notify
        maxMB = try values.decodeIfPresent(Double.self, forKey: .maxMB) ?? defaults.maxMB
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
            ?? defaults.launchAtLogin
        sofficePath = try values.decodeIfPresent(String.self, forKey: .sofficePath)
            ?? defaults.sofficePath
        ebookConvertPath = try values.decodeIfPresent(String.self, forKey: .ebookConvertPath)
            ?? defaults.ebookConvertPath
        defaultTargetFolder = try values.decodeIfPresent(String.self, forKey: .defaultTargetFolder)
            ?? defaults.defaultTargetFolder
        language = try values.decodeIfPresent(AppLanguage.self, forKey: .language) ?? defaults.language
    }
}

// MARK: - Speicher

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: AppSettings {
        didSet {
            Localization.use(settings.language)
            scheduleSave()
        }
    }

    private var saveWorkItem: DispatchWorkItem?

    private init() {
        if let data = try? Data(contentsOf: Paths.settingsFile),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
        Localization.use(settings.language)
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
