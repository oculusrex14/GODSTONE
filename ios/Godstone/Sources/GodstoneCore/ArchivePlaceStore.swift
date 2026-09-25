import Foundation

/// *** GS-ARCHIVE-005 STEP 4: THE DURABLE PLACE, IN A VEHICLE THAT SURVIVETH A PROCESS DEATH. ***
///
/// ## THE DEFECT THIS REPLACES, AND WHY THE OLD PROOF DID NOT COVER IT
///
/// *The record stood in `@SceneStorage`. Its justification, quoted from the view, was:* **"W16 (a behavioural arm in
/// GodstoneCoreTests) MEASURABLY PROVETH that the handle surviveth a real `PropertyListSerialization` round-trip INTO A
/// FRESH SCENE with its identity and metadata intact -- so this store is backed by a measured semantic and not by a
/// hope."**
///
/// **THAT EXPERIMENT MEASURED THE SERIALISATION, NOT THE DURABILITY, AND THE DIFFERENCE IS THE WHOLE DEFECT.** *A
/// plist round-trip into a fresh `ArchiveSceneModel` proveth that the handle's contents can be encoded and decoded. **It
/// saith nothing whatever about whether the STORE surviveth a `terminate()`.*** *And `@SceneStorage`, by Apple's own
/// contract, is **scene-scoped**: iOS discards it when the scene goes away, AND IT IS ONLY RESTORED AT ALL FOR AN APP
/// THAT OPTS INTO STATE RESTORATION* -- *which this application does not: there is no `UIApplicationSceneManifest`
/// restoration configuration, no scene delegate and no restoration identifier anywhere in the target.*
///
/// **MEASURED, HOSTED AND LOCAL: `testGSA005DocumentReopensAfterCleanProcessDeath` IS DETERMINISTICALLY RED** -- *the
/// relaunch landeth at the document list, and the trace showeth the relaunch never restoring the reader.* **THE
/// VEHICLE WAS THE PROBLEM, NOT THE TIMING.** *Moving the write to a guaranteed transition (which the view now
/// doeth) cannot help a store the system throweth away.*
///
/// ## THE REPLACEMENT
///
/// *`UserDefaults` is process-durable: it is written to disk, it surviveth a hard `terminate()`, and it requireth no
/// scene-restoration opt-in.* **It is the boring, standard answer to "this must survive the process", which is
/// precisely why it is right here** -- *the exotic vehicle was the one carrying an unstated precondition.*
///
/// *THE FAIL-CLOSED RULE IS PRESERVED FROM THE OLD CODE, because it was correct: **A HALF-WRITTEN PLACE IS WORSE THAN
/// AN OLD ONE**, since it restores a place that was never true. A record that cannot be encoded is NOT written and the
/// previous record standeth.*
public struct ArchivePlaceStore {

    /// *The key the record liveth under. One key, one place -- and it is namespaced by the bundle so a lab build and
    /// the shipping build cannot restore each other's places.*
    public let key: String

    private let defaults: UserDefaults

    /// - Parameters:
    ///   - defaults: *the durable store. Injectable so a court can drive a REAL `UserDefaults` over a scratch suite
    ///     rather than an in-memory dictionary -- **a test double for the store would measure the double, and the
    ///     store is the thing under test.***
    ///   - key: *the record's key.*
    public init(defaults: UserDefaults = .standard,
                key: String = "godstone.archive.scene") {
        self.defaults = defaults
        self.key = key
    }

    /// *** THE PLACE, AS IT WAS LAST WRITTEN -- OR NIL WHEN THERE IS NONE. ***
    ///
    /// *A record that cannot be decoded returneth NIL rather than an empty handle, because an empty handle is
    /// INDISTINGUISHABLE FROM "THE READER WAS AT THE LIST" and would silently assert a place the user never had.*
    public func read() -> [String: Any]? {
        guard let data = defaults.data(forKey: key), !data.isEmpty else { return nil }
        guard let handle = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return handle
    }

    /// *** AND THE PLACE IS WRITTEN, OR THE PREVIOUS ONE STANDETH. ***
    ///
    /// *Returneth whether the write landed, so a caller (or a court) can tell "there is now a place" from "the record
    /// could not be encoded and the old one remaineth".* **A silent failure here would be the very thing the
    /// fail-closed rule existeth to prevent.**
    @discardableResult
    public func write(_ handle: [String: Any]) -> Bool {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: handle, format: .binary, options: 0) else {
            return false
        }
        defaults.set(data, forKey: key)
        return true
    }

    /// *Used by the recreation court and by a wipe, so a restored place can never outlive the archive it pointed at.*
    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
