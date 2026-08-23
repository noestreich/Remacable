import AppKit
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

/// Sprache der Oberflaeche. „System“ folgt der Systemeinstellung.
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system, english, german

    var id: String { rawValue }

    /// Sprachcode fuer AppleLanguages — nil heisst: nicht eingreifen.
    var code: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .german: return "de"
        }
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

    /// Von Hand geschrieben, damit eine aeltere settings.json ohne die neueren
    /// Felder weiter geladen wird. Der erzeugte Decoder wuerde bei einem
    /// fehlenden Schluessel werfen — und die eingerichteten Ordner waeren weg.
    /// Nach einem Vorschlag von jimmystridh (PR #1).
    init(from decoder: Decoder) throws {
        let fallback = AppSettings()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sources = try values.decodeIfPresent([WatchSource].self, forKey: .sources) ?? fallback.sources
        watchingEnabled = try values.decodeIfPresent(Bool.self, forKey: .watchingEnabled) ?? fallback.watchingEnabled
        keepUploaded = try values.decodeIfPresent(Bool.self, forKey: .keepUploaded) ?? fallback.keepUploaded
        cleanupUploadedDays = try values.decodeIfPresent(Double.self, forKey: .cleanupUploadedDays) ?? fallback.cleanupUploadedDays
        notify = try values.decodeIfPresent(Bool.self, forKey: .notify) ?? fallback.notify
        maxMB = try values.decodeIfPresent(Double.self, forKey: .maxMB) ?? fallback.maxMB
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? fallback.launchAtLogin
        sofficePath = try values.decodeIfPresent(String.self, forKey: .sofficePath) ?? fallback.sofficePath
        ebookConvertPath = try values.decodeIfPresent(String.self, forKey: .ebookConvertPath) ?? fallback.ebookConvertPath
        defaultTargetFolder = try values.decodeIfPresent(String.self, forKey: .defaultTargetFolder) ?? fallback.defaultTargetFolder
        language = try values.decodeIfPresent(AppLanguage.self, forKey: .language) ?? fallback.language
    }
}

/// Setzt die Sprache fuer den naechsten Start. macOS liest AppleLanguages beim
/// Programmstart, ein Wechsel wirkt daher erst nach einem Neustart der App.
enum LanguageOverride {
    static func apply(_ language: AppLanguage) {
        if let code = language.code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    static func restartApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
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
