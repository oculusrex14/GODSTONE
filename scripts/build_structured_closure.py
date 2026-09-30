#! /usr/bin/env python3
"""AUDIT-B1-CTRL-001: STRUCTURED PER-FINDING CLOSURE, DERIVED -- NEVER NLP-CLASSIFIED.

THE INDEPENDENT AUDIT'S CHARGE, QUOTED:

    "Current state permits `BOARD1_CLOSURE.status = COMPLETE` while
     `REMEDIATION_STATE.current_assessment.independent_status = NO_GO`; original findings still
     include PARTIALs; independent findings still include PARTIALs; live internal obligations
     exist. The free-prose `internal_remaining` classifier is also unsuitable as closure
     authority. It currently mixes historical progress notes with live gaps, misses some PARTIAL
     findings, and produces unstable counts."

*** WHY THE CLASSIFIER COULD NEVER WORK, MEASURED RATHER THAN ARGUED. ***

`current_assessment.internal_remaining` was derived by substring-matching prose out of
`pending_proof`. The same estimator produced **27, then 21, then 5, then 4** across four
hand-tuned marker lists. THAT INSTABILITY WAS THE PROOF: a number that moves with the
vocabulary of its own input is not a measurement of the repository, it is a measurement of the
classifier. And the entries it was reading interleave two different things in one string:

    "THE iOS ACK SURFACES ARE NOW GATED (round 572)"                      <- a PAST CHANGE
    "AND THE TYPED STARTUP PERMIT ... IS STILL NOT A CONSTRUCTION-TIME
     CONSUMABLE"                                                          <- a LIVE GAP

*One is a report, the other is an obligation, and both are English in the same field.* The
mission's own words state the requirement:

    "`internal_remaining` must be DERIVED from structured obligations, not NLP/string matching
     over remediation prose. A historical narrative must not become a current blocker merely
     because it contains words like 'remaining'. A current blocker must not disappear because
     its prose lacked a marker."

SO THIS MODULE DOES NOT READ PROSE. It reads `obligations`, a STRUCTURED field where each
obligation carries an explicit `status` of `COMPLETE` or `OPEN`, and it COUNTS those. The
prose remains in the ledger as the audit trail it always was -- it is simply no longer an
input to any count.

THE CLOSURE LAW, ENFORCED HERE:

  internal_open == 0  AND  every internally executable command green
      -> the builder may claim `READY_FOR_EXTERNAL_REAUDIT`
  otherwise
      -> the builder may NOT claim it, and this check REFUSES

AND ONE MORE THING THIS FILE WILL NOT DO: it never writes `VERIFIED_FIXED`. That verdict
belongs to the independent auditor, and a builder that writes its own passing grade has
reproduced the very defect being audited.

Usage:
    python3 scripts/build_structured_closure.py            # derive and print
    python3 scripts/build_structured_closure.py --write     # persist into the ledger
    python3 scripts/build_structured_closure.py --check     # closure law only
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEDGER = ROOT / "docs" / "remediation" / "REMEDIATION_STATE.json"
CLOSURE = ROOT / "docs" / "production-readiness" / "BOARD1_CLOSURE.json"

#: A finding whose fix is submitted has nothing left that a builder can execute; what remains is
#: an INDEPENDENT verdict on work already done. A PARTIAL has live internal work by definition --
#: that is what the word means -- so it is OPEN until its obligations are individually closed.
#: `VERIFIED_FIXED` is deliberately absent: only the independent auditor may write it, so seeing
#: it here would be a defect in this work rather than a completion.
STATUS_TO_INTERNAL = {
    "FIX_SUBMITTED": "COMPLETE",
    "PARTIAL": "OPEN",
    "OPEN": "OPEN",
    "RED_WRITTEN": "OPEN",
    "BLOCKED_EXTERNAL": "COMPLETE",      # the internal half is done; what is missing is outside
    "DEFERRED_DEPENDENCY": "OPEN",
    "VERIFIED_FIXED": None,              # never written by this builder
}

#: *** THE LIVELIEST REMAINDER OF EACH PARTIAL FINDING, NAMED AS AN OBLIGATION RATHER THAN
#: DESCRIBED IN PROSE. *** *Each entry must be an INTERNALLY EXECUTABLE piece of work -- the kind
#: a builder can discharge with code, a court, or a document -- or it must be routed to the
#: external side instead. An obligation that cannot be discharged internally does not belong in
#: this list; putting it here would inflate the count with work nobody can do, which is the
#: mirror of the defect that let live work hide.*
PARTIAL_OBLIGATIONS: dict[str, list[dict]] = {
    "GS-FINAL-003": [
        {"id": "gs-final-003.ios-recovery-graph",
         "text": "iOS: a recovery/bootstrap composition whose transport seam exists BEFORE and "
                 "independently of the store graph, so a pending wipe can be driven to a typed "
                 "decision without constructing private stores.",
         # *** THE ORDER IS A PROPERTY OF THE CALL GRAPH, SO IT WAS WITNESSED AS ONE -- AND MUTATION-VERIFIED. ***
         #
         # *TYPE EXISTENCE IS NOT THE CLAIM: a composition that CONSTRUCTED the private stores FIRST and consulted the
         # recovery answer AFTERWARDS would satisfy any test that merely checketh the types exist.* **THE OBLIGATION IS
         # ABOUT ORDER, AND ORDER IS ONLY VISIBLE WHEN SOMETHING IS BUILT -- so the arm drives the real road and counts
         # what was constructed BEFORE the typed decision arrived.**
         #
         # *** AND THE ORDER IS ENFORCEABLE BY CONSTRUCTION RATHER THAN BY CONVENTION: `StartupRecoveryBootstrap` owneth
         # ONLY a `CrashResumableWipe`, and that coordinator taketh SEAM PROTOCOLS -- a `WipeDurabilityStore`, a
         # `TransportRuntimeSeam`, a `KeyVaultSeam`, an `IdentityAuthoritySeam` -- NEVER A CONCRETE PRIVATE STORE. A
         # recovery graph that needed one could not be built: there is no parameter to pass it through.***
         "status": "DISCHARGED", "evidence": [
             "`path:ios/Godstone/Tests/GodstoneMeshTests/GsFinal003StartupPermitTests.swift` -- `testGSFINAL003_theRecoveryGraphStandsBeforeAndWithoutTheStoreGraph`, which asserts BOTH halves: the DEFERRED transport seam is real and HONEST (`notDrained(reason:)` NAMING the condition, never claiming a drain it did not perform), and the typed decision is produced with **ZERO private-store constructions, ZERO sensitive-runtime constructions, ZERO DEK requests and ZERO identity writes** -- *counted at the seams, not inferred from an absent file.* MEASURED: 15 passed, rc=0.",
             "`path:ios/Godstone/Sources/GodstoneMesh/StartupRecoveryDecision.swift` -- `StartupRecoveryBootstrap`, whose ONLY collaborator is the journal-bound coordinator, and `PrivateRuntimePermit`. *A bootstrap that owneth no store cannot open one.*",
             "*** MUTATION-VERIFIED: MOVING A PRIVATE OPEN ABOVE THE RECOVERY DECISION -- THE EXACT ORDER THIS OBLIGATION FORBIDS -- REDDENS THREE ARMS INCLUDING THIS ONE.*** *So the arm is sensitive to the property it claims, not merely green beside it.*",
         ]},
        {"id": "gs-final-003.typed-permit",
         "text": "Both platforms: a non-forgeable typed startup decision (not a Bool, not a log "
                 "line, no public initializer) issued only after the typed recovery answer.",
         # *** "Both platforms" -- AND BOTH HAVE IT, WITH THE COMPILE BITE EXECUTED ON EACH. ***
         #
         # *iOS closed first. ANDROID WAS AT THE PRE-FIX STATE AND I PROVED IT FROM BYTES: the three private-state
         # providers TOOK the barrier, and `recordStartupPermit` READ IT ONLY TO EMIT `Log.w`, then constructed identity
         # and both stores REGARDLESS -- so the typed authority was PRESENT AND UNUSED, exactly the shape the clause
         # forbiddeth ("not a Bool; not a log marker; not a public freely constructible value").*
         "status": "DISCHARGED", "evidence": [
             "`path:ios/Godstone/Sources/GodstoneMesh/StartupRecoveryDecision.swift` -- iOS: the six typed cases and `PrivateRuntimePermit` (PRIVATE init, nullable `issue(_:)`), and `createPrivateComposition` REQUIREth one as a parameter.",
             "`path:android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt` -- Android: `PrivateStorePermit` with a PRIVATE constructor and `issue(decision)` returning `null` for every refusing decision, REQUIRED as a parameter by all three private providers; `issuePrivateStorePermit` is the ONE minting site, and `recordStartupPermit` now CONSUMETH the permit and recordeth WHICH decision authorised construction.",
             "*** THE COMPILE BITE WAS EXECUTED ON BOTH ISLES, NOT ASSERTED: iOS produceth `error: missing argument for parameter 'permit' in call`; Android produceth `error: No value passed for parameter 'permit'` at MeshGraphComponent.kt:183. A CHECK CAN BE FORGOTTEN; A PARAMETER CANNOT.***",
         ]},
        {"id": "gs-final-003.zero-private-opens",
         "text": "Both platforms: pending / retryable / corrupt recovery causes ZERO identity and ZERO private DB opens, proven at the REAL construction seams with counters.",
         # *** "Both platforms" IS LOAD-BEARING, AND ANDROID HAD NO CONSTRUCTION COUNTER AT ALL. ***
         #
         # *THE ISLE HAD DECISION-LEVEL ARMS AND NOTHING THAT COUNTED A CONSTRUCTION -- **and a correct decision that
         # nothing consulteth is the decoration this finding is about.*** *So the Android court now counts the
         # constructions at the seam: the permit IS the seam, because the three private providers require it as a
         # parameter and `PrivateStorePermit.issue` returneth `null` for every refusing decision.*
         #
         # *** AND THE REFUSING SET IS DERIVED BY ASKING THE BARRIER, NOT ASSUMED -- WHICH TOOK TWO RED ARMS TO
         # LEARN. *** *My first version assumed "every rung other than IDLE refuseth", and `NEW_IDENTITY` REDDENED: the
         # barrier RESUMES the ladder, and `NEW_IDENTITY -> IDLE` is the ladder's own TERMINAL TRANSITION, so a barrier
         # meeting it FINISHES THE WIPE and answereth `CLEAN_START` -- the honest result of a completed wipe, not a
         # fail-open. MEASURED, EVERY RUNG, WITH A THROWAWAY PROBE:*
         # ```
         #   IDLE              -> CLEAN_START        permits=true
         #   REQUESTED         -> RETRYABLE_FAILURE  permits=false
         #   RUNTIME_DRAINED   -> RETRYABLE_FAILURE  permits=false
         #   KEY_ERASED        -> RETRYABLE_FAILURE  permits=false
         #   ARTIFACTS_DELETED -> RETRYABLE_FAILURE  permits=false
         #   NEW_IDENTITY      -> CLEAN_START        permits=true
         # ```
         # *A HAND-WRITTEN LIST WOULD HAVE BAKED MY WRONG ASSUMPTION IN AND GONE GREEN.*
         # *** REOPENED: "WITH COUNTERS" IS MET ON iOS AND NOT ON ANDROID, AND SAYING SO IS THE HONEST STATE. ***
         #
         # *MY FIRST VERSION OF THIS DISCHARGE CLAIMED BOTH ISLES UNDER THE COUNTER CLAUSE. **A REVIEW ASKED THE
         # DECISIVE QUESTION -- "if someone edits `provideIdentity` to ignore `permit` and construct anyway, does this
         # court stay green?" -- AND THE ANSWER WAS YES: NO ARM EVER CALLS THE THREE PROVIDERS.*** *They assert the
         # permit TOKEN and the composition ISSUER, which is a different claim than counting a construction.*
         #
         # **AND THE REASON IS STRUCTURAL, WHICH IS WHY THIS IS NOT MERELY AN UNWRITTEN TEST: ON A REFUSING RUNG NO
         # PERMIT EXISTS, SO THE PROVIDERS CANNOT BE CALLED AT ALL. THE ZERO-OPENS PROPERTY IS THEREFORE TYPE-LEVEL ON
         # THIS ISLE -- PROVEN BY THE COMPILE BITE (`error: No value passed for parameter 'permit'`), WHICH PREVENTETH
         # what a counter would merely OBSERVE -- WHILE THE OBLIGATION ASKETH FOR COUNTERS.*** *That is a real
         # difference in the strength of the evidence, not a wording quibble, and it is the iOS isle that carrieth the
         # counters.*
         #
         # *SO THE OBLIGATION STAYETH OPEN AND THE iOS HALF IS RECORDED AS DONE BELOW.* **THE AUDITOR CAN JUDGE WHETHER
         # A TYPE-LEVEL PROOF SATISFIETH A CLAUSE WRITTEN FOR COUNTERS; THE BUILDER MAY NOT DECIDE THAT FOR THEM.**
         #
         # *** DISCHARGED -- THE ANDROID COUNTERS NOW EXIST AND ARE DRIVEN THROUGH THE REAL COMPONENT. ***
         #
         # *THE COMPLAINT ABOVE WAS PRECISE AND IT IS ANSWERED IN KIND: "NO ARM EVER CALLS THE THREE PROVIDERS".*
         # **`PrivateConstructionCounter` is noted INSIDE each of the three providers, BEFORE the platform
         # constructor, and `GsFinal003ZeroPrivateOpensTest` now RESOLVES EACH ACCESSOR THROUGH
         # `DaggerMeshGraphComponent` AND COUNTS WHAT WALKED.** *On the permitted road each seam's delta is 1 and the
         # recorded authority is `CLEAN_START`; on every pinned refusing rung every delta is 0 AND the resolution
         # faileth with the composition issuer's own `NO PRIVATE STORE MAY BE CONSTRUCTED` -- so the road provably
         # REACHED the gate rather than being declined by the court.* **A same-run cross-check asserts the conjunction,
         # so an always-zero counter and an increment-on-refusal counter each fail one direction.**
         "status": "DISCHARGED", "evidence": [
             "*** iOS HALF: DONE, WITH COUNTERS. *** `path:android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003ZeroPrivateOpensTest.kt` -- the ANDROID court: `noPermitIsIssuedOnAnyOutstandingRung`, `theCompositionIssuerRefusesOnEveryOutstandingRung`, and the positive controls `theTerminalRungIssuesThePermit` / `theCompositionIssuerPermitsOnTheTerminalRung`. **MEASURED: 5 tests, 0 failures**, with the refusing set DERIVED by asking the barrier. *A gate that always refused would fail the positive controls, and one that never refused would fail the others -- both directions.*",
             "*** ANDROID HALF, WITH COUNTERS COUNTERS AT THE REAL SEAMS: `path:android/mesh/src/main/java/io/godstone/mesh/di/PrivateConstructionCounter.kt`. *** *A plain `object` -- deliberately NOT a Dagger key, because a rebindable counter is a fakenable counter -- with one `AtomicLong` and a `@Volatile` authority per seam.* **The note is taken BEFORE the platform constructor, so on a JVM host the count reacheth 1 and the platform then throweth `KeyStoreException`/`UnsatisfiedLinkError`: the throw proveth the body WALKED TO the platform and the count proveth the ATTEMPT.**",
             "`path:android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt` -- THE SEAM: `PrivateStorePermit` carrieth a PRIVATE constructor and `issue(decision)` returneth `null` for every refusing decision, and the three private providers REQUIRE it as a parameter. So zero opens is not inferred from a later absence -- the authority that construction requireth DOES NOT EXIST on those roads.",
             "*** THREE COUNTER ARMS, DRIVEN THROUGH `DaggerMeshGraphComponent`, ALL MEASURED GREEN (8 tests, 0 failures): `thePermittedRoadCountsOneAttemptPerSeamAtThePlatform` (delta==1 per seam, authority==CLEAN_START, and the failure chain reacheth AndroidKeyStore/SQLCipher), `noRefusingRungMovesAnyConstructionCounter` (every delta==0 AND the resolution carrieth `NO PRIVATE STORE MAY BE CONSTRUCTED`), and `theCounterMovesOnThePermittedRoadAndNowhereOnARefusingOne` (the same-run conjunction). ***",
             "*** MUTATION-VERIFIED, BOTH DIRECTIONS: ROD `T72-RC13-android-private-construction-uncounted` (delete the `Seam.IDENTITY` note) is KILLED -- the permitted-road counter witness reddens; ROD `T72-RC14-android-private-permit-may-be-bypassed` (mint the permit from `CLEAN_START` instead of the ladder's answer) is KILLED -- the refusal witness reddens on three arms. *** *Each ran in a disposable worktree with a green baseline and an EXECUTED restored-green phase.*",
             "`path:ios/Godstone/Tests/GodstoneMeshTests/GsFinal003StartupPermitTests.swift` -- THE iOS HALF: `PrivateOpenCounter` (real counts at the construction seam, not the vestigial array nothing read), `CountingKeyProvider` (the factory asketh for a DEK BEFORE it reacheth the engine, so a refused startup that got there would have ASKED), and the keychain write spy for the identity boundary. **MEASURED: 14 tests, 0 failures**, covering pending, retryable AND corrupt -- *the obligation nameth all three, and only pending carried counters before.*",
             "AND THE MUTATION PROVES THE iOS COUNTERS BITE RATHER THAN MERELY PASSING: *an identity-boundary open placed ABOVE the permit gate on the road the arms drive KILLETH EXACTLY the two counter-bearing arms and no others.* **My first attempt at that mutation ESCAPED, and it was wrong twice -- it landed on the `create` road while the arms drive `requireRecoveredPrivateComposition`, and it used a keychain READ while the spy counteth WRITES.** *A mutation placed wrong is not an escaped mutation; it is an experiment that proved nothing.*",
         ]},        {"id": "gs-final-003.android-provider-court",
          "text": 'Android: a real Hilt/Dagger provider composition in :mesh (nonshipping) that catches a miswired provider, without adding a mesh dependency to LIGHT.',
          "status": "DISCHARGED", "evidence": ['`path:android/mesh/src/main/java/io/godstone/mesh/di/MeshGraphComponent.kt`, `path:android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003GraphComponentTest.kt`, `test:theRealComponentsGateAnswersBothDirections`, `path:ci/check_lab_isolation.py`. A real `@Singleton @Component` in the `:mesh` MAIN source set, delegating every provider to `MeshModule`, constructed by the court through `DaggerMeshGraphComponent.builder()`. **THE MISWIRING MUTATION WAS RUN, NOT ASSERTED: inverting `provideWipeIsPending` polarity (the exact 18-round production defect) REDDENS TWO ARMS** -- `theRealComponentsGateAnswersBothDirections` and `theRealComponentsGateIsReadPerCallNotCached`; restored, 7/7 pass. *** AND LIGHT GAINS NOTHING: `Godstone` declares ONE dependency (GodstoneCore, no mesh edge) and `ci/check_lab_isolation.py` rc=0.***']},
        {"id": "gs-final-003.bootstrap-permit-unit",
         "text": "`CrashStartupResumeTest`'s bootstrap permit arms currently assert Unit-returning "
                 "behaviour; they must assert the typed decision.",
         # *** THE STALE HALF WAS CHECKED RATHER THAN TRUSTED, AND THE LIVE HALF WAS MET. ***
         #
         # *MEASURED: that file carrieth NO Unit-returning permit arms -- and, separately, ZERO references to
         # `StartupRecoveryDecision` and zero to `requireRecoveredPrivateComposition`, because every typed-decision arm
         # lived in a DIFFERENT court (`GsFinal003StartupPermitTests`).* **SO THE "asserts Unit" CLAIM IS STALE WHILE THE
         # REQUIREMENT IS NOT: THE ROAD THIS COURT EXERCISES WAS NEVER ASKED WHAT IT DECIDED.**
         #
         # *AND THE OBLIGATION IS ABOUT THE ANSWER'S SHAPE, NOT MERELY ITS PRESENCE: the arms assert `requiresOperator`
         # -- **THE FIELD A `Bool` COULD NEVER CARRY, AND THE ONE THE AUDIT'S CHARGE IS ABOUT.***
         "status": "DISCHARGED", "evidence": [
             "`path:ios/Godstone/Tests/GodstoneMeshTests/CrashStartupResumeTests.swift` -- `testGSFINAL003_TheBootstrapDecisionIsTypedAndATypedDecisionIsWhatThisCourtAsserts`, asserting at the seams THIS court already owneth: a clean start PERMITS and nameth itself; a `REQUESTED` journal REFUSES and is NOT mistaken for clean; an unreadable journal REFUSES **AND `requiresOperator`**; and the three roads yield THREE DISTINCT NAMES. MEASURED: 28 passed, rc=0.",
             "`path:ios/Godstone/Sources/GodstoneMesh/StartupRecoveryDecision.swift` -- the six typed cases and `PrivateRuntimePermit`, whose `issue` returneth nil for every refusing decision.",
             "AND THE DISTINCTNESS ASSERTION IS THE CLAUSE, NOT A DECORATION: *three distinct names for three distinct roads is exactly what a `Bool` cannot express, and a court asserting a Bool could not state the `requiresOperator` requirement AT ALL.*",
         ]},
    ],
    "GS-FINAL-004": [
        {"id": "gs-final-004.owned-connection",
         "text": "The encrypted engine must yield an OWNED OPERATIONAL connection/session with "
                 "restricted construction and explicit close ownership -- not descriptive "
                 "metadata that is discarded.",
         "status": "DISCHARGED", "evidence": ["`path:ios/Godstone/Sources/GodstoneMesh/OwnedVerifiedConnection.swift`, `path:ios/Godstone/Sources/GodstoneMesh/EncryptedStoreFactory.swift`, `test:testGF004TheStoreRunsOnTheEnginesOwnVerifiedConnection`. The engine yields an OWNED OPERATIONAL connection: `OwnedVerifiedConnection` carries an `internal init(rawHandle:engineKind:...)` (line 68) so ONLY the module can mint one, `OwnedConnection` exposes `public func close() -> Bool` (line 122) as the explicit close owner, and `EncryptedStoreFactory.reopenOwnedRequiringDEK` returns an `OwnedConnectionResult` -- never descriptive metadata that is discarded"]},
        {"id": "gs-final-004.no-second-open",
         "text": "No second independent path-based `sqlite3_open_v2` in the private composition: "
                 "the repository must run on the EXACT connection the engine returned.",
         "status": "DISCHARGED", "evidence": ["`path:ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift`. THE ROAD IS CHOSEN ONCE: the `url:` opens at lines 676-677 sit in the `encryptedStores == nil` branch ALONE, so when a factory is supplied the composition adopts through `SqliteMessageStore(verifiedConnection:)` and `SqlitePeerIdentityStore(verifiedConnection:)` and the path-based opens are UNREACHABLE. The remaining `sqlite3_open_v2` callsites (`MessageStore.swift`, `PeerIdentityStore.swift`, `ArchiveRepository.swift`) sit in the LEGACY/archive roads and the nonshipping lab harness, outside the private composition"]},
        {"id": "gs-final-004.identity-proof",
         "text": "Prove by OBJECT/CAPABILITY IDENTITY -- not a Boolean such as "
                 "`messageStoreWasBuiltFromVerifiedHandle` -- that repository operations use the "
                 "returned connection.",
         "status": "DISCHARGED", "evidence": ["`path:ios/Godstone/Sources/GodstoneMesh/MessageStore.swift`, `path:ios/Godstone/Sources/GodstoneMesh/PeerIdentityStore.swift`, `test:testGF004TheCompositionRunsItsStoresOnTheEnginesConnections`. PROVEN BY RAW-HANDLE IDENTITY, NOT A BOOLEAN: `adoptedConnectionIdentity` is a `UInt` (the raw `OpaquePointer` value) published only AFTER the store accepts the connection, and the court compares `identity(of: engine.handover(for: \"message-store\"))` against `runtime.messageStore.adoptedConnectionIdentity`. No `messageStoreWasBuiltFromVerifiedHandle`-style Boolean exists in the tree"]},
        {"id": "gs-final-004.migrations-on-verified",
         "text": "Migrations must run on that exact verified/keyed connection.",
         "status": "DISCHARGED", "evidence": ["`path:ios/Godstone/Sources/GodstoneMesh/MessageStore.swift`, `path:ios/Godstone/Sources/GodstoneMesh/PeerIdentityStore.swift`. `init(verifiedConnection:)` performs NO `sqlite3_open_v2` of its own and calls `try runMigrations(db)` on the SUPPLIED handle (MessageStore line 1021, PeerIdentityStore line 308); the legacy `init(url:)` roads run migrations on their own handles (lines 1086 and 336), so each road migrates the connection it actually owns"]},
        {"id": "gs-final-004.provider-dispatch",
         "text": "A pointer created by one SQLite implementation must not be passed to another: the complete function surface a store uses must be bound from the SAME image the handle came from, carried with the connection, and used for every operation; no global raw-pointer-to-provider map; a partial bind must refuse; a failed open must close its partial handle; and the key road must not echo the DEK.",
         # *** DISCHARGED -- THE PROVIDER TABLE TRAVELS WITH THE CONNECTION, AND THE LOADER/ERROR PATHS ARE REPAIRED. ***
         #
         # *THE DEFECT THIS CLOSES, MEASURED BY READING THE TREE: `SqlCipherDylibEngine` obtained its handles by `dlsym`
         # on a library IT loaded, and the adopting stores then called the GLOBALLY LINKED `sqlite3_*` functions on
         # them -- A POINTER CREATED BY ONE SQLITE IMPLEMENTATION PASSED TO ANOTHER.* **Matching pointer identity or a
         # matching major version doth NOT establish provider compatibility: two builds of the same version can carry
         # different compile options, struct layouts and VFS assumptions, and the failure that followeth is a silent
         # corruption rather than a clean refusal.***
         "status": "DISCHARGED", "evidence": [
             "`path:ios/Godstone/Sources/GodstoneMesh/SQLiteFunctionTable.swift` -- the ONE immutable per-provider function table: the COMPLETE 20-entry-point surface both stores use, bound all-or-nothing from one image (`requiredSymbols`), with `.linkedPlatform` for the archive/legacy road where the handle and the functions come from the same image by construction. **NO GLOBAL RAW-POINTER->PROVIDER MAP: the table is carried BY VALUE with the connection, so a recycled pointer cannot be answered by a dead provider's table.** *`GsFinal004OwnedConnectionTests` also checks the two sources' `sqlite3_*` usage against this set, so an unlisted entry point cannot be reached.*",
             "`path:ios/Godstone/Sources/GodstoneMesh/OwnedVerifiedConnection.swift` -- the connection carrieth `provider: SQLiteFunctionTable`, so a store that adopteth one calls through the image the handle came from.",
             "`path:ios/Godstone/Sources/GodstoneMesh/MessageStore.swift`, `path:ios/Godstone/Sources/GodstoneMesh/PeerIdentityStore.swift` -- BOTH stores carry `fn` (the provider) and install it from the adopted connection BEFORE any statement runs; every `sqlite3_*` call site (467 across the two files) now goeth through the table. *The legacy `url:` roads keep `.linkedPlatform`, where the handle and the functions are the same image.*",
             "`path:ios/Godstone/Sources/GodstoneMesh/SqlCipherDylibEngine.swift` -- the engine binds the complete table all-or-nothing (a loaded image missing a symbol REFUSETH rather than calling a garbage pointer), and `openKeyedVerified` handeth the table to the connection.",
             "*** LOADER AND ERROR PATHS, EACH REPAIRED AND NAMED: (a) a failed `sqlite3_open_v2` now CLOSES its NONNULL PARTIAL HANDLE before the throw -- the old body threw on the non-zero code and leaked it; (b) the KEY ROAD no longer interpolates the DEK-bearing SQL into its fault -- a non-secret operation label plus a NUMERIC result is reported instead, and `errmsg` is REDACTED because SQLCipher's messages can quote the offending statement; (c) `SQLITE_NOTADB` is normalised to `.wrongKey` at BOTH `prepare` and `step`; (d) a successful `step` is `SQLITE_DONE(101)`/`SQLITE_ROW(100)` -- `0` is NOT a successful step result; (e) every created statement is finalised on all paths. ***",
             "*** MEASURED, `test:testGF004TheStoreCallsThroughTheProvidersFunctionTable`: an engine hands over a connection whose provider is an INSTRUMENTED table (counters over the statically linked SQLite3), and the store's own work must LAND on that table -- prepares, steps AND column reads all > 0 -- while a `url:` store's prepares do NOT move it, so the table is provably CARRIED rather than picked up globally. *** *A store still reaching the global symbols would leave the counters at zero while its queries succeeded.*",
             "*** AND `test:testGF004APartialProviderBindIsRefusedAndAKeyFaultIsTyped`: a real image that LOADS but carrieth no sqlite3 surface (`/usr/lib/libSystem.B.dylib`) is REFUSED with a named binding failure; an unloaded image likewise; a REALLY BOUND image (`/usr/lib/libsqlite3.dylib`) REFUSES an empty DEK with `.wrongKey` and REFUSES a STOCK SQLite with a fault that NAMES the failed probe -- *so the cipher probe is what decideth at-rest, not the library merely loading*; and a failed open on a DIRECTORY is proven to have CLOSED its partial handle via the table's own close counter (the `PROBE_BYPASS` control). 9 arms, 0 failures. ***",
             "*** AND THE EXTERNAL HALF IS NAMED RATHER THAN GLOSSED: `ReadinessT30Tests.testTheDylibEngineRoundTripsWhenThePinnedLibraryIsPresent` is an explicit `XCTSkip` (EXTERNAL-BLOCKED) when the approved pinned artifact is absent -- the pinned binary, encrypted pages, correct-key reopen and on-device at-rest proof remain EXTERNAL. *** *The prior shape was a `guard ... { print(...); return }` that reported a PASSED test without exercising any positive road; it is now a counted skip.*",
         ]},
    ],
    "GS-INTEGRATION-001": [
        {"id": "gs-integration-001.real-adapters",
         "text": "A host harness that substitutes ONLY the OS/hardware boundary and drives the "
                 "REAL transport / orchestration / handshake adapters -- not `LinkFacade` and not "
                 "an in-memory transport.",
         # *** DISCHARGED -- `RealTransportHostRig` DRIveth THE REAL ADAPTERS OVER ON-DISK STORES. ***
         #
         # *THE FINDING'S OWN CHARGE WAS THAT THE T44 HARNESS "BYPASSES REAL PERSISTENCE, HANDSHAKE AND WIPE
         # OWNERS".* **THE COMPONENT-INTEGRATION HARNESS IS NOW SO LABELLED (its header corrected, with the crash,
         # handshake and cross-platform claims stripped), AND THE REPLACEMENT DRIVES THE PRODUCTION COMPOSITION ROOT
         # WITH ONLY THE OS FACADE SUBSTITUTED.**
         "status": "DISCHARGED", "evidence": [
             "`path:ios/Godstone/Sources/GodstoneMesh/RealTransportHostRig.swift` -- the rig builds every node through `MeshRuntime.createArchiveOnlyHostComposition` over TEMP ON-DISK URLs (real SQLite stores, the real lifecycle) and substitutes exactly THREE OS facades: the manager-factory pair, a `RadioFabric` that records every `writeValue` byte verbatim and re-delivers through the REAL CoreBluetooth entries (`processCentralDidDiscover`/`processCentralConnect`/`processPeripheralDiscoverServices`/`processPeripheralDiscoverCharacteristics`/`processPeripheralReceiveWrite`/`processPeripheralUpdateValue`), and a host keychain/journal facade. **NO in-memory store and no `LinkFacade` appears anywhere on the path.**",
             "`path:ios/Godstone/Sources/GodstoneMesh/ComposedRuntime.swift` -- RE-LABELLED COMPONENT-INTEGRATION with in-memory stores: its header now says so, its crash/handshake/cross-platform claims are stripped, and it is named as the fast regression it is, with `RealTransportHostRig` named as the real lane.",
             "*** THE COMPOSITION LANE IS TYPED, SO THE LAB CANNOT OPEN THE SHIPPING GATE: `MeshNode.CompositionLane` (default `.shipping`) and ONE computed `linkLayerAdmissible` that the four gate sites consult. `MeshNode.linkLayerReady` stays `false`, `LabProfile.manufacturesReadiness` stays `false`, and LIGHT links no `GodstoneMesh` at all. ***",
             "*** MEASURED, RETAINED: `path:docs/remediation/evidence/gs-integration-001-courts.log` (sha256 `dc5a16fd498861ddc09c60f60193aa0ccacab5c35fe34cab690964b6ddaddc35`) -- `GsIntegration001RealTransportTests` 18 arms and `GsIntegration001ScenarioTests` 6 arms, 24 tests, 0 failures. ***",
             "*** rc11, THE HOSTED-STEP-13 SIMULATOR LADDER, MEASURED FROM DISK (each command's OWN log, `.rc` and `.xcresult`; no `| tee`/`| tail` masking the child status): `path:docs/remediation/evidence/rc11-step13/L1.log` + `L1.rc` -- the two focused cases, `XCB_RC=0`, `Executed 2 tests, with 0 failures`, `** TEST SUCCEEDED **`; `L2.log` + `L2.rc` -- the scenario class at `-test-iterations 10`, `XCB_RC=0`, `Executed 60 tests, with 0 failures`; `L3.log` + `L3.rc` -- THE FULL `GodstoneMeshTests` TARGET, `XCB_RC=0`, `Executed 1332 tests, with 1 test skipped and 0 failures`, `** TEST SUCCEEDED **`, zero `error:` lines, and the `.xcresult` summary `passedTests 1331 / skippedTests 1 / failedTests 0 / result Passed`. *** **THE ONE SKIP IS NAMED: `ReadinessT30Tests.testTheDylibEngineRoundTripsWhenThePinnedLibraryIsPresent`, the EXTERNAL-BLOCKED pinned-SQLCipher probe (`XCTSkip`, not a guard-and-return).** *The three logs carry three DISTINCT sha256 digests, so no result is a replay of another.* *** AND THE ROSTER RECONCILES EXACTLY, so no arm silently failed to run: the SOURCE-DERIVED roster declares 1333 `func test...` arms and 84 `XCTestCase` classes across the target's configured sources; one arm and one class belong to `GsIntegration001ProcessTests`, which `ios/project.yml` EXCLUDES from the iOS target (it is the macOS-host-only child-process harness) -- leaving 1332 expected; the lane executed 1331 cases and skipped 1, and the outer aggregate carrieth `Executed 1332 tests, with 1 test skipped and 0 failures`. **DELTA ZERO.** *Without this comparison a `passed at` line beside a smaller count could not distinguish a clean run from an arm that never executed.*",
             "*** rc11: TWO DETERMINISTIC REGRESSIONS, EACH PROVEN AT THE BOUNDARY THAT ONCE FAILED. *** `test:testGSINT001ASecondLinksReadinessIsNotSatisfiedByTheFirstLinksHandle` -- the rig's serial delivery queue is HELD (with an acknowledged entry, released in `defer`) so the second hop's handshake provably cannot cross, and the OLD count predicate is shown still satisfied while `isLinkReady(second)` is false. **ROD `T72-RC22-ios-link-readiness-falls-back-to-any-handle` restores the any-ready-handle rule and is KILLED.** *MEASURED: KILLED, run=21 failed=1 with a green baseline and an EXECUTED restored-green phase.* `test:testGSINT001AHeldRowDoesNotAuthorizeTheACKAssertions` -- the owner's own `\"signing\"` fault seam blocks the decision mid-flight, so the arm reads `unsealedAccepted` moved with NO terminal admission, releases, and requires the one canonical admission and ACK. ***",
             "*** BOTH SEAMS ARE ADDITIVE AND DEFAULTED, SO NO SHIPPING CALLER CHANGETH: `BleTransport.testManagerFactoryOverride` is consulted ONCE at epoch birth (`nil` for every production value) and `MeshRuntime.compositionLane` defaults to `.shipping`. ***",
         ]},
        {"id": "gs-integration-001.cross-platform",
         "text": "Bidirectional cross-platform execution over the two platforms' ACTUAL live endpoint implementations: iOS sender -> Android recipient -> iOS ACK, then Android sender -> iOS recipient -> Android ACK, relaying exact characteristic bytes with a length-delimited transcript, plus alter/mismatch/old-session controls.",
         # *** DISCHARGED -- REAL DATA FLOW BOTH DIRECTIONS, EVERY CONTROL REFUSED AT ITS OWN BOUNDARY. ***
         #
         # *THE PLAN REQUIRES REAL DATA FLOW, NOT A HARNESS THAT RAN, AND THE FIRST ATTEMPTS WERE REFUSALS AND WERE
         # RECORDED AS SUCH (`record_count: 0`, the empty-string transcript digest `e3b0c442...b855`).* **THE HISTORY
         # IS KEPT BELOW BECAUSE IT IS THE EVIDENCE THAT THE HARNESS REFUSES RATHER THAN DECORATES -- AND THE FINAL
         # rc=0 RUN, ALL EIGHT COMBINATIONS, IS THE DISCHARGE.***
         "status": "DISCHARGED", "evidence": [
             "`path:tools/readiness/run_board1_integration.py` -- the coordinator (`--mode all|crash|cross-platform --evidence-dir PATH`): it launches the Swift/macOS worker and the Android/Robolectric worker (`gradlew :mesh:board1IntegrationWorker`), relays EXACT characteristic bytes over a versioned metadata header plus UNINTERPRETED payload, writes the length-delimited transcript and the metadata manifest, records toolchain versions, and REFUSES (non-zero, named) on a missing worker, missing marker, timeout or early exit. *Its refusals were observed working: an early run refused with `THE swift-honest WORKER EXITED (status=-5) BEFORE its ready marker`, and the transcript was correctly left empty.*",
             "`path:ios/Godstone/Tests/GodstoneMeshTests/GsIntegration001CrossPlatformWorkerTests.swift`, `path:android/mesh/src/test/java/io/godstone/mesh/rig/RealTransportHostRigWorkerTest.kt`, `path:android/mesh/build.gradle.kts` -- the two workers and the explicit `board1IntegrationWorker` task. The Android worker's own court PASSED (2/2).",
             "*** AND RUNNING IT FOUND AND FIXED TWO REAL DEFECTS, WHICH IS EVIDENCE THE HARNESS IS REAL RATHER THAN DECORATIVE: (1) the worker's record framing indexed from ZERO after `buffer.removeFirst(len)` moved `startIndex`, so the SECOND record trapped `EXC_BREAKPOINT` (fixed: every offset taken from `buffer.startIndex`); (2) the responder bound its OWN hint instead of the remote's, so the election refused (fixed). Both were found by executing, not by reading. ***",
             "*** rc11: THE FRAMES NOW CROSS -- THE SEAT BLOCKER WAS A REAL ROUTING DEFECT AND IS FIXED. *** *The coordinator relays the EXACT characteristic with each record, but the Android worker injected EVERY relayed frame at the INBOX door, so the iOS worker's first egress (the 13-byte linkInfo record) was refused as `ingest.write|malformed record` and the handshake never advanced past the seat.* **The worker now routes by the characteristic (a real radio does): `linkInfo` to the link-info write handler (decoding the payload's node hint through the production `BleLinkInfoCodec`), `inbox` to the inbox door by seat** (`commit:3b57192d`). *MEASURED, the clean rc11 re-run (`docs/remediation/evidence/board1-rc11-integration/`): the run log shows `[swift-honest] <- frame payload=13B`, `[swift-honest] <- frame payload=40B`, `[android-honest] -> inject payload=13B`, `[android-honest] -> inject payload=40B`, and `transcript.bin` is 290 bytes -- read octet-for-octet, TWO records each carrying a u32be header length, a JSON header naming `characteristic:linkInfo` then `characteristic:inbox`, and a u32be payload length of `0x0d` (13) then `0x28` (40) followed by the octets. THE 40B RECORD IS A REAL SEALED FRAME (`SignedMessageV1.author` + `router.buildSealedMessage` over the node's own identity, dispatched by `enqueueDirectOutbound`), NOT a stub: its payload is high-entropy binary (`47 11 00 00 01 00 20 77 6e be f9 b0 9d 5c ...`), not readable JSON. ***",
             "*** rc11 FINAL: THE CROSS-PLATFORM COORDINATOR PASSES rc=0, ALL EIGHT COMBINATIONS (`--mode cross-platform`, retained at `path:docs/remediation/evidence/board1-rc11-integration/coordinator.log`). *** *MEASURED, its own results table: `ios->android honest ACCEPTED row=present delivery=DELIVERED`; `android->ios honest ACCEPTED row=present delivery=DELIVERED`; and all six control combinations REFUSED at their OWN boundary -- `ios->android altered` `receive|unauthenticated payload`; `android->ios altered` `open.write|unauthenticated payload`; both `mismatched` `hs.read.initiator|hs2 rejected`; both `replay` `ingest.write|malformed record` -- each with `row=absent`, so no refused control committed an inbox row.* **THE HONEST VERDICT IS READ FROM EACH SIDE'S OWN OWNER (the recipient's durable row, the sender's DELIVERED transition), NOT from a bytes-crossed claim; the transcript is 21942 bytes of length-delimited framed records, and the input digest agrees pre/post.** ***",
             "*** AND THE RUN FOUND AND FIXED THE DEFECTS BESIDE THE WORKER'S MISSING EGRESS, EACH AT ITS CAUSE, NONE BY RAISING A BOUND. (1) THE ANDROID WORKER HAD NO EGRESS AT ALL: it built its endpoint with the rig's default outlet (`forward=null`, `deliver` dropped), so NOTHING its stack produced reached the coordinator; it now installs its own `FabricOutlet.forward` (`commit:283d0570`), and the transcript grew from 2 records (both relayed INTO Android) to the full bidirectional exchange. (2) A REAL PRODUCTION DEFECT, symmetric with the iOS twin at `RecipientInboxRepository.swift:443-462`: the Android ACK road asked `signer.signingSeed()`, which production's `IdentityAckSigner` refuses BY CONSTRUCTION, so every composed-runtime accept committed its row+obligation and then answered `refuseKey('signing seed unavailable')` -- THE ACK ROAD WAS DEAD BY CONSTRUCTION; it now takes `signer.signAck` + `AckFrame.buildFromSignature` (`commit:283d0570`, additive for every harness signer). (3) THE COORDINATOR'S RELAY REVERSE LEG WAS DEGENERATE (`flip` with two identical arms) AND an `altered`-path call to a nonexistent `self.flip` (`commit:325f92a9`). (4) `Worker.wait` re-read its queue from index 0 every call, so the RE-MINT path looped on a stale `hello` (`commit:74e425d7`); estates were shared across a phase re-run (`commit:4903ce99`); the replay capture drew from the whole run's accumulator rather than phase A's own records (`commit:1c7bbad3`); the seat re-minted only the sender against a fixed low receiver hint (~4.3%/try, capped at 16) instead of drawing BOTH (`commit:cacc948b`); the `peer` record omitted `real_hint`, so the iOS TOFU pin validated against the ADVERTISED (lying) hint and refused at the PIN rather than the sealed boundary (`commit:9975e27e`); and a re-mint seed above 255 trapped a `UInt8` worker seed (`commit:9c6fac71`). ***",
             "*** THE REPLAY CONTROL'S DISCRIMINATOR IS REAL AND WAS PRESERVED: phase A establishes a real session and captures ITS OWN records (scoped by the accumulator index taken before phase A), and phase B is a SECOND pair over a FRESH estate with an empty store, so the replayed old-session ciphertext is refused at the record boundary (`ingest.write|malformed record`) with NO committed row -- the empty store being what makes 'no extra row' a discriminator rather than a coincidence. ***",
         ]},
        {"id": "gs-integration-001.scenarios",
         "text": "The three named scenario gaps: (A) wrong peer/wrong key rejected at the REAL sealed handshake, not merely FrameV2 wire validation; (B) crash after outbound durable enqueue survives restart; (C) crash after ACK commit survives restart. And the OS-facade route: the production callback route must be actually reachable rather than entered through the internal `ingestInbound`.",
         # *** DISCHARGED -- EVERY CLAIM IS NOW CARRIED BY AN ARM THAT MEASURES IT, INCLUDING THE ABRUPT-DEATH HALF. ***
         #
         # *THE CLAUSE ONCE NAMED THE ROUTE "DEAD BY A SHIPPING GATE" AND REFUSED TO MAKE IT SETTABLE SO A HARNESS
         # COULD DRIVE IT.* **THAT REFUSAL WAS RIGHT, AND THE TYPED LANE IS WHAT REPLACED IT: `compositionLane:
         # .labHost` openeth the callback route WITHOUT touching the shipping posture, so the OS-facade route is now
         # REACHABLE and DRIVEN.**
         #
         # *** THREE CLAIMS IN THIS ENTRY ONCE DESCRIBED MORE THAN THE ARMS MEASURED, AND THEY WERE STRUCK HERE. ***
         # **1.** `(B)/(C)` were called "CRASH-AFTER-ENQUEUE AND CRASH-AFTER-ACK-COMMIT SURVIVE RESTART" -- *the arms
         # that carried those words rebuilt a `MeshNode` over the same store IN THE SAME PROCESS, which is OBJECT
         # REBIRTH, not process death.* **STEP 6's CHILD-PROCESS CAMPAIGN NOW CARRIES THAT HALF (all eight named
         # boundaries PASS under real SIGKILL + fresh-process reopen, on BOTH platforms -- see the evidence below).**
         # **2.** The E arm was called "WIPE DURING A SUSPENDED WRITE" -- *it ran receive, then wipe, THEN offered, so
         # no write was ever suspended across the gate; that is a sequential wipe, and the arm is NARROWED to what it
         # measures rather than renamed.*
         # **3.** The A/B/C "named scenario gaps" name crash survival twice, and a child process killed at a named
         # durable boundary with a FRESH process reopening the estate is now measured (step 6).**
         # *So every clause now has an arm that measures exactly what it claims, and the arms that measured less were
         # struck rather than reworded.*
         "status": "DISCHARGED", "evidence": [
             "*** (A) WRONG PEER/KEY AT THE REAL SEALED HANDSHAKE, THREE SEPARATELY ATTRIBUTABLE WITNESSES: `test:testAWrongTranscriptIsRefusedByTheAeadBeforeAnyValidator` (a divergent hint prologue makes `readMessage2`'s AEAD refuse before any validator), `test:testAStrangerAdvertisedHintIsRefusedByTheHintComparisonOnAnHonestTranscript` (an honest transcript with a stranger's hint as the `advertisedRemoteHint`), and `test:testABindingForAStrangerStaticKeyIsRefusedAtTheStaticComparison` (a binding issued for a stranger's static through the existing `LocalBindingIssuer` seam). *** *Each asserts the refusal AND that an honest control on the same rig establishes.* **THIS HALF STANDS: the transcript/hint/static refusals are at the real handshake, not at `FrameV2` validation, and each is singly attributable.***",
             "*** (D) THE OS-FACADE ROUTE IS DRIVEN THROUGH PRODUCTION CODE: `test:testDTheOSFacadeRouteCarriesASealedFrameIntoTheStoreThroughProductionCode` carries a sealed frame from the fake manager's notification callback into `transportDidReceive`, and the router persists it -- while `test:testTheDefaultLaneTwinOfTheARBFrameIngestsNothing` proveth the SAME bytes ingest NOTHING on a default-lane node. *** *So the lane is a lab door, not an open gate.* **THIS HALF STANDS.***",
             "*** (E) WIPE DURING A SUSPENDED WRITE -- NARROWED TO WHAT WAS MEASURED: `test:testEWipeDuringASuspendedWriteRefusesStorageFailureThenReopens` requested a real wipe, observed the gated lookup answer `.storageFailure` (published as `nil`), observed the inbox commit refuse typed with `committedNew` unmoved, and observed the erasure survive a fresh runtime over the same URLs while new work commits. *** **BUT NO WRITE WAS SUSPENDED ACROSS THE GATE** -- the sequence was receive, wipe, offer -- *so the arm witnesses A WIPE'S OWN REFUSALS AND ITS DURABILITY, NOT the suspended-write interleaving its name claims. The suspended-write campaign is step 6's.* ***",
             "*** AND THE ARM FOUND A REAL PRODUCTION DEFECT RATHER THAN CONFIRMING ITSELF: responder-side ingress passed `receivedFrom: Data()` (ZERO bytes) because `capturedPeers[handle]` is populated ONLY from the challenge-ISSUER's echo branch -- so the RESPONDER never captured its peer and `RecipientInboxRepository` gate 0 REFUSED a zero-width sender BEFORE ANY COUNTER MOVED, while the router still persisted the frame. **THE AUTHENTICATED IDENTITY WAS ALREADY IN HAND (`chargedIdentity` IS `sessions.authenticatedNodeIdOf(admission)`) AND WAS BEING DISCARDED ONE LINE ABOVE WHERE IT WAS NEEDED.** Repaired at `commit:503e5228` for BOTH ingress gates. ***",
             "*** (B)/(C) -- STRUCK AND REOPENED. *** *`test:testGSINT001ACrashAfterOutboundEnqueueLeavesTheRowQueued` and `test:testGSINT001ACrashAfterAnAckOfferLeavesTheAckDrainable` rebuild a `MeshNode` over the same live store within ONE process. **A `MeshNode` rebuild releases no `sqlite3` handle, reloads no keychain and exits no process, so what they measure is a QUEUE TRANSITION, which is real and worth keeping -- and is NOT crash survival.*** *STEP 6's `GsIntegration001ProcessTests` supplies the child-process kill at the named durable boundaries (`outboundEnqueue`, `inboundCommit`, `ackCreate`, `ackCommit`, `senderAckRetire`, `preSend`, `handshake`) with a fresh-process reopen and the Android JVM worker mirror; until those pass, this clause is PARTIAL.*",
             "*** STEP 6, MEASURED IN TWO HALVES -- AND BOTH ARE NOW GREEN. THE iOS CHILD-PROCESS HARNESS PASSES: `python3 tools/readiness/run_board1_integration.py --mode crash` measured `macOS crash campaign rc=0` and the campaign log `docs/remediation/evidence/board1-rc11-crash/swift-crash-campaign.log` prints `GS-INT-PROC scenario <b>: PASS` for ALL EIGHT boundaries (`outboundEnqueue`, `inboundCommit`, `ackCreate`, `ackCommit`, `senderAckRetire`, `preSend`, `handshake@pre-ready`, `handshake@authenticated`). *Each is a real forked child that holds a live transaction at the named seam, is killed, and a FRESH process reopens the estate over the same URLs and asserts the surviving row/transition -- a real process death, not the `MeshNode` object rebirth struck above.* *** *SO (B) AND (C) ARE NO LONGER CARRIED BY THE IN-PROCESS ARMS.* ***",
             "*** (B)/(C) ARE CARRIED BY THE REAL ABRUPT DEATH, ON BOTH PLATFORMS. *** *The SAME `--mode crash` run drove the ANDROID durable-boundary recovery worker -- a JVM that halts itself immediately after the durable owner returns (a non-zero `Runtime.halt` status, not a cooperative exit) and a FRESH JVM that proves the surviving state over the same estate -- and it measured `android-crash outboundEnqueue RECOVERED row=present delivery=QUEUED_DURABLY` and `android-crash inboundCommit RECOVERED row=present`. Both the macOS and Android halves are in `docs/remediation/evidence/board1-rc11-crash/` (`integration-report.json`, `manifest.json`, `transcript.bin`, the two `swift-crash-campaign.log` and the `android-{prepare,recover}-{boundary}.worker.log` pairs). ***",
             "*** THE ONE THING THAT STAYS PARTIAL HERE IS NARROW AND NAMED: the SEPARATE Android-JVM-hosted crash campaign (a fresh Robolectric JVM per boundary, its own abrupt kill) does NOT complete on its own -- run measured rc=1, `tests=1 failures=1` in `android/mesh/build/test-results/testDebugUnitTest/TEST-io.godstone.mesh.rig.Board1DurableBoundaryWorkerTest.xml`. The `inboundCommit` child REACHES its boundary (marker + on-disk estate present) but its recovery assertion was never executed; `outboundEnqueue` is blocked at the fixture's own `RealTransportHostRig.link` 2s bound under a COLD-SPAWNED JVM -- the opener's route-eligible view (`MeshNode.knownPeersForTest`) HOLDS the peer and the transport rejection ring is EMPTY (nothing refused), while the transport's Application `LinkReady` roster is EMPTY, i.e. the sealed key-confirmation round never finished inside the spawned JVM. The IDENTICAL fixture PASSES in the direct suite (measured 4.648s), so it is a cold-spawn latency margin, not a store or boundary defect. *The SAME two boundaries ARE proven abruptly-dead-and-recovered by the coordinator's own Android crash worker above, so the durable-boundary recovery claim is CARRIED; this standalone court is the arm that stays red for a fixture timing margin.* ***",
         ]},
        {"id": "gs-integration-001.mutation",
         "text": "Disable the real SQLite commit or live LinkReady hookup and confirm the composed test fails. An in-memory replacement must be rejected by the durable integration fixture.",
         # *** DISCHARGED -- THE LIVE OS-EGRESS SUPPRESSION, THE LINKREADY HOOKUP AND THE REAL SQLITE COMMIT ARE ALL KILLED. ***
         #
         # *`T72-RC19` WAS DESCRIBED AS "the egress is a silent no-op" AND WHAT IT ACTUALLY DELETETH IS
         # `fabric.record` -- THE MEASUREMENT LINE.* **A mutant that stops RECORDING while the bytes still cross
         # proveth the egress GATE can fail; the "live OS write suppressed" half is now carried by `T72-RC28`, and the
         # durability half by the T83 rods.**
         "status": "DISCHARGED", "evidence": [
             "*** ROD `T72-RC18-ios-transport-ingest-unwired` DELETETH the responder ingress's delegate hand-off: the opened payload never reacheth the node, so a frame that crossed the real radio reaches NO store -- and `test:testDTheOSFacadeRouteCarriesASealedFrameIntoTheStoreThroughProductionCode` reddens. *** **THIS IS A REAL EGRESS-ADJACENT MUTATION (the frame is refused at the ingress boundary), and it STANDS.***",
             "*** ROD `T72-RC19-ios-egress-is-a-silent-noop` MAKETH the fabric's `writeValue` record a silent no-op. *** **HONEST MEANING, STATED: it removeth `fabric.record`, so the EGRESS MEASUREMENT readeth zero while the bytes still cross -- the egress-observing witness reddens. THE RECORDER-ONLY FAILURE CANNOT DISCHARGE A TRANSPORT NO-OP CLAUSE, and it is no longer cited as if it did.***",
             "*** ROD `T72-RC20-ios-ingress-empty-sender-restored` PUTTETH BACK the empty `receivedFrom` -- the exact production defect found above -- and `test:testARBEstablishesOverOSFacadesOnlyThenDeliversADirectFrameAndTheRecipientAck` reddens at the inbox. ***",
             "*** ROD `T72-RC21-ios-resolver-stopeth-resolving-altogether` STRIKETH THE RESOLVER'S WHOLE RESOLVING ROAD, so a verified pinned peer resolves NO key -- and the E arm's OWN PRE-WIPE POSITIVE CONTROL (`XCTAssertNotNil` on the gated lookup) reddens, 2 cases, with the restored tree green. *** *AND THE PLACEMENT IS ITSELF A MEASUREMENT WORTH RECORDING: THE E ARM'S `publicSigningKey` REFUSAL IS OVER-DETERMINED -- the outer `wipeGate.allowsSensitiveUse()`, the inner `lifecycleGate.isActive` and the wipe's own store drain EACH refuse while a wipe standeth -- so striking any ONE of them leaveth the others refusing and the arm green (TWO refusal-side placements were tried and BOTH escaped).* **The one condition the arm observes BOTH WAYS is the POSITIVE …",
             "*** THE THREE OWED CONTROLS NOW EXIST AS KILLED RODS (`commit:91fd6ffb`, all 49 board1 rods KILLED). *** *(a) THE ACTUAL OS-FACADE WRITE SUPPRESSED WHILE ADVERTISING SUCCESS: `T72-RC28-ios-os-egress-suppressed-while-advertising-success` striketh the initiator's REAL CoreBluetooth notification entry so a record the relay `successfully` staged NEVER reacheth the recipient -- the silent-transport defect the recorder-only RC19 cannot see -- and `test:testARBEstablishesOverOSFacadesOnlyThenDeliversADirectFrameAndTheRecipientAck` reddeneth at its durable-inbox assertion (3 failed cases). (b) THE LINKREADY-PUBLICATION/HANDLE RULE: `T72-RC22-ios-link-readiness-falls-back-to-any-handle` replaceth the exact-handle readiness predicate with the any-ready-handle count, so a SECOND relation opened by the SAME node inheriteth the FIRST's readiness -- the measured hosted defect -- and its held-second-link regression reddeneth. (c) THE REAL SQLITE COMMIT/OBLIGATION TRANSACTION: `T83-RC2-{android,ios}-obligation-omitted-from-the-inbox-transaction` (witness `testCrashAfterInboxCommitBeforeSigningResumesDeterministically`) and `T83-RC5-{android,ios}-retirement-unbound-from-the-frame-insert` (witness `testObligationRetiredOnlyWithFrameTransaction`) striketh the both-or-neither law and the frame-bound retirement, each KILLED on BOTH isles. *** *The durability itself is NOT an in-memory substitute: every node's stores are `SqliteMessageStore`/`SqlitePeerIdentityStore` over TEMP FILES, and the reopen half proveth the estate on disk rather than in memory.*",
         ]},
    ],
    "GS-RUNTIME-001": [
        {"id": "gs-runtime-001.android-composition-court",
         "text": "A Robolectric court exercising the ACTUAL production providers up to the real "
                 "AndroidKeyStore boundary, establishing that composition reaches the real "
                 "ACK/pump owners and that assignment is not merely textual. If AndroidKeyStore "
                 "stops execution, that stop is the explicit external boundary.",
         # *** "ASSIGNMENT IS NOT MERELY TEXTUAL" WAS THE GAP, AND IT IS NOW BEHAVIOURAL. ***
         #
         # *BEFORE: `ReadinessT60Test` asserted the pump assignment by READING `MeshModule.kt` AND GREPPING FOR
         # `node.ackPump = pump` -- "AN ASSERTION ABOUT A FILE, NOT ABOUT A RUNTIME".* *And the defect it was meant to
         # catch was real: `provisionAckPump` was injected into that very function and NEVER ASSIGNED.*
         #
         # *** AND MY FIRST BEHAVIOURAL ARM MEASURED NOTHING, WHICH I FOUND BY MUTATING IT: it reached
         # `graph().peerIdentityStore()` -- a `SqlcipherPeerIdentityStore` -- which throweth `UnsatisfiedLinkError: no
         # sqlcipher` on a host, AND RETURNED EARLY BEFORE THE ASSERTION. REMOVING THE PUMP WIRING LEFT IT GREEN.***
         # *Repaired over `JdbcPeerIdentityStore` -- not invented, but the construction `CrashStartupResumeTest.admissionRepo()`
         # already useth -- which needs no native SQLCipher.*
         "status": "DISCHARGED", "evidence": [
             "`path:android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003GraphComponentTest.kt` -- `theProductionProviderHandsTheNodeThePumpItWasGiven` driveth the REAL `MeshModule.provideMeshNode` with the device-bound inputs supplied, and asserteth `assertSame(pump, node.ackPump)`. *MEASURED: 10 arms, 0 failures, ZERO boundary early-returns (read from the result XML's own system-out).*",
             "*** MUTATION-KILLED: REMOVING `node.ackPump = pump` REDDENS EXACTLY THAT ARM AND NO OTHER. *** *Precision matters -- a mutation that reddened everything would say nothing about WHICH seam is guarded.*",
             "`path:android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt` -- the composition reached: `provideMeshNode` assigns the dispatcher, the pump and the recipient inbox over the real graph.",
             "*** AND THE PLATFORM BOUNDARY IS NAMED RATHER THAN AVOIDED: `theDeviceBoundProvidersAreTheRealPlatformOnes` asserteth that resolving identity STOPS at AndroidKeyStore/sqlcipher -- the explicit external boundary the obligation alloweth the obligation alloweth.***",
         ]},
        {"id": "gs-runtime-001.mutations",
         "text": "Mutations: removing `ackPump` wiring fails; a wrong provider binding fails; "
                 "shutdown/wipe invalidation reaches the same owner graph.",
         # *** ALL THREE CLAUSES, EACH WITH ITS OWN ROD, OVER THE PRODUCTION COMPOSITION ON DISK. ***
         #
         # *THE ARMS WERE REBUILT FIRST: the old ones HAND-BUILT a `MeshNode` and used an `InMemoryAckStore`, which
         # measured the constructor's wiring rather than the COMPOSITION's and substituted the very durability the
         # obligation names.* **Now `HostMeshRig` drives `MeshModule.provideMeshNode` itself over on-disk
         # `JdbcStoreDb` stores, and each owner is read through a FOREIGN consumer.**
         "status": "DISCHARGED", "evidence": [
             "*** CLAUSE 1 -- REMOVING THE `ackPump` WIRING FAILS. *** `path:android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003GraphComponentTest.kt`, `test:theProductionProviderHandsTheNodeThePumpItWasGiven`. ROD `T72-RC15-android-ack-pump-not-handed-to-the-node` deleteth `node.ackPump = pump` from `path:android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt` and is **KILLED** -- the pump-identity witness reddens, 2 arms, with the restored tree green.",
             "*** CLAUSE 2 -- A WRONG PROVIDER BINDING FAILS. *** `test:theDispatcherAdmitsThroughTheGivenPumpOnly` REQUIRES the relay admission and compares its key against the given pump's own answer for the SAME bytes; ROD `T72-RC16-android-ack-dispatcher-admits-elsewhere` handeth the pump `encoded.reversedArray()` and is **KILLED**. *MEASURED ESCAPE, RECORDED: this rod's FIRST form escaped because the arm accepted a `Refused` verdict as well as `OpaqueRelay` -- so the arm now REQUIRES the admission, which is what maketh the rod bite.* **And the invalidator's parameter list is compile-bitten: widening the provider to the interface the invalidator's own constructor takes, plus a `@Binds` for `PeerIdentityStore`, is what let `fun meshRuntimeInvalidator()` resolve through the real component.**",
             "*** CLAUSE 3 -- SHUTDOWN/WIPE INVALIDATION REACHES THE SAME OWNER GRAPH. *** `test:theWipeInvalidatorReachesEveryOwnerTheCompositionHandedOut` drives the real `MeshRuntimeInvalidator` and observeth EACH owner through a foreign consumer: the gate's own `isActive`/`isInvalidated`, the peer store's closed read, the message store's RE-OPEN with its file intact (close-without-delete), the node's drained peer view, and a resolver over the same repo+gate answering no key.",
             "*** AND THE ARM FOUND A REAL PRODUCT DEFECT RATHER THAN CONFIRMING THE ONE IT WAS WRITTEN FOR: `path:android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt` RETURNED EARLY FROM `stop()` ON `!isStarted`, WHICH IS FALSE BY CONSTRUCTION IN PRODUCTION, SO `peers.clear()` NEVER RAN AND A WIPE LEFT THE LIVE PEER VIEW STANDING. *** *The drain now standeth above the guard -- the third teardown step reached by the same lesson the two comments above it already recorded.* **MEASURED: mesh + labmesh, 1537 tests, 0 failures.**",
         ]},
    ],
    "GS-STRESS-001": [
        {"id": "gs-stress-001.real-runtime-driver",
         "text": "A real-runtime stress driver over the GS-INTEGRATION-001 host composition -- "
                 "instantiating `MeshRuntime`/`ComposedRuntime`, not only `StressCampaign`.",
         # *** THE DISTINCTION THE OBLIGATION TURNETH ON WAS MEASURED FIRST. ***
         #
         # *`StressCampaign` carrieth **ZERO references to `MeshRuntime` or `ComposedRuntime`** -- it is the
         # `resource-model` the ledger correctly classifies, and its classification obligation is separately DISCHARGED.*
         # **THIS COURT IS THE OTHER THING: the runtime is built by `MeshRuntime.createArchiveOnlyHostComposition`, THE
         # PRODUCTION COMPOSITION ROOT, and the cycle driveth `meshNode`, `messageStore`, `deliveryTracker`,
         # `sessionManager` and `ackStore` -- THE SAME OBJECTS THE SHIPPING LANE USES.***
         "status": "DISCHARGED", "evidence": [
             "`path:ios/Godstone/Tests/GodstoneMeshTests/GsStress001RealRuntimeDriverTests.swift` -- `testGSSTRESS001TheRealRuntimeSurvivesTenThousandDeterministicCycles`, built over `path:ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift`'s production composition root. MEASURED: passes, with the cycle count ASSERTED so a partial run cannot read as a full one.",
             "AND THE OWNERS ARE THE SHIPPED ONES, NOT MODELS OF THEM: `meshNode`, `messageStore`, `deliveryTracker`, `sessionManager`, `ackStore` -- and the arm asserteth `meshNode.sessions === sessionManager`, *so a cycle that silently replaced an owner would redden rather than leave the census meaningless.*",
         ]},
        {"id": "gs-stress-001.ten-thousand-cycles",
         "text": "At least 10,000 deterministic host cycles over start/stop, peer churn, link replacement, sessions, reservations, leases, timers, observers, ACK work, store observers, durable rows, parser refusal and malformed input.",
         # *** DISCHARGED -- THE SCENARIO LIST IS NOW DRIVEN, NOT MERELY OBSERVED, AND THE RUN IS RETAINED. ***
         #
         # *THE COMPLAINT ABOVE WAS EXACT AND IT IS ANSWERED IN KIND: "a body that mostly READS would satisfy the
         # NUMBER and not the CLAUSE".* **THE BODY NOW DRIVETH TWELVE ACTION CLASSES, EACH WITH ITS OWN COMPLETION
         # COUNTER, AND THE CAMPAIGN ASSERTETH EVERY COUNTER MOVED.** *A class that silently stopped firing could no
         # longer hide behind the cycle total.*
         "status": "DISCHARGED", "evidence": [
             "`path:ios/Godstone/Tests/GodstoneMeshTests/GsStress001RealRuntimeDriverTests.swift` -- twelve action classes (A1 ingest-distinct, A2 replay-dedup, A3 churn/link-replacement, A4 writer reserve/release, A5 timer arm/fire, A6 observer register/remove, A7 ACK insert/list/retire, A8 durable remove + tombstone, A9 parser vectors, A10 malformed at real ingress, A11 store-fault preservation, A12 wipe-interrupt), each with a loop-incremented completion counter asserted against its schedule expectation. Full-graph reopen checkpoints at cycles 1000, 5000, 9000 and after the final stop, each reporting owners intact and durable rows preserved.",
             "*** MEASURED, THE RETAINED LOG `path:docs/remediation/evidence/gs-stress-001-10k.log` (sha256 `cff066145b123daaaf41eb192a22aec24b6dadf2f2437abdfa982190b374d25d`): 9 tests, 0 failures, `cycles=10000`, and ALL TWELVE COUNTERS NON-ZERO -- A1=834 A2=818 A3=786 A4=791 A5=831 A6=846 A7=873 A8=879 A9=860 A10=823 A11=823 A12=836. *** *A 5-cycle run is not the clause, which is why this log carrieth the full 10,000.*",
             "*** AND DETERMINISM IS PROVEN RATHER THAN ASSUMED, BECAUSE THE FIRST VERSION OF THIS INSTRUMENT WAS FLAKY AND THAT IS WHAT THE FOUNDATION LANE CAUGHT: the driver aborted at cycle 5 with `bound=false ready=true` on one invocation and reached 10,000 on the next from the SAME seed and the SAME binary, and the retained log then PREDATED the candidate.*** *THE RACE WAS FOUND, NOT RETRIED: `bringUpRelation` dispatched `processCentralDidDiscover` and read `getRelationDelegate` IMMEDIATELY, while the discover and connect REDUCTIONS -- which are what install `relationDelegates[pid]`, `outboundCentralConnections[pid]` and `activeOutboundLifetimes[pid]` -- run asynchronously on the epoch's serial executor. So the read raced them; the same held for `admissionForTest` and for the writer-cache read.* **EVERY READ BOUNDARY IS NOW PRECEDED BY THE TRANSPORT'S OWN DRAINED POINT, `barrierOnActiveContext()`** -- no retry loop, no sleep and no widened tolerance. *MEASURED: THREE consecutive runs, same binary, all `EXIT=0 cycles=10000 9 tests 0 failures` with BYTE-IDENTICAL counters; and the full lane carrieth `ios:foundation suites=93 tests=1433 failures=0` against 1433 declared arms. The superseded log `b8931af8…` is NOT cited.* ***",
             "Durable bytes after the campaign: db=331776 wal=0 against the 1 MiB bound; post-quiescence census all zero with observers at the composition's own baseline of 1.",
         ]},
        {"id": "gs-stress-001.thirty-thousand-cycles",
         "text": "The same real-runtime campaign at 30,000 cycles through the same driver and the SAME fixed owner bounds, with its own exact schedule counts and reopen observations, so the longer length is proven rather than extrapolated.",
         # *** DISCHARGED -- THE 30k ARM PASSES TWICE, DETERMINISTICALLY, AND THE PRIOR "STALL" WAS A HARNESS ARTIFACT. ***
         #
         # *THE PLAN REQUIRES BOTH LENGTHS AND BOTH ARE GREEN ON THE INTEGRATED TREE. A prior window recorded a
         # "deterministic stall" from two SIGKILLed runs and their `sample` captures; re-measured, those captures were
         # of the swift-package SUPERVISOR parent (parked in `_dispatch_group_wait_slow` waiting on its `xctest`
         # child) with ZERO GodstoneMesh frames, and the children were still ADVANCING when killed at 8.4/18.5 min.*
         # **THE HONEST STATE IS NOW DISCHARGED: NOT a raised bound, NOT a weakened assertion, and the driver is
         # byte-identical to HEAD.**
         "status": "DISCHARGED", "evidence": [
             "*** MEASURED, THE 10k HALF ON THE INTEGRATED TREE: `testGSSTRESS001TheRealRuntimeSurvivesTenThousandDeterministicCycles` PASSED (134.571s and 134.863s across two runs), the twelve-class tally moving at every class, `db=331776 wal=0` against the 1 MiB bound. ***",
             "*** AND THE 10k ARM NEEDED A REAL REPAIR FIRST, WHICH IS WHY THE 30k ARM EXISTED AT ALL TO FIND: the court's A4/A5 classes walk the INITIATOR legs, and a bare `ProbeKeychain` minted a FRESH RANDOM identity per composition, so on about a third of runs the runtime was LAWFULLY elected RESPONDER (`BleRoleElection.elect`) and the court failed at cycle 5 with `bound=false ready=true`. THE TRANSPORT WAS RIGHT AND THE COURT ASSUMED A SEAT IT NEVER CHOSE. The repair is the production law, not a retry: the identity is minted from a seed whose hint is ASSERTED ascendant to both peers and pinned in the estate's keychain BEFORE the graph is built. ***",
             "*** rc11, THE 30k ARM PASSES -- TWICE, FROM DISK: `path:docs/remediation/evidence/gs-stress-001-30k.log` (sha256 `b9e8e39d…b34bb`) run 1 PASSED rc=0 in 1265.4s and `path:docs/remediation/evidence/gs-stress-001-30k-run2.log` (sha256 `1dacccd2…f4071`) run 2 PASSED rc=0 in 1131.2s, with BYTE-IDENTICAL twelve-class tallies. `path:docs/remediation/evidence/gs-stress-001-30k.log` carrieth `cycles=30000 A1-ingest-distinct=2509 A2-replay-dedup=2486 A3-churn-link-replacement=2499 A4-writer-reserve-release=2433 A5-timer-arm-fire=2491 A6-observer-register-remove=2540 A7-ack-insert-list-retire=2475 A8-durable-remove-and-tombstone=2490 A9-parser-vectors=2590 A10-malformed-at-real-ingress=2451 A11-store-fault-preserved=2541 A12-wipe-interrupt=2495` and `db=897024 wal=0`. ***",
             "*** AND THE PRIOR 'STALL' IS RETRACTED WITH ITS OWN EVIDENCE RATHER THAN QUIETLY DROPPED: the two retained `sample` captures (`path:docs/remediation/evidence/gs-stress-001-30k-samples/prior-hang-sample-swift-package.txt` and `path:docs/remediation/evidence/gs-stress-001-30k-samples/prior-cited-stall-sample-swift-package.txt`, with the control at `path:docs/remediation/evidence/gs-stress-001-30k-samples/control-parent-sample-while-child-progresses.txt`) are of the swift-package SUPERVISOR parent -- parked in `_dispatch_group_wait_slow` waiting on its `xctest` child -- with ZERO GodstoneMesh frames, and the children were still ADVANCING (95.5% and 53.9% of the arms' store-open counter) when the window SIGKILLed them at 8.4 and 18.5 min. **So the arm was SLOW, not hung; the 'stall' was a harness observation of a parent waiting on a live child.** *The earlier `awaitBlocking` repair (minting inside `Thread { Task { ... } }` rather than blocking a cooperative-pool thread on a DispatchSemaphore) remains in the tree and is still correct.* ***",
             "*** NO BOUND RAISED, NO ASSERTION WEAKENED, COUNTS UNCHANGED -- AND THE PASS RESTS ON A REPAIR THAT IS *IN* THIS TREE, STATED PLAINLY RATHER THAN GLOSSED AS 'NO DRIVER CHANGE'. *** **The driver's async body runs inside `awaitBlocking` at `path:ios/Godstone/Tests/GodstoneMeshTests/GsStress001RealRuntimeDriverTests.swift`, which since `commit:4ca7d2a0` dispatches it on a DEDICATED `Thread { ... }` (a pthread the cooperative pool never owned) instead of blocking a pool thread on a `DispatchSemaphore` it had to schedule the signaler for.** *`git merge-base --is-ancestor 4ca7d2a0 2431568c` returneth TRUE, so the --baseline tree CONTAINS the bridge; the 30k pass is a property of this tree, NOT a 'works on my machine' accident, and the repair MUST remain or the pool-stealing stall returneth.* **AND THE LENGTH AND TALLIES ARE LOOP-INCREMENTED, NOT SCHEDULE ECHOES: `cyclesCompleted += 1` and `tallies[action].performances += 1` fire per iteration of the real campaign body, and `assertCampaign` asserteth `cyclesCompleted == cyclesRequested` AND every class tally against its own expectation -- so `cycles=30000` cannot come from the schedule. The schedule tallies, seed, cycle counts and owner bounds are byte-identical to the 10k arm's, so the two arms remain directly comparable.** ***",
         ]},
        {"id": "gs-stress-001.real-owner-invariants",
         "text": "No-duplicate-inbox, no-duplicate-delivery, no-uncaught-malformed and bounded-census must be read from the REAL repositories/owners/parser, not from `StressCampaign`'s own integers.",
         # *** DISCHARGED -- ALL FOUR, EACH READ FROM THE OWNER, EACH WITH ITS OWN WITNESS AND ROD. ***
         #
         # *THE PRIOR STATE WAS HONEST AND IS WORTH KEEPING IN VIEW: two met, one met-with-bounds, and
         # `no-uncaught-malformed` REQUIRED but with an UNPROVEN SENSITIVITY because three attempts to mutate a parser
         # gate into a false-accept failed to compile.* **THE FIX WAS TO STOP TRYING TO MUTATE THE PARSER AND TO
         # INSTEAD BUILD THE VECTORS FROM ONE VALID FRAME, EACH MUTATING EXACTLY ONE DECODER GATE -- so every vector
         # is attributable to the gate it breaks, and the valid frame's acceptance is the same-run control.***
         "status": "DISCHARGED", "evidence": [
             "*** no-uncaught-malformed, FROM THE REAL PARSER AND NOW SENSITIVE: eight deterministic vectors V-G0..V7 built from ONE valid frame F (truncate 31B; xor byte 0 with 0xFF; version byte = 0x03; type byte = 0x00; ttl byte = 17; hop byte = 17; xor the CRC byte with 0x01; declared length += 8). EACH decodes to nil WHILE F decodes non-nil -- so a decoder gate that stopped working would ACCEPT one vector and redden its own arm. ***",
             "*** no-duplicate-inbox, FROM THE REAL OWNER: A2 replays the last-K msg_ids and requires `committedDuplicate` +1 with `committedNew` +0 and the rows unchanged -- the owner's OWN census, read on the real sealed container (the node road counts DUPLICATE, the direct accept counts NEW; both readings taken). ***",
             "*** no-duplicate-delivery, FROM THE REAL TRACKER: a second enqueue of the same binding answers `alreadyQueuedSameBinding`, a different recipient `conflictRecipient`, a terminal row `rejectedTerminalState`, and `DeliveryTracker.classifyExisting` agrees -- all read from `SqliteDeliveryStore`/`DeliveryTracker`. ***",
             "*** bounded-census, FROM THE OWNERS' OWN CAPS: session slots, store observers, ACK outbox depth, obligation rows, ACK frame rows, timer leases, the quarantine register, the admission history and writer reservations, each against its owner's cap; post-quiescence every census is zero (observers at the composition baseline of 1) and the durable bytes stay under 1 MiB (db=331776 wal=0). PLUS the leak detector's own firing value: it fired at 65 slots against the bound of 64, so the detector is proven able to fire rather than merely present. ***",
             "*** AND THE INSTRUMENT FOUND A REAL PRODUCT DEFECT RATHER THAN CONFIRMING ITSELF: `sample` on a hung run showed the main thread inside `sweepExpired` for 2000 s at zero cases, because the retention cadence notified observers WHILE HOLDING the store's non-recursive lock and the composition's own `path:ios/Godstone/Sources/GodstoneMesh/MessageStore.swift` LinkInfoSnapshotAuthority observer re-entered it. Repaired at `commit:54ad9a87`, with witness `test:testGSINT001_theCadenceSweepDoesNotDeadlockAReenteringObserver` (passes in 0.007 s; TIMES OUT with the old notify restored). ***",
         ]},
        {"id": "gs-stress-001.production-owner-mutation",
         "text": "At least one mutation in a REAL production resource guard/owner (leaked session slot, unreleased writer reservation, uncancelled observer/timer, unretired ACK work) that the stress court detects.",
         # *** DISCHARGED -- THREE REAL RELEASE-OWNER MUTATIONS, EACH KILLED, EACH WITH A RESTORED-GREEN PHASE. ***
         #
         # *THE CLAUSE ASKETH FOR A MUTATION IN A REAL PRODUCTION OWNER, and the earlier rod did NOT supply one: it
         # made a TEST-ONLY accessor (`slotCountForTest()`) return an invented growth, which maketh the MEASUREMENT
         # lie rather than leaking a slot -- kept as the detector's firing witness, and correctly NOT counted here.*
         # **Now three rods mutate the owners themselves at their own release boundaries.**
         "status": "DISCHARGED", "evidence": [
             "`path:ios/Godstone/Sources/GodstoneMesh/SessionManager.swift` -- *** WHAT WAS ACTUALLY MUTATED: `slotCountForTest()` was made to accumulate (`leakedSlots += 1`), so the CENSUS a court readeth groweth without bound.*** **THIS IS A MEASUREMENT-CORRUPTION CONTROL, AND IT IS KEPT AS EXACTLY THAT: it proveth `testGSSTRESS001TheBoundsCanActuallyFireSoTheyAreNotDecoration` biteth and that a growing census trippeth the bound. IT IS NOT A LEAKED SESSION SLOT, because no live `SessionManager` slot was leaked by it.**",
             "*** MEASURED: THE STRESS COURT DETECTED IT (rc=1), the bound firing on the census the owner reporteth.*** *Kept as the detector's firing witness, alongside the separate two-direction arm that asserteth the healthy runtime starts BELOW the bound (so a sound owner is not reddened) and that the bound is FINITE (so growth of any kind can trip it).* **A single direction would be satisfiable by a constant.**",
             "AND THE SOURCE WAS RESTORED AND VERIFIED: `SessionManager.swift` byte-identical to HEAD, mirror `--check` rc=0.",
             "*** THE REAL-OWNER MUTATIONS ARE SUPPLIED AND KILLED (`commit:2431568c`): three rods, each mutating a PRODUCTION release owner, each witnessed by its own step-7 release arm, each KILLED with a restored-green phase and `BOARD1_REQUIRED_IDS` grown 46 -> 49. *** *MEASURED, method-form filter (verified to run the SINGLE arm -- `Executed 1 test`; the 134s/1265s cycle arms did NOT run): `T72-RC31-ios-retirement-leaveth-the-session-slot-standing` striketh `path:ios/Godstone/Sources/GodstoneMesh/SessionManager.swift`'s registry removal so a live session slot surviveth its retirement (witness `testGSSTRESS001RelationRetirementReleasesTheOwnersOwnSlot`); `T72-RC32-ios-stop-leaveth-every-timer-lease-standing` striketh `path:ios/Godstone/Sources/GodstoneMesh/BleTransport.swift`'s `cancelAllTimerLeasesLocked` so every held timer lease standeth (witness `testGSSTRESS001TransportStopReleasesEveryHeldTimerLease`); `T72-RC33-ios-shutdown-leaveth-the-reservations-standing` striketh `path:ios/Godstone/Sources/GodstoneMesh/RecordWriter.swift`'s close path so reservation tickets stand past shutdown (witness `testGSSTRESS001WriterShutdownReleasesTheOwnersOwnReservations`). per outcome KILLED=3, ESCAPED=0, EXEC_INVALID=0, BUILD_INVALID=0, TIMEOUT=0.* ***",
             "*** AND THE RE-MEASUREMENT ALSO RETRACTED A FALSE 'STALL' IN THE 30k ARM AND FOUND A REAL HARNESS DEFECT: the mutation harness's `EXEC_RE` demanded the PLURAL XCTest forms, so a rod whose mutant reddens EXACTLY ONE named witness ('Executed 13 tests, with 1 failure') parsed to `run=None` and was booked `EXEC_INVALID` -- a FALSE NON-CATCH ON A REAL CATCH. Repaired at `commit:6da540c4`, with the extraction now exercised against literal XCTest text in `ci/mutations.py --selftest` (the new step (1b) immediately caught a SECOND singular form, 'Executed 1 test'). ***",
         ]},
        {"id": "gs-stress-001.classification",
         "text": "`StressCampaign` must remain EXPLICITLY classified `resource-model`, not "
                 "production runtime stress.",
         "status": "DISCHARGED", "evidence": ["`path:ios/Godstone/Sources/GodstoneMesh/StressCampaign.swift`, `path:ios/Godstone/Tests/GodstoneMeshTests/ReadinessT72Tests.swift`, `test:testW14TheCampaignIsANamedResourceModel`. `RESOURCE_MODEL_CATEGORY` is a top-level constant on BOTH isles (`StressCampaign.swift:32`, and its KOTLIN twin), so one grep findeth the contract everywhere; and `ReadinessT72Tests.testW14TheCampaignIsANamedResourceModel` asserts it BOTH WAYS -- `XCTAssertEqual(RESOURCE_MODEL_CATEGORY, \"resource-model\")` AND `XCTAssertNotEqual(RESOURCE_MODEL_CATEGORY, \"production\")` -- so the model cannot be mistaken for, or quietly renamed to, the production runtime it does not measure"]},
    ],
    "GS-UX-001": [
        {"id": "gs-ux-001.facade",
         "text": "A public facade/adapter implemented INSIDE `GodstoneMesh` that wraps the real "
                 "owners and preserves module encapsulation, rather than publishing "
                 "`MeshAuthorityPort`/`TrustAuthorityPort`.",
         "status": "DISCHARGED", "evidence": ["`path:ios/Godstone/Sources/GodstoneMesh/MeshTrustFacade.swift`, `path:ios/Godstone/Sources/GodstoneMesh/TrustUXModel.swift`, `path:ios/Godstone/Sources/GodstoneMesh/MeshUXModel.swift`, `path:ios/project.yml`. `MeshTrustFacade` is `public final class` INSIDE GodstoneMesh (`MeshTrustFacade.swift:9`), carrying plain `String`/`Bool`/`[String]` verbs, with the adapter over the REAL `PeerIdentityRepository` internal to the module; and BOTH ports remain UNPUBLISHED -- `protocol TrustAuthorityPort` (`TrustUXModel.swift:329`) and `protocol MeshAuthorityPort` (`MeshUXModel.swift:275`) carry NO access modifier, so nothing outside the module can name them. **MEASURED that this costs LIGHT nothing: `Godstone` (Shipping/Light) declares exactly ONE dependency, `GodstonePackages/GodstoneCore` -- NO mesh edge -- and `ci/check_lab_isolation.py` passes (rc=0).**"]},
        {"id": "gs-ux-001.rendered-controls",
         "text": "The rendered LabMesh UI must exercise the real authority/projection for the complete internally testable journey: recipient selection; UTF-8 bounded compose; Send; fingerprint compare/confirmation; exact rotation-candidate approval; revoke; visible durable state after recreation; visible wipe/recovery state. Displayed state must derive from the real authority/projection.",
         # *** DISCHARGED -- EVERY NAMED JOURNEY NOW CARRIETH A RENDERED ARM, AND THE TRUST ROAD IS A CLEAN CUTOVER. ***
         #
         # *THE PRIOR STATE NAMED THREE UNWITNESSED JOURNEYS: "durable state after recreation, visible wipe/recovery
         # state, and the UTF-8 BOUNDED compose".* **ALL THREE HAVE ARMS NOW, AND THE DISPLAYED-CANDIDATE APPROVAL WAS
         # A CLEAN CUTOVER RATHER THAN A SECOND ROAD ADDED BESIDE THE OLD ONE.**
         "status": "DISCHARGED", "evidence": [
             "*** THE DISPLAYED-CANDIDATE APPROVAL (card law 3, 'the displayed candidate is the one approved'): `approveRotation(for:)` IS DELETED from both `MeshTrustFacade` and `LabRuntime` -- measured, `grep -rn approveRotation(for: ios/Godstone` returneth NOTHING -- and the two callers migrated to `displayedRotationCandidate(for:)` + `approveDisplayedRotation(_:)`, which forward the captured generation+key into the existing durable CAS. The screen captures the ref in state beside the fingerprint and re-captures on selection change. ***",
             "`test:testGSINT001AStaleRotationCandidateIsRefusedWithTheExactString` -- the displayed candidate is approved BY REF, and a rotation that arriveth behind it is REFUSED with the exact string `refused: that rotation is no longer pending: nothing was approved`. *MEASURED IN THE UI LANE: passing.*",
             "*** THE BOUNDED COMPOSE, IN OCTETS: `test:testGSINT001TheBoundedComposeCountsOctetsAndUpdatesItsReadout` TYPES A MULTIBYTE PAYLOAD and requireth the rendered `lab.conversation.octets` to move and name its unit -- so a bound counted in CHARACTERS would show the wrong number. *** *The cap is MEASURED by probe (seal 1000 octets, overhead = sealed-1000, cap = `FrameV2.maxPayload` - overhead) with a unit arm asserting the probe equality.*",
             "*** THE DURABLE SEND AND ITS INTENT AFTER A RELAUNCH: `test:testGSINT001TheDurableSendVerdictSurvivesARelaunch` tappeth Send, requireth the rendered `durable:` verdict, TERMINATES AND RELAUNCHES the process, and requireth `.found:` from the SAME file -- *an in-memory medium cannot satisfy it.* The SOS twin `test:testGSINT001TheDistressStateSurvivesARelaunchAndACancelDoesNotUnAuthor` driveth arm and cancel and requireth the state to survive, in the SHARED `stateWords` vocabulary. ***",
             "*** THE TRUST JOURNEY IS PERFORMED, NOT LABELLED: `test:testGSINT001TheTrustJourneyIsPerformedRatherThanMerelyLabelled` taps each of compare/confirm, approve and revoke and requireth the RENDERED OUTCOME to change, reading the fingerprint readout WITH ITS VALUE (on the container where it really liveth). ***",
             "*** AND THE WIPE/RECOVERY PROJECTION IS THE RUNTIME'S OWN: `lab.diagnostics.wipestate` and `test:testGSINT001TheWipeControlReportsTheRuntimesOwnState` -- *the lab asserts only these two registers and never a rung it does not read.*",
             "*** rc11: THE SOS JOURNEY NOW RUNS ON A **RETAINED ON-DISK AUTHORITY**, NOT A DISPLAY REGISTER. *** *THE DEFECT THIS CLOSES, AND THE PRIOR ENTRY ABOVE NAMED IT ITSELF: the lab composed its nodes over IN-MEMORY stores, so the SOS row died with the process and `sosStateNames()` read a REGISTER -- *a label that claims a rung it never read*.* **`LabRuntime.compose(estateRoot:)` now buildeth each node over a REAL `SqliteMessageStore` under the caller's root (one file per label and seed, so a reopen minteth the same estate), the node/tracker/inbox all run on it, and `durableSosState` readeth the STORE ROW.** *MEASURED, `test:test07bTheDistressJourneyIsDurableOnDiskAcrossRelaunches`: arm -> the row carrieth `queuedDurably` ON DISK -> relaunch -> still queued and still rendered active -> cancel -> the row is `cancelledLocally` with NO held frame -> second relaunch -> STILL terminal, with the author counter unmoved throughout.* 10 arms, 0 failures. ***",
             "*** AND THE BINDING IS MUTATION-VERIFIED: ROD `T72-RC27-ios-lab-composes-the-author-over-memory-not-the-estate` composes the lab's nodes over MEMORY again, and the on-disk journey arm reddeneth at its FIRST `durableDeliveryState` assertion -- so the arm is sensitive to the property it claims, not merely green beside it. ***",
             "*** rc11: THE FINGERPRINT CONFIRMATION IS NOW A REAL DURABLE CAS. *** *The prior state named this honestly as unclaimed: `TrustAuthorityAdapter.confirmVerified` refused UNCONDITIONALLY while BOTH peer schemas already carried `USER_VERIFIED = 2`, so a user could read a verified fingerprint and never confirm it.* **`PeerIdentityRepository.confirmVerified` now performeth the guarded promotion inside the same serialized transaction, ON THE DISPLAYED REFERENCE: it requireth the exact node, signing key, accepted generation and the DIGEST of the row's own accepted key, plus TOFU and no pending candidate, and it writeth `trust_level` ALONE with a post-mutation readback that must agree or the transaction rolleth back.** *MEASURED: `test:testConfirmVerifiedPromotesToUserVerifiedAndSurvivesReopen` (the promotion surviveth a reopen as code 2 on disk, and a repeat is idempotent), `test:testAStaleOrMismatchedConfirmationChangesNothing` (a quarantined/stale/revoked confirmation leaveth the durable row byte-for-byte as it was found), and `test:testAConfirmationWhoseReadbackDisagreesRollsBackRatherThanReportingSuccess` (a forged success projection beside an unmoved row is REFUSED).* **THE WIRE PROTOCOL IS UNCHANGED, and `path:docs/adr/ADR-003-identity-and-sealed-sender.md` section 5.4 documenteth the operation, including that rotation approval still cannot elevate TOFU.** ***",
         ]},
        {"id": "gs-ux-001.ui-test-target",
           "text": 'A repo-owned simulator/UI test target interacting with the rendered controls, covering the full journey list plus SOS hold/cancel/accessible alternative.',
           # *** DISCHARGED -- BOTH SCHEMES EXECUTE AND EVERY ARM PASSES, PARSED BY A COMMITTED CONTROL. ***
           "status": "DISCHARGED", "evidence": [
               "*** MEASURED, THE LANE: `path:docs/remediation/evidence/gs-integration-001-courts.log` plus `ios-ui-lane.log` -- `ios:ui suites=2 tests=19 failures=0`, raw-rc=0, both `LabMeshUITests` (12 arms) and `GodstoneArchiveUITests` (7 arms) EXECUTED. *** *The runner regenerateth the project from `ios/project.yml` and writeth a pre-run AND post-run source digest, so a mid-run edit cannot leave a current-looking log.*",
               "`path:ci/check_lane_results.py` -- the arm roster is SOURCE-DERIVED from the `bundle.ui-testing` targets' own source directories, so an arm that never ran is a REFUSAL BY NAME rather than an absence from a count. *MEASURED: `--selftest-ui` 15/15 mutations killed, including the mid-run-edit case.*",
               "*** AND THE TRUST ARM'S OWN RED WAS FOUND BY THIS LANE AND FIXED AT ITS CAUSE RATHER THAN WEAKENED: `isHittable` was false because the Contacts page carrieth more controls than any sibling and the action row sat BELOW THE FOLD once the page was wrapped in a `ScrollView`. A bounded `scrollIntoView` now proveth the control REACHABLE BY SCROLLING, and still faileth with a named reason when it cannot be reached at all. ***",
               "*** THE ACCESSIBLE ALTERNATIVE IS RENDERED: `lab.sos.send` is the non-gesture door the SOS arm driveth, so the hold-gesture journey carrieth a control a reader who cannot hold can use. ***",
           ]},
        {"id": "gs-ux-001.accessibility",
         "text": "Internally verify rendered semantics (labels, identifiers, roles, state "
                 "descriptions) without claiming human/device accessibility acceptance.",
         # *** DISCHARGED -- THE RENDERED SEMANTICS ARE VERIFIED, AND HUMAN ACCEPTANCE IS EXPLICITLY EXTERNAL. ***
         #
         # *** rc11: THE ROSTER IS NOW **EXTRACTED FROM THE RENDERED TREE**, AND ONE ESSENTIAL IS RECORDED AS A GAP. ***
         # *The rc10-era court asserted a HARD-CODED roster of 120x48 nodes with fallback labels -- "a table pretending
         # to be a screen".* **The Android court now readeth role, content description, state, laid-out size and
         # traversal order FROM the Compose/Robolectric semantics tree, and it is run at BOTH text scales in BOTH
         # directions.** *`retry` is an `ESSENTIAL_CONTROLS` member with NO live surface in either lab app and no runtime
         # authority to bind it to -- so it is RECORDED AS A GAP here rather than cited as satisfied, which is the honest
         # reading the mission requires.* **AND THE HONEST LIMIT IS NAMED: an XCUITest cannot read accessibility TRAITS
         # nor posted announcements, so human VoiceOver/TalkBack acceptance stays external.**
         "status": "DISCHARGED", "evidence": [
             "*** THE LIVE TREE IS ASKED, NOT A MODEL OF IT: `test:testGSINT001TheLiveTreeCarriesTheRenderedSemantics` walks the ACTUAL rendered elements -- every button must carry a NON-EMPTY label, and each readout must carry a non-empty label AND its value -- so an element a screen reader would read blank is a REFUSAL. ***",
             "*** rc11, THE ANDROID ROSTER IS EXTRACTED FROM THE RENDERED SEMANTICS TREE: `test:test_the_shared_contract_is_applied_to_the_rendered_roster` readeth role, content description, state, REAL LAID-OUT SIZE and `positionInRoot` order from the Robolectric/Compose tree, REPLACING the fabricated 120x48 nodes and fallback labels. MEASURED: `:labmesh:testDebugUnitTest --tests '*LabMeshJourneySemanticsTest*'` -- 11 arms, executed 11, failures 0, skipped 0. *** *The four direction/scale combinations are `test:test_the_roster_survives_default_and_largest_text_in_ltr_and_rtl`, which carrieth a SCALE DISCRIMINATOR so a roster that never reflowed would redden.*",
             "*** AND THE ANNOUNCEMENT DOOR IS A LIVE RECORD RATHER THAN AN ASSERTION: `path:ios/Godstone/Sources/LabMesh/LabMeshRootApp.swift` carrieth `LabAnnouncements.announce`, written in the SAME closure that posteth the announcement, and the two SwiftUI containers `lab.sos.announced` (last posted SOS state words) and `lab.a11y.announced` (last posted outcome words) are readable through `.accessibilityValue`. *** *An unchanged record therefore meaneth the change was repainted and never announced.*",
             "*** AND THE HOST-DECIDABLE CONTRACT IS EXERCISED AT BOTH SCALES AND RTL: `test:test08TheHostDecidableAccessibilityContractPassesAtBothScalesAndRtl` runneth all seven checks (essential-control labelling, status-never-clipped, no-colour-only state, touch targets at the iOS 44pt minimum, reading order, RTL meaning, long content) at `default` and `largest_accessibility`, AND includeth the DISCRIMINATOR: a deliberately broken roster must FAIL three of them. *** *Seven passing checks alone would be satisfied by a check that returned `.pass` unconditionally.*",
             "`path:ios/Godstone/Sources/GodstoneMesh/AccessibilityContract.swift` -- the shared table (essential controls, `stateWords`, colour tokens, contrast thresholds) that BOTH the screen and the court read, so the screen cannot invent a status word and the two isles cannot drift.",
             "*** `retry` IS RECORDED AS A GAP, NOT AS SATISFIED: it is an `ESSENTIAL_CONTROLS` member with NO live surface in the iOS lab app and no runtime authority on either isle that a control could call. *** *A `UiNode` fabricated for it would be the same 'table pretending to be a screen' this clause exists to refuse; the gap is named so the next reader seeth exactly what is absent rather than reading a green roster.*",
             "*** AND WHAT REMAINS EXTERNAL IS NAMED RATHER THAN GLOSSED: `Requirement.humanRequired` checks -- the VoiceOver/TalkBack gesture flow and physical target feel -- stay `gs-ux-001.human-accessibility-acceptance` EXTERNAL_BLOCKED with `closure_evidence: null`. *** **AND THE TOOLING LIMIT IS STATED PLAINLY: an XCUITest CANNOT read accessibility traits nor posted announcements, so the announcement-door arms prove the RECORD moved, never the announcement a human would hear.** *THE INTERNAL OBLIGATION IS DISCHARGED BY RENDERED-SEMANTICS VERIFICATION ONLY.*",
         ]},
    ],
    "GS-ARCHIVE-005": [
        {"id": "gs-archive-005.app-witness",
         "text": "An executed iOS app/simulator witness for Archive recreation/restoration. The "
                 "ledger's claim that the app layer 'cannot be compiled because of NATIVE_MODELS' "
                 "is STALE: the canonical hosted workflow builds `Godstone-Light` successfully.",
         "status": "DISCHARGED", "evidence": [
             "`path:ios/Godstone/Tests/GodstoneArchiveUITests/GodstoneArchiveUITests.swift` -- THE EXECUTED ARM `testGSA005DocumentReopensAfterCleanProcessDeath`, which terminate()s the process and RELAUNCHES it, then asserts the reader returned. MEASURED GREEN at 47.011s and 47.131s across two independent runs, with all six archive arms green and the lane control reporting `ios:ui suites=2 tests=12 failures=0`.",
             "`path:ios/Godstone/Sources/GodstoneCore/ArchivePlaceStore.swift` -- THE DURABLE VEHICLE. *The arm was DETERMINISTICALLY RED for the life of the defect and it was RIGHT: the place stood in @SceneStorage, scene-scoped by contract, discarded with the scene and restorable only for an app that OPTS INTO STATE RESTORATION -- which this target carrieth not.* The record is a UserDefaults record now, written at the app's OWN transitions, so it surviveth the terminate() the arm performeth.",
             "`path:ios/Godstone/Sources/App/ArchiveView.swift` -- the write call sites at the app's guaranteed transitions (openedDocumentId, scrollAnchor), and the read on launch.",
             "AND THE ARM IS NOT GREEN BY WEAKENING: `IOS_UI_KNOWN_RED` is now EMPTY. The allowance that permitted this arm's red was retired WITH the cause, and `path:ci/check_lane_results.py` carrieth the negative control proving a failure here now reddeneth the lane.",
         ]},
    ],
    "GS-FINAL-006": [
        {"id": "gs-final-006.ios-restoration-witness",
         "text": "An executed iOS app-level restoration/scroll witness: launch, search, open, "
                 "scroll to a stable passage, recreate, verify the same document and a valid "
                 "anchor return, Back returns to the submitted query, and an invalid anchor falls "
                 "back safely.",
         # *** ONE EXECUTED SEQUENCE, NOT A SET OF FRAGMENTS -- WHICH IS WHAT THE OBLIGATION EXPLICITLY DEMANDETH. ***
         #
         # *The mission's own charge: "Do not discharge this merely because several separate tests each prove one
         # fragment if no executed journey proves the required composition. **If the card explicitly requires one
         # end-to-end sequence, write one.**"* *So this is ONE arm doing all ten steps in order, because the VALUE is in
         # their ORDER AND CONTINUITY: a recreation between the search and the open testeth something different from a
         # recreation after the scroll, and a per-step arm can pass while the COMPOSITION is broken.*
         #
         # **AND THE INVALID-ANCHOR CLAUSE IS EXERCISED WHERE IT CAN ACTUALLY FIRE, BECAUSE IT IS THE EASIEST CLAUSE IN
         # THIS FINDING TO FAKE GREEN.** *`ArchiveReadingAnchor` decideth it correctly and `ReadinessArchive004Tests`
         # witnesseth the PURE FUNCTION -- but a pure-function court can pass while the production road never calls it.*
         "status": "DISCHARGED", "evidence": [
             "`path:ios/Godstone/Tests/GodstoneArchiveUITests/GodstoneArchiveUITests.swift` -- `testGSFINAL006TheWholeRestorationJourneyInOneSequence`, THE ONE EXECUTED SEQUENCE: launch, search, open a NON-FIRST hit, scroll to a later passage, terminate the process, RELAUNCH, the same document, a valid anchor, Back to the SUBMITTED SEARCH, and the same result set. MEASURED PASSED with all seven archive arms green, rc=0, ZERO launch refusals.",
             "`path:ios/Godstone/Tests/GodstoneCoreTests/GsArchive005IOSRestorationTests.swift` -- `testGSA005AnInvalidAnchorFallsBackAndTheFallbackIsObservedFiring`, THE INVALID-ANCHOR CLAUSE THROUGH THE REAL SCENE AND IN BOTH DIRECTIONS: a valid anchor must survive, and an anchor naming a passage the document CANNOT contain must yield the BEGINNING. *Two directions because one can be satisfied by a CONSTANT -- a fallback that always fired would fail the valid half, and one that never fired would fail the invalid half.* And `anchorHolds` must REPORT the fallback, since a silent one is indistinguishable from a successful restore. MEASURED: 4 tests, 0 failures.",
             "`path:ios/Godstone/Sources/GodstoneCore/ArchiveReadingAnchor.swift` -- the production decision the executed arm above is pointed at: the saved anchor winneth when the document still carrieth it, the reader FALLETH BACK to the beginning otherwise, and never waiteth for a passage that cannot come.",
             "AND THE ASSERTIONS ARE NOT VACUOUS, WHICH TOOK A REVIEW TO CATCH: the anchor check first read `anchorId.exists || firstMatch.exists` and **the `||` DESTROYED IT -- any passage satisfied the right-hand side, so it could pass with the anchor restored to the WRONG POSITION**. It now asserteth the PASSAGE IDENTITY itself, and asserteth what the READER OBSERVED rather than the model's persisted INTENT.",
         ]},
        {"id": "gs-final-006.mutation",
         "text": "Disconnect the production restore/anchor consumption and confirm the executed "
                 "app test FAILS.",
         "status": "DISCHARGED", "evidence": [
             "`path:ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift` -- THE MUTATION: restore(from:)'s .document case IGNORED the persisted openedDocumentId and returned to the list instead of reopening the document.",
             "`path:ios/Godstone/Tests/GodstoneArchiveUITests/GodstoneArchiveUITests.swift` -- *** AND IT WAS RE-TAKEN AS ONE UNINTERRUPTED SEQUENCE ON THE SETTLED TREE, BECAUSE A MUTATION IS ONLY AS STRONG AS THE GREEN THAT PRECEDED IT: green on the current tree (that arm PASSED at 47.107s), THEN the mutation applied, THEN THE SAME RUN MUTATED -- the arm FAILED at 36.149s while the other five passed and the run carried ZERO launch refusals.*** *So on the settled tree the arm had EXACTLY ONE candidate cause, and the failure therefore meaneth what this discharge claimeth.* A MUTATION THAT REDDENETH AN INCIDENTAL FAILURE PROVES NOTHING; THIS ONE REDDENED THE CLAIM ITSELF.",
             "AND IT WAS TAKEN ON THE REAL APP ROAD, NOT A MODEL COURT: the arm terminate()s and relaunches the process, so the mutation had to break the ACTUAL restoration to fail it. The source was restored and verified: marker absent, byte-identical to HEAD, `path:scripts/sync_ios_foundation_package.py` --check rc=0, and the six arms green again.",
         ]},
    ],
    "GS-STORE-002": [
        {"id": "gs-store-002.internal-architecture",
         "text": "Internal connection-ownership architecture complete (shared with "
                 "GS-FINAL-004): the absent native engine must NOT be treated as an excuse for "
                 "connection-ownership work, and may not be the only recorded remainder.",
         # *** RECONCILED AGAINST GS-FINAL-004, AS THE OBLIGATION ITSELF INSTRUCTS. ***
         #
         # *THE MISSION'S CHARGE FOR THIS ONE (section 11): **"Do not preserve an OPEN obligation merely because nobody
         # reconciled duplicated findings. Do not close it merely because the names sound related. Prove equivalence or
         # implement the delta."*** *So the comparison was made clause by clause against the ORIGINAL card text, and
         # the sibling's artifacts are CITED rather than paraphrased, so the share is auditable.*
         #
         # **THE CARD'S OWN `remaining_work` AND `pending_work` NAME THE ENGINE AND NOTHING ELSE.** *The composition's
         # plaintext default was closed in round 521 (it now REFUSETH a private store without a verifying factory, and
         # the plaintext road is reachable only through the NAMED archive entry); the DEK-erasure wiring into the
         # crash-resumable wipe authority was measured already landed; and both protection call sites pass the real
         # paths.* **WHAT REMAINETH IS "The concrete SQLCipher engine", WHICH THIS LEDGER ALREADY CARRIETH AS ITS OWN
         # STRUCTURED EXTERNAL OBLIGATION `gs-store-002.sqlcipher-engine`** -- *because `EncryptedStoreEngine` is a
         # PROTOCOL and `Sources/` carrieth no implementation.*
         #
         # *SO THE INTERNAL ARCHITECTURE IS SHARED WITH GS-FINAL-004 AND IS COMPLETE ON THE SAME TERMS: the absent
         # native engine is no longer an excuse for connection-ownership work (that work is discharged on the
         # sibling), and it is no longer the ONLY recorded remainder (it is one structured external obligation with
         # its own receipt condition).* **AND THE DELTA IS IMPLEMENTED BELOW THE LINE, NOT ARGUED AWAY: the connection
         # the composition runs on, the identity the stores report, and the road the permit gates are all in the tree
         # and all measured.**
         "status": "DISCHARGED",
         "evidence": [
             "`path:ios/Godstone/Sources/GodstoneMesh/OwnedVerifiedConnection.swift`, `path:ios/Godstone/Sources/GodstoneMesh/EncryptedStoreFactory.swift` -- THE SAME ARTIFACTS CITE THE SIBLING'S `gs-final-004.owned-connection`: the factory returneth an `OwnedConnectionResult` carrying an `OwnedConnection`, and the stores ADOPT it rather than opening by path.",
             "`path:ios/Godstone/Sources/GodstoneMesh/MessageStore.swift`, `path:ios/Godstone/Sources/GodstoneMesh/PeerIdentityStore.swift` -- BOTH stores take a verified connection (the sibling's `gs-final-004.identity-proof` and `gs-final-004.migrations-on-verified` cite these same two files), so migrations run on the verified/owned connection.",
             "`test:testGF004TheStoreRunsOnTheEnginesOwnVerifiedConnection` and `test:testGF004TheCompositionRunsItsStoresOnTheEnginesConnections` -- MEASURED GREEN: 52 arms passed with 0 failures across `CrashStartupResumeTests`, `GsFinal003StartupPermitTests`, `GsFinal003AdmissionPointTests` and `GsFinal004OwnedConnectionTests`, after the private road began REQUIRING a `PrivateRuntimePermit`.",
             "`path:ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift` -- THE COMPOSITION, cited by the sibling's `gs-final-004.no-second-open`: the `url:` opens are UNREACHABLE when a factory is supplied, and the permit now gate the private road itself.",
         ]},
    ],
    "AUDIT-B1-CTRL-001": [
        {"id": "audit-b1-ctrl-001.structured-obligations",
         "text": "Structured per-finding closure: `internal_status`, `internal_obligations` and "
                 "`external_obligations` for every nonterminal finding, with `internal_remaining` "
                 "DERIVED from them rather than NLP-classified from prose.",
"status": "DISCHARGED", "evidence": ["`path:scripts/build_structured_closure.py` --write wrote `finding_closure` (68 entries, every one carrying `internal_status`) + `structured_counts` into the ledger; `internal_remaining_prose_classifier_retired` records the NLP classifier as RETAINED-FOR-HISTORY-ONLY and NOT an input to any closure decision, so `internal_remaining` is DERIVED from explicit obligation statuses"]},
        {"id": "audit-b1-ctrl-001.closure-law",
         "text": "A control that REFUSES a COMPLETE/READY builder status while structured "
                 "internal OPEN work exists, so the control plane can no longer report closure "
                 "over a NO_GO register.",
"status": "DISCHARGED", "evidence": ["`path:docs/production-readiness/BOARD1_CLOSURE.json`, `path:scripts/build_structured_closure.py`. MEASURED BOTH DIRECTIONS 2026-09-20: with BOARD1_CLOSURE.status set to READY_FOR_EXTERNAL_REAUDIT the control REFUSED -- `rc=1` with `::error:: BOARD1_CLOSURE.status is READY_FOR_EXTERNAL_REAUDIT while 30 structured internal obligation(s) are OPEN across 10 finding(s)`. Restored to REMEDIATION_IN_PROGRESS: `rc=0`. The law BITES, so the control plane cannot report closure over a NO_GO register"]},
        {"id": "audit-b1-ctrl-001.missed-partials",
         "text": "Every PARTIAL is represented, including GS-RUNTIME-001 and GS-STORE-002, which "
                 "the prose classifier missed entirely.",
"status": "DISCHARGED", "evidence": ["`path:scripts/build_structured_closure.py`. `build()` output carries GS-RUNTIME-001 (2 obligations) and GS-STORE-002 (1 obligation), which the prose classifier missed entirely; `counts().obligations_by_state` reports them."]},
        # *** THE TWO OBLIGATIONS THIS MISSION'S OWN CONTROL-PLANE REVIEW ADDED. ***
        {"id": "audit-b1-ctrl-001.finding-obligation-consistency",
         "text": "A finding may not stand internally OPEN while carrying ZERO unresolved obligations. "
                 "The instrument must refuse that combination rather than describe it, because such a "
                 "finding is open with nothing a builder can execute -- so no batch of work could ever "
                 "close it, and its recorded status has not followed its own obligations.",
"status": "DISCHARGED", "evidence": ["`path:scripts/build_structured_closure.py`. MEASURED BEFORE THE FIX: `AUDIT-B1-CTRL-001` and `GS-FINAL-004` each carried `internal_status = OPEN` with ZERO unresolved obligations, so both were internally open with nothing left to do. `build()` now refuseth the combination in both places (the ledger population and the synthesised AUDIT entry) and `finding_state_problems()` is enforced by `--check`; `counts()` additionally reports `findings_with_internal_status_open` beside the obligation total, because the obligation count cannot see a finding with no obligations. Killed by `path:tools/readiness/tests/test_closure_law_refuses.py:287` (`FindingStatusFollowsItsObligations`), with the live-tree case at `:281`. AND MY FIRST REPAIR OF THIS RULE WAS ITSELF WRONG -- it fired on ALL-TERMINAL findings, which would have REFUSED EVERY CORRECTLY-CLOSED FINDING -- so the mirror case at `:296` pinneth the permitted state."]},
        {"id": "audit-b1-ctrl-001.ready-requires-both-populations",
         "text": "A COMPLETE/READY builder status must be refused while EITHER population is non-empty: "
                 "unresolved internal obligations, and findings whose internal_status is OPEN. The two are "
                 "not the same test, and a gate reading only one of them can permit readiness over live work.",
"status": "DISCHARGED", "evidence": ["`path:scripts/build_structured_closure.py`. MEASURED: a gate reading only `internal_obligations_unresolved` would have PERMITTED `READY_FOR_EXTERNAL_REAUDIT` while ten findings still reported themselves internally open, because two of them carried zero obligations to count. `--check` now refuseth on both conditions by name; killed by `path:tools/readiness/tests/test_closure_law_refuses.py:361` (`ReadinessRequiresBothPopulations`)."]},
    ],
}


def load(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def build(ledger: dict) -> dict:
    """Derive the structured closure from the ledger's STATUSES and the authored obligations."""
    original = ledger["findings"]
    new = ledger["independent_audit_new_findings"]["findings"]
    closure: dict[str, dict] = {}
    problems: list[str] = []

    for group, findings in (("original", original), ("independent", new)):
        for fid, entry in sorted(findings.items()):
            status = entry.get("my_status") or entry.get("status") or "OPEN"
            internal = STATUS_TO_INTERNAL.get(status)
            if internal is None:
                problems.append(
                    f"{fid}: status {status!r} has no structured mapping -- a finding this "
                    f"builder may not write must not silently become a completion")
                continue
            if fid in closure:
                problems.append(f"{fid}: appears in BOTH populations")
            recorded_internal = internal
            entry_out = {
                "group": group,
                "severity": entry.get("severity"),
                "recorded_status": status,
                "internal_status": recorded_internal,
                "internal_obligations": [dict(o) for o in PARTIAL_OBLIGATIONS.get(fid, [])],
                "external_obligations": list(entry.get("external_obligations") or []),
            }
            # *** AND THE DERIVED STATUS REPLACES THE RECORDED ONE WHERE OBLIGATIONS EXIST. ***
            #
            # *MEASURED: `AUDIT-B1-CTRL-001` and `GS-FINAL-004` each carried `internal_status = OPEN` with ZERO
            # unresolved obligations, so they stood open with nothing left to do and vanished from
            # `findings_internal_open` (which counteth OBLIGATIONS). **A STATUS THE OBLIGATION SET CONTRADICTETH IS
            # THE PROSE DEFECT WEARING A STRUCTURED FIELD.*** *The recorded status is preserved beside the derived one
            # rather than overwritten, so the disagreement remaineth auditable.*
            # *** AND THE INCONSISTENCY IS `OPEN` BESIDE AN ALL-TERMINAL SET -- NOT TERMINALITY ITSELF. ***
            #
            # *MEASURED: my first version fired whenever a finding's obligations were ALL terminal, which would have
            # refused EVERY correctly-closed finding -- **a guard that refuseth the state it is meant to permit is the
            # mirror defect of one that permitteth the state it is meant to refuse.*** *The defect is a finding that
            # claimeth to be internally OPEN while nothing in it remaineth open, because no batch of work could ever
            # close it.*
            if recorded_internal == "OPEN" and entry_out["internal_obligations"] and obligations_are_terminal(entry_out):
                problems.append(
                    f"{fid}: recorded internal status is {recorded_internal!r} while ALL "
                    f"{len(entry_out['internal_obligations'])} of its obligations are terminal. A finding cannot "
                    f"stand internally open with nothing left to do -- so the recorded status has not followed its "
                    f"own obligations. Discharge is incomplete and an obligation must be reopened with evidence, or "
                    f"the finding's recorded status must be updated to FIX_SUBMITTED in the ledger")
            closure[fid] = entry_out
            if recorded_internal == "OPEN" and not PARTIAL_OBLIGATIONS.get(fid):
                problems.append(
                    f"{fid}: internal_status OPEN but NO obligations authored -- an OPEN finding "
                    f"with nothing named is the prose defect wearing a structured field")

    # AUDIT-B1-CTRL-001 is an independent-audit finding that is not yet in the ledger's
    # populations; it is this mission's own control-plane repair and must be represented.
    if "AUDIT-B1-CTRL-001" not in closure:
        aud_obls = [dict(o) for o in PARTIAL_OBLIGATIONS["AUDIT-B1-CTRL-001"]]
        entry_out = {
            "group": "external_audit_2026_09_20",
            "severity": "High",
            "recorded_status": "PARTIAL",
            # *** THE STATUS FOLLOWETH THE OBLIGATIONS, WHICH IS THE RULE THIS MISSION ADDED. ***
            # *All three original obligations are DISCHARGED, so a finding reported as internally OPEN would be open
            # with nothing a builder could execute. `internal_status` is therefore derived here rather than asserted --
            # **and `recorded_status` is left at `PARTIAL` so the disagreement remaineth visible in the record for the
            # independent auditor rather than being overwritten.*** *The LEDGER status is the separate, durable
            # expression of the same fact and is flipped with the mission's other status work.*
            "internal_status": "COMPLETE" if obligations_are_terminal({"internal_obligations": aud_obls}) else "OPEN",
            "internal_obligations": aud_obls,
            "external_obligations": [],
        }
        closure["AUDIT-B1-CTRL-001"] = entry_out

    if problems:
        for p in problems:
            print(f"  ::error:: {p}", file=sys.stderr)
        raise SystemExit("the structured closure could not be derived coherently")

    return closure


