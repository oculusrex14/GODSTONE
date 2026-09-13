import Foundation

/* ============================================================================
 T51 (s17) -- resource intake and installable bundle metadata, in code.

 Three laws keep the intake road honest:

   1. no name that is not well-formed may be asked of the bundle or of the
      filesystem (ArchiveResourceName);
   2. a bundle is installable only when its metadata swears the truth about
      executable, identifier, package type, dictionary version, orientations
      and the archive it meaneth to carry (BundleMetadata);
   3. a project manifest is generated, never guessed: the SOURCE-ONLY face
      referenceth none of the Approved paths and refuseth any listed source
      that is absent; the APPROVED face is born only of a receipt which the
      staging gate published after successful staging (ProjectInputManifest).

 Determinism is a property of the renderers: fixed key order, sorted paths,
 no timestamps, no ambient state. The same inputs shall ever render the same
 bytes, that two builds may be compared byte for byte.
 ============================================================================ */

// MARK: - the law of resource names

public enum ArchiveResourceName {
    /// The endings intake at this gate. Lower case only: the frozen names
    /// of the release are lower case, and a name shall match its release.
    public static let allowedEndings: Set<String> = ["db", "gguf"]

    /// A name longer than this shall not be asked at all.
    public static let maxLength = 64

    private static let allowed: Set<Character> = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// Well-formed: at most `maxLength` characters from letters, digits,
    /// '.', '_' and '-'; not beginning with '.'; ending in one of the
    /// allowed lower-case endings after at least one other character. No
    /// path separator, no traversal, no NUL, no blank can ever pass.
    public static func isWellFormed(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxLength else { return false }
        if name.contains(where: { !allowed.contains($0) }) { return false }
        if name.utf16.contains(where: { $0 == 0 }) { return false }   // belt and braces: no NUL passeth
        let first = name.first!
        let last = name.last!
        if first == "." || last == "." { return false }      // hidden files and dangling dots are not intake
        let ns = name as NSString
        guard let ext = ns.pathExtension as String?, !ext.isEmpty,
              ext != name,                                          // a dot alone is no ending
              allowedEndings.contains(ext) else { return false }
        return true
    }
}

// MARK: - the law of installable bundle metadata

public struct BundleMetadata: Sendable {
    public let values: [String: Any]

    public init(values: [String: Any]) { self.values = values }

    public static let knownPhoneOrientations: Set<String> = [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ]
    public static let knownPadOrientations: Set<String> = knownPhoneOrientations.union([
        "UIInterfaceOrientationPortraitUpsideDown",
    ])
    public static let allowedPackageTypes: Set<String> = ["APPL", "PLAIN"]
    public static let expectedDictionaryVersion = "6.0"
    public static let expectedTier = "LIGHT"

    private func string(_ key: String) -> String? { values[key] as? String }
    private func strings(_ key: String) -> [String]? { values[key] as? [String] }

