import XCTest
import Foundation
import SQLite3
@testable import GodstoneCore

/* ============================================================================
 T51 (s17) -- the designated regression court for resource intake and
 installable bundle metadata.

 The witnesses walk two roads: the pure functions of ReleaseIntake (names,
 metadata, the two faces of the generated manifest) and the REAL repository
 road, where a planted sibling file lies just outside the sanctioned archives
 directory and the forgeard name that would reach it is refused before the
 filesystem is ever consulted -- the very escape the guard existeth to
 prevent, provéd here by a file that doth truly exist.

 The committed artifacts themselves are inspected: ios/project.yml must be
 source-only (no absent resource reference, no optional: true phantom, and
 every listed path站立 upon the disk), and ios/Godstone/Info.plist must be
 installable (every key the launchservices require, sworn by the metadata
 law after the build's own substitutions are applied -- the settings are
 extracted from the committed project.yml, not hard-coded, that manifest
 and build shall never disagree in the court's mouth).
 ============================================================================ */

@MainActor
final class ReadinessT51Tests: XCTestCase {
    private enum TestError: Error { case fixtureNotFound(String), noSupportDirectory }

    // MARK: - the walkers (the T48 idiom, reseeded whole)

    private func repoFile(named relative: String) throws -> String {
        var dir = FileManager.default.currentDirectoryPath
        for _ in 0..<8 {
            let candidate = dir + "/" + relative
            if FileManager.default.fileExists(atPath: candidate) {
                return try String(contentsOfFile: candidate, encoding: .utf8)
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty || parent == "/" { break }
            dir = parent
        }
        XCTFail("the committed artifact \(relative) could not be found above \(dir)")
        throw TestError.fixtureNotFound(relative)
    }

    private func repoRoot() -> String {
        var dir = FileManager.default.currentDirectoryPath
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir + "/ios/project.yml") { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty || parent == "/" { break }
            dir = parent
        }
        XCTFail("no repository root bearing ios/project.yml could be found")
        return dir
    }

    private func between(_ s: String, _ open: String, _ close: String) -> String {
        let tail = s.components(separatedBy: open).last ?? ""
        return tail.components(separatedBy: close).first ?? ""
    }