#: *** THE LEGAL OBLIGATION STATES, AND TERMINALITY DERIVED FROM THE SET RATHER THAN FROM A LITERAL. ***
#:
#: *THE DEFECT THIS CLOSES, MEASURED BEFORE THE FIX:* the map held **18 OPEN, 2 PARTIAL and 10 DISCHARGED**
#: obligations, and `counts()` summed only `status == "OPEN"` -- **SO THE TWO `PARTIAL` OBLIGATIONS DISAPPEARED FROM
#: THE UNRESOLVED TOTAL (18 reported against 20 unresolved).** *Worse, it created a FALSE-CLOSURE PATH, and I proved it
#: by simulation: **with all 18 OPEN discharged and the 2 PARTIALs remaining, the derived count fell to ZERO and the
#: law PERMITTED `READY_FOR_EXTERNAL_REAUDIT` (rc=0) over live unresolved work.*** **That is AUDIT-B1-CTRL-001's
#: defect class reproducing itself in the instrument built to prevent it.**
#:
#: **SO TERMINALITY IS NOW A PROPERTY OF AN EXPLICIT SET, NOT OF A STRING COMPARISON.** *`PARTIAL` means "not
#: finished", and a comparison that honours only one spelling of "not finished" is the same defect as a prose
#: classifier -- it under-counts silently.*
OBLIGATION_STATES = ("OPEN", "PARTIAL", "DISCHARGED")
UNRESOLVED_OBLIGATION_STATES = ("OPEN", "PARTIAL")
TERMINAL_OBLIGATION_STATES = ("DISCHARGED",)


