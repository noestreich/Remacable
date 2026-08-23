import SwiftUI
import AppKit

struct SettingsWindow: View {
    @EnvironmentObject private var store: SettingsStore
    // S2R_TAB waehlt beim Start einen Reiter — praktisch zum Nachschauen
    @State private var tab = ProcessInfo.processInfo.environment["S2R_TAB"] ?? "allgemein"
    var body: some View {
        let _ = store.settings.language
        TabView(selection: $tab) {
            GeneralTab()
                .tabItem { Label(tr("settings.tab.general"), systemImage: "gearshape") }.tag("allgemein")
            FoldersTab()
                .tabItem { Label(tr("settings.tab.folders"), systemImage: "folder") }.tag("ordner")
            LogTab()
                .tabItem { Label(tr("settings.tab.log"), systemImage: "list.bullet.rectangle") }.tag("protokoll")
        }
        .padding(.top, 10)
        .padding([.horizontal, .bottom], 12)
        .frame(minWidth: 520, minHeight: 400)
    }
}

// MARK: - Allgemein

struct GeneralTab: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var coordinator: Coordinator

    @State private var installMessage = ""
    @State private var isInstalling = false
    @State private var showPairing = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section(tr("settings.section.setup")) {
                LabeledContent("rmapi") {
                    HStack(spacing: 8) {
                        StatusDot(ok: RmapiClient.isInstalled)
                        Text(coordinator.rmapiVersion ?? tr("settings.not_installed"))
                            .foregroundStyle(RmapiClient.isInstalled ? .primary : .secondary)
                        versionBadge
                        Spacer()
                        Button(RmapiClient.isInstalled ? tr("settings.update") : tr("settings.install")) {
                            install()
                        }
                        .disabled(isInstalling)
                    }
                }
                if !installMessage.isEmpty {
                    Text(installMessage).font(.caption).foregroundStyle(.secondary)
                }

                LabeledContent(tr("settings.account")) {
                    HStack(spacing: 8) {
                        StatusDot(ok: coordinator.isPaired)
                        Text(coordinator.isPaired ? tr("settings.paired") : tr("settings.not_paired"))
                        Spacer()
                        if coordinator.isPaired {
                            Button(tr("settings.unpair")) {
                                RmapiClient.unpair()
                                coordinator.refreshStatus()
                            }
                        }
                        Button(tr("settings.pair")) { showPairing = true }
                            .disabled(!RmapiClient.isInstalled)
                    }
                }

                if coordinator.legacyAgentActive {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("settings.legacy_agent.title"))
                                .font(.callout)
                            Text(tr("settings.legacy_agent.detail"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(tr("settings.disable")) { coordinator.disableLegacyAgent() }
                    }
                }
            }

            Section(tr("settings.section.behavior")) {
                LabeledContent(tr("settings.language")) {
                    Picker("", selection: $store.settings.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                Toggle(tr("settings.launch_at_login"), isOn: Binding(
                    get: { store.settings.launchAtLogin },
                    set: { setLoginItem($0) }))
                Toggle(tr("settings.notifications"), isOn: $store.settings.notify)
                Toggle(tr("settings.keep_uploaded"),
                       isOn: $store.settings.keepUploaded)
                if store.settings.keepUploaded {
                    LabeledContent(tr("settings.cleanup_uploaded")) {
                        HStack {
                            Stepper(value: $store.settings.cleanupUploadedDays, in: 0...365, step: 5) {
                                Text(store.settings.cleanupUploadedDays == 0
                                     ? tr("settings.cleanup.never")
                                     : tr("settings.cleanup.days", Int(store.settings.cleanupUploadedDays)))
                            }
                        }
                    }
                }
                LabeledContent(tr("settings.size_limit")) {
                    Stepper(value: $store.settings.maxMB, in: 5...500, step: 5) {
                        Text(tr("settings.size_limit.value", Int(store.settings.maxMB)))
                    }
                }
                LabeledContent(tr("settings.default_target")) {
                    TextField("", text: $store.settings.defaultTargetFolder, prompt: Text("/Inbox"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
            }

            Section(tr("settings.section.converters")) {
                ConverterRow(name: "LibreOffice", detail: tr("settings.converter.office"),
                             path: $store.settings.sofficePath)
                ConverterRow(name: "Calibre", detail: tr("settings.converter.ebook"),
                             path: $store.settings.ebookConvertPath)
                LabeledContent("sips") {
                    HStack(spacing: 8) {
                        StatusDot(ok: true)
                        Text(tr("settings.converter.images")).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPairing) { PairingSheet() }
        .alert(tr("common.error"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            coordinator.refreshStatus()
            coordinator.checkRmapiVersion()
        }
        .onChange(of: store.settings.language) { _, _ in
            StatusItemController.shared.refreshLocalizedText()
        }
    }

    /// Zeigt die Version von GitHub neben der installierten an.
    @ViewBuilder
    private var versionBadge: some View {
        if let latest = coordinator.latestRmapiVersion {
            if coordinator.rmapiUpdateAvailable {
                Text("→ \(latest)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .help(tr("settings.version.update_help", latest))
            } else if RmapiClient.isInstalled {
                Text(tr("settings.version.current"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(tr("settings.version.latest_help", latest))
            } else {
                Text(tr("settings.version.available", latest))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func install() {
        isInstalling = true
        installMessage = tr("settings.install.starting")
        Task {
            do {
                let version = try await RmapiClient.install { message in
                    Task { @MainActor in installMessage = message }
                }
                await MainActor.run {
                    installMessage = tr("settings.install.ready", version)
                    isInstalling = false
                    coordinator.refreshStatus()
                    coordinator.applySettings()
                }
                Log.shared.info(tr("log.rmapi_installed", version))
            } catch {
                await MainActor.run {
                    installMessage = ""
                    isInstalling = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            store.settings.launchAtLogin = enabled
        } catch {
            errorMessage = tr("error.login_item", error.localizedDescription)
        }
    }
}

struct ConverterRow: View {
    let name: String
    let detail: String
    @Binding var path: String

    var body: some View {
        LabeledContent(name) {
            HStack(spacing: 8) {
                StatusDot(ok: FileManager.default.isExecutableFile(atPath: path))
                VStack(alignment: .leading, spacing: 1) {
                    Text(detail).foregroundStyle(.secondary).font(.caption)
                    Text(path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button(tr("common.choose")) { choose() }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = tr("dialog.choose_program", name)
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(ok ? Color.green : Color.secondary)
    }
}

// MARK: - Kopplung

struct PairingSheet: View {
    @EnvironmentObject private var coordinator: Coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isPairing = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("pairing.title")).font(.headline)
            Text(tr("pairing.explanation"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button(tr("pairing.open_code_page")) { NSWorkspace.shared.open(RmapiClient.connectURL) }

            TextField(tr("pairing.code_placeholder"), text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title3, design: .monospaced))
                .disabled(isPairing)

            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isPairing { ProgressView().controlSize(.small) }
                Spacer()
                Button(tr("common.cancel")) { dismiss() }
                Button(tr("pairing.pair")) { pair() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || isPairing)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func pair() {
        isPairing = true
        message = nil
        let entered = code
        Task.detached {
            do {
                try RmapiClient.pair(code: entered)
                await MainActor.run {
                    isPairing = false
                    Coordinator.shared.refreshStatus()
                    Coordinator.shared.applySettings()
                    Log.shared.success(tr("log.account_paired"))
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isPairing = false
                    message = error.localizedDescription
                }
            }
        }
    }
}
