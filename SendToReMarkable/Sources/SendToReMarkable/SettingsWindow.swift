import SwiftUI
import AppKit

struct SettingsWindow: View {
    // S2R_TAB waehlt beim Start einen Reiter — praktisch zum Nachschauen
    @State private var tab = ProcessInfo.processInfo.environment["S2R_TAB"] ?? "allgemein"
    var body: some View {
        TabView(selection: $tab) {
            GeneralTab()
                .tabItem { Label("Allgemein", systemImage: "gearshape") }.tag("allgemein")
            FoldersTab()
                .tabItem { Label("Ordner", systemImage: "folder") }.tag("ordner")
            LogTab()
                .tabItem { Label("Protokoll", systemImage: "list.bullet.rectangle") }.tag("protokoll")
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
            Section("Einrichtung") {
                LabeledContent("rmapi") {
                    HStack(spacing: 8) {
                        StatusDot(ok: RmapiClient.isInstalled)
                        Text(coordinator.rmapiVersion ?? "nicht installiert")
                            .foregroundStyle(RmapiClient.isInstalled ? .primary : .secondary)
                        Spacer()
                        Button(RmapiClient.isInstalled ? "Aktualisieren" : "Installieren") {
                            install()
                        }
                        .disabled(isInstalling)
                    }
                }
                if !installMessage.isEmpty {
                    Text(installMessage).font(.caption).foregroundStyle(.secondary)
                }

                LabeledContent("Konto") {
                    HStack(spacing: 8) {
                        StatusDot(ok: coordinator.isPaired)
                        Text(coordinator.isPaired ? "gekoppelt" : "nicht gekoppelt")
                        Spacer()
                        if coordinator.isPaired {
                            Button("Kopplung lösen") {
                                RmapiClient.unpair()
                                coordinator.refreshStatus()
                            }
                        }
                        Button("Koppeln …") { showPairing = true }
                            .disabled(!RmapiClient.isInstalled)
                    }
                }

                if coordinator.legacyAgentActive {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Der alte launchd-Agent der Skript-Fassung läuft noch.")
                                .font(.callout)
                            Text("Er würde dieselben Ordner parallel abarbeiten — alles ginge doppelt hoch.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Deaktivieren") { coordinator.disableLegacyAgent() }
                    }
                }
            }

            Section("Verhalten") {
                Toggle("Beim Anmelden starten", isOn: Binding(
                    get: { store.settings.launchAtLogin },
                    set: { setLoginItem($0) }))
                Toggle("Benachrichtigungen anzeigen", isOn: $store.settings.notify)
                Toggle("Hochgeladene Dateien nach „Uploaded“ verschieben",
                       isOn: $store.settings.keepUploaded)
                if store.settings.keepUploaded {
                    LabeledContent("„Uploaded“ aufräumen") {
                        HStack {
                            Stepper(value: $store.settings.cleanupUploadedDays, in: 0...365, step: 5) {
                                Text(store.settings.cleanupUploadedDays == 0
                                     ? "nie"
                                     : "nach \(Int(store.settings.cleanupUploadedDays)) Tagen")
                            }
                        }
                    }
                }
                LabeledContent("Größenlimit") {
                    Stepper(value: $store.settings.maxMB, in: 5...500, step: 5) {
                        Text("\(Int(store.settings.maxMB)) MB pro Datei")
                    }
                }
                LabeledContent("Standard-Zielordner") {
                    TextField("", text: $store.settings.defaultTargetFolder, prompt: Text("/Inbox"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
            }

            Section("Konverter") {
                ConverterRow(name: "LibreOffice", detail: "Office-Dokumente → PDF",
                             path: $store.settings.sofficePath)
                ConverterRow(name: "Calibre", detail: "Text, HTML, MOBI → EPUB",
                             path: $store.settings.ebookConvertPath)
                LabeledContent("sips") {
                    HStack(spacing: 8) {
                        StatusDot(ok: true)
                        Text("Bilder → PDF, Teil von macOS").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPairing) { PairingSheet() }
        .alert("Fehler", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear { coordinator.refreshStatus() }
    }

    private func install() {
        isInstalling = true
        installMessage = "Starte …"
        Task {
            do {
                let version = try await RmapiClient.install { message in
                    Task { @MainActor in installMessage = message }
                }
                await MainActor.run {
                    installMessage = "Bereit: \(version)"
                    isInstalling = false
                    coordinator.refreshStatus()
                    coordinator.applySettings()
                }
                Log.shared.info("rmapi installiert: \(version)")
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
            errorMessage = "Anmeldeobjekt ließ sich nicht setzen: \(error.localizedDescription)"
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
                Button("Wählen …") { choose() }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "\(name)-Programm auswählen"
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
            Text("Mit reMarkable koppeln").font(.headline)
            Text("""
                 Hol dir den 8-stelligen Einmalcode von my.remarkable.com und trag ihn hier ein. \
                 Die App meldet sich damit als zusätzliches Gerät an; du kannst die Verbindung \
                 in deinem Konto jederzeit wieder entziehen.
                 """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button("Code-Seite öffnen") { NSWorkspace.shared.open(RmapiClient.connectURL) }

            TextField("z. B. abcdefgh", text: $code)
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
                Button("Abbrechen") { dismiss() }
                Button("Koppeln") { pair() }
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
                    Log.shared.success("Konto gekoppelt")
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
