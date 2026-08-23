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
            Label(tr("folders.paused_while_open"),
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
                Text(tr("folders.none_selected")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = tr("folders.choose.message")
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
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var coordinator: Coordinator

    private struct Preview {
        var matching = 0
        var stats = UploadEngine.ScanStats()
        var known = 0
    }
    @State private var preview: Preview?

    var body: some View {
        let _ = store.settings.language
        Form {
            if !source.enabled {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("folders.inactive.title"))
                                .font(.callout.weight(.medium))
                            Text(tr("folders.inactive.detail"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(tr("folders.enable")) {
                            SourceActivation.set(true, sourceID: source.id)
                        }
                    }
                }
            }

            Section(tr("folders.section.folder")) {
                LabeledContent(tr("folders.path")) {
                    HStack {
                        Text(source.url.path)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(tr("common.change")) { choosePath() }
                    }
                }
                LabeledContent(tr("folders.cloud_target")) {
                    TextField("", text: $source.targetFolder, prompt: Text("/Inbox"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                Toggle(tr("folders.mirror_subfolders"), isOn: $source.subfolders)
                Text(source.subfolders
                     ? tr("folders.mirror.example", source.displayName, source.targetFolder)
                     : tr("folders.mirror.disabled"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(tr("folders.section.after_upload")) {
                Picker("", selection: $source.move) {
                    Text(tr("folders.after_upload.move")).tag(true)
                    Text(tr("folders.after_upload.leave")).tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(source.move
                     ? tr("folders.after_upload.move_detail")
                     : tr("folders.after_upload.leave_detail"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(tr("folders.section.filter")) {
                LabeledContent(tr("folders.file_patterns")) {
                    TextField("", text: Binding(
                        get: { source.patternText },
                        set: { source.patternText = $0 }), prompt: Text("*"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                }
                Text(tr("folders.file_patterns.hint"))
                    .font(.caption).foregroundStyle(.secondary)

                LabeledContent(tr("folders.max_age")) {
                    Stepper(value: $source.maxAgeDays, in: 0...365, step: 1) {
                        Text(source.maxAgeDays == 0
                             ? tr("folders.max_age.any")
                             : Int(source.maxAgeDays) == 1
                                ? tr("folders.max_age.day")
                                : tr("folders.max_age.days", Int(source.maxAgeDays)))
                    }
                }
                LabeledContent(tr("folders.stability_wait")) {
                    Stepper(value: $source.stableWait, in: 0...60, step: 1) {
                        Text("\(Int(source.stableWait)) s")
                    }
                }
                Text(tr("folders.stability_wait.hint"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(tr("folders.section.current")) {
                if let preview {
                    if preview.matching > 0 {
                        Label(preview.matching == 1
                              ? tr("folders.pending.one")
                              : tr("folders.pending.many", preview.matching),
                              systemImage: "arrow.up.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(tr("folders.nothing_to_do"), systemImage: "checkmark.circle")
                            ForEach(reasons(preview), id: \.self) { reason in
                                Text("• " + reason)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if preview.known > 0 {
                        HStack {
                            Text(tr("folders.memo.count", preview.known))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(tr("common.reset")) {
                                UploadEngine.shared.forget(source: source)
                                refreshPreview()
                            }
                        }
                    }
                }
            }

            Section(tr("folders.section.rename")) {
                if source.renameRules.isEmpty {
                    Text(tr("folders.rename.empty"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($source.renameRules) { $rule in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField(tr("folders.rename.pattern"), text: $rule.match)
                            Button {
                                source.renameRules.removeAll { $0.id == rule.id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                        TextField(tr("folders.rename.title"), text: $rule.title)
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(.vertical, 2)
                }
                Button(tr("folders.rename.add")) { source.renameRules.append(RenameRule()) }
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
            list.append(Int(source.maxAgeDays) == 1
                        ? tr("folders.reason.too_old.day", preview.stats.tooOld)
                        : tr("folders.reason.too_old.days", Int(source.maxAgeDays),
                             preview.stats.tooOld))
        }
        if preview.stats.known > 0 {
            list.append(tr("folders.reason.known", preview.stats.known))
        }
        if preview.stats.pattern > 0 {
            list.append(tr("folders.reason.pattern", preview.stats.pattern))
        }
        if list.isEmpty {
            list.append(preview.stats.total == 0
                        ? tr("folders.reason.empty")
                        : tr("folders.reason.done"))
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
    @EnvironmentObject private var store: SettingsStore
    @StateObject private var log = Log.shared

    var body: some View {
        let _ = store.settings.language
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
                Text(tr("log.entries", log.entries.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("log.show_file")) {
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
            ? tr("folders.activation.existing.one")
            : tr("folders.activation.existing.many", pending.count)
        alert.informativeText = tr("folders.activation.question")
        alert.addButton(withTitle: tr("folders.activation.upload_all"))
        alert.addButton(withTitle: tr("folders.activation.future_only"))
        alert.addButton(withTitle: tr("common.cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            activate(at: index)
        case .alertSecondButtonReturn:
            UploadEngine.shared.markAsSeen(pending)
            Log.shared.info(pending.count == 1
                            ? tr("log.existing_marked_done.one")
                            : tr("log.existing_marked_done.many", pending.count))
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
