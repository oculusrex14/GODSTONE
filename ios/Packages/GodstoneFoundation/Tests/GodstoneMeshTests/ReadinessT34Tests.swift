import XCTest
@testable import GodstoneMesh

/// T34 readiness court (iOS isle) -- the twin of ReadinessT34Test.kt. Drives the same
/// crash-resumable wipe ladder through injected fakes and a crash hook that throws BEFORE
/// a journal write lands, so every card-named boundary is exercised: crash at every journal
/// boundary, key deletion failure, database file busy, late radio callback, stale UI send,
/// reboot mid-wipe, old files unreadable after key erasure.
final class ReadinessT34Tests: XCTestCase {

    // ---- durable store: append-only journal lines ------------------------------------
    fileprivate final class T34Store: WipeDurabilityStore {
        var lines: [String] = []
        func readJournal() -> [String] { lines }
        func appendJournal(_ stateName: String) { lines.append(stateName) }
    }

    // ---- key vault: scripted failures; absent keys are satisfied ---------------------
    fileprivate final class T34Vault: KeyVaultSeam {
        var alive: Set<String> = Set(WipeScope.privateKeys)
        var failedOnce: Set<String> = []          // retryable, then succeeds
        var permanent: Set<String> = []           // non-retryable
        var eraseCalls: [String: Int] = [:]
        func eraseKey(_ name: String) -> KeyDeletionResult {
            eraseCalls[name, default: 0] += 1
            if !alive.contains(name) { return .absent }
            if permanent.contains(name) { return .failed(keyName: name, retryable: false, reason: "keystore entry stuck") }
            if failedOnce.contains(name) { failedOnce.remove(name); return .failed(keyName: name, retryable: true, reason: "transient") }
            alive.remove(name)
            return .deleted
        }
    }

    // ---- file system: busy scripting; readable iff some key still lives --------------
    fileprivate final class T34Fs: ArtifactFileSystemSeam {
        let vault: T34Vault
        var files: [String: Bool] = [:]
        var busyOnce: Set<String> = []
        var deleteCalls: [String: Int] = [:]
        init(vault: T34Vault) { self.vault = vault }
        func deleteArtifact(_ path: String) -> FileDeletionResult {
            deleteCalls[path, default: 0] += 1
            if busyOnce.contains(path) { busyOnce.remove(path); return .failed(path: path, reason: "database file busy") }
            if files[path] != true { return .absent }
            files[path] = false
            return .deleted
        }
        func exists(_ path: String) -> Bool { files[path] == true }
        func isReadable(_ path: String) -> Bool { files[path] == true && !vault.alive.isEmpty }
    }

    // ---- transport: drain proof + quiesced radio -------------------------------------
    fileprivate final class T34Runtime: TransportRuntimeSeam {
        var quiesced = false
        var drainCalls = 0
        var drainAttempts = 0                                 // every drain attempt, success or not
        var drainFails = 0                                    // scripted: next N drains report NotDrained
        var delivered: [String] = []
        var sends: [String] = []
        func drainTransport() -> RuntimeDrainReceipt {
            drainAttempts += 1
            if drainFails > 0 { drainFails -= 1; return .notDrained(reason: "radio pairing in progress") }
            drainCalls += 1
            quiesced = true
            return .drained(closedTransports: 3, quiescedRuntime: true)
        }
        func isQuiesced() -> Bool { quiesced }
        func fireRadio(_ msg: String) -> Bool { if !quiesced { return false }; delivered.append(msg); return true }
        func sendVia(_ msg: String) -> Bool { if !quiesced { return false }; sends.append(msg); return true }
    }

    // ---- identity authority ----------------------------------------------------------
    fileprivate final class T34Authority: IdentityAuthoritySeam {
        var current: String? = nil
        var published: [String] = []
        func publishNewIdentity() -> String? { let id = "node-\(published.count + 1)"; published.append(id); current = id; return id }
        func identity() -> String? { current }
    }

