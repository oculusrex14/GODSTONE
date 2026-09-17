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

    public init(fileManager: FileManager = .default, journal: WipeDurabilityStore) {
        self.fileManager = fileManager
        self.journal = journal
    }

    public func exists(_ path: String) -> Bool {
        return fileManager.fileExists(atPath: path)
    }

    public func deleteArtifact(_ path: String) -> FileDeletionResult {
        guard fileManager.fileExists(atPath: path) else {
            // ABSENCE AND DELETION BOTH SATISFY THE ERASURE (the wipe's own tri-state doctrine), so an artifact that
            // never stood is reported as such rather than as a failure.
            return .absent
        }
        do {
            try fileManager.removeItem(atPath: path)
        } catch {
            return .failed(path: path, reason: String(describing: error))
        }
        guard !fileManager.fileExists(atPath: path) else {
            // A `removeItem` that did not throw while the file survives IS STILL A FAILURE, and saying so is the whole
            // point of checking every result rather than trusting the call.
            return .failed(path: path, reason: "the artifact surviveth its own deletion")
        }
        return .deleted
    }

    public func isReadable(_ path: String) -> Bool {
        guard fileManager.fileExists(atPath: path) else { return false }
        // THE JOURNAL IS THE ORACLE, AND IT IS READ-ONLY: once the durable record stands at KEYS_ERASED, the material
        // that would decrypt this artifact is gone, so an artifact still on disk is NOT readable. NO KEY IS TOUCHED
        // HERE -- the erasure belongeth to the step that is supposed to erase, and a read that erased would be a
        // question destroying its own subject.
        return !journal.readJournal().contains("KEYS_ERASED")
    }
}
