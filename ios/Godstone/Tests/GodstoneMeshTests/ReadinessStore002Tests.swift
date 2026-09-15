// GS-STORE-002 -- the iOS private stores must be opened through the ENCRYPTED factory, with the
// per-install DEK applied. The audit reproduced the opposite: "AuditStorageTests writes through actual
// SqliteMessageStore. The resulting file has the SQLite format 3 header, and stock unkeyed sqlite3 can
// prepare SELECT payload FROM held_frames. MeshRuntime still instantiates both old stores."
import XCTest
import Foundation
@testable import GodstoneMesh
@testable import GodstoneCore

final class ReadinessStore002Tests: XCTestCase {

    /// W01 -- THE FINDING'S CORE: the runtime must obtain its stores through the factory.
    func testW01TheRuntimeOpenethItsStoresThroughTheEncryptedFactory() throws {
        let source = try runtimeSource()
        XCTAssertTrue(source.contains("EncryptedStoreFactory"),
                      "MeshRuntime must compose its private stores through EncryptedStoreFactory, so "
                      + "the per-install DEK is applied; today it constructeth SqliteMessageStore and "
                      + "SqlitePeerIdentityStore directly (GS-STORE-002)")
        XCTAssertTrue(source.contains("encryptedStores"),
                      "and the factory must be a SEAM the composition carrieth, so a caller cannot "
                      + "compose private stores without saying how they are encrypted")
        XCTAssertTrue(source.contains("reopenExisting("),
                      "the runtime must ASK the factory for the at-rest verdict before opening a store")
    }

    /// W02 -- the seam REFUSETH a plain database: a store opened without its DEK is not a private store.
    func testW02TheFactoryRefusethAPlainDatabaseWithoutItsDEK() throws {
        let source = try factorySource()
        XCTAssertTrue(source.contains("reopenRequiringDEK"),
                      "the factory's reopen road must REQUIRE the DEK, so a plain file cannot be "
                      + "mistaken for a private store")
        XCTAssertTrue(source.contains("wrongKey"),
                      "and a file that cannot be decrypted must be a named refusal, never a silent open")
    }

    /// W03 -- the protection errors may not be SWALLOWED on the composition road.
    func testW03TheCompositionCarriethNoSwallowedProtectionError() throws {
        let source = try runtimeSource()
        // an EMPTY line spliteth to NOTHING, and `[0]` on nothing is the crash this court already
        // suffered once: the strip is guarded rather than assumed
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let cut = line.firstIndex(of: "/") else { return line }
                return line[line.startIndex..<cut]
            }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("try? SqliteMessageStore"),
                       "a store that cannot be opened under its DEK must REFUSE, never be swallowed")
        XCTAssertFalse(code.contains("try? SqlitePeerIdentityStore"))
    }

    private func repoRoot() -> URL {
        var repo = URL(fileURLWithPath: #filePath)
        var hops = 0
        while repo.path != "/" && hops < 12 {
            if FileManager.default.fileExists(atPath: repo.appendingPathComponent("android").path) { break }
            repo.deleteLastPathComponent(); hops += 1
        }
        return repo
    }

    private func runtimeSource() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(
            "ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift"), encoding: .utf8)
    }

    private func factorySource() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(
            "ios/Godstone/Sources/GodstoneMesh/EncryptedStoreFactory.swift"), encoding: .utf8)
    }
}
