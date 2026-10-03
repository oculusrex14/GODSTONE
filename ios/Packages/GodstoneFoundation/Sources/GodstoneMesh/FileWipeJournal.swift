import Foundation

// ================================================================================================
// *** IOS-R3 (durability): A FILE-BACKED, CROSS-PROCESS JOURNAL -- BECAUSE `UserDefaults.set` +
// A SAME-PROCESS RE-READ IS *NOT* A DURABLE ACKNOWLEDGMENT. ***
//
// *THE PARENT'S RULING, AND IT IS CORRECT: `UserDefaults` shares an in-process cache, so
// `write(state); read()` observeth the cached value and would report `.committed` for a write that
// never reached disk. A durable ack must survive the PROCESS, so it must be read from the durable
// MEDIUM rather than from a cache.*
//
// **THIS STORE WRITETH THE STATE AND THE GENERATION TO A FILE, `fsync`S IT, AND RE-READS IT FROM
// THE FILESYSTEM ON EVERY QUESTION.** *A write that did not reach disk therefore readeth back as
// the OLD value and the coordinator refuseth to advance.*
//
// *** IOS-FOLLOWUP-C2: THE REPLACEMENT IS ATOMIC AND ITS RESULT IS CHECKED. ***
//   * the old journal is NEVER unlinked before the move: `FileManager.replaceItemAt` (or a POSIX
//     `rename(2)` fallback) atomically REPLACES the record, so a crash at any boundary leaves the
//     OLD or the NEW record -- never a fabricated clean estate from a missing file;
//   * `persist` returneth `Bool`, and EVERY ordinary writer (`write`/`bumpEpoch`/`clear`/`append`)
//     PROPAGATETH it. The medium's `readDurable` answer alone is not sufficient evidence: the
//     bytes may be VISIBLE while the DIRECTORY FSYNC failed, so the adapter requires the persist/
//     sync RESULT, not merely a matching reread.
//
// *** IOS-FOLLOWUP-C3: THE DURABLE GENERATION IS MONOTONE AND SURVIVETH RECOVERY. ***
//   * a corrupt STATE head no longer discards a VALID generation suffix -- the suffix is parsed
//     independently, so an operator recovery ADVANCES the prior durable generation rather than an
//     invented zero;
//   * `clear` keepeth (does not delete) the generation, so a later clean baseline cannot REUSE a
//     previously issued generation (ABA).
// ================================================================================================

/// *** THE TYPED RESULT OF A DURABLE WRITE, WITH THE GENERATION THAT ACTUALLY REACHED THE MEDIUM. ***
public struct DurableWriteResult: Equatable, Sendable {
    /// Whether the file AND its parent directory synchronization succeeded.
    public let synchronized: Bool
    /// The generation now on the medium (or `nil` when none is carried).
    public let epoch: UInt64?
    public init(synchronized: Bool, epoch: UInt64?) {
        self.synchronized = synchronized
        self.epoch = epoch
    }
}

