import XCTest
@testable import Remacable

final class LocalizationTests: XCTestCase {
    override func tearDown() {
        Localization.use(.system)
        super.tearDown()
    }

    func testEnglishAndGermanCatalogsResolveTheSameKeys() throws {
        let english = try localizationKeys(for: "en")
        let german = try localizationKeys(for: "de")

        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(english, german)
    }

    func testLanguageSelectionChangesTextAndFormatsArguments() {
        Localization.use(.english)
        XCTAssertEqual(tr("status.ready"), "Ready")
        XCTAssertEqual(tr("status.uploading.many", 3), "Uploading 3 files…")

        Localization.use(.german)
        XCTAssertEqual(tr("status.ready"), "Bereit")
        XCTAssertEqual(tr("status.uploading.many", 3), "Lade 3 Dateien hoch …")
    }

    func testLegacySettingsWithoutLanguageKeepTheirValues() throws {
        let json = #"{"watchingEnabled":false,"maxMB":75}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertFalse(settings.watchingEnabled)
        XCTAssertEqual(settings.maxMB, 75)
        XCTAssertEqual(settings.language, .system)
        XCTAssertFalse(settings.sources.isEmpty)
    }

    func testLanguageSelectionPersists() throws {
        var settings = AppSettings()
        settings.language = .german

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.language, .german)
    }

    private func localizationKeys(for code: String) throws -> Set<String> {
        let bundle = try XCTUnwrap(Localization.localizationBundle(for: code))
        let stringsPath = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
        let dictionary = try XCTUnwrap(NSDictionary(contentsOf: stringsPath) as? [String: String])
        return Set(dictionary.keys)
    }
}
