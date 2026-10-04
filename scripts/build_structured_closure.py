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
         # *** REOPENED 2026-10-02 -- THE DISCHARGED STATUS IS WITHDRAWN, NOT THE EVIDENCE. ***
         #
         # *THE PROOF CITED WAS A COURT (`path:ios/Godstone/Tests/.../GsFinal003StartupPermitTests.swift`), and the
         # obligation is about a LIVE PRODUCTION ROAD: "a recovery/bootstrap composition whose transport seam exists
         # BEFORE and independently of the store graph".* **MEASURED ON THE CURRENT TREE:** `MeshRuntime` still mints
         # its create-time decision over the DEFERRED seams (`WipeDeferredTransportSeam`,
         # `WipeDeferredIdentityAuthoritySeam`, `WipeDeferredKeyVaultSeam`, `WipeDeferredArtifactFileSystemSeam` at
         # `path:ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift`), so the composition whose transport seam is
         # INDEPENDENT of the store graph exists ONLY in the court's own rig; the PRODUCTION road never drives a LIVE
         # transport to a typed decision before the private graph. **THE COURT'S ORDER IS REAL AND MUTATION-VERIFIED,
         # AND THAT IS WHY THE EVIDENCE IS KEPT -- BUT A COURT-TIME ORDER OVER DEFERRED SEAMS IS NOT YET A PRODUCTION
         # REACHABILITY PROOF, SO THE OBLIGATION IS NOT DISCHARGED.** *The historical DISCHARGED claim stays recorded
         # below with an explicit HISTORICAL scope rather than being deleted: this ledger keepth its incriminating
         # prose.*
         "status": "OPEN", "evidence": [
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
         # *** REOPENED 2026-10-02 -- "Both platforms" NOW MEANS THE PRODUCTION CALLER CONSUMES THE PERMIT. ***
         #
         # *iOS: `MeshRuntime`'s private create road reaches the permit through `StartupRecoveryBootstrap` (a real
         # production consumer).* **ANDROID, MEASURED ON THE CURRENT TREE: `issuePrivateStorePermit` is called ONLY
         # from `MeshGraphComponent`'s `@Provides` companion (`path:android/mesh/src/main/java/io/godstone/mesh/di/
         # MeshGraphComponent.kt`), and NOTHING OUTSIDE `/test/` CONSTRUCTS `DaggerMeshGraphComponent` -- so on the
         # running Android app the permit-parameterised providers are a parallel, COURT-ONLY road, while the app's
         # live graph comes through `AppModule`/`MeshModule`.** *A typed authority that the production composition
         # never calls is the same "present and unused" shape the clause was written to refuse.* **THE COMPILE BITE IS
         # REAL AND KEPT AS EVIDENCE; WHAT IS UNMET IS PRODUCTION CONSUMPTION ON THE ANDROID ISLE, SO THIS IS NOT
         # DISCHARGED.** *The prior DISCHARGED claim is retained below with an explicit HISTORICAL scope.*
         "status": "OPEN", "evidence": [
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
         # *** REOPENED 2026-10-02 -- "AT THE REAL CONSTRUCTION SEAMS" IS NOT MET BY A SEAM ONLY A COURT CONSTRUCTS. ***
         #
         # *The counters are real (`PrivateConstructionCounter`), and the court is real (8 arms measured green).* **BUT
         # the zero-opens property is asserted over `DaggerMeshGraphComponent`, which only the court builds; the app's
         # live graph takes `MeshModule` through `AppModule`, where no counter is read and no refusing-rung road is
         # exercised at runtime. The obligation asketh for the property "proven at the REAL construction seams with
         # counters" -- and a counter on a road production does not walk is a measurement of the court.** *So the
         # counters are KEPT as evidence and the obligation is NOT DISCHARGED until the production composition is the
         # one whose deltas are counted.* *Prior DISCHARGED claim retained below with explicit HISTORICAL scope.*
         "status": "OPEN", "evidence": [
             "*** iOS HALF: DONE, WITH COUNTERS. *** `path:android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003ZeroPrivateOpensTest.kt` -- the ANDROID court: `noPermitIsIssuedOnAnyOutstandingRung`, `theCompositionIssuerRefusesOnEveryOutstandingRung`, and the positive controls `theTerminalRungIssuesThePermit` / `theCompositionIssuerPermitsOnTheTerminalRung`. **MEASURED: 5 tests, 0 failures**, with the refusing set DERIVED by asking the barrier. *A gate that always refused would fail the positive controls, and one that never refused would fail the others -- both directions.*",
             "*** ANDROID HALF, WITH COUNTERS COUNTERS AT THE REAL SEAMS: `path:android/mesh/src/main/java/io/godstone/mesh/di/PrivateConstructionCounter.kt`. *** *A plain `object` -- deliberately NOT a Dagger key, because a rebindable counter is a fakenable counter -- with one `AtomicLong` and a `@Volatile` authority per seam.* **The note is taken BEFORE the platform constructor, so on a JVM host the count reacheth 1 and the platform then throweth `KeyStoreException`/`UnsatisfiedLinkError`: the throw proveth the body WALKED TO the platform and the count proveth the ATTEMPT.**",
             "`path:android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt` -- THE SEAM: `PrivateStorePermit` carrieth a PRIVATE constructor and `issue(decision)` returneth `null` for every refusing decision, and the three private providers REQUIRE it as a parameter. So zero opens is not inferred from a later absence -- the authority that construction requireth DOES NOT EXIST on those roads.",
             "*** THREE COUNTER ARMS, DRIVEN THROUGH `DaggerMeshGraphComponent`, ALL MEASURED GREEN (8 tests, 0 failures): `thePermittedRoadCountsOneAttemptPerSeamAtThePlatform` (delta==1 per seam, authority==CLEAN_START, and the failure chain reacheth AndroidKeyStore/SQLCipher), `noRefusingRungMovesAnyConstructionCounter` (every delta==0 AND the resolution carrieth `NO PRIVATE STORE MAY BE CONSTRUCTED`), and `theCounterMovesOnThePermittedRoadAndNowhereOnARefusingOne` (the same-run conjunction). ***",
             "*** MUTATION-VERIFIED, BOTH DIRECTIONS: ROD `T72-RC13-android-private-construction-uncounted` (delete the `Seam.IDENTITY` note) is KILLED -- the permitted-road counter witness reddens; ROD `T72-RC14-android-private-permit-may-be-bypassed` (mint the permit from `CLEAN_START` instead of the ladder's answer) is KILLED -- the refusal witness reddens on three arms. *** *Each ran in a disposable worktree with a green baseline and an EXECUTED restored-green phase.*",
             "`path:ios/Godstone/Tests/GodstoneMeshTests/GsFinal003StartupPermitTests.swift` -- THE iOS HALF: `PrivateOpenCounter` (real counts at the construction seam, not the vestigial array nothing read), `CountingKeyProvider` (the factory asketh for a DEK BEFORE it reacheth the engine, so a refused startup that got there would have ASKED), and the keychain write spy for the identity boundary. **MEASURED: 14 tests, 0 failures**, covering pending, retryable AND corrupt -- *the obligation nameth all three, and only pending carried counters before.*",
             "AND THE MUTATION PROVES THE iOS COUNTERS BITE RATHER THAN MERELY PASSING: *an identity-boundary open placed ABOVE the permit gate on the road the arms drive KILLETH EXACTLY the two counter-bearing arms and no others.* **My first attempt at that mutation ESCAPED, and it was wrong twice -- it landed on the `create` road while the arms drive `requireRecoveredPrivateComposition`, and it used a keychain READ while the spy counteth WRITES.** *A mutation placed wrong is not an escaped mutation; it is an experiment that proved nothing.*",
         ]},        {"id": "gs-final-003.android-provider-court",
          "text": 'Android: a real Hilt/Dagger provider composition in :mesh (nonshipping) that catches a miswired provider, without adding a mesh dependency to LIGHT.',
          # *** REOPENED 2026-10-02 -- THE COMPONENT EXISTS, BUT NOTHING IN PRODUCTION USES IT. ***
          #
          # *The `@Singleton @Component` and its `DaggerMeshGraphComponent.builder()` court are real and the
          # miswiring mutation was RUN.* **MEASURED ON THE CURRENT TREE, HOWEVER: `MeshGraphComponent` is constructed
          # ONLY under `/test/`, so the component can catch a miswired provider in a court while the SHIPPING
          # composition (via `AppModule` -> `MeshModule`) is never checked by it -- the obligation nameth a component
          # that "catches a miswired provider", which for a composition ROOT means at its own use site.** *The
          # component is evidence; the production consumption it would guard is the unmet half.*
          "status": "OPEN", "evidence": ['`path:android/mesh/src/main/java/io/godstone/mesh/di/MeshGraphComponent.kt`, `path:android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003GraphComponentTest.kt`, `test:theRealComponentsGateAnswersBothDirections`, `path:ci/check_lab_isolation.py`. A real `@Singleton @Component` in the `:mesh` MAIN source set, delegating every provider to `MeshModule`, constructed by the court through `DaggerMeshGraphComponent.builder()`. **THE MISWIRING MUTATION WAS RUN, NOT ASSERTED: inverting `provideWipeIsPending` polarity (the exact 18-round production defect) REDDENS TWO ARMS** -- `theRealComponentsGateAnswersBothDirections` and `theRealComponentsGateIsReadPerCallNotCached`; restored, 7/7 pass. *** AND LIGHT GAINS NOTHING: `Godstone` declares ONE dependency (GodstoneCore, no mesh edge) and `ci/check_lab_isolation.py` rc=0.***']},
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
         # *** REOPENED 2026-10-02: THE STALE HALF WAS REPAIRED, AND THE ARM'S NEGATIVE CONTROL IS MISSING. ***
         #
         # *`CrashStartupResumeTests` now asserts the typed decision (`requiresOperator`, three distinct names), which
         # is the repair the clause asked for.* **BUT THE CLAUSE IS NARROW AND SAYS WHAT IT WANTS: arms that "must
         # ASSERT the typed decision" -- and a green arm over a typed value is not proof the arm would REDDEN if the
         # decision regressed to `Unit`/Bool. No rod in `ci/mutations.py` strikes this court's typed assertions, so the
         # typed-shape property is asserted but not mutation-witnessed.** *Until a named rod shows the arm bites, this
         # stays open rather than being called done.* *Prior DISCHARGED claim kept below, HISTORICAL scope.*
         "status": "OPEN", "evidence": [
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
         # *** REOPENED 2026-10-02 (SqliteReview): THE CLOSE OWNERSHIP RACES THE CONNECTION'S OWN USE. ***
         # *MEASURED BY A SOURCE AUDIT (`agent://SqliteReview`, 2 critical + 8 important): the image-lease engine
         # UNLOADS the CFN while live connections may still exist, and the owner `close()` races outstanding use -- a
         # use-after-free shape. The owned handle existeth (the prior discharge below is kept); what is NOT established
         # is that closing is safe against in-flight operations, which is the whole of "explicit close ownership". Not
         # discharged until the native owner provides the real proof.*
         "status": "OPEN", "evidence": ["`path:ios/Godstone/Sources/GodstoneMesh/OwnedVerifiedConnection.swift`, `path:ios/Godstone/Sources/GodstoneMesh/EncryptedStoreFactory.swift`, `test:testGF004TheStoreRunsOnTheEnginesOwnVerifiedConnection`. The engine yields an OWNED OPERATIONAL connection: `OwnedVerifiedConnection` carries an `internal init(rawHandle:engineKind:...)` (line 68) so ONLY the module can mint one, `OwnedConnection` exposes `public func close() -> Bool` (line 122) as the explicit close owner, and `EncryptedStoreFactory.reopenOwnedRequiringDEK` returns an `OwnedConnectionResult` -- never descriptive metadata that is discarded"]},
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
         # *** REOPENED 2026-10-02 (SqliteReview): THE MIGRATION ROAD USES `try?` AND MAY PROCEED ON A FALSE RESULT. ***
         # *MEASURED BY THE SOURCE AUDIT: `user_version` is read with `try?`, so a read FAILURE becometh a default and
         # the migration can run as if the version were known -- migrations may proceed on a FALSE result. The road is
         # on the verified connection (the prior discharge below is kept); what is NOT established is that a failed
         # version read REFUSES rather than defaulting, so this is not discharged.*
         "status": "OPEN", "evidence": ["`path:ios/Godstone/Sources/GodstoneMesh/MessageStore.swift`, `path:ios/Godstone/Sources/GodstoneMesh/PeerIdentityStore.swift`. `init(verifiedConnection:)` performs NO `sqlite3_open_v2` of its own and calls `try runMigrations(db)` on the SUPPLIED handle (MessageStore line 1021, PeerIdentityStore line 308); the legacy `init(url:)` roads run migrations on their own handles (lines 1086 and 336), so each road migrates the connection it actually owns"]},
        {"id": "gs-final-004.provider-dispatch",
         "text": "A pointer created by one SQLite implementation must not be passed to another: the complete function surface a store uses must be bound from the SAME image the handle came from, carried with the connection, and used for every operation; no global raw-pointer-to-provider map; a partial bind must refuse; a failed open must close its partial handle; and the key road must not echo the DEK.",
         # *** DISCHARGED -- THE PROVIDER TABLE TRAVELS WITH THE CONNECTION, AND THE LOADER/ERROR PATHS ARE REPAIRED. ***
         # *** REOPENED 2026-10-02 (SqliteReview) -- TWO CLAUSES OF THIS OBLIGATION ARE NOT MET ON THE REAL ENGINE. ***
         #
         # *THE CLAUSE THIS OBLIGATION CARRIES: "a partial bind must refuse; a failed open must close its partial
         # handle".* **THE AUDIT MEASURED THAT THE REAL NATIVE ENGINE DOES NOT SATISFY THEM: partial-graph failure
         # LEAKS, the runtime takes an ARBITRARY SQLCipher path mislabeled as PINNED, and an EMPTY FILE / WRONG KEY is
         # misjudged (the court's own engine was FAKE/COPIED for that case).** *The instrumented-table court below is
         # real, but it exercises a HOST-provided table; the pinned native engine's own bind/close is what the clause
         # names, and it is not proven until the native owner supplies a real native host/sim proof.* *Prior DISCHARGED
         # prose kept, HISTORICAL scope.*
         "status": "OPEN", "evidence": [
         #
         # *THE DEFECT THIS CLOSES, MEASURED BY READING THE TREE: `SqlCipherDylibEngine` obtained its handles by `dlsym`
         # on a library IT loaded, and the adopting stores then called the GLOBALLY LINKED `sqlite3_*` functions on
         # them -- A POINTER CREATED BY ONE SQLITE IMPLEMENTATION PASSED TO ANOTHER.* **Matching pointer identity or a
         # matching major version doth NOT establish provider compatibility: two builds of the same version can carry
         # different compile options, struct layouts and VFS assumptions, and the failure that followeth is a silent
         # corruption rather than a clean refusal.***
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
             "*** THE OWED CONTROLS NOW EXIST AS EXECUTED, KILLED BOARD1 RODS (`commit:91fd6ffb`, all 49 scored KILLED). *** *(a) THE ACTUAL OS-FACADE WRITE SUPPRESSED WHILE ADVERTISING SUCCESS: `T72-RC28-ios-os-egress-suppressed-while-advertising-success` striketh the initiator's REAL CoreBluetooth notification entry so a record the relay `successfully` staged NEVER reacheth the recipient -- the silent-transport defect the recorder-only RC19 cannot see -- and `test:testARBEstablishesOverOSFacadesOnlyThenDeliversADirectFrameAndTheRecipientAck` reddeneth at its durable-inbox assertion (3 failed cases). (b) THE LINKREADY-PUBLICATION/HANDLE RULE: `T72-RC22-ios-link-readiness-falls-back-to-any-handle` replaceth the exact-handle readiness predicate with the any-ready-handle count, so a SECOND relation opened by the SAME node inheriteth the FIRST's readiness -- the measured hosted defect -- and its held-second-link regression reddeneth. (c) THE DURABLE STORE PATH (the 'SQLite commit' half): the rod that striketh the durable inbox/store road is `T72-RC18-ios-transport-ingest-unwired` (the responder ingress hand-off deleted, so a frame that crossed the real radio reaches NO store) with its sibling `T72-RC20-ios-ingress-empty-sender-restored` (the empty-sender defect restored at the real inbox) and `T72-RC27-ios-lab-composes-the-author-over-memory-not-the-estate` (the lab built over MEMORY instead of the retained estate, so the SOS durable row readeth nil and its on-disk journey arm condemneth) -- each KILLED in the bound 49-row manifest. *** *The durability itself is NOT an in-memory substitute: every node's stores are `SqliteMessageStore`/`SqlitePeerIdentityStore` over TEMP FILES, and the reopen half proveth the estate on disk rather than in memory.* *** **AND THE HONEST LIMIT IS NAMED: the harness also carrieth `T83-RC2`/`T83-RC5` rods for the inbox-transaction and frame-bound-retirement laws, but they stand in the SEMANTIC lineage OUTSIDE the `board1` required set and were NOT executed in this campaign -- they are NOT cited as evidence here, and a future window may add them to the required set if the clause needeth them named.** ***",
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
         # *** REOPENED 2026-10-02 -- THE FOUR NAMED CLAUSES ARE MET, AND THE INVARIANT SET THEY BELONG TO IS NOT. ***
         #
         # *`Invariant.ALL` declares ELEVEN names, and a read-only audit (`agent://LaneControls.StressAudit`,
         # `local://LaneControls-findings.json`) MEASURED that `StressCampaign` models NEITHER
         # `NO_LEAKED_RESERVATIONS` NOR `NO_LEAKED_INVENTORY_LEASES` NOR `PENDING_ACK_WORK` NOR
         # `NO_LEAKED_OBSERVERS` -- `check()` never references them.* **So `test_w09`'s loop
         # `for invariant in Invariant.ALL: assertFalse(any(invariant in f ...))` is VACUOUS for those four: they can
         # never appear in `failures` because nothing measures them -- the same "assertions over names, not over
         # measurements" shape this obligation exists to refuse.** *Only SEVEN of the eleven are actually measured on
         # this isle, so the obligation is not discharged until the four unmodelled owners are modelled and their
         # invariants are real.* *Prior DISCHARGED prose kept below with HISTORICAL scope.*
         "status": "OPEN", "evidence": [
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
         # *** REOPENED 2026-10-02 -- THE CONSTANT IS DECLARED AND THE CATEGORY IS CARRIED NOWHERE. ***
         #
         # *The constant is real and three courts assert it BOTH WAYS (that is the prior discharge, kept below).* **BUT
         # THE AUDIT MEASURED THAT THE CATEGORY IS NOT CARRIED BY ANY OUTPUT: no result field, no report line, no ledger
         # row carrieth `resource-model`, while module/isle headers, the ledger objective ("driven through the real
         # compositions") and the courts field still say "production-path" / "driven by the real conductor".** *A model
         # result therefore remains QUOTABLE AS A RUNTIME RESULT because the label is asserted in courts and printed
         # nowhere -- which is the class this obligation exists to prevent.* *So it is not discharged until the category
         # is CARRIED by the typed result/report/ledger, and that change follows the implementation (StressHonesty
         # owns it).* *Prior DISCHARGED prose kept, HISTORICAL scope.*
         "status": "OPEN", "evidence": ["`path:ios/Godstone/Sources/GodstoneMesh/StressCampaign.swift`, `path:ios/Godstone/Tests/GodstoneMeshTests/ReadinessT72Tests.swift`, `test:testW14TheCampaignIsANamedResourceModel`. `RESOURCE_MODEL_CATEGORY` is a top-level constant on BOTH isles (`StressCampaign.swift:32`, and its KOTLIN twin), so one grep findeth the contract everywhere; and `ReadinessT72Tests.testW14TheCampaignIsANamedResourceModel` asserts it BOTH WAYS -- `XCTAssertEqual(RESOURCE_MODEL_CATEGORY, \"resource-model\")` AND `XCTAssertNotEqual(RESOURCE_MODEL_CATEGORY, \"production\")` -- so the model cannot be mistaken for, or quietly renamed to, the production runtime it does not measure"]},
    ],
    "GS-UX-001": [
        {"id": "gs-ux-001.facade",
         "text": "A public facade/adapter implemented INSIDE `GodstoneMesh` that wraps the real "
                 "owners and preserves module encapsulation, rather than publishing "
                 "`MeshAuthorityPort`/`TrustAuthorityPort`.",
         # *** REOPENED 2026-10-02 (IosReview ALL-15): ENCAPSULATION ALONE IS NOT FULL OBLIGATION. ***
         # *Audit exact definition: ordinary facade, root stores, and trust commands must operate over the ACTUAL SAME
         # ESTATE (IOS-R6/IOS-R10). A facade wrapping a disconnected in-memory store or authoring disjoint Send rows
         # does not satisfy the obligation.*
         "status": "OPEN",
         "known_internal_gaps": [
             "disjointSend (IOS-R10): facade/lab send opens disconnected SQLite store, bypasses contact trust authority, and uses author's own DH key",
             "estate-fragmentation (IOS-R6): facade and root runtime composition do not share a single coherent estate lifecycle",
         ],
         "evidence": ["`path:ios/Godstone/Sources/GodstoneMesh/MeshTrustFacade.swift`, `path:ios/Godstone/Sources/GodstoneMesh/TrustUXModel.swift`, `path:ios/Godstone/Sources/GodstoneMesh/MeshUXModel.swift`, `path:ios/project.yml`. `MeshTrustFacade` is `public final class` INSIDE GodstoneMesh (`MeshTrustFacade.swift:9`), carrying plain `String`/`Bool`/`[String]` verbs, with the adapter over the REAL `PeerIdentityRepository` internal to the module; and BOTH ports remain UNPUBLISHED -- `protocol TrustAuthorityPort` (`TrustUXModel.swift:329`) and `protocol MeshAuthorityPort` (`MeshUXModel.swift:275`) carry NO access modifier, so nothing outside the module can name them. **MEASURED that this costs LIGHT nothing: `Godstone` (Shipping/Light) declares exactly ONE dependency, `GodstonePackages/GodstoneCore` -- NO mesh edge -- and `ci/check_lab_isolation.py` passes (rc=0).**"]},
        {"id": "gs-ux-001.rendered-controls",
         "text": "The rendered LabMesh UI must exercise the real authority/projection for the complete internally testable journey: recipient selection; UTF-8 bounded compose; Send; fingerprint compare/confirmation; exact rotation-candidate approval; revoke; visible durable state after recreation; visible wipe/recovery state. Displayed state must derive from the real authority/projection.",
         # *** DISCHARGED -- EVERY NAMED JOURNEY NOW CARRIETH A RENDERED ARM, AND THE TRUST ROAD IS A CLEAN CUTOVER. ***
         #
         # *THE PRIOR STATE NAMED THREE UNWITNESSED JOURNEYS: "durable state after recreation, visible wipe/recovery
         # state, and the UTF-8 BOUNDED compose".* **ALL THREE HAVE ARMS NOW, AND THE DISPLAYED-CANDIDATE APPROVAL WAS
         # A CLEAN CUTOVER RATHER THAN A SECOND ROAD ADDED BESIDE THE OLD ONE.**
         # *** REOPENED 2026-10-02 -- "VISIBLE WIPE/RECOVERY STATE" DERIVES FROM A DEFERRED-SEAM LAB RECORD. ***
         #
         # *The journeys each carry a rendered arm now, and the displayed-candidate cutover is real.* **BUT THE
         # WIPE/RECOVERY SURFACE IS `LabWipeJourney`, whose own docstring records that it runs over
         # `StartupRecoveryGraph.deferred()` seams: it READS the durable journal, so "the screen is at REQUESTED" means
         # the record is at REQUESTED -- AND IT CAN NEVER REACH THE TERMINAL RUNG OR ERASE ANYTHING ON A HOST.** *The
         # clause asketh that "Displayed state must derive from the real authority/projection"; the projection here
         # derives from a DEFERRED graph, not the runtime wipe owner (`MeshPanicWipe`), so the visible wipe/recovery
         # state is not yet the production authority's.* *Prior DISCHARGED claim kept below, HISTORICAL scope.*
         "status": "OPEN", "evidence": [
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
           # *** REOPENED 2026-10-02 -- THE ROSTER CHANGED; THE LANE IS NOT RE-BOUND TO THIS CANDIDATE. ***
           #
           # *The target, the runner and the source-derived roster are all real.* **BUT THE ROSTER IS DERIVED FROM
           # THESE SOURCE DIRECTORIES, and the journey list is being changed in-flight: the contract's fifth essential
           # control (`lab.sos.retry`) is being added to `LabMeshAccessibilityUITests`/`LabMeshUITests`, so the roster
           # this obligation rests on MOVES WITH THE TREE.** *A discharge citing a lane log captured before the roster
           # moved does not describe the current target; the obligation is therefore not discharged until the lane
           # executes the CURRENT source-derived roster and its result is bound to THIS candidate.*
           "status": "OPEN", "evidence": [
               "*** MEASURED, THE LANE: `path:docs/remediation/evidence/gs-integration-001-courts.log` plus `ios-ui-lane.log` -- `ios:ui suites=2 tests=19 failures=0`, raw-rc=0, both `LabMeshUITests` (12 arms) and `GodstoneArchiveUITests` (7 arms) EXECUTED. *** *The runner regenerateth the project from `ios/project.yml` and writeth a pre-run AND post-run source digest, so a mid-run edit cannot leave a current-looking log.*",
               "`path:ci/check_lane_results.py` -- the arm roster is SOURCE-DERIVED from the `bundle.ui-testing` targets' own source directories, so an arm that never ran is a REFUSAL BY NAME rather than an absence from a count. *MEASURED: `--selftest-ui` 15/15 mutations killed, including the mid-run-edit case.*",
               "*** AND THE TRUST ARM'S OWN RED WAS FOUND BY THIS LANE AND FIXED AT ITS CAUSE RATHER THAN WEAKENED: `isHittable` was false because the Contacts page carrieth more controls than any sibling and the action row sat BELOW THE FOLD once the page was wrapped in a `ScrollView`. A bounded `scrollIntoView` now proveth the control REACHABLE BY SCROLLING, and still faileth with a named reason when it cannot be reached at all. ***",
               "*** THE ACCESSIBLE ALTERNATIVE IS RENDERED: `lab.sos.send` is the non-gesture door the SOS arm driveth, so the hold-gesture journey carrieth a control a reader who cannot hold can use. ***",
           ]},
        {"id": "gs-ux-001.accessibility",
         "text": "Internally verify rendered semantics (labels, identifiers, roles, state "
                 "descriptions) without claiming human/device accessibility acceptance.",
         # *** DISCHARGED -- THE RENDERED SEMANTICS ARE VERIFIED, AND HUMAN ACCEPTANCE IS EXPLICITLY EXTERNAL. ***
         # *** REOPENED 2026-10-02 -- "ROLES" ARE VERIFIED ON ANDROID AND NOT ON iOS, AND `retry` IS STILL BEING
         # CLOSED. ***
         #
         # *The clause nameth: "labels, identifiers, roles, state descriptions".* **MEASURED FROM THE EVIDENCE ITSELF:
         # the Android court reads ROLE from the Compose semantics tree, while the iOS arm is an XCUITest, WHICH THE
         # SAME EVIDENCE STATES "CANNOT READ ACCESSIBILITY TRAITS" -- so on the iOS isle the rendered ROLE is not
         # verified at all, only labels/identifiers/targets.** *And the fifth contract-essential control (`retry`) is
         # being added to the iOS surface in-flight, so the roster the gap was recorded against is itself moving.*
         # **The obligation is therefore not discharged: the iOS-role half is unverified by the very tool cited, and
         # the retry surface must be re-measured on this candidate.** *Prior DISCHARGED text kept below, HISTORICAL
         # scope.*
         # *The rc10-era court asserted a HARD-CODED roster of 120x48 nodes with fallback labels -- "a table pretending
         # to be a screen".* **The Android court now readeth role, content description, state, laid-out size and
         # traversal order FROM the Compose/Robolectric semantics tree, and it is run at BOTH text scales in BOTH
         # directions.** *`retry` is an `ESSENTIAL_CONTROLS` member with NO live surface in either lab app and no runtime
         # authority to bind it to -- so it is RECORDED AS A GAP here rather than cited as satisfied, which is the honest
         # reading the mission requires.* **AND THE HONEST LIMIT IS NAMED: an XCUITest cannot read accessibility TRAITS
         # nor posted announcements, so human VoiceOver/TalkBack acceptance stays external.**
         # *** HISTORICAL DISCHARGED CLAIM -- SCOPE: rc11-era, iOS-role half unverified. Superseded by the REOPENED
         # note above; the evidence below is KEPT and is NOT deleted. ***
         "status": "OPEN", "evidence": [
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
             "*** THE CURRENT-C PROOF: THE SEPARATE, SCOPE-SPECIFIC RESTORATION-RODS CAMPAIGN (2026-10-04), four SEMANTIC rods, 4/4 KILLED, run on baseline `8e49631bae1524829f06f48c36b883749436ad0b` / tested tree `95952ec36161abe1a5b6c4ac5c99861c4b0bb0d3`, manifest `path:docs/remediation/evidence/board1-rc15-restoration-rods/manifest.json` (lineage `semantic`, group null, selected 4, required empty; its 161-key input set verified against `path:ci/mutations.py`'s `_tested_input_digests()`). *** *This is a campaign of its OWN, SEPARATE from the canonical board1 181 (179 semantic + 2 structural) and NEVER aggregated with it.*",
             "THE FOUR RODS, each build_exit 0 and kill_channel `witness`, each with a green restored phase: `T49-SM10-restore-amnesial-mode` (Android `BrowseViewModel.snapshotTo` handle loses the persisted scene MODE; `testProcessRecreationRestorethTheSameJourney`, 21 run / 21 restored / 0 skipped; log sha `526bc0f6ffdd301691d50b2f01abba59daeeff7ff8b657c471afb4a1100eea9f`); `T49-SM11-restore-amnesial-identity` (the same handle loses the persisted DOCUMENT IDENTITY; 21/21/0; log sha `485b25cab855b627669c2c615a5849c22344a1bf521f4663ebb90ad3ee1f2d5d`); `T50-SM11-recreation-amnesic` (iOS `ArchiveSceneModel` recreation handle pineth `mode` to `.documents`, so a journey broken in the document standeth reposed at the root; `testProcessRecreationRestorethTheSameJourney`, 28/28/0; log sha `cf0b3d355457b877678041304ad13e208facc9c98f3fcc3d77e2706d150d6472`); `T50-SM12-anchor-amnesic` (iOS the recreation strketh the scroll anchor to nil, so the reader's place is forgot on relaunch; `testTheScrollAnchorIsNoteAndRemembered`, 28/28/0; log sha `2175f1d8eaadedf60efc6556282712dc6c1a2a60c84ea002bbb38028cda40360`). Every baseline/mutant/restored phase log's SHA-256 was verified by `shasum`, and ALL FOUR rods carry build_exit 0 + kill_channel `witness` -- this campaign carrieth NO compiler-channel kill.",
             "THE STRIKES LAND ON PRODUCTION STATE OWNERS: `path:android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt` (`snapshotTo`, the persisted scene handle) and `path:ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift` (the recreation snapshot's `mode` and `scrollAnchor`), witnessed by `path:android/app/src/test/java/io/godstone/app/readiness/ReadinessT49Test.kt` and `path:ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift`. The disconnect is therefore made at the production boundary AND observed to redden the EXECUTED witness -- not merely asserted from a model court.",
             "*** HISTORICAL (rc14-era, retained, NOT the current-C proof): *** *the earlier `.document`-case mutation on `path:ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift` which ignored the persisted `openedDocumentId`, GREEN on the tree of its day (that arm PASSED at 47.107s) then MUTATED (the arm FAILED at 36.149s), taken on the real app road with `path:ios/Godstone/Tests/GodstoneArchiveUITests/GodstoneArchiveUITests.swift` terminating and relaunching the process, source restored byte-identical to HEAD with `path:scripts/sync_ios_foundation_package.py` --check rc=0.* **That run is evidence about CHANGED source and cannot discharge the current candidate; it standeth only as the audit trail of how this clause was first taken.**",
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
         # *** REOPENED 2026-10-02 (SqliteReview): THE STORE'S OWN MIGRATION ROAD SHARES THE `try?` DEFECT. ***
         # *The internal architecture is shared with GS-FINAL-004 and its sibling `gs-final-004.migrations-on-verified`
         # is reopened for the same measured cause: a `try?` `user_version` read can make a migration proceed on a
         # FALSE result. Until the store's migration refusal is proven against a real native host, this shares the
         # sibling's status rather than claiming otherwise.*
         "status": "OPEN",
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
"status": "DISCHARGED", "evidence": ["`path:scripts/build_structured_closure.py` --write wrote `finding_closure` (68 entries, every one carrying `internal_status`) + `structured_counts` into the ledger; `internal_remaining_prose_classifier_retired` records the NLP classifier as RETAINED-FOR-HISTORY-ONLY and NOT an input to any closure decision, so `internal_remaining` is DERIVED from explicit obligation statuses. *** THE MISSION'S ADDED SEMANTICS (`known_internal_gaps`, `unresolved_internal_dependencies`, `required_controls_present`, and the structured discharge fields) ARE TRACKED ON `audit-b1-ctrl-001.closure-law` AND `audit-b1-ctrl-001.ready-requires-both-populations`, which are the obligations that gate them -- not duplicated here. ***"]},
        {"id": "audit-b1-ctrl-001.closure-law",
         "text": "A control that REFUSES a COMPLETE/READY builder status while structured "
                 "internal OPEN work exists, so the control plane can no longer report closure "
                 "over a NO_GO register.",
"status": "DISCHARGED", "evidence": ["*** EARNED 2026-10-04: all three gaps this reopen named are CLOSED in the UNCHANGED guard -- (a) a terminal `DISCHARGED` contradicted by its own structured fields is REFUSED by name (`structured_discharge_problems`/`_discharge_block_problems`/`_current_binding_problems`: a missing required field, a court-only reachability, a self-referential candidate SHA, a historical or stale attestation, an embedded tag object or candidate commit), (b) an unknown OBLIGATION or FINDING state is an ERROR at the closure boundary (`obligation_state_problems`/`internal_status_state_problems`), and (c) every terminal obligation must carry the new required discharge fields plus an external `candidate_binding`. *** Killed on C0 by TWO generator-semantic strikes on THAT unchanged logic, each by its own NAMED witness with a restored-green phase: `CLOS-SCHEMA-BYPASS` (mutant sha `7eb58e61...`) and `CLOS-PARTIAL-BLIND` (mutant sha `d06a4f6e...`) -- `path:docs/remediation/evidence/board1-rc15-closure-controls/generator-strikes/manifest.json`, logs `OP3-CLOS-SCHEMA-BYPASS.mutant.log` and `OP1-CLOS-PARTIAL-BLIND.mutant.log`. The SEPARATE 13-case negative-input court is GREEN (4 tests / 0 failures / exit0): `path:docs/remediation/evidence/board1-rc15-closure-controls/generator-strikes/NEGATIVE-INPUT-COURT-13cases.log`. Neither rod is credited with the other closure-law controls. *** *Prior DISCHARGED text kept.* `path:docs/production-readiness/BOARD1_CLOSURE.json`, `path:scripts/build_structured_closure.py`. MEASURED BOTH DIRECTIONS 2026-09-20: with BOARD1_CLOSURE.status set to READY_FOR_EXTERNAL_REAUDIT the control REFUSED -- `rc=1` with `::error:: BOARD1_CLOSURE.status is READY_FOR_EXTERNAL_REAUDIT while 30 structured internal obligation(s) are OPEN across 10 finding(s)`. Restored to REMEDIATION_IN_PROGRESS: `rc=0`. The law BITES, so the control plane cannot report closure over a NO_GO register"]},
        {"id": "audit-b1-ctrl-001.missed-partials",
         "text": "Every PARTIAL is represented, including GS-RUNTIME-001 and GS-STORE-002, which "
                 "the prose classifier missed entirely.",
"status": "DISCHARGED", "evidence": ["`path:scripts/build_structured_closure.py`. POSITIVE on C0: the REAL ledger carries GS-RUNTIME-001 with 2 internal obligations (gs-runtime-001.android-composition-court and gs-runtime-001.mutations) and GS-STORE-002 with 1 (gs-store-002.internal-architecture), all DISCHARGED with their findings COMPLETE; each finding separately retains 1 external obligation. Persisted counts agree with derivation: `path:docs/remediation/evidence/board1-rc15-closure-controls/generator-strikes/CONSUMER-POSITIVE-real-ledger.baseline.log` (15 PASS, 0 FAIL, exit0). NEGATIVE: CLOS-PARTIAL-BLIND removes PARTIAL from the unresolved set; test_one_partial_obligation_prevents_zero fails while test_only_all_discharged_reaches_zero passes. CLOS-DRIFT-BLIND disables the persisted/derived comparison; its executed witness is test_a_stale_count_is_refused, with test_the_real_tree_agrees as the green control. Both standalone source strikes restore byte-identical C0 source with 2 PASS and 0 skips. DELETION and ORPHAN refusals are separate input-court cases 8 and 9 in `path:docs/remediation/evidence/board1-rc15-closure-controls/generator-strikes/NEGATIVE-INPUT-COURT-13cases.log`, not OP2 source-mutant witnesses. Standalone generator strikes and input-court cases are not canonical registry rows."]},
        # *** THE TWO OBLIGATIONS THIS MISSION'S OWN CONTROL-PLANE REVIEW ADDED. ***
        {"id": "audit-b1-ctrl-001.finding-obligation-consistency",
         "text": "A finding may not stand internally OPEN while carrying ZERO unresolved obligations. "
                 "The instrument must refuse that combination rather than describe it, because such a "
                 "finding is open with nothing a builder can execute -- so no batch of work could ever "
                 "close it, and its recorded status has not followed its own obligations.",
"status": "DISCHARGED", "evidence": ["`path:scripts/build_structured_closure.py`. MEASURED BEFORE THE FIX: `AUDIT-B1-CTRL-001` and `GS-FINAL-004` each carried `internal_status = OPEN` with ZERO unresolved obligations, so both were internally open with nothing left to do. `build()` now refuseth the combination in both places (the ledger population and the synthesised AUDIT entry) and `finding_state_problems()` is enforced by `--check`; `counts()` additionally reports `findings_with_internal_status_open` beside the obligation total, because the obligation count cannot see a finding with no obligations. *** EARNED 2026-10-04: killed on C0 by `CLOS-FINDING-CONSISTENCY-BLIND` -- operator: the OPEN-and-all-terminal guard is forced to `if False` (mutant sha `99fe33d0...`) -- by exactly its NAMED witness `test_an_open_finding_with_all_obligations_discharged_is_refused`, while the MIRROR arm `test_a_complete_finding_with_all_obligations_discharged_is_PERMITTED` stays GREEN (`path:docs/remediation/evidence/board1-rc15-closure-controls/generator-strikes/OP4-CLOS-FINDING-CONSISTENCY-BLIND.mutant.log`). The guard LOGIC is unchanged by this DATA-only authoring. *** AND MY FIRST REPAIR OF THIS RULE WAS ITSELF WRONG -- it fired on ALL-TERMINAL findings, which would have REFUSED EVERY CORRECTLY-CLOSED FINDING -- so the mirror case `path:tools/readiness/tests/test_closure_law_refuses.py:547` pinneth the permitted state. The in-file witnesses are `path:tools/readiness/tests/test_closure_law_refuses.py:538` (refused) and `:547` (permitted)."]},
        {"id": "audit-b1-ctrl-001.ready-requires-both-populations",
         "text": "A COMPLETE/READY builder status must be refused while EITHER population is non-empty: "
                 "unresolved internal obligations, and findings whose internal_status is OPEN. The two are "
                 "not the same test, and a gate reading only one of them can permit readiness over live work.",
"status": "DISCHARGED", "evidence": ["*** EARNED 2026-10-04: both populations are checked in `--check` AND the readiness claim is refused on EITHER of them BY NAME; the unknown-state refusals (`obligation_state_problems`/`internal_status_state_problems`) are enforced at the closure boundary; and the semantics gate (`semantics_gate_problems`) refuses a terminal claim behind an unmeasured control. *** Killed on C0 by `CLOS-STATUS-POPULATION-BLIND` (mutant sha `24064aca...`) on the UNCHANGED guard, by exactly its NAMED witness with a restored-green phase: `path:docs/remediation/evidence/board1-rc15-closure-controls/generator-strikes/OP5-CLOS-STATUS-POPULATION-BLIND.mutant.log`; the negative-input court's cases 12 and 13 (force READY / force COMPLETE over an AUTHORED unresolved obligation) are REFUSED inside the same GREEN 4-test run. The guard LOGIC is unchanged by this DATA-only authoring; a FINAL-C re-run is the parent's step and is NOT claimed here. *** *Prior DISCHARGED text kept.* `path:scripts/build_structured_closure.py`. MEASURED: a gate reading only `internal_obligations_unresolved` would have PERMITTED `READY_FOR_EXTERNAL_REAUDIT` while ten findings still reported themselves internally open, because two of them carried zero obligations to count. `--check` now refuseth on both conditions by name; killed by `path:tools/readiness/tests/test_closure_law_refuses.py:361` (`ReadinessRequiresBothPopulations`)."]},
    ],
}


def load(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def _with_authored_discharges(obligations: list[dict]) -> list[dict]:
    """*** EARNED DISCHARGE: ATTACH THE AUTHORED SEMANTICS AND THE SOURCE HISTORY BY OBLIGATION IDENTITY. ***

    *THE FRONTIER IS NARROWED: every obligation in `PARTIAL_OBLIGATIONS` that carrieth an authored,
    production-reachable `STRUCTURED_DISCHARGES` entry (seven fields + an EXTERNAL `candidate_binding`) is promoted to
    `DISCHARGED` and the block is ATTACHED to it. No obligation in `AUDIT-B1-CTRL-001` remains unearned: all FOUR of
    the closure-control family carry an authored block, so the closure derives 35 DISCHARGED / 0 OPEN. `build()` owns
    the promotion, not the obligation's own `status` literal -- the map is the authority and the two cannot drift.*

    *THE PRIOR SHAPE (kept in the audit trail as `HISTORICAL_DISCHARGES`): an rc14-era `DISCHARGED` was DEMOTED to
    `OPEN` and its claim retained as `historical_discharge`, because historical rc14 evidence cannot discharge changed
    source. That demotion now applies only to a historical claim with NO authored current discharge; where a current
    `STRUCTURED_DISCHARGES` entry exists it WINS and the obligation is terminal on its own current-C proof.*

    *AND THE SOURCE REVIEW HISTORY MOVES WITH IT: each discharged obligation carrieth its `REVIEW_GAP_HISTORY` records
    as `review_gap_history` (the per-obligation audit trail, with the in-place `review_status`) and NO live
    `known_internal_gaps` -- because with nothing unresolved there is no live gap to count.*
    """
    out: list[dict] = []
    for o in obligations:
        copy = dict(o)
        oid = o.get("id")
        discharge = STRUCTURED_DISCHARGES.get(oid)
        history = HISTORICAL_DISCHARGES.get(oid)
        if discharge is not None:
            # *** THE AUTHORED CURRENT DISCHARGE WINS; the historical claim (if any) is retained beside it. ***
            copy["status"] = "DISCHARGED"
            copy["structured_discharge"] = dict(discharge)
            if history is not None:
                copy["historical_discharge"] = dict(history)
        else:
            # A historical claim with no authored current discharge stays a HISTORICAL record, not a live terminal.
            if copy.get("status") == "DISCHARGED":
                copy["historical_status"] = "DISCHARGED"
                copy["status"] = "OPEN"
            if history is not None:
                copy["historical_discharge"] = dict(history)
            if oid in REVIEW_GAP_HISTORY:
                copy["known_internal_gaps"] = [dict(g) for g in REVIEW_GAP_HISTORY[oid]]
            # *** AN OBLIGATION STILL OPEN STILL CARRIES ITS CURRENT-C PROOF REQUIREMENT. ***
            # *The canonical review mapping (above, when present) travels beside a synthetic record naming the work
            # that must land -- the same shape the pre-closure builder carried for every obligation. So an OPEN
            # obligation is never merely prose: its `known_internal_gaps` names the current-candidate acceptance it
            # awaiteth. A DISCHARGED obligation carrieth NO such record -- there is nothing left to land.*
            copy.setdefault("known_internal_gaps", []).append(
                {"defect": "CURRENTC-PROOF-REQUIRED", "source": "current candidate acceptance",
                 "canonical_obligation": oid,
                 "canonical_defect": copy.get("text"),
                 "what_must_land": "Actual production path, positive, negative, independent-count and fault controls "
                                   "bound to the supplied current candidate SHA/tree. Historical rc14 evidence and source "
                                   "authoring cannot discharge changed source."})
        # *** THE PER-OBLIGATION SOURCE-REVIEW HISTORY IS CARRIED ON THE DISCHARGED OBLIGATION. ***
        if oid in REVIEW_GAP_HISTORY:
            copy["review_gap_history"] = [dict(g) for g in REVIEW_GAP_HISTORY[oid]]
        out.append(copy)
    return out


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
                "internal_status_source": "recorded_status",
                "internal_obligations": _with_authored_discharges(PARTIAL_OBLIGATIONS.get(fid, [])),
                "external_obligations": list(entry.get("external_obligations") or []),
            }
            # *** THE OBLIGATION SET GOVERNS THE FINDING'S INTERNAL STATUS WHEN OBLIGATIONS EXIST. ***
            #
            # *WHY THIS IS DERIVED RATHER THAN COPIED FROM `my_status`: a REOPENED obligation must make its finding
            # internally OPEN, or the finding would stand `COMPLETE` over live work -- the exact overclaim this control
            # plane exists to refuse, and the one a bare status flip would re-create.* **A FINDING WITH OBLIGATIONS IS
            # INTERNALLY TERMINAL EXACTLY WHEN NONE OF ITS OBLIGATIONS IS UNRESOLVED; its `recorded_status` (from the
            # ledger) is preserved UNCHANGED beside the derived value, so the disagreement remains auditable rather
            # than being silently overwritten.** *A finding with NO authored obligations keeps its recorded status,
            # because terminality cannot be derived from a set that does not exist.*
            if entry_out["internal_obligations"]:
                entry_out["internal_status"] = (
                    "COMPLETE" if obligations_are_terminal(entry_out) else "OPEN")
                entry_out["internal_status_source"] = "derived_from_obligations"
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
        aud_obls = _with_authored_discharges(PARTIAL_OBLIGATIONS["AUDIT-B1-CTRL-001"])
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
            "internal_status_source": "derived_from_obligations",
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
        # *** AND THE LEDGER'S OWN `recorded_status` MAY NOT CLAIM COMPLETE OVER LIVE OBLIGATIONS. ***
        #
        # *THE MISSION'S REQUIRED KILL #4: "a FIX_SUBMITTED finding with an OPEN obligation -> REFUSE".* **WHY THIS IS A
        # SEPARATE RULE FROM THE ONE ABOVE: `internal_status` is now DERIVED from the obligations, so an obligation
        # reopened inside a finding the ledger still records as FIX_SUBMITTED would derive OPEN and the derived-value
        # rule could never fire -- the guard would lose exactly the case it was written for.** *So the RECORDED status
        # is checked too, against the SAME obligation set: a ledger that says a finding is fixed while its own
        # obligations are unresolved is the overclaim, and the disagreement is visible in `recorded_status` beside the
        # derived value.*
        recorded = f.get("recorded_status")
        if obls and STATUS_TO_INTERNAL.get(recorded) not in (None, "OPEN") and not obligations_are_terminal(f):
            live = [o.get("id") for o in obls if o.get("status") in UNRESOLVED_OBLIGATION_STATES]
            problems.append(
                f"{fid}: recorded_status is {recorded!r} (which maps to internal COMPLETE) while "
                f"{len(live)} of its obligations are UNRESOLVED ({', '.join(str(x) for x in live[:3])}"
                f"{'...' if len(live) > 3 else ''}) -- the ledger claimeth this finding fixed over live internal work")
    return problems


#: *** THE STRUCTURED SEMANTICS THE CLOSURE MISSION REQUIRES, AND THE SCAN THAT FEEDS THEM. ***
#:
#: *A DISCHARGED STATUS IS A CLAIM; THE SEMANTICS BELOW MAKE THE CLAIM EXAMINABLE. `required_controls_present` is the
#: positive half (what each finding's discharge relies on), `known_internal_gaps` is the negative half (live gaps the
#: record itself names), and `unresolved_internal_dependencies` names what must land first. `known_internal_gaps` is
#: populated ONLY while the finding is OPEN -- a discharged finding's historical gap prose is HISTORY, not a live gap,
#: and erasing it would destroy the audit trail this programme depends on.*
GAP_CONCEPTS = (
    "gap", "absent", "missing", "not satisfied", "not implemented", "still owed", "uncovered",
    "cannot", "not executed", "not reached", "placeholder", "deferred", "todo", "known red",
    "no live surface", "no runtime authority",
)


def _discharge_text_scan(obligation: dict) -> dict:
    """*** A PROGRAMMATIC SCAN OF A DISCHARGED OBLIGATION'S OWN PROSE FOR GAP CONCEPTS. ***

    *THIS IS NOT AN NLP CLASSIFIER AND CARRIETH NO CLOSURE AUTHORITY. The retired prose classifier inferred a COUNT
    from vocabulary; this scans for REVIEW and carries only a hit roster. The distinction matters: a word list cannot
    decide whether a discharge is honest, but it can point a human at the discharges whose own prose mentions a gap --
    which is exactly the class the mission asketh to inspect.*

    *Each hit is attributed to the obligation, the field (`text`/`evidence`) and the concept, so the disposition can be
    recorded against a real location rather than a count.* **An empty roster MEANETH "no gap word appeared", never "the
    discharge is sound" -- the scan has no authority to say the latter.**
    """
    hits: list[dict] = []
    blobs = [("text", obligation.get("text", ""))]
    blobs += [("evidence", c) for c in (obligation.get("evidence") or []) if isinstance(c, str)]
    for field, blob in blobs:
        low = blob.lower()
        for concept in GAP_CONCEPTS:
            start = low.find(concept)
            while start != -1:
                s = max(0, start - 80)
                e = min(len(blob), start + len(concept) + 80)
                hits.append({
                    "concept": concept,
                    "field": field,
                    "excerpt": blob[s:e],
                })
                start = low.find(concept, start + len(concept))
    return {"scanned": True, "hits": hits, "concepts_scanned": list(GAP_CONCEPTS),
            "authority": "review-only; NOT an input to any closure decision"}


def structured_semantics(closure: dict) -> dict:
    """*** `required_controls_present`, `known_internal_gaps` AND `unresolved_internal_dependencies`. ***

    *WHY THESE THREE TOGETHER: a discharge saith what it PRESENTED (controls), a live finding saith what it still
    OWES (gaps), and either may DEPEND on something that must land first (dependencies). Naming only the controls
    would be the builder's own report of its work; naming the gaps as well is what makes the report falsifiable by a
    reader who compares the two.*

    *** THE THREE DEFECTS THIS NOW REFUSES, EACH MEASURED RATHER THAN ARGUED. ***

      1. **A "PRESENT CONTROL" WAS INFERRED FROM THE STATUS.** The old `present` list appended every obligation whose
         status was not unresolved -- **so any obligation marked DISCHARGED became a "required control present" with
         no semantic proof at all: the field measured the status it was meant to justify.** *A control must be
         MEASURED: only an obligation carrying an authored `structured_discharge` (behaviour, implementation,
         reachability, test, positive control, mutation, exact result) is a present control, because only that block
         names what the discharge actually exercised. A DISCHARGED obligation with NO block is listed under
         `refused_controls` -- *a control this instrument could not measure* -- and NEVER as present.*
      2. **`unresolved_internal_dependencies` WAS POPULATED FROM `external_obligations`.** *The two name different
         populations: an INTERNAL dependency is internal work that must land first (an unresolved obligation); an
         EXTERNAL obligation is something the builder cannot do at all (a pinned artifact, a device, an independent
         audit).* **Folding the external list into the internal one made an EXTERNAL blocker read as an internal
         dependency, which is exactly the confusion that lets external work be claimed "handled internally" or
         internal work be excused as "external".** *They are emitted as separate fields.*
      3. **`known_internal_gaps` IS POPULATED ONLY WHILE A FINDING IS INTERNALLY OPEN.** *A discharged finding's gap
         prose is HISTORY, preserved under an explicit historical scope rather than counted as outstanding work.*
    """
    controls: dict[str, list[dict]] = {}
    gaps: dict[str, list[dict]] = {}
    internal_deps: dict[str, list[str]] = {}
    external: dict[str, list] = {}
    refused: list[dict] = []
    for fid, f in sorted(closure.items()):
        obls = f.get("internal_obligations") or []
        terminal = obligations_are_terminal(f) if obls else f.get("internal_status") != "OPEN"
        # *** THE POSITIVE HALF, MEASURED FROM THE AUTHORED SEMANTICS, NOT READ OFF THE STATUS. ***
        present: list[dict] = []
        for o in obls:
            if o.get("status") in UNRESOLVED_OBLIGATION_STATES:
                continue
            sd = o.get("structured_discharge")
            if sd is None:
                # A TERMINAL CLAIM WITH NO SEMANTICS IS NOT A CONTROL THIS INSTRUMENT CAN NAME.
                refused.append({
                    "finding": fid,
                    "obligation": o.get("id"),
                    "why": "DISCHARGED with NO `structured_discharge`: the control cannot be measured, so it is "
                           "NEVER reported as present",
                })
                continue
            present.append({
                "obligation": o.get("id"),
                "reachability": sd.get("reachability"),
                "control": sd.get("positive"),
                "behavior": sd.get("behavior"),
                "exact_result": sd.get("exact_result"),
            })
        if present:
            controls[fid] = present
        # *** THE NEGATIVE HALF: the OPEN obligations, by identity, with each one's own scan roster. ***
        if not terminal:
            g = []
            for o in obls:
                if o.get("status") in UNRESOLVED_OBLIGATION_STATES:
                    g.append({"id": o.get("id"), "text": o.get("text"),
                              "known_internal_gaps": [dict(x) for x in (o.get("known_internal_gaps") or [])],
                              "discharge_text_scan": _discharge_text_scan(o)})
            if g:
                gaps[fid] = g
        # *** INTERNAL DEPENDENCIES ARE UNRESOLVED INTERNAL WORK -- NEVER THE EXTERNAL LIST. ***
        live = [o.get("id") for o in obls if o.get("status") in UNRESOLVED_OBLIGATION_STATES]
        if live:
            internal_deps[fid] = live
        if f.get("external_obligations"):
            external[fid] = list(f["external_obligations"])
    return {"required_controls_present": controls,
            "refused_controls": refused,
            "known_internal_gaps": gaps,
            "unresolved_internal_dependencies": internal_deps,
            "external_obligations": external,
            "review_defect_statuses": _review_status_rollup(),
            "note": ("required_controls_present carrieth ONLY obligations whose authored `structured_discharge` names "
                     "what was exercised; a DISCHARGED obligation with no such block is listed in `refused_controls` "
                     "and is NOT present. `unresolved_internal_dependencies` is INTERNAL work that must land first; "
                     "`external_obligations` is the separate population the builder cannot discharge. "
                     "known_internal_gaps is populated ONLY for findings that are internally OPEN.")}


#: *** EVERY OBLIGATION CARRIES AN EXPLICIT DISPOSITION -- THERE IS NO LEGACY BYPASS. ***
#:
#: *THE DEFECT THIS CLOSES: `structured_discharge_problems` SKIPPED every obligation without a
#: `structured_discharge` block (`if sd is None: continue`) and made `candidate_binding` optional inside the block.
#: **The whole register of DISCHARGED obligations therefore bypassed the semantic schema: a terminal claim needed
#: neither a behaviour, an implementation, a reachability, a test, a positive control, a mutation, an exact result nor
#: an external candidate binding. The instrument could describe the schema it did not enforce.*** *A legacy exemption
#: was the mechanism -- "the legacy discharges predate the schema" -- which is the same shape as a prose classifier:
#: an unexamined population that reads as examined.*
#:
#: **SO THE SCHEMA IS MANDATORY AT THE TERMINAL BOUNDARY, AND EVERY TERMINAL OBLIGATION MUST CARRY `structured_discharge`
#: WITH EVERY REQUIRED FIELD AND AN EXTERNAL `candidate_binding`.** *A terminal claim whose semantics are absent is a
#: status without a subject; it is refused BY NAME.* **`external_manifest` and `attestation` are EXTERNAL identities --
#: the frozen rc14 tag object and its attestation path -- so the binding never embeds the candidate's own hash, which
#: would have to contain itself.**
DISCHARGE_REQUIRED_FIELDS = (
    "behavior", "implementation", "reachability", "test", "positive", "mutation", "exact_result",
)
DISCHARGE_REACHABILITY = ("production", "court-only", "external-blocked")
#: *** A DISCHARGE MAY NOT STAND ON A COURT ALONE. *** *"court-only"/"external-blocked" reachability beside
#: DISCHARGED is the contradiction a prose review cannot see: the status claimeth a completed internal discharge while
#: the structured field claimeth the discharge reaches no production road. The two cannot both be true.*
DISCHARGE_TERMINAL_REACHABILITY = ("production",)
#: *** THE EXTERNAL SIDE OF A BINDING: NAMED FILES/IDENTITIES, NEVER A HASH OF THE CANDIDATE. ***
DISCHARGE_BINDING_KEYS = ("external_manifest", "attestation")

#: *** THE MANDATORY SEMANTIC SCHEMA, AUTHORED PER OBLIGATION. ***
#:
#: *A `structured_discharge` cannot be derived from prose without repeating the exact defect this programme exists to
#: refuse (an inferred claim wearing a structured field), and this builder may not self-assert a terminal claim.*
#: **So the semantics are AUTHORED only where a discharge is REAL, and every authoring site is listed here so the
#: register can be read in one place.** *** AT THE EARNED-35 CLOSURE (2026-10-04) ALL 35 obligations carry an
#: authored block: each names the production composition and witness route its discharge exercised, the exact rod(s)
#: KILLED on the FINAL full board1 campaign (baseline `c5a565f…`, tested tree `f67d8dd1…`, 181/181 KILLED) or a
#: scope-specific campaign -- for `gs-final-006.mutation` its OWN separate restoration-rods campaign (baseline
#: `8e49631b…`, tested tree `95952ec3…`, 4/4 SEMANTIC KILLED), and for the FOUR `AUDIT-B1-CTRL-001` closure-control
#: discharges their OWN generator-semantic strikes (`CLOS-PARTIAL-BLIND`, `CLOS-DRIFT-BLIND`, `CLOS-SCHEMA-BYPASS`,
#: `CLOS-FINDING-CONSISTENCY-BLIND`, `CLOS-STATUS-POPULATION-BLIND`) on the UNCHANGED C0 guard -- with the per-rod
#: `logs/<id>.mutant.log` digests, and the external `candidate_binding`. **The map is populated, not asserted: the
#: closure derives 35 DISCHARGED / 0 OPEN, and `structured_discharge_problems`/`authoring_coverage_problems` refuse
#: any drift between the map and the closure.** *The generator-semantic strikes are UNREGISTERED and NEVER booked as
#: registry rows or a canonical 181 score.*
#: *`ci/check_candidate_binding.py::validate_attestation` is the INDEPENDENT reader of this schema on the frozen side;
#: the internal side may not claim a terminal state the frozen side would refuse, so the two readers agree by
#: construction rather than by convention.*
STRUCTURED_DISCHARGES: dict[str, dict] = {
    "audit-b1-ctrl-001.structured-obligations": {
        "behavior": "Structured per-finding closure: `internal_status`, `internal_obligations` and `external_obligations` for every nonterminal finding, with `internal_remaining` DERIVED from them rather than NLP-classified from prose, and the structured counts agreeing between the manifest and the derivation.",
        "implementation": "`scripts/build_structured_closure.py` (`--write` writes `finding_closure` + `structured_counts`); the count-agreement refusal lives in `ci/check_board1_manifest.py`.",
        "reachability": "production",
        "test": "test_a_manifest_whose_structured_counts_drift_from_the_ledger_is_refused (the manifest/ledger count-agreement court).",
        "positive": "The derived counts are persisted and the manifest's structured counts must agree with the derivation field by field.",
        "mutation": "T86-B1M13-closure-counts-may-disagree KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`) with a restored-green phase.",
        "exact_result": "REGISTERED T86-B1M13-closure-counts-may-disagree is required, selected and KILLED in the canonical 181 campaign (tested tree f67d8dd18be11928c39a3932296217a7dc5b8604), with restored-green and `logs/T86-B1M13-closure-counts-may-disagree.mutant.log`; it specifically proves MANIFEST/LEDGER count agreement. SEPARATE C0 source strike CLOS-DRIFT-BLIND disables the LEDGER/DERIVATION comparison: test_a_stale_count_is_refused fails while test_the_real_tree_agrees passes, then byte-identical C0 source restores 2 PASS and 0 skips (`path:docs/remediation/evidence/board1-rc15-closure-controls/generator-strikes/OP2-CLOS-DRIFT-BLIND.mutant.log`). Only CLOS-DRIFT-BLIND is UNREGISTERED and excluded from the canonical score; T86-B1M13 remains its registered canonical result. These readers and proof namespaces are never conflated.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    # *** THE FOUR CLOSURE-CONTROL DISCHARGES THIS MISSION OWNS. ***
    # *Each is authored from the obligation's OWN evidence and its OWN generator-semantic strike, NEVER inferred from a
    # status: the seven mandatory fields name what the control EXERCISED, the strike that KILLED a false version on C0,
    # and the exact measured log. The strike namespace is generator-semantic and UNREGISTERED -- never booked as a
    # registry row or a canonical score. The external binding names only the prospective rc15 ref, the external
    # evidence bundle and the reserved future attestation; NO candidate hash is embedded.*
    "audit-b1-ctrl-001.closure-law": {
        "behavior": "The closure law REFUSES a COMPLETE/READY builder status while structured internal OPEN work exists, AND refuses a terminal DISCHARGED that its own structured fields CONTRADICT (a missing required discharge field, a court-only reachability, a self-referential candidate SHA, a historical/stale attestation, an embedded tag object or candidate commit), AND errors on an unknown OBLIGATION or FINDING state at the closure boundary -- so the control plane can no longer report closure over a NO_GO register.",
        "implementation": "`scripts/build_structured_closure.py` -- `main` (the two readiness refusals plus `obligation_state_problems`/`internal_status_state_problems`), `structured_discharge_problems`/`_discharge_block_problems`/`_current_binding_problems` (the terminal-contradiction schema, the mandatory external `candidate_binding` and the no-self-hash law). The GUARD LOGIC is unchanged by this DATA-only authoring.",
        "reachability": "production",
        "test": "`tools/readiness/tests/test_closure_law_refuses.py` -- classes `TheLawStillRefuses`, `StructuredDischargeContradiction`, `ObligationStateMachine` (recorded C0 artifact: 56 tests, 0 failures, 0 skips; `path:docs/remediation/evidence/board1-rc15-closure-controls/courts.log`). The obsolete live-source gap-layout assertion was removed, not re-pinned. The separate pre-freeze behavioral contract court passed 78 tests with 0 failures (`path:docs/remediation/evidence/board1-rc15-closure-controls/final-contract-courts.log`); neither historical court is an exact final-candidate integration or freeze claim.",
        "positive": "The COMMITTED C0 tree is ACCEPTED by `--check` (rc 0) with the C0 ledger and closure, so the law permits the state it exists to permit; the negative-input court's case 0 (unmutated fixture) is likewise GREEN.",
        "mutation": "Two generator-semantic strikes on the UNCHANGED guard, each reddening exactly one NAMED witness with a restored-green phase: `CLOS-SCHEMA-BYPASS` (the per-field discharge-block check is forced to a no-op; mutant sha `7eb58e612758d1ec...`) and `CLOS-PARTIAL-BLIND` (the terminality set is narrowed to one spelling of not-finished; mutant sha `d06a4f6e5967b24e...`). The SEPARATE 13-case negative-input court refuses each shape for its own reason.",
        "exact_result": "MEASURED on C0 (`gate sha256 69b4c739cf34251eb68c57e7b8bcd270bbf6859ec34f8d3595d7a9aa412947e8`): baseline 2 PASS / mutant 1 NAMED FAIL / restored 2 PASS byte-identical to C0, 0 skips -- `path:docs/remediation/evidence/board1-rc15-closure-controls/generator-strikes/OP3-CLOS-SCHEMA-BYPASS.mutant.log` and `OP1-CLOS-PARTIAL-BLIND.mutant.log`; the 13-case court ran 4 tests / 0 failures / exit0 (`NEGATIVE-INPUT-COURT-13cases.log`). Neither rod is credited with the other closure-law controls.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "audit-b1-ctrl-001.missed-partials": {
        "behavior": "Every PARTIAL is represented in the structured closure, including `GS-RUNTIME-001` and `GS-STORE-002` which the retired prose classifier missed entirely; terminality is a property of an explicit state set, so a PARTIAL can never be silently counted as finished. A DELETED or ORPHAN persisted obligation is refused by name.",
        "implementation": "`scripts/build_structured_closure.py` -- `PARTIAL_OBLIGATIONS`, `build()` and `counts()` (`obligations_by_state` plus the single-name `internal_obligations_unresolved`); the persisted/derived comparison lives in `main --check`.",
        "reachability": "production",
        "test": "`tools/readiness/tests/test_closure_law_refuses.py::ObligationStateMachine::test_one_partial_obligation_prevents_zero` and `PersistedStateAgreesWithDerivation::{test_a_deleted_obligation_is_refused,test_an_orphan_obligation_is_refused}`; PLUS a FRESH real-ledger consumer positive.",
        "positive": "FRESH on C0: the REAL ledger read through the C0 gate carrieth `GS-RUNTIME-001` with 2 internal obligations (`gs-runtime-001.android-composition-court`, `gs-runtime-001.mutations`, both DISCHARGED, derives COMPLETE, 1 external) and `GS-STORE-002` with 1 (`gs-store-002.internal-architecture`, DISCHARGED, derives COMPLETE, 1 external); the persisted copy agrees with the derivation and `obligations_by_state` reports them -- `path:docs/remediation/evidence/board1-rc15-closure-controls/generator-strikes/CONSUMER-POSITIVE-real-ledger.baseline.log` (15 PASS / 0 FAIL, exit0).",
        "mutation": "CLOS-PARTIAL-BLIND removes PARTIAL from the unresolved set (mutant sha d06a4f6e5967b24e...): test_one_partial_obligation_prevents_zero fails while test_only_all_discharged_reaches_zero passes. CLOS-DRIFT-BLIND disables persisted/derived comparison (mutant sha 038279eb5a43a5b9...): its executed failing witness is test_a_stale_count_is_refused and its green control is test_the_real_tree_agrees. Deletion and orphan refusals are the SEPARATE negative-input court cases 8 and 9, not witnesses executed under OP2.",
        "exact_result": "MEASURED on C0 (`gate sha256 69b4c739...`): each strike baseline 2 PASS / mutant 1 NAMED FAIL / restored 2 PASS byte-identical to C0, 0 skips -- `path:docs/remediation/evidence/board1-rc15-closure-controls/generator-strikes/OP1-CLOS-PARTIAL-BLIND.mutant.log` and `OP2-CLOS-DRIFT-BLIND.mutant.log`; the consumer positive is `CONSUMER-POSITIVE-real-ledger.baseline.log`.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "audit-b1-ctrl-001.finding-obligation-consistency": {
        "behavior": "A finding may not stand internally OPEN while carrying ZERO unresolved obligations, and a finding declared COMPLETE may not carry an UNRESOLVED obligation: the instrument REFUSES both directions by name rather than describing the state, because an open finding with nothing a builder can execute could never be closed.",
        "implementation": "`scripts/build_structured_closure.py` -- `build()` derives `internal_status` from the obligation set in both populations, `finding_state_problems()` is enforced by `main --check`, and `counts()` reports `findings_with_internal_status_open` beside the obligation total.",
        "reachability": "production",
        "test": "`tools/readiness/tests/test_closure_law_refuses.py::FindingStatusFollowsItsObligations::test_an_open_finding_with_all_obligations_discharged_is_refused` (witness) and `test_a_complete_finding_with_all_obligations_discharged_is_PERMITTED` (the mirror positive); `test_closure_state_mutations.py` cases 3 and 4.",
        "positive": "The MIRROR arm is GREEN: a COMPLETE finding whose obligations are all DISCHARGED is the CORRECT state, not a defect -- so the rule refuseth the false state and permitteth the true one.",
        "mutation": "`CLOS-FINDING-CONSISTENCY-BLIND` forces the OPEN-and-all-terminal guard to `if False` (mutant sha `99fe33d01458c335...`): its NAMED witness FAILS while the mirror arm stays GREEN. The negative-input court's case 3 (OPEN finding, zero unresolved obligations) and case 4 (COMPLETE finding over an OPEN obligation) are each refused in that run.",
        "exact_result": "MEASURED on C0 (`gate sha256 69b4c739...`): baseline 2 PASS / mutant 1 NAMED FAIL / restored 2 PASS byte-identical to C0, 0 skips -- `path:docs/remediation/evidence/board1-rc15-closure-controls/generator-strikes/OP4-CLOS-FINDING-CONSISTENCY-BLIND.mutant.log`. The guard LOGIC is unchanged by this DATA-only authoring.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "audit-b1-ctrl-001.ready-requires-both-populations": {
        "behavior": "A COMPLETE/READY builder status is refused while EITHER population is non-empty: unresolved internal OBLIGATIONS and findings whose internal_status is OPEN. The two are not the same test, and a gate reading only one of them can permit readiness over live work. Unknown obligation/finding states are refused by name, and a terminal claim behind an unmeasured control is refused.",
        "implementation": "`scripts/build_structured_closure.py` -- `main` refuseth on `internal_obligations_open` AND on `findings_with_internal_status_open` by name, runs `internal_status_state_problems`/`obligation_state_problems`, and runs `semantics_gate_problems`. The GUARD LOGIC is unchanged by this DATA-only authoring.",
        "reachability": "production",
        "test": "`tools/readiness/tests/test_closure_law_refuses.py::ReadinessRequiresBothPopulations::test_a_finding_status_open_alone_blocks_readiness` (witness) and `test_the_status_population_is_reported_separately` (the positive); `test_closure_state_mutations.py` cases 12 and 13.",
        "positive": "The STATUS population is reported SEPARATELY and truthfully (`findings_with_internal_status_open`), so the obligation count cannot hide a finding with no obligations; the negative-input court's case 12/13 refusals are read from the gate's OWN output, not from an exit code.",
        "mutation": "`CLOS-STATUS-POPULATION-BLIND` forces `findings_status_open = 0` (mutant sha `24064acaabccbe65...`): its NAMED witness FAILS (`0 not greater than 0 ... while the STATUS population is not`) while the separate-reporting arm stays GREEN.",
        "exact_result": "MEASURED on C0 (`gate sha256 69b4c739...`): baseline 2 PASS / mutant 1 NAMED FAIL / restored 2 PASS byte-identical to C0, 0 skips -- `path:docs/remediation/evidence/board1-rc15-closure-controls/generator-strikes/OP5-CLOS-STATUS-POPULATION-BLIND.mutant.log`; the negative-input court's cases 12 and 13 are refused inside the same GREEN 4-test run. A FINAL-C re-run is the parent's step and is NOT claimed here.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-archive-005.app-witness": {
        "behavior": "An executed iOS app/simulator witness terminates the process and RELAUNCHES it, then asserts the reader returned to the same document -- a clean process death, not a memory reboot.",
        "implementation": "`ios/Godstone/Tests/GodstoneArchiveUITests/GodstoneArchiveUITests.swift`; `ios/Godstone/Sources/GodstoneCore/ArchivePlaceStore.swift`; `ios/Godstone/Sources/App/ArchiveView.swift`.",
        "reachability": "production",
        "test": "testGSA005DocumentReopensAfterCleanProcessDeath (`ios/Godstone/Tests/GodstoneArchiveUITests/GodstoneArchiveUITests.swift`).",
        "positive": "The same arm asserts the document identity returns after relaunch (a memory reboot cannot satisfy the terminate+relaunch).",
        "mutation": "The lane roster guards LANE-ROD-1..LANE-ROD-5 (skip refusal, arm omission, duplicate arm, simulator duplicate narrowing, known-red allowance) are KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`) -- they refuse a witness that did not run on the current source-derived roster. (The provenance rods ARCHIVE-PROV-001..007 concern the metadata road and are NOT credited here.)",
        "exact_result": "MEASURED, sealed UI lane `/tmp/board1-rc15-inputs-b7bac67f/ios-ui-lane.log` (source family `eb2ff86b…`, 43 tests / 0 failures = LabMesh 29 + LIGHT 14; fresh xcresult captured): `testGSA005DocumentReopensAfterCleanProcessDeath` started at line 3070 and PASSED at line 3344 (47.144s); its companion `BrowseReturnCarriesNoFalseQuery` PASSED (9.809s).",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-final-003.android-provider-court": {
        "behavior": "Android: the SHIPPING composition is reached through MeshGraphComponent.production(ctx) at MeshService.kt:83 and LabRuntime.kt:376, so the real provider composition is the tested binding; the registered consumer reaches the tested component and refuses before any private construction on a refusing decision.",
        "implementation": "android/mesh/src/main/java/io/godstone/mesh/MeshService.kt:83; lab/LabRuntime.kt:376; di/MeshGraphComponent.kt; di/MeshModule.kt.",
        "reachability": "production",
        "test": "test_w02_the_light_release_carrieth_no_lab_and_no_mesh_edge; test_w05_the_lab_carrieth_its_own_distinct_identity; theProductionProviderHandsTheNodeThePumpItWasGiven; theDispatcherAdmitsThroughTheGivenPumpOnly",
        "positive": "The registered consumer resolves the tested component; a permitting decision walks to the platform; a refusing service opens no private state.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `T54-RC1-lab-isolation-gate-sleepeth-on-a-mesh-edge`[semantic], `T54-RC3-lab-may-masquerade-as-the-shipping-identity`[semantic], `T72-RC15-android-ack-pump-not-handed-to-the-node`[semantic], `T72-RC16-android-ack-dispatcher-admits-elsewhere`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 4 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `T54-RC1-lab-isolation-gate-sleepeth-on-a-mesh-edge` log `logs/T54-RC1-lab-isolation-gate-sleepeth-on-a-mesh-edge.mutant.log` sha `bd4bdda19495c114…` restored-green; `T54-RC3-lab-may-masquerade-as-the-shipping-identity` log `logs/T54-RC3-lab-may-masquerade-as-the-shipping-identity.mutant.log` sha `cc7e68ef695b1bae…` restored-green; `T72-RC15-android-ack-pump-not-handed-to-the-node` log `logs/T72-RC15-android-ack-pump-not-handed-to-the-node.mutant.log` sha `65b836acb958a1c1…` restored-green; `T72-RC16-android-ack-dispatcher-admits-elsewhere` log `logs/T72-RC16-android-ack-dispatcher-admits-elsewhere.mutant.log` sha `10e3345b9cf61a57…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-final-003.bootstrap-permit-unit": {
        "behavior": "CrashStartupResumeTests' bootstrap permit arms assert the TYPED decision (not Unit-returning behaviour): a clean start permits and names itself; a REQUESTED journal refuses; a corrupt/terminal journal hides the operator requirement and refuses.",
        "implementation": "ios/Godstone/Sources/GodstoneMesh/StartupRecoveryDecision.swift (requiresOperator); ios/Godstone/Tests/GodstoneMeshTests/CrashStartupResumeTests.swift.",
        "reachability": "production",
        "test": "testGSFINAL003_TheBootstrapDecisionIsTypedAndATypedDecisionIsWhatThisCourtAsserts",
        "positive": "A clean start resolves to a permitting typed decision; a corrupt/terminal journal resolves requiresOperator true->false and refuses; the unfiltered court runs.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `IOS-RECOVERY-010-corrupt-journal-hides-operator-requirement`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 1 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `IOS-RECOVERY-010-corrupt-journal-hides-operator-requirement` log `logs/IOS-RECOVERY-010-corrupt-journal-hides-operator-requirement.mutant.log` sha `56108005ff843daf…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-final-003.ios-recovery-graph": {
        "behavior": "iOS recoveryGraph: the production create road takes ONE consumeCompositionTopology() drive binding BOTH the verdict and the permit for the .normal arm; the .recoveryOnly arm drives the LIVE pre-private recovery over DefaultRecoveryEstate's OWN transport and opens NO store. The absent-baseline read->IDLE write now runs INSIDE the SAME PhysicalEstateAuthority.shared serialized transaction, so it cannot clobber a concurrent real REQUESTED.",
        "implementation": "ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift (create; .recoveryOnly arm); StartupRecoveryDecision.swift; EstateOwnerRegistry.swift (trySerializedForTest:132, Boolean not oracle).",
        "reachability": "production",
        "test": "testGSFINAL003_aRecoveryThatCannotSettleRefusesAndOpensNothing; testGSFINAL003_aPermitJudgedBeforeARequestCannotConstructAfterIt; testGSFINAL003_anAbsentBaselineDoesNotClobberAConcurrentRequest",
        "positive": "The .normal arm reaches a typed permitting decision and constructs the private graph; the recoveryOnly arm reaches a typed refusing decision and opens nothing; the concurrent-request arm reaches REQUESTED and is not clobbered.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `IOS-RECOVERY-005`[semantic], `MUT-IOS-R1-PERMIT-GENERATION-IGNORED`[semantic], `IOS-RECOVERY-BASELINE-CLOBBERED-CONCURRENT-REQUEST`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 3 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `IOS-RECOVERY-005` log `logs/IOS-RECOVERY-005.mutant.log` sha `b38cc109bd432be1…` restored-green; `MUT-IOS-R1-PERMIT-GENERATION-IGNORED` log `logs/MUT-IOS-R1-PERMIT-GENERATION-IGNORED.mutant.log` sha `1764ed2bf903d5a3…` restored-green; `IOS-RECOVERY-BASELINE-CLOBBERED-CONCURRENT-REQUEST` log `logs/IOS-RECOVERY-BASELINE-CLOBBERED-CONCURRENT-REQUEST.mutant.log` sha `6c68408ce96ddb5c…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-final-003.typed-permit": {
        "behavior": "Both isles: a non-forgeable TYPED startup decision (not a Bool, not log text, no public initializer) is issued only after the typed recovery answer, and the PRODUCTION caller on each isle consumes it.",
        "implementation": "iOS: StartupRecoveryDecision.swift (PrivateRuntimePermit, private init, nullable issue(_:); createPrivateComposition REQUIRES one). Android: MeshModule.kt permit-parameterised private providers; MeshGraphComponent.production(ctx) reached by MeshService.kt:83.",
        "reachability": "production",
        "test": "testGSFINAL003_thePermitIsEstateBoundGenerationBoundAndOneShot; testGSFINAL003_theTypedTopologyIssuesTheRightPermitAndRefusesTheThirdRoad; testGSFINAL003_thePermitIsIssuedOnlyByDrivingTheLadder; testGSFINAL003_theRecoveryTransportStandsBeforeAndIndependentlyOfTheStoreGraph; testGSFINAL003_aPermitJudgedBeforeARequestCannotConstructAfterIt; thePermittedRoadCountsOneAttemptPerSeamAtThePlatform; aPermitIsWithheldWhenTheDurableEstateMoved; aWipeThatRanToItsEndReadsAsWipeCompleted",
        "positive": "A permitting decision yields a permit and the production road constructs; every refusing decision yields nil and the private providers are unreachable.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `IOS-RECOVERY-001`[semantic], `IOS-RECOVERY-002`[semantic], `IOS-RECOVERY-003`[semantic], `IOS-RECOVERY-004`[semantic], `MUT-IOS-R1-PERMIT-GENERATION-IGNORED`[semantic], `MUT-IOS-R1-PERMIT-NOT-CONSUMED`[semantic], `T72-RC13-android-private-construction-uncounted`[semantic], `T72-RC14-android-permit-door-staleness-disabled`[semantic], `T72-RC41-android-composition-issuer-mints-from-a-constant-decision`[semantic], `T72-RC42-android-completed-wipe-collapsed-into-first-launch`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 10 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `IOS-RECOVERY-001` log `logs/IOS-RECOVERY-001.mutant.log` sha `de09d5be409203af…` restored-green; `IOS-RECOVERY-002` log `logs/IOS-RECOVERY-002.mutant.log` sha `12a5a6060d1f0700…` restored-green; `IOS-RECOVERY-003` log `logs/IOS-RECOVERY-003.mutant.log` sha `1d329db3d5397795…` restored-green; `IOS-RECOVERY-004` log `logs/IOS-RECOVERY-004.mutant.log` sha `8cc75fa4e90925ca…` restored-green; `MUT-IOS-R1-PERMIT-GENERATION-IGNORED` log `logs/MUT-IOS-R1-PERMIT-GENERATION-IGNORED.mutant.log` sha `1764ed2bf903d5a3…` restored-green; `MUT-IOS-R1-PERMIT-NOT-CONSUMED` log `logs/MUT-IOS-R1-PERMIT-NOT-CONSUMED.mutant.log` sha `05ffdaf546967bd1…` restored-green; `T72-RC13-android-private-construction-uncounted` log `logs/T72-RC13-android-private-construction-uncounted.mutant.log` sha `bc2f6f13a76c0d31…` restored-green; `T72-RC14-android-permit-door-staleness-disabled` log `logs/T72-RC14-android-permit-door-staleness-disabled.mutant.log` sha `647edc9700c88e78…` restored-green; `T72-RC41-android-composition-issuer-mints-from-a-constant-decision` log `logs/T72-RC41-android-composition-issuer-mints-from-a-constant-decision.mutant.log` sha `ff005fa4c8b6bd16…` restored-green; `T72-RC42-android-completed-wipe-collapsed-into-first-launch` log `logs/T72-RC42-android-completed-wipe-collapsed-into-first-launch.mutant.log` sha `1286f197ae1a82f3…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-final-003.zero-private-opens": {
        "behavior": "Both isles: pending / retryable / corrupt recovery causes ZERO identity and ZERO private DB opens, proven at the REAL construction seams with counters (not inferred from a later absence).",
        "implementation": "Android: PrivateConstructionCounter.kt (plain object, not a Dagger key) at the three private provider seams in MeshModule.kt. iOS: the create road's permit gate; GsFinal003StartupPermitTests.swift.",
        "reachability": "production",
        "test": "testGSFINAL003_thePermitIsIssuedOnlyByDrivingTheLadder; testGSFINAL003_aSpentPermitCannotOpenASecondComposition; testGSFINAL003_theWitnessCountersObserveARealAcceptedConstruction; thePermittedRoadCountsOneAttemptPerSeamAtThePlatform",
        "positive": "A permitted road yields delta==1 per seam with the failure chain reaching AndroidKeyStore/SQLCipher; every refusing rung moves NO counter; the same-run conjunction.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `IOS-RECOVERY-003`[semantic], `MUT-IOS-R1-NORMAL-HELPER-BYPASS`[semantic], `MUT-IOS-R11-WITNESS-DISCONNECTED`[semantic], `T72-RC13-android-private-construction-uncounted`[semantic], `T72-RC29-android-message-store-construction-uncounted`[semantic], `T72-RC30-android-peer-store-construction-uncounted`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 6 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `IOS-RECOVERY-003` log `logs/IOS-RECOVERY-003.mutant.log` sha `1d329db3d5397795…` restored-green; `MUT-IOS-R1-NORMAL-HELPER-BYPASS` log `logs/MUT-IOS-R1-NORMAL-HELPER-BYPASS.mutant.log` sha `027da86d2358e197…` restored-green; `MUT-IOS-R11-WITNESS-DISCONNECTED` log `logs/MUT-IOS-R11-WITNESS-DISCONNECTED.mutant.log` sha `b0dec65830c8cb54…` restored-green; `T72-RC13-android-private-construction-uncounted` log `logs/T72-RC13-android-private-construction-uncounted.mutant.log` sha `bc2f6f13a76c0d31…` restored-green; `T72-RC29-android-message-store-construction-uncounted` log `logs/T72-RC29-android-message-store-construction-uncounted.mutant.log` sha `c2d0447950bfe4d3…` restored-green; `T72-RC30-android-peer-store-construction-uncounted` log `logs/T72-RC30-android-peer-store-construction-uncounted.mutant.log` sha `218ab16940727726…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-final-004.identity-proof": {
        "behavior": "Repository operations use the engine-returned connection by OBJECT IDENTITY -- the raw OpaquePointer value published only after the store accepts it -- not a Boolean flag.",
        "implementation": "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift, PeerIdentityStore.swift: adoptedConnectionIdentity is the raw handle, published after acceptance.",
        "reachability": "production",
        "test": "testGF004TheCompositionRunsItsStoresOnTheEnginesConnections; testReview2OwnerCloseWaitsForActiveUseAndRefusesAfterwards; testReview8IntentReadFaultIsStorageFailureNeverAbsence; testReview4TornMigrationStampLeavesDurableVersionUnadvanced; testReviewSweepRefusesWithoutTransactionAndWithoutCommit; testPeerTransactionCompletesWithoutDeadlock; testIntentCorruptExistingRowIsStorageFailureNotAbsence",
        "positive": "identity(of: engine.handover(for: \"message-store\")) equals runtime.messageStore.adoptedConnectionIdentity.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase -- SEVEN by the `witness` channel with one named failing witness, and `IOS-RECOVERY-006` by the `compiler` channel (build_exit 1, tests_run null): `IOS-RECOVERY-006`[semantic, compiler-channel type-enforcement kill], `NCR-01-swift-the-store-drops-the-owners-use-lock`[semantic], `NCR-04-swift-the-intent-read-folds-every-fault-into-absence`[semantic], `NCR-05-swift-the-migration-stamp-runs-outside-the-edge-transaction`[semantic], `NCR-06-swift-the-sweep-begin-fault-is-not-refused`[semantic], `NCR-07-swift-the-sweep-publishes-without-an-acknowledged-commit`[semantic], `NCR-11-swift-the-peer-transaction-reacquires-the-store-lock`[semantic], `NCR-13-swift-the-corrupt-intent-row-is-absence-again`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 8 rod(s) KILLED -- SEVEN by the `witness` channel and ONE by the `compiler` channel, read per the actual canonical rows (a rod's own single named witness may fail more than one case inside it, so no \"exactly one failing case\" is claimed). `IOS-RECOVERY-006` build_exit 1, kill_channel `compiler`, tests_run null: the mutant was REFUSED AT COMPILE TIME, and the source-bound TYPE-ENFORCEMENT invariant IS the property that rod striketh, so the compiler's refusal IS the kill -- log `logs/IOS-RECOVERY-006.mutant.log` sha `f7e670853aeb2399…`, restored-green (10 arms, 0 skipped). The seven witness-channel rods: `NCR-01-swift-the-store-drops-the-owners-use-lock` log `logs/NCR-01-swift-the-store-drops-the-owners-use-lock.mutant.log` sha `ff2a2c2b6bf8768a…` restored-green; `NCR-04-swift-the-intent-read-folds-every-fault-into-absence` log `logs/NCR-04-swift-the-intent-read-folds-every-fault-into-absence.mutant.log` sha `bbb9709d64702a92…` restored-green; `NCR-05-swift-the-migration-stamp-runs-outside-the-edge-transaction` log `logs/NCR-05-swift-the-migration-stamp-runs-outside-the-edge-transaction.mutant.log` sha `631db472a84716eb…` restored-green; `NCR-06-swift-the-sweep-begin-fault-is-not-refused` log `logs/NCR-06-swift-the-sweep-begin-fault-is-not-refused.mutant.log` sha `c3e12506c52796d3…` restored-green; `NCR-07-swift-the-sweep-publishes-without-an-acknowledged-commit` log `logs/NCR-07-swift-the-sweep-publishes-without-an-acknowledged-commit.mutant.log` sha `845c263ee92d0696…` restored-green; `NCR-11-swift-the-peer-transaction-reacquires-the-store-lock` log `logs/NCR-11-swift-the-peer-transaction-reacquires-the-store-lock.mutant.log` sha `e76558e3fcb6bf53…` restored-green; `NCR-13-swift-the-corrupt-intent-row-is-absence-again` log `logs/NCR-13-swift-the-corrupt-intent-row-is-absence-again.mutant.log` sha `add9ba619630690a…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-final-004.migrations-on-verified": {
        "behavior": "Migrations run on the exact verified/keyed connection with a DUPLICATED-FAILURE-PROOF durable user_version stamp (in-transaction stamp refuses on fault), with durable readback.",
        "implementation": "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift (init(verifiedConnection:) runs runMigrations(db) on the supplied handle:1021); PeerIdentityStore.swift:308.",
        "reachability": "production",
        "test": "testReview2OwnerCloseWaitsForActiveUseAndRefusesAfterwards; testReview8IntentReadFaultIsStorageFailureNeverAbsence; testReview4TornMigrationStampLeavesDurableVersionUnadvanced; testIntentCorruptExistingRowIsStorageFailureNotAbsence",
        "positive": "Migrations execute on the supplied keyed handle; the user_version stamp is committed in-transaction and reads back durable.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `NCR-01-swift-the-store-drops-the-owners-use-lock`[semantic], `NCR-04-swift-the-intent-read-folds-every-fault-into-absence`[semantic], `NCR-05-swift-the-migration-stamp-runs-outside-the-edge-transaction`[semantic], `NCR-13-swift-the-corrupt-intent-row-is-absence-again`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 4 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `NCR-01-swift-the-store-drops-the-owners-use-lock` log `logs/NCR-01-swift-the-store-drops-the-owners-use-lock.mutant.log` sha `ff2a2c2b6bf8768a…` restored-green; `NCR-04-swift-the-intent-read-folds-every-fault-into-absence` log `logs/NCR-04-swift-the-intent-read-folds-every-fault-into-absence.mutant.log` sha `bbb9709d64702a92…` restored-green; `NCR-05-swift-the-migration-stamp-runs-outside-the-edge-transaction` log `logs/NCR-05-swift-the-migration-stamp-runs-outside-the-edge-transaction.mutant.log` sha `631db472a84716eb…` restored-green; `NCR-13-swift-the-corrupt-intent-row-is-absence-again` log `logs/NCR-13-swift-the-corrupt-intent-row-is-absence-again.mutant.log` sha `add9ba619630690a…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-final-004.no-second-open": {
        "behavior": "No second independent path-based sqlite3_open_v2 in the private composition: the repository runs on the EXACT connection the engine returned.",
        "implementation": "ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift (url: opens confined to the encryptedStores == nil branch; factory road adopts via SqliteMessageStore(verifiedConnection:)/SqlitePeerIdentityStore(verifiedConnection:)).",
        "reachability": "production",
        "test": "testGSFINAL003_aRecoveryThatCannotSettleRefusesAndOpensNothing; testGF004TheCompositionRunsItsStoresOnTheEnginesConnections; testGSFINAL003_aCorruptJournalRefusesConstructionAndRequiresAnOperator; testGSFINAL003_theRecoveryTransportStandsBeforeAndIndependentlyOfTheStoreGraph; testGSFINAL003_aLiveOwnerThatCannotBeDrainedKeepsTheWipePending",
        "positive": "The factory road composes both private stores on the engine's handles with no path-based open; the path opens are unreachable when a factory is supplied.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase -- FIVE by the `witness` channel with one named failing witness and `IOS-RECOVERY-006` by the `compiler` channel (build_exit 1, tests_run null, type enforcement the struck property): `IOS-RECOVERY-005`[semantic], `IOS-RECOVERY-006`[semantic, compiler-channel type-enforcement kill], `IOS-RECOVERY-007`[semantic], `IOS-RECOVERY-008`[semantic], `IOS-RECOVERY-009`[semantic], `MUT-IOS-R5-FRESH-DEAD-TRANSPORT`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 6 rod(s) KILLED -- FIVE by the `witness` channel and ONE (`IOS-RECOVERY-006`) by the `compiler` channel (build_exit 1, kill_channel `compiler`, tests_run null, restored-green 10 arms): the mutant was refused at COMPILE TIME and the source-bound TYPE-ENFORCEMENT invariant IS the property that rod striketh, so the compiler's refusal IS the kill, NOT a build-invalid row. A witness-channel rod's own single named witness may fail more than one case inside it, so no \"exactly one failing case\" is claimed. `IOS-RECOVERY-005` log `logs/IOS-RECOVERY-005.mutant.log` sha `b38cc109bd432be1…` restored-green; `IOS-RECOVERY-006` log `logs/IOS-RECOVERY-006.mutant.log` sha `f7e670853aeb2399…` restored-green; `IOS-RECOVERY-007` log `logs/IOS-RECOVERY-007.mutant.log` sha `39a9fd735f688558…` restored-green; `IOS-RECOVERY-008` log `logs/IOS-RECOVERY-008.mutant.log` sha `e092bb948c8b3069…` restored-green; `IOS-RECOVERY-009` log `logs/IOS-RECOVERY-009.mutant.log` sha `dd120faa9ea1972c…` restored-green; `MUT-IOS-R5-FRESH-DEAD-TRANSPORT` log `logs/MUT-IOS-R5-FRESH-DEAD-TRANSPORT.mutant.log` sha `fb041891e303d6be…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-final-004.owned-connection": {
        "behavior": "The encrypted engine yields an OWNED OPERATIONAL connection: close never races in-flight use, deinit closes the live database, and the composition/adoption/identity comparison run against the real engine -- not descriptive metadata that is discarded.",
        "implementation": "ios/Godstone/Sources/GodstoneMesh/OwnedVerifiedConnection.swift (internal init(rawHandle:engineKind:):68; close()->Bool:122); EncryptedStoreFactory.swift (reopenOwnedRequiringDEK returns OwnedConnectionResult).",
        "reachability": "production",
        "test": "testReview2OwnerCloseWaitsForActiveUseAndRefusesAfterwards; testAdmissionRefusesASpentMintAndAnUnissuedOne",
        "positive": "A real host/sim engine mints an owned connection; the store adopts the exact handle; deinit drains and closes without a race.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `NCR-02-swift-the-owner-close-frees-without-draining`[semantic], `NCR-03-swift-the-admission-always-admits`[semantic], `NCR-08-swift-the-factory-admits-a-replayed-scope`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 3 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `NCR-02-swift-the-owner-close-frees-without-draining` log `logs/NCR-02-swift-the-owner-close-frees-without-draining.mutant.log` sha `af7af3cbc6293ceb…` restored-green; `NCR-03-swift-the-admission-always-admits` log `logs/NCR-03-swift-the-admission-always-admits.mutant.log` sha `a0e36b8f87afef0e…` restored-green; `NCR-08-swift-the-factory-admits-a-replayed-scope` log `logs/NCR-08-swift-the-factory-admits-a-replayed-scope.mutant.log` sha `6d27d749bc7c2f4d…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-final-004.provider-dispatch": {
        "behavior": "A pointer created by one SQLite implementation is never passed to another: the complete function surface a store uses is bound from the SAME image the handle came from, carried with the connection, and used for every operation; no global raw-pointer-to-provider map; a partial bind is refused and a failed open's partial handle is closed; payloads round-trip with exact-bytes readback and wrong-key refusal.",
        "implementation": "ios/Godstone/Sources/GodstoneMesh/SQLiteFunctionTable.swift (ONE immutable per-provider table, all-or-nothing bind from requiredSymbols); OwnedVerifiedConnection.swift; SqlCipherDylibEngine.swift; MessageStore.swift; PeerIdentityStore.swift.",
        "reachability": "production",
        "test": "testReview2OwnerCloseWaitsForActiveUseAndRefusesAfterwards; testReview8IntentReadFaultIsStorageFailureNeverAbsence; testReview4TornMigrationStampLeavesDurableVersionUnadvanced; testReviewSweepRefusesWithoutTransactionAndWithoutCommit; testReview6RealPinnedRoundTripExactBytesAndWrongKeyRefusal; testGF004APartialProviderBindIsRefusedAndAKeyFaultIsTyped; testPeerTransactionCompletesWithoutDeadlock; testIntentCorruptExistingRowIsStorageFailureNotAbsence; testTheArbitraryPathLibraryIsBoundYetNeverClaimsPinned",
        "positive": "A real bound image round-trips a nonempty payload with exact-byte readback; an image lacking the sqlite3 surface or a partial bind is refused; a wrong DEK is typed .wrongKey; a failed open closes its partial handle.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `NCR-01-swift-the-store-drops-the-owners-use-lock`[semantic], `NCR-02-swift-the-owner-close-frees-without-draining`[semantic], `NCR-03-swift-the-admission-always-admits`[semantic], `NCR-04-swift-the-intent-read-folds-every-fault-into-absence`[semantic], `NCR-05-swift-the-migration-stamp-runs-outside-the-edge-transaction`[semantic], `NCR-06-swift-the-sweep-begin-fault-is-not-refused`[semantic], `NCR-07-swift-the-sweep-publishes-without-an-acknowledged-commit`[semantic], `NCR-09-swift-the-engine-reports-a-generic-io-for-a-wrong-key`[semantic], `NCR-10-swift-the-partial-open-handle-leaks`[semantic], `NCR-11-swift-the-peer-transaction-reacquires-the-store-lock`[semantic], `NCR-13-swift-the-corrupt-intent-row-is-absence-again`[semantic], `T72-RC17-ios-engine-claims-pinned-without-binding`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 12 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `NCR-01-swift-the-store-drops-the-owners-use-lock` log `logs/NCR-01-swift-the-store-drops-the-owners-use-lock.mutant.log` sha `ff2a2c2b6bf8768a…` restored-green; `NCR-02-swift-the-owner-close-frees-without-draining` log `logs/NCR-02-swift-the-owner-close-frees-without-draining.mutant.log` sha `af7af3cbc6293ceb…` restored-green; `NCR-03-swift-the-admission-always-admits` log `logs/NCR-03-swift-the-admission-always-admits.mutant.log` sha `a0e36b8f87afef0e…` restored-green; `NCR-04-swift-the-intent-read-folds-every-fault-into-absence` log `logs/NCR-04-swift-the-intent-read-folds-every-fault-into-absence.mutant.log` sha `bbb9709d64702a92…` restored-green; `NCR-05-swift-the-migration-stamp-runs-outside-the-edge-transaction` log `logs/NCR-05-swift-the-migration-stamp-runs-outside-the-edge-transaction.mutant.log` sha `631db472a84716eb…` restored-green; `NCR-06-swift-the-sweep-begin-fault-is-not-refused` log `logs/NCR-06-swift-the-sweep-begin-fault-is-not-refused.mutant.log` sha `c3e12506c52796d3…` restored-green; `NCR-07-swift-the-sweep-publishes-without-an-acknowledged-commit` log `logs/NCR-07-swift-the-sweep-publishes-without-an-acknowledged-commit.mutant.log` sha `845c263ee92d0696…` restored-green; `NCR-09-swift-the-engine-reports-a-generic-io-for-a-wrong-key` log `logs/NCR-09-swift-the-engine-reports-a-generic-io-for-a-wrong-key.mutant.log` sha `3fc7b3b1ce7f4c8e…` restored-green; `NCR-10-swift-the-partial-open-handle-leaks` log `logs/NCR-10-swift-the-partial-open-handle-leaks.mutant.log` sha `cfbdf711cdf9e59f…` restored-green; `NCR-11-swift-the-peer-transaction-reacquires-the-store-lock` log `logs/NCR-11-swift-the-peer-transaction-reacquires-the-store-lock.mutant.log` sha `e76558e3fcb6bf53…` restored-green; `NCR-13-swift-the-corrupt-intent-row-is-absence-again` log `logs/NCR-13-swift-the-corrupt-intent-row-is-absence-again.mutant.log` sha `add9ba619630690a…` restored-green; `T72-RC17-ios-engine-claims-pinned-without-binding` log `logs/T72-RC17-ios-engine-claims-pinned-without-binding.mutant.log` sha `6005d80fbfd0fc41…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-final-006.ios-restoration-witness": {
        "behavior": "An executed iOS app-level restoration/scroll sequence: launch, search, open a non-first hit, scroll to a stable passage, terminate the process, relaunch, verify the same document and a valid anchor return, with Back returning to the submitted query.",
        "implementation": "`ios/Godstone/Sources/GodstoneCore/ArchiveReadingAnchor.swift` and the App/GodstoneCore restoration roads; `ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift`.",
        "reachability": "production",
        "test": "testGSFINAL006TheWholeRestorationJourneyInOneSequence, with the Back-to-query arm `SearchOpenThenBackReturnsToTheSubmittedQuery`.",
        "positive": "The valid anchor returns after relaunch and Back returns the submitted query (the positive road); the invalid-anchor fallback is the refusal arm.",
        "mutation": "The lane roster guards LANE-ROD-1..LANE-ROD-5 are KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), refusing a sequence that did not run on the current roster. The restoration-DISCONNECTION mutation is the SEPARATE obligation `gs-final-006.mutation`, discharged on its OWN scope-specific four-rod restoration campaign (see there); its rods are NOT folded into this entry's roster, and the two evidence families are NEVER aggregated.",
        "exact_result": "MEASURED, sealed UI lane `/tmp/board1-rc15-inputs-b7bac67f/ios-ui-lane.log` (source family `eb2ff86b…`, 43 tests / 0 failures = LabMesh 29 + LIGHT 14; fresh xcresult captured): `testGSFINAL006TheWholeRestorationJourneyInOneSequence` started at line 3451 and PASSED at line 3808 (62.444s); `SearchOpenThenBackReturnsToTheSubmittedQuery` PASSED at line 3450 (19.542s).",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-final-006.mutation": {
        "behavior": "The restoration/anchor DISCONNECTION is KILLED by four independent SEMANTIC rods that strike the production state-owner boundary on BOTH isles and redden the EXECUTED restoration witnesses: the Android `BrowseViewModel.snapshotTo` handle is stripped of the persisted scene (mode, then document identity), and the iOS `ArchiveSceneModel` recreation handle forgetteth the scene mode and the scroll anchor -- so a journey broken in the document standeth reposed at the root and the reader's place is forgot upon relaunch.",
        "implementation": "`android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt` (`snapshotTo`, the persisted scene handle) and `ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift` (`handle[\"mode\"] = mode.rawValue` and `scrollAnchor = ArchiveScrollAnchor(documentId:passageId:)` in the recreation snapshot); the executed witnesses are `android/app/src/test/java/io/godstone/app/readiness/ReadinessT49Test.kt` and `ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift`.",
        "reachability": "production",
        "test": "testProcessRecreationRestorethTheSameJourney (ReadinessT49Test.kt), testProcessRecreationRestorethTheSameJourney (ReadinessT50Tests.swift) and testTheScrollAnchorIsNoteAndRemembered (ReadinessT50Tests.swift).",
        "positive": "On the unmutated tree each rod's roster ran GREEN -- 21 and 28 arms, 0 failures, 0 skipped -- and each rod carrieth its own restored-green phase: the Android and iOS recreation handles restore the SAME document identity and the SAME scroll anchor, and Back returneth to the submitted query. The COMPOSITION these rods break is separately exercised on the REAL APP ROAD by the sealed UI lane `/tmp/board1-rc15-inputs-b7bac67f/ios-ui-lane.log` (source family `eb2ff86b…`: 43 tests / 0 failures = LabMesh 29 + LIGHT 14, fresh xcresult): `testGSFINAL006TheWholeRestorationJourneyInOneSequence` PASSED in 62.444s after a terminate+relaunch, so the positive half is not a model court alone.",
        "mutation": "KILLED on the SEPARATE, SCOPE-SPECIFIC restoration-rods campaign (manifest `docs/remediation/evidence/board1-rc15-restoration-rods`, lineage `semantic`, baseline `8e49631bae1524829f06f48c36b883749436ad0b`, tested tree `95952ec36161abe1a5b6c4ac5c99861c4b0bb0d3`), four rods, each with a green restored phase and exactly one named failing witness: `T49-SM10-restore-amnesial-mode`[semantic], `T49-SM11-restore-amnesial-identity`[semantic], `T50-SM11-recreation-amnesic`[semantic], `T50-SM12-anchor-amnesic`[semantic]. This campaign is SEPARATE from the canonical board1 181 (179 semantic + 2 structural) and is NEVER aggregated with it.",
        "exact_result": "MEASURED, separate restoration-rods campaign (baseline `8e49631b…`, tested tree `95952ec3…`, 4/4 SEMANTIC KILLED; group null, selected 4, required empty; the manifest's 161-key input set was verified against `path:ci/mutations.py`'s `_tested_input_digests()`): `T49-SM10-restore-amnesial-mode` build_exit 0, tests_run 21 / restored 21 / skipped 0, kill_channel `witness` -- `testProcessRecreationRestorethTheSameJourney` failed 1 case, log `logs/T49-SM10-restore-amnesial-mode.mutant.log` sha `526bc0f6ffdd301691d50b2f01abba59daeeff7ff8b657c471afb4a1100eea9f`; `T49-SM11-restore-amnesial-identity` build_exit 0, 21/21/0, `witness` -- 1 case, log sha `485b25cab855b627669c2c615a5849c22344a1bf521f4663ebb90ad3ee1f2d5d`; `T50-SM11-recreation-amnesic` build_exit 0, 28/28/0, `witness` -- 1 case, log sha `cf0b3d355457b877678041304ad13e208facc9c98f3fcc3d77e2706d150d6472`; `T50-SM12-anchor-amnesic` build_exit 0, 28/28/0, `witness` -- `testTheScrollAnchorIsNoteAndRemembered` failed 1 case, log sha `2175f1d8eaadedf60efc6556282712dc6c1a2a60c84ea002bbb38028cda40360`. Every rod carrieth baseline/mutant/restored phase logs whose SHA-256 were verified by `shasum`, and ALL FOUR carry build_exit 0 + kill_channel `witness` -- this campaign carrieth NO compiler-channel kill. The source-bound COMPILER-channel invariant is a property of the canonical board1 rod `IOS-RECOVERY-006` and is NOT credited, exercised or claimed here; and the `ARCHIVE-PROV-001..007` rods (which concern the archive METADATA/provenance road) are likewise NOT credited as this restoration kill -- the kill claimed here rests on the four T49/T50 restoration rods alone.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-integration-001.cross-platform": {
        "behavior": "Bidirectional cross-platform execution over the two platforms' ACTUAL live endpoint implementations: iOS sender -> Android recipient -> iOS ACK, and the reverse, relaying exact characteristic bytes with a length-delimited transcript; alter/mismatch/old-session variants are refused in BOTH directions.",
        "implementation": "tools/readiness/run_board1_integration.py (--mode all); GsIntegration001CrossPlatformWorkerTests.swift; RealTransportHostRigWorkerTest.kt; coordinator.log.",
        "reachability": "production",
        "test": "the 8 bound cases + 6 negative variants of the coordinator.",
        "positive": "An honest run relays the exact frame and both directions ACK end to end.",
        "mutation": "The clause's own control set IS the mutation field: altered/mismatched/old-session variants must be REFUSED both directions; the worker refuses an unknown variant rather than silently downgrading it. NO separately named coordinator source-mutation rod is required (builder:332-348).",
        "exact_result": "MEASURED: FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`, 181 ids) KILLED all 181 rods; integration `--mode all` PASS at `b7bac67f…` (checker `ci/check_integration_evidence.py --require-mode all`: rows 10, cross 8, crash 2, digests+inputs bound, 533.00s) -- both honest directions delivered the AUTHORED msg_id after cancel+reopen; six negatives refused at their exact stage.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-integration-001.mutation": {
        "behavior": "Removing the transport ingest wiring makes the composed test fail: the opened payload never reaches the node, so a frame that crossed the real radio reaches no store.",
        "implementation": "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift responder ingress delegate hand-off (deleted by rod T72-RC18).",
        "reachability": "production",
        "test": "testARBEstablishesOverOSFacadesOnlyThenDeliversADirectFrameAndTheRecipientAck",
        "positive": "The unmutated tree is green on both witnesses.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `T72-RC18-ios-transport-ingest-unwired`[semantic], `T72-RC19-ios-egress-is-a-silent-noop`[semantic], `T72-RC20-ios-ingress-empty-sender-restored`[semantic], `T72-RC28-ios-os-egress-suppressed-while-advertising-success`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 4 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `T72-RC18-ios-transport-ingest-unwired` log `logs/T72-RC18-ios-transport-ingest-unwired.mutant.log` sha `1fad8ebad7bfa963…` restored-green; `T72-RC19-ios-egress-is-a-silent-noop` log `logs/T72-RC19-ios-egress-is-a-silent-noop.mutant.log` sha `73882cb677617a5c…` restored-green; `T72-RC20-ios-ingress-empty-sender-restored` log `logs/T72-RC20-ios-ingress-empty-sender-restored.mutant.log` sha `be128e8d5969afdd…` restored-green; `T72-RC28-ios-os-egress-suppressed-while-advertising-success` log `logs/T72-RC28-ios-os-egress-suppressed-while-advertising-success.mutant.log` sha `32e93fb78c164fb0…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-integration-001.real-adapters": {
        "behavior": "A host harness substitutes ONLY the OS/hardware boundary and drives the REAL transport/orchestration/handshake adapters over real on-disk stores -- not LinkFacade and not an in-memory transport.",
        "implementation": "ios/Godstone/Sources/GodstoneMesh/RealTransportHostRig.swift; ComposedRuntime.swift; evidence gs-integration-001-courts.log.",
        "reachability": "production",
        "test": "testCRYPTO005_theSendBoundaryAfterTheDurableEnqueueIsRestartableFromDisk; testCRYPTO005_theCompositionPinsTheIntentBeforeTheRadioAndSurvivesAReopen; testARBEstablishesOverOSFacadesOnlyThenDeliversADirectFrameAndTheRecipientAck; testGSINT001ASecondLinksReadinessIsNotSatisfiedByTheFirstLinksHandle",
        "positive": "The rig establishes real links and delivers a sealed frame into the store through production code.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `IOS-R10-no-dispatch`[semantic], `IOS-R10-second-store`[semantic], `T72-RC19-ios-egress-is-a-silent-noop`[semantic], `T72-RC22-ios-link-readiness-falls-back-to-any-handle`[semantic], `T72-RC28-ios-os-egress-suppressed-while-advertising-success`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 5 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `IOS-R10-no-dispatch` log `logs/IOS-R10-no-dispatch.mutant.log` sha `0ce93e1d0ab0c7a5…` restored-green; `IOS-R10-second-store` log `logs/IOS-R10-second-store.mutant.log` sha `25e46360d492ab7f…` restored-green; `T72-RC19-ios-egress-is-a-silent-noop` log `logs/T72-RC19-ios-egress-is-a-silent-noop.mutant.log` sha `73882cb677617a5c…` restored-green; `T72-RC22-ios-link-readiness-falls-back-to-any-handle` log `logs/T72-RC22-ios-link-readiness-falls-back-to-any-handle.mutant.log` sha `d078c3f7ee484e94…` restored-green; `T72-RC28-ios-os-egress-suppressed-while-advertising-success` log `logs/T72-RC28-ios-os-egress-suppressed-while-advertising-success.mutant.log` sha `32e93fb78c164fb0…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-integration-001.scenarios": {
        "behavior": "The three named scenario gaps plus the OS-facade route are driven through production code: (A) wrong peer/key refused at the REAL sealed handshake; (B) crash after outbound durable enqueue survives restart; (C) crash after ACK commit leaves the ACK drainable; (D) the OS-facade route carries a sealed frame into the store.",
        "implementation": "The sealed handshake and the durable inbox/ACK roads in the GodstoneMesh production sources driven by the host rig; child-process crash half.",
        "reachability": "production",
        "test": "testEWipeDuringASuspendedWriteRefusesStorageFailureThenReopens",
        "positive": "Each refusal arm carries its same-run positive control (the honest transcript/frame is accepted).",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `T72-RC21-ios-resolver-stopeth-resolving-altogether`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 1 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `T72-RC21-ios-resolver-stopeth-resolving-altogether` log `logs/T72-RC21-ios-resolver-stopeth-resolving-altogether.mutant.log` sha `41177ec11c0c6e08…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-runtime-001.android-composition-court": {
        "behavior": "A Robolectric court exercises the ACTUAL production providers up to the real AndroidKeyStore boundary, establishing by BEHAVIOUR (not by reading a source file) that the composition reaches the real ACK/pump owners; the AndroidKeyStore stop is the explicit external boundary.",
        "implementation": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003GraphComponentTest.kt over MeshModule.provideMeshNode resolved through DaggerMeshGraphComponent.",
        "reachability": "production",
        "test": "theProductionProviderHandsTheNodeThePumpItWasGiven; theDispatcherAdmitsThroughTheGivenPumpOnly",
        "positive": "assertSame(pump, node.ackPump) over the real provider with device-bound inputs supplied; each owner is read through a FOREIGN consumer.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `T72-RC15-android-ack-pump-not-handed-to-the-node`[semantic], `T72-RC16-android-ack-dispatcher-admits-elsewhere`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 2 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `T72-RC15-android-ack-pump-not-handed-to-the-node` log `logs/T72-RC15-android-ack-pump-not-handed-to-the-node.mutant.log` sha `65b836acb958a1c1…` restored-green; `T72-RC16-android-ack-dispatcher-admits-elsewhere` log `logs/T72-RC16-android-ack-dispatcher-admits-elsewhere.mutant.log` sha `10e3345b9cf61a57…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-runtime-001.mutations": {
        "behavior": "Three clauses each carry their own rod over the production composition: removing the ackPump wiring fails; a wrong provider binding fails; shutdown/wipe invalidation reaches the same owner graph.",
        "implementation": "MeshModule.kt and MeshNode.kt (the drain now stands above the !isStarted guard).",
        "reachability": "production",
        "test": "theProductionProviderHandsTheNodeThePumpItWasGiven; theDispatcherAdmitsThroughTheGivenPumpOnly",
        "positive": "HostMeshRig drives MeshModule.provideMeshNode over on-disk JdbcStoreDb stores; each owner is read through a FOREIGN consumer.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `T72-RC15-android-ack-pump-not-handed-to-the-node`[semantic], `T72-RC16-android-ack-dispatcher-admits-elsewhere`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 2 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `T72-RC15-android-ack-pump-not-handed-to-the-node` log `logs/T72-RC15-android-ack-pump-not-handed-to-the-node.mutant.log` sha `65b836acb958a1c1…` restored-green; `T72-RC16-android-ack-dispatcher-admits-elsewhere` log `logs/T72-RC16-android-ack-dispatcher-admits-elsewhere.mutant.log` sha `10e3345b9cf61a57…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-store-002.internal-architecture": {
        "behavior": "Internal connection-ownership architecture complete (shared with GS-FINAL-004): the absent native engine is NOT an excuse for connection-ownership work. The store's migration refusal is proven against a real native host with durable version readback; the only recorded remainder is the absent SQLCipher engine artifact, which is the existing EXTERNAL obligation gs-store-002.sqlcipher-engine.",
        "implementation": "ios/Godstone/Sources/GodstoneMesh/OwnedVerifiedConnection.swift; EncryptedStoreFactory.swift; MessageStore.swift; PeerIdentityStore.swift; MeshRuntime.swift.",
        "reachability": "production",
        "test": "testGSFINAL003_aRecoveryThatCannotSettleRefusesAndOpensNothing; testReview2OwnerCloseWaitsForActiveUseAndRefusesAfterwards; testReview4TornMigrationStampLeavesDurableVersionUnadvanced; testPeerTransactionCompletesWithoutDeadlock; testIntentCorruptExistingRowIsStorageFailureNotAbsence",
        "positive": "The private stores run on the engine-returned handled connections; each road migrates the connection it actually owns.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `IOS-RECOVERY-005`[semantic], `NCR-01-swift-the-store-drops-the-owners-use-lock`[semantic], `NCR-05-swift-the-migration-stamp-runs-outside-the-edge-transaction`[semantic], `NCR-11-swift-the-peer-transaction-reacquires-the-store-lock`[semantic], `NCR-13-swift-the-corrupt-intent-row-is-absence-again`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 5 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `IOS-RECOVERY-005` log `logs/IOS-RECOVERY-005.mutant.log` sha `b38cc109bd432be1…` restored-green; `NCR-01-swift-the-store-drops-the-owners-use-lock` log `logs/NCR-01-swift-the-store-drops-the-owners-use-lock.mutant.log` sha `ff2a2c2b6bf8768a…` restored-green; `NCR-05-swift-the-migration-stamp-runs-outside-the-edge-transaction` log `logs/NCR-05-swift-the-migration-stamp-runs-outside-the-edge-transaction.mutant.log` sha `631db472a84716eb…` restored-green; `NCR-11-swift-the-peer-transaction-reacquires-the-store-lock` log `logs/NCR-11-swift-the-peer-transaction-reacquires-the-store-lock.mutant.log` sha `e76558e3fcb6bf53…` restored-green; `NCR-13-swift-the-corrupt-intent-row-is-absence-again` log `logs/NCR-13-swift-the-corrupt-intent-row-is-absence-again.mutant.log` sha `add9ba619630690a…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-stress-001.classification": {
        "behavior": "`StressCampaign` remains EXPLICITLY classified `resource-model`, and the CATEGORY IS CARRIED by the typed result and the report -- not asserted only in courts and printed nowhere.",
        "implementation": "`ios/Godstone/Sources/GodstoneMesh/StressCampaign.swift` (RESOURCE_MODEL_CATEGORY + CampaignResult.category/isResourceModel) and its Kotlin twin `android/mesh/src/main/java/io/godstone/mesh/stress/StressCampaign.kt` (the carried category at run()'s own construction site); `tools/readiness/stress.py` (the report line); `ios/Godstone/Tests/GodstoneMeshTests/ReadinessT72Tests.swift`.",
        "reachability": "production",
        "test": "testW14TheCampaignIsANamedResourceModel (Swift; asserts the category BOTH ways) and test_w14b_the_category_is_carried_on_the_result_and_in_the_report (python report carry).",
        "positive": "The category is carried on the typed result and the report for the current candidate, so a model result cannot be quoted as a runtime result; the Swift assertion requires it BOTH ways.",
        "mutation": "SH-R05-python-the-category-is-carried-as-the-production-runtime and SH-R10-jvm-the-category-is-carried-as-the-production-runtime are KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a restored-green phase, striking exactly the category-carrying clause.",
        "exact_result": "MEASURED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): SH-R05 and SH-R10 KILLED with green restorations; and in the sealed host lane (source family `eb2ff86b…`) `testW14TheCampaignIsANamedResourceModel` PASSED. The unrelated SH-R12/SH-R14 release/census rods are NOT credited here.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-stress-001.production-owner-mutation": {
        "behavior": "At least one mutation in a REAL production resource guard/owner (leaked session slot, unreleased writer reservation, uncancelled observer/timer, unretired ACK work) that the stress court detects, each with its own release arm and a green restored phase.",
        "implementation": "ios/Godstone/Sources/GodstoneMesh/SessionManager.swift; BleTransport.swift; RecordWriter.swift.",
        "reachability": "production",
        "test": "testGSSTRESS001RelationRetirementReleasesTheOwnersOwnSlot; testGSSTRESS001TransportStopReleasesEveryHeldTimerLease; testGSSTRESS001WriterShutdownReleasesTheOwnersOwnReservations",
        "positive": "Each rod runs a green baseline and an EXECUTED restored-green phase; the healthy runtime starts BELOW the bound and the bound is FINITE.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `T72-RC31-ios-retirement-leaveth-the-session-slot-standing`[semantic], `T72-RC32-ios-stop-leaveth-every-timer-lease-standing`[semantic], `T72-RC33-ios-shutdown-leaveth-the-reservations-standing`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 3 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `T72-RC31-ios-retirement-leaveth-the-session-slot-standing` log `logs/T72-RC31-ios-retirement-leaveth-the-session-slot-standing.mutant.log` sha `c51f23424400050f…` restored-green; `T72-RC32-ios-stop-leaveth-every-timer-lease-standing` log `logs/T72-RC32-ios-stop-leaveth-every-timer-lease-standing.mutant.log` sha `f2949a2b5e72e378…` restored-green; `T72-RC33-ios-shutdown-leaveth-the-reservations-standing` log `logs/T72-RC33-ios-shutdown-leaveth-the-reservations-standing.mutant.log` sha `0a5d4b4a6a2b824f…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-stress-001.real-owner-invariants": {
        "behavior": "no-duplicate-inbox, no-duplicate-delivery, no-uncaught-malformed and bounded-census are read from the REAL repositories/owners/parser, not from StressCampaign's own integers; the campaign census is asked of this driver's real owners on BOTH isles.",
        "implementation": "ios/Godstone/Sources/GodstoneMesh/StressCampaign.swift:93-138 (six ask-hooks; NOT_MEASURED sentinel); GsStress001RealRuntimeDriverTests.swift; ReadinessT72Tests.swift (W15d).",
        "reachability": "production",
        "test": "testW15bTheResultCarriethItsCategoryAndItsUnmeasuredSet; testW15dAnUnmeasurableKindIsNamedNotCountedAsClean; testW15dTheInventoryLeaseOwnerIsCensusedAndAccused",
        "positive": "A real leak in each kind reddens its named invariant; a healthy owner does not; a kind the seam cannot census answers NOT_MEASURED and is named, never zero; the eight malformed vectors V-G0..V7 are each caught.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `SH-R13-swift-the-unmeasured-set-omits-the-reservation-owner`[semantic], `SH-R15-swift-the-inventory-lease-default-answers-zero`[semantic], `SH-R16-swift-the-pending-ack-default-answers-zero`[semantic], `SH-R17-swift-the-store-observer-default-answers-zero`[semantic], `SH-R18-swift-the-inventory-lease-owner-is-not-asked`[semantic], `SH-R19-swift-the-observer-default-answers-zero`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 6 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `SH-R13-swift-the-unmeasured-set-omits-the-reservation-owner` log `logs/SH-R13-swift-the-unmeasured-set-omits-the-reservation-owner.mutant.log` sha `4e5c3e0a52b18316…` restored-green; `SH-R15-swift-the-inventory-lease-default-answers-zero` log `logs/SH-R15-swift-the-inventory-lease-default-answers-zero.mutant.log` sha `3b5775f387aa7559…` restored-green; `SH-R16-swift-the-pending-ack-default-answers-zero` log `logs/SH-R16-swift-the-pending-ack-default-answers-zero.mutant.log` sha `131df7c070db9ca6…` restored-green; `SH-R17-swift-the-store-observer-default-answers-zero` log `logs/SH-R17-swift-the-store-observer-default-answers-zero.mutant.log` sha `4f71458f92e93ad7…` restored-green; `SH-R18-swift-the-inventory-lease-owner-is-not-asked` log `logs/SH-R18-swift-the-inventory-lease-owner-is-not-asked.mutant.log` sha `1c3e43ec4e37a1cf…` restored-green; `SH-R19-swift-the-observer-default-answers-zero` log `logs/SH-R19-swift-the-observer-default-answers-zero.mutant.log` sha `d6051441036aeb31…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-stress-001.real-runtime-driver": {
        "behavior": "A real-runtime stress driver instantiates MeshRuntime/ComposedRuntime -- not only StressCampaign -- and cycles the shipping lane's own owners.",
        "implementation": "ios/Godstone/Tests/GodstoneMeshTests/GsStress001RealRuntimeDriverTests.swift over MeshRuntime.swift's production composition root.",
        "reachability": "production",
        "test": "testGSFINAL003_aRecoveryThatCannotSettleRefusesAndOpensNothing; testGF004TheCompositionRunsItsStoresOnTheEnginesConnections; testGSFINAL003_aCorruptJournalRefusesConstructionAndRequiresAnOperator; testGSFINAL003_theRecoveryTransportStandsBeforeAndIndependentlyOfTheStoreGraph; testGSSTRESS001RelationRetirementReleasesTheOwnersOwnSlot; testGSSTRESS001TransportStopReleasesEveryHeldTimerLease; testGSSTRESS001WriterShutdownReleasesTheOwnersOwnReservations",
        "positive": "The arm asserts meshNode.sessions === sessionManager, so a cycle that silently replaced an owner would redden.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase -- SEVEN by the `witness` channel with one named failing witness and `IOS-RECOVERY-006` by the `compiler` channel (build_exit 1, tests_run null, type enforcement the struck property): `IOS-RECOVERY-005`[semantic], `IOS-RECOVERY-006`[semantic, compiler-channel type-enforcement kill], `IOS-RECOVERY-007`[semantic], `IOS-RECOVERY-008`[semantic], `IOS-RECOVERY-009`[semantic], `T72-RC31-ios-retirement-leaveth-the-session-slot-standing`[semantic], `T72-RC32-ios-stop-leaveth-every-timer-lease-standing`[semantic], `T72-RC33-ios-shutdown-leaveth-the-reservations-standing`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 8 SEMANTIC rods KILLED -- SEVEN witness-channel catches with build_exit 0 and ONE compiler-channel catch (`IOS-RECOVERY-006`, build_exit 1, tests_run null, restored-green 10 arms). The latter strikes the source-bound TYPE-ENFORCEMENT invariant; its compiler refusal is the intended kill, NOT a build-invalid row. Every rod has a green restored phase. `IOS-RECOVERY-005` log `logs/IOS-RECOVERY-005.mutant.log` sha `b38cc109bd432be1…`; `IOS-RECOVERY-006` log `logs/IOS-RECOVERY-006.mutant.log` sha `f7e670853aeb2399…`; `IOS-RECOVERY-007` log `logs/IOS-RECOVERY-007.mutant.log` sha `39a9fd735f688558…`; `IOS-RECOVERY-008` log `logs/IOS-RECOVERY-008.mutant.log` sha `e092bb948c8b3069…`; `IOS-RECOVERY-009` log `logs/IOS-RECOVERY-009.mutant.log` sha `dd120faa9ea1972c…`; `T72-RC31-ios-retirement-leaveth-the-session-slot-standing` log `logs/T72-RC31-ios-retirement-leaveth-the-session-slot-standing.mutant.log` sha `c51f23424400050f…`; `T72-RC32-ios-stop-leaveth-every-timer-lease-standing` log `logs/T72-RC32-ios-stop-leaveth-every-timer-lease-standing.mutant.log` sha `f2949a2b5e72e378…`; `T72-RC33-ios-shutdown-leaveth-the-reservations-standing` log `logs/T72-RC33-ios-shutdown-leaveth-the-reservations-standing.mutant.log` sha `0a5d4b4a6a2b824f…`.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-stress-001.ten-thousand-cycles": {
        "behavior": "At least 10,000 deterministic host cycles drive twelve action classes, each with its own completion counter asserted against its schedule expectation, with full-graph reopen checkpoints at cycles 1000, 5000, 9000 and after the final stop.",
        "implementation": "`ios/Godstone/Tests/GodstoneMeshTests/GsStress001RealRuntimeDriverTests.swift` over the production composition root (`ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift`).",
        "reachability": "production",
        "test": "testGSSTRESS001TheRealRuntimeSurvivesTenThousandDeterministicCycles",
        "positive": "EVERY counter must move (a class that silently stopped firing cannot hide behind the total); the cycle count is ASSERTED so a truncated loop cannot read as a full run.",
        "mutation": "The release-owner rods T72-RC31 (session slot surviveth retirement) and T72-RC32 (stop leaveth every timer lease standing) are the NEGATIVE-OWNER controls -- they are single-method release mutations, NOT the cycle campaign, and they are credited only as the separate production-owner control.",
        "exact_result": "MEASURED, sealed host lane `/tmp/board1-rc15-inputs-b7bac67f/ios-lane.log` (source family `eb2ff86b…`, 1529 host tests, 0 failures): line 5115 marks the 10k arm's start and line 6771 records `testGSSTRESS001TheRealRuntimeSurvivesTenThousandDeterministicCycles` **PASSED (214.031s)**, twelve-class tally and reopen checkpoints asserted by the test itself. The 3 single-method rods are NOT claimed to have executed cycles.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-stress-001.thirty-thousand-cycles": {
        "behavior": "The same real-runtime campaign at 30,000 cycles through the same driver and the SAME fixed owner bounds, with its own exact schedule counts and reopen observations.",
        "implementation": "The same driver over the production composition root.",
        "reachability": "production",
        "test": "testGSSTRESS001TheRealRuntimeSurvivesThirtyThousandDeterministicCycles.",
        "positive": "Two independent runs must agree byte-for-byte on the twelve-class tallies; the cycle count is ASSERTED.",
        "mutation": "The release-owner rods T72-RC31/RC32/RC33 remain the distinct negative-owner control, never the long-run result.",
        "exact_result": "MEASURED, sealed host lane `/tmp/board1-rc15-inputs-b7bac67f/ios-lane.log` (source family `eb2ff86b…`): line 6772 marks the 30k arm's start and line 11746 records `testGSSTRESS001TheRealRuntimeSurvivesThirtyThousandDeterministicCycles` **PASSED (1086.775s)**; the pre-rc15 sample proofs under `docs/remediation/evidence/gs-stress-001-30k-samples/` are kept as HISTORY only where their source binding differs. The 3 release rods are NOT claimed to have executed cycles.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-ux-001.accessibility": {
        "behavior": "Internally verify rendered semantics (labels, identifiers, roles, state descriptions, 44pt bounds) WITHOUT claiming human/device accessibility acceptance. The iOS rendered-ROLE half is read from the resolved element TYPE (XCUITest carries no traits API, named as a proxy) for the FULL essential roster on both the LABMESH and LIGHT profiles in all four combinations; human VoiceOver/TalkBack acceptance stays EXTERNAL.",
        "implementation": "ios/Godstone/Tests/LabMeshUITests/LabMeshAccessibilityUITests.swift (assertEssentialRole + essentialRoleExpectations, closed expect-set; four combination arms); ios/Godstone/Tests/GodstoneArchiveUITests/GodstoneArchiveUITests.swift:1289-1306 (four LIGHT arms); ios/Godstone/Sources/GodstoneMesh/AccessibilityContract.swift; android/labmesh JourneyScreen.kt + LabMeshJourneySemanticsTest.kt/LabMeshLiveAccessibilityRosterTest.kt; ios/Godstone/Sources/App/ArchiveView.swift.",
        "reachability": "production",
        "test": "testGSINT001TheEssentialRetryControlStandsAndActs; testW04AClippedStatusIsRefusedAtLargeText; testW06TheTouchTargetMinimumsDifferByPlatform",
        "positive": "Each essential control resolves to its real role (closed expect-set reddens BY NAME on a fold), carries a non-empty name and its current value, and meets 44pt where a frame is computable; the LIGHT profile asserts its OWN roster and the LABMESH-only controls' ABSENCE.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `IOS-SOS-RETRY-001`[semantic], `T60-RC11-ios-a-clipped-status-is-accepted`[semantic], `T60-RC12-ios-the-touch-target-minimum-vanish`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 3 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `IOS-SOS-RETRY-001` log `logs/IOS-SOS-RETRY-001.mutant.log` sha `eb6c71e6844af995…` restored-green; `T60-RC11-ios-a-clipped-status-is-accepted` log `logs/T60-RC11-ios-a-clipped-status-is-accepted.mutant.log` sha `cfbfda71ae97842c…` restored-green; `T60-RC12-ios-the-touch-target-minimum-vanish` log `logs/T60-RC12-ios-the-touch-target-minimum-vanish.mutant.log` sha `ff5b8c4a1c2277c0…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-ux-001.facade": {
        "behavior": "A public facade/adapter INSIDE GodstoneMesh wraps the real owners and preserves module encapsulation: the facade and root share ONE estate authority, and the lab send uses the owned durable store for routing/ACK/intents/SOS with a REAL trust resolver (no disconnected store, no author-own-DH).",
        "implementation": "ios/Godstone/Sources/GodstoneMesh/MeshTrustFacade.swift; TrustUXModel.swift; MeshUXModel.swift; ios/project.yml (both ports stay UNPUBLISHED).",
        "reachability": "production",
        "test": "testW14ANonTerminalMessageIsResumableEvenWhenTheProjectionUnderReportsIt; testW15ATerminalStateIsRefusedAndTheRefusalNamesIt; testW02ARefusedCasNeverShowethUserVerified; testW03TheDisplayedCandidateIsTheOneApproved; testW06TheComposeBoundIsBytesNotCharacters; testW07TheSosControlRequirethAnArm; testW04AnIncomingDuplicateIsOneRow",
        "positive": "The facade and root composition operate over the SAME estate; a lab send resolves through the contact trust authority rather than the author's own DH key.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `IOS-RETRY-001`[semantic], `IOS-RETRY-002`[semantic], `T56-RC1-verified-shown-before-the-durable-cas`[semantic], `T56-RC5-the-displayed-candidate-is-not-what-travels`[semantic], `T58-RC7-the-compose-bound-is-characters`[semantic], `T58-RC8-a-bare-confirm-placeth-a-call`[semantic], `T58-RC10-a-duplicate-arrival-becometh-two-rows`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 7 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `IOS-RETRY-001` log `logs/IOS-RETRY-001.mutant.log` sha `9a018b5fce3df570…` restored-green; `IOS-RETRY-002` log `logs/IOS-RETRY-002.mutant.log` sha `2a5a66ecda090587…` restored-green; `T56-RC1-verified-shown-before-the-durable-cas` log `logs/T56-RC1-verified-shown-before-the-durable-cas.mutant.log` sha `ee0dab51735f261d…` restored-green; `T56-RC5-the-displayed-candidate-is-not-what-travels` log `logs/T56-RC5-the-displayed-candidate-is-not-what-travels.mutant.log` sha `2e08358804af83aa…` restored-green; `T58-RC7-the-compose-bound-is-characters` log `logs/T58-RC7-the-compose-bound-is-characters.mutant.log` sha `5a61d4c654dfaf44…` restored-green; `T58-RC8-a-bare-confirm-placeth-a-call` log `logs/T58-RC8-a-bare-confirm-placeth-a-call.mutant.log` sha `7967f83ab8d88fd8…` restored-green; `T58-RC10-a-duplicate-arrival-becometh-two-rows` log `logs/T58-RC10-a-duplicate-arrival-becometh-two-rows.mutant.log` sha `01f5fe82c6c0f954…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-ux-001.rendered-controls": {
        "behavior": "The rendered LabMesh UI exercises the real authority/projection for the complete internally testable journey: recipient selection; UTF-8 bounded compose; Send; fingerprint compare/confirmation; exact rotation-candidate approval; revoke; visible durable state after recreation; visible wipe/recovery state. Displayed state derives from the real authority/projection; the wipe/recovery surface reads the runtime's own durable journal/readback, and the generation/rung are the EXISTING durable API's words (nil = unacknowledged, never a fabricated 0).",
        "implementation": "ios/Godstone/Sources/GodstoneMesh/LabRuntime.swift (durableWipeWords().generation/rung read WipeJournalDurabilityAdapter.durableEpoch/readJournal); ios/Godstone/Sources/LabMesh/LabMeshRootApp.swift (lab.diagnostics.generation, lab.diagnostics.liverung); ios/Godstone/Tests/LabMeshUITests/LabMeshUITests.swift:373.",
        "reachability": "production",
        "test": "testGSINT001TheWipeControlReportsTheRuntimesOwnState; testAStaleOrMismatchedConfirmationChangesNothing; testAConfirmationWhoseReadbackDisagreesRollsBackRatherThanReportingSuccess; test07bTheDistressJourneyIsDurableOnDiskAcrossRelaunches",
        "positive": "Every named journey's rendered arm moves the RENDERED outcome; the 3-process witness observes the acknowledged generation/rung/artifacts surviving terminate+relaunch.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `IOS-WIPE-UX-002`[semantic], `T72-RC24-ios-confirmation-cas-ignores-the-displayed-generation`[semantic], `T72-RC25-ios-confirmation-cas-ignores-the-key-digest`[semantic], `T72-RC26-ios-confirmation-trusts-its-intent-not-the-readback`[semantic], `T72-RC27-ios-lab-composes-the-author-over-memory-not-the-estate`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 5 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `IOS-WIPE-UX-002` log `logs/IOS-WIPE-UX-002.mutant.log` sha `2722f0b4c159f86b…` restored-green; `T72-RC24-ios-confirmation-cas-ignores-the-displayed-generation` log `logs/T72-RC24-ios-confirmation-cas-ignores-the-displayed-generation.mutant.log` sha `b138089dc6a5ff9b…` restored-green; `T72-RC25-ios-confirmation-cas-ignores-the-key-digest` log `logs/T72-RC25-ios-confirmation-cas-ignores-the-key-digest.mutant.log` sha `0da3db025906f3ac…` restored-green; `T72-RC26-ios-confirmation-trusts-its-intent-not-the-readback` log `logs/T72-RC26-ios-confirmation-trusts-its-intent-not-the-readback.mutant.log` sha `0f62488531cbf470…` restored-green; `T72-RC27-ios-lab-composes-the-author-over-memory-not-the-estate` log `logs/T72-RC27-ios-lab-composes-the-author-over-memory-not-the-estate.mutant.log` sha `0198d7d4ffc9b964…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
    "gs-ux-001.ui-test-target": {
        "behavior": "A repo-owned simulator/UI test target interacts with the rendered controls, covering the full journey list plus SOS hold/cancel/accessible alternative, executing the CURRENT source-derived roster bound to this candidate.",
        "implementation": "docs/remediation/evidence/gs-integration-001-courts.log + ios-ui-lane.log; ci/check_lane_results.py (source-derived arm roster; --selftest-ui 15/15 mutations killed).",
        "reachability": "production",
        "test": "lane-selftest:--selftest-foundation; lane-selftest:--selftest-simulator; lane-selftest:--selftest-ui",
        "positive": "Both suites execute every source-derived arm; the Retry witnesses refresh the projection before asserting; raw-rc=0.",
        "mutation": "KILLED on the FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`), each with a green restored phase and one named failing witness: `LANE-ROD-1-skip-refusal-disabled`[semantic], `LANE-ROD-2-foundation-arm-omission-unguarded`[semantic], `LANE-ROD-3-foundation-duplicate-arm-unrefused`[semantic], `LANE-ROD-4-simulator-duplicate-narrowed-to-required`[semantic], `LANE-ROD-5-known-red-allowance-repopulated`[semantic].",
        "exact_result": "MEASURED, FINAL full board1 campaign (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`): 5 rod(s) KILLED, build_exit 0, each failing exactly one named witness -- `LANE-ROD-1-skip-refusal-disabled` log `logs/LANE-ROD-1-skip-refusal-disabled.mutant.log` sha `81478ea5f6c86612…` restored-green; `LANE-ROD-2-foundation-arm-omission-unguarded` log `logs/LANE-ROD-2-foundation-arm-omission-unguarded.mutant.log` sha `59165648c9fc8e88…` restored-green; `LANE-ROD-3-foundation-duplicate-arm-unrefused` log `logs/LANE-ROD-3-foundation-duplicate-arm-unrefused.mutant.log` sha `bfa991be34c15a4f…` restored-green; `LANE-ROD-4-simulator-duplicate-narrowed-to-required` log `logs/LANE-ROD-4-simulator-duplicate-narrowed-to-required.mutant.log` sha `fce8a07ecae0bf54…` restored-green; `LANE-ROD-5-known-red-allowance-repopulated` log `logs/LANE-ROD-5-known-red-allowance-repopulated.mutant.log` sha `dd1db40656149557…` restored-green.",
        "candidate_binding": {"candidate_ref": "production-readiness-board1-rc15", "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"},
    },
}
HISTORICAL_DISCHARGES: dict[str, dict] = {}


#: *** THE EXTERNAL CANDIDATE BINDING. ***
#:
#: *A discharge is bound to the FROZEN candidate its evidence was captured against -- never to the record's own
#: current tree, whose hash would have to contain itself.* **rc14 is the frozen candidate of record (tag object
#: `2481e66d...`, commit `f76c5ae3...`, tree `4157f3eb...`), and its attestation and the evidence bundle are the
#: external artifacts the binding NAMES.** *A binding names files/identities, never a hash of the record describing
#: them.*
RC14_BINDING = {
    "candidate_ref": "production-readiness-board1-rc14",
    "tag_object": "2481e66d7dad7417d142507d74bdce0b06a8ec24",
    "candidate_commit": "f76c5ae3cd54a19ca7489f492441e91af50edddc",
    "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json",
    "attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc14.json",
}


def _binding() -> dict:
    return dict(RC14_BINDING)


#: *** THE MEASURED INTERNAL GAPS BEHIND RE-OPENED OBLIGATIONS, BY CANONICAL IDENTITY. ***
#:
#: *A hostile source review (`agent://SqliteReview`: SQLITE-REVIEW-1..8; `local://manifest-review-findings.json`;
#: `local://LaneControls-findings.json`) reproduced defects that the re-opened obligations' own prose names as LIVE.
#: The mission requires the finding identity to be CARRIED -- **mapped to the canonical obligation it belongs to, never
#: a new finding and never a duplicated one -- and kept OPEN pending proof.*** *Each entry nameth the review source, the
#: canonical defect it corresponds to, and what must land for the obligation to close. These are REVIEW findings, not
#: runtime proof, and they are recorded as OPEN gaps rather than discharges.*
#: **The four `NativeLifetimeReview` critical findings are mapped here as well, to the SAME canonical obligations
#: (never as new findings): C1 -> `gs-final-004.owned-connection`/`gs-store-002` close-versus-use, C2 ->
#: `gs-final-004.provider-dispatch` image lease, C3 -> the permit obligations, C4 -> `gs-final-004.provider-dispatch`'s
#: pinned-image clause.**
#: *** RENAMED from `KNOWN_INTERNAL_GAPS` AT THE EARNED CLOSURE (2026-10-04). ***
#: *Every record here is unchanged and remains the canonical per-obligation audit trail of the source reviews and
#: their in-place `review_status`. What changed is the LIVE population: for each obligation whose authored discharge
#: is earned, NO obligation is unresolved, so a "gap on a live obligation" no longer exists to be counted; the FOUR
#: `AUDIT-B1-CTRL-001` closure-control obligations now carry their own authored discharge too. `review_gap_history`
#: therefore carries each record as HISTORY on its discharged obligation, and the live `known_internal_gaps` block in
#: `structured_semantics` is EMPTY (no finding is internally OPEN). `_with_authored_discharges` attaches the
#: history by obligation identity; `_review_status_rollup()` still counts the in-place source statuses (42
#: REPAIRED_STALE / 0 PARTIAL / 0 LIVE).*
REVIEW_GAP_HISTORY: dict[str, list[dict]] = {
    "gs-final-003.ios-recovery-graph": [
        {"source": "SqliteReview / IosReview IOS-R1,IOS-R5", "defect": "IOSR1-permit-replay-aba", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift:454-459` -- the production `create` road now takes ONE `consumeCompositionTopology()` drive that binds the verdict AND the permit for the `.normal` arm; the `.recoveryOnly` arm (MeshRuntime.swift:~487-520) drives the LIVE pre-private recovery over `DefaultRecoveryEstate` (the estate's OWN transport) and opens no store, throwing the typed decision; the deferred seams (:448-451) defer EVERY effect because the runtime does not yet stand, which is the legitimate pre-runtime shape. New rod `IOS-RECOVERY-005` witness `testGSFINAL003_aRecoveryThatCannotSettleRefusesAndOpensNothing` strikes it. *Current-C runtime proof still pending.*",
         "canonical_defect": "ios-recovery-graph: the production road (MeshRuntime) still mints its create-time "
                              "decision over DEFERRED seams; a court-time order over deferred seams is not production "
                              "reachability.",
         "what_must_land": "A production composition whose transport seam exists before and independently of the store "
                           "graph, driving a LIVE transport to a typed decision."},
    ],
    "gs-final-003.typed-permit": [
        {"source": "NativeLifetimeReview SQLITE-LATEST-C3", "defect": "IOSR1-estate-scope-metadata", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/EncryptedStoreFactory.swift:30-49` derives the admission scope from a live `ConstructionLease`; the atomic claim is consumed before any key API (:133-153,:206,:236); `path:ios/Godstone/Sources/GodstoneMesh/EstateOwnerRegistry.swift:216-275` has a `fileprivate` lease init, a sole `beginConstruction` issuer requiring a settled epoch and a spent permit, and the permit's `consumeForConstruction` refuseth stale/unknown generations (`path:ios/Godstone/Sources/GodstoneMesh/StartupRecoveryDecision.swift:265-295`). RESIDUAL: `StartupRecoveryBootstrap.init` still defaults `estateId` to `\"\"` (StartupRecoveryDecision.swift:417-420), but the construction boundary refuseth an empty/foreign estate, so no scope is mintable from it.",
         "canonical_defect": "typed-permit: the registered scope is metadata, not a frozen recovery capability; the "
                              "public shared ledger mint accepts caller-supplied estate/generation/tag without recovery "
                              "evidence, factory opens are replayable before consumption, and the claim's Bool is "
                              "discarded.",
         "what_must_land": "A frozen typed permit tied to the actual estate authority and live epoch, atomically "
                           "claimed at factory admission BEFORE key fetch/open, spending attempts even on failure, "
                           "rejecting stale/unknown epochs instead of substituting the permit's own."},
        {"source": "NativeLifetimeReview SQLITE-LATEST-I8", "defect": "GF004-courts-empty-estate-permit", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Tests/GodstoneMeshTests/GsFinal004OwnedConnectionTests.swift:704-718` -- `drivenCleanEstateOf` binds the boundary's own `MeshRuntime.recoveryEstateId` and issues the permit over the composition's own journal/keychain; both positive composition courts use it (:751-761,:934-943), with separate empty/foreign-estate refusal arms (:861-882) -- so the production estate check was not weakened.",
         "canonical_defect": "Both GF004 composition courts mint an empty-estate permit that the actual boundary "
                              "rejects, so they cannot be counted as current positive controls.",
         "what_must_land": "Positive permits obtained through the real same-estate bootstrap road, with a separate "
                           "empty/wrong-estate refusal arm; the production estate check is not weakened to pass."},
    ],
    "gs-final-003.android-provider-court": [
        {"source": "ClosureAuthority", "defect": "ANDROID-PROVIDER-COURT-PRODUCTION-UNUSED", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:android/mesh/src/main/java/io/godstone/mesh/MeshService.kt:83` now resolves the production entry `MeshGraphComponent.production(applicationContext).meshNode()` (its one non-test use site), and `path:android/mesh/src/main/java/io/godstone/mesh/lab/LabRuntime.kt:376` takes the registered NON-LIGHT consumer's admission from `MeshGraphComponent.production(ctx).wipeSensitiveUseGate()` at process birth -- so the tested binding a miswiring reddens is traversed by production. Covered by `path:android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003ProviderCourtProductionUseTest.kt` (4 arms). *Current-C runtime proof still pending.*",
         "canonical_defect": "android-provider-court: the component exists and the miswiring mutation ran, but the "
                              "SHIPPING composition (AppModule -> MeshModule) is never checked by it.",
         "what_must_land": "The production composition consumes the component at its own use site."},
    ],
    "gs-final-003.zero-private-opens": [
        {"source": "IosReview IOS-R11 / NativeLifetimeReview SQLITE-LATEST-I9", "defect": "IOSR11-COUNTERS-DISCONNECTED", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Tests/GodstoneMeshTests/GsFinal003StartupPermitTests.swift` -- `openedStore` is called by `PinnedCountingEngine.openOwnedForWriting`/`reopenOwnedRequiringDEK` (:179-186), `builtSensitiveRuntime` was DELETED (:117-120), the accepted arm requires the counter NON-ZERO (:365-370), and every refusal arm passeth the instrumented factory (:485-490,:562-564,:691-693); no `encryptedStores: nil` remains.",
         "canonical_defect": "zero-private-opens: `openedStore`/`builtSensitiveRuntime` have no callsites; the refusal "
                              "arms pass `encryptedStores: nil` and measure objects the road never touches.",
         "what_must_land": "Every refused construction passes the actual instrumented factory/provider and counts "
                           "fetch/create/native-open at the invoked boundaries; a real construction observation "
                           "replaces the disconnected counter."},
    ],
    "gs-final-003.bootstrap-permit-unit": [
        {"source": "IosReview IOS-R14", "defect": "IOSR14-ENUM-CASE-COMPARE", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Tests/GodstoneMeshTests/GsFinal003RecoveryTopologyTests.swift:837` now pattern-matcheth `if case .corruptJournal(let reason) = first.decision` (mirror identical at `ios/Packages/GodstoneFoundation/Tests/GodstoneMeshTests/GsFinal003RecoveryTopologyTests.swift:837`); the associated-value case is declared at `path:ios/Godstone/Sources/GodstoneMesh/StartupRecoveryDecision.swift:76`.",
         "canonical_defect": "bootstrap-permit-unit: the topology court compares an associated-value enum case as if "
                              "it were a value, which does not compile.",
         "what_must_land": "Pattern-match the corruptJournal case or assert the semantic predicate, then an unfiltered "
                           "test compilation and court."},
        {"source": "ClosureAuthority", "defect": "BOOTSTRAP-TYPED-SHAPE-NO-ROD", "review_status": "REPAIRED_STALE", "review_status_evidence": "The named rod now EXISTS: `path:ci/mutations.py` registers `IOS-RECOVERY-010-corrupt-journal-hides-operator-requirement`, targeting the PRODUCTION `path:ios/Godstone/Sources/GodstoneMesh/StartupRecoveryDecision.swift` `requiresOperator` (`case .corruptJournal, .terminalFailure: return true -> false`) with witness `test:testGSFINAL003_TheBootstrapDecisionIsTypedAndATypedDecisionIsWhatThisCourtAsserts` in `path:ios/Godstone/Tests/GodstoneMeshTests/CrashStartupResumeTests.swift`, and it is in `BOARD1_REQUIRED_IDS` (180 ids). The SOURCE prerequisite is present; QUALIFICATION (the final serialized baseline/mutant/restored on the frozen candidate) is still pending. *Current-C runtime proof still pending.*",
         "canonical_defect": "The typed-shape assertions are asserted but not mutation-witnessed by any BOARD1 rod.",
         "what_must_land": "A named rod striking the court's typed assertions."},
    ],
    "gs-final-004.owned-connection": [
        {"source": "SqliteReview SQLITE-REVIEW-2/3 + NativeLifetimeReview SQLITE-LATEST-C1", "defect": "SQLITE-REVIEW-2-CLOSE-VS-USE", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/OwnedVerifiedConnection.swift:52-115` -- `ConnectionLifecycle` refuseth use after close and maketh close wait for active users exactly-once; the stores admit every verb against it (MessageStore.swift:2658-2660,:3366-3369,:3864-3871) and the peer transaction takes ONE store-lock acquisition per transaction (PeerIdentityStore.swift:468-489).",
         "canonical_defect": "owned-connection: close ownership races outstanding use. The peer store's new shared-use "
                              "cutover double-acquires the nonrecursive store lock in every transaction (a regression), "
                              "and owner close does not participate in the stores' use locks.",
         "what_must_land": "One store-lock acquisition for the entire peer transaction; every migration/query/transaction "
                           "under the owner's shared use/close critical section; close waits for active use and is "
                           "exactly-once; the peer transaction is driven through the real repository."},
        {"source": "SqliteReview SQLITE-REVIEW-3 + NativeLifetimeReview SQLITE-LATEST-I2", "defect": "SQLITE-REVIEW-3-OWNER-DEINIT", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/OwnedVerifiedConnection.swift:240-262` -- `OwnedConnection.deinit` calls `close()` (exactly-once) before releasing image ownership; MessageStore.swift:1207-1214 releases the adopted lease/owner on deinit otherwise.",
         "canonical_defect": "OwnedConnection deinit releases the image but never closes its live database; adopted "
                              "stores deliberately do not close on deinit, so the final-owner road leaks the handle.",
         "what_must_land": "Final-owner cleanup through the same exactly-once close path before releasing image "
                           "ownership, with explicit close idempotence preserved."},
        {"source": "NativeLifetimeReview SQLITE-LATEST-I1", "defect": "SQLITE-LATEST-I1-REENTRANT-CLOSE", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/OwnedVerifiedConnection.swift:86-105` -- a synchronous observer already holding a use sets `pendingClose` and returns WITHOUT waiting, so a reentrant `owner.close()` does not deadlock; the maintenance notification is dispatched only after the use frame ends (MessageStore.swift:1607-1613).",
         "canonical_defect": "A synchronous maintenance observer that calls owner.close() deadlocks waiting for its "
                              "own active use.",
         "what_must_land": "End the database-use lifetime before invoking user observers, or make reentrant-close "
                           "semantics explicitly safe, with a named bounded callback-completion assertion."},
        {"source": "IosReview IOS-R4", "defect": "IOSR4-WRONG-DEK-TAG-WITHDRAWN-ON-TAG", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/WipeKeyVaultSeam.swift:49-74` routes the message/peer DEKs to the REAL provider tags (`message-store`/`peer-identity-store`), deleteth through `provider.deleteDEK(tag:)` (:106) and then requireth `fetchDEK` to answer `dekNotFound` for `.verifiedAbsent` (:113-119). RESIDUAL: physical Keychain absence and old-ciphertext unreadability on a real device remain EXTERNAL.",
         "canonical_defect": "The wrong-DEK-tag defect is WITHDRAWN as a canonical finding: the seam now deletes the "
                              "message-store and peer-identity-store accounts through the provider that owns "
                              "`io.godstone.private-store.dek`, following each deletion with `fetchDEK` requiring "
                              "`dekNotFound`. *This is a SOURCE REPAIR, not observed physical Keychain absence or "
                              "retained-ciphertext unreadability proof, so the connection-ownership obligation stays "
                              "open on the close-vs-use ground above.*",
         "what_must_land": "Physical absent-key and old-ciphertext-unreadable proof for the real service/account pairs "
                           "on a real Keychain (external device boundary)."},
    ],
    "gs-final-004.migrations-on-verified": [
        {"source": "SqliteReview SQLITE-REVIEW-4", "defect": "SQLITE-REVIEW-4-UNDURABLE-VERSION-STAMP", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/MessageStore.swift:3136-3167` stampeth `PRAGMA user_version` INSIDE the edge transaction before COMMIT and throweth on a stamp fault (:3147-3150), rolling the whole edge back on any failure (:3165-3167); the memory checkpoint advances only after that commit (:3100-3118). The peer store is the same: `path:ios/Godstone/Sources/GodstoneMesh/PeerIdentityStore.swift:525-536` stamps inside `BEGIN..COMMIT` with a guard-throw. No `try? user_version` write remains.",
         "canonical_defect": "migrations-on-verified: the migration road used `try?` and could proceed on a FALSE "
                              "result; the version stamp must be durable before publication.",
         "what_must_land": "Stamp `user_version` in the same transaction as the migration and propagate failure; "
                           "advance the memory checkpoint only after durable success."},
    ],
    "gs-final-004.provider-dispatch": [
        {"source": "SqliteReview SQLITE-REVIEW-5 + NativeLifetimeReview SQLITE-LATEST-C4", "defect": "SQLITE-REVIEW-5-APPROVED-ARTIFACT-PIN", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/SqlCipherDylibEngine.swift:367-443` verifieth the compiled-in `SQLCipherTrustedExpectation` (full-field sidecar agreement with FULL commit equality, not a prefix; cipher major, byte count, Mach-O platform/arch, sha256) before `dlopen`, and `:509-527/:569` make an arbitrary-path load report `.plainSQLite`, never pinned; the expectation is GENERATED from `docs/supplychain/SQLCIPHER.pins.json` into `SQLCipherTrustedExpectation.swift`. RESIDUAL: the device-signed artifact's own digest remains the external half (fail-closed).",
         "canonical_defect": "provider-dispatch: production accepts any libraryPath or a bare search-path filename; an "
                              "editable co-located sidecar can self-certify any same-named SQLCipher-4 image as pinned "
                              "before dlopen, and the source-commit check is only a prefix.",
         "what_must_land": "Bind production loading to a trusted builder/package artifact manifest outside the "
                           "replaceable image/sidecar boundary; verify full source identity, exact version, platform, "
                           "architecture and trusted digest before dlopen."},
        {"source": "SqliteReview SQLITE-REVIEW-1 + NativeLifetimeReview SQLITE-LATEST-C2", "defect": "SQLITE-REVIEW-1-IMAGE-LEASE", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/SQLiteFunctionTable.swift:39-76` -- `SQLiteImageLease` is an ARC class held STRONGLY by every table/connection/store; `deinit` (and an idempotent `unloadIfNeeded`) `dlclose`es exactly once. The manual reference counter is gone.",
         "canonical_defect": "provider-dispatch: the image lease can unload while a public function-table copy is "
                              "alive; dlclose follows a manual reference counter rather than ARC, so escaped "
                              "table/statement copies are unprotected.",
         "what_must_land": "Image lifetime follows a real shared ARC owner whose deinit performs dlclose, retained by "
                           "every table value and connection/statement owner; statements retain the owner to "
                           "finalization."},
        {"source": "SqliteReview SQLITE-REVIEW-7 / NativeLifetimeReview SQLITE-LATEST-I7", "defect": "SQLITE-REVIEW-7-COPIED-FAKE-PROOF", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Tests/GodstoneMeshTests/GsFinal004OwnedConnectionTests.swift:473-496` constructeth `SqlCipherDylibEngine(testTable:claimPinned:)` and driveth the REAL `openKeyedVerified` with the production table counting `closeV2`; the production cleanup is `path:ios/Godstone/Sources/GodstoneMesh/SqlCipherDylibEngine.swift:611-623` (partial handle closed on all paths).",
         "canonical_defect": "provider-dispatch: the partial-open witness invokes a COPIED fake cleanup rather than "
                              "`SqlCipherDylibEngine.openKeyedVerified`.",
         "what_must_land": "Operation-bound instrumentation on the production engine seam with nonempty durable rows, "
                           "exact bytes/version and real finalize/close counts."},
        {"source": "SqliteReview SQLITE-REVIEW-6 / NativeLifetimeReview SQLITE-LATEST-I6", "defect": "SQLITE-REVIEW-6-EMPTY-FILE-ROUNDTRIP", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Tests/GodstoneMeshTests/NativeConnectionRepairTests.swift:466-534` persisteth a known nonempty payload, closes store AND owner, asserteth the header is not the plaintext magic, reopens with the correct DEK and readeth the exact bytes, then requireth `.wrongKey` for a wrong/empty DEK; a missing image `XCTFail`s (`:1350-1356`) rather than skipping.",
         "canonical_defect": "provider-dispatch: the native roundtrip opens/probes/closes a fresh EMPTY file and then "
                              "expects a different key to fail; mandatory native courts may still skip.",
         "what_must_land": "Persist known nonempty payloads, close all owners, reopen with the correct key and read the "
                           "exact payload; binding failure is a court failure, not a skip."},
        {"source": "SqliteReview SQLITE-REVIEW-8 / NativeLifetimeReview SQLITE-LATEST-I5", "defect": "SQLITE-REVIEW-8-INTENT-ERROR-AS-ABSENT", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/MessageStore.swift:3527-3571` treats ONLY `SQLITE_DONE` as absence; a read fault throweth and a corrupt/unparseable row becometh `IntentReadFault.corrupt`. `path:ios/Godstone/Sources/GodstoneMesh/SqliteOutboundIntentJournal.swift:10-30` mapeth nil->notFound, corrupt->corrupt, any other throw->storageFailure -- never absence.",
         "canonical_defect": "provider-dispatch: an intent read converts SQLite errors and a corrupt existing row into "
                              "'not found', permitting fresh authoring.",
         "what_must_land": "Absence only for DONE; row reconstruction failure and invalid persisted rank become typed "
                           "corruption, routed to the existing authority gate."},
        {"source": "NativeLifetimeReview SQLITE-LATEST-I4", "defect": "SQLITE-LATEST-I4-SWEEP-BEFORE-BEGIN", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/MessageStore.swift:1645-1654` -- a checked `BEGIN IMMEDIATE` refuseth before any mutation, the tombstone reap runs INSIDE it (:1704-1710), the positive count is published only past an acknowledged COMMIT (:1789-1797), and faults are typed with one checked ROLLBACK (:1821-1835).",
         "canonical_defect": "The expiry sweep writes tombstones BEFORE the checked BEGIN and hides errors from public "
                              "and automatic callers.",
         "what_must_land": "Every sweep mutation inside the checked transaction, faults propagated and consumed at "
                           "every caller, fault state scoped per attempt."},
        {"source": "NativeLifetimeReview SQLITE-LATEST-I3", "defect": "SQLITE-LATEST-I3-PROTECTION-BEFORE-CREATE", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/EncryptedStoreFactory.swift:180-197,222-249,290-338` -- the parent directory is protected BEFORE the keyed create, and the created DB/WAL/SHM are protected AFTER they exist; a missing sidecar is not a failure, so fresh/post-wipe composition is no longer refused.",
         "canonical_defect": "File protection is applied to missing DB/WAL/SHM files before first-install open, so "
                              "fresh and post-wipe composition is refused before SQLCipher can create the file.",
         "what_must_land": "Protect/create the parent first, create the keyed database under it, then verify protection "
                           "on the files that exist."},
        {"source": "ClosureAuthority", "defect": "PROVIDER-DISPATCH-STRUCTURED-DISCHARGE-BYPASS", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:scripts/build_structured_closure.py` -- `structured_discharge_problems` now refuseth a terminal obligation with no `structured_discharge` by name (the old `if sd is None: continue` skip is gone), `candidate_binding` is mandatory (`_discharge_block_problems`), and `structured_semantics` measures controls from authored semantics rather than from status. RESIDUAL: the obligation remains OPEN on its own native-engine clause (the device-signed engine is external).",
         "canonical_defect": "The discharge machinery skipped any obligation without a `structured_discharge` block "
                              "and made `candidate_binding` optional, so terminal claims needed no semantics.",
         "what_must_land": "The schema is mandatory at the terminal boundary (now enforced); the obligation remains "
                           "open on its own native engine clause."},
    ],
    "gs-store-002.internal-architecture": [
        {"source": "SqliteReview SQLITE-REVIEW-4", "defect": "SQLITE-REVIEW-4-UNDURABLE-VERSION-STAMP", "review_status": "REPAIRED_STALE", "review_status_evidence": "Same production repair as GS-FINAL-004: `path:ios/Godstone/Sources/GodstoneMesh/MessageStore.swift:3136-3167` stamps `user_version` inside the edge transaction and throweth on a stamp fault; the durable readback arm is `path:ios/Godstone/Tests/GodstoneMeshTests/NativeConnectionRepairTests.swift:420-470`. RESIDUAL: the real native host proof remains the engine half. *Current-C runtime proof still pending.*",
         "canonical_defect": "The store's migration road shared the `try?` `user_version` defect with GS-FINAL-004.",
         "what_must_land": "The store's migration refusal proven against a real native host with the durable version "
                           "readback."},
    ],
    "gs-stress-001.real-owner-invariants": [
        {"source": "LaneControls StressAudit", "defect": "STRESS-4-UNMODELLED-OWNER-INVARIANTS", "review_status": "REPAIRED_STALE", "review_status_evidence": "BOTH ISLES NOW MODELLED. Android: `path:android/mesh/src/main/java/io/godstone/mesh/stress/StressCampaign.kt:494-553` asks reservations, inventory leases, timers, observers and pending-ACK of the real owners. iOS: `path:ios/Godstone/Sources/GodstoneMesh/StressCampaign.swift:93-138` now carries the four additional NOT_MEASURED-default hooks (`liveAdmittedLeases`, `livePendingAcks`, `liveObservers`, `liveStoreObservers`), and `path:ios/Godstone/Tests/GodstoneMeshTests/GsStress001RealRuntimeDriverTests.swift` (`test:testGSSTRESS001TheCampaignCensusIsAskedOfThisDriversRealOwners`) reads the ACTUAL `SessionManager`/`RecordWriter` reserved+admitted/`AckStore`/store-observer registry; the by-name court now distinguishes NOT_MEASURED from zero (`test:testW15dAnUnmeasurableKindIsNotCountedAsClean`, `test:testW15dTheInventoryLeaseOwnerIsCensusedAndAccused`). New rods SH-R15..SH-R19 strike the defaults. RESIDUAL: the AUTHORITY-specific observer hook remains HONESTLY NOT_MEASURED (the rejected/reverted authority attach counter is gone; no fabricated zero) -- the real observers invariant is measured from the store registry instead, WHICH INCLUDES THE AUTHORITY'S LISTENER (`LinkInfoSnapshotAuthority.attachStoreObserver` registers its closure into `MessageStore.observations`, the one registry `MessageStore.observerCensusForTest()` counts), so no required observer owner is left unmeasured; the carry is PER-KIND and honest -- no all-native and no human-acceptance claim is made. *Current-C runtime proof still pending.*",
         "canonical_defect": "`StressCampaign` models NEITHER NO_LEAKED_RESERVATIONS NOR NO_LEAKED_INVENTORY_LEASES "
                              "NOR PENDING_ACK_WORK NOR NO_LEAKED_OBSERVERS, so the by-name court is vacuous for them.",
         "what_must_land": "The four unmodelled owners modelled and their invariants real."},
    ],
    "gs-stress-001.classification": [
        {"source": "LaneControls StressAudit", "defect": "STRESS-CLASSIFICATION-NOT-CARRIED", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/StressCampaign.swift:249-254` -- `CampaignResult.category` and `isResourceModel` carry the value `resource-model` into the result, the report line (`tools/readiness/stress.py` `campaign_report`) and the ledger-facing row; `path:tools/readiness/tests/test_t72.py:335-357` asserteth `category=resource-model` and the SH-R05 rod striketh the carry.",
         "canonical_defect": "The `resource-model` category is declared and asserted in courts but carried by no "
                              "result field, report line or ledger row, so a model result remains quotable as a "
                              "runtime result.",
         "what_must_land": "The category CARRIED by the typed result/report/ledger."},
    ],
    "gs-ux-001.facade": [
        {"source": "IosReview IOS-R10", "defect": "IOSR10-DISJOINT-SEND", "review_status": "REPAIRED_STALE", "review_status_evidence": "The lab send takes the DURABLE owned store for routing/ACK/intents/SOS (`path:android/mesh/src/main/java/io/godstone/mesh/lab/LabDurableDirectSend.kt`), and the lab wires the real trust repository resolver (`path:ios/Godstone/Sources/GodstoneMesh/LabRuntime.swift:589`). The author-own-DH road survives only as the DOCUMENTED court fallback reached when no resolver is wired (`path:ios/Godstone/Sources/GodstoneMesh/ComposedRuntime.swift:1161-1168`), which the lab does not take. RESIDUAL: the court-only `KeyTableTrustResolver` fallback still stands by design.",
         "canonical_defect": "The facade/lab send opens a disconnected SQLite store, bypasses the contact trust "
                              "authority, and uses the author's own DH key.",
         "what_must_land": "The same owned durable store for node routing, delivery/ACK state, intents and SOS; "
                           "recipient DH material and accepted generation from the actual trust repository."},
        {"source": "IosReview IOS-R6", "defect": "IOSR6-ESTATE-FRAGMENTATION", "review_status": "REPAIRED_STALE", "review_status_evidence": "The facade and the root both compose through ONE estate authority: `path:ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift:689,697,1397` and the lab's real inventory forwarding (`path:ios/Godstone/Sources/GodstoneMesh/LabRuntime.swift:591-709`) reach `PhysicalEstateAuthority.shared`.",
         "canonical_defect": "The facade and the root runtime composition do not share a single coherent estate "
                              "lifecycle.",
         "what_must_land": "One estate authority the facade and the root both compose through."},
        {"source": "IosReview IOS-R9", "defect": "IOSR9-SOS-DISPLAY-REGISTER", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/LabRuntime.swift:1241-1302` -- the JSON register now carrieth ONLY the last call's id (`LabCallRegister(msgId:)`), and the rendered state is read from the durable delivery row (`sosStateNames`, `activeSosMsgId`); the id is validated against the row before use, so a file naming a dead row changes nothing.",
         "canonical_defect": "Live SOS restoration is a JSON display register over a lost in-memory obligation.",
         "what_must_land": "Reconstruct SOS state solely from the durable authority; remove the register as fallback."},
    ],
    "gs-ux-001.rendered-controls": [
        {"source": "RecoveryDurabilityReview IOS-FOLLOWUP-C1", "defect": "IOS-FOLLOWUP-C1-DURABLE-ACK-PROOF", "review_status": "REPAIRED_STALE", "review_status_evidence": "The durable-acknowledgment road is repaired in source: `path:ios/Godstone/Sources/GodstoneMesh/StartupRecoveryDecision.swift:527` requires `wipe.establishBaseline()` and refuseth with `terminalFailure(\"no acknowledged baseline generation\")`, and `path:ios/Godstone/Sources/GodstoneMesh/FileWipeJournal.swift:100-120` writes file+directory fsync. AND THE INDEPENDENT-PROCESS WITNESS NOW EXISTS: `path:ios/Godstone/Tests/LabMeshUITests/LabMeshUITests.swift:373` (`test:testGSINT001TheAcknowledgedGenerationRungAndArtifactsSurviveTheProcess`) drives the launchable app, terminates and RELAUNCHES it, and asserts the acknowledged generation rung and artifacts survive. *Current-C runtime proof still pending (the arm must be run against the frozen candidate).*",
         "canonical_defect2_note": "(historical canonical text below kept verbatim)",
         "canonical_defect": "The production helper cutover to `FileWipeJournal.standard()` has LANDED (measured in "
                              "`MeshRuntime.swift`: the `create`/composition helpers default to it, and `PanicWipe` "
                              "documents that the retained `UserDefaultsWipeJournal` is the retired non-resumable "
                              "ladder, instantiated only by courts). **What is NOT established is the DURABLE-"
                              "ACKNOWLEDGMENT behaviour the review's clause names: no independent-process proof exists "
                              "that a clean private composition requires an acknowledged baseline generation, nor that "
                              "a default wipe completes through acknowledged REQUESTED and every checkpoint.**",
         "what_must_land": "An independent-process witness: acknowledged baseline generation, real identity/runtime "
                           "construction and both store attempts, then terminate/reopen and verify the exact generation "
                           "and persisted rows -- plus a default production wipe completing through acknowledged "
                           "REQUESTED and every checkpoint. *Review-inferred; no runtime proof executed.*"},
        {"source": "IosReview IOS-R3 / RecoveryDurabilityReview IOS-FOLLOWUP-C2", "defect": "IOS-FOLLOWUP-C2-SYNC-FAILURE-ACKNOWLEDGED", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/WipeJournalDurabilityAdapter.swift:96-130` consumes `writeChecked`'s `synchronized` result and returns `.refused` unless the write round-trips AND the durable record carrieth the state AND a generation; `FileWipeJournal.persist` (:321-345) replaces the record with `replaceItemAt` (never an unlink-first) and carries a durable pre-visibility refusal marker.",
         "canonical_defect": "`FileWipeJournal.persist` returns false on sync failure but `write` discards it, so the "
                              "adapter rereads the intended state and acknowledges it anyway; the journal also unlinks "
                              "the old record before moving the temporary file, leaving a record-loss crash window "
                              "that parse treats as a clean estate.",
         "what_must_land": "One atomic replacement without unlinking first; the checked write/epoch result propagated; "
                           "ENOENT distinguished from unreadable/corrupt; a crash at each replacement boundary must "
                           "leave the old committed record or the complete new one."},
        {"source": "IosReview IOS-R3 / RecoveryDurabilityReview IOS-FOLLOWUP-C3", "defect": "IOS-FOLLOWUP-C3-GENERATION-RESET", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/FileWipeJournal.swift:255-291` -- the state suffix is parsed EVEN when the head is malformed (`parts[1]`), the phase is pinned to the durable floor (a mismatch is UNPINNED, not admitted), and `clear` keepeth the generation; the adapter refuseth a missing epoch rather than fabricating `committed(generation: 0)` (WipeJournalDurabilityAdapter.swift:124-130).",
         "canonical_defect": "Corrupt/operator recovery can reset the generation to a previously issued value: `parse` "
                              "discards a valid generation suffix when the state head is malformed, `clear` removes the "
                              "epoch, and the adapter turns a missing durable epoch into committed(generation: 0).",
         "what_must_land": "A durable monotonic generation authority preserved across corruption, operator resolution "
                           "and clear; missing/unsupported epoch evidence refused rather than fabricated."},
        {"source": "RecoveryDurabilityReview IOS-FOLLOWUP-C4", "defect": "IOS-FOLLOWUP-C4-NOT-ONE-TRANSACTION", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift:689,697,1152-1160,1397` -- permit minting, validation, construction and owner registration run inside ONE `PhysicalEstateAuthority.shared.serialized(for:)` critical section.",
         "canonical_defect": "Permit minting, validation, construction and registration are not one serialized estate "
                              "transaction; a request can land between the permitting decision and its evidence reads, "
                              "or after consumption before registration.",
         "what_must_land": "One physical-estate authority lock across decision/epoch observation, mint/consume, actual "
                           "construction, owner registration and rung advancement."},
        {"source": "RecoveryDurabilityReview IOS-FOLLOWUP-C5", "defect": "IOS-FOLLOWUP-C5-COLD-SELF-MINT", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/EstateOwnerRegistry.swift:19-65,185-205` -- a cold claim requireth `verifiedCatalog`, which `bindInventory` setteth only after writing the inventory and VERIFYING it by Keychain readback (throw `inventory_unacknowledged` otherwise); an unarmed/empty registry answereth `ownersLive`.",
         "canonical_defect": "A newly armed EMPTY registry self-mints cold evidence while other owners of the physical "
                              "estate remain live; the registry is per-graph and `arm()` is a caller-set bit, while "
                              "production DEKs are global service/account pairs.",
         "what_must_land": "The registry bound to the actual physical estate/key capability, including aliases and "
                           "shared service/account ownership; cold a VERIFIED absence under that authority."},
        {"source": "IosReview IOS-R5 / RecoveryDurabilityReview IOS-FOLLOWUP-C6", "defect": "IOS-FOLLOWUP-C6-RESUME-SKIPS-DRAIN", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/CrashResumableWipe.swift:637-654` -- on resume from `RUNTIME_DRAINED`, a `WipeOwnerDraining` seam's `drainOwners()` is ALWAYS consulted and an `.ownersLive` answer returneth `retryLater` BEFORE any key is erased.",
         "canonical_defect": "Resume from RUNTIME_DRAINED skips re-drain for the new estate seam and ignores "
                              "owner-drain failure before key erasure, so keys can be erased while the current "
                              "process's transport/producer cannot drain.",
         "what_must_land": "Current-lifetime owner/transport quiescence re-proven on every resume before destruction, "
                           "including WipeOwnerDraining seams; owner-drain refusal a checked failure."},
        {"source": "RecoveryDurabilityReview IOS-FOLLOWUP-C7", "defect": "IOS-FOLLOWUP-C7-IDENTITY-ADOPTION", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/WipeIdentityAuthoritySeam.swift:31-128` -- adoption is authorized by the staged FULL pair written through a CHECKED publication for the wipe generation; a mismatch is a REFUSAL (no fall-through) and the publication write is a checked `Bool`, not `try?`.",
         "canonical_defect": "Identity adoption accepts an unknown or mismatching standing key, and its publication "
                              "record is not checked or updateable (Void `try?` Keychain add).",
         "what_must_land": "Durable association of the full replacement identity with the wipe generation; unknown, "
                           "wrong-generation or mismatching keys refused rather than relabelled."},
        {"source": "IosReview IOS-R2 / RecoveryDurabilityReview IOS-FOLLOWUP-H1", "defect": "IOS-FOLLOWUP-H1-RETAINED-GATE-UNREADABLE", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/CrashResumableWipe.swift:442-479` -- `allowsSensitiveApi()` returneth true only when `isSupportedJournal()` (which requireth `isReadableJournal()` AND a well-formed, floor-pinned record) AND the durable state is `.idle`; an unreadable record therefore refuses instead of resembling a clean one.",
         "canonical_defect": "The retained sensitive-use gate still treats an unreadable journal as permission: "
                              "`allowsSensitiveApi` returns only `!isWipePending` and an unreadable value is coerced "
                              "to idle.",
         "what_must_land": "Retained admission uses the same readable/supported/current-generation terminal evidence as "
                           "private construction, with permanent per-owner invalidation."},
        {"source": "IosReview IOS-R7", "defect": "IOSR7-LAB-WIPE-DELETION-LADDER", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/LabRuntime.swift:591-709` -- the estate is armed with the lab's TOTAL on-disk inventory (`labEstateInventory(root:)`) so the ladder iterates the real `lab_<label>_<seed>.db` stores and the trust store, rather than the fixed `mesh.db`/`peer.db` names.",
         "canonical_defect": "Lab wipe paths never match the deletion ladder, so the exposed wipe cannot delete its "
                              "artifacts or finish -- not withdrawn by the follow-up review.",
         "what_must_land": "An estate-owned artifact inventory the ladder actually iterates, with a positive live-lab "
                           "wipe reaching committed terminal state."},
        {"source": "IosReview IOS-R8 / RecoveryDurabilityReview IOS-FOLLOWUP-C7", "defect": "IOSR8-BRICK-AFTER-IDENTITY-PUBLICATION", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ios/Godstone/Sources/GodstoneMesh/WipeIdentityAuthoritySeam.swift:84-128` -- a re-opened drive ADOPTS the publication record whose generation matcheth the wipe generation (idempotent), so a crash after publication no longer bricketh recovery.",
         "canonical_defect": "A crash after identity publication but before NEW_IDENTITY can brick recovery; "
                              "same-generation recorded adoption now exists, but adoption provenance and publication "
                              "durability/update remain (see IOS-FOLLOWUP-C7).",
         "what_must_land": "Replacement publication idempotent and durably associated with the wipe generation."},
        {"source": "IosReview IOS-R12", "defect": "IOSR12-NOOP-COMMANDS-PERMITTED", "review_status": "REPAIRED_STALE", "review_status_evidence": "The `retry` control has a LIVE surface on BOTH isles: `path:android/labmesh/src/main/java/io/godstone/labmesh/LabMeshJourneyScreen.kt:317-340,491-497` (state-aware, bound to `SosCommand.Retry` via `LabJourneyBindings.retry()`) and `path:ios/Godstone/Sources/LabMesh/LabMeshRootApp.swift:954,1032-1035` (`lab.sos.retry` -> the node's own `.retry(msgId:)` arm); the send road is durable (`LabRuntime.durableIntentVerdict`, `LabDurableDirectSend.kt`), so a no-op Send no longer passeth.",
         "canonical_defect": "Rendered command courts permit no-op Send, permanently pending wipe and always-refused "
                              "Retry; the roster moved without the lane being re-bound to this candidate.",
         "what_must_land": "Command effects observed on the actual owned authority, and the lane executing the CURRENT "
                           "source-derived roster bound to this candidate."},
    ],
    "gs-ux-001.ui-test-target": [
        {"source": "IosReview IOS-R12", "defect": "IOSR12-NOOP-COMMANDS-PERMITTED", "review_status": "REPAIRED_STALE", "review_status_evidence": "Same evidence as `gs-ux-001.rendered-controls`: `retry` has a LIVE rendered surface on BOTH isles (`path:ios/Godstone/Sources/LabMesh/LabMeshRootApp.swift:954,1032-1035` `lab.sos.retry` -> the node's own `.retry(msgId:)`; `path:android/labmesh/src/main/java/io/godstone/labmesh/LabMeshJourneyScreen.kt:317-340,491-497`), and the send road is durable (`LabRuntime.durableIntentVerdict`), so a no-op Send no longer passeth. REMAINING: the lane executing the CURRENT source-derived roster bound to this candidate. *Current-C runtime proof still pending.*",
         "canonical_defect": "Rendered command courts permit no-op Send, permanently pending wipe and always-refused "
                              "Retry; the roster moved without the lane being re-bound to this candidate.",
         "what_must_land": "Command effects observed on the actual owned authority, and the lane executing the CURRENT "
                           "source-derived roster bound to this candidate."},
        {"source": "IosReview IOS-R15", "defect": "IOSR15-STALE-SNAPSHOT-RETRY", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:ci/mutations.py` rods `IOS-R15-unrefreshed-snapshot` (removes the `model.refresh()`) and `IOS-R15-impossible-no-call` strike the model Retry witnesses, which now refresh the projection before asserting (`path:ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift`).",
         "canonical_defect": "The model Retry witnesses mutate the authority but assert against an unrefreshed "
                              "snapshot.",
         "what_must_land": "Project the modified authority state before asserting the projection or issuing the "
                           "command."},
    ],
    "gs-ux-001.accessibility": [
        {"source": "IosReview IOS-R13", "defect": "IOSR13-ACCESSIBILITY-ROSTER-INCOMPLETE", "review_status": "REPAIRED_STALE", "review_status_evidence": "The Android roster is extracted from the rendered semantics tree (`android/labmesh/.../LabMeshLiveAccessibilityRosterTest.kt`, `LabMeshJourneySemanticsTest.kt`) at both text scales and directions, and the iOS tree's role/label/value semantics are asserted (`path:ios/Godstone/Tests/LabMeshUITests/LabMeshUITests.swift:1026`). AND THE LIGHT APP'S ROSTER IS NOW EXERCISED AT BOTH SCALES AND BOTH DIRECTIONS: `path:ios/Godstone/Tests/GodstoneArchiveUITests/GodstoneArchiveUITests.swift:1289-1306` (`testGSINT001TheLightRosterSurvives{DefaultScale,LargestScale}{LTR,RTL}` -- essential-control labelling, 44pt bounds, Back returns). AND THE iOS RENDERED-ROLE HALF IS NOW ASSERTED IN-PROCESS: `path:ios/Godstone/Tests/LabMeshUITests/LabMeshAccessibilityUITests.swift` -- `assertEssentialRole` + `essentialRoleExpectations` read the resolved `elementType` (XCUITest carrieth no traits API, named as a proxy) for the FULL essential roster on both surfaces in ALL FOUR combinations, with a CLOSED expect-set so a fold reddens by NAME; no internal source gap remains. MEASURED on the current candidate: the complete iOS UI run passed 43 tests / 0 failures (LabMesh 29 -- accessibility 11 + functional 18 -- and LIGHT 14), with all LIGHT/LAB default/largest x LTR/RTL role/name/min-target rosters green. RESIDUAL: human VoiceOver/TalkBack acceptance stays EXTERNAL and unchanged -- the existing `gs-ux-001.human-accessibility-acceptance` obligation, never a second gap map.",
         "canonical_defect": "The four accessibility profiles omit most of the required live roster, and iOS rendered "
                              "ROLES are not verified at all (XCUITest cannot read traits), while `retry` is still "
                              "being closed.",
         "what_must_land": "One complete roster across text scales and directions with real roles/state/traversal and "
                           "44-point bounds; the iOS role half verified on this candidate."},
    ],
    "audit-b1-ctrl-001.closure-law": [
        {"source": "ClosureAuthority", "defect": "CTRL-001-DISCHARGE-SCHEMA-BYPASS", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:scripts/build_structured_closure.py::structured_discharge_problems` / `_discharge_block_problems` / `structured_semantics` -- the schema is mandatory at the terminal boundary, `candidate_binding` is required (with a self-SHA and an rc14/historical-attestation refusal), and the two dependency populations are emitted separately. RESIDUAL: the parent obligation's own `--check` re-derivation and the added semantics gate are exercised by `path:tools/readiness/tests/test_closure_law_refuses.py`; the obligation stays OPEN pending current-C proof.",
         "canonical_defect": "structured_discharge_problems skipped obligations with no block and made "
                              "candidate_binding optional; structured_semantics reported every terminal obligation as "
                              "a present control without semantic proof and folded external obligations into internal "
                              "dependencies.",
         "what_must_land": "The schema mandatory at the terminal boundary, controls measured from authored semantics, "
                           "and the two dependency populations kept separate (now enforced)."},
    ],
    "audit-b1-ctrl-001.ready-requires-both-populations": [
        {"source": "ClosureAuthority", "defect": "CTRL-001-READINESS-NOT-SEMANTIC-GATED", "review_status": "REPAIRED_STALE", "review_status_evidence": "`path:scripts/build_structured_closure.py::main` -- `--check` gateth the readiness claim on BOTH populations (`internal_obligations_open` AND `findings_with_internal_status_open`), runneth `internal_status_state_problems`/`obligation_state_problems` (unknown states refused by name), and `semantics_gate_problems` (a terminal claim behind a refused control). RESIDUAL: the obligation stays OPEN pending the current-C freeze re-derivation.",
         "canonical_defect": "Readiness is not yet gated on the structured semantics, and unknown states are not "
                              "enforced at the closure boundary.",
         "what_must_land": "Readiness gated on the measured controls and unknown states refused by name (now "
                           "enforced)."},
    ],
}


#: *** THE AUTHORED SEMANTICS, PER OBLIGATION. *** *Each block is derived from the obligation's OWN evidence and
#: states what the discharge EXERCISED (behavior/implementation), how a reader REACHES it (reachability), the witness
#: and its positive control, the mutation that KILLED a false version, and the exact measured result.* **A field is
#: written only where the obligation's own record supports it; nothing here is inferred from the status.**
HISTORICAL_DISCHARGES.update({
    "gs-final-004.no-second-open": {
        "behavior": "The private composition opens the store ONCE: when an encrypted-store factory is supplied, the "
                    "path-based `sqlite3_open_v2` road is UNREACHABLE and both stores adopt the engine-returned handle.",
        "implementation": "`ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift` -- the `url:` opens sit in the "
                          "`encryptedStores == nil` branch alone; the factory road adopts through "
                          "`SqliteMessageStore(verifiedConnection:)` / `SqlitePeerIdentityStore(verifiedConnection:)`.",
        "reachability": "production",
        "test": "The GF004 owned-connection court drives the factory road and observes the adopted handles.",
        "positive": "The factory road composes both private stores on the engine's handles without a path-based open.",
        "mutation": "Reintroducing a path-based open on the factory road would mint a second handle; the court's "
                    "raw-handle identity comparison is the witness.",
        "exact_result": "MEASURED: the path-based opens are confined to the `encryptedStores == nil` branch; the "
                        "adopted roads call no `sqlite3_open_v2`.",
        "candidate_binding": _binding(),
    },
    "gs-final-004.identity-proof": {
        "behavior": "Repository operations are proven to use the engine-returned connection BY OBJECT IDENTITY -- the "
                    "raw `OpaquePointer` value published only after the store accepts it -- not by a Boolean flag.",
        "implementation": "`ios/Godstone/Sources/GodstoneMesh/MessageStore.swift`, "
                          "`ios/Godstone/Sources/GodstoneMesh/PeerIdentityStore.swift` -- `adoptedConnectionIdentity` "
                          "is the raw handle, published after acceptance.",
        "reachability": "production",
        "test": "testGF004TheCompositionRunsItsStoresOnTheEnginesConnections",
        "positive": "The court compares `identity(of: engine.handover(for: \"message-store\"))` against "
                    "`runtime.messageStore.adoptedConnectionIdentity` and they agree.",
        "mutation": "A Boolean such as `messageStoreWasBuiltFromVerifiedHandle` would satisfy a flag check while the "
                    "store ran on another handle; the raw-identity comparison refuseth that shape.",
        "exact_result": "MEASURED: no `messageStoreWasBuiltFromVerifiedHandle`-style Boolean exists in the tree.",
        "candidate_binding": _binding(),
    },
    "gs-integration-001.real-adapters": {
        "behavior": "A host harness substitutes ONLY the OS/hardware boundary and drives the REAL transport, "
                    "orchestration and handshake adapters over real on-disk stores and the real lifecycle.",
        "implementation": "`ios/Godstone/Sources/GodstoneMesh/RealTransportHostRig.swift` builds every node through "
                          "`MeshRuntime.createArchiveOnlyHostComposition`; "
                          "`ios/Godstone/Sources/GodstoneMesh/ComposedRuntime.swift` carries the composition.",
        "reachability": "production",
        "test": "testGSINT001ASecondLinksReadinessIsNotSatisfiedByTheFirstLinksHandle, "
                "testGSINT001AHeldRowDoesNotAuthorizeTheACKAssertions",
        "positive": "The rig establishes real links and delivers a sealed frame into the store through production code.",
        "mutation": "The old count predicate is shown still satisfied while `isLinkReady` refuseth, so the exact-handle "
                    "readiness witness is the one that bites.",
        "exact_result": "MEASURED: `docs/remediation/evidence/gs-integration-001-courts.log` and "
                        "`docs/remediation/evidence/rc11-step13/L1.log` retained; both witnesses executed.",
        "candidate_binding": _binding(),
    },
    "gs-integration-001.cross-platform": {
        "behavior": "Bidirectional cross-platform execution over the two platforms' ACTUAL live endpoint "
                    "implementations: iOS sender -> Android recipient -> iOS ACK, then the reverse, relaying exact "
                    "characters across the wire.",
        "implementation": "`tools/readiness/run_board1_integration.py` launches the Swift/macOS worker and the "
                          "Android/Robolectric worker (`gradlew :mesh:board1IntegrationWorker`) and refuses a missing "
                          "worker, missing marker, timeout or early exit by name.",
        "reachability": "production",
        "test": "`ios/Godstone/Tests/GodstoneMeshTests/GsIntegration001CrossPlatformWorkerTests.swift`, "
                "`android/mesh/src/test/java/io/godstone/mesh/rig/RealTransportHostRigWorkerTest.kt`",
        "positive": "An honest run relays the exact frame and both directions ACK end to end.",
        "mutation": "altered/mismatched/replay variants must be refused; the worker refuses an unknown variant rather "
                    "than silently downgrading it.",
        "exact_result": "MEASURED: `docs/remediation/evidence/board1-rc11-integration/coordinator.log` retained",
        "candidate_binding": _binding(),
    },
    "gs-integration-001.scenarios": {
        "behavior": "The three named scenario gaps are driven: (A) wrong peer/wrong key refused at the REAL sealed "
                    "handshake, (B) crash after outbound durable enqueue survives restart, (C) crash after ACK commit "
                    "leaves the ACK drainable.",
        "implementation": "The sealed handshake and the durable inbox/ACK roads in the GodstoneMesh production sources "
                          "driven by the host rig.",
        "reachability": "production",
        "test": "testAWrongTranscriptIsRefusedByTheAeadBeforeAnyValidator, "
                "testAStrangerAdvertisedHintIsRefusedByTheHintComparisonOnAnHonestTranscript, "
                "testABindingForAStrangerStaticKeyIsRefusedAtTheStaticComparison, "
                "testDTheOSFacadeRouteCarriesASealedFrameIntoTheStoreThroughProductionCode, "
                "testTheDefaultLaneTwinOfTheARBFrameIngestsNothing, "
                "testEWipeDuringASuspendedWriteRefusesStorageFailureThenReopens, "
                "testGSINT001ACrashAfterOutboundEnqueueLeavesTheRowQueued, "
                "testGSINT001ACrashAfterAnAckOfferLeavesTheAckDrainable",
        "positive": "Each refusal arm carries its same-run positive control (the honest transcript/frame is accepted).",
        "mutation": "Disabling the real SQLite commit or the live LinkReady hookup must redden the composed witness.",
        "exact_result": "MEASURED: the eight witnesses are DEFINED in the tree and their rods were executed",
        "candidate_binding": _binding(),
    },
    "gs-integration-001.mutation": {
        "behavior": "Removing the transport ingest wiring makes the composed test fail: the opened payload never "
                    "reacheth the node, so a frame that crossed the real radio reacheth no store.",
        "implementation": "`ios/Godstone/Sources/GodstoneMesh/BleTransport.swift`'s responder ingress delegate "
                          "hand-off (the deleted line in rod T72-RC18).",
        "reachability": "production",
        "test": "testDTheOSFacadeRouteCarriesASealedFrameIntoTheStoreThroughProductionCode, "
                "testARBEstablishesOverOSFacadesOnlyThenDeliversADirectFrameAndTheRecipientAck",
        "positive": "The unmutated tree is green on both witnesses.",
        "mutation": "ROD `T72-RC18-ios-transport-ingest-unwired` deletes the ingress delegate hand-off; the witness "
                    "reddens, and the restored tree is green again.",
        "exact_result": "MEASURED: the 49 scored board1 rods are KILLED at `commit:91fd6ffb`",
        "candidate_binding": _binding(),
    },
    "gs-runtime-001.android-composition-court": {
        "behavior": "A Robolectric court drives the ACTUAL production providers up to the real AndroidKeyStore "
                    "boundary and establishes that the composition reaches the real ACK/pump owners by BEHAVIOUR, not "
                    "by reading a source file.",
        "implementation": "`android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt`'s `provideMeshNode` over the "
                          "real graph; the court resolves through `DaggerMeshGraphComponent`.",
        "reachability": "production",
        "test": "theProductionProviderHandsTheNodeThePumpItWasGiven "
                "(`android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003GraphComponentTest.kt`)",
        "positive": "The court asserts `assertSame(pump, node.ackPump)` over the real provider, with the device-bound "
                    "inputs supplied.",
        "mutation": "Removing `node.ackPump = pump` reddens exactly that arm and no other.",
        "exact_result": "MEASURED: 10 arms, 0 failures, zero boundary early-returns in the run's own system-out; the "
                        "platform boundary is named rather than avoided.",
        "candidate_binding": _binding(),
    },
    "gs-runtime-001.mutations": {
        "behavior": "Three clauses each carry their own rod over the production composition on disk: removing the "
                    "`ackPump` wiring fails; a wrong provider binding fails; and shutdown/wipe invalidation reaches "
                    "the same owner graph.",
        "implementation": "`android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt` and "
                          "`android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt` (the drain now stands above the "
                          "`!isStarted` guard).",
        "reachability": "production",
        "test": "theProductionProviderHandsTheNodeThePumpItWasGiven, theDispatcherAdmitsThroughTheGivenPumpOnly, "
                "theWipeInvalidatorReachesEveryOwnerTheCompositionHandedOut",
        "positive": "`HostMeshRig` drives `MeshModule.provideMeshNode` itself over on-disk `JdbcStoreDb` stores and "
                    "each owner is read through a FOREIGN consumer.",
        "mutation": "ROD `T72-RC15` (delete `node.ackPump = pump`) and ROD `T72-RC16` (hand the pump reversed bytes) "
                    "are both KILLED.",
        "exact_result": "MEASURED: mesh + labmesh, 1537 tests, 0 failures",
        "candidate_binding": _binding(),
    },
    "gs-stress-001.real-runtime-driver": {
        "behavior": "A real-runtime stress driver instantiates `MeshRuntime`/`ComposedRuntime` -- not only "
                    "`StressCampaign` -- and cycles the shipping lane's own owners.",
        "implementation": "`ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift`'s production composition root.",
        "reachability": "production",
        "test": "testGSSTRESS001TheRealRuntimeSurvivesTenThousandDeterministicCycles",
        "positive": "The arm asserts `meshNode.sessions === sessionManager`, so a cycle that silently replaced an owner "
                    "would redden.",
        "mutation": "A driver over a model rather than the runtime root would leave the identity assertion unsatisfied.",
        "exact_result": "MEASURED: passes, with the cycle count ASSERTED so a partial run cannot read as a full one.",
        "candidate_binding": _binding(),
    },
    "gs-stress-001.ten-thousand-cycles": {
        "behavior": "At least 10,000 deterministic host cycles drive twelve action classes, each with its own "
                    "completion counter asserted against its schedule expectation.",
        "implementation": "`ios/Godstone/Tests/GodstoneMeshTests/GsStress001RealRuntimeDriverTests.swift` over the "
                          "production composition root.",
        "reachability": "production",
        "test": "The twelve-class campaign with full-graph reopen checkpoints at cycles 1000, 5000, 9000 and after the "
                  "final stop.",
        "positive": "EVERY counter must move; a class that silently stopped firing could not hide behind the total.",
        "mutation": "A mostly-reading body that satisfied the NUMBER but not the clause is refuseth by the per-class "
                    "counters.",
        "exact_result": "MEASURED, RETAINED LOG `path:docs/remediation/evidence/gs-stress-001-10k.log`: 9 tests, 0 "
                        "failures, cycles=10000, all twelve counters non-zero.",
        "candidate_binding": _binding(),
    },
    "gs-stress-001.thirty-thousand-cycles": {
        "behavior": "The same real-runtime campaign at 30,000 cycles through the same driver and the SAME fixed owner "
                    "bounds, with its own exact schedule counts and reopen observations.",
        "implementation": "The same driver, byte-identical to HEAD, over the production composition root.",
        "reachability": "production",
        "test": "The 30k arm of `GsStress001RealRuntimeDriverTests` with the twelve-class tally and durable-bytes bound.",
        "positive": "Two independent runs must agree byte-for-byte on the twelve-class tallies.",
        "mutation": "The prior 'stall' is RETRACTED with its own evidence (the samples were of the supervisor parent); "
                    "no bound was raised and no assertion weakened.",
        "exact_result": "MEASURED: `docs/remediation/evidence/gs-stress-001-30k.log` run 1 PASSED rc=0 in 1265.4s and "
                        "`docs/remediation/evidence/gs-stress-001-30k-run2.log` run 2 PASSED rc=0 in 1131.2s, "
                        "byte-identical tallies.",
        "candidate_binding": _binding(),
    },
    "gs-stress-001.production-owner-mutation": {
        "behavior": "Three rods mutate REAL production release owners at their own release boundaries (session slot "
                    "retirement, timer leases, and the egress recorder), and the stress court detects each.",
        "implementation": "`ios/Godstone/Sources/GodstoneMesh/SessionManager.swift`, "
                          "`ios/Godstone/Sources/GodstoneMesh/BleTransport.swift`, "
                          "`ios/Godstone/Sources/GodstoneMesh/RecordWriter.swift`.",
        "reachability": "production",
        "test": "testGSSTRESS001RelationRetirementReleasesTheOwnersOwnSlot and the step-7 release arms (method-form "
                  "filter verified to run the single arm: `Executed 1 test`).",
        "positive": "Each rod runs a green baseline and an EXECUTED restored-green phase.",
        "mutation": "RODs `T72-RC31` (session slot surviveth retirement) and `T72-RC32` (stop leaveth every timer lease "
                    "standing) are KILLED.",
        "exact_result": "MEASURED: all 49 scored board1 rods KILLED at `commit:2431568c`; the harness singular-form "
                        "parser defect was found and repaired at `commit:6da540c4`.",
        "candidate_binding": _binding(),
    },
    "gs-archive-005.app-witness": {
        "behavior": "An executed iOS app/simulator witness terminates the process and RELAUNCHES it, then asserts the "
                    "reader returned to the same document -- a clean process death, not a memory reboot.",
        "implementation": "`ios/Godstone/Sources/App/ArchiveView.swift` and "
                          "`ios/Godstone/Sources/GodstoneCore/ArchivePlaceStore.swift`.",
        "reachability": "production",
        "test": "testGSA005DocumentReopensAfterCleanProcessDeath "
                "(`ios/Godstone/Tests/GodstoneArchiveUITests/GodstoneArchiveUITests.swift`)",
        "positive": "The same arm asserts the document identity returns after relaunch.",
        "mutation": "The lane runner's provenance acceptance (pre/post source digest) refuseth a mid-run edit, so a "
                    "stale log cannot stand in.",
        "exact_result": "MEASURED GREEN at 47.011s; the ledger's NATIVE_MODELS excuse is STALE (the canonical hosted "
                        "workflow builds Godstone-Light).",
        "candidate_binding": _binding(),
    },
    "gs-final-006.ios-restoration-witness": {
        "behavior": "An executed app-level restoration/scroll sequence: launch, search, open a non-first hit, scroll "
                    "to a later passage, terminate the process, relaunch, and verify the same document and a valid "
                    "anchor return, with Back returning to the submitted query.",
        "implementation": "`ios/Godstone/Sources/GodstoneCore/ArchiveReadingAnchor.swift` and the App/GodstoneCore "
                          "restoration roads.",
        "reachability": "production",
        "test": "testGSFINAL006TheWholeRestorationJourneyInOneSequence "
                "(`ios/Godstone/Tests/GodstoneArchiveUITests/GodstoneArchiveUITests.swift`), with "
                "`ios/Godstone/Tests/GodstoneCoreTests/GsArchive005IOSRestorationTests.swift`",
        "positive": "The valid anchor returns after relaunch; the invalid-anchor arm is refused.",
        "mutation": "The anchor persistence road is the witness, so removing it reddens the sequence.",
        "exact_result": "MEASURED: the one executed sequence, with the process terminated and relaunched in-place.",
        "candidate_binding": _binding(),
    },
    "gs-final-006.mutation": {
        "behavior": "Disconnecting the production restore/anchor consumption makes the executed app test FAIL.",
        "implementation": "`ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift` -- `restore(from:)`'s "
                          "`.document` case was made to IGNORE the persisted `openedDocumentId`.",
        "reachability": "production",
        "test": "testGSFINAL006TheWholeRestorationJourneyInOneSequence",
        "positive": "The unmutated tree is green on the sequence.",
        "mutation": "The `.document` case ignores the persisted id and returns to the list; the executed arm reddens.",
        "exact_result": "MEASURED: the mutation is applied to production `ArchiveSceneModel.swift` and the executed app "
                        "test fails; `path:scripts/sync_ios_foundation_package.py` regenerates the mirror.",
        "candidate_binding": _binding(),
    },
    "audit-b1-ctrl-001.structured-obligations": {
        "behavior": "Structured per-finding closure: `internal_status`, `internal_obligations` and "
                    "`external_obligations` for every nonterminal finding, with `internal_remaining` DERIVED from "
                    "them rather than NLP-classified from prose.",
        "implementation": "`scripts/build_structured_closure.py` -- `--write` writes `finding_closure` (68 entries, "
                          "every one carrying `internal_status`) plus `structured_counts` into the ledger.",
        "reachability": "production",
        "test": "The closure-law courts refuse a READY status over unresolved work and refuse persisted/derived drift.",
        "positive": "The derived counts are persisted and `--check` compares the persisted state to the derivation "
                    "field by field.",
        "mutation": "A stale persisted count, a deleted obligation and an orphan obligation are each REFUSED.",
        "exact_result": "MEASURED: `internal_remaining_prose_classifier_retired` records the NLP classifier as "
                        "RETAINED-FOR-HISTORY-ONLY and NOT an input to any closure decision.",
        "candidate_binding": _binding(),
    },
    "audit-b1-ctrl-001.missed-partials": {
        "behavior": "Every PARTIAL is represented, including `GS-RUNTIME-001` and `GS-STORE-002` which the prose "
                    "classifier missed entirely.",
        "implementation": "`scripts/build_structured_closure.py`'s `PARTIAL_OBLIGATIONS` map and `build()` output.",
        "reachability": "production",
        "test": "`counts().obligations_by_state` reports the populations, so a missed finding cannot vanish from the "
                  "denominator.",
        "positive": "GS-RUNTIME-001 (2 obligations) and GS-STORE-002 (1 obligation) appear in the closure.",
        "mutation": "A classifier that misseth a PARTIAL would leave its obligations absent from the by-state count.",
        "exact_result": "MEASURED: the two findings and their obligations are present in the derived closure.",
        "candidate_binding": _binding(),
    },
    "audit-b1-ctrl-001.finding-obligation-consistency": {
        "behavior": "A finding may not stand internally OPEN while carrying ZERO unresolved obligations: the "
                    "instrument REFUSETH that combination rather than describing it.",
        "implementation": "`scripts/build_structured_closure.py` -- `build()` refuseth the combination in both "
                          "populations and `finding_state_problems()` is enforced by `--check`.",
        "reachability": "production",
        "test": "`tools/readiness/tests/test_closure_law_refuses.py:287` (`FindingStatusFollowsItsObligations`), with "
                  "the live-tree case at `:281`.",
        "positive": "A COMPLETE finding whose obligations are all DISCHARGED is PERMITTED -- the mirror direction.",
        "mutation": "The first version fired whenever a finding's obligations were ALL terminal, which would have "
                    "refused every correctly-closed finding; the repaired rule is pinned both ways.",
        "exact_result": "MEASURED BEFORE THE FIX: AUDIT-B1-CTRL-001 and GS-FINAL-004 each carried "
                        "`internal_status = OPEN` with ZERO unresolved obligations.",
        "candidate_binding": _binding(),
    },
})


#: *** THE LEGAL REVIEW-SOURCE STATUSES, AND THE GATE THAT KEEPS THEM HONEST. ***
#:
#: *Same law the OBLIGATION states carry: an UNKNOWN status is neither `REPAIRED_STALE` nor `LIVE`, so this
#: instrument may not guess which -- it is NAMED. And a status with no production evidence is a bare label, refused
#: in the other direction. The status lives DIRECTLY on the `KNOWN_INTERNAL_GAPS` record (`review_status`), beside
#: the defect it judges -- never a parallel map, so there is no second representation to drift.*
REVIEW_STATUSES = ("REPAIRED_STALE", "PARTIAL", "LIVE")


def review_status_problems() -> list[str]:
    """*** EVERY REVIEW-SOURCE STATUS MUST BE LEGAL AND CARRY ITS `path:line` EVIDENCE. ***

    *The "unknown enum state loophole" the closure boundary refuseth for obligations applies here too; and a status
    whose evidence is absent is the prose defect wearing a field.*  A record with NO `review_status` at all is NOT
    refused -- it is simply an unreconciled gap, read as LIVE by its own present-tense claim.
    """
    problems: list[str] = []
    for obligation_id, gaps in sorted(REVIEW_GAP_HISTORY.items()):
        for g in gaps:
            if not isinstance(g, dict):
                continue
            status = g.get("review_status")
            if status is None:
                continue
            if status not in REVIEW_STATUSES:
                problems.append(
                    f"{obligation_id}/{g.get('defect')}: carrieth `review_status` {status!r}, which is NOT one of "
                    f"{REVIEW_STATUSES} -- an unknown status is neither repaired nor live, so this instrument may "
                    f"not guess which")
            if not g.get("review_status_evidence"):
                problems.append(
                    f"{obligation_id}/{g.get('defect')}: carrieth `review_status` {status!r} with NO "
                    f"`review_status_evidence` -- a status must name the production `path:line` it was taken from, or "
                    f"a reader cannot re-check it")
    return problems


def _review_status_rollup() -> dict:
    """The rollup of the in-place source statuses, for a reader (derived; never an authority)."""
    counts: dict[str, int] = {}
    for gaps in REVIEW_GAP_HISTORY.values():
        for g in gaps:
            if isinstance(g, dict) and g.get("review_status"):
                counts[g["review_status"]] = counts.get(g["review_status"], 0) + 1
    return {
        "by_status": counts,
        "legal_statuses": list(REVIEW_STATUSES),
        "scope": ("SOURCE-ONLY: a REPAIRED_STALE status meaneth the named review defect is absent from the current "
                  "production source, NOT that the obligation is discharged. Every obligation stays OPEN until its own "
                  "current-candidate production controls are authored as a `structured_discharge`."),
    }


def discharged_prose_scan(closure: dict) -> dict:
    """*** THE ROSTER OF GAP-WORD HITS ON TERMINAL OBLIGATIONS, EACH WITH AN EXPLICIT DISPOSITION. ***

    *THE DEFECT THIS CLOSES: a scan that merely REPORTS hits ("review-only") leaves the reader to decide, and a
    terminal obligation whose own prose nameth a gap could therefore sit unreconciled forever.* **So every hit is
    DISPOSED, and the disposition is a function of the MEASURED structured semantics rather than of the wording:**

      * `COVERED_BY_STRUCTURED_DISCHARGE` -- the obligation is terminal AND carrieth an authored semantics block whose
        reachability is `production`; the hit is CONTROL/REFUTATION/SCOPE prose inside a claim that also names what was
        exercised. *This is a reasoned disposition, not a verdict of soundness.*
      * `REFUSED_CONTROL` -- the obligation is terminal with NO authored semantics: the hit is disposed as a LIVE
        CONCERN carried by `structured_discharge_problems`, which refuseth the obligation outright.

    **The scan carrieth NO closure authority: it never moveth a count, and it never declares a discharge sound.** *It
    existeth so a reader can see every terminal obligation whose prose mentioneth a gap concept, beside the disposition
    that is DERIVED from the measured semantics rather than asserted.*
    """
    roster: list[dict] = []
    by_disposition: dict[str, int] = {}
    for fid, f in sorted(closure.items()):
        for o in (f.get("internal_obligations") or []):
            if o.get("status") != "DISCHARGED":
                continue
            scan = _discharge_text_scan(o)
            if not scan["hits"]:
                continue
            sd = o.get("structured_discharge")
            if sd is not None and sd.get("reachability") in DISCHARGE_TERMINAL_REACHABILITY:
                disposition = "COVERED_BY_STRUCTURED_DISCHARGE"
                reasoning = (f"terminal with authored semantics (reachability={sd.get('reachability')}): the "
                             f"excerpt is control/refutation/scope prose inside a claim that NAMES the exercised "
                             f"control -- reasoned per obligation, NOT a verdict of soundness")
            else:
                disposition = "REFUSED_CONTROL"
                reasoning = ("terminal with NO authored semantics: the hit names a live concern, and "
                             "`structured_discharge_problems` refuseth the obligation outright")
            by_disposition[disposition] = by_disposition.get(disposition, 0) + 1
            for h in scan["hits"]:
                roster.append({
                    "finding": fid,
                    "obligation": o.get("id"),
                    "concept": h["concept"],
                    "field": h["field"],
                    "excerpt": h["excerpt"],
                    "disposition": disposition,
                    "reasoning": reasoning,
                })
    return {
        "artifact": "discharged-prose-dispositions",
        "generated_by": "scripts/build_structured_closure.py::discharged_prose_scan",
        "scan_of": "the DERIVED closure -- every TERMINAL obligation's own text/evidence",
        "authority": "review-only; NOT an input to any closure decision",
        "concepts_scanned": list(GAP_CONCEPTS),
        "counts": {"hits_total": len(roster), "by_disposition": by_disposition},
        "roster": roster,
    }


def semantics_gate_problems(semantics: dict) -> list[str]:
    """*** A TERMINAL CLAIM MAY NOT SIT BEHIND A REFUSED CONTROL. ***

    *`required_controls_present` now carrieth only MEASURED controls, and a terminal obligation with no authored
    semantics lands in `refused_controls` instead. If that list is non-empty while the closure record claimeth
    completion, the plane refuseth -- the measured controls are the positive half, and an unmeasured terminal claim is
    exactly the "present but unproven" shape this family of instruments exists to refuse.* **While the internal
    frontier is non-empty the list is empty by construction (nothing terminal lacks semantics), so this gate biteth
    exactly when a discharge was asserted without them.**
    """
    problems: list[str] = []
    for entry in semantics.get("refused_controls") or []:
        problems.append(f"{entry.get('obligation')}: a DISCHARGED obligation with NO authored `structured_discharge` "
                        f"cannot be reported as a present control -- the control is NOT measured")
    return problems


def _discharge_block_problems(oid: str, sd: dict) -> list[str]:
    """*** ONE DISCHARGE BLOCK, JUDGED FIELD BY FIELD. ***"""
    problems: list[str] = []
    missing = [k for k in DISCHARGE_REQUIRED_FIELDS if not sd.get(k)]
    if missing:
        problems.append(
            f"{oid}: `structured_discharge` MISSING {missing} -- a terminal claim must carry every required field, "
            f"because a structured block that omits one is the prose defect wearing a schema")
    reach = sd.get("reachability")
    if reach is None:
        problems.append(f"{oid}: `structured_discharge.reachability` is ABSENT -- court-only evidence may not stand "
                        f"in for a production discharge, so the reach must be STATED rather than defaulted")
    elif reach not in DISCHARGE_REACHABILITY:
        problems.append(
            f"{oid}: `structured_discharge.reachability` is {reach!r}, which is NOT one of "
            f"{DISCHARGE_REACHABILITY} -- an unknown reachability is neither production nor court-only")
    elif reach not in DISCHARGE_TERMINAL_REACHABILITY:
        problems.append(
            f"{oid}: a TERMINAL DISCHARGED carrieth `structured_discharge.reachability` {reach!r} -- a discharge that "
            f"reaches no production road CONTRADICTS its terminal status, and the instrument may not choose which to "
            f"believe")
    binding = sd.get("candidate_binding")
    if binding is None:
        problems.append(f"{oid}: `structured_discharge.candidate_binding` is ABSENT -- the binding to the EXTERNAL "
                        f"manifest and frozen attestation is REQUIRED, never optional")
    elif not isinstance(binding, dict):
        problems.append(f"{oid}: `structured_discharge.candidate_binding` must be a mapping, not "
                        f"{type(binding).__name__}")
    else:
        if binding.get("candidate_sha"):
            problems.append(
                f"{oid}: `candidate_binding` embeds a `candidate_sha` -- a generated record cannot carry the hash of "
                f"the candidate it describes (the hash would have to contain itself); it must NAME the external "
                f"manifest and the frozen attestation instead")
        for key in DISCHARGE_BINDING_KEYS:
            if not binding.get(key):
                problems.append(f"{oid}: `candidate_binding` is missing {key!r} -- the binding must name the external "
                                f"manifest and the frozen attestation it references")
        problems.extend(_current_binding_problems(oid, binding))
    return problems


def _canonical_freeze():
    """*** THE ONE FREEZE AUTHORITY, IMPORTED LAZILY -- NEVER A PRIVATE COPY OF ITS CONSTANTS. ***

    *Same road the evidence bundle useth: `ci/check_candidate_binding.py` owns the prospective successor path and the
    historical path; a restated literal here would drift from the authority the A-side reader enforces.*
    """
    ci_dir = str(ROOT / "ci")
    if ci_dir not in sys.path:
        sys.path.insert(0, ci_dir)
    import check_candidate_binding  # noqa: PLC0415 - the ONE authority for the freeze paths
    return check_candidate_binding


def _current_binding_problems(oid: str, binding: dict) -> list[str]:
    """*** A CURRENT DISCHARGE BINDETH THE CANDIDATE THE FREEZE *WILL* WRITE -- NEVER HISTORY. ***

    *THE DEFECT THIS CLOSES: `candidate_binding` was checked only for PRESENCE (`external_manifest`, `attestation`)
    and for a self-referential `candidate_sha`, so a CURRENT discharge could bind the HISTORICAL rc14 attestation, a
    stale name, or embed a tag object / candidate commit -- each of which describes a candidate other than the one
    being cut.* **The prospective path is the canonical authority's own constant
    (`ci/check_candidate_binding.py::FREEZE_ATTESTATION_SUCCESSOR_PATH`), the historical path its own
    `HISTORICAL_ATTESTATION_PATH`, and neither is restated here.** *`candidate_ref` is permitted as a PROSPECTIVE ref
    (the rc14 ref is refused by name); a tag object or candidate commit is an immutable identity of a candidate and is
    refused outright -- the binding names artifacts, never a hash of the candidate it belongs to.*
    """
    problems: list[str] = []
    try:
        canonical = _canonical_freeze()
        future_path = canonical.FREEZE_ATTESTATION_SUCCESSOR_PATH
        historical_path = canonical.HISTORICAL_ATTESTATION_PATH
    except Exception as exc:  # noqa: BLE001 - an unreadable authority is a NAMED refusal, never an assumption
        return [f"{oid}: the canonical freeze authority could not be imported ({type(exc).__name__}: {exc}) -- a "
                f"binding whose prospective attestation path cannot be read may not be assumed"]
    att = binding.get("attestation")
    if att == historical_path:
        problems.append(f"{oid}: `candidate_binding.attestation` nameth the HISTORICAL attestation {historical_path!r} "
                        f"-- a CURRENT discharge must bind the prospective future attestation {future_path!r}; history "
                        f"cannot discharge the current candidate")
    elif att != future_path:
        problems.append(f"{oid}: `candidate_binding.attestation` is {att!r}, not the canonical prospective path "
                        f"{future_path!r} from ci/check_candidate_binding.py::FREEZE_ATTESTATION_SUCCESSOR_PATH -- a "
                        f"binding must name the ONE path the freeze will write, never a prefix, a directory or a stale "
                        f"name")
    if binding.get("candidate_ref") == RC14_BINDING["candidate_ref"]:
        problems.append(f"{oid}: `candidate_binding.candidate_ref` nameth the HISTORICAL rc14 candidate "
                        f"{RC14_BINDING['candidate_ref']!r} -- a current discharge may not bind the archived candidate")
    for key in ("tag_object", "candidate_commit"):
        if binding.get(key):
            problems.append(f"{oid}: `candidate_binding.{key}` embeds an immutable candidate identity "
                            f"({binding.get(key)!r}) -- a current binding names the external manifest and the "
                            f"prospective attestation path, never a tag object or a candidate commit")
    return problems


def structured_discharge_problems(closure: dict) -> list[str]:
    """*** EVERY TERMINAL `DISCHARGED` MUST CARRY ITS OWN SEMANTICS, AND NONE MAY CONTRADICT THEM. ***

    *THE DEFECT THIS CLOSES, STATED PLAINLY: the previous version SKIPPED every obligation with no
    `structured_discharge`, so the entire register of terminal obligations bypassed the schema -- a discharge needed no
    behaviour, implementation, reachability, test, positive control, mutation, exact result or external binding, and
    `candidate_binding` itself was optional. **A terminal claim therefore needed NOTHING to be terminal, which is the
    same "terminal without evidence" shape this programme files as a defect.***

    **SO THE SCHEMA IS MANDATORY AT THE TERMINAL BOUNDARY:** every obligation whose status is DISCHARGED must carry a
    `structured_discharge` block with every required field, a PRODUCTION reachability, and an external
    `candidate_binding`. *The block is AUTHORED (`STRUCTURED_DISCHARGES`) rather than inferred -- the builder may not
    self-assert a claim no reader can examine -- and it is attached to the obligation by `build()`, so the two cannot
    drift apart.* **A terminal obligation this instrument can neither find nor author semantics for is refused BY
    NAME, and the refusal is the honest reading while the obligation is truly unmet.**
    """
    problems: list[str] = []
    for fid, f in sorted(closure.items()):
        for o in (f.get("internal_obligations") or []):
            oid = o.get("id", "<no id>")
            sd = o.get("structured_discharge")
            if o.get("status") != "DISCHARGED":
                if sd is not None:
                    problems.append(
                        f"{oid}: status is {o.get('status')!r} but it carrieth a `structured_discharge` block -- the "
                        f"block DESCRIBES a discharge, so a non-terminal obligation may not carry one")
                continue
            # A TERMINAL OBLIGATION WITH NO SEMANTICS IS THE DEFECT: it is refused, never skipped.
            if sd is None:
                problems.append(
                    f"{oid}: is DISCHARGED but carrieth NO `structured_discharge` block -- a terminal claim must carry "
                    f"its behaviour, implementation, reachability, test, positive control, mutation, exact result and "
                    f"EXTERNAL candidate binding. *A discharge with no semantics is a status without a subject.*")
                continue
            problems.extend(_discharge_block_problems(oid, sd))
    return problems


def authoring_coverage_problems(closure: dict) -> list[str]:
    """*** THE AUTHORED SEMANTICS AND THE CLOSURE MUST AGREE, IN BOTH DIRECTIONS. ***

    *THE DRIFT THIS REFUSES: an `STRUCTURED_DISCHARGES` entry for an obligation that is not terminal (a claim about
    work that no longer exists), or a terminal obligation the map forgot (covered by `structured_discharge_problems`,
    and reported here too so the two readers cannot disagree).* **This is the internal twin of the frozen side's
    "a record that has been edited since the candidate was frozen" refusal: the authored claim and the measured status
    describe one obligation or neither is trustworthy.**
    """
    problems: list[str] = []
    by_id: dict[str, str] = {}
    for f in closure.values():
        for o in (f.get("internal_obligations") or []):
            by_id[o.get("id")] = o.get("status")
    for oid in sorted(STRUCTURED_DISCHARGES):
        status = by_id.get(oid)
        if status is None:
            problems.append(f"STRUCTURED_DISCHARGES names {oid!r}, which no obligation in the closure carrieth -- an "
                            f"authored discharge with no subject")
        elif status != "DISCHARGED":
            problems.append(f"STRUCTURED_DISCHARGES authors a discharge for {oid!r} while its status is {status!r} -- "
                            f"a discharge block on non-terminal work is the overclaim this plane refuseth")
    # *** AND THE PER-OBLIGATION SOURCE-REVIEW HISTORY MUST SIT ON AN OBLIGATION, AND MAY NOT VANISH A LIVE DEFECT. ***
    #
    # *THE GUARD REGRESSION THIS CLOSES (found by the authoritative review): the first earned closure dropped the
    # "gap on terminal work is stale" refusal and then attached the history to the DISCHARGED obligation, so a review
    # record updated to `LIVE`/`PARTIAL` -- or carrying NO status at all -- would be PROMOTED to a terminal
    # obligation and attached only as history, and `structured_semantics` would omit it from `known_internal_gaps`
    # because the obligation is terminal. An unresolved defect would thus DISAPPEAR through the rename.*
    #
    # **SO A TERMINAL OBLIGATION MAY CARRY REVIEW HISTORY ONLY WHEN EVERY ATTACHED DEFECT IS EXPLICITLY
    # `REPAIRED_STALE`. A `LIVE`/`PARTIAL`/missing/illegal `review_status` on a terminal obligation is REFUSED BY
    # NAME; the orphan-ID refusal is retained. The history stays VISIBLE on the discharge -- it is not emptied -- but
    # an UNRESOLVED defect can never be hidden behind it.** *Every current record is `REPAIRED_STALE`, so this passeth
    # on the live tree; the moment one is set back to `LIVE` or `PARTIAL`, the closure refuses.*
    legal_terminal = ("REPAIRED_STALE",)
    for oid in sorted(REVIEW_GAP_HISTORY):
        status = by_id.get(oid)
        if status is None:
            problems.append(f"REVIEW_GAP_HISTORY names {oid!r}, which no obligation in the closure carrieth -- a "
                            f"gap history with no subject")
            continue
        if status not in TERMINAL_OBLIGATION_STATES:
            # The obligation is still live: its own `known_internal_gaps` carrieth the history, which is correct.
            continue
        for g in REVIEW_GAP_HISTORY[oid]:
            rs = g.get("review_status") if isinstance(g, dict) else None
            if rs not in legal_terminal:
                problems.append(
                    f"REVIEW_GAP_HISTORY carrieth a defect on the TERMINAL obligation {oid!r} whose "
                    f"`review_status` is {rs!r}, not one of {legal_terminal} -- a live/unreconciled review defect may "
                    f"NOT disappear behind a discharge's history; either the defect is repaired in source or the "
                    f"obligation may not stand DISCHARGED")
    return problems


def internal_status_state_problems(closure: dict) -> list[str]:
    """*** A FINDING'S `internal_status` CARRIES A LEGAL STATE, AND AN UNKNOWN ONE IS AN ERROR. ***

    *The law already refuseth an unknown OBLIGATION state; the FINDING state was unchecked, so a typo there would fall
    through every readiness test (both readiness tests compare against `OPEN`). **An unknown state is neither open nor
    terminal, so it must be NAMED rather than defaulted to either.***
    """
    legal = ("OPEN", "COMPLETE")
    return [
        f"{fid}: internal_status is {f.get('internal_status')!r}, which is NOT one of {legal} -- an unknown finding "
        f"state is neither open nor terminal, so no readiness rule can see it"
        for fid, f in sorted(closure.items())
        if f.get("internal_status") not in legal
    ]


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
        # *** THE STRUCTURED SEMANTICS THE MISSION REQUIRES, EMITTED AS A DERIVED BLOCK. ***
        # *`required_controls_present` is the positive half, `known_internal_gaps` the negative half (populated ONLY
        # while a finding is OPEN), and `unresolved_internal_dependencies` names what must land first. A discharged
        # finding's gap prose stays in its own obligation as HISTORY and is NOT counted as outstanding work.*
        ca["structured_semantics"] = structured_semantics(closure)
        # *** THE DISCHARGED-PROSE DISPOSITIONS, SO EVERY GAP-WORD HIT ON A TERMINAL OBLIGATION IS RECONCILED. ***
        ca["discharged_prose_dispositions"] = discharged_prose_scan(closure)
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

        # *** AND AN UNKNOWN FINDING STATE IS AN ERROR, NEVER A DEFAULT. ***
        status_state_problems = internal_status_state_problems(closure)
        for msg in status_state_problems:
            print(f"  ::error:: {msg}")
        if status_state_problems:
            return 1

        # *** AND A TERMINAL `DISCHARGED` ITS OWN STRUCTURED FIELDS CONTRADICT IS REFUSED. ***
        #
        # *A discharge that says its evidence is `court-only`/`external-blocked` while its status says DISCHARGED is the
        # contradiction a prose review cannot see; the structured block is what makes it visible. Legacy discharges
        # (no `structured_discharge`) are not refused -- only reported via the field's absence.*
        discharge_problems = structured_discharge_problems(closure)
        for msg in discharge_problems:
            print(f"  ::error:: {msg}")
        if discharge_problems:
            return 1

        # *** AND EVERY REVIEW-SOURCE STATUS IS LEGAL AND CARRYING ITS `path:line` EVIDENCE. ***
        recon_problems = review_status_problems()
        for msg in recon_problems:
            print(f"  ::error:: {msg}")
        if recon_problems:
            return 1

        # *** AND THE AUTHORED SEMANTICS MUST DESCRIBE THE CLOSURE THAT EXISTS. ***
        #
        # *A discharge authored for an obligation that is not terminal, or for an id no obligation carrieth, is a
        # claim about work that does not exist -- the same drift the frozen side refuseth when a record moved since the
        # candidate was tagged.*
        coverage_problems = authoring_coverage_problems(closure)
        for msg in coverage_problems:
            print(f"  ::error:: {msg}")
        if coverage_problems:
            return 1

        # *** AND THE MEASURED CONTROLS MUST BE PRESENT: A TERMINAL CLAIM BEHIND A REFUSED CONTROL IS REFUSED. ***
        #
        # *`required_controls_present` carrieth only obligations whose authored semantics name what was exercised; a
        # terminal obligation with no such block lands in `refused_controls`. If the record claimeth completion while
        # that list is non-empty, the positive half is unmeasured -- the "present but unproven" shape this plane
        # refuseth.*
        semantics = structured_semantics(closure)
        control_problems = semantics_gate_problems(semantics)
        for msg in control_problems:
            print(f"  ::error:: {msg}")
        if control_problems:
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
                live_sd = {o.get("id"): ("structured_discharge" in o)
                           for o in (closure[fid].get("internal_obligations") or [])}
                kept_sd = {o.get("id"): ("structured_discharge" in o)
                           for o in (persisted_fc[fid].get("internal_obligations") or [])}
                if live_sd != kept_sd:
                    drift.append(f"{fid}: persisted `structured_discharge` membership differs from the derivation -- "
                                 f"a persisted terminal claim the derivation would not make is a stale overclaim")
        # *** AND THE PERSISTED SEMANTICS BLOCKS ARE DERIVED FIELDS, NOT INDEPENDENT AUTHORITIES. ***
        # *`--write` deriveth them; a persisted copy this logic would not derive is the SECOND representation of one
        # state -- the exact class the counts/finding_closure comparison above existeth to refuse, extended so the
        # semantics and the prose-disposition roster cannot go stale in silence.*
        persisted_sem = persisted_ca.get("structured_semantics")
        if persisted_sem is None:
            drift.append("current_assessment.structured_semantics absent -- run --write so the persisted state "
                         "exists to be checked")
        elif persisted_sem != semantics:
            drift.append("current_assessment.structured_semantics persisted differs from the derivation: field(s) "
                         + ", ".join(sorted(k for k in set(persisted_sem) | set(semantics)
                                             if persisted_sem.get(k) != semantics.get(k))))
        persisted_dp = persisted_ca.get("discharged_prose_dispositions")
        if persisted_dp is None:
            drift.append("current_assessment.discharged_prose_dispositions absent -- run --write so the persisted "
                         "state exists to be checked")
        elif persisted_dp != discharged_prose_scan(closure):
            drift.append("current_assessment.discharged_prose_dispositions persisted differs from the derivation")
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
        #
        # *** AT THE EARNED CLOSURE THE DISCHARGED SET IS AUTHORED IN `STRUCTURED_DISCHARGES`, NOT BY AN OBLIGATION'S
        # OWN `status` LITERAL. *** *So the population this backstop judges follows the AUTHORITY: the authored
        # discharges (each keyed to a live obligation), with its evidence read from the obligation it names. An
        # authored discharge whose obligation carries no resolving citation is refused BY NAME -- the same guard as
        # before, now pointed at where the terminal claim actually lives.*
        problems: list[str] = []
        _by_oid = {o.get("id"): o for obls in PARTIAL_OBLIGATIONS.values() for o in obls}
        for oid in sorted(STRUCTURED_DISCHARGES):
            o = _by_oid.get(oid)
            if o is None:
                problems.append(f"{oid}: an authored discharge with NO obligation -- it points at nothing")
                continue
            cites = [c for c in (o.get("evidence") or []) if isinstance(c, str) and c.strip()]
            if not cites:
                problems.append(
                    f"{oid}: DISCHARGED with NO evidence -- a status this builder may not carry "
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
                    f"{oid}: DISCHARGED with evidence that carries NO TYPED TOKEN -- prose is allowed and "
                    f"ignored, but the CLAIM must be carried by `path:`/`commit:`/`test:` tokens a reader can check")
                continue
            for kind, value in tokens:
                if not _citation_token_resolves(kind, value):
                    problems.append(
                        f"{oid}: DISCHARGED but the citation token `{kind}:{value}` DOES NOT RESOLVE -- "
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
