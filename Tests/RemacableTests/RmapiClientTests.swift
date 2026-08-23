import XCTest
@testable import Remacable

final class RmapiClientTests: XCTestCase {
    func testEnsureFolderWaitsUntilCreatedFolderIsVisible() throws {
        var commands: [[String]] = []
        var checksAfterCreation = 0

        let listing = try RmapiClient.ensureFolder(
            "/Inbox",
            command: { arguments, _ in
                commands.append(arguments)
                switch arguments {
                case ["stat", "/Inbox"] where commands.count == 1:
                    throw commandFailure("file doesn't exist")
                case ["mkdir", "/Inbox"]:
                    return ""
                case ["stat", "/Inbox"]:
                    checksAfterCreation += 1
                    if checksAfterCreation < 2 {
                        throw commandFailure("file doesn't exist")
                    }
                    return #"{"Type":"CollectionType"}"#
                case ["ls", "/Inbox"]:
                    return "[f]\tDocument.pdf\n"
                default:
                    XCTFail("Unexpected command: \(arguments)")
                    return ""
                }
            },
            wait: { _ in })

        XCTAssertEqual(listing, "[f]\tDocument.pdf\n")
        XCTAssertEqual(commands, [
            ["stat", "/Inbox"],
            ["mkdir", "/Inbox"],
            ["stat", "/Inbox"],
            ["stat", "/Inbox"],
            ["ls", "/Inbox"]
        ])
    }

    func testEnsureFolderPropagatesVerificationFailure() {
        var statCount = 0

        XCTAssertThrowsError(try RmapiClient.ensureFolder(
            "/Inbox",
            command: { arguments, _ in
                if arguments.first == "mkdir" { return "" }
                if arguments == ["stat", "/Inbox"] {
                    statCount += 1
                    throw commandFailure(statCount == 1 ? "file doesn't exist" : "cloud unavailable")
                }
                return ""
            },
            wait: { _ in })) { error in
                XCTAssertTrue(error.localizedDescription.contains("cloud unavailable"))
            }
    }

    func testEnsureFolderRejectsDocumentWithSameName() {
        var commands: [[String]] = []

        XCTAssertThrowsError(try RmapiClient.ensureFolder(
            "/Inbox",
            command: { arguments, _ in
                commands.append(arguments)
                return #"{"Type":"DocumentType"}"#
            },
            wait: { _ in })) { error in
                XCTAssertTrue(error.localizedDescription.contains("ist ein Dokument"))
            }

        XCTAssertEqual(commands, [["stat", "/Inbox"]])
    }

    func testPutRepairsMissingFolderAndRetriesOnce() throws {
        let file = URL(fileURLWithPath: "/tmp/Document.pdf")
        var commands: [[String]] = []
        var putCount = 0

        try RmapiClient.put(
            file: file,
            folder: "/Inbox",
            command: { arguments, _ in
                commands.append(arguments)
                if arguments.first == "put" {
                    putCount += 1
                    if putCount == 1 { throw commandFailure("directory doesn't exist") }
                }
                if arguments == ["stat", "/Inbox"] { return #"{"Type":"CollectionType"}"# }
                return ""
            },
            wait: { _ in })

        XCTAssertEqual(putCount, 2)
        XCTAssertEqual(commands, [
            ["put", file.path, "/Inbox"],
            ["stat", "/Inbox"],
            ["ls", "/Inbox"],
            ["put", file.path, "/Inbox"]
        ])
    }

    func testPutDoesNotRetryUnrelatedFailure() {
        var putCount = 0

        XCTAssertThrowsError(try RmapiClient.put(
            file: URL(fileURLWithPath: "/tmp/Document.pdf"),
            folder: "/Inbox",
            command: { _, _ in
                putCount += 1
                throw commandFailure("authentication failed")
            },
            wait: { _ in }))

        XCTAssertEqual(putCount, 1)
    }

    func testCloudUploadRoundTripWhenConfigured() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["REMACABLE_CLOUD_TEST_FOLDER"],
              let filePath = environment["REMACABLE_CLOUD_TEST_FILE"] else {
            throw XCTSkip("Set REMACABLE_CLOUD_TEST_FOLDER and REMACABLE_CLOUD_TEST_FILE to run")
        }

        let file = URL(fileURLWithPath: filePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertThrowsError(try RmapiClient.run(["stat", folder], timeout: 120))
        defer { _ = try? RmapiClient.run(["rm", "-r", folder], timeout: 120) }

        try RmapiClient.put(file: file, folder: folder)

        let entries = try RmapiClient.entries(in: folder)
        XCTAssertTrue(entries.contains(file.deletingPathExtension().lastPathComponent))
    }

    private func commandFailure(_ output: String) -> ProcessError {
        .failed(command: "rmapi", status: 1, output: output)
    }
}