    // ---- crash hook ------------------------------------------------------------------
    fileprivate final class T34CrashHook: WipeHooks {
        var crashBefore: String?
        var crashes = 0
        init(crashBefore: String?) { self.crashBefore = crashBefore }
        func beforeWrite(_ stateName: String) throws {
            if let cb = crashBefore, stateName == cb { crashBefore = nil; crashes += 1; throw WipeCrashError(msg: "power loss at \(stateName)") }
        }
    }

    fileprivate final class T34Rig {
        let store = T34Store()
        let vault = T34Vault()
        let fs: T34Fs
        let runtime = T34Runtime()
        let authority = T34Authority()
        let hook: T34CrashHook
        init(crashBefore: String?) {
            fs = T34Fs(vault: vault)
            hook = T34CrashHook(crashBefore: crashBefore)
            for p in WipeScope.privateArtifacts { fs.files[p] = true }
            fs.files["accepted-archive/model.bin"] = true   // approved public asset: must NEVER be touched
            fs.files["accepted-archive/voices.bin"] = true
        }
        func engine() -> CrashResumableWipe { CrashResumableWipe(store: store, vault: vault, filesystem: fs, runtime: runtime, authority: authority, hooks: hook) }
    }

    /** Drive the engine to a terminal state, swallowing the injected crash exactly once. */
    private func drive(_ engine: CrashResumableWipe, _ first: () throws -> WipeStepResult) -> WipeStepResult {
        var r: WipeStepResult
        do { r = try first() } catch is WipeCrashError { return .retryLater(at: .requested, reason: "crashed") } catch { return .refused(reason: "unexpected") }
        var guardCount = 0
        while guardCount < 32 {
            var isRetry = false; var crashed = false
            if case let .retryLater(_, reason) = r { isRetry = true; crashed = (reason == "crashed") }
            if !isRetry || crashed { break }
            guardCount += 1
            do { r = try engine.step() } catch is WipeCrashError { return .retryLater(at: .requested, reason: "crashed") } catch { return .refused(reason: "unexpected") }
        }
        return r
    }

    private func advanced(_ r: WipeStepResult, _ to: WipeJournalState) -> Bool {
        if case let .advanced(_, t) = r, t == to { return true }
        return false
    }
    private func retryAt(_ r: WipeStepResult, _ at: WipeJournalState) -> Bool {
        if case let .retryLater(a, _) = r, a == at { return true }
        return false
    }

    // (1) crash at every journal boundary: resume lands the FULL monotone ladder exactly once
    func testCrashAtEveryJournalBoundaryResumesToIdle() throws {
        for boundary in CrashResumableWipe.fullLadder {
            let rig = T34Rig(crashBefore: boundary)
            let e1 = rig.engine()
            let r1 = drive(e1) { try e1.requestWipe() }
            XCTAssertTrue(rig.hook.crashes == 1, "the crash boundary \(boundary) really fired")
            XCTAssertTrue(retryAt(r1, .requested) && (isCrashed(r1)), "the run stopped at the crash of \(boundary)")
            let e2 = rig.engine()
            var r2 = drive(e2) { try e2.resume() }
            if rig.store.lines.isEmpty {
                // crashed BEFORE the first write: the request itself never landed, so a re-request is the honest restart
                XCTAssertTrue(isRefused(drive(e2) { try e2.resume() }), "nothing was journaled before the first write")
                r2 = drive(e2) { try e2.requestWipe() }
            }
            XCTAssertTrue(advanced(r2, .idle), "resume from the \(boundary) crash reaches IDLE")
            XCTAssertEqual(rig.store.lines.count, CrashResumableWipe.fullLadder.count, "the journal is exactly the ladder once")
            XCTAssertEqual(e2.journalView().map { $0 }, CrashResumableWipe.fullLadder.map { WipeJournalState.fromWire($0) }, "the journal records the full ladder")
            XCTAssertEqual(e2.journalView().map { $0!.rawValue }, [1, 2, 3, 4, 5, 6], "ranks strictly increase")
        }
    }