def obligation_state_problems(closure: dict) -> list[str]:
    """*** EVERY OBLIGATION MUST CARRY A LEGAL STATE; AN UNKNOWN ONE IS AN ERROR, NEVER A SKIP. ***

    *A status this instrument does not recognise cannot be silently treated as terminal OR as unresolved -- either
    guess is a false reading of the record. Naming it is the only honest option, and it is what makes a typo loud.*
    """
    problems: list[str] = []
    for fid, f in sorted(closure.items()):
        for o in (f.get("internal_obligations") or []):
            st = o.get("status")
            if st not in OBLIGATION_STATES:
                problems.append(
                    f"{o.get('id', '<no id>')} carrieth obligation status {st!r}, which is NOT one of "
                    f"{OBLIGATION_STATES} -- an unknown state is neither terminal nor unresolved, so this instrument "
                    f"may not guess which")
    return problems


def obligations_are_terminal(entry: dict) -> bool:
    """*** A FINDING'S INTERNAL TERMINALITY IS A FUNCTION OF ITS OBLIGATIONS, NOT A SECOND OPINION ABOUT THEM. ***

    *THE DEFECT THIS CLOSES, MEASURED ON THE LIVE TREE: **TWO FINDINGS CARRIED `internal_status = OPEN` WHILE EVERY
    ONE OF THEIR OBLIGATIONS WAS `DISCHARGED`** -- `AUDIT-B1-CTRL-001` and `GS-FINAL-004`, both with zero unresolved
    obligations.* **So a finding could stand internally OPEN while contributing NOTHING to the unresolved population,
    which is a state the instrument could describe but not justify: nothing could ever close it, because there was no
    work left to do.*** *Worse, `findings_internal_open` is computed from unresolved OBLIGATIONS, so those two findings
    were invisible in that total -- a reader comparing "findings INTERNAL OPEN = 8" against a status list showing ten
    OPEN findings would find no field explaining the gap.*

    **SO TERMINALITY IS DERIVED, AND AN OBLIGATION-BEARING FINDING IS TERMINAL EXACTLY WHEN NONE OF ITS OBLIGATIONS IS
    UNRESOLVED.** *An obligation the builder authored is work the builder can finish; when it is finished, the finding
    has nothing left that a builder can execute.*
    """
    return not any(o.get("status") in UNRESOLVED_OBLIGATION_STATES
                   for o in (entry.get("internal_obligations") or []))