    /// Every fault, plain-spoken; an empty tale is an installable bundle.
    public func faults(tier: Tier) -> [String] {
        var faults: [String] = []

        func scalarText(_ key: String, _ requirement: String) {
            guard let text = string(key) else {
                faults.append("missing \(key): \(requirement)")
                return
            }
            if text.isEmpty { faults.append("\(key) is empty") }
            if text.contains(where: { $0 == "/" }) { faults.append("\(key) containeth a path separator") }
            if text.hasPrefix(".") { faults.append("\(key) beginneth with a dot") }
            if text.contains("$(") || text.contains(")") {
                faults.append("\(key) still holdeth an unsubstituted placeholder: \(text)")
            }
        }

        scalarText("CFBundleExecutable", "the launchservices refuse an un-executable bundle")
        scalarText("CFBundleName", "the bundle shall have a name")
        let identifier = string("CFBundleIdentifier") ?? ""
        if identifier.isEmpty {
            faults.append("missing CFBundleIdentifier")
        }
        if !identifier.isEmpty {
            let segments = identifier.split(separator: ".", omittingEmptySubsequences: false)
            if segments.count < 2 { faults.append("CFBundleIdentifier is no reverse-domain name: \(identifier)") }
            for segment in segments {
                if segment.isEmpty {
                    faults.append("CFBundleIdentifier holdeth an empty label: \(identifier)")
                } else if segment.contains(where: { !("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-".contains($0)) }) {
                    faults.append("CFBundleIdentifier label \(segment) is not of letters, digits and hyphens")
                }
                if let f = segment.first, f == "-" { faults.append("CFBundleIdentifier label beginneth with a hyphen") }
                if let l = segment.last, l == "-" { faults.append("CFBundleIdentifier label endeth with a hyphen") }
            }
            if !identifier.hasPrefix("io.godstone") {
                faults.append("CFBundleIdentifier shall begin with the io.godstone prefix, got \(identifier)")
            }
        }
        if let package = string("CFBundlePackageType"), !Self.allowedPackageTypes.contains(package) {
            faults.append("CFBundlePackageType \(package) is none of APPL/PLAIN")
        } else if string("CFBundlePackageType") == nil {
            faults.append("missing CFBundlePackageType")
        }
        if let version = string("CFBundleInfoDictionaryVersion"), version != Self.expectedDictionaryVersion {
            faults.append("CFBundleInfoDictionaryVersion is \(version), shall be \(Self.expectedDictionaryVersion)")
        } else if string("CFBundleInfoDictionaryVersion") == nil {
            faults.append("missing CFBundleInfoDictionaryVersion")
        }

        func orientations(_ key: String, known: Set<String>, allowUpsideDown: Bool) {
            guard let list = strings(key) else {
                faults.append("missing \(key): a window with no orientation counsel is a window unopen")
                return
            }
            if list.isEmpty { faults.append("\(key) is empty") }
            for one in list {
                if !known.contains(one) {
                    faults.append("\(key) holdeth an unknown orientation \(one)")
                }
            }
            if !allowUpsideDown, list.contains("UIInterfaceOrientationPortraitUpsideDown") {
                faults.append("\(key) (the phone) shall not list PortraitUpsideDown")
            }
        }
        orientations("UISupportedInterfaceOrientations", known: Self.knownPhoneOrientations, allowUpsideDown: false)
        orientations("UISupportedInterfaceOrientations~ipad", known: Self.knownPadOrientations, allowUpsideDown: true)

        if values["UILaunchScreen"] == nil {
            faults.append("missing UILaunchScreen: the bundle flasheth black on install")
        }

        if let shipped = string("GodstoneTier"), shipped != Self.expectedTier {
            faults.append("GodstoneTier is \(shipped), the release shipeth \(Self.expectedTier)")
        } else if string("GodstoneTier") == nil {
            faults.append("missing GodstoneTier")
        }
        if let archive = string("GodstoneArchiveFile") {
            if !ArchiveResourceName.isWellFormed(archive) {
                faults.append("GodstoneArchiveFile \(archive) is not a well-formed resource name")
            }
            if archive != tier.archiveDatabaseName {
                faults.append("GodstoneArchiveFile \(archive) doth not match the tier's own name \(tier.archiveDatabaseName)")
            }
        } else {
            faults.append("missing GodstoneArchiveFile")
        }
        return faults
    }

    /// Substitute $(VAR) values as the build tool would, from the project's
    /// declared settings, that the metadata may be judged as launchservices
    /// shall see it. Only whole occurrences of known names are replaced.
    public static func substituting(_ values: [String: Any], settings: [String: String]) -> [String: Any] {
        func replace(_ text: String) -> String {
            var result = text
            for (name, value) in settings {
                result = result.replacingOccurrences(of: "$(" + name + ")", with: value, options: [])
                // (occurrences of unknown names are left alone, that the
                //  placeholder-fault may cry of them)
            }
            return result
        }
        var out: [String: Any] = [:]
        for (key, value) in values {
            switch value {
            case let text as String: out[key] = replace(text)
            case let list as [String]: out[key] = list.map(replace)
            case let inner as [String: Any]: out[key] = substituting(inner, settings: settings)
            default: out[key] = value
            }
        }
        return out
    }
}

// MARK: - the two faces of the generated project manifest

public struct ApprovedResourceEntry: Codable, Sendable, Equatable {
    public let role: String
    public let name: String
    public let sha256: String
    public let bytes: Int
    public let buildPhase: String

