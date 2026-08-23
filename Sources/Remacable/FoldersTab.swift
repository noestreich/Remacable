import SwiftUI
import AppKit

struct FoldersTab: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var coordinator: Coordinator
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                list
                    .frame(minWidth: 190, maxWidth: 260)
                detail
                    .frame(minWidth: 340, maxWidth: .infinity)
            }
            Divider()
            Label("Solange dieses Fenster offen ist, wird nicht automatisch hochgeladen.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .onAppear { if selection == nil { selection = store.settings.sources.first?.id } }
    }

    // MARK: Liste

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach($store.settings.sources) { $source in
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(
                            get: { source.enabled },
                            set: { wanted in
                                // Nicht mitten im View-Update modal werden
                                let id = source.id
                                DispatchQueue.main.async {
                                    SourceActivation.set(wanted, sourceID: id)
                                }
                            }))
                            .labelsHidden()
                            .controlSize(.mini)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.displayName)
                                .lineLimit(1)
                            Text(source.targetFolder)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(source.id)
                }
            }
            Divider()
            HStack(spacing: 0) {
                Button { addFolder() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).padding(6)
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless).padding(6)
                    .disabled(selection == nil || store.settings.sources.count <= 1)
                Spacer()
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let index = store.settings.sources.firstIndex(where: { $0.id == selection }) {
            SourceDetail(source: $store.settings.sources[index])
                .id(store.settings.sources[index].id)
        } else {
            VStack {
                Text("Kein Ordner ausgewählt").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Ordner auswählen, der überwacht werden soll"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var source = WatchSource(path: url.path)
        source.targetFolder = store.settings.defaultTargetFolder
        source.enabled = false  // erst einstellen, dann einschalten
        store.settings.sources.append(source)
        selection = source.id
        coordinator.applySettings()
    }

    private func removeSelected() {
        guard let selection, store.settings.sources.count > 1 else { return }
        // Sonst erbt ein spaeter neu angelegter Ordner desselben Pfads die alte Erinnerung
        if let source = store.settings.sources.first(where: { $0.id == selection }) {
            UploadEngine.shared.forget(source: source)
        }
        store.settings.sources.removeAll { $0.id == selection }
        self.selection = store.settings.sources.first?.id
        coordinator.applySettings()
    }
}

// MARK: - Ein Ordner

struct SourceDetail: View {
    @Binding var source: WatchSource
    @EnvironmentObject private var coordinator: Coordinator

    private struct Preview {
        var matching = 0
        var stats = UploadEngine.ScanStats()
        var known = 0
    }
    @State private var preview: Preview?

    var body: some View {
        Form {
            if !source.enabled {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dieser Ordner ist noch inaktiv.")
                                .font(.callout.weight(.medium))
                            Text("Bis du ihn einschaltest, passiert nichts — Zeit, alles in Ruhe einzustellen.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Einschalten") {
                            SourceActivation.set(true, sourceID: source.id)
                        }
                    }
                }
            }

