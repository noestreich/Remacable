import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

@main
struct SendToReMarkableApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Die App lebt in der Menueleiste; das Statusobjekt haengt am AppDelegate,
        // weil nur so das Symbol selbst Dateien annehmen kann.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            StatusItemController.shared.install()
            Coordinator.shared.start()
            // S2R_OPEN_MENU klappt das Menü beim Start auf — zum Nachschauen.
            if ProcessInfo.processInfo.environment["S2R_OPEN_MENU"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    StatusItemController.shared.togglePopover()
                }
                return
            }
            // Beim ersten Start direkt in die Einrichtung — ohne rmapi geht nichts.
            // S2R_TAB oeffnet das Fenster ebenfalls, mit vorgewaehltem Reiter.
            if !RmapiClient.isInstalled || ProcessInfo.processInfo.environment["S2R_TAB"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    SettingsWindowController.shared.show()
                }
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

// MARK: - Statusobjekt in der Menueleiste

@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var subscription: AnyCancellable?

    /// Eigenes Symbol als Template: macOS faerbt es passend zur Menueleiste ein,
    /// hell auf dunkel und umgekehrt.
    private lazy var icon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url), image.size.height > 0 else {
            // Notnagel, falls die Ressource fehlt
            let fallback = NSImage(systemSymbolName: "paperplane",
                                   accessibilityDescription: "Send to reMarkable")
            fallback?.isTemplate = true
            return fallback
        }
        let height: CGFloat = 16
        image.size = NSSize(width: (image.size.width / image.size.height) * height, height: height)
        image.isTemplate = true
        return image
    }()

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.toolTip = "Send to reMarkable — Dateien auf dieses Symbol ziehen"
            // Der Knopf selbst reagiert auf Klicks …
            button.target = self
            button.action = #selector(handleClick)
            // … und darueber liegt die Ebene, die Dateien annimmt. Je nachdem,
            // wer den Klick bekommt, landet er am selben Handler.
            let drop = StatusDropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.onClick = { [weak self] in self?.togglePopover() }
            drop.onHighlight = { [weak button] active in button?.highlight(active) }
            drop.onDrop = { urls in UploadEngine.shared.send(files: urls) }
            button.addSubview(drop)
        }

        updateIcon(watching: Coordinator.shared.isWatching)
        subscription = Coordinator.shared.$isWatching.sink { [weak self] watching in
            Task { @MainActor in self?.updateIcon(watching: watching) }
        }
    }

    @objc private func handleClick() {
        togglePopover()
    }

    private func updateIcon(watching: Bool) {
        statusItem?.button?.image = icon
        // Abgeschaltete Ueberwachung: blasses Symbol, wie bei Systemobjekten
        statusItem?.button?.appearsDisabled = !watching
    }

    func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let popover = self.popover ?? makePopover()
        self.popover = popover
        Coordinator.shared.refreshStatus()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: MenuView()
                .environmentObject(SettingsStore.shared)
                .environmentObject(Coordinator.shared)
                .environmentObject(UploadEngine.shared))
        return popover
    }

    func closePopover() { popover?.performClose(nil) }
}

/// Unsichtbare Ebene ueber dem Menueleisten-Knopf: sie faengt den Klick ab und
/// nimmt Dateien an, die man auf das Symbol zieht.
final class StatusDropView: NSView {
    var onClick: (() -> Void)?
    var onDrop: (([URL]) -> Void)?
    var onHighlight: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("nicht unterstützt") }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        onHighlight?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHighlight?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHighlight?(false)
        let files = fileURLs(from: sender)
        guard !files.isEmpty else { return false }
        onDrop?(files)
        return true
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL]) ?? []
    }
}

// MARK: - Einstellungsfenster

/// Selbst verwaltet statt ueber die `Settings`-Szene: bei einer Menueleisten-App
/// ohne Menue greift `showSettingsWindow:` nicht zuverlaessig.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsWindow()
                    .environmentObject(SettingsStore.shared)
                    .environmentObject(Coordinator.shared)
                    .environmentObject(UploadEngine.shared))
            let created = NSWindow(contentViewController: hosting)
            created.title = "Send to reMarkable"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 640, height: 540))
            created.contentMinSize = NSSize(width: 520, height: 400)
            created.isReleasedWhenClosed = false
            created.setFrameAutosaveName("SettingsWindow")  // Groesse und Position merken
            created.delegate = self
            created.center()
            window = created
        }
        Coordinator.shared.refreshStatus()
        Coordinator.shared.settingsDidOpen()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Coordinator.shared.settingsDidClose()
    }
}

// MARK: - Menue

struct MenuView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var coordinator: Coordinator
    @EnvironmentObject private var engine: UploadEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !RmapiClient.isInstalled || !coordinator.isPaired {
                setupHint
            } else {
                Toggle("Überwachung aktiv", isOn: Binding(
                    get: { settings.settings.watchingEnabled },
                    set: { coordinator.setWatching($0) }))
                .toggleStyle(.switch)
                .padding(.horizontal, 8)

                Label("Dateien lassen sich direkt auf das Symbol in der Menüleiste ziehen.",
                      systemImage: "arrow.up.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }

            Divider()

            VStack(alignment: .leading, spacing: 1) {
                MenuRow(title: "Dateien auswählen …", systemImage: "doc.badge.plus",
                        enabled: coordinator.isPaired) { chooseFiles() }
                MenuRow(title: "Jetzt prüfen", systemImage: "arrow.clockwise",
                        enabled: coordinator.isPaired && !engine.isBusy) {
                    StatusItemController.shared.closePopover()
                    UploadEngine.shared.scanAll(reason: "manuell")
                }
                MenuRow(title: "Watch-Ordner öffnen", systemImage: "folder") { openInbox() }
            }

            Divider()

            VStack(alignment: .leading, spacing: 1) {
                MenuRow(title: "Einstellungen …", systemImage: "gearshape") {
                    StatusItemController.shared.closePopover()
                    SettingsWindowController.shared.show()
                }
                MenuRow(title: "Beenden", systemImage: "power") { NSApp.terminate(nil) }
            }
        }
        .padding(10)
        .frame(width: 290)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(coordinator.isWatching ? "Überwachung läuft" : "Überwachung aus")
                    .font(.headline)
                if engine.isBusy { ProgressView().controlSize(.small) }
            }
            Text(engine.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private var statusColor: Color {
        if !coordinator.isPaired { return .orange }
        return coordinator.isWatching ? .green : .secondary
    }

    private var setupHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(RmapiClient.isInstalled ? "Konto noch nicht gekoppelt" : "Noch nicht eingerichtet")
                .font(.callout.weight(.medium))
            Text("In den Einstellungen einrichten — das dauert eine Minute.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func chooseFiles() {
        StatusItemController.shared.closePopover()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Dateien ans reMarkable schicken"
        if panel.runModal() == .OK {
            UploadEngine.shared.send(files: panel.urls)
        }
    }

    private func openInbox() {
        StatusItemController.shared.closePopover()
        let path = settings.settings.sources.first?.url ?? Paths.defaultInbox
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(path)
    }
}

/// Zeile im Menue — sieht aus wie ein Menueeintrag, inklusive Hervorhebung.
struct MenuRow: View {
    let title: String
    let systemImage: String
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).frame(width: 16)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(hovering && enabled ? Color.primary.opacity(0.09) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}