    /// The committed Info.plist, read with the grammar it was written in:
    /// one <key>…</key><string>…</string> pair per line, multi-line <array>
    /// of <string>, standalone <key> before <array>/<dict>/<true/>, and the
    /// inline <array><string>…</string></array> form. A reader of the court's
    /// own: the property-list family hides behind a pointer-shaped veil, and
    /// the bytes shall be judged as they lie.
    private func readInfoPlist(_ text: String) -> [String: Any] {
        var out: [String: Any] = [:]
        var pendingKey: String?
        var collectingKey: String?
        var collected: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("<key>") && line.hasSuffix("</key>") {
                pendingKey = between(line, "<key>", "</key>")
                continue
            }
            if line.contains("<key>") && line.contains("<string>") {
                out[between(line, "<key>", "</key>")] = between(line, "<string>", "</string>")
                pendingKey = nil
                continue
            }
            if line.contains("<key>") && line.contains("<true") {
                let k = between(line, "<key>", "</key>")
                if !k.isEmpty { out[k] = true }
                pendingKey = nil
                continue
            }
            if line.contains("<key>") && line.contains("<dict") {
                let k = between(line, "<key>", "</key>")
                if !k.isEmpty { out[k] = [String: Any]() }
                pendingKey = nil
                continue
            }
            if line == "<array>" {
                collectingKey = pendingKey; collected = []; pendingKey = nil
                continue
            }
            if line == "</array>" {
                if let k = collectingKey { out[k] = collected }
                collectingKey = nil
                continue
            }
            if collectingKey != nil, line.hasPrefix("<string>"), line.hasSuffix("</string>") {
                collected.append(between(line, "<string>", "</string>"))
                continue
            }
            if line.hasPrefix("<array>") && line.hasSuffix("</array>") {
                if let k = pendingKey { out[k] = [between(line, "<string>", "</string>")] }
                pendingKey = nil
                continue
            }
        }
        return out
    }

    /// Split on semicolons that lie outside quoted and comment regions (the
    /// frozen DDL hideth a semicolon in prose and in the tokenizer string).
    private func splitStatements(_ script: String) -> [String] {
        enum Region { case plain, lineComment, blockComment, singleQuote, doubleQuote }
        var region = Region.plain
        var statements: [String] = []
        var current = ""
        let chars = Array(script)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            let peek: Character? = (i + 1 < chars.count) ? chars[i + 1] : nil
            switch (region, ch) {
            case (.plain, "'"):
                region = .singleQuote; current.append(ch)
            case (.plain, "\""):
                region = .doubleQuote; current.append(ch)
            case (.plain, "-") where peek == "-":
                region = .lineComment; current.append(ch)
            case (.plain, "/") where peek == "*":
                region = .blockComment; current.append("/*"); i += 1
            case (.plain, ";"):
                statements.append(current); current = ""
            case (.singleQuote, "'") where peek == "'":
                current.append("''"); i += 1
            case (.singleQuote, "'"):
                region = .plain; current.append(ch)
            case (.doubleQuote, "\"") where peek == "\"":
                current.append("\"\""); i += 1
            case (.doubleQuote, "\""):
                region = .plain; current.append(ch)
            case (.lineComment, "\n"):
                region = .plain; current.append(ch)
            case (.blockComment, "*") where peek == "/":
                region = .plain; current.append("*/"); i += 1
            default:
                current.append(ch)
            }
            i += 1
        }
        statements.append(current)
        return statements
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func execStatements(_ db: OpaquePointer?, _ script: String, from origin: String) {
        for statement in splitStatements(script) {
            var err: UnsafeMutablePointer<Int8>?
            let rc = sqlite3_exec(db, statement, nil, nil, &err)
            if rc != SQLITE_OK {
                let why = err.map { String(cString: $0) ?? "?" } ?? "rc \(rc)"
                if let e = err { sqlite3_free(e) }
                XCTFail("plant DDL from \(origin) cried on \"\(String(statement.prefix(72)))…\": \(why)")
                return
            }
        }
    }

    /// A REAL archive at the given path: the FROZEN DDL executed verbatim,
    /// one document, one chunk, the sworn metadata, the indexes -- the very
    /// bytes that make the road ready. The escape probe and the ready probe
    /// are born of this one planter, that neither be a tale of convenience.
    private func plantRealArchive(at path: String) throws {
        let schema = try repoFile(named: "content/db/schema.sql")
        let indexes = try repoFile(named: "content/db/indexes.sql")
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let db else {
            XCTFail("the plant could not be opened for building: rc \(rc)")
            return
        }
        defer { sqlite3_close_v2(db) }
        execStatements(db, schema, from: "schema.sql")
        for sql in [
            "INSERT INTO documents (document_id, title, domain, source_id, licence, revision, tier_min, reading_level, is_critical) VALUES (1, 'Escape probe', 'reference', 'src-p', 'CC0', 'r1', 'LIGHT', 8, 0)",
            "INSERT INTO chunks (chunk_id, document_id, ordinal, section, text, token_count) VALUES (11, 1, 1, 'Prose', 'The quick brown fox jogs past the lazy riverbank', 9)",
            "INSERT INTO archive_meta (key, value) VALUES ('schema_version', '3')",
            "INSERT INTO archive_meta (key, value) VALUES ('built_by', 't51-court')",
        ] {
            var err: UnsafeMutablePointer<Int8>?
            let prc = sqlite3_exec(db, sql, nil, nil, &err)
            if prc != SQLITE_OK {
                let why = err.map { String(cString: $0) ?? "?" } ?? "rc \(prc)"
                if let e = err { sqlite3_free(e) }
                XCTFail("plant insert cried: \(why) on \(String(sql.prefix(72)))…")
                return
            }
        }
        execStatements(db, indexes, from: "indexes.sql")
    }

    private func supportDirectory() throws -> URL {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw TestError.noSupportDirectory
        }
        return base
    }

    // MARK: - 1 the source-only verification

    /// W1 -- the verify refuseth absent listings: a manifest that would
    /// reference what is not there is refused at the birth.
    func testTheSourceOnlyVerifyRefusethAbsentListedPaths() throws {
        let root = repoRoot() + "/ios"
        let good = ["Godstone/Info.plist", "project.yml"]
        XCTAssertNotNil(ProjectInputManifest.verifySourceOnly(listing: good, under: root),
                        "existing sources must verify")
        XCTAssertNil(ProjectInputManifest.verifySourceOnly(listing: good + ["Godstone/Nope.h"], under: root),
                     "an absent source must be refused at the birth")
        XCTAssertNil(ProjectInputManifest.verifySourceOnly(listing: [], under: root),
                     "an empty listing is no manifest")
        XCTAssertNil(ProjectInputManifest.verifySourceOnly(listing: ["/etc/passwd"], under: root),
                     "an absolute path escapeth the root and is refused")
        XCTAssertNil(ProjectInputManifest.verifySourceOnly(listing: ["Godstone/Info.plist", "Godstone/Info.plist"], under: root),
                     "a duplicate listing is a false witness")
    }

    /// W2 -- the rendering is deterministic: twice and shuffled render the
    /// very same bytes; the golden fixture is that very string.
    func testTheSourceOnlyRenderingIsDeterministicAndGolden() throws {
        let manifest = ProjectInputManifest.sourceOnly(sources: ["c.swift", "a.swift", "b.swift"])
        let first = manifest.renderedSourcesSection()
        let second = manifest.renderedSourcesSection()
        XCTAssertEqual(first, second, "the same inputs must render the same bytes")
        let shuffled = ProjectInputManifest.sourceOnly(sources: ["b.swift", "c.swift", "a.swift"])
        XCTAssertEqual(shuffled.renderedSourcesSection(), first,
                       "the order of the input may not alter the rendering")
        let golden = "    # generated by scripts/prepare_release_assets.py -- do not edit by hand\n"
            + "    - path: a.swift\n"
            + "    - path: b.swift\n"
            + "    - path: c.swift\n"
        XCTAssertEqual(first, golden, "the golden rendering must be respected, got |\(first)|")
    }

    /// W3 -- the source-only face nameth neither the Approved directory nor
    /// the optional phantom; the whole point of the defect cured.
    func testTheSourceOnlySectionReferencethNoApprovedNothing() throws {
        let rendered = ProjectInputManifest.sourceOnly(sources: ["Godstone/Info.plist"]).renderedSourcesSection()
        XCTAssertFalse(rendered.contains("Approved"), "the source-only face shall never name the Approved directory")
        XCTAssertFalse(rendered.contains("optional"), "the word optional shall never be sown")
        XCTAssertFalse(rendered.contains("$("), "no placeholder may survive into a rendering")
    }

    // MARK: - 4/5/6 the approved receipt gate

    private static let sha64 = String(repeating: "e", count: 64)
    private static let goldenReceipt = """
        {
          "application_id": "io.godstone.app",
          "assets": [
            { "build_phase": "resources", "bytes": 1234, "name": "archive_light.db",
              "role": "archive", "sha256": "\(String(repeating: "e", count: 64))" }
          ],
          "generated_by": "scripts/prepare_release_assets.py",
          "schema": 1,
          "tier": "LIGHT"
        }
        """

    /// W4 -- a true receipt of staged bytes is accepted, whole and bound.
    func testTheApprovedReceiptOfStagedBytesIsAccepted() throws {
        let data = Data(ReadinessT51Tests.goldenReceipt.utf8)
        guard let receipt = ProjectInputManifest.approved(from: data) else {
            XCTFail("a truthful receipt must pass the gate")
            return
        }
        XCTAssertEqual(receipt.schema, 1)
        XCTAssertEqual(receipt.tier, "LIGHT")
        XCTAssertEqual(receipt.assets.count, 1)
        XCTAssertEqual(receipt.assets.first?.name, "archive_light.db")
        XCTAssertEqual(receipt.assets.first?.buildPhase, "resources")
        XCTAssertEqual(receipt.assets.first?.bytes, 1234)
    }

    /// W5 -- every forgery is refused: future schema, foreign keys, wrong
    /// bindings, bad digests, two assets, traversal names.
    func testTheApprovedGateRefusethForeignReceipts() throws {
        func forge(_ edits: [(String, String)]) -> Data {
            var text = ReadinessT51Tests.goldenReceipt
            for (from, to) in edits {
                text = text.replacingOccurrences(of: from, with: to, options: [])
            }
            return Data(text.utf8)
        }
        let refusals: [(String, [(String, String)])] = [
            ("a future schema", [("\"schema\": 1", "\"schema\": 2")]),
            ("a zero schema", [("\"schema\": 1", "\"schema\": 0")]),
            ("an extra key", [("\"tier\": \"LIGHT\"", "\"tier\": \"LIGHT\", \"surprise\": 1")]),
            ("a missing key", [("\"generated_by\": \"scripts/prepare_release_assets.py\",", "")]),
            ("a mismatched role/name pair", [("\"role\": \"archive\"", "\"role\": \"generation_model\"")]),
            ("two assets", [("\"schema\": 1", "\"schema\": 1")]),   // handled below by array splice
            ("an upper-case digest", [(ReadinessT51Tests.sha64, String(repeating: "E", count: 64))]),
            ("a short digest", [(ReadinessT51Tests.sha64, String(repeating: "e", count: 63) + "z")]),
            ("a foreign tier", [("\"tier\": \"LIGHT\"", "\"tier\": \"MEDIUM\"")]),
            ("a foreign application", [("\"application_id\": \"io.godstone.app\"", "\"application_id\": \"io.evil.app\"")]),
            ("a foreign tool", [("\"generated_by\": \"scripts/prepare_release_assets.py\"", "\"generated_by\": \"by hand\"")]),
            ("negative bytes", [("\"bytes\": 1234", "\"bytes\": -1")]),
            ("a traversal name", [("\"name\": \"archive_light.db\"", "\"name\": \"../archive_light.db\"")]),
            ("a stolen build phase", [("\"build_phase\": \"resources\"", "\"build_phase\": \"sources\"")]),
        ]
        for (tale, edits) in refusals {
            if tale == "two assets" { continue }   // the splice case below, spliced with care
            XCTAssertNil(ProjectInputManifest.approved(from: forge(edits)),
                         "the gate must refuse \(tale)")
        }
        let doubled = ReadinessT51Tests.goldenReceipt.replacingOccurrences(
            of: "\"sha256\": \"\(ReadinessT51Tests.sha64)\" }",
            with: "\"sha256\": \"\(ReadinessT51Tests.sha64)\" },\n            { \"build_phase\": \"resources\", \"bytes\": 1234, \"name\": \"archive_light.db\", \"role\": \"archive\", \"sha256\": \"\(ReadinessT51Tests.sha64)\" }",
            options: [])
        XCTAssertNil(ProjectInputManifest.approved(from: Data(doubled.utf8)),
                     "the gate must refuse a receipt promising two assets")
    }

    /// W6 -- the approved face listeth precisely the staged paths, and
    /// only them; deterministic, no 'optional', the whole directory sworn.
    func testTheApprovedSectionListethTheStagedPathsAndOnlyThem() throws {
        guard let receipt = ProjectInputManifest.approved(from: Data(ReadinessT51Tests.goldenReceipt.utf8)) else {
            XCTFail("the golden receipt must pass the gate"); return
        }
        let rendered = ProjectInputManifest.approvedArchive(receipt: receipt).renderedSourcesSection()
        XCTAssertTrue(rendered.contains("- path: Godstone/Resources/Approved/archive_light.db"),
                      "the staged archive must be listed at its sanctioned place, got \(rendered)")
        XCTAssertTrue(rendered.contains("buildPhase: resources"), "the build phase must be sworn")
        XCTAssertFalse(rendered.contains("optional"), "the word optional shall never appear")
        XCTAssertEqual(rendered, ProjectInputManifest.approvedArchive(receipt: receipt).renderedSourcesSection(),
                       "the rendering must be deterministic")
    }

    // MARK: - 7 the committed artifacts, inspected as themselves

    /// W7 -- the committed project.yml is source-only upon inspection: no
    /// optional phantom, no Approved reference, every listed path standeth
    /// upon the disk, and the configurations are named truly.
    func testTheCommittedProjectManifestIsSourceOnlyUponInspection() throws {
        let yml = try repoFile(named: "ios/project.yml")
        let iosRoot = repoRoot() + "/ios"
        XCTAssertFalse(yml.contains("optional:"), "the committed manifest shall never carry the optional phantom")
        XCTAssertFalse(yml.contains("Resources/Approved"), "the committed manifest shall reference no staged directory")
        XCTAssertTrue(yml.contains("LightDebug: debug"), "the configurations must be named truly (LightDebug)")
        XCTAssertTrue(yml.contains("LightRelease: release"), "and LightRelease, not Debug nor Release")
        var listed = 0
        for line in yml.components(separatedBy: "\n") {
            let text = line.components(separatedBy: "#").first ?? ""
            guard text.contains("- path: ") else { continue }
            let path = (text.components(separatedBy: "- path: ").last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("Godstone/") else { continue }
            listed += 1
            let full = (iosRoot as NSString).appendingPathComponent(path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: full),
                          "the manifest reference \(path) must stand upon the disk")
        }
        XCTAssertGreaterThan(listed, 5, "the scan must have found the app target's listings (got \(listed))")
    }

    /// W8 -- the committed Info.plist is installable: parsed as the very
    /// XML the build embeddeth, substituted with the project's own declared
    /// PRODUCT_* settings, and judged fault-free by the metadata law.
    func testTheCommittedBundleMetadataIsInstallable() throws {
        let plistText = try repoFile(named: "ios/Godstone/Info.plist")
        let plist = readInfoPlist(plistText)
        for required in ["CFBundleExecutable", "CFBundleName", "CFBundleIdentifier",
                         "CFBundlePackageType", "CFBundleInfoDictionaryVersion",
                         "GodstoneTier", "GodstoneArchiveFile", "UILaunchScreen",
                         "UISupportedInterfaceOrientations", "UISupportedInterfaceOrientations~ipad"] {
            XCTAssertTrue(plist.keys.contains(required), "the committed plist must declare \(required)")
        }
        // extract the substitutions from the committed project.yml itself
        let yml = try repoFile(named: "ios/project.yml")
        var settings: [String: String] = [:]
        for wanted in ["PRODUCT_BUNDLE_IDENTIFIER", "PRODUCT_NAME", "EXECUTABLE_NAME"] {
            let needle = wanted + ":"
            for line in yml.components(separatedBy: "\n") {
                guard line.contains(needle) else { continue }
                var value = (line.components(separatedBy: needle).last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                value = value.replacingOccurrences(of: "\"", with: "", options: [])
                value = value.replacingOccurrences(of: "'", with: "", options: [])
                if settings[wanted] == nil { settings[wanted] = value }   // the app target cometh first
            }
        }
        // the build tool's own default: the executable beareth the target's name
        if settings["EXECUTABLE_NAME"] == nil { settings["EXECUTABLE_NAME"] = settings["PRODUCT_NAME"] }
        XCTAssertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"] ?? "", "io.godstone.app",
                       "the bundle identifier must be read from the manifest, got \(settings["PRODUCT_BUNDLE_IDENTIFIER"] ?? "nil")")
        XCTAssertFalse((settings["PRODUCT_NAME"] ?? "").isEmpty, "PRODUCT_NAME must be declared")
        let substituted = BundleMetadata.substituting(plist, settings: settings)
        let metadata = BundleMetadata(values: substituted)
        let faults = metadata.faults(tier: .light)
        XCTAssertEqual(faults, [], "the committed bundle must be installable, faults: \(faults.joined(separator: "; "))")
    }

    // MARK: - 9..13 the metadata law, witness by witness

    private func goodSubstitutedMetadata() -> [String: Any] {
        [
            "CFBundleExecutable": "Godstone",
            "CFBundleName": "Godstone",
            "CFBundleIdentifier": "io.godstone.app",
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
            "UILaunchScreen": [String: Any](),
            "GodstoneTier": "LIGHT",
            "GodstoneArchiveFile": "archive_light.db",
            "UISupportedInterfaceOrientations": [
                "UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight"],
            "UISupportedInterfaceOrientations~ipad": [
                "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        ]
    }

    /// W9 -- the card's own negative: omit CFBundleExecutable and the
    /// install gate must fail (the fault must be named, not whispered).
    func testALaunchServicesRefusethAnUnexecutableBundle() throws {
        var values = goodSubstitutedMetadata()
        values.removeValue(forKey: "CFBundleExecutable")
        let faults = BundleMetadata(values: values).faults(tier: .light)
        XCTAssertTrue(faults.contains(where: { $0.contains("CFBundleExecutable") }),
                      "the missing executable must be cried, got \(faults)")
        values["CFBundleExecutable"] = ""
        XCTAssertTrue(BundleMetadata(values: values).faults(tier: .light)
                      .contains(where: { $0.contains("CFBundleExecutable") }),
                      "an empty executable is no whitelisted bundle")
        values["CFBundleExecutable"] = "sub/Godstone"
        XCTAssertTrue(BundleMetadata(values: values).faults(tier: .light)
                      .contains(where: { $0.contains("path separator") }),
                      "a separator in the executable name must be refused")
    }

    /// W10 -- a placeholder that survived the build is exposed, not excused.
    func testPlaceholderRemnantsAreExposed() throws {
        var values = goodSubstitutedMetadata()
        values["CFBundleName"] = "$(PRODUCT_NAME)"
        let faults = BundleMetadata(values: values).faults(tier: .light)
        XCTAssertTrue(faults.contains(where: { $0.contains("unsubstituted placeholder") }),
                      "a surviving placeholder must be cried, got \(faults)")
        // and substituting with the true setting maketh it pass again
        values = BundleMetadata.substituting(values, settings: ["PRODUCT_NAME": "Godstone"])
        XCTAssertEqual(values["CFBundleName"] as? String, "Godstone")
    }

    /// W11 -- the orientation counsel: empty, unknown and phone-upside-down
    /// are each a cry; the pad's fourth is allowed.
    func testTheOrientationCounselIsKept() throws {
        var values = goodSubstitutedMetadata()
        values["UISupportedInterfaceOrientations"] = [String]()
        XCTAssertTrue(BundleMetadata(values: values).faults(tier: .light)
                      .contains(where: { $0.contains("UISupportedInterfaceOrientations is empty") }),
                      "an empty counsel is no counsel")
        values = goodSubstitutedMetadata()
        values["UISupportedInterfaceOrientations"] = ["UIInterfaceOrientationJiggling"]
        XCTAssertTrue(BundleMetadata(values: values).faults(tier: .light)
                      .contains(where: { $0.contains("unknown orientation") }),
                      "an unknown orientation must be cried")
        values = goodSubstitutedMetadata()
        values["UISupportedInterfaceOrientations"] = [
            "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown"]
        XCTAssertTrue(BundleMetadata(values: values).faults(tier: .light)
                      .contains(where: { $0.contains("shall not list PortraitUpsideDown") }),
                      "the phone shall not stand upside down")
        var pad = goodSubstitutedMetadata()
        pad["UISupportedInterfaceOrientations~ipad"] = [
            "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
        XCTAssertEqual(BundleMetadata(values: pad).faults(tier: .light), [],
                       "the pad may turn to either side")
    }

    /// W12 -- the identifier beareth the firm in reverse domain.
    func testTheIdentifierMustBearTheFirm() throws {
        func faultsFor(_ identifier: String) -> [String] {
            var values = goodSubstitutedMetadata()
            values["CFBundleIdentifier"] = identifier
            return BundleMetadata(values: values).faults(tier: .light)
        }
        XCTAssertEqual(faultsFor("io.godstone.app"), [], "the true identifier must pass")
        XCTAssertTrue(faultsFor("app").contains(where: { $0.contains("reverse-domain") }),
                      "a single label is no reverse-domain name")
        XCTAssertTrue(faultsFor("io..godstone.app").contains(where: { $0.contains("empty label") }),
                      "an empty label must be cried")
        XCTAssertTrue(faultsFor("not an id!").contains(where: { $0.contains("not of letters, digits and hyphens") }),
                      "a hard-coded foreign identifier must be cried")
        XCTAssertTrue(faultsFor("com.evil.app").contains(where: { $0.contains("io.godstone prefix") }),
                      "the prefix is the house's, not the guest's")
    }

    /// W13 -- package type and dictionary version are sworn values.
    func testPackageTypeAndDictionaryVersionAreSworn() throws {
        var values = goodSubstitutedMetadata()
        values["CFBundlePackageType"] = "DATA"
        XCTAssertTrue(BundleMetadata(values: values).faults(tier: .light)
                      .contains(where: { $0.contains("CFBundlePackageType") }),
                      "only APPL and PLAIN are of the part")
        values = goodSubstitutedMetadata()
        values["CFBundleInfoDictionaryVersion"] = "5.0"
        XCTAssertTrue(BundleMetadata(values: values).faults(tier: .light)
                      .contains(where: { $0.contains("CFBundleInfoDictionaryVersion") }),
                      "the dictionary version is of the record, 6.0")
    }

    // MARK: - 14/15 the name law and the guard upon the road

    /// W14 -- the truth table of the resource-name law.
    func testTheResourceNameLawKeepethTheRoad() throws {
        let accepted = ["archive_light.db", "model.gguf", "a.db",
                       String(repeating: "x", count: 61) + ".db"]        // exactly the measure of 64
        let rejected = ["../archive_light.db", "a/b.db", "", ".hidden.db", "db.",
                        "no_ext", "x.g5", "x.GGUF", "x db.db", "archive_light.DB",
                        String(repeating: "x", count: 62) + ".db",        // 65, over the measure
                        "archive_light.db\0"]
        for name in accepted {
            XCTAssertTrue(ArchiveResourceName.isWellFormed(name), "\(name) must pass the name law")
        }
        for name in rejected {
            XCTAssertFalse(ArchiveResourceName.isWellFormed(name), "\(name) must be refused")
        }
    }

    /// W15 -- THE GUARD UPON THE ROAD: a planted sibling file, truly on the
    /// disk just outside the sanctioned archives directory, is named by a
    /// forged traversal name that the old road would have resolved -- and
    /// the guard refuseth it before the filesystem is asked at all. The
    /// availability tale is the honest .missing, naming the forgeard file.
    func testTheResolverRefusethForgeardNamesBeforeTheFilesystem() throws {
        let base = try supportDirectory()
        let fm = FileManager.default
        let archives = base.appendingPathComponent("archives", isDirectory: true)
        try fm.createDirectory(at: archives, withIntermediateDirectories: true)
        let siblingName = "t51_escape_probe.db"
        let sibling = base.appendingPathComponent(siblingName, isDirectory: false)
        try? fm.removeItem(atPath: sibling.path)
        try plantRealArchive(at: sibling.path)                 // a REAL archive, just outside the gate
        defer { try? fm.removeItem(atPath: sibling.path) }
        XCTAssertTrue(fm.fileExists(atPath: sibling.path),
                      "the witness proveth nothing unless the plant is there")
        let readyName = "t51_ready_probe.db"
        let readyUrl = archives.appendingPathComponent(readyName, isDirectory: false)
        try? fm.removeItem(atPath: readyUrl.path)
        try plantRealArchive(at: readyUrl.path)                 // and one within, for the lawful road
        defer { try? fm.removeItem(atPath: readyUrl.path) }

        // the forged traversal: under the faithful guard the name is refused
        // before the filesystem is asked; were the guard asleep, the old road
        // (appendingPathComponent resolving '..') would walk out of archives/
        // onto this very file and FIND IT -- the isAvailable flip below is
        // the absence made heard
        let smuggled = ArchiveRepository(databaseName: "../" + siblingName, expectedTier: nil)
        defer { smuggled.close() }
        XCTAssertFalse(smuggled.isAvailable,
                       "the traversal name must never reach the sibling -- the guard must refuse it before the filesystem")
        guard case .missing(let why) = smuggled.availability else {
            XCTFail("a forged traversal must be told .missing, got \(smuggled.availability.reasonForDisplay)")
            return
        }
        XCTAssertTrue(why.contains(siblingName), "the tale shall name the file asked for, got \(why)")

        // other forged shapes of the same road
        for forged in ["..", "t51/../../escape.db", "\0hidden.db"] {
            let repo = ArchiveRepository(databaseName: forged, expectedTier: nil)
            defer { repo.close() }
            XCTAssertFalse(repo.isAvailable, "\(forged) must be refused at the road")
        }

        // the honest name for the same sibling (not under archives/) is
        // honestly told missing -- the guard changed nothing of the lawful
        // roads...
        let honest = ArchiveRepository(databaseName: siblingName, expectedTier: nil)
        defer { honest.close() }
        XCTAssertFalse(honest.isAvailable, "the honest name, file absent from the sanctioned places, is .missing")
        // ...and the honest name within the sanctioned place STANDETH ready
        let ready = ArchiveRepository(databaseName: readyName, expectedTier: nil)
        defer { ready.close() }
        XCTAssertTrue(ready.isAvailable,
                      "the guard must not obstruct the lawful road: a real archive within archives/ is ready, got \(ready.availability.reasonForDisplay)")
    }
}
