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
            Label("While this window is open, nothing is uploaded automatically.",
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
                Text("No folder selected").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose a folder to watch")
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
                            Text("This folder is still switched off.")
                                .font(.callout.weight(.medium))
                            Text("Nothing happens until you switch it on — time to set everything up in peace.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Switch on") {
                            SourceActivation.set(true, sourceID: source.id)
                        }
                    }
                }
            }

            Section("Folder") {
                LabeledContent("Path") {
                    HStack {
                        Text(source.url.path)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Change…") { choosePath() }
                    }
                }
                LabeledContent("Destination folder in the cloud") {
                    TextField("", text: $source.targetFolder, prompt: Text("/Inbox"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                Toggle("Mirror subfolders in the cloud", isOn: $source.subfolders)
                Text(source.subfolders
                     ? String(format: String(localized: "“%@/Papers/x.pdf” ends up in “%@/Papers”."),
                              source.displayName, source.targetFolder)
                     : String(localized: "Only files directly in this folder are uploaded."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("After the upload") {
                Picker("", selection: $source.move) {
                    Text("Move the file to “Uploaded”").tag(true)
                    Text("Leave the file untouched").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(source.move
                     ? "Creates the subfolders “Uploaded” and “Failed” inside this folder."
                     : "For folders someone else manages: nothing is moved, no subfolders are created. A record keeps track of what already went up; if the file changes, it is uploaded again.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Filter") {
                LabeledContent("File pattern") {
                    TextField("", text: Binding(
                        get: { source.patternText },
                        set: { source.patternText = $0 }), prompt: Text("*"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                }
                Text("Separate several with commas, e.g. “Paper_*.pdf, *.epub”.")
                    .font(.caption).foregroundStyle(.secondary)

                LabeledContent("Only newer files") {
                    Stepper(value: $source.maxAgeDays, in: 0...365, step: 1) {
                        Text(source.maxAgeDays == 0
                             ? String(localized: "all, however old")
                             : String(format: String(localized: "newer than %lld days"),
                                      Int(source.maxAgeDays)))
                    }
                }
                LabeledContent("Wait before uploading") {
                    Stepper(value: $source.stableWait, in: 0...60, step: 1) {
                        Text("\(Int(source.stableWait)) s")
                    }
                }
                Text("The wait checks whether the file is still growing — raise it if another program edits the file afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Right now") {
                if let preview {
                    if preview.matching > 0 {
                        Label(preview.matching == 1
                              ? String(localized: "One file is waiting to be uploaded")
                              : String(format: String(localized: "%lld files are waiting to be uploaded"),
                                       preview.matching),
                              systemImage: "arrow.up.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Nothing to do", systemImage: "checkmark.circle")
                            ForEach(reasons(preview), id: \.self) { reason in
                                Text("• " + reason)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if preview.known > 0 {
                        HStack {
                            Text(String(format: String(localized: "Upload memory: %lld file(s) count as done"), preview.known))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Reset") {
                                UploadEngine.shared.forget(source: source)
                                refreshPreview()
                            }
                        }
                    }
                }
            }

            Section("Renaming") {
                if source.renameRules.isEmpty {
                    Text("Without a rule, the file name becomes the title on the device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($source.renameRules) { $rule in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Pattern (regular expression)", text: $rule.match)
                            Button {
                                source.renameRules.removeAll { $0.id == rule.id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                        TextField("Title, e.g. Paper \\3-\\2-\\1", text: $rule.title)
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(.vertical, 2)
                }
                Button("Add rule") { source.renameRules.append(RenameRule()) }
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
            list.append(String(format: String(localized: "%lld file(s) are older than %lld days"),
                               preview.stats.tooOld, Int(source.maxAgeDays)))
        }
        if preview.stats.known > 0 {
            list.append(String(format: String(localized: "%lld file(s) have already been uploaded"),
                               preview.stats.known))
        }
        if preview.stats.pattern > 0 {
            list.append(String(format: String(localized: "%lld file(s) do not match the pattern"),
                               preview.stats.pattern))
        }
        if list.isEmpty {
            list.append(preview.stats.total == 0
                        ? String(localized: "The folder contains no files")
                        : String(localized: "Everything done"))
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
                Text(String(format: String(localized: "%lld entries"), log.entries.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show log file") {
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
            ? String(localized: "This folder already contains one matching file")
            : String(format: String(localized: "This folder already contains %lld matching files"),
                     pending.count)
        alert.informativeText = String(localized: "Upload those as well, or only whatever arrives from now on?")
        alert.addButton(withTitle: String(localized: "Upload all"))
        alert.addButton(withTitle: String(localized: "Only future ones"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            activate(at: index)
        case .alertSecondButtonReturn:
            UploadEngine.shared.markAsSeen(pending)
            Log.shared.info(String(format: String(localized: "Marked %lld existing file(s) as done"),
                                   pending.count))
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
