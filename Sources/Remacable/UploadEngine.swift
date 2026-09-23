import Foundation
import Darwin

/// Sammelt Dateien aus den Quellen ein, konvertiert sie und laedt sie hoch.
/// Alle Uploads laufen auf einer seriellen Queue — nie zwei gleichzeitig.
@MainActor
final class UploadEngine: ObservableObject {
    static let shared = UploadEngine()

    @Published private(set) var isBusy = false
    @Published private(set) var status: String = String(localized: "Ready")
    @Published private(set) var uploadedTotal = 0
    @Published private(set) var lastUpload: Date?

    private let queue = DispatchQueue(label: "de.send2rm.upload")
    /// Gemeinsamer Merkzettel statt einer Kopie je Durchlauf — siehe SeenStore.
    private nonisolated let seen = SeenStore()
    /// Laeuft gerade ein Durchlauf, wird ein weiterer nur vorgemerkt.
    private var scanRunning = false
    private var pendingReason: String?

    private init() {}

    // MARK: Oeffentliche Aufrufe

    /// Warum Dateien nicht drankommen — fuer die Anzeige in den Einstellungen.
    struct ScanStats {
        var total = 0
        var pattern = 0
        var tooOld = 0
        var known = 0
    }

    /// Was dieser Ordner gerade hochladen wuerde — fuer die Rueckfrage beim
    /// Einschalten einer Quelle.
    func matchingFiles(in source: WatchSource) -> [URL] {
        var stats = ScanStats()
        return collect(from: source, state: seen.snapshot(), stats: &stats)
    }

    /// Dasselbe mit Begruendung, wenn nichts uebrig bleibt.
    func preview(for source: WatchSource) -> (files: [URL], stats: ScanStats) {
        var stats = ScanStats()
        let files = collect(from: source, state: seen.snapshot(), stats: &stats)
        return (files, stats)
    }

    /// Wie viele Dateien dieses Ordners im Merkzettel stehen.
    func knownCount(for source: WatchSource) -> Int {
        seen.count(withPrefix: source.url.path + "/")
    }

    /// Merkzettel fuer einen Ordner leeren — danach geht alles erneut hoch.
    func forget(source: WatchSource) {
        let removed = seen.forget(withPrefix: source.url.path + "/")
        if removed > 0 {
            Log.shared.info(String(format: String(localized: "Cleared upload memory for %@ (%lld entries)"),
                                   source.displayName, removed))
        }
    }

    /// Vorhandene Dateien als „schon erledigt" abhaken, ohne sie hochzuladen.
    func markAsSeen(_ files: [URL]) {
        seen.mark(files)
    }

    func scanAll(reason: String) {
        guard RmapiClient.isInstalled else { return }
        // Laeuft schon einer, wird nur vorgemerkt. Sonst reihen sich waehrend
        // eines langen Durchlaufs beliebig viele weitere ein — und jeder von
        // ihnen wuerde dieselben Dateien noch einmal hochladen.
        guard !scanRunning else {
            pendingReason = reason
            return
        }
        start(reason: reason)
    }