    private enum CodingKeys: String, CodingKey {
        case role, name, sha256, bytes
        case buildPhase = "build_phase"
    }
}

public struct ApprovedReceiptDocument: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public let schema: Int
    public let tier: String
    public let applicationId: String
    public let generatedBy: String
    public let assets: [ApprovedResourceEntry]

    private enum CodingKeys: String, CodingKey {
        case schema, tier
        case applicationId = "application_id"
        case generatedBy = "generated_by"
        case assets
    }
}

public enum ProjectInputManifest: Sendable {
    case sourceOnly(sources: [String])
    case approvedArchive(receipt: ApprovedReceiptDocument)

    public static let approvedDirectory = "Godstone/Resources/Approved"

    /// Verify a source-only listing: every path shall stand under `root`
    /// already -- a manifest that would reference an absent resource is
    /// refused at the birth, not discovered at the build.
    public static func verifySourceOnly(listing: [String], under root: String) -> [String]? {
        let fm = FileManager.default
        guard !listing.isEmpty else { return nil }
        var names = Set<String>()
        for path in listing {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(where: { $0 == "\\" }) else { return nil }
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty, !components.contains("..") else { return nil }
            let full = (root as NSString).appendingPathComponent(components.joined(separator: "/"))
            guard fm.fileExists(atPath: full) else { return nil }
            // a directory cannot be enumerated as a file: where enumeration
            // of the path succeedeth, the entry is a directory and is refused
            if (try? fm.contentsOfDirectory(atPath: full)) != nil { return nil }
            if names.contains(path) { return nil }      // duplicates are a false witness
            names.insert(path)
        }
        return listing
    }

    /// The gate of the approved receipt: exact key-sets, the schema version
    /// (unknown future versions are refused outright), the role/name binding,
    /// the hex-shape of the digests, the one-and-only archive.
    public static func approved(from data: Data) -> ApprovedReceiptDocument? {
        guard let top = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }
        guard Set(top.keys) == Set(["schema", "tier", "application_id", "generated_by", "assets"]) else { return nil }
        guard let rawAssets = top["assets"] as? [[String: Any]], rawAssets.count == 1 else { return nil }
        guard let entry = rawAssets.first, Set(entry.keys) == Set(["role", "name", "sha256", "bytes", "build_phase"]) else {
            return nil
        }
        guard let receipt = try? JSONDecoder().decode(ApprovedReceiptDocument.self, from: data) else { return nil }
        guard receipt.schema == currentSchemaValue else { return nil }
        guard receipt.tier == "LIGHT", receipt.applicationId == "io.godstone.app" else { return nil }
        guard receipt.generatedBy == "scripts/prepare_release_assets.py" else { return nil }
        guard let asset = receipt.assets.first, receipt.assets.count == 1 else { return nil }
        guard asset.role == "archive", asset.name == Tier.light.archiveDatabaseName else { return nil }
        guard asset.buildPhase == "resources" else { return nil }
        guard asset.bytes > 0 else { return nil }
        let hex = Set("0123456789abcdef".unicodeScalars)
        guard asset.sha256.unicodeScalars.count == 64,
              !asset.sha256.unicodeScalars.contains(where: { !hex.contains($0) }) else { return nil }
        guard ArchiveResourceName.isWellFormed(asset.name) else { return nil }
        return receipt
    }
    private static let currentSchemaValue = ApprovedReceiptDocument.currentSchema

    /// Deterministic rendering of the target's sources section. The
    /// source-only face never nameeth the Approved directory and never
    /// writeth 'optional'; the approved face nameth exactly and only the
    /// receipt's verified files, sorted, that the bytes shall ever be the
    /// same for the same inputs.
    public func renderedSourcesSection() -> String {
        var lines: [String] = ["    # generated by scripts/prepare_release_assets.py -- do not edit by hand"]
        switch self {
        case .sourceOnly(let sources):
            for path in sources.sorted() {
                lines.append("    - path: \(path)")
            }
        case .approvedArchive(let receipt):
            for asset in receipt.assets.sorted(by: { $0.name < $1.name }) {
                lines.append("    - path: \(ProjectInputManifest.approvedDirectory)/\(asset.name)")
                lines.append("      buildPhase: resources")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