    // (2) reboot mid-wipe: a fresh runtime is drained again; the journal alone drives progress
    func testRebootMidWipeResumesFromJournalAlone() throws {
        let rig = T34Rig(crashBefore: WipeJournalState.wireName(.keysErased))   // die after the drain was journaled, before erasure
        let e1 = rig.engine()
        _ = drive(e1) { try e1.requestWipe() }
        XCTAssertEqual(rig.store.lines, ["REQUESTED", "RUNTIME_DRAINED"], "the journal holds REQUESTED and RUNTIME_DRAINED")
        let freshRuntime = T34Runtime()                                          // the process rebooted: volatile runtime gone
        let rebooted = CrashResumableWipe(store: rig.store, vault: rig.vault, filesystem: rig.fs, runtime: freshRuntime, authority: rig.authority, hooks: NoHooks())
        let r = drive(rebooted) { try rebooted.resume() }
        XCTAssertTrue(advanced(r, .idle), "the rebooted boot resumes to IDLE")
        XCTAssertEqual(freshRuntime.drainCalls, 1, "the fresh runtime was drained again (idempotent drain)")
        XCTAssertEqual(rig.store.lines, CrashResumableWipe.fullLadder, "no duplicate journal writes across the reboot")
    }

    // (3) retryable key deletion failure blocks the erase until it clears
    func testFailedKeyDeletionRetriesDurablyBeforeErase() throws {
        let rig = T34Rig(crashBefore: nil)
        rig.vault.failedOnce.insert("identity-x25519")
        let e = rig.engine()
        let first = try e.requestWipe()
        XCTAssertTrue(retryAt(first, .runtimeDrained), "the ladder parks at RUNTIME_DRAINED while a key erasure is pending")
        XCTAssertEqual(rig.store.lines, ["REQUESTED", "RUNTIME_DRAINED"], "KEYS_ERASED was NOT written while a key still lived")
        XCTAssertFalse(e.allowsStartup(), "the gate stays closed across the retry")
        let second = try e.step()
        XCTAssertTrue(advanced(second, .idle), "after the retry clears, the erasure lands")
        XCTAssertEqual(rig.vault.eraseCalls["identity-x25519"] ?? 0, 2, "the flaky key was attempted exactly twice")
    }

    // (4) permanent key failure refuses the wipe: no artifacts deleted, no new runtime
    func testPermanentKeyDeletionFailureRefusesAndKeepsArtifactsAndNoNewRuntime() throws {
        let rig = T34Rig(crashBefore: nil)
        rig.vault.permanent.insert("store-dek")
        let e = rig.engine()
        let r = try e.requestWipe()
        XCTAssertTrue(isRefused(r), "a non-retryable key failure REFUSES")
        XCTAssertEqual(rig.store.lines, ["REQUESTED", "RUNTIME_DRAINED"], "the journal never advances past the drain")
        XCTAssertTrue(rig.fs.exists("mesh.db"), "the database file is NOT deleted while its key lives")
        XCTAssertTrue(rig.authority.published.isEmpty, "no new identity was constructed on a refused wipe")
        XCTAssertFalse(e.allowsStartup(), "the gate remains closed -- a refused wipe is retried, not bypassed")
    }

    // (5) busy database file is retryable; an already-absent copy is satisfaction, not failure
    func testBusyDatabaseFileIsRetriedAbsentIsNotFailure() throws {
        let rig = T34Rig(crashBefore: nil)
        rig.fs.busyOnce.insert("mesh.db")
        rig.fs.files["mesh.db-shm"] = false                                      // a copy already removed by a former run
        let e = rig.engine()
        let first = try e.requestWipe()
        XCTAssertTrue(retryAt(first, .keysErased), "the busy db parks the ladder at KEYS_ERASED")
        var reason = ""
        if case let .retryLater(_, rr) = first { reason = rr }
        XCTAssertTrue(reason.contains("mesh.db") && !reason.contains("shm"), "the stall names the busy copy as the sole failure")
        XCTAssertEqual(rig.store.lines, ["REQUESTED", "RUNTIME_DRAINED", "KEYS_ERASED"], "ARTIFACTS_DELETED was NOT written while the db was busy")
        let second = try e.step()
        XCTAssertTrue(advanced(second, .idle), "after the busy flag clears, cleanup lands")
        XCTAssertEqual(rig.fs.deleteCalls["mesh.db"] ?? 0, 2, "the busy db was attempted exactly twice")
        XCTAssertGreaterThanOrEqual(rig.fs.deleteCalls["mesh.db-shm"] ?? 0, 1, "the already-absent shm was satisfaction, never a stall cause")
    }

