// GS-STORE-003 -- actual message-store upgrades must not DROP durable tables.
//
// The audit reproduced it behaviourally ("The Swift acceptance probe persists a real row, closes the store,
// sets user_version=1 while retaining compatible DDL, and reopens. The held row disappears") and confirmed
// it by source ("both production upgrade methods execute DROP TABLE"). The behavioural arm needeth the
// store's own persist API; THESE arms assert the two source facts the audit confirmed, and they are RED
// while the destructive path is the one bound to onUpgrade.
import XCTest
import Foundation
@testable import GodstoneMesh
@testable import GodstoneCore

final class ReadinessStore003Tests: XCTestCase {

    /// W01 -- the VERSIONED upgrade path may not drop durable tables.
    func testW01TheVersionedUpgradeDothNotDropDurableTables() throws {
        let source = try storeSource()
        let upgrade = try upgradeBody(source)
        XCTAssertFalse(upgrade.contains("DROP TABLE"),
                       "the production onUpgrade executeth DROP TABLE: a versioned reopen loseth the "
                       + "held rows the store existeth to keep (GS-STORE-003)")
    }

    /// W02 -- the migration engine that REPLACES the drop path must be the one BOUND to onUpgrade.
    func testW02TheMigrationEngineIsBoundToTheUpgrade() throws {
        let source = try storeSource()
        XCTAssertTrue(source.contains("SchemaMigration"),
                      "MessageStore must bind the non-destructive SchemaMigration engine to onUpgrade; "
                      + "its own contract sayeth 'the engine is what the runtime binds onUpgrade to once "
                      + "installs must survive' (GS-STORE-003)")
    }

    /// W03 -- the destructive path may survive ONLY for the never-shipped pre-ship case, and must SAY so.
    func testW03TheDestructivePathIsNamedAndBounded() throws {
        let source = try storeSource()
        if source.contains("DROP TABLE") {
            XCTAssertTrue(source.contains("pre-ship") || source.contains("never-shipped"),
                          "a destructive path that surviveth must be NAMED as the never-shipped "
                          + "pre-ship case, not left as the ordinary versioned road (GS-STORE-003)")
        }
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

    private func storeSource() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(
            "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift"), encoding: .utf8)
    }

    /// The body of the production upgrade method, from its declaration to the next top-level brace.
    private func upgradeBody(_ source: String) throws -> String {
        guard let start = source.range(of: "private func runMigrations(") else {
            // the method was RENAMED: that is itself worth failing on, because this arm addressth it BY NAME
            XCTFail("the versioned migration method is not called runMigrations(_:) any more: "
                    + "re-point this arm at its new name rather than skipping (GS-STORE-003)")
            return ""
        }
        let tail = source[start.lowerBound...]
        var depth = 0
        var body = ""
        for character in tail {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            body.append(character)
            if depth == 0 && body.contains("{") { break }
        }
        return body
    }
}