    private func start(reason: String) {
        let settings = SettingsStore.shared.settings
        scanRunning = true
        setBusy(true, status: String(localized: "Checking folders…"))
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.runScan(settings: settings, reason: reason)
            Task { @MainActor in
                self.scanRunning = false
                self.finish(result)
                if let pending = self.pendingReason {
                    self.pendingReason = nil
                    self.start(reason: pending)
                }
            }
        }
    }

    /// Direkter Upload einzelner Dateien (Menü, Drag & Drop).
    func send(files: [URL], folder: String? = nil, title: String? = nil) {
        guard !files.isEmpty else { return }
        let settings = SettingsStore.shared.settings
        let target = folder ?? settings.defaultTargetFolder
        setBusy(true, status: files.count == 1
                ? String(format: String(localized: "Uploading %@…"), files[0].lastPathComponent)
                : String(format: String(localized: "Uploading %lld files…"), files.count))
        queue.async { [weak self] in
            guard let self else { return }
            var taken = TitleRegistry()
            var result = Result()
            for file in files {
                do {
                    try self.upload(file: file, to: target, settings: settings,
                                    rename: [], forcedTitle: files.count == 1 ? title : nil,
                                    taken: &taken)
                    result.uploaded += 1
                } catch {
                    result.failed += 1
                    result.lastError = error.localizedDescription
                    Log.shared.error("\(file.lastPathComponent): \(error.localizedDescription)")
                    Notifier.send(title: String(localized: "Remacable: Error"),
                                  body: "\(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
            self.finish(result)
        }
    }

    // MARK: Ablauf

    private struct Result {
        var uploaded = 0
        var failed = 0
        var lastError: String?
    }

    /// Merkt sich vergebene Titel je Cloud-Ordner, damit "put" nicht an einem
    /// bestehenden Dokument scheitert.
    private struct TitleRegistry {
        private var byFolder: [String: Set<String>] = [:]

        mutating func unique(_ wanted: String, in folder: String) throws -> String {
            if byFolder[folder] == nil {
                byFolder[folder] = try RmapiClient.entries(in: folder)
            }
            var candidate = wanted
            var counter = 2
            while byFolder[folder]?.contains(candidate) == true {
                candidate = "\(wanted) (\(counter))"
                counter += 1
                if counter > 99 { break }
            }
            byFolder[folder]?.insert(candidate)
            return candidate
        }
    }

    private nonisolated func runScan(settings: AppSettings, reason: String) -> Result {
        var result = Result()
        var taken = TitleRegistry()
        // Erst hier lesen, nicht beim Einreihen: zwischen beidem koennen
        // Minuten liegen, in denen ein anderer Durchlauf schon hochgeladen hat.
        var state = seen.snapshot()

        for source in settings.sources where source.enabled {
            // Erst jetzt warten: nur fuer Dateien, die wirklich in Frage kommen,
            // und fuer alle gemeinsam statt nacheinander.
            var stats = ScanStats()
            let candidates = settled(collect(from: source, state: state, stats: &stats),
                                     wait: source.stableWait)
            guard !candidates.isEmpty else {
                cleanupArchive(source: source, settings: settings)
                continue
            }
            Log.shared.info(String(format: String(localized: "%@: %lld file(s) — %@"),
                                   source.displayName, candidates.count, reason))

            for file in candidates {
                let relativeDir = self.relativeDir(of: file, in: source)
                let folder = Self.cloudFolder(base: source.targetFolder, relativeDir: relativeDir)
                do {
                    try upload(file: file, to: folder, settings: settings,
                               rename: source.renameRules, forcedTitle: nil, taken: &taken)
                    result.uploaded += 1
                    if source.move {
                        if settings.keepUploaded {
                            archive(file, source: source, subdir: "Uploaded", relativeDir: relativeDir)
                        } else {
                            try? FileManager.default.removeItem(at: file)
                        }
                    } else if let mark = Self.fingerprint(file) {
                        // Sofort festhalten, damit ein parallel angestossener
                        // Durchlauf die Datei nicht erneut aufgreift
                        state[file.path] = mark
                        seen.mark(file.path, as: mark)
                    }
                } catch {
                    result.failed += 1
                    result.lastError = error.localizedDescription
                    Notifier.send(title: String(localized: "Remacable: Error"),
                                  body: "\(file.lastPathComponent): \(error.localizedDescription)")
                    if source.move {
                        Log.shared.error("\(file.lastPathComponent): \(error.localizedDescription)")
                        archive(file, source: source, subdir: "Failed", relativeDir: relativeDir)
                    } else if Self.isPermanent(error), let mark = Self.fingerprint(file) {
                        // Ohne Failed/ bliebe die Datei liegen und scheiterte alle
                        // fuenf Minuten erneut — einmal merken, dann Ruhe.
                        state[file.path] = mark
                        seen.mark(file.path, as: mark)
                        Log.shared.error(String(format: String(localized: "%@: %@ — will not be retried"),
                                            file.lastPathComponent, error.localizedDescription))
                    } else {
                        Log.shared.error("\(file.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
            cleanupArchive(source: source, settings: settings)
        }

        seen.prune()
        return result
    }

    private nonisolated func upload(file: URL, to folder: String, settings: AppSettings,
                                    rename: [RenameRule], forcedTitle: String?,
                                    taken: inout TitleRegistry) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let sizeMB = Double((attributes[.size] as? NSNumber)?.int64Value ?? 0) / 1_048_576
        if sizeMB > settings.maxMB {
            throw EngineError.tooLarge(sizeMB: sizeMB, limit: settings.maxMB)
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("send2rm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let converter = Converter(sofficePath: settings.sofficePath,
                                  ebookConvertPath: settings.ebookConvertPath)
        let payload = try converter.convert(file, workDir: workDir)

        let base = forcedTitle ?? Self.applyRename(file.deletingPathExtension().lastPathComponent,
                                                   rules: rename)
        let title = try taken.unique(base, in: folder)

        // Der Dateiname wird zum Titel auf dem Geraet
        let staged = workDir.appendingPathComponent("\(title).\(payload.pathExtension)")
        if staged != payload {
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: payload, to: staged)
        }

        try RmapiClient.put(file: staged, folder: folder)
        Log.shared.success("\(file.lastPathComponent) → \(folder)/\(title).\(payload.pathExtension)")
    }

    // MARK: Dateien einsammeln

    private nonisolated func collect(from source: WatchSource, state: [String: String],
                                     stats: inout ScanStats) -> [URL] {
        let root = source.url
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            Log.shared.error(String(format: String(localized: "Folder is missing: %@"), root.path))
            return []
        }
        if source.move {
            for sub in ["Uploaded", "Failed"] {
                try? FileManager.default.createDirectory(
                    at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
            }
        }

        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !source.subfolders { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: options) else { return [] }

        let now = Date()
        var found: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = relativeParts(of: url, in: root)
            if relative.dropLast().contains(where: { $0 == "Uploaded" || $0 == "Failed" }) { continue }
            if Converter.shouldSkip(url) { continue }
            stats.total += 1
            if !matches(url.lastPathComponent, patterns: source.patterns) {
                stats.pattern += 1
                continue
            }
            if source.maxAgeDays > 0,
               let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               now.timeIntervalSince(modified) > source.maxAgeDays * 86400 {
                stats.tooOld += 1
                continue
            }
            if let mark = Self.fingerprint(url), state[url.path] == mark {
                stats.known += 1
                continue
            }
            found.append(url)
        }

        return found.sorted { $0.path < $1.path }
    }

    /// Wartet einmal und behaelt die Dateien, die sich in der Zeit nicht
    /// veraendert haben. Frueher wurde je Datei einzeln gewartet — bei 60
    /// Sekunden Wartezeit dauerte ein Durchlauf dadurch Minuten.
    private nonisolated func settled(_ files: [URL], wait: Double) -> [URL] {
        guard !files.isEmpty else { return [] }
        let before = files.map { ($0, Self.fingerprint($0)) }
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        return before.compactMap { url, mark in
            guard let mark, let now = Self.fingerprint(url), now == mark else { return nil }
            return url
        }
    }

    private nonisolated func matches(_ name: String, patterns: [String]) -> Bool {
        if patterns.isEmpty { return true }
        return patterns.contains { fnmatch($0, name, 0) == 0 }
    }

    private nonisolated func relativeParts(of url: URL, in root: URL) -> [String] {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > rootParts.count else { return [url.lastPathComponent] }
        return Array(parts.dropFirst(rootParts.count))
    }

    private nonisolated func relativeDir(of url: URL, in source: WatchSource) -> [String] {
        Array(relativeParts(of: url, in: source.url).dropLast())
    }

    private nonisolated static func cloudFolder(base: String, relativeDir: [String]) -> String {
        var folder = base.hasSuffix("/") ? String(base.dropLast()) : base
        if folder.isEmpty { folder = "" }
        for part in relativeDir { folder += "/" + part }
        return folder.isEmpty ? "/" : folder
    }

    // MARK: Archiv

    private nonisolated func archive(_ file: URL, source: WatchSource, subdir: String, relativeDir: [String]) {
        var target = source.url.appendingPathComponent(subdir)
        for part in relativeDir { target.appendPathComponent(part) }
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        var destination = target.appendingPathComponent(file.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HHmmss"
            let stem = file.deletingPathExtension().lastPathComponent
            destination = target.appendingPathComponent(
                "\(stem) \(formatter.string(from: Date())).\(file.pathExtension)")
        }
        do {
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            Log.shared.error(String(format: String(localized: "Could not file %@: %@"),
                                    file.lastPathComponent, error.localizedDescription))
        }
    }

    /// Raeumt alte Dateien aus Uploaded/ weg — sonst waechst das Archiv endlos.
    private nonisolated func cleanupArchive(source: WatchSource, settings: AppSettings) {
        guard source.move, settings.keepUploaded, settings.cleanupUploadedDays > 0 else { return }
        let directory = source.url.appendingPathComponent("Uploaded")
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date().addingTimeInterval(-settings.cleanupUploadedDays * 86400)
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                Log.shared.info(String(format: String(localized: "Archive cleaned up: %@"), url.lastPathComponent))
            } catch {
                Log.shared.error(String(format: String(localized: "Could not delete %@"), url.lastPathComponent))
            }
        }
    }

    /// Fehler, die sich durch Wiederholen nicht beheben lassen. Netz- und
    /// rmapi-Fehler zaehlen bewusst nicht dazu.
    private nonisolated static func isPermanent(_ error: Error) -> Bool {
        if let conversion = error as? ConversionError {
            switch conversion {
            case .unsupported, .failed: return true
            case .toolMissing: return false
            }
        }
        return error is EngineError  // zu gross
    }

    // MARK: Umbenennen

    /// Erste passende Regel gewinnt. Rueckverweise duerfen \1 oder $1 heissen.
    nonisolated static func applyRename(_ stem: String, rules: [RenameRule]) -> String {
        for rule in rules where !rule.match.isEmpty && !rule.title.isEmpty {
            guard let regex = try? NSRegularExpression(pattern: rule.match) else { continue }
            let range = NSRange(stem.startIndex..., in: stem)
            guard regex.firstMatch(in: stem, range: range) != nil else { continue }
            var template = rule.title
            for index in 1...9 {
                template = template.replacingOccurrences(of: "\\\(index)", with: "$\(index)")
            }
            return regex.stringByReplacingMatches(in: stem, range: range, withTemplate: template)
        }
        return stem
    }

    // MARK: Zustand

    private nonisolated static func fingerprint(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return "\(size):\(Int(modified.timeIntervalSince1970))"
    }

    // MARK: Status

    private func setBusy(_ busy: Bool, status: String) {
        isBusy = busy
        self.status = status
    }

    private nonisolated func finish(_ result: Result) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isBusy = false
            self.uploadedTotal += result.uploaded
            if result.uploaded > 0 {
                self.lastUpload = Date()
                self.status = String(format: String(localized: "Uploaded %lld document(s)"), result.uploaded)
                if SettingsStore.shared.settings.notify {
                    Notifier.send(title: "Remacable", body: self.status)
                }
            } else if result.failed > 0 {
                self.status = result.lastError ?? String(localized: "Failed")
            } else {
                self.status = String(localized: "Ready")
            }
        }
    }
}