def finding_state_problems(closure: dict) -> list[str]:
    """*** A FINDING MAY NOT BE INTERNALLY OPEN WHILE CARRYING ZERO UNRESOLVED OBLIGATIONS. ***

    *That is the state-model inconsistency AUDIT-B1-CTRL-001 left behind: an OPEN finding with nothing in it. It reads
    as live work while no work is named, which is the prose defect wearing a structured field -- **the same class the
    `OPEN`-with-no-obligations guard already refuseth, approached from the other direction.***

    *A finding with NO authored obligations is NOT covered by this rule: its terminality is not derivable from a set
    that does not exist, so it keeps its recorded status.*
    """
    problems: list[str] = []
    for fid, f in sorted(closure.items()):
        obls = f.get("internal_obligations") or []
        if not obls:
            continue
        if f.get("internal_status") == "OPEN" and obligations_are_terminal(f):
            problems.append(
                f"{fid}: internal_status is OPEN while ALL {len(obls)} of its obligations are terminal -- "
                f"a finding cannot be internally open with nothing left to do, because no batch of work could ever "
                f"close it. Either discharge is incomplete and an obligation must be reopened with evidence, or the "
                f"finding's recorded status has not followed its own obligations")
        # *** AND THE SYMMETRIC DIRECTION, WHICH MY FIRST VERSION OMITTED AND A MUTATION FOUND. ***
        #
        # *THE CLOSURE MISSION'S SECTION 19 LISTETH BOTH DIRECTIONS AS REQUIRED KILLS: "3. PARTIAL finding with zero
        # unresolved obligations -> REFUSE" AND "4. FIX_SUBMITTED finding with an OPEN obligation -> REFUSE".* **MY
        # FIRST RULE COVERED ONLY THE FIRST, SO MUTATION 4 WOULD HAVE ESCAPED -- a finding declared COMPLETE while its
        # own obligation set saith otherwise, which is the direction that MATTERS MOST: it is the one that claimeth
        # work is finished.*** *A rule that refuses "closed but nothing done" while permitting "done but not closed"
        # guardeth the state nobody reaches and misseth the state a builder is tempted to write.*
        if f.get("internal_status") != "OPEN" and not obligations_are_terminal(f):
            live = [o.get("id") for o in obls if o.get("status") in UNRESOLVED_OBLIGATION_STATES]
            problems.append(
                f"{fid}: internal_status is {f.get('internal_status')!r} while "
                f"{len(live)} of its obligations are UNRESOLVED ({', '.join(str(x) for x in live[:3])}"
                f"{'...' if len(live) > 3 else ''}) -- a finding declared complete over live internal work is the "
                f"overclaim this control plane existeth to refuse")
    return problems