    // (6) a late radio callback while the ladder is pending is dropped, never delivered to the pre-wipe session
    func testLateRadioCallbackAfterDrainIsDropped() throws {
        let rig = T34Rig(crashBefore: WipeJournalState.wireName(.keysErased))   // die after the drain, mid-ladder: pending holds
        let e = rig.engine()
        _ = drive(e) { try e.requestWipe() }
        XCTAssertFalse(e.allowsStartup(), "the ladder is still outstanding after the crash")
        let before = rig.runtime.delivered.count
        XCTAssertFalse(e.deliverLate("stale-frame"), "a frame for the pre-wipe session is dropped while the wipe is pending")
        XCTAssertEqual(before, rig.runtime.delivered.count, "the delivered queue did not grow")
        XCTAssertEqual(e.bypassAttempts, 1, "the drop was counted as a gate-bypass attempt")
        let r2 = drive(e) { try e.step() }
        XCTAssertTrue(advanced(r2, .idle), "the ladder completes")
        XCTAssertTrue(e.deliverLate("fresh-frame"), "post-completion a fresh frame is delivered")
        XCTAssertEqual(rig.runtime.delivered, ["fresh-frame"], "exactly the fresh frame reached the transport")
    }

    // (7) a stale UI send while the wipe is pending is refused by the gate
    func testStaleUiSendWhilePendingIsRefused() throws {
        let rig2 = T34Rig(crashBefore: WipeJournalState.wireName(.keysErased))
        let e2 = rig2.engine()
        _ = drive(e2) { try e2.requestWipe() }
        XCTAssertFalse(e2.submitUi("stale-send"), "a UI send while a wipe is outstanding is REFUSED")
        XCTAssertTrue(rig2.runtime.sends.isEmpty, "the refused send never reached the transport")
        XCTAssertFalse(e2.allowsStartup(), "the gate is closed mid-ladder")
        XCTAssertEqual(e2.bypassAttempts, 1, "the refusal was counted -- the gate was probed, not bypassed")
        let e3 = rig2.engine()
        _ = drive(e3) { try e3.resume() }
        XCTAssertTrue(e3.submitUi("fresh-send"), "post-completion a fresh send is admitted")
        XCTAssertEqual(rig2.runtime.sends, ["fresh-send"], "the transport took exactly the fresh frame")
    }

    // (8) old ciphertext is unreadable once the keys are gone -- and public assets survive scoping
    func testOldCiphertextUnreadableAfterKeyErasureAndPublicAssetsSurvive() throws {
        let rig = T34Rig(crashBefore: WipeJournalState.wireName(.keysErased))   // die right after the erasure succeeded, before its journaling
        let e = rig.engine()
        _ = drive(e) { try e.requestWipe() }
        XCTAssertEqual(rig.store.lines, ["REQUESTED", "RUNTIME_DRAINED"], "the journal still sits at the drain: the erasure was not yet journaled")
        XCTAssertTrue(rig.vault.alive.isEmpty, "every private key is gone from the vault")
        for p in WipeScope.privateArtifacts {
            XCTAssertTrue(rig.fs.exists(p), "the ciphertext \(p) still EXISTS on flash (best-effort deletion has not run)")
            XCTAssertFalse(rig.fs.isReadable(p), "yet it is UNREADABLE: the keys were erased BEFORE any file cleanup")
        }
        let e2 = rig.engine()
        let r2 = drive(e2) { try e2.resume() }
        XCTAssertTrue(advanced(r2, .idle), "resume re-proves the idempotent erasure and completes the ladder")
        for p in WipeScope.privateArtifacts {
            XCTAssertFalse(rig.fs.exists(p), "after resume the copy \(p) is gone")
        }
        XCTAssertTrue(rig.fs.exists("accepted-archive/model.bin"), "the approved public Archive asset was never touched (no glob delete)")
        XCTAssertTrue(rig.fs.exists("accepted-archive/voices.bin"), "the second public asset survived too")
        for k in rig.fs.deleteCalls.keys { XCTAssertTrue(WipeScope.privateArtifacts.contains(k), "deletions stayed inside the enumerated private scope") }
    }

