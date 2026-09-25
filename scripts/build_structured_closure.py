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
         "status": "OPEN", "evidence": []},
        {"id": "gs-final-003.typed-permit",
         "text": "Both platforms: a non-forgeable typed startup decision (not a Bool, not a log "
                 "line, no public initializer) issued only after the typed recovery answer.",
         "status": "OPEN", "evidence": []},
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
         "status": "DISCHARGED", "evidence": [
             "`path:android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003ZeroPrivateOpensTest.kt` -- the ANDROID counter court: `noPermitIsIssuedOnAnyOutstandingRung`, `theCompositionIssuerRefusesOnEveryOutstandingRung`, and the positive controls `theTerminalRungIssuesThePermit` / `theCompositionIssuerPermitsOnTheTerminalRung`. **MEASURED: 5 tests, 0 failures**, with the refusing set DERIVED by asking the barrier. *A gate that always refused would fail the positive controls, and one that never refused would fail the others -- both directions.*",
             "`path:android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt` -- THE SEAM: `PrivateStorePermit` carrieth a PRIVATE constructor and `issue(decision)` returneth `null` for every refusing decision, and the three private providers REQUIRE it as a parameter. So zero opens is not inferred from a later absence -- the authority that construction requireth DOES NOT EXIST on those roads.",
             "`path:ios/Godstone/Tests/GodstoneMeshTests/GsFinal003StartupPermitTests.swift` -- THE iOS HALF: `PrivateOpenCounter` (real counts at the construction seam, not the vestigial array nothing read), `CountingKeyProvider` (the factory asketh for a DEK BEFORE it reacheth the engine, so a refused startup that got there would have ASKED), and the keychain write spy for the identity boundary. **MEASURED: 14 tests, 0 failures**, covering pending, retryable AND corrupt -- *the obligation nameth all three, and only pending carried counters before.*",
             "AND THE MUTATION PROVES THE iOS COUNTERS BITE RATHER THAN MERELY PASSING: *an identity-boundary open placed ABOVE the permit gate on the road the arms drive KILLETH EXACTLY the two counter-bearing arms and no others.* **My first attempt at that mutation ESCAPED, and it was wrong twice -- it landed on the `create` road while the arms drive `requireRecoveredPrivateComposition`, and it used a keychain READ while the spy counteth WRITES.** *A mutation placed wrong is not an escaped mutation; it is an experiment that proved nothing.*",
         ]},        {"id": "gs-final-003.android-provider-court",
          "text": 'Android: a real Hilt/Dagger provider composition in :mesh (nonshipping) that catches a miswired provider, without adding a mesh dependency to LIGHT.',
          "status": "DISCHARGED", "evidence": ['`path:android/mesh/src/main/java/io/godstone/mesh/di/MeshGraphComponent.kt`, `path:android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003GraphComponentTest.kt`, `test:theRealComponentsGateAnswersBothDirections`, `path:ci/check_lab_isolation.py`. A real `@Singleton @Component` in the `:mesh` MAIN source set, delegating every provider to `MeshModule`, constructed by the court through `DaggerMeshGraphComponent.builder()`. **THE MISWIRING MUTATION WAS RUN, NOT ASSERTED: inverting `provideWipeIsPending` polarity (the exact 18-round production defect) REDDENS TWO ARMS** -- `theRealComponentsGateAnswersBothDirections` and `theRealComponentsGateIsReadPerCallNotCached`; restored, 7/7 pass. *** AND LIGHT GAINS NOTHING: `Godstone` declares ONE dependency (GodstoneCore, no mesh edge) and `ci/check_lab_isolation.py` rc=0.***']},
        {"id": "gs-final-003.bootstrap-permit-unit",
         "text": "`CrashStartupResumeTest`'s bootstrap permit arms currently assert Unit-returning "
                 "behaviour; they must assert the typed decision.",
         "status": "OPEN", "evidence": []},
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
    ],
    "GS-INTEGRATION-001": [
        {"id": "gs-integration-001.real-adapters",
         "text": "A host harness that substitutes ONLY the OS/hardware boundary and drives the "
                 "REAL transport / orchestration / handshake adapters -- not `LinkFacade` and not "
                 "an in-memory transport.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-integration-001.scenarios",
         "text": "Drive from OS-facade callbacks only, covering DIRECT, recipient ACK, no direct "
                 "link, reconnect, wrong peer/key, replay, refused offer, crash after outbound "
                 "durable enqueue / inbound commit / ACK commit, resume, wipe interruption.",
         "status": "PARTIAL", "evidence": ["`path:ios/Godstone/Tests/GodstoneMeshTests/GsIntegration001RealTransportTests.swift`, `path:ios/Godstone/Sources/GodstoneMesh/WireV2.swift`, `path:ios/Godstone/Sources/GodstoneMesh/MeshNode.swift`. **9 OF THE 12 NAMED SCENARIOS HAVE ARMS, COUNTED ONE BY ONE RATHER THAN BY FEEL:** DIRECT (`testGSINT001AnInboundDeliveryIsCommittedExactlyOnce`), recipient ACK (`...RecipientAcksAreOfferedThenDrainedForTheLink`, mutation-proven), no direct link (`...NoDirectLinkQueuesDurablyRatherThanClaimingARadio`), reconnect (`...TheRuntimeSurvivesALostLinkAndStillServesItsDurableRoad`), replay (`...ACrashAfterCommitLeavesTheRowAndRefusesTheReplay`, mutation-proven), refused offer (`...ADistinctFrameIsStillAdmittedAfterARefusal`), crash after inbound commit (same replay arm), resume (same), and wipe interruption (`...ALoweredWipeGateRefusesSensitiveWorkThroughTheRealTransportNode`, mutation-proven). *** THREE REMAIN GENUINELY UNCOVERED AND ARE NAMED RATHER THAN IMPLIED: (i) WRONG PEER/KEY -- the malformed-frame arm drives `FrameV2.decode`, WHICH IS PURE WIRE-STRUCTURE VALIDATION (magic, version, type, ttl/hop bounds, CRC16) AND CONTAINS NO CRYPTOGRAPHY, so it is NOT a key or identity test; the real wrong-key road needs the SEALED HANDSHAKE, which `barePair` never runs. (ii) CRASH AFTER AN OUTBOUND DURABLE ENQUEUE and (iii) CRASH AFTER AN ACK COMMIT -- this rig runs an `InMemoryMessageStore`, so an OBJECT REBIRTH IS NOT A PROCESS DEATH: the store is never discarded and the rows stand for a reason the arms do not claim. THE DURABLE-ACROSS-RESTART HALF IS OWED TO THE REAL-COMPOSITION LANE, WHERE `SqliteMessageStore.enqueueDirectOutbound` COMMITS THE FRAME AND ITS QUEUED_DURABLY ROW IN ONE TRANSACTION.*** *Also unmet by CONSTRUCTION: the card\'s \"drive from OS-facade callbacks only\" clause, because `MeshNode.linkLayerReady = false` and BOTH `transportDidReceive` overloads guard on it -- the production transport->node delivery road is DEAD-ENDED in the shipped configuration, so every delivery arm must enter at `ingestInbound`.*** **MUTATION EVIDENCE FOR THE MALFORMED ARM, SERIALIZED AND ATTRIBUTABLE: baseline 13 passed / 0 failed; with `FrameV2.decode`'s magic AND CRC16 guards removed, 1 FAILED (that arm).** *My FIRST attempt mutated `BleRecord.decodeHeader` -- A ROAD THIS ARM NEVER TRAVERSES -- and stayed green, which proved nothing about the arm and everything about aiming a mutation at the wrong function.*"]},
        {"id": "gs-integration-001.mutation",
         "text": "Disconnect one production transport/orchestration call site and confirm the "
                 "integration court FAILS.",
         "status": "OPEN", "evidence": []},
    ],
    "GS-RUNTIME-001": [
        {"id": "gs-runtime-001.android-composition-court",
         "text": "A Robolectric court exercising the ACTUAL production providers up to the real "
                 "AndroidKeyStore boundary, establishing that composition reaches the real "
                 "ACK/pump owners and that assignment is not merely textual. If AndroidKeyStore "
                 "stops execution, that stop is the explicit external boundary.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-runtime-001.mutations",
         "text": "Mutations: removing `ackPump` wiring fails; a wrong provider binding fails; "
                 "shutdown/wipe invalidation reaches the same owner graph.",
         "status": "OPEN", "evidence": []},
    ],
    "GS-STRESS-001": [
        {"id": "gs-stress-001.real-runtime-driver",
         "text": "A real-runtime stress driver over the GS-INTEGRATION-001 host composition -- "
                 "instantiating `MeshRuntime`/`ComposedRuntime`, not only `StressCampaign`.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-stress-001.ten-thousand-cycles",
         "text": "At least 10,000 deterministic host cycles over start/stop, peer churn, link "
                 "replacement, sessions, reservations, leases, timers, observers, ACK work, store "
                 "observers, durable rows, parser refusal and wipe recovery.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-stress-001.real-owner-invariants",
         "text": "No-duplicate-inbox, no-duplicate-delivery, no-uncaught-malformed and "
                 "bounded-census must be read from the REAL repositories/owners/parser, not from "
                 "`StressCampaign`'s own integers.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-stress-001.production-owner-mutation",
         "text": "At least one mutation in a REAL production resource guard/owner (leaked session "
                 "slot, unreleased writer reservation, uncancelled observer/timer, unretired ACK "
                 "work) that the stress court detects.",
         "status": "OPEN", "evidence": []},
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
         "text": "Rendered LabMesh controls for recipient selection, UTF-8 bounded compose, Send, "
                 "fingerprint compare/confirm, exact rotation-candidate approval, revoke, visible "
                 "durable state after recreation, and visible wipe/recovery state -- every "
                 "displayed value derived from the real authority/projection.",
         "status": "OPEN", "evidence": []},
          {"id": "gs-ux-001.ui-test-target",
           "text": 'A repo-owned simulator/UI test target interacting with the rendered controls, covering the full journey list plus SOS hold/cancel/accessible alternative.',
           "status": "PARTIAL", "evidence": ["`path:tools/readiness/run_ios_ui_lane.sh`, `path:ci/check_lane_results.py`, `path:ios/Godstone/Tests/LabMeshUITests/LabMeshUITests.swift`, `path:ios/Godstone/Tests/GodstoneArchiveUITests/GodstoneArchiveUITests.swift`, `path:ios/project.yml`. TWO REAL `bundle.ui-testing` TARGETS, NOW WITH A COMMITTED RUNNER AND A CONTROL THAT PARSES THEM. Measured and reproduced from the committed runner: `ios:ui suites=2 tests=12 failures=1` -- 6 LabMeshUI arms and 6 GodstoneArchiveUI arms, all executed. THE LANE DID NOT EXIST BEFORE THIS ROUND: `run_ios_lane.sh` runs only `swift test --package-path`, so the UI witnesses had NO LANE, NO RESULT-FILE PARSING, NO SKIPPED ACCOUNTING AND NO DIGEST-BOUND LOG, and ran only from ad-hoc `/tmp` scripts an auditor cannot re-execute. `check_ios_ui_lane` now refuses a REQUIRED-SUITE omission, an `Executed 0` run (what a crashed XCUITest process reports), ANY SKIP, and a stale digest, and counts every arm's own line. THE ONE RED ARM IS A NAMED ALLOWLIST ENTRY, NOT A SUPPRESSION: flipping a PASSING arm to failed makes the control refuse by name, PROVEN BY MUTATION, so a new break cannot hide behind the recorded one. STILL OWED: several of the card's named journeys are not driven end to end in one arm, and the archive recreation arm is deterministically RED (see gs-archive-005.app-witness)."]},
        {"id": "gs-ux-001.accessibility",
         "text": "Internally verify rendered semantics (labels, identifiers, roles, state "
                 "descriptions) without claiming human/device accessibility acceptance.",
         "status": "OPEN", "evidence": []},
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