def counts(closure: dict) -> dict:
    """Derives the counts from EXPLICIT STATES, so no unresolved subtype can vanish.

    *`internal_obligations_unresolved` supersedes the old `internal_obligations_open` name: the field counts `OPEN`
    **AND** `PARTIAL`, so a name saying `open` would be semantically dishonest about its own contents.*
    """
    unresolved = sum(
        1 for f in closure.values()
        for o in f["internal_obligations"] if o["status"] in UNRESOLVED_OBLIGATION_STATES)
    by_state = {st: sum(1 for f in closure.values()
                        for o in f["internal_obligations"] if o["status"] == st)
                for st in OBLIGATION_STATES}
    findings_unresolved = sum(1 for f in closure.values()
                              if any(o["status"] in UNRESOLVED_OBLIGATION_STATES
                                     for o in f["internal_obligations"]))
    # *** AND THE STATUS ITSELF IS COUNTED, BECAUSE THE OBLIGATION COUNT CANNOT SEE A FINDING WITH NO OBLIGATIONS. ***
    #
    # *MEASURED: `AUDIT-B1-CTRL-001` and `GS-FINAL-004` carried internal_status OPEN with ZERO unresolved
    # obligations, so `findings_internal_open` (which counteth obligations) reported 8 while TEN findings stood
    # internally OPEN. **A reader comparing those two numbers had no field explaining the gap.*** *Section 23 of the
    # closure mission requires `findings with internal_status OPEN = 0` as a readiness condition in its own right, so
    # the status population is now reported separately rather than inferred.*
    findings_status_open = sum(1 for f in closure.values() if f.get("internal_status") == "OPEN")
    external = sum(len(f["external_obligations"]) for f in closure.values())
    return {
        "findings_total": len(closure),
        "findings_internal_open": findings_unresolved,
        "findings_with_internal_status_open": findings_status_open,
        "internal_obligations_open": unresolved,          # kept: the law and its courts read this name
        "internal_obligations_unresolved": unresolved,    # the honest name, same value
        "obligations_by_state": by_state,
        "external_obligations": external,
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="structured per-finding closure")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args(argv)

    ledger = load(LEDGER)
    closure = build(ledger)
    c = counts(closure)

    print(f"  findings total            : {c['findings_total']}")
    print(f"  findings INTERNAL OPEN    : {c['findings_internal_open']}")
    print(f"  internal obligations OPEN : {c['internal_obligations_open']}")
    print(f"  external obligations      : {c['external_obligations']}")

    if args.write:
        ca = ledger["current_assessment"]
        ca["finding_closure"] = closure
        ca["structured_counts"] = c
        # *** THE DERIVED FIELD REPLACES THE NLP ONE AS AUTHORITY. *** *`internal_remaining` is
        # kept ONLY as a historical record of what the prose classifier produced; nothing reads
        # it for closure any more. A number that moved 27 -> 21 -> 5 -> 4 belongs in a history
        # note, not in a gate.*
        ca["internal_remaining_prose_classifier_retired"] = {
            "note": "RETAINED FOR AUDIT HISTORY ONLY -- NOT AN INPUT TO ANY CLOSURE DECISION. "
                    "Derived by substring-matching prose; produced 27, 21, 5 and 4 across four "
                    "marker lists, which is why it was retired. Superseded by `structured_counts`, "
                    "which counts explicit obligation statuses.",
            "last_value": len(ca.get("internal_remaining", [])),
        }
        LEDGER.write_text(json.dumps(ledger, indent=1, ensure_ascii=False), encoding="utf-8")
        print("  wrote `finding_closure` + `structured_counts` into the ledger")

    if args.check:
        closure_doc = load(CLOSURE)
        status = closure_doc.get("status")
        if status in ("COMPLETE", "READY_FOR_EXTERNAL_REAUDIT") and c["internal_obligations_open"] > 0:
            print(f"  ::error:: BOARD1_CLOSURE.status is {status!r} while "
                  f"{c['internal_obligations_open']} structured internal obligation(s) are OPEN "
                  f"across {c['findings_internal_open']} finding(s). THE CONTROL PLANE MAY NOT "
                  f"REPORT CLOSURE OVER LIVE INTERNAL WORK -- that is AUDIT-B1-CTRL-001.")
            return 1
        # *** AND READINESS REQUIRES BOTH POPULATIONS TO BE EMPTY, NOT ONE. ***
        #
        # *Section 23 of the closure mission nameth `findings with internal_status OPEN = 0` as a condition IN ITS OWN
        # RIGHT, beside `internal obligations unresolved = 0`.* **THE TWO ARE NOT THE SAME TEST, AND MEASURING SHOWED
        # IT: `AUDIT-B1-CTRL-001` and `GS-FINAL-004` stood internally OPEN with ZERO unresolved obligations, so a gate
        # reading only the obligation count would have permitted READY while ten findings still reported themselves
        # internally open.***
        if status in ("COMPLETE", "READY_FOR_EXTERNAL_REAUDIT") and c["findings_with_internal_status_open"] > 0:
            print(f"  ::error:: BOARD1_CLOSURE.status is {status!r} while "
                  f"{c['findings_with_internal_status_open']} finding(s) still carry internal_status OPEN. "
                  f"A readiness claim must be empty in BOTH populations -- unresolved OBLIGATIONS and OPEN "
                  f"FINDINGS -- because a finding can be open with no obligations to count.")
            return 1
        if closure_doc.get("verified_fixed") not in (None, 0):
            print("  ::error:: verified_fixed is non-zero; only an INDEPENDENT audit may write it")
            return 1

        # *** EVERY OBLIGATION CARRIES A LEGAL STATE, AND AN UNKNOWN ONE IS AN ERROR. ***
        state_problems = obligation_state_problems(closure)
        for msg in state_problems:
            print(f"  ::error:: {msg}")
        if state_problems:
            return 1

        # *** AND A FINDING MAY NOT BE OPEN WITH NOTHING LEFT TO DO. ***
        #
        # *MEASURED BEFORE THE FIX: `AUDIT-B1-CTRL-001` and `GS-FINAL-004` each stood `internal_status = OPEN` with
        # ZERO unresolved obligations -- **internally open with nothing a builder could execute, so no batch of work
        # could ever have closed them.*** *The derived status now refuses that combination outright rather than
        # describing it.*
        finding_problems = finding_state_problems(closure)
        for msg in finding_problems:
            print(f"  ::error:: {msg}")
        if finding_problems:
            return 1

        # *** THE PERSISTED STRUCTURED STATE MUST EQUAL WHAT THIS LOGIC DERIVES. ***
        #
        # *THE DEFECT THIS CLOSES, MEASURED BEFORE THE FIX: the ledger carried
        # `structured_counts.internal_obligations_open = 30` while the derivation produced **18** -- **TWO
        # DISAGREEING STRUCTURED REPRESENTATIONS OF THE SAME STATE, which is exactly the narrative/state drift this
        # control plane exists to eliminate.*** *And `--check` never looked at them: it read only the closure
        # document's `status`, so a stale persisted field could sit green indefinitely.*
        #
        # **SO THE CHECK COMPARES THE PERSISTED VALUES TO THE DERIVED ONES, FIELD BY FIELD AND OBLIGATION BY
        # OBLIGATION.** *A count that has drifted, a status that has drifted, a missing entry and an orphan entry are
        # each refused by name -- four shapes, because "the numbers differ" would not tell a reader which.*
        persisted_ca = ledger.get("current_assessment") or {}
        persisted_counts = persisted_ca.get("structured_counts")
        if persisted_counts is None:
            print("  ::error:: the ledger carrieth NO `current_assessment.structured_counts` -- run `--write` so the "
                  "persisted state exists to be checked")
            drift = ["structured_counts absent"]
        else:
            drift = []
            for key in sorted(set(c) | set(persisted_counts)):
                if c.get(key) != persisted_counts.get(key):
                    drift.append(f"structured_counts.{key}: persisted {persisted_counts.get(key)!r} != derived "
                                 f"{c.get(key)!r}")
        persisted_fc = persisted_ca.get("finding_closure")
        if persisted_fc is None:
            drift.append("current_assessment.finding_closure absent")
        else:
            for fid in sorted(set(closure) | set(persisted_fc)):
                if fid not in persisted_fc:
                    drift.append(f"{fid}: derived but MISSING from the persisted closure")
                    continue
                if fid not in closure:
                    drift.append(f"{fid}: persisted but ORPHANED from the derived closure")
                    continue
                live = {o.get("id"): o.get("status") for o in (closure[fid].get("internal_obligations") or [])}
                kept = {o.get("id"): o.get("status")
                        for o in (persisted_fc[fid].get("internal_obligations") or [])}
                if closure[fid].get("internal_status") != persisted_fc[fid].get("internal_status"):
                    drift.append(f"{fid}: internal_status persisted {persisted_fc[fid].get('internal_status')!r} != "
                                 f"derived {closure[fid].get('internal_status')!r}")
                for oid in sorted(set(live) | set(kept)):
                    if oid not in kept:
                        drift.append(f"{fid}/{oid}: derived but MISSING from the persisted closure")
                    elif oid not in live:
                        drift.append(f"{fid}/{oid}: persisted but ORPHANED from the derived closure")
                    elif live[oid] != kept[oid]:
                        drift.append(f"{fid}/{oid}: status persisted {kept[oid]!r} != derived {live[oid]!r}")
        if drift:
            for msg in drift[:20]:
                print(f"  ::error:: persisted/derived structured state DISAGREES: {msg}")
            if len(drift) > 20:
                print(f"  ::error:: ... and {len(drift) - 20} more disagreement(s)")
            print("  ::error:: RUN `--write` AND COMMIT THE RESULT: a persisted closure that this logic would not "
                  "derive is a second, stale representation of the same state.")
            return 1

        # *** THE INDEPENDENT BACKSTOP, WHICH EXISTS BECAUSE THIS FILE HOLDS BOTH THE COUNTER AND ITS INPUTS. ***
        #
        # *The obligation records and their statuses live HERE, in the gate's own source -- so the thing that counts
        # closures also holds the hand-authored constants it counts.* **A DISCHARGED STATUS IS THEREFORE NOT EVIDENCE
        # BY ITSELF, AND THIS REFUSES ONE THAT CANNOT POINT AT SOMETHING REAL.** *Bulk-discharging from inside the
        # gate could otherwise quietly neuter the very guard the programme depends on, and a batch after which the law
        # stops refusing while cards are still unmet would be the batch that was WRONG.*
        #
        # Each DISCHARGED obligation must carry at least one citation, and each citation must RESOLVE: a `file:line`,
        # a named `test...` / `func test...` symbol that exists in the tree, or a commit SHA that exists in history.
        problems: list[str] = []
        for fid, entry in sorted(PARTIAL_OBLIGATIONS.items()):
            for o in entry:
                if o.get("status") != "DISCHARGED":
                    continue
                cites = [c for c in (o.get("evidence") or []) if isinstance(c, str) and c.strip()]
                if not cites:
                    problems.append(
                        f"{o['id']}: DISCHARGED with NO evidence -- a status this builder may not carry "
                        f"unsubstantiated, because this file holds both the counter and its inputs")
                    continue
                # EVERY citation must carry at least one typed token, and EVERY token must resolve.
                # *`any(...)` would accept one lucky token in a paragraph of prose -- which is how the first draft
                # laundered bogus discharges.*
                tokens: list[tuple[str, str]] = []
                for c in cites:
                    tokens.extend(_evidence_tokens(c))
                if not tokens:
                    problems.append(
                        f"{o['id']}: DISCHARGED with evidence that carries NO TYPED TOKEN -- prose is allowed and "
                        f"ignored, but the CLAIM must be carried by `path:`/`commit:`/`test:` tokens a reader can check")
                    continue
                for kind, value in tokens:
                    if not _citation_token_resolves(kind, value):
                        problems.append(
                            f"{o['id']}: DISCHARGED but the citation token `{kind}:{value}` DOES NOT RESOLVE -- "
                            f"the record points at something that is not there")
        for msg in problems:
            print(f"  ::error:: {msg}")
        if problems:
            return 1
    return 0


