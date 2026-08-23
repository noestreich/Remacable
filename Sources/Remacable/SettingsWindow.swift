import SwiftUI
import AppKit

struct SettingsWindow: View {
    // S2R_TAB waehlt beim Start einen Reiter — praktisch zum Nachschauen
    @State private var tab = ProcessInfo.processInfo.environment["S2R_TAB"] ?? "allgemein"
    var body: some View {
        TabView(selection: $tab) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }.tag("allgemein")
            FoldersTab()
                .tabItem { Label("Folders", systemImage: "folder") }.tag("ordner")
            LogTab()
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }.tag("protokoll")
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
            Section("Setup") {
                LabeledContent("rmapi") {
                    HStack(spacing: 8) {
                        StatusDot(ok: RmapiClient.isInstalled)
                        Text(coordinator.rmapiVersion ?? String(localized: "not installed"))
                            .foregroundStyle(RmapiClient.isInstalled ? .primary : .secondary)
                        versionBadge
                        Spacer()
                        Button(RmapiClient.isInstalled ? "Update" : "Install") {
                            install()
                        }
                        .disabled(isInstalling)
                    }
                }
                if !installMessage.isEmpty {
                    Text(installMessage).font(.caption).foregroundStyle(.secondary)
                }

                LabeledContent("Account") {
                    HStack(spacing: 8) {
                        StatusDot(ok: coordinator.isPaired)
                        Text(coordinator.isPaired ? "paired" : "not paired")
                        Spacer()
                        if coordinator.isPaired {
                            Button("Unpair") {
                                RmapiClient.unpair()
                                coordinator.refreshStatus()
                            }
                        }
                        Button("Pair…") { showPairing = true }
                            .disabled(!RmapiClient.isInstalled)
                    }
                }

                if coordinator.legacyAgentActive {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("The old launchd agent from the script version is still running.")
                                .font(.callout)
                            Text("It would work through the same folders in parallel — everything would go up twice.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Disable") { coordinator.disableLegacyAgent() }
                    }
                }
            }

            Section("Behavior") {
                Toggle("Start at login", isOn: Binding(
                    get: { store.settings.launchAtLogin },
                    set: { setLoginItem($0) }))
                Toggle("Show notifications", isOn: $store.settings.notify)
                Toggle("Move uploaded files to “Uploaded”",
                       isOn: $store.settings.keepUploaded)
                if store.settings.keepUploaded {
                    LabeledContent("Clean up “Uploaded”") {
                        HStack {
                            Stepper(value: $store.settings.cleanupUploadedDays, in: 0...365, step: 5) {
                                Text(store.settings.cleanupUploadedDays == 0
                                     ? String(localized: "never")
                                     : String(format: String(localized: "after %lld days"),
                                              Int(store.settings.cleanupUploadedDays)))
                            }
                        }
                    }
                }
                LabeledContent("Size limit") {
                    Stepper(value: $store.settings.maxMB, in: 5...500, step: 5) {
                        Text(String(format: String(localized: "%lld MB per file"), Int(store.settings.maxMB)))
                    }
                }
                LabeledContent("Language") {
                    Picker("", selection: Binding(
                        get: { store.settings.language },
                        set: { chooseLanguage($0) })) {
                            Text("System default").tag(AppLanguage.system)
                            Text(verbatim: "English").tag(AppLanguage.english)
                            Text(verbatim: "Deutsch").tag(AppLanguage.german)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                }
                LabeledContent("Default destination folder") {
                    TextField("", text: $store.settings.defaultTargetFolder, prompt: Text("/Inbox"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
            }

            Section("Converters") {
                ConverterRow(name: "LibreOffice", detail: "Office documents → PDF",
                             path: $store.settings.sofficePath)
                ConverterRow(name: "Calibre", detail: "Text, HTML, MOBI → EPUB",
                             path: $store.settings.ebookConvertPath)
                LabeledContent("sips") {
                    HStack(spacing: 8) {
                        StatusDot(ok: true)
                        Text("Images → PDF, part of macOS").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPairing) { PairingSheet() }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            coordinator.refreshStatus()
            coordinator.checkRmapiVersion()
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
                    .help(String(format: String(localized: "GitHub has %@ — “Update” fetches it."), latest))
            } else if RmapiClient.isInstalled {
                Text("up to date")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(String(format: String(localized: "Latest version on GitHub: %@"), latest))
            } else {
                Text(String(format: String(localized: "available: %@"), latest))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func install() {
        isInstalling = true
        installMessage = String(localized: "Starting…")
        Task {
            do {
                let version = try await RmapiClient.install { message in
                    Task { @MainActor in installMessage = message }
                }
                await MainActor.run {
                    installMessage = String(format: String(localized: "Ready: %@"), version)
                    isInstalling = false
                    coordinator.refreshStatus()
                    coordinator.applySettings()
                }
                Log.shared.info(String(format: String(localized: "rmapi installed: %@"), version))
            } catch {
                await MainActor.run {
                    installMessage = ""
                    isInstalling = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Die Sprache greift erst beim naechsten Start — deshalb gleich anbieten,
    /// die App neu zu starten.
    private func chooseLanguage(_ language: AppLanguage) {
        guard language != store.settings.language else { return }
        store.settings.language = language
        store.saveNow()
        LanguageOverride.apply(language)

        let alert = NSAlert()
        alert.messageText = String(localized: "Restart to switch the language")
        alert.informativeText = String(localized: "Remacable reads the language at launch. Restart now?")
        alert.addButton(withTitle: String(localized: "Restart now"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            LanguageOverride.restartApp()
        }
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            store.settings.launchAtLogin = enabled
        } catch {
            errorMessage = String(format: String(localized: "Could not set the login item: %@"),
                                  error.localizedDescription)
        }
    }
}

struct ConverterRow: View {
    let name: String
    let detail: LocalizedStringKey
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
                Button("Choose…") { choose() }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = String(format: String(localized: "Choose the %@ application"), name)
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
            Text("Pair with reMarkable").font(.headline)
            Text("""
                 Get the 8-character one-time code from my.remarkable.com and enter it here. \
                 The app then registers as an additional device; you can revoke that connection \
                 in your account at any time.
                 """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button("Open code page") { NSWorkspace.shared.open(RmapiClient.connectURL) }

            TextField("e.g. abcdefgh", text: $code)
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
                Button("Cancel") { dismiss() }
                Button("Pair") { pair() }
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
                    Log.shared.success(String(localized: "Account paired"))
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
