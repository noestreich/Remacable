import Foundation
import ServiceManagement

// MARK: - Ordnerueberwachung

/// Duenne Huelle um FSEvents. Meldet Aenderungen gebuendelt, damit ein
/// Kopiervorgang nicht hundert Scans ausloest.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "de.send2rm.fsevents")
    private var debounce: DispatchWorkItem?
    private let onChange: () -> Void
    private(set) var watchedPaths: [String] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit { stopStream() }

    func watch(paths: [String]) {
        let unique = Array(Set(paths)).sorted()
        guard unique != watchedPaths else { return }
        stopStream()
        watchedPaths = unique
        guard !unique.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagIgnoreSelf)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().trigger()
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, unique as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else {
            Log.shared.error("Ordnerüberwachung ließ sich nicht starten")
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        stopStream()
        watchedPaths = []
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func trigger() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = item
        queue.asyncAfter(deadline: .now() + 1.5, execute: item)
    }
}

// MARK: - Anmeldeobjekt

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - Koordination

/// Haelt Ueberwachung, Zeitgeber und Einstellungen zusammen.
@MainActor
final class Coordinator: ObservableObject {
    static let shared = Coordinator()

    @Published private(set) var isWatching = false
    @Published var rmapiVersion: String?
    /// Neueste Version laut GitHub — nur zur Anzeige, es wird nichts geladen.
    @Published var latestRmapiVersion: String?
    @Published var isPaired = false
    @Published var legacyAgentActive = false

    private var watcher: FolderWatcher!
    private var timer: Timer?
    private var versionTimer: Timer?
    /// Solange die Einstellungen offen sind, wird nicht automatisch hochgeladen —
    /// sonst funkt ein Scan in eine halb getippte Konfiguration hinein.
    private(set) var settingsOpen = false
    private var missedScan = false

    private init() {
        watcher = FolderWatcher { [weak self] in
            Task { @MainActor in self?.handleChange() }
        }
    }

    func start() {
        refreshStatus()
        SettingsStore.shared.saveNow()  // beim ersten Start die Voreinstellungen festschreiben
        applySettings()
        // Netz gegen verlorene Ereignisse, analog zum StartInterval des Agents
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isWatching else { return }
                self.requestScan(reason: "regelmäßige Prüfung")
            }
        }
        checkRmapiVersion()
        versionTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkRmapiVersion() }
        }
        if SettingsStore.shared.settings.watchingEnabled {
            UploadEngine.shared.scanAll(reason: "Start")
        }
    }

    /// Fragt bei GitHub nach der neuesten rmapi-Version. Schlaegt das fehl
    /// (kein Netz), bleibt die Anzeige einfach leer.
    func checkRmapiVersion() {
        Task { [weak self] in
            guard let tag = try? await RmapiClient.latestVersion() else { return }
            await MainActor.run { self?.latestRmapiVersion = tag }
        }
    }

    /// true, wenn GitHub eine hoehere Version meldet als die installierte.
    var rmapiUpdateAvailable: Bool {
        guard let installed = RmapiClient.versionNumber(rmapiVersion),
              let latest = RmapiClient.versionNumber(latestRmapiVersion) else { return false }
        return RmapiClient.isNewer(latest, than: installed)
    }

    func refreshStatus() {
        rmapiVersion = RmapiClient.isInstalled ? RmapiClient.version() : nil
        isPaired = RmapiClient.isInstalled && RmapiClient.isPaired()
        legacyAgentActive = FileManager.default.fileExists(atPath: Paths.legacyAgent.path)
    }

    /// Nach jeder Aenderung an den Einstellungen aufrufen.
    func applySettings() {
        let settings = SettingsStore.shared.settings
        SettingsStore.shared.ensureInboxExists()
        guard settings.watchingEnabled, RmapiClient.isInstalled else {
            watcher.stop()
            isWatching = false
            return
        }
        let paths = settings.sources.filter(\.enabled).map(\.url.path)
        watcher.watch(paths: paths)
        isWatching = !paths.isEmpty
    }

    func setWatching(_ enabled: Bool) {
        SettingsStore.shared.settings.watchingEnabled = enabled
        applySettings()
        if enabled { UploadEngine.shared.scanAll(reason: "eingeschaltet") }
    }

    private func handleChange() {
        guard isWatching else { return }
        requestScan(reason: "Ordner geändert")
    }

    private func requestScan(reason: String) {
        guard !settingsOpen else {
            missedScan = true
            return
        }
        UploadEngine.shared.scanAll(reason: reason)
    }

    func settingsDidOpen() { settingsOpen = true }

    func settingsDidClose() {
        settingsOpen = false
        applySettings()
        guard missedScan else { return }
        missedScan = false
        UploadEngine.shared.scanAll(reason: "Einstellungen geschlossen")
    }

    /// Der launchd-Agent der Skript-Fassung wuerde parallel dieselben Ordner
    /// abarbeiten — das laedt alles doppelt hoch.
    func disableLegacyAgent() {
        let plist = Paths.legacyAgent
        guard FileManager.default.fileExists(atPath: plist.path) else { return }
        _ = try? ProcessRunner.run("/bin/launchctl",
                                   ["bootout", "gui/\(getuid())/com.send2rm.watch"], timeout: 30)
        let disabled = plist.appendingPathExtension("disabled")
        try? FileManager.default.removeItem(at: disabled)
        try? FileManager.default.moveItem(at: plist, to: disabled)
        Log.shared.info("Alter launchd-Agent deaktiviert")
        refreshStatus()
    }
}