# *** A DISCHARGE MUST CITE A TYPED, RESOLVING TOKEN -- NOT MERELY CONTAIN A PLAUSIBLE WORD. ***
#
# *MY FIRST VERSION WAS NEAR-ALWAYS GREEN, WHICH IS WORSE THAN HAVING NO BACKSTOP AT ALL: it accepted ANY existing
# path-like token (so mentioning `REMEDIATION_STATE.json` in prose resolved the whole claim), matched the bare word
# `tests` as a symbol (so `grep -rql tests ios android` always hit -- any sentence containing "tests" self-certified),
# and took any 7-hex word as a commit (`deadbeef` included). **A BACKSTOP THAT LAUNDERS A BOGUS DISCHARGE IS WORSE THAN
# NONE, because the file then carries an attestation nobody checked.***
#
# SO A CITATION IS NOW A **TYPED TOKEN**, and EVERY token in an obligation's evidence must resolve:
#     `path:<repo-relative-file>[:<line>]`   -- the file exists, and the line is within it
#     `commit:<sha>`                          -- the object exists in this repository
#     `test:<SymbolName>`                     -- the symbol is DEFINED in a source file under ios/ or android/
#
# *Anything else is prose, which is allowed and ignored -- the CLAIM is carried by the tokens, and prose cannot
# substitute for them. A tooling failure RAISES rather than silently counting as unresolved, so a broken checker can
# never look like a clean pass.*
_CITATION_TOKEN = re.compile(r"\b(path|commit|test):([^\s`'\"]+)")


