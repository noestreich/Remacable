import Foundation

/// Das reMarkable kann nur PDF und EPUB — alles andere wird vorher konvertiert.
struct Converter {
    let sofficePath: String
    let ebookConvertPath: String

    static let passthrough: Set<String> = ["pdf", "epub"]
    static let office: Set<String> = ["doc", "docx", "rtf", "odt", "ott", "xls", "xlsx",
                                      "csv", "ods", "ppt", "pptx", "odp"]
    static let ebook: Set<String> = ["mobi", "azw", "azw3", "fb2", "lit", "pdb",
                                     "htm", "html", "txt", "md", "markdown"]
    static let image: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif",
                                     "tiff", "gif", "bmp", "webp"]
    /// Halbfertige Downloads und Zwischenstaende wie "datei.tmp.pdf"
    static let skipSuffixes: Set<String> = ["part", "crdownload", "download", "tmp", "partial"]

    static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return passthrough.contains(ext) || office.contains(ext)
            || ebook.contains(ext) || image.contains(ext)
    }

    static func shouldSkip(_ url: URL) -> Bool {
        let parts = url.lastPathComponent.split(separator: ".").dropFirst().map { $0.lowercased() }
        return !Set(parts).isDisjoint(with: skipSuffixes) || url.lastPathComponent.hasPrefix(".")
    }

    /// Liefert die hochzuladende Datei (PDF oder EPUB) im Arbeitsverzeichnis.
    func convert(_ source: URL, workDir: URL) throws -> URL {
        let ext = source.pathExtension.lowercased()

        if Converter.passthrough.contains(ext) { return source }

        if Converter.office.contains(ext) {
            guard FileManager.default.isExecutableFile(atPath: sofficePath) else {
                throw ConversionError.toolMissing("LibreOffice")
            }
            // Eigenes Profil, sonst scheitert der Aufruf bei geoeffnetem LibreOffice
            let profile = workDir.appendingPathComponent("loprofile")
            _ = try? ProcessRunner.run(sofficePath, [
                "-env:UserInstallation=file://\(profile.path)", "--headless",
                "--convert-to", "pdf", "--outdir", workDir.path, source.path,
            ], timeout: 900)
            let out = workDir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".pdf")
            guard FileManager.default.fileExists(atPath: out.path) else {
                throw ConversionError.failed(tr("error.convert.libreoffice", source.lastPathComponent))
            }
            return out
        }

        if Converter.ebook.contains(ext) {
            guard FileManager.default.isExecutableFile(atPath: ebookConvertPath) else {
                throw ConversionError.toolMissing("Calibre")
            }
            let out = workDir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".epub")
            _ = try? ProcessRunner.run(ebookConvertPath, [source.path, out.path], timeout: 900)
            guard FileManager.default.fileExists(atPath: out.path) else {
                throw ConversionError.failed(tr("error.convert.calibre", source.lastPathComponent))
            }
            return out
        }

        if Converter.image.contains(ext) {
            let out = workDir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".pdf")
            _ = try? ProcessRunner.run("/usr/bin/sips",
                                       ["-s", "format", "pdf", source.path, "--out", out.path],
                                       timeout: 300)
            guard FileManager.default.fileExists(atPath: out.path) else {
                throw ConversionError.failed(tr("error.convert.image", source.lastPathComponent))
            }
            return out
        }

        throw ConversionError.unsupported(ext.isEmpty ? tr("error.convert.no_extension") : ext)
    }
}

enum ConversionError: LocalizedError {
    case unsupported(String)
    case toolMissing(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): return tr("error.convert.unsupported", ext)
        case .toolMissing(let tool): return tr("error.convert.tool_missing", tool)
        case .failed(let message): return message
        }
    }
}