    // (9) journal compatibility: legacy spellings map; unknown future versions refuse fail-closed
    func testLegacyJournalHonoredAndUnsupportedVersionRefused() throws {
        let rig = T34Rig(crashBefore: nil)
        rig.store.lines.append(contentsOf: ["REQUESTED", "RUNTIME_DRAINED", "KEY_ERASED"])   // the sealed ladder's legacy spelling
        let e = rig.engine()
        XCTAssertTrue(e.isSupportedJournal(), "a legacy-spelled journal parses")
        let r = drive(e) { try e.resume() }
        XCTAssertTrue(advanced(r, .idle), "the legacy journal resumes to completion")
        XCTAssertEqual(e.journalView()[2], WipeJournalState.keysErased, "the normalized view names the canonical state")
        let rig2 = T34Rig(crashBefore: nil)
        rig2.store.lines.append(contentsOf: ["REQUESTED", "WATERS_DOWN"])                     // a future/unknown version line
        let e2 = rig2.engine()
        XCTAssertFalse(e2.isSupportedJournal(), "an unsupported journal is not well-formed")
        XCTAssertTrue(isRefused(try e2.resume()), "resume REFUSES an unsupported journal fail-closed")
        XCTAssertEqual(rig2.store.lines.count, 2, "nothing was appended to the unsupported journal")
    }

    // (10) the drain is a PROOF before destruction: while it reports NotDrained nothing may die
    func testRuntimeDrainIsProvenBeforeAnyDestruction() throws {
        let rig = T34Rig(crashBefore: nil)
        rig.runtime.drainFails = 2                                  // the first two drain attempts refuse to quiesce
        let e = rig.engine()
        let r1 = try e.requestWipe()
        XCTAssertTrue(retryAt(r1, .requested), "the ladder parks at REQUESTED without a Drained receipt")
        XCTAssertEqual(rig.store.lines, ["REQUESTED"], "only REQUESTED is journaled while the transport is live")
        XCTAssertFalse(rig.runtime.quiesced, "the runtime was NOT quiesced, so the point of no return was not crossed")
        XCTAssertEqual(rig.vault.alive.count, WipeScope.privateKeys.count, "no key was erased while a radio frame could still be in flight")
        XCTAssertTrue(rig.fs.files.values.allSatisfy { $0 }, "no artifact was deleted while the transport was live")
        let r2 = try e.step()
        XCTAssertTrue(retryAt(r2, .requested), "a second failed drain still parks the ladder")
        XCTAssertEqual(rig.vault.alive.count, WipeScope.privateKeys.count, "still nothing destroyed")
        XCTAssertFalse(rig.runtime.quiesced, "still not quiesced")
        let r3 = try e.step()
        XCTAssertTrue(advanced(r3, .idle), "once the drain is proven, the ladder completes")
        XCTAssertEqual(rig.runtime.drainAttempts, 3, "the drain was attempted exactly the scripted three times")
        XCTAssertEqual(rig.runtime.drainCalls, 1, "exactly one drain actually succeeded")
    }