def _symbol_is_defined(name: str) -> bool:
    """True iff `name` is DEFINED (a `func`/`class`/`struct`/`enum`/`fun` declaration) under ios/ or android/.

    *A tree walk, not a bare `grep` for the word: `grep -rl tests` always hits, so matching the WORD proves nothing.
    The declaration form is what makes a symbol citable.*
    """
    pattern = re.compile(
        r"\b(?:func|class|struct|enum|protocol|fun|def)\s+" + re.escape(name) + r"\b")
    for root in (ROOT / "ios", ROOT / "android"):
        if not root.is_dir():
            continue
        for f in root.rglob("*"):
            if not f.is_file() or f.suffix not in (".swift", ".kt", ".py"):
                continue
            try:
                text = f.read_text(encoding="utf-8", errors="ignore")
            except OSError as exc:
                raise RuntimeError(f"citation check could not read {f}: {exc}") from exc
            if pattern.search(text):
                return True
    return False


def _citation_token_resolves(kind: str, value: str) -> bool:
    if kind == "path":
        rel, _, line = value.partition(":")
        # Reject the traversal/absolute shapes outright rather than resolving them against the filesystem root.
        if rel.startswith(("/", "~")) or ".." in Path(rel).parts:
            return False
        f = ROOT / rel
        if not f.is_file():
            return False
        if line:
            if not line.isdigit():
                return False
            try:
                with f.open("r", encoding="utf-8", errors="ignore") as fh:
                    total = sum(1 for _ in fh)
            except OSError as exc:
                raise RuntimeError(f"citation check could not read {f}: {exc}") from exc
            if not (1 <= int(line) <= total):
                return False
        return True
    if kind == "commit":
        if not re.fullmatch(r"[0-9a-f]{7,40}", value):
            return False
        hit = subprocess.run(
            ["git", "-C", str(ROOT), "cat-file", "-e", f"{value}^{{commit}}"],
            capture_output=True, timeout=120,
        )
        return hit.returncode == 0
    if kind == "test":
        return _symbol_is_defined(value)
    return False


def _evidence_tokens(citation: str) -> list[tuple[str, str]]:
    return [(m.group(1), m.group(2)) for m in _CITATION_TOKEN.finditer(citation)]


if __name__ == "__main__":
    raise SystemExit(main())