            Section("Ordner") {
                LabeledContent("Pfad") {
                    HStack {
                        Text(source.url.path)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Ändern …") { choosePath() }
                    }
                }
                LabeledContent("Zielordner in der Cloud") {
                    TextField("", text: $source.targetFolder, prompt: Text("/Inbox"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                Toggle("Unterordner in der Cloud spiegeln", isOn: $source.subfolders)
                Text(source.subfolders
                     ? "„\(source.displayName)/Zeitungen/x.pdf“ landet in „\(source.targetFolder)/Zeitungen“."
                     : "Nur Dateien direkt in diesem Ordner werden hochgeladen.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Nach dem Upload") {
                Picker("", selection: $source.move) {
                    Text("Datei nach „Uploaded“ verschieben").tag(true)
                    Text("Datei unberührt liegen lassen").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(source.move
                     ? "Legt in diesem Ordner die Unterordner „Uploaded“ und „Failed“ an."
                     : "Für Ordner, die jemand anders verwaltet: nichts wird verschoben, keine Unterordner angelegt. Ein Merkzettel hält fest, was schon oben ist; ändert sich die Datei, geht sie erneut hoch.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Filter") {
                LabeledContent("Dateimuster") {
                    TextField("", text: Binding(
                        get: { source.patternText },
                        set: { source.patternText = $0 }), prompt: Text("*"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                }
                Text("Mehrere durch Komma trennen, z. B. „Zeitung_*.pdf, *.epub“.")
                    .font(.caption).foregroundStyle(.secondary)

                LabeledContent("Nur neuere Dateien") {
                    Stepper(value: $source.maxAgeDays, in: 0...365, step: 1) {
                        Text(source.maxAgeDays == 0
                             ? "alle, egal wie alt"
                             : "jünger als \(Int(source.maxAgeDays)) Tage")
                    }
                }
                LabeledContent("Wartezeit vor dem Upload") {
                    Stepper(value: $source.stableWait, in: 0...60, step: 1) {
                        Text("\(Int(source.stableWait)) s")
                    }
                }
                Text("Die Wartezeit prüft, ob die Datei noch wächst — höher setzen, wenn ein anderes Programm sie nachträglich bearbeitet.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Zurzeit") {
                if let preview {
                    if preview.matching > 0 {
                        Label(preview.matching == 1
                              ? "Eine Datei wartet auf den Upload"
                              : "\(preview.matching) Dateien warten auf den Upload",
                              systemImage: "arrow.up.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Nichts zu tun", systemImage: "checkmark.circle")
                            ForEach(reasons(preview), id: \.self) { reason in
                                Text("• " + reason)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if preview.known > 0 {
                        HStack {
                            Text("Merkzettel: \(preview.known) Datei(en) gelten als erledigt")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Zurücksetzen") {
                                UploadEngine.shared.forget(source: source)
                                refreshPreview()
                            }
                        }
                    }
                }
            }

            Section("Umbenennen") {
                if source.renameRules.isEmpty {
                    Text("Ohne Regel wird der Dateiname zum Titel auf dem Gerät.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($source.renameRules) { $rule in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Muster (regulärer Ausdruck)", text: $rule.match)
                            Button {
                                source.renameRules.removeAll { $0.id == rule.id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                        TextField("Titel, z. B. Zeitung \\3-\\2-\\1", text: $rule.title)
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(.vertical, 2)
                }
                Button("Regel hinzufügen") { source.renameRules.append(RenameRule()) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: source) { _, _ in coordinator.applySettings() }
        .onChange(of: source.filterKey) { _, _ in refreshPreview() }
        .onAppear { refreshPreview() }
    }

    private func refreshPreview() {
        let result = UploadEngine.shared.preview(for: source)
        preview = Preview(matching: result.files.count,
                          stats: result.stats,
                          known: UploadEngine.shared.knownCount(for: source))
    }

    /// Warum gerade nichts hochgeht — das ist sonst nicht nachvollziehbar.
    private func reasons(_ preview: Preview) -> [String] {
        var list: [String] = []
        if preview.stats.tooOld > 0 {
            list.append("\(preview.stats.tooOld) Datei(en) sind älter als \(Int(source.maxAgeDays)) Tage")
        }
        if preview.stats.known > 0 {
            list.append("\(preview.stats.known) Datei(en) wurden schon hochgeladen")
        }
        if preview.stats.pattern > 0 {
            list.append("\(preview.stats.pattern) Datei(en) passen nicht zum Muster")
        }
        if list.isEmpty {
            list.append(preview.stats.total == 0
                        ? "Der Ordner enthält keine Dateien"
                        : "Alles erledigt")
        }
        return list
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = source.url
        if panel.runModal() == .OK, let url = panel.url { source.path = url.path }
    }
}

// MARK: - Protokoll

struct LogTab: View {
    @StateObject private var log = Log.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(log.entries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.date, format: .dateTime.hour().minute().second())
                                    .foregroundStyle(.tertiary)
                                Text(entry.message)
                                    .foregroundStyle(color(for: entry.level))
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .font(.system(.caption, design: .monospaced))
                            .id(entry.id)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: log.entries.count) { _, _ in
                    if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Text("\(log.entries.count) Einträge").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Logdatei zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([Paths.logFile])
                }
            }
            .padding(8)
        }
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .primary
        case .success: return .green
        case .error: return .red
        }
    }
}


// MARK: - Ein- und Ausschalten

@MainActor
enum SourceActivation {
    /// Beim Einschalten erst fragen, wenn im Ordner schon etwas liegt — sonst
    /// gingen beim ersten Haken ungefragt Altbestaende hoch.
    static func set(_ enabled: Bool, sourceID: UUID) {
        let store = SettingsStore.shared
        guard let index = store.settings.sources.firstIndex(where: { $0.id == sourceID }) else { return }

        guard enabled else {
            store.settings.sources[index].enabled = false
            Coordinator.shared.applySettings()
            return
        }

        let pending = UploadEngine.shared.matchingFiles(in: store.settings.sources[index])
        guard !pending.isEmpty else {
            activate(at: index)
            return
        }

        let alert = NSAlert()
        alert.messageText = pending.count == 1
            ? "In diesem Ordner liegt bereits eine passende Datei"
            : "In diesem Ordner liegen bereits \(pending.count) passende Dateien"
        alert.informativeText = "Sollen die jetzt mit hochgeladen werden, oder nur alles, was ab jetzt dazukommt?"
        alert.addButton(withTitle: "Alle hochladen")
        alert.addButton(withTitle: "Nur künftige")
        alert.addButton(withTitle: "Abbrechen")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            activate(at: index)
        case .alertSecondButtonReturn:
            UploadEngine.shared.markAsSeen(pending)
            Log.shared.info("\(pending.count) vorhandene Datei(en) als erledigt abgehakt")
            activate(at: index)
        default:
            break  // bleibt inaktiv
        }
    }

    private static func activate(at index: Int) {
        SettingsStore.shared.settings.sources[index].enabled = true
        SettingsStore.shared.saveNow()
        Coordinator.shared.applySettings()
    }
}