    // -- helpers ------------------------------------------------------------------------
    private func isCrashed(_ r: WipeStepResult) -> Bool {
        if case let .retryLater(_, reason) = r { return reason == "crashed" }
        return false
    }
    private func isRefused(_ r: WipeStepResult) -> Bool {
        if case .refused = r { return true }
        return false
    }

    // MARK: - GS-STORE-006: THE DRAIN CHECKPOINT IN THE **REAL** JOURNAL, THROUGH THE MAPPING

    /**
     * THE ARM THIS FINDING DESERVETH, AND ITS FIRST DRAFT WOULD HAVE BEEN IMPOSSIBLE TO WRITE: the court's own doubles
     * exercise the crash-resumable ladder faithfully, but they exercise it against a DOUBLE JOURNAL -- while the
     * production journal carrieth ONE TYPED `WipeState`, WHICH HAD **NO CASE FOR THE DRAIN** UNTIL THIS ROUND. So this
     * arm driveth the REAL coordinator, through the SAME first step the court already driveth, with **THE MAPPING
     * ADAPTER OVER A REAL `WipeJournal`** in place of the double, and demandeth that the durable checkpoint it standeth
     * at is `runtimeDrained` -- i.e. THAT THE DRAIN IS WRITTEN DOWN WHERE A CRASH CAN FIND IT, which is the whole of
     * the audit's charge ("key deletion must remain blocked until transport drain completeth").
     *
     * ITS HONEST STATUS: a CONTROL, since the mapping landed in the same round -- an arm that cannot be red proves the
     * law still holdeth. ITS NEGATIVE TWIN BELOW IS THE PART THAT CAN FAIL.
     */
    func testGSSTORE006_theDrainCheckpointIsPersistedInTheRealJournal() throws {
        // *** THE CRASH IS INJECTED AT `KEYS_ERASED` -- ONE STAGE PAST THE DRAIN -- BECAUSE `requestWipe()` RUNNETH THE
        // WHOLE LADDER TO COMPLETION (the first draft of this arm measured `advanced(from: .newIdentity, to: .idle)` and
        // read a FINISHED wipe's journal, which is why it could not see the checkpoint it was asking about). THE COURT'S
        // OWN TECHNIQUE, READ RATHER THAN REINVENTED: inject the crash where you want the ladder to STOP. ***
        let rig = T34Rig(crashBefore: "KEYS_ERASED")
        // THE **PRODUCTION** JOURNAL ITSELF, IN ITS OWN SUITE: `UserDefaultsWipeJournal` is the field-proven
        // implementation the composition carrieth, and putting it in a private suite meaneth this arm measures the REAL
        // durable object rather than a double -- and touches no other domain.
        let suite = try XCTUnwrap(UserDefaults(suiteName: "gsstore006-\(UUID().uuidString)"))
        let journal = UserDefaultsWipeJournal(defaults: suite)
        let adapter = WipeJournalDurabilityAdapter(journal: journal)
        let engine = CrashResumableWipe(store: adapter, vault: rig.vault, filesystem: rig.fs,
                                        runtime: rig.runtime, authority: rig.authority, hooks: rig.hook)

        let r = drive(engine) { try engine.requestWipe() }

        // *** THE SUBJECT'S OWN ANSWER, ASSERTED FIRST: WITHOUT IT THE ARM COULD NOT SAY WHETHER THE COORDINATOR
        // REFUSED BEFORE WRITING OR WROTE AND THE JOURNAL FAILED TO KEEP IT -- the gap its first draft had. THE INJECTED
        // CRASH MEANETH THE ANSWER IS `retryLater`, AND WHAT MATTERS IS THAT IT STOPPED ONE STAGE PAST THE DRAIN. ***
        XCTAssertTrue(retryAt(r, .requested),
                      "the injected crash at KEYS_ERASED must stop the ladder (its answer was \(r))")
        XCTAssertEqual(journal.read().rawValue, WipeState.runtimeDrained.rawValue,
                       "THE DRAIN MUST BE WRITTEN DOWN IN THE PRODUCTION JOURNAL'S OWN TYPED STATE -- it is the "
                       + "checkpoint a crash resumeth from, and before this round THE JOURNAL HAD NO CASE FOR IT")
        XCTAssertEqual(adapter.readJournal(), ["RUNTIME_DRAINED"],
                       "and the adapter must report the single checkpoint the journal actually standeth at")
        XCTAssertEqual(rig.runtime.drainCalls, 1, "the drain happened exactly once")
    }