enum EngineError: LocalizedError {
    case tooLarge(sizeMB: Double, limit: Double)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let sizeMB, let limit):
            return String(format: String(localized: "File is %.0f MB (limit is %.0f MB)"), sizeMB, limit)
        }
    }
}


// MARK: - Merkzettel

/// Haelt fest, welche Dateien schon hochgeladen wurden — Pfad, Groesse und
/// Aenderungsdatum.
///
/// Bewusst nicht am Main-Actor: Die Upload-Queue und die Oberflaeche greifen
/// beide zu, und vor allem muss ein Durchlauf den *aktuellen* Stand sehen.
/// Frueher bekam jeder Durchlauf eine Kopie aus dem Moment, in dem er
/// eingereiht wurde — lief er erst Minuten spaeter los, lud er laengst
/// erledigte Dateien ein zweites Mal hoch.
final class SeenStore: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: String]

    init() {
        entries = SeenStore.load()
    }

    func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func mark(_ path: String, as fingerprint: String) {
        lock.lock()
        entries[path] = fingerprint
        let copy = entries
        lock.unlock()
        SeenStore.save(copy)
    }

    func mark(_ files: [URL]) {
        lock.lock()
        for file in files {
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
               let size = values.fileSize, let modified = values.contentModificationDate {
                entries[file.path] = "\(size):\(Int(modified.timeIntervalSince1970))"
            }
        }
        let copy = entries
        lock.unlock()
        SeenStore.save(copy)
    }

    func count(withPrefix prefix: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.keys.filter { $0.hasPrefix(prefix) }.count
    }

    @discardableResult
    func forget(withPrefix prefix: String) -> Int {
        lock.lock()
        let before = entries.count
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
        let removed = before - entries.count
        let copy = entries
        lock.unlock()
        if removed > 0 { SeenStore.save(copy) }
        return removed
    }

    /// Eintraege verschwundener Dateien entfernen, damit die Liste nicht waechst.
    func prune() {
        lock.lock()
        let before = entries.count
        entries = entries.filter { FileManager.default.fileExists(atPath: $0.key) }
        let changed = before != entries.count
        let copy = entries
        lock.unlock()
        if changed { SeenStore.save(copy) }
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: Paths.stateFile),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }

    private static func save(_ entries: [String: String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        let tmp = Paths.stateFile.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(Paths.stateFile, withItemAt: tmp)
        } catch {
            try? data.write(to: Paths.stateFile)
        }
    }
}
