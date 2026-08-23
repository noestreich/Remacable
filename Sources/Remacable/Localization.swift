import Foundation

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case english
    case german

    var id: String { rawValue }

    var localizationCode: String {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.lowercased().hasPrefix("de") ? "de" : "en"
        case .english:
            return "en"
        case .german:
            return "de"
        }
    }

    var displayName: String {
        switch self {
        case .system: return tr("language.system")
        case .english: return "English"
        case .german: return "Deutsch"
        }
    }
}

enum Localization {
    private static let lock = NSLock()
    private static var selectedLanguage = AppLanguage.system
    private static let resources: Bundle = {
        let bundleName = "Remacable_Remacable.bundle"
        let installedURL = Bundle.main.resourceURL?.appendingPathComponent(bundleName)
        if let installedURL, let bundle = Bundle(url: installedURL) { return bundle }
        return Bundle.module
    }()

    static func use(_ language: AppLanguage) {
        lock.lock()
        selectedLanguage = language
        lock.unlock()
    }

    static func text(_ key: String, arguments: [CVarArg] = []) -> String {
        lock.lock()
        let code = selectedLanguage.localizationCode
        lock.unlock()

        guard let bundle = localizationBundle(for: code) else {
            return key
        }

        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: code), arguments: arguments)
    }

    static func localizationBundle(for code: String) -> Bundle? {
        guard let path = resources.path(forResource: code, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}

func tr(_ key: String, _ arguments: CVarArg...) -> String {
    Localization.text(key, arguments: arguments)
}