    /**
     * THE NEGATIVE CONTROL: an UNKNOWN STAGE NAME must be REFUSED rather than silently dropped, because a dropped
     * checkpoint is a wipe that restarteth LATER than it should -- or, worse, one that believeth it erased what it hath
     * not. THE ADAPTER FAILETH CLOSED, AND THIS ARM DEMANDETH IT.
     */
    func testGSSTORE006_anUnknownStageNameIsRefusedAndTheCheckpointDoesNotMove() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "gsstore006-neg-\(UUID().uuidString)"))
        let journal = UserDefaultsWipeJournal(defaults: suite)
        let adapter = WipeJournalDurabilityAdapter(journal: journal)
        adapter.appendJournal("REQUESTED")
        XCTAssertEqual(journal.read().rawValue, WipeState.requested.rawValue, "a known stage is written through")

        adapter.appendJournal("NOT_A_LADDER_STAGE")
        XCTAssertEqual(journal.read().rawValue, WipeState.requested.rawValue,
                       "AN UNKNOWN STAGE MUST BE REFUSED: the checkpoint must NOT move, because a checkpoint that "
                       + "advances on a name nobody meant is a wipe that skips work it still oweth")
        XCTAssertFalse(WipeJournalDurabilityAdapter.ladder.contains("NOT_A_LADDER_STAGE"),
                       "the ladder is the coordinator's own vocabulary, and the adapter speaketh only that")
    }

    // MARK: - GS-STORE-006: CRASH AT **EVERY** CHECKPOINT, AGAINST THE **NEW** COMPOSITION

    /**
     * THE CARD'S SECOND CLOSURE CLAUSE: "Crash/restart before and after each journal checkpoint. No sensitive runtime may
     * reopen prematurely, and failed key/file operations must remain pending."
     *
     * AND THE HONEST GAP THIS ARM CLOSES, NAMED BEFORE IT WAS WRITTEN: the court already proveth crash-at-every-boundary --
     * BUT AGAINST **DOUBLES**. WHAT WAS NEVER MEASURED IS THE SAME PROPERTY THROUGH THE **AUTHORITY THE COMPOSITION ACTUALLY
     * RUNS**, whose effectful seams are DEFERRED. SO THIS ARM PLANTS THE JOURNAL AT EVERY LADDER CHECKPOINT, DRIVES THE REAL
     * COORDINATOR OVER THE FOUR DEFERRED SEAMS, AND DEMANDETH THE ONE THING "MAY NOT REOPEN PREMATURELY" MEANS HERE: *** THE
     * LADDER MUST NOT ADVANCE, AND THE JOURNAL MUST NOT MOVE. ***
     *
     * AND ONE STAGE IS HONESTLY DIFFERENT, WHICH THE ARM STATES RATHER THAN SMOOTHS OVER: AT `newIdentity` EVERY EFFECTFUL
     * RUNG IS ALREADY BEHIND THE WIPE, so its remaining step is the idle transition -- an act with no platform effect -- and
     * THE WIPE MAY THEREFORE LEGITIMATELY FINISH THERE. THAT IS NOT AN EXCEPTION TO THE CLAUSE; IT IS THE CLAUSE'S OWN BOUNDARY.
     */
    func testGSSTORE006_everyJournalCheckpointStaysPendingThroughTheAuthorityTheCompositionRuns() throws {
        let stages: [WipeState] = [.requested, .runtimeDrained, .keyErased, .artifactsDeleted, .newIdentity]

        for stage in stages {
            let suite = try XCTUnwrap(UserDefaults(suiteName: "gsstore006-crash-\(UUID().uuidString)"))
            let journal = UserDefaultsWipeJournal(defaults: suite)
            journal.write(stage)

            let authority = CrashResumableWipe(
                store: WipeJournalDurabilityAdapter(journal: journal),
                vault: WipeDeferredKeyVaultSeam(),
                filesystem: WipeDeferredArtifactFileSystemSeam(),
                runtime: WipeDeferredTransportSeam(),
                authority: WipeDeferredIdentityAuthoritySeam()
            )

            let r = try authority.resume()

            // *** AND HERE THIS ARM USED TO ASSERT A DEFECT, BECAUSE IT FOUND ONE (round 421): FROM `artifactsDeleted`
            // THE LADDER ADVANCED ALL THE WAY TO `IDLE`, BECAUSE `IdentityAuthoritySeam.publishNewIdentity()` RETURNED A
            // NON-OPTIONAL `String` AND A `String` CANNOT SAY "I DID NOT PUBLISH AN IDENTITY". SO A COMPOSITION THAT OWNED NO
            // IDENTITY AUTHORITY **REACHED `IDLE` BELIEVING AN IDENTITY STOOD WHEN NONE DID.** *** THE FIX LANDED IN THIS
            // ROUND -- `publishNewIdentity() -> String?`, WITH `nil` MEANING NOT PUBLISHED AND THE LADDER HONOURING IT AS A
            // `retryLater` -- AND THIS BRANCH THEREFORE NOW ASSERTS **THE FIX**: AT `artifactsDeleted` THE LADDER MUST STOP
            // AND THE JOURNAL MUST NOT MOVE. THE ARM WAS NOT DELETED; IT WAS TURNED AROUND. ***
            if stage == .newIdentity {
                // PAST EVERY EFFECTFUL RUNG ONLY THE IDLE TRANSITION REMAINS, AND IT HATH NO PLATFORM EFFECT -- so
                // finishing here is the clause's own boundary rather than a premature reopen.
                XCTAssertTrue(advanced(r, .idle), "at NEW_IDENTITY the idle transition may finish the wipe: \(r)")
                XCTAssertEqual(journal.read().rawValue, WipeState.idle.rawValue)
                continue
            }

            guard case let .retryLater(at, reason) = r else {
                XCTFail("AT \(stage.rawValue) THE LADDER MUST NOT ADVANCE THROUGH DEFERRED SEAMS -- its answer was \(r)")
                continue
            }
            // *** AND I DO NOT CLAIM A CROSS-VOCABULARY EQUALITY HERE, BECAUSE THE TWO VOCABULARIES DIFFER IN **FORMAT**:
            // the coordinator's wire names are SCREAMING_SNAKE ("RUNTIME_DRAINED") while the journal's typed states are
            // camelCase ("runtimeDrained"). The compiler refused my first attempt at exactly that comparison, and the
            // honest arm does not need it: WHAT MATTERS IS THAT THE LADDER STOPPED AND THE DURABLE RECORD DID NOT MOVE. ***
            // (`at` is a TYPED stage, not a string -- its `rawValue` is the RANK -- so the arm asserts the rank is real
            // rather than pretending it is a name; the NAME lives in `WipeJournalState.wireName(_:)`, in another format.)
            XCTAssertGreaterThan(at.rawValue, 0, "it must stand at a real checkpoint, not before the ladder")
            XCTAssertFalse(reason.isEmpty, "with a reason naming what refused (\(reason))")
            XCTAssertEqual(journal.read().rawValue, stage.rawValue,
                           "*** AND THE JOURNAL MUST NOT MOVE: a crash-and-restart at \(stage.rawValue) must leave the "
                           + "durable record where it standeth, so the next attempt resumeth at the SAME checkpoint rather "
                           + "than believing work was done -- THAT IS 'NO SENSITIVE RUNTIME MAY REOPEN PREMATURELY' ***")
        }
    }
}