/// *** A REAL, FILE-BACKED, CROSS-PROCESS DURABLE WIPE JOURNAL. ***
public final class FileWipeJournal: WipeJournal, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    /// *** IOS-FOLLOWUP-C2: THE RECORD WHOSE BYTES BECAME VISIBLE BUT WERE NEVER SYNCHRONIZATION-VOUCHED. ***
    /// *While a read matches this spelling, the medium is UNREADABLE for admission purposes: visibility is not an
    /// acknowledgment, and a state-only reread must not turn a failed directory fsync into `committed`. The next
    /// successful persist clears it.*
    private var unvouchedRaw: String?
    /// *** IOS-FOLLOWUP-C3: THE HIGHEST GENERATION THIS PROCESS HAS EVER SEEN. *** *Monotonicity may never regress
    /// behind a seen value -- not through a corrupt head, not through a clear, and not through a poisoned read.*
    private var carriedEpoch: UInt64?

    /// *** THE FORCED-SYNCHRONIZATION-FAILURE SEAM (IOS-FOLLOWUP-C2'S NEGATIVE CONTROLS). ***
    ///
    /// *The refusal roads -- "the file sync failed" and "the directory fsync failed AFTER the new bytes became
    /// readable" -- are unreachable on a healthy host filesystem, and a control that cannot be driven is not a
    /// control. So the fault is INJECTABLE: `.file` fails before the replacement (the OLD record survives untouched)
    /// and `.directory` fails after it (the new bytes ARE visible -- exactly the case the poison exists for). The
    /// production road is unchanged when this is `nil`.*
    internal enum SyncFaultForTest: Sendable { case file, directory }
    internal var syncFaultForTest: SyncFaultForTest?
    /// The independent floor file, beside the state record.
    private var floorURL: URL { URL(fileURLWithPath: url.path + ".epoch") }
    /// The durable refusal marker, beside the state record.
    private var unackedURL: URL { URL(fileURLWithPath: url.path + ".unacked") }

    /// *** THE DURABLE GENERATION FLOOR (CURRENT-01): read from its OWN file, so no wrapper, corruption or `clear`
    /// can launder a real estate into a generation-1 baseline. ***
    private func readFloor() -> UInt64? {
        guard let raw = try? String(contentsOf: floorURL, encoding: .utf8) else { return nil }
        return UInt64(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether a state record EXISTS (present-but-unreadable counts: that is evidence of a real estate).
    private var recordPresent: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// *** ANY DURABLE EVIDENCE THAT THIS ESTATE HAS A HISTORY -- THE PHASE, THE FLOOR, OR A REFUSAL MARKER. ***
    ///
    /// *MEASURED (the parent's actual probe, 2026-10-02): a PRESENT-but-corrupt floor file with an ABSENT phase was
    /// admitted as a clean first launch (`rc=-5: present corrupt floor with absent phase admitted as clean`), because a
    /// predicate that asked "can this file be PARSED" answers `nil` for corruption. So this asks about FILESYSTEM
    /// PRESENCE -- evidence a real estate exists, regardless of whether its bytes are interpretable.*
    ///
    /// **THE SAME PREDICATE IS USED BY EVERY FIRST-LAUNCH GUARD** -- the raise, the checked write, the ordinary write,
    /// `clear`, and the medium's absent read -- so "absent phase + present floor/marker" can never be admitted as
    /// clean anywhere.
    private var historyPresent: Bool {
        recordPresent
            || FileManager.default.fileExists(atPath: floorURL.path)
            || FileManager.default.fileExists(atPath: unackedURL.path)
    }

    /// *** WRITE THE FLOOR ITSELF, CHECKED. *** *A floor that did not reach the medium is not raised, and the caller
    /// is told: the state file is NOT rewritten, so no phase laundering can happen here (CURRENT-02).*
    @discardableResult
    private func raiseFloor(to value: UInt64) -> Bool {
        let raw = "\(value)"
        let tmp = URL(fileURLWithPath: floorURL.path + ".tmp")
        if syncFaultForTest == .file { return false }
        do {
            try Data(raw.utf8).write(to: tmp, options: [.atomic])
            let fh = try FileHandle(forWritingTo: tmp); try fh.synchronize(); try fh.close()
            if FileManager.default.fileExists(atPath: floorURL.path) {
                _ = try FileManager.default.replaceItemAt(floorURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: floorURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        if syncFaultForTest == .directory { return false }
        let dir = floorURL.deletingLastPathComponent().path
        var synced = false
        for _ in 0..<2 {
            let dirFd = open(dir, O_RDONLY)
            if dirFd >= 0 { synced = fsync(dirFd) == 0; close(dirFd) }
            if synced { break }
        }
        return synced
    }

    /// *** THE DURABLE REFUSAL MARKER (CURRENT-03). *** *Written FILE+DIRSUNCED BEFORE a replacement becometh
    /// visible, and cleared only after a later persist whose own directory sync really succeeded -- an atomic
    /// `Data.write` alone is not durability. It is consulted by PRESENCE (measured: byte-equality ignored a corrupt
    /// marker and admitted visible bytes), so its CONTENT need never be interpreted.*

    /// One checked directory synchronization, retried once (the refusal must come from the medium, not a stumble).
    private func syncDirectory(_ dir: String) -> Bool {
        var synced = false
        for _ in 0..<2 {
            let dirFd = open(dir, O_RDONLY)
            if dirFd >= 0 { synced = fsync(dirFd) == 0; close(dirFd) }
            if synced { break }
        }
        return synced
    }

    /// *** THE MARKER PRECEDES VISIBILITY: file + directory sync, CHECKED. *** *If this cannot be made durable the
    /// replace MUST NOT happen -- otherwise visible bytes could exist with no refusal on record.*
    @discardableResult
    private func writeMarkerDurably(_ raw: String) -> Bool {
        if syncFaultForTest == .file { return false }
        let tmp = URL(fileURLWithPath: unackedURL.path + ".tmp")
        do {
            try Data(raw.utf8).write(to: tmp, options: [.atomic])
            let fh = try FileHandle(forWritingTo: tmp); try fh.synchronize(); try fh.close()
            if FileManager.default.fileExists(atPath: unackedURL.path) {
                _ = try FileManager.default.replaceItemAt(unackedURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: unackedURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        return syncDirectory(unackedURL.deletingLastPathComponent().path)
    }
    /// Clear the refusal only durably: removal + directory sync.
    private func clearMarkerDurably() {
        try? FileManager.default.removeItem(at: unackedURL)
        _ = syncDirectory(unackedURL.deletingLastPathComponent().path)
    }
    /// *** IOS-FOLLOWUP-CURRENT-01/02/03: A DURABLE GENERATION FLOOR AND A DURABLE REFUSAL MARKER BESIDE THE STATE. ***
    ///
    /// *The review measured three holes in the in-memory design, and each is repaired by ONE independent file beside
    /// the state record:*
    ///   * **CURRENT-01** -- `carriedEpoch` was INSTANCE MEMORY, so a fresh wrapper (or a lost state file) could
    ///     convert a real estate into a legitimate generation-1 baseline. The floor now lives in `<journal>.epoch`,
    ///     written and fsynced on its own, so it surviveth reconstruction, whole-file corruption, `clear`, and the
    ///     process itself. A brand-new estate beginneth at 1 ONLY when BOTH files are absent; a PRESENT record whose
    ///     counter is missing/invalid is never given the baseline rule.
    ///   * **CURRENT-02** -- the separate `bumpEpoch` used to persist `parseState()` (IDLE for an unreadable head),
    ///     laundering corruption into a clean record before REQUESTED landed. The bump now RAISES ONLY THE FLOOR and
    ///     NEVER writes the phase: the phase is written by the checked state write that followeth, so a failure leaveth
    ///     the prior corrupt/pending record standing with the HIGHER generation -- and an old permit at the lower
    ///     generation is thereby no longer current. A failed raise answereth `nil`, never the previous value.
    ///   * **CURRENT-03** -- the failed-directory-fsync poison was one object's `unvouchedRaw`, so a fresh
    ///     `FileWipeJournal` over the same URL admitted the visible bytes. The refused spelling is now ALSO written to
    ///     `<journal>.unacked`, so ANY wrapper for the same physical journal refuseth until a later persist really
    ///     synchronizes.

    public init(url: URL) { self.url = url }

    /// The default location: Application Support on the device, a temp dir on the host.
    public static func beside(_ storeUrl: URL) -> FileWipeJournal {
        FileWipeJournal(url: URL(fileURLWithPath: storeUrl.path + ".wipe-journal"))
    }

    /// *** THE CONVENTIONAL PRODUCTION LOCATION: a fixed path under Application Support (or the temp dir on the
    /// host), so a caller that names no journal still getteth a DURABLE one rather than a cache-backed default. ***
    ///
    /// *** IOS-FOLLOWUP-C1: A LEGACY PENDING `UserDefaults` RECORD IS MIGRATED DURABLY, NEVER READ AS CLEAN. ***
    /// *The old backend stored the record in `UserDefaults`; switching the default to this file journal must not let
    /// an existing PENDING wipe masquerade as a clean first launch.* **So on first use, an absent file that meets a
    /// non-idle legacy record is durably seeded from it (with a fresh generation), and `migrateLegacy` answereth the
    /// state it carried.***
    public static func standard(legacy: WipeJournal? = UserDefaultsWipeJournal()) -> FileWipeJournal {
        let base: URL
        #if os(iOS)
        base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        #else
        base = FileManager.default.temporaryDirectory
        #endif
        let journal = FileWipeJournal(url: base.appendingPathComponent("io.godstone.wipe.journal"))
        journal.migrateLegacyIfNeeded(legacy)
        return journal
    }

    /// *** IOS-FOLLOWUP-C1: ONE-TIME MIGRATION OF A PENDING LEGACY RECORD. *** *Idempotent: only runneth when the
    /// file carrieth NO record yet, and only when the legacy record standeth at a NON-IDLE rung.*
    @discardableResult
    public func migrateLegacyIfNeeded(_ legacy: WipeJournal?) -> WipeState? {
        lock.lock()
        defer { lock.unlock() }
        guard case .absent = medium() else { return nil }        // this journal already carrieth truth
        guard let legacy, legacy.isReadable else { return nil }
        let prior = legacy.read()
        guard prior != .idle else { return nil }                 // a clean legacy record migrateth nothing
        // DURABLY SEED the pending rung (with a fresh generation) so the wipe RESUMES rather than reading clean.
        _ = persist(state: prior, epoch: (legacy.durableEpoch ?? 0) &+ 1)
        return prior
    }

    /// *** THE MEDIUM READ: *ABSENT* vs *UNREADABLE* vs a RECORD, with the epoch PINNED to the authority. ***
    ///
    /// *A malformed STATE head never discards a valid generation suffix. AND -- the parent's counter-first invariant
    /// -- a record whose phase-stamped suffix is NOT the authoritative floor is UNPINNED: the reader may name its state
    /// but may NOT name a generation from it, so it can never be admitted as settled.*
    private struct Record {
        let state: WipeState?
        let epoch: UInt64?
        let pinned: Bool        // phase-stamped suffix == the durable floor
    }
    private enum Medium {
        case absent
        case unreadable            // present but the file could not be read as text
        case record(Record)
    }

    private func medium() -> Medium {
        guard FileManager.default.fileExists(atPath: url.path) else {
            // *** CURRENT-01: AN ABSENT PHASE FILE IS A CLEAN START ONLY WHEN NOTHING ELSE SAYS OTHERWISE. *** *A
            // PRESENT floor (even a corrupt one) or a refusal marker is evidence of a real estate: admitting it as
            // absent/clean here would let a recreated wrapper bless existing history as a first launch.*
            return historyPresent ? .unreadable : .absent
        }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return .unreadable }
        // *** CURRENT-03: THE REFUSAL MARKER IS CONSULTED BY *PRESENCE*, NOT BY BYTE-EQUALITY. ***
        //
        // *MEASURED (the parent's actual probe, 2026-10-02): a PRESENT-but-corrupt refusal marker on a phase of
        // `idle|1` with floor `1` was admitted as IDLE (`rc=-5: present corrupt refusal marker admitted IDLE`). A
        // byte-equality test answereth "not this record" for an unparseable or differently-spelled marker, and the
        // visible replacement was then admitted. THE MARKER IS WRITTEN BEFORE EVERY REPLACE AND CLEARED ONLY BY A
        // VERIFIED SYNC, so a standing marker is itself the evidence that an unacknowledged replacement may be in
        // flight -- its CONTENT need not be interpretable. A later successful persist that really synchronizes is what
        // clears it, which boundeth the refusal.*
        if FileManager.default.fileExists(atPath: unackedURL.path) { return .unreadable }
        if let refused = unvouchedRaw, raw == refused { return .unreadable }
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", maxSplits: 1,
                                                                               omittingEmptySubsequences: false)
        // *** THE SUFFIX IS PARSED EVEN WHEN THE HEAD IS MALFORMED. ***
        let suffix = parts.count == 2 ? UInt64(parts[1]) : nil
        let state = parts.first.flatMap { WipeState(rawValue: String($0)) }
        // *** THE PHASE IS PINNED TO THE AUTHORITY: the epoch this record may be ADMITTED at is the durable floor,
        // and only when the record's own suffix reproduces it. `max(suffix, floor)` would let a floor raised by a
        // FAILED REQUESTED write launder the old `IDLE|N` into a settled `(IDLE, N+1)` -- exactly the hole the parent
        // named. A mismatch is therefore UNPINNED: pending/corrupt for admission, never a permit. ***
        let floor = readFloor()
        let pinned = suffix != nil && suffix == floor
        return .record(Record(state: state, epoch: pinned ? suffix : nil, pinned: pinned))
    }

    /// The state the medium carrieth, coerced to `.idle` when the head is unreadable (a caller that must know asks
    /// `isReadable` first).
    private func parseState() -> WipeState {
        if case .record(let r) = medium(), let state = r.state { return state }
        return .idle
    }

    /// *** THE GENERATION THE MEDIUM'S PHASE CARRIETH -- AND ONLY WHEN IT MATCHES THE DURABLE FLOOR (CURRENT-01/02). ***
    /// *A suffix-less record (an old `IDLE` whose generation was lost) and a suffix that disagrees with the floor are
    /// both UNPINNED: the reader answereth `nil`, so no settled/admission question can name a generation from them.*
    private func parseEpoch() -> UInt64? {
        if case .record(let r) = medium() { return r.epoch }
        return nil
    }

    /// *** THE RAW RECORD SUFFIX, AS A LOWER BOUND ONLY. ***
    ///
    /// *Admission NEVER useth this (the phase must be pinned to the floor). Raising the floor DOES: a record whose
    /// suffix disagrees with the floor still carrieth evidence of a generation that was really issued (a legacy file
    /// journal from before the floor existed, or a record written by a failed floor raise), so the next generation
    /// must be strictly above it. Reading it here is what keepeth monotonicity across upgrade and refusal.*
    private func rawSuffixLowerBound() -> UInt64? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return UInt64(parts[1])
    }

    /// True when the durable HEAD is a state this build understands AND its generation is pinned to the floor
    /// (an absent file is a clean start).
    private func headReadable() -> Bool {
        switch medium() {
        case .absent: return true
        case .unreadable: return false
        case .record(let r): return r.state != nil && r.pinned
        }
    }

    /// *** IOS-FOLLOWUP-C2: ATOMIC REPLACEMENT OF THE EXISTING JOURNAL -- NEVER AN UNLINK FIRST. ***
    private func persist(state: WipeState?, epoch: UInt64?) -> DurableWriteResult {
        let raw: String
        switch (state, epoch) {
        case (let s?, let e?): raw = "\(s.rawValue)|\(e)"
        case (let s?, nil): raw = s.rawValue          // the reader treateth a suffix-less record as UNPINNED
        case (nil, let e?): raw = "|\(e)"             // no phase to name: unreadable, never a clean estate
        case (nil, nil): raw = ""
        }
        let tmp = URL(fileURLWithPath: url.path + ".tmp")
        // *** THE INJECTED FILE-SYNC FAULT (IOS-FOLLOWUP-C2 negative control): nothing is replaced, so the OLD
        // record survives untouched -- this is the pre-visibility failure road. ***
        if syncFaultForTest == .file {
            return DurableWriteResult(synchronized: false, epoch: epoch)
        }
        // *** CURRENT-03: THE REFUSAL MARKER PRECEDES VISIBILITY, DURABLY. *** *The bytes are marked unacknowledged
        // BEFORE the replacement can be seen, so no crash and no fresh wrapper can find visible bytes with no refusal
        // on record. If the marker cannot be made durable, the replace MUST NOT happen.*
        if !writeMarkerDurably(raw) {
            return DurableWriteResult(synchronized: false, epoch: epoch)
        }
        do {
            try Data(raw.utf8).write(to: tmp, options: [.atomic])
            let fh = try FileHandle(forWritingTo: tmp)
            try fh.synchronize()
            try fh.close()
            // *** ATOMIC REPLACE: `replaceItemAt` never leaves the record missing. POSIX `rename(2)` is the fallback
            // (also atomic). EITHER WAY the OLD or the NEW record surviveth a crash -- never an absent one. ***
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return DurableWriteResult(synchronized: false, epoch: epoch)   // the marker still refuseth these bytes
        }
        // *** THE INJECTED DIRECTORY-FSYNC FAULT (IOS-FOLLOWUP-C2 negative control): the replacement IS on the medium
        // and its bytes ARE readable -- and it MUST NOT be acknowledged. The durable marker already refuseth them. ***
        if syncFaultForTest == .directory {
            unvouchedRaw = raw
            return DurableWriteResult(synchronized: false, epoch: epoch)
        }
        // THE DIRECTORY ENTRY: fsync the parent so the rename surviveth a crash. A failure here REFUSETH.
        let synced = syncDirectory(url.deletingLastPathComponent().path)
        if synced {
            // THE MEDIUM VOUCHES FOR THIS RECORD: the refusal clears (durably) and the generation is carried.
            unvouchedRaw = nil
            clearMarkerDurably()
            if let epoch { carriedEpoch = epoch; _ = raiseFloor(to: epoch) }
        } else {
            // VISIBLE BUT UNVOUCHED: the marker written above still refuseth these bytes.
            unvouchedRaw = raw
        }
        return DurableWriteResult(synchronized: synced, epoch: epoch)
    }

    // MARK: WipeJournal
    public func read() -> WipeState { lock.lock(); defer { lock.unlock() }; return parseState() }
    public func write(_ state: WipeState) {
        lock.lock(); defer { lock.unlock() }
        var epoch = parseEpoch()
        if epoch == nil {
            // *** CURRENT-01: A PRESENT RECORD OR A STANDING FLOOR IS HISTORY. *** *It is never given the baseline
            // rule: an unknown counter means the generation cannot be named, and a fabricated 1 would recycle it.*
            guard !historyPresent else { return }
            epoch = 1                 // a genuinely NEW estate BEGINNETH at generation 1 (baseline)
        }
        let result = persist(state: state, epoch: epoch)
        if result.synchronized, let epoch { _ = raiseFloor(to: epoch) }
    }
    /// *** IOS-FOLLOWUP-C3 + CURRENT-01: `clear` KEEPETH THE GENERATION, so a later clean baseline cannot REUSE a
    /// previously issued generation (ABA) -- and it REFUSETH to clear at all when the history carrieth no nameable
    /// generation. ***
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        let epoch = parseEpoch() ?? readFloor()
        guard epoch != nil || !historyPresent else { return }   // history with an unknown counter: not a clear
        let result = persist(state: .idle, epoch: epoch)
        if result.synchronized, let epoch { _ = raiseFloor(to: epoch) }
    }

    public var durableEpoch: UInt64? { lock.lock(); defer { lock.unlock() }; return parseEpoch() }

    /// *** THE MEDIUM'S OWN ANSWER, RE-READ FROM THE FILESYSTEM. *** *`nil` when the record is UNREADABLE, so no
    /// cache-less-but-corrupt read is mistaken for a clean one.*
    public func readDurable() -> (state: WipeState, epoch: UInt64?)? {
        lock.lock(); defer { lock.unlock() }
        switch medium() {
        case .absent: return (.idle, nil)
        case .unreadable: return nil
        case .record(let r):
            guard let state = r.state else { return nil }   // a malformed head is NOT a durable answer
            // *** CURRENT-01/02: A PRESENT RECORD WHOSE PHASE IS NOT PINNED NAMES ITS STATE BUT NOT A GENERATION --
            // and the settled/admission roads require BOTH, so it cannot be admitted as a settled estate. ***
            return (state, r.epoch)
        }
    }

    /// *** AN ABSENT FILE IS A CLEAN START; AN UNPARSEABLE ONE IS NOT. ***
    public var isReadable: Bool { lock.lock(); defer { lock.unlock() }; return headReadable() }

    /// *** THE DURABLE FLOOR, FOR A COURT THAT MUST WITNESS MONOTONICITY ITSELF (independent of the state phase). ***
    internal var readFloorForTest: UInt64? { lock.lock(); defer { lock.unlock() }; return readFloor() }

    /// *** THE CHECKED EPOCH RAISE: the generation that REACHED THE MEDIUM, or `nil` when it did not. ***
    ///
    /// *CURRENT-02: it NO LONGER writes the state phase. The old body called `persist(state: parseState(), …)`,
    /// which for an unreadable head is `IDLE` -- so an operator's bump DURABLY REPLACED corruption with a clean record
    /// before `REQUESTED` was written, and a crash in between left a clean IDLE over unerased material. Now only the
    /// INDEPENDENT floor is raised; the phase is written by the checked state write that followeth. And a failed
    /// raise answereth `nil` (never the previous value, which the caller would read as an advance).*
    @discardableResult
    public func bumpEpoch() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        // *** CURRENT-01 (the parent's independent-process probe): A PRESENT JOURNAL WITH NO KNOWN COUNTER IS UNKNOWN
        // HISTORY, NOT A FIRST LAUNCH. ***
        //
        // *The probe wrote a fresh-but-present `idle|invalid` record with NO `.epoch` and watched a bare bump answer
        // `1` -- a reset of a real estate's history to generation 1, exactly what this repair must forbid. So the next
        // generation is computable ONLY from a KNOWN counter (this instance's memory, the durable floor, or a valid
        // record suffix). When none of those exists: a PRESENT record or floor REFUSES (`nil`), and ONLY a genuinely
        // absent estate (`no record, no floor`) is legitimate as the generation-1 baseline. And the successor never
        // wraps: a counter at `UInt64.max` refuses rather than overflowing to 0.*
        // *** NO ALLOCATION: the successor is the max of three OPTIONAL scalars, tracked as a value plus a `hasKnown`
        // flag -- an array and `compactMap` would allocate on every raise for no gain.*
        var known: UInt64 = 0
        var hasKnown = false
        if let value = carriedEpoch { known = value; hasKnown = true }
        if let value = readFloor(), !hasKnown || value > known { known = value; hasKnown = true }
        if let value = rawSuffixLowerBound(), !hasKnown || value > known { known = value; hasKnown = true }
        let next: UInt64
        if hasKnown {
            guard known < UInt64.max else { return nil }     // never wrap to 0
            next = known + 1
        } else if historyPresent {
            return nil                                        // present history, no nameable counter: REFUSE
        } else {
            next = 1                                          // a genuinely NEW estate beginneth at generation 1
        }
        guard raiseFloor(to: next) else { return nil }
        carriedEpoch = next
        return next
    }

    /// *** THE CHECKED RESULT FORM THE PRODUCTION BASELINE AND ADMISSION USE. ***
    ///
    /// *** IOS-FOLLOWUP-CURRENT-03: THE WITNESS IS `writeChecked(_:)`, MATCHING THE PROTOCOL. ***
    /// *It was declared `writeChecked(state:)`; the `WipeJournal` requirement and the adapter's call are
    /// `writeChecked(_:)`, so every checked caller dispatched to the PROTOCOL DEFAULT -- whose "synchronized" result is
    /// a matching REREAD, not this class's real file+directory fsync receipt. The label now matches, so the adapter
    /// (and every court) receives the true medium answer.*
    @discardableResult
    public func writeChecked(_ state: WipeState) -> DurableWriteResult {
        lock.lock(); defer { lock.unlock() }
        var epoch = parseEpoch()
        if epoch == nil {
            // *** CURRENT-01: THE BASELINE RULE APPLIETH ONLY TO A GENUINELY NEW ESTATE. *** *No record at all and no
            // floor: this is a first launch, and generation 1 is legitimate. A PRESENT record (even an unreadable one)
            // or a standing floor is HISTORY: when the floor can NAME the generation the checked write RE-STAMPS the
            // phase with that real number (the authoritative recovery road); when it cannot, the write is REFUSED
            // rather than blessed as generation 1.*
            if !historyPresent {
                epoch = 1
            } else if let floor = readFloor() {
                epoch = floor
            } else {
                return DurableWriteResult(synchronized: false, epoch: nil)
            }
        }
        let result = persist(state: state, epoch: epoch)
        if result.synchronized, let epoch { _ = raiseFloor(to: epoch) }
        return result
    }
}
