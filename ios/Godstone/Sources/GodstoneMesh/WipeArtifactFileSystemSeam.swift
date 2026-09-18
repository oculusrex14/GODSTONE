import Foundation

/// GS-STORE-006: **THE PRODUCTION `ArtifactFileSystemSeam`** -- the second of the five adapters the finding's card
/// requireth, written entirely from the protocol's own three members (`deleteArtifact`, `exists`, `isReadable`) and the
/// platform's own filesystem.
///
/// **EVERY RESULT IS CHECKED, WHICH IS THE CARD'S STEP 5**: deletion is performed through `FileManager`, and the answer
/// is derived from WHAT THE FILESYSTEM REPORTS AFTERWARDS rather than from the absence of a thrown error -- so a
/// permission, a lock, or a path that survived is RETURNED AS A FAILURE and the wipe stays pending, exactly as the card
/// demands ("check every result, and leave the wipe pending when cleanup fails").
///
/// **AND `isReadable` CONSULTS THE DURABLE JOURNAL, NOT THE VAULT -- BECAUSE THE FIRST DRAFT OF THIS FILE MADE A
/// DESTRUCTIVE *READ*.** The protocol says "An artifact is readable exactly while it exists AND some erasable key still
/// lives", and the seam's only key verb is `eraseKey`, so my first version answered the question BY ERASING THE KEYS: a
/// question that destroys what it asks about, and in a type whose whole purpose is irreversible action. THE ORACLE IS
/// THEREFORE THE WIPE'S OWN DURABLE RECORD: `KEYS_ERASED` in the journal is the one place that says, truthfully and
/// without side effects, whether the material is gone -- so the journal is asked, and the vault is left alone until the
/// step that is SUPPOSED to erase it.
public final class WipeArtifactFileSystemSeam: ArtifactFileSystemSeam {
    private let fileManager: FileManager
    private let journal: WipeDurabilityStore
    /// GS-FINAL-002: **`WipeScope.privateArtifacts` NAMETH LOGICAL NAMES, NOT PATHS, AND THE FIRST VERSION OF THIS
    /// SEAM DELETED NOTHING WITH THEM.** `fileManager.removeItem(atPath: "mesh.db")` is measured against the PROCESS's
    /// working directory, where no such file has ever existed — so every deletion answered `.absent`, the ladder read
    /// that as success, and the durable store survived a "completed" wipe. The ABSENCE of a file that was never
    /// addressed is not the DELETION of a file that was. The runtime's REAL urls are mapped here, and a logical name
    /// with no mapping is REFUSED rather than silently reported absent.
    private let realPaths: [String: URL]

    public init(fileManager: FileManager = .default, journal: WipeDurabilityStore,
                realPaths: [String: URL] = [:]) {
        self.fileManager = fileManager
        self.journal = journal
        self.realPaths = realPaths
    }

    /// The URL a logical private-artifact name actually denoteth. **THE MAPPING IS TOTAL OR THE NAME FAILS**: a
    /// logical name with no entry here cannot be addressed, and `deleteArtifact` refuses it rather than reporting the
    /// absence of a file that was never named.
    private func url(for path: String) -> URL? { realPaths[path] }

    public func exists(_ path: String) -> Bool {
        guard let target = url(for: path) else { return false }
        return fileManager.fileExists(atPath: target.path)
    }

    public func deleteArtifact(_ path: String) -> FileDeletionResult {
        guard let target = url(for: path) else {
            // AN UNMAPPED LOGICAL NAME IS A FAILURE, NOT AN ABSENCE: this seam cannot delete what it cannot address,
            // and reporting `.absent` would let a wipe reach ARTIFACTS_DELETED with the artifact still standing.
            return .failed(path: path, reason: "no real path is mapped for this private artifact")
        }
        let targetPath = target.path
        guard fileManager.fileExists(atPath: targetPath) else {
            // ABSENCE AND DELETION BOTH SATISFY THE ERASURE (the wipe's own tri-state doctrine), so an artifact that
            // never stood is reported as such rather than as a failure.
            return .absent
        }
        do {
            try fileManager.removeItem(atPath: targetPath)
        } catch {
            return .failed(path: path, reason: String(describing: error))
        }
        guard !fileManager.fileExists(atPath: targetPath) else {
            // A `removeItem` that did not throw while the file survives IS STILL A FAILURE, and saying so is the whole
            // point of checking every result rather than trusting the call.
            return .failed(path: path, reason: "the artifact surviveth its own deletion")
        }
        return .deleted
    }

    public func isReadable(_ path: String) -> Bool {
        guard let target = url(for: path) else { return false }
        guard fileManager.fileExists(atPath: target.path) else { return false }
        // THE JOURNAL IS THE ORACLE, AND IT IS READ-ONLY: once the durable record stands at KEYS_ERASED, the material
        // that would decrypt this artifact is gone, so an artifact still on disk is NOT readable. NO KEY IS TOUCHED
        // HERE -- the erasure belongeth to the step that is supposed to erase, and a read that erased would be a
        // question destroying its own subject.
        return !journal.readJournal().contains("KEYS_ERASED")
    }
}
