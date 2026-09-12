#!/usr/bin/env python3
"""The mutation-controls ledger of this repository, reformed per master blueprint section 21.

Two lineages, kept apart on the page and in the tally:

  STRUCTURAL  text-scan controls of Invariant G (the legacy registry below).
              Their oracle is ci/integration.check: a finding must appear or
              the control is not doing its work. These are name/shape/gate
              checks. They are not semantics, are never reported as such, and
              are recorded with category="structural".

  SEMANTIC    meaning-breaking mutations of the production files, each run in
              a DISPOSABLE worktree at a pinned head - the live tree is never
              touched - with a BEHAVIORAL oracle: the named witness cases of
              the readiness suites. Honesty rules, per section 21:

                KILLED    the baseline passed unmutated, the mutation applied
                          exactly (anchor seen once), the mutant compiled, and
                          the intended witness assertion failed.
                INVALID the mutant did not compile - or the baseline itself
                          did not pass. Never counted as a catch.
                SKIPPED the anchor was not seen exactly once - the needle moved
                          on. Recorded, and NEVER counted as a catch. (This is
                          the reform's central honesty fix: the old ledger let
                          a missing anchor fall through to the caught tally.)
                TIMEOUT the harness did not settle inside the bound.
                ESCAPED the mutant compiled and the witness stayed green - a
                          real finding: strengthen the witness or revert the
                          production change that let it live.

    python3 ci/mutations.py                 # structural lineage (fast, default)
    python3 ci/mutations.py --semantic      # semantic lineage (runs harnesses)
    python3 ci/mutations.py --all           # both, reported separately
    python3 ci/mutations.py --report        # do not fail on findings
    python3 ci/mutations.py --emit-dir DIR  # write logs/ beside the manifest
    python3 ci/mutations.py --baseline SHA  # pin the audited head for a run

No aggregate is ever printed as a single killed percentage. The two lineages
are never summed. Every result row carries the section 21 schema fields
verbatim: id, baseline_sha, mutant_patch_sha, category, anchor_count,
build_exit, target_tests, tests_run, outcome, failed_assertion, log_sha.

A control that has never been observed failing is not a control.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SCHEMA_FIELDS = ("id", "baseline_sha", "mutant_patch_sha", "category",
                 "anchor_count", "build_exit", "target_tests", "tests_run",
                 "outcome", "failed_assertion", "log_sha")


def _load_checker():
    spec = importlib.util.spec_from_file_location("integ", os.path.join(ROOT, "ci", "integration.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m.check


def _sha_text(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def _sha_file(path):
    if not path or not os.path.exists(path):
        return None
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def _now_utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _row(entry, baseline_sha, category, anchor_count, build_exit, target_tests,
         tests_run, outcome, failed_assertion, log_path):
    return {"id": entry["id"], "baseline_sha": baseline_sha,
            "mutant_patch_sha": entry["patch_sha"], "category": category,
            "anchor_count": anchor_count, "build_exit": build_exit,
            "target_tests": list(target_tests), "tests_run": tests_run,
            "outcome": outcome, "failed_assertion": failed_assertion,
            "log_sha": _sha_file(log_path), "log_path": log_path,
            "started_utc": entry.get("started_utc"), "ended_utc": entry.get("ended_utc")}


# --------------------------------------------------------------------------
# The structural lineage: the legacy Invariant G registry. The oracle is the
# text checker; these controls are shape gates and stay recorded as such.
# --------------------------------------------------------------------------
# (id, file, find, replace, invariant, why, expect_escape)
#
# expect_escape=True marks a KNOWN CEILING of text-based analysis, not a bug
# to be tuned away. M2 keeps SealedSender.seal( textually present inside a
# dead if (false) branch. A regex can tell a MENTION from a CALL; it cannot
# tell a LIVE call from a DEAD one, because that is reachability analysis and
# it needs a compiler or a call graph. It is recorded as the boundary, and
# closing it is a stated reason ./gradlew build is the real exit gate.
G_STRUCTURAL = [
    ("M1-gate-comment-only",
     "android/llm/src/main/java/io/godstone/llm/rag/Retriever.kt",
     "val verdict = io.godstone.llm.safety.SafetyGate.evaluate(query, fused, corpusIndex)",
     "val verdict: io.godstone.llm.safety.SafetyGate.Result? = null  // SafetyGate.evaluate",
     "G4",
     "the call becomes a comment; V3 passed on exactly this", False),

    ("M2-sealed-sender-orphan",
     "android/mesh/src/main/java/io/godstone/mesh/router/Router.kt",
     "val sealed = io.godstone.mesh.seal.SealedSender.seal(",
     "val sealed = ByteArray(0); if (false) io.godstone.mesh.seal.SealedSender.seal(",
     "G7",
     "call kept alive textually inside if (false) -- CEILING, needs a compiler", True),

    ("M3-handshake-removed",
     "android/mesh/src/main/java/io/godstone/mesh/crypto/SessionManager.kt",
     # re-anchored at the T20 reform: the T-era registry had been silently
     # counting this entry while its anchor had drifted (the function's
     # return type moved on to ByteArray?). The old ledger called that
     # "caught"; the reform's SKIPPED verdict is what honesty looks like.
     "fun beginInitiator(peerId: ByteArray, remoteHint: ByteArray): ByteArray? =",
     "// fun beginInitiator REMOVED\n    private fun _unused_beginInitiator(peerId: ByteArray, remoteHint: ByteArray): ByteArray? =",
     "G3",
     "sessions.seal survives; nothing can establish a session", False),

    ("M4-wrong-sqlcipher-package",
     "android/mesh/src/main/java/io/godstone/mesh/store/MessageStore.kt",
     "import net.zetetic.database.sqlcipher.SQLiteDatabase",
     "import net.sqlcipher.database.SQLiteDatabase",
     "G8",
     "legacy package contains the substring V3 checked for", False),

    ("M5-codec-orphaned",
     "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt",
     'val SERVICE_UUID: UUID = FrameV2.SERVICE_UUID',
     'val SERVICE_UUID: UUID = UUID.fromString("67640001-1000-8000-00805f9b34fb")',
     "G2",
     "generated codec still present, runtime uses a legacy literal", False),

    ("M6-idf-formula-drift",
     "ios/Godstone/Sources/GodstoneCore/SafetyGate.swift",
     "idf[t] = log((Double(n - d) + 0.5) / (Double(d) + 0.5) + 1.0)",
     "idf[t] = log(Double(n - d) + 0.5) / (Double(d) + 0.5) + 1.0",
     "G6",
     "the real iOS defect: constants agree, the equation does not", False),
]


def run_structural(report_only, emit_dir, baseline_sha):
    check = _load_checker()
    root_path = pathlib.Path(ROOT)
    baseline = check(root_path)
    rows = []
    tally = {k: 0 for k in ("KILLED", "SKIPPED", "ESCAPED", "INVALID", "TIMEOUT")}
    print("STRUCTURAL lineage (oracle: ci/integration.check text scan; "
          "these are shape gates, not semantics)")
    for mid, rel, find, repl, inv, why, expect_escape in G_STRUCTURAL:
        entry = {"id": mid, "patch_sha": _sha_text(find + "\n==\n" + repl)}
        target = os.path.join(ROOT, rel)
        if not os.path.exists(target):
            tally["SKIPPED"] += 1
            rows.append(_row(entry, baseline_sha, "structural", 0, None, [inv], None,
                            "SKIPPED", "file absent: " + rel, None))
            print("  SKIPPED %s: %s absent -- not counted as a catch" % (mid, rel))
            continue
        original = open(target, encoding="utf-8").read()
        anchor_count = original.count(find)
        if anchor_count != 1:
            tally["SKIPPED"] += 1
            rows.append(_row(entry, baseline_sha, "structural", anchor_count, None,
                            [inv], None, "SKIPPED", "anchor count %d != 1" % anchor_count, None))
            print("  SKIPPED %s: anchor seen %d times -- not counted as a catch"
                  % (mid, anchor_count))
            continue
        log_bytes = []
        caught = False
        try:
            open(target, "w", encoding="utf-8").write(original.replace(find, repl, 1))
            found = check(root_path)
            new = [f for f in found if f not in baseline]
            log_bytes.append(("new findings: " + json.dumps(new) + "\n").encode("utf-8"))
            caught = any(f.startswith(inv) for f in new)
        finally:
            open(target, "w", encoding="utf-8").write(original)
            back = open(target, encoding="utf-8").read()
            assert back == original, "restoration of " + rel + " failed; halt"
        if caught:
            outcome = "KILLED"
            status = "CLOSED " if expect_escape else "caught "
        elif expect_escape:
            outcome = "ESCAPED"
            status = "ceiling"
        else:
            outcome = "ESCAPED"
            status = "ESCAPED"
        tally[outcome] += 1
        log_path = None
        if emit_dir:
            log_path = os.path.join(emit_dir, "logs", mid + ".structural.log")
            os.makedirs(os.path.dirname(log_path), exist_ok=True)
            open(log_path, "wb").write(b"".join(log_bytes))
        rows.append(_row(entry, baseline_sha, "structural", anchor_count, None, [inv], None,
                        outcome, None if caught else "the text checker stayed silent", log_path))
        print("  %s %-28s [%s] %s" % (status, mid, inv, why))
    print("  per outcome: " + ", ".join("%s=%d" % (k, tally[k]) for k in
          ("KILLED", "SKIPPED", "ESCAPED", "INVALID", "TIMEOUT")))
    escapes = [r["id"] for r in rows if r["outcome"] == "ESCAPED"
               and not any(r["id"] == m[0] and m[6] for m in G_STRUCTURAL)]
    if escapes:
        print("  :: the text checker missed: " + ", ".join(escapes) +
              " -- this is why ./gradlew build is the exit gate, not this script.")
    bad = [r["id"] for r in rows if r["outcome"] in ("SKIPPED", "INVALID", "TIMEOUT")] + escapes
    if bad and not report_only:
        print("::error::structural controls regressed: " + ", ".join(bad), file=sys.stderr)
        return 1
    return 0


# --------------------------------------------------------------------------
# The semantic lineage. Every mutation runs in a DISPOSABLE worktree at a
# pinned head; the oracle is the named witness case of the readiness suites.
# --------------------------------------------------------------------------
SEMANTIC = [
    # -------------------------------------------------------------- T24 (replay)
    #
    #   The bounded conduits late-subscriber replay, at the real iOS transport
    #   seam. Unlike the saturated-emit branch (which no public path reacheth),
    #   a late-joiner replay is reachable by the public API, so this control is
    #   genuinely court-controllable and CAUGHT by its named witness (verified
    #   KILLED). It complements the publisher-side SM1..SM4.
    {'id': 'T24-SM5-ios-replay-late-subscriber', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/BleTransport.swift', 'find': '        for peer in replay { subscriber(peer) }', 'replace': '        // (mutant) the replay to a late joiner is suppressd', 'why': 'the present ready state is never replayed to a late subscriber; a consumer that attacheth after the sealed round is left in ignorance of what is already ready, so the conduit loseth its late-joiner guarantee', 'witness': 'testALateSubscriberDothSeeThePresentReadyState', 'swift_filter': 'ReadinessT23Tests'},
    # -------------------------------------------------------------- T24
    #
    #   The bounded reliable publisher / router core. The cards two named
    #   falsifications (ignore the offer verdict / look up the current peer on
    #   delayed delivery) are each falsified against the REAL committed
    #   PeerEventPublisher on both isles; each must be caught by its named witness
    #   in ReadinessT24PublicationTest(s). The transport-level wiring controls
    #   accompany the deep-wiring child once this seam is adopted by the transport.
    {'id': 'T24-SM1-android-swallow-offer-verdict', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/transport/PeerEventPublisher.kt', 'find': '                val v = channel.offer(event, key.generation)\n                if (v == OfferVerdict.Accepted) {\n                    readyPublished.add(key)\n                    shouldDeliver = true\n                }', 'replace': '                val v = channel.offer(event, key.generation)\n                run {\n                    readyPublished.add(key)\n                    shouldDeliver = true\n                }', 'why': 'the publisher ignores the reliable channels offer verdict; a refused (full/terminal) offer still marks the relation published and delivers - the cards ignore-tryEmit-failure falsification', 'witness': 'testAFullChannelAnswerethWithBackpressureAndIsNotSilentlyDropt', 'gradle_filter': '*ReadinessT24PublicationTest*'},
    {'id': 'T24-SM2-android-route-lookups-current-peer-by-handle', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/transport/PeerEventPublisher.kt', 'find': '        forward(captured, received)', 'replace': '        forward(byHandle(captured.relation) ?: captured, received)', 'why': 'route re-looks-up the current peer by handle at delivery rather than forwarding the captured immutable trusted peer - the cards look-up-current-peer-on-delayed-delivery falsification', 'witness': 'testStaleInputCannotRouteUnderANewIdentityAndRouteUsethTheCapturedPeer', 'gradle_filter': '*ReadinessT24PublicationTest*'},
    {'id': 'T24-SM3-ios-swallow-offer-verdict', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/PeerEventPublisher.swift', 'find': '            let v = channel.offer(event, ownerGeneration: key.generation)\n            if v == .accepted {\n                readyPublished.insert(key)\n                return (.accepted, true)\n            }\n            return (v, false)', 'replace': '            let v = channel.offer(event, ownerGeneration: key.generation)\n            readyPublished.insert(key)\n            return (.accepted, true)', 'why': 'the publisher ignores the reliable channels offer verdict; a refused (full/terminal) offer still marks the relation published and delivers - the cards ignore-tryEmit-failure falsification', 'witness': 'testAFullChannelAnswerethWithBackpressureAndIsNotSilentlyDropt', 'swift_filter': 'ReadinessT24PublicationTests'},
    {'id': 'T24-SM4-ios-route-lookups-current-peer-by-handle', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/PeerEventPublisher.swift', 'find': '        forward(captured, received)', 'replace': '        forward(byHandle(captured.relation) ?? captured, received)', 'why': 'route re-looks-up the current peer by handle at delivery rather than forwarding the captured immutable trusted peer - the cards look-up-current-peer-on-delayed-delivery falsification', 'witness': 'testStaleInputCannotRouteUnderANewIdentityAndRouteUsethTheCapturedPeer', 'swift_filter': 'ReadinessT24PublicationTests'},
    # -------------------------------------------------------------- T25 (snapshot authority)
    #
    #   The nonblocking, subscription-owned LinkInfo snapshot authority. The cards
    #   required_semantic_negative (compute the digest with synchronous DB work inside
    #   the read callback) is falsified on BOTH isles by routing the ATT read through a
    #   durable traversal; the read-purity witness falleth. Three further isle-symmetric
    #   semantic negatives strike the rewires own laws (bounded reentrancy latest-wins,
    #   the observation-lease gate, the one-byte saturation cap); each is caught by its
    #   named witness in the canonical ReadinessT25Test(s) court. None touch a frozen
    #   contract; the frozen generators are perturbed only in the disposable mutant.
    {'id': 'T25-SM1-android-read-traverses-store', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/transport/LinkInfoSnapshotAuthority.kt', 'find': '    fun currentBytes(): ByteArray? {\n        return cachedBytes.get()\n    }', 'replace': '    fun currentBytes(): ByteArray? {\n        refresh()\n        return cachedBytes.get()\n    }', 'why': 'the GATT read callback performeth durable store traversal (currentBytes calleth refresh), so a blocked or slow store stall the ATT read; the cards synchronous-DB-work-in-read-callback falsification - the read-purity witness (a read must not move the traversal count) falleth', 'witness': 'testTheReadPathCopiethTheCommittedValueEvenWhileTheStoreIsBlocked', 'gradle_filter': '*ReadinessT25Test*'},
    {'id': 'T25-SM2-ios-read-traverses-store', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/LinkInfoSnapshotAuthority.swift', 'find': '    public func currentData() -> Data? {\n        lock.lock(); defer { lock.unlock() }\n        return cachedData\n    }', 'replace': '    public func currentData() -> Data? {\n        _ = refresh()\n        lock.lock(); defer { lock.unlock() }\n        return cachedData\n    }', 'why': 'the ATT read callback performeth durable store traversal (currentData calleth refresh), so a blocked store stall or falsifieth the read; the cards synchronous-DB-work-in-read-callback falsification - the read-purity witness falleth', 'witness': 'testTheReadPathCopiethTheCommittedValueEvenWhileTheStoreIsBlocked', 'swift_filter': 'ReadinessT25Tests'},
    {'id': 'T25-SM3-android-rerun-loop-disabled', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/transport/LinkInfoSnapshotAuthority.kt', 'find': '        } while (rerun.get() && ++guard < 8)', 'replace': '        } while (false && ++guard < 8)', 'why': 'the bounded re-run after a reentrant notify is disabled, so a commit that landeth during an in-flight compute is lost and the stale first compute (dropt by the revalidate gate) leaves the prior snapshot standing; the latest-wins-once law is broke and the reentrancy witness falleth', 'witness': 'testObserverReentrancyPublishethTheLatestValueExactlyOnce', 'gradle_filter': '*ReadinessT25Test*'},
    {'id': 'T25-SM4-ios-rerun-loop-disabled', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/LinkInfoSnapshotAuthority.swift', 'find': '        } while isRerun() && passes < 8', 'replace': '        } while false && passes < 8', 'why': 'the bounded re-run after a reentrant notify is disabled, so a commit that landeth during an in-flight compute is lost; the latest-wins-once law is broke and the reentrancy witness falleth', 'witness': 'testObserverReentrancyPublishethTheLatestValueExactlyOnce', 'swift_filter': 'ReadinessT25Tests'},
    {'id': 'T25-SM5-android-lease-gate-removed', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/transport/LinkInfoSnapshotAuthority.kt', 'find': '        if (!observing.get().isActive) return', 'replace': '        // (mutant) the observation lease gate is removd; notify always recomputes', 'why': 'the observation lease gate is taken from the store callback, so a stopped runtime still recomputeth on a committed change; the one-active-while-started zero-while-stopped law is broke and the start/stop witness falleth', 'witness': 'testRepeatedRuntimeStartStopLeavethOneRegistrationThenZeroActive', 'gradle_filter': '*ReadinessT25Test*'},
    {'id': 'T25-SM6-ios-lease-gate-removed', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/LinkInfoSnapshotAuthority.swift', 'find': '        guard lease.isActive else { return }', 'replace': '        // (mutant) the observation lease gate is removd; notify always recomputes', 'why': 'the observation lease gate is taken from the store callback, so a stopped runtime still recomputeth; the one/zero active law is broke and the start/stop witness falleth', 'witness': 'testRepeatedRuntimeStartStopLeavethOneRegistrationThenZeroActive', 'swift_filter': 'ReadinessT25Tests'},
    {'id': 'T25-SM7-android-saturation-cap-wrong', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/transport/LinkInfoSnapshotAuthority.kt', 'find': '        val queueDepth = minOf(count, 255)', 'replace': '        val queueDepth = minOf(count, 254)', 'why': 'the held-count saturating cap is perturbed from the one-byte bound 255 to 254, so a three-hundred-item store reporteth the wrong depth; the saturation witness falleth', 'witness': 'testQueueDepthSaturatethAtTheOneByteBound', 'gradle_filter': '*ReadinessT25Test*'},
    {'id': 'T25-SM8-ios-saturation-cap-wrong', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/LinkInfoSnapshotAuthority.swift', 'find': '        let queueDepth = UInt8(min(count, 255))', 'replace': '        let queueDepth = UInt8(min(count, 254))', 'why': 'the held-count saturating cap is perturbed from 255 to 254, so a three-hundred-item store reporteth the wrong one-byte depth; the saturation witness falleth', 'witness': 'testQueueDepthSaturatethAtTheOneByteBoundViaTheFrozenGenerators', 'swift_filter': 'ReadinessT25Tests'},
    # -------------------------------------------------------------- T26 (admission governor)
    #
    #   The bounded, authenticated traffic-budget governor (abuse/PeerGovernor).
    #   The cards two named falsifications are struck against the REAL committed
    #   PeerGovernor and each must be caught by its named witness in the
    #   canonical ReadinessT26Test court: (SM1) allocating a governor entry
    #   BEFORE consulting the global bound (unbounded Sybil registry growth), and
    #   (SM2) exempting SOS from the token bucket (the unbounded exempt-channel
    #   the design closes). Android-only task; the court is the single regression
    #   path named by the manifest.
    {'id': 'T26-SM1-android-allocate-before-global-admission', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/abuse/PeerGovernor.kt', 'find': '            if (tracked.get() >= maxTrackedPeers) return false\n            var created = false\n            trust.computeIfAbsent(k) { created = true; Trust() }\n            if (created) tracked.incrementAndGet()', 'replace': '            var created = false\n            trust.computeIfAbsent(k) { created = true; Trust() }\n            if (created) tracked.incrementAndGet()\n            if (tracked.get() >= maxTrackedPeers) return false', 'why': 'the per-peer governor entry is allocated BEFORE the global bound is consulted, so a Sybil flood of fresh identities grows the registry past the cap unbounded (the card named falsification: allocate a governor entry before global admission); the bounded-resource witness over the tracked count falleth', 'witness': 'testSybilFloodIsBoundedByTheGovernorAdmittingBeforeAllocating', 'gradle_filter': '*ReadinessT26Test*'},
    {'id': 'T26-SM2-android-bypass-SOS-charging', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/abuse/PeerGovernor.kt', 'find': '        val k = key(nodeId)\n        if (!admits(nodeId)) return false', 'replace': '        val k = key(nodeId)\n        if (priority == Priority.SOS) return true\n        if (!admits(nodeId)) return false', 'why': 'SOS frames are exempted from the token bucket (admitted without charging the SOS budget), reopening the unbounded exempt-channel the design closes; a sustained SOS stream is never bounded, so the SOS-spam charging witness that expects the 30-token cap falleth', 'witness': 'testSustainedSOSIsChargedAndBoundedNotExempt', 'gradle_filter': '*ReadinessT26Test*'},
    # -------------------------------------------------------------- T27 (iOS traffic governance parity)
    #
    #   The iOS twin governor (PeerGovernor.swift) must decide identically to the
    #   sealed android governor on the shared vector AND must key the budget by the
    #   AUTHENTICATED identity, never the untrusted advertised hint. SM1 is the
    #   cards named falsification (use the advertised hint as the authenticated
    #   budget identity -> two distinct peers sharing one hint are conflated);
    #   SM2 removes the global bound tested before a governor entry is allocated
    #   (Sybil flood grows the registry unbounded).
    {'id': 'T27-SM1-ios-hint-as-authenticated-identity', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/PeerGovernor.swift', 'find': '        _ = advertisedHint                                   // NEVER the budget identity\n        let k = keyOf(authenticatedNodeId)', 'replace': '        let k = keyOf(advertisedHint ?? authenticatedNodeId)', 'why': 'the untrusted advertised hint is used as the authenticated budget identity, so two distinct peers that share one advertised hint are conflated into a single bucket and the second is starved (the cards named falsification: multi identity and malformed trace fails); the hint-isolation witness falleth', 'witness': 'testAdvertisedHintIsNeverTheAuthenticatedIdentity', 'swift_filter': 'ReadinessT27Tests'},
    {'id': 'T27-SM2-ios-unbounded-identity-governor', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/PeerGovernor.swift', 'find': '        if trackedCount >= maxTrackedPeers { registryLock.unlock(); return false }\n        trust[k] = Trust()', 'replace': '        trust[k] = Trust()', 'why': 'the global bound is no longer consulted before allocating a governor entry, so a Sybil flood grows the registry past maxTrackedPeers unbounded (the allocate-before-admission law is broke); the bounded-cache witness falleth', 'witness': 'testBoundedCacheHoldsUnderSybilChurn', 'swift_filter': 'ReadinessT27Tests'},
    # -------------------------------------------------------------- T28 (unified runtime lifecycle)
    #
    #   The lifecycle authority (android identity/RuntimeLifecycle.kt and its iOS
    #   twin Sources/GodstoneMesh/UnifiedRuntimeLifecycle.swift) must make a
    #   stopped/terminal runtime issue NO OS call and must UNIFORMLY invalidate on
    #   power loss. SM1 lets a background event start a scanner on a stopped runtime
    #   (the cards named falsification); SM2 lets power-off merely toggle advertising,
    #   leaving the scanner and session live and non-terminal. Each is struck on BOTH
    #   isles and must be caught by its named ReadinessT28 witness.
    {'id': 'T28-SM1-android-background-starts-stopped-runtime', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/identity/RuntimeLifecycle.kt', 'find': '            if (!started || capability != CapabilityStatus.ACTIVE_READY) return   // the semantic-negative guard\n            // a background event never (re)starts a scan; it only stays within the already-active budget', 'replace': '            seam.startScan()   // (mutant) a background event starts a scanner even on a stopped runtime', 'why': 'a background transition on a stopped runtime reaches the scanner and issues an OS call, the opposite of the invariant that a stopped or terminal runtime makes no OS call (the cards named falsification: allow setBackgrounded to start a stopped scanner); the no-OS-calls witness falleth', 'witness': 'testBackgroundCanNotStartAStoppedRuntimeMakesNoOsCalls', 'gradle_filter': '*ReadinessT28Test*'},
    {'id': 'T28-SM2-android-power-loss-not-uniform', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/identity/RuntimeLifecycle.kt', 'find': '            drainLocked()\n            if (started) { lease?.releaseOnce(); started = false }\n            capability = CapabilityStatus.TERMINAL_UNAVAILABLE', 'replace': '            seam.stopAdvertising()   // (mutant) power-off merely toggles advertising, leaving the scanner and session live and non-terminal', 'why': 'power-off merely toggles advertising instead of uniformly invalidating: the scanner and session are left live and the capability never reaches the terminal state, so isReady stays true; the power-loss uniform-invalidation and terminal witness falleth', 'witness': 'testPowerLossUniformlyInvalidatesAndIsTerminalNeverReady', 'gradle_filter': '*ReadinessT28Test*'},
    {'id': 'T28-SM1-ios-background-starts-stopped-runtime', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/UnifiedRuntimeLifecycle.swift', 'find': '        if !started || capability != .activeReady { return }   // the semantic-negative guard\n        // a background event never (re)starts a scan; it only stays within the already-active budget', 'replace': '        seam.startScan()   // (mutant) a background event starts a scanner even on a stopped runtime', 'why': 'a background transition on a stopped runtime reaches the scanner and issues an OS call, the opposite of the invariant that a stopped or terminal runtime makes no OS call (the cards named falsification); the no-OS-calls witness falleth on the iOS twin', 'witness': 'testBackgroundCanNotStartAStoppedRuntimeMakesNoOsCalls', 'swift_filter': 'ReadinessT28Tests'},
    {'id': 'T28-SM2-ios-power-loss-not-uniform', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/UnifiedRuntimeLifecycle.swift', 'find': '        _ = drainLocked()\n        if started { lease?.releaseOnce(); started = false }\n        capability = .terminalUnavailable', 'replace': '        seam.stopAdvertising()   // (mutant) power-off merely toggles advertising, leaving the scanner and session live and non-terminal', 'why': 'power-off merely toggles advertising instead of uniformly invalidating: the scanner and session are left live and the capability never reaches the terminal state, so isReady stays true; the power-loss uniform-invalidation and terminal witness falleth on the iOS twin', 'witness': 'testPowerLossUniformlyInvalidatesAndIsTerminalNeverReady', 'swift_filter': 'ReadinessT28Tests'},
    # -------------------------------------------------------------- T29 (private-store encryption / fail-closed open)
    #
    #   The store-open contract (store/StoreOpenResult.kt classifier + store/SqlcipherStoreOpener.kt
    #   adapter) must never let a fault or a plain (un-encrypted) store surface as a healthy
    #   Available store. SM1 is the cards named falsification (replace the production encrypted
    #   opener with plain SQLite: the encrypted-at-rest assertion fails) -- struck on the adapter
    #   so a cipherEnabled=false binding is accepted as if encrypted. SM2 breaks the fail-closed
    #   classifier so an unclassified fault masquerades as a healthy empty store. Each is caught
    #   by its named ReadinessT29Test witness.
    {'id': 'T29-SM1-android-plain-opener-accepted-as-encrypted', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/store/SqlcipherStoreOpener.kt', 'find': '            encryptedAtRest = binding.cipherEnabled,                  // a plain binding reports false -> StoreOpener rejects', 'replace': '            encryptedAtRest = true,                                 // (mutant) the adapter always claims encrypted-at-rest regardless of the native', 'why': 'the adapter reports a store encrypted-at-rest no matter what the native cipher binding says, so a plain (cipherEnabled=false) SQLite store is accepted as if encrypted and the at-rest guarantee is silently lost (the cards named falsification: replace the production encrypted opener with plain SQLite); the encrypted-at-rest-required adapter witness falleth', 'witness': 'testSqlcipherAdapterRejectsAPlainBindingViaTheEncryptedAtRestPredicate', 'gradle_filter': '*ReadinessT29Test*'},
    {'id': 'T29-SM2-android-unclassified-fault-not-fail-closed', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/store/StoreOpenResult.kt', 'find': '            else -> StoreOpenResult.Corrupt                     // an unclassified store fault fails CLOSED', 'replace': '            else -> StoreOpenResult.Available(object : StoreHandle { override val encryptedAtRest = true; override val backupExcluded = true; override val journalMode = "wal" })   // (mutant) an unclassified fault masquerades as a healthy empty store', 'why': 'the total classifier no longer fails closed: an unrecognised store fault is reported as a healthy Available (empty) store instead of a typed terminal result, so a disk/key/corruption fault would surface as an empty healthy store (the precise defect the card forbids); the fail-closed-never-available witness falleth', 'witness': 'testUnclassifiedFaultFailsClosedNeverAvailable', 'gradle_filter': '*ReadinessT29Test*'},
    # -------------------------------------------------------------- T30 (iOS erasable private-store encryption key)
    #
    #   The T30 factory (Sources/GodstoneMesh/EncryptedStoreFactory.swift) and migration
    #   (Sources/GodstoneMesh/PlaintextToEncryptedMigration.swift) are fail-closed: a file-
    #   protection error is NEVER swallowed, a store cannot be reopened without its DEK, and
    #   an encrypted copy is verified BEFORE it is selected (the source is preserved on any
    #   pre-select fault). The cards required_semantic_negative is exactly "ignore a protection
    #   failure OR reopen without a DEK => the store test fails"; SM1/SM2 strike the two
    #   protection guards, SM3 strikes the reopen-without-DEK guard, SM4 strikes verify-before-
    #   select. Each is caught by its named ReadinessT30Tests witness. Swift platform (the tool
    #   re-syncs the ios/Packages mirror).
    {'id': 'T30-SM1-ios-swallow-protection-failure-openstore', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/EncryptedStoreFactory.swift', 'find': '        guard protection.isSuccess else { return .unavailable }               // never swallow a protection error', 'replace': '        if protection.isSuccess { _ = 0 }   // (mutant) a file-protection error is swallowed', 'why': 'a failed file-protection apply on the create path is swallowed instead of failing closed, so an unprotected store is accepted as usable; the ignore-protection-failure witness falleth (the cards named falsification)', 'witness': 'testProtectionFailureIsNeverSwallowed', 'swift_filter': 'ReadinessT30Tests'},
    {'id': 'T30-SM2-ios-swallow-protection-failure-reopen', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/EncryptedStoreFactory.swift', 'find': '        let protection = provider.applyFileProtection(paths: [path], protection: .complete)\n        guard protection.isSuccess else { return .unavailable }\n        return finalize { try self.engine.reopenRequiringDEK(path: path, dek: dek) }', 'replace': '        let protection = provider.applyFileProtection(paths: [path], protection: .complete)\n        if protection.isSuccess { _ = 0 }\n        return finalize { try self.engine.reopenRequiringDEK(path: path, dek: dek) }', 'why': 'a failed file-protection apply on the REOPEN path is swallowed instead of failing closed, so a store that lost its at-rest protection is reopened as usable; the reopen-path never-swallow witness falleth', 'witness': 'testReopenProtectionFailureIsNeverSwallowed', 'swift_filter': 'ReadinessT30Tests'},
    {'id': 'T30-SM3-ios-reopen-without-dek-accepted', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/EncryptedStoreFactory.swift', 'find': '            case .dekNotFound, .keychainUnavailable, .deviceLocked, .dekWrongLength, .protectionFailure: return .unavailable', 'replace': '            case .dekNotFound: return .available(EncryptedStoreHandle(path: "x", kind: .pinnedSQLCipher, encryptedAtRest: true, cipherVersion: 4))\n            case .keychainUnavailable, .deviceLocked, .dekWrongLength, .protectionFailure: return .unavailable', 'why': 'a missing DEK on reopen is accepted as an encrypted Available store instead of refused, so the erasability guarantee collapses and a store reopens without its key; the reopen-without-DEK witness falleth (the cards named falsification)', 'witness': 'testReopenWithoutDEKIsRejectedNeverEmptyHealthy', 'swift_filter': 'ReadinessT30Tests'},
    {'id': 'T30-SM4-ios-select-before-verify', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/PlaintextToEncryptedMigration.swift', 'find': '        guard verification.isGood else { return .sourcePreservedOnFailure(.verificationMismatch) }  // never select an unverified copy', 'replace': '        if verification.isGood { _ = 0 }   // (mutant) select the encrypted copy even when verification says it is not good', 'why': 'the encrypted copy is selected even when the verify-before-select check reports a mismatch, so an unverified or corrupt copy could be promoted and the plaintext source retired; the failed-migration-preserves-recoverable-source witness falleth', 'witness': 'testFailedMigrationPreservesRecoverableSource', 'swift_filter': 'ReadinessT30Tests'},
    # -------------------------------------------------------------- T32 (bounded receipt-relative retention across restarts, dual-isle)


    # T35 — SignedMessageV1 authorship binding inside the sealed envelope (section 15: version 0x01
    #   closed layout, domain-separated Ed25519 preimage over GMP2-SIGNED-MESSAGE-V1, BLAKE2s128
    #   sender-id/key binding, intended-local-recipient equality before inbox/ACK, exact-span and
    #   strict UTF-8 obligations, unknown-version fail-closed with NO legacy plaintext fallback).
    #   The randomized iOS signer (RFC 8032 section 9.1) forbids byte-identity claims: the court
    #   proves bidirectional AUTHENTICATION parity over pinned vectors. Five falsifications, struck
    #   on BOTH isles, each with a non-shadowed oracle (trailing-byte probe for the exact-span gate,
    #   attacker-self-signed hostile frames for the version and UTF-8 gates -- the signature alone
    #   cannot see outside the signed span). Disposable worktrees; the live tree is never touched.
    {
        'id': 'T35-RC1-android-trust-sealed-sender-without-verifying-signature',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/wire/v2/SignedMessageV1.kt',
        'find': '        if (!ok) return SenderVerificationResult.Invalid("signature does not verify over the domain preimage")',
        'replace': '        if (false) return SenderVerificationResult.Invalid("signature does not verify over the domain preimage")',
        'why': 'the receiver admits any frame whose fields parse: the attacker-authored envelope (every tampered priority/creation/body/signature variant) walks into the inbox unchallenged; the authorship binding of the sealed sender ID falleth',
        'witness': 'testModifiedPriorityTimeOrBodyBreaksTheSignature',
        'gradle_filter': '*ReadinessT35Test*',
    },
    {
        'id': 'T35-RC1-ios-trust-sealed-sender-without-verifying-signature',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/SignedMessageV1.swift',
        'find': '        if !key.isValidSignature(signature, for: preimage) { return .invalid(reason: "signature does not verify over the domain preimage") }',
        'replace': '        if false { return .invalid(reason: "signature does not verify over the domain preimage") }',
        'why': 'the iOS twin admits any frame whose fields parse without authenticating the Ed25519 binding; the attacker-authored envelope walks in; the authorship law on this isle falleth',
        'witness': 'testModifiedPriorityTimeOrBodyBreaksTheSignature',
        'swift_filter': 'ReadinessT35Tests',
    },
    {
        'id': 'T35-RC2-android-drop-intended-recipient-equality',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/wire/v2/SignedMessageV1.kt',
        'find': '        if (!recipientLocalNodeId.contentEquals(embeddedRecipient)) {',
        'replace': '        if (false) {',
        'why': 'a valid signature over the WRONG recipient is delivered: the frame reaches an inbox it was never addressed to and the ACK path commits to a peer that holds no such message; the intended-local-recipient obligation falleth',
        'witness': 'testValidSignatureWrongRecipientRejectedBeforeInbox',
        'gradle_filter': '*ReadinessT35Test*',
    },
    {
        'id': 'T35-RC2-ios-drop-intended-recipient-equality',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/SignedMessageV1.swift',
        'find': '        if embeddedRecipient != recipientLocalNodeId {',
        'replace': '        if false {',
        'why': 'the iOS twin delivers a validly signed frame to any local endpoint regardless of the embedded recipientNodeId; the wrong-recipient oracle falleth',
        'witness': 'testValidSignatureWrongRecipientRejectedBeforeInbox',
        'swift_filter': 'ReadinessT35Tests',
    },
    {
        'id': 'T35-RC3-android-drop-exact-length-obligation',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/wire/v2/SignedMessageV1.kt',
        'find': '        if (signedPlaintext.size != expectedTotal) return SenderVerificationResult.Invalid("bodyLength does not match the actual tail; the frame is not exact")',
        'replace': '        if (false) return SenderVerificationResult.Invalid("bodyLength does not match the actual tail; the frame is not exact")',
        'why': 'frames whose declared bodyLength does not match their actual tail (and frames with one byte smuggled past the signature) are accepted: the exact-span obligation of the wire format falleth',
        'witness': 'testMalformedLengthAndUtf8RejectedFailClosed',
        'gradle_filter': '*ReadinessT35Test*',
    },
    {
        'id': 'T35-RC3-ios-drop-exact-length-obligation',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/SignedMessageV1.swift',
        'find': '        if b.count != expectedTotal { return .invalid(reason: "bodyLength does not match the actual tail; the frame is not exact") }\n        let body = Data(b[(bodyLenPos + 2) ..< (bodyLenPos + 2 + bodyLength)])\n        let signature = Data(b[(bodyLenPos + 2 + bodyLength) ..< (bodyLenPos + 2 + bodyLength + sigLen)])',
        'replace': '        if false { return .invalid(reason: "bodyLength does not match the actual tail; the frame is not exact") }\n        let body = Data(b[Swift.min(bodyLenPos + 2, b.count) ..< Swift.min(bodyLenPos + 2 + bodyLength, b.count)])\n        let signature = Data(b[Swift.min(bodyLenPos + 2 + bodyLength, b.count) ..< Swift.min(bodyLenPos + 2 + bodyLength + sigLen, b.count)])',
        'why': 'the iOS twin accepts mis-declared spans and smuggled trailing bytes; slices are clamped so the mutant dies by the oracle, not by a fatal trap (a trap would report INVALID, not KILLED); the exact-span obligation on this isle falleth',
        'witness': 'testMalformedLengthAndUtf8RejectedFailClosed',
        'swift_filter': 'ReadinessT35Tests',
    },
    {
        'id': 'T35-RC4-android-drop-utf8-validator',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/wire/v2/SignedMessageV1.kt',
        'find': '        if (!isWellFormedUtf8(body)) return SenderVerificationResult.Invalid("body is not well-formed UTF-8")',
        'replace': '        if (false) return SenderVerificationResult.Invalid("body is not well-formed UTF-8")',
        'why': 'a self-signed body carrying a lone continuation byte (surrogates, overlongs, truncations) passes: no receiver validates the UTF-8 obligation of the application body and the presentation layer chokes downstream; the validator falleth',
        'witness': 'testMalformedLengthAndUtf8RejectedFailClosed',
        'gradle_filter': '*ReadinessT35Test*',
    },
    {
        'id': 'T35-RC4-ios-drop-utf8-validator',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/SignedMessageV1.swift',
        'find': '        if !isWellFormedUtf8([UInt8](body)) { return .invalid(reason: "body is not well-formed UTF-8") }',
        'replace': '        if false { return .invalid(reason: "body is not well-formed UTF-8") }',
        'why': 'the iOS twin accepts a self-signed malformed body; the UTF-8 validation obligation on this isle falleth',
        'witness': 'testMalformedLengthAndUtf8RejectedFailClosed',
        'swift_filter': 'ReadinessT35Tests',
    },
    {
        'id': 'T35-RC5-android-drop-version-rejection',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/wire/v2/SignedMessageV1.kt',
        'find': '        if (signedPlaintext[i].toInt() and 0xFF != VERSION) return SenderVerificationResult.Invalid("unknown version; there is no legacy plaintext fallback")',
        'replace': '        if (false) return SenderVerificationResult.Invalid("unknown version; there is no legacy plaintext fallback")',
        'why': 'a self-signed frame claiming version 0x02 is accepted beside the closed 0x01 layout: the version gate falleth and an unknown encoding is quietly admitted, which the card forbids -- there is no legacy plaintext fallback',
        'witness': 'testMalformedLengthAndUtf8RejectedFailClosed',
        'gradle_filter': '*ReadinessT35Test*',
    },
    {
        'id': 'T35-RC5-ios-drop-version-rejection',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/SignedMessageV1.swift',
        'find': '        if b[0] != version { return .invalid(reason: "unknown version; there is no legacy plaintext fallback") }',
        'replace': '        if false { return .invalid(reason: "unknown version; there is no legacy plaintext fallback") }',
        'why': 'the iOS twin admits a self-signed unknown-version frame; the closed-layout version gate on this isle falleth',
        'witness': 'testMalformedLengthAndUtf8RejectedFailClosed',
        'swift_filter': 'ReadinessT35Tests',
    },
    # -------------------------------------------------------------- T34 (crash-resumable wipe across transport and storage, dual-isle)
    #
    #   The durable wipe ladder (identity/CrashResumableWipe.kt + iOS twin Sources/GodstoneMesh/CrashResumableWipe.swift)
    #   must PROVE the transport drained before destruction (no resurrection of the wiped session across the point of no
    #   return), erase keys before file cleanup with FAILED erasures never treated as satisfaction (old ciphertext must
    #   die cryptographically), verify delete results distinguishing absent from busy-failed, keep the journal-bound gate
    #   unbypassable by stale UI sends, and honour the sealed journal's legacy KEY_ERASED spelling on resume. Five
    #   falsifications, struck on BOTH isles. Disposable worktrees; the live tree is never touched.
    {
        'id': 'T34-RC1-android-skip-runtime-drain',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/identity/CrashResumableWipe.kt',
        'find': '                    val receipt = runtime.drainTransport()\n                    if (!receipt.isDrained) {',
        'replace': '                    val receipt = runtime.drainTransport()\n                    if (false) {',
        'why': 'the ladder advances past REQUESTED without a Drained RuntimeDrainReceipt, so transport queues are never proven drained and an in-flight radio frame can resurrect the wiped session across the point of no return; the proof-before-destruction law falleth',
        'witness': 'testRuntimeDrainIsProvenBeforeAnyDestruction',
        'gradle_filter': '*ReadinessT34Test*',
    },
    {
        'id': 'T34-RC1-ios-skip-runtime-drain',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/CrashResumableWipe.swift',
        'find': '                let receipt = runtime.drainTransport()\n                if !receipt.isDrained {',
        'replace': '                let receipt = runtime.drainTransport()\n                if false {',
        'why': 'the ladder advances past REQUESTED without a Drained receipt so the drain is no longer proven before destruction; the proof-before-destruction oracle on the iOS twin falleth',
        'witness': 'testRuntimeDrainIsProvenBeforeAnyDestruction',
        'swift_filter': 'ReadinessT34Tests',
    },
    {
        'id': 'T34-RC2-android-ignore-failed-key-deletion',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/identity/CrashResumableWipe.kt',
        'find': '                    if (failed.isNotEmpty()) {\n                        return WipeStepResult.RetryLater(from, failed.joinToString(",") { it.keyName })',
        'replace': '                    if (false) {\n                        return WipeStepResult.RetryLater(from, failed.joinToString(",") { it.keyName })',
        'why': 'a retryable key-erasure failure is ignored and KEYS_ERASED journaled while a live key remains, so files deleted afterwards leave OLD CIPHERTEXT still decryptable; the cryptographically-erased claim dies with the ignored failure',
        'witness': 'testFailedKeyDeletionRetriesDurablyBeforeErase',
        'gradle_filter': '*ReadinessT34Test*',
    },
    {
        'id': 'T34-RC2-ios-ignore-failed-key-deletion',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/CrashResumableWipe.swift',
        'find': '                if !failedKeys.isEmpty {\n                    return .retryLater(at: from, reason: failedKeys.map { $0.keyName }.joined(separator: ","))',
        'replace': '                if false {\n                    return .retryLater(at: from, reason: failedKeys.map { $0.keyName }.joined(separator: ","))',
        'why': 'a retryable key-erasure failure is treated as satisfaction and the ladder advances with a live key; the old-ciphertext oracle on the iOS twin falleth',
        'witness': 'testFailedKeyDeletionRetriesDurablyBeforeErase',
        'swift_filter': 'ReadinessT34Tests',
    },
    {
        'id': 'T34-RC3-android-swallow-busy-delete',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/identity/CrashResumableWipe.kt',
        'find': '                    if (failed.isNotEmpty()) {\n                        return WipeStepResult.RetryLater(from, failed.joinToString(",") { it.path })',
        'replace': '                    if (false) {\n                        return WipeStepResult.RetryLater(from, failed.joinToString(",") { it.path })',
        'why': 'a busy database deletion failure is swallowed and ARTIFACTS_DELETED journaled while the db file still exists, so the durable record CLAIMS cleanup that never happened and the busy copy survives un-retried; the verify-delete-results law falleth',
        'witness': 'testBusyDatabaseFileIsRetriedAbsentIsNotFailure',
        'gradle_filter': '*ReadinessT34Test*',
    },
    {
        'id': 'T34-RC3-ios-swallow-busy-delete',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/CrashResumableWipe.swift',
        'find': '                if !failedPaths.isEmpty {\n                    return .retryLater(at: from, reason: failedPaths.joined(separator: ","))',
        'replace': '                if false {\n                    return .retryLater(at: from, reason: failedPaths.joined(separator: ","))',
        'why': 'a busy file-deletion failure is swallowed and the journal advances claiming deleted while the file lives; the busy-retry oracle on the iOS twin falleth',
        'witness': 'testBusyDatabaseFileIsRetriedAbsentIsNotFailure',
        'swift_filter': 'ReadinessT34Tests',
    },
    {
        'id': 'T34-RC4-android-gate-bypass-stale-send',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/identity/CrashResumableWipe.kt',
        'find': '    fun submitUi(msg: String): Boolean {\n        if (isWipePending) {',
        'replace': '    fun submitUi(msg: String): Boolean {\n        if (false) {',
        'why': 'the journal-bound gate is bypassed and a stale UI send is admitted mid-wipe, so the old session can publish across the point of no return; the cannot-bypass RuntimeLifecycleGate law falleth',
        'witness': 'testStaleUiSendWhilePendingIsRefused',
        'gradle_filter': '*ReadinessT34Test*',
    },
    {
        'id': 'T34-RC4-ios-gate-bypass-stale-send',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/CrashResumableWipe.swift',
        'find': '    public func submitUi(_ msg: String) -> Bool {\n        if isWipePending { bypassAttempts += 1; return false }',
        'replace': '    public func submitUi(_ msg: String) -> Bool {\n        if false { bypassAttempts += 1; return false }',
        'why': 'the gate admits stale UI sends while the ladder is pending; the cannot-bypass gate oracle on the iOS twin falleth',
        'witness': 'testStaleUiSendWhilePendingIsRefused',
        'swift_filter': 'ReadinessT34Tests',
    },
    {
        'id': 'T34-RC5-android-break-legacy-compat',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/identity/CrashResumableWipe.kt',
        'find': '            "KEY_ERASED" -> WipeJournalState.KEYS_ERASED',
        'replace': '            "KEY_ERASED" -> null',
        'why': 'the legacy KEY_ERASED spelling of the sealed journal no longer maps onto the new ladder, so an interrupted pre-T34 wipe is refused as unsupported and the device is bricked mid-wipe with keys live; the honor-current-journal-compatibility law falleth',
        'witness': 'testLegacyJournalHonoredAndUnsupportedVersionRefused',
        'gradle_filter': '*ReadinessT34Test*',
    },
    {
        'id': 'T34-RC5-ios-break-legacy-compat',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/CrashResumableWipe.swift',
        'find': '        if name == "KEY_ERASED" { return .keysErased }',
        'replace': '        if name == "KEY_ERASED" { return nil }',
        'why': 'the legacy spelling stops mapping onto the canonical state and a pre-T34 in-flight journal is refused; the compatibility oracle on the iOS twin falleth',
        'witness': 'testLegacyJournalHonoredAndUnsupportedVersionRefused',
        'swift_filter': 'ReadinessT34Tests',
    },
    # -------------------------------------------------------------- T33 (bounded store growth & observer lifetimes, dual-isle)
    #
    #   The quota/eviction/lease contract (android store/StoreQuota.kt + iOS twin Sources/GodstoneMesh/StoreQuota.swift)
    #   must never fabricate a 0 on a failed measurement; must update the delivery record in the SAME transaction as the
    #   held eviction; keep non-SOS-first / SOS-retained-LAST stable order; fire observers only on commit (an aborted tx
    #   discards its notifications); and keep cursor reads bounded. Five falsifications, on BOTH isles. Disposable worktrees.
    {
        'id': 'T33-RC1-android-fabricate-zero-heldbytes',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/store/StoreQuota.kt',
        'find': '    private fun Measured.valueOrFailed(): Long? = (this as? Measured.Values)?.value',
        'replace': '    private fun Measured.valueOrFailed(): Long? = 0L   // (mutant) a failed read is fabricated as 0',
        'why': 'a heldBytes query failure is fabricated as a real 0 so admission proceeds on a fake empty measurement and the store can grow unbounded; the no-fabricated-empty-set authority oracle falleth',
        'witness': 'testSqlFailureInHeldBytesNeverFabricatesZeroAndRefusesAdmission',
        'gradle_filter': '*ReadinessT33Test*',
    },
    {
        'id': 'T33-RC1-ios-fabricate-zero-heldbytes',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/StoreQuota.swift',
        'find': '    public static func valueOrFailed(_ m: Measured) -> Int64? { if case let .values(v) = m { return v }; return nil }',
        'replace': '    public static func valueOrFailed(_ m: Measured) -> Int64? { 0 }   // (mutant) a failed read is fabricated as 0',
        'why': 'a heldBytes query failure is fabricated as a real 0 so admission proceeds on a fake empty measurement; the authority oracle on the iOS twin falleth',
        'witness': 'testSqlFailureInHeldBytesNeverFabricatesZeroAndRefusesAdmission',
        'swift_filter': 'ReadinessT33Tests',
    },
    {
        'id': 'T33-RC2-android-eviction-leaves-delivery-unchanged',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/store/StoreQuota.kt',
        'find': '            transitions.add(Pair(r.id, DeliveryState.EVICTED))   // SAME-transaction delivery update',
        'replace': '            transitions.add(Pair(r.id, r.deliveryState))   // (mutant) delivery left unchanged by the eviction',
        'why': 'the transaction-owned eviction removes the held row but leaves its delivery record in the prior state so a stale delivery survives and held/delivery diverge; the same-transaction delivery-pairing oracle falleth',
        'witness': 'testEvictionUpdatesDeliveryStateInTheSameTransaction',
        'gradle_filter': '*ReadinessT33Test*',
    },
    {
        'id': 'T33-RC2-ios-eviction-leaves-delivery-unchanged',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/StoreQuota.swift',
        'find': '            evicted.append(r.id); trans.append((r.id, .evicted)); cum += r.size; overshoot -= r.size',
        'replace': '            evicted.append(r.id); trans.append((r.id, r.deliveryState)); cum += r.size; overshoot -= r.size   // (mutant) delivery left unchanged',
        'why': 'the eviction removes the held row but leaves the delivery in the prior state so held/delivery diverge; the delivery-pairing oracle on the iOS twin falleth',
        'witness': 'testEvictionUpdatesDeliveryStateInTheSameTransaction',
        'swift_filter': 'ReadinessT33Tests',
    },
    {
        'id': 'T33-RC3-android-held-cap-excludes-sos',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/store/StoreQuota.kt',
        'find': '        if (a.priority != b.priority) return@Comparator b.priority - a.priority',
        'replace': '        if (a.priority != b.priority) return@Comparator a.priority - b.priority',
        'why': 'the policy order is inverted so SOS (priority 0) is evicted FIRST instead of retained-last, letting a flood of non-critical rows discard the retained emergency traffic and break the stable order; the stable-eviction-order oracle falleth',
        'witness': 'testStableEvictionOrderIsDeterministic',
        'gradle_filter': '*ReadinessT33Test*',
    },
    {
        'id': 'T33-RC3-ios-held-cap-excludes-sos',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/StoreQuota.swift',
        'find': '        if a.priority != b.priority { return a.priority > b.priority }',
        'replace': '        if a.priority != b.priority { return a.priority < b.priority }',
        'why': 'the policy order is inverted so SOS is evicted FIRST instead of retained-last, breaking stable order and emergency retention; the stable-eviction-order oracle on the iOS twin falleth',
        'witness': 'testStableEvictionOrderIsDeterministic',
        'swift_filter': 'ReadinessT33Tests',
    },
    {
        'id': 'T33-RC4-android-observer-fires-before-commit',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/store/StoreQuota.kt',
        'find': '    fun abort() { inTx = false; deferred.clear() }',
        'replace': '    fun abort() { inTx = false }   // (mutant) an aborted transaction no longer discards its notifications',
        'why': 'an aborted transaction no longer discards its pending notifications, so a rolled-back tx still fires its observers and a stale/foreign event mutates committed state; the commit-only notification oracle falleth',
        'witness': 'testObserverReentryIsDeferredAndFiresOnlyAfterCommit',
        'gradle_filter': '*ReadinessT33Test*',
    },
    {
        'id': 'T33-RC4-ios-observer-fires-before-commit',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/StoreQuota.swift',
        'find': '    public func abort() { inTx = false; deferred.removeAll() }',
        'replace': '    public func abort() { inTx = false }   // (mutant) an aborted transaction no longer discards its notifications',
        'why': 'an aborted transaction no longer discards its pending notifications so a rolled-back tx still fires; the commit-only notification oracle on the iOS twin falleth',
        'witness': 'testObserverReentryIsDeferredAndFiresOnlyAfterCommit',
        'swift_filter': 'ReadinessT33Tests',
    },
    {
        'id': 'T33-RC5-android-cursor-unbounded',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/store/StoreQuota.kt',
        'find': '        return source.subList(start, minOf(start + limit, source.size))',
        'replace': '        return source.subList(start, source.size)   // (mutant) the cursor ignores its limit and over-reads the full backing',
        'why': 'the bounded cursor ignores its limit and over-reads the full backing store, an unbounded read that defeats the bounded-read contract and the DoS defence; the bounded-cursor oracle falleth',
        'witness': 'testStableEvictionOrderIsDeterministic',
        'gradle_filter': '*ReadinessT33Test*',
    },
    {
        'id': 'T33-RC5-ios-cursor-unbounded',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/StoreQuota.swift',
        'find': '        return Array(source[start..<min(start + limit, source.count)])',
        'replace': '        return Array(source[start..<source.count])   // (mutant) the cursor ignores its limit and over-reads the full backing',
        'why': 'the bounded cursor ignores its limit and over-reads the full backing store, an unbounded read defeating the bounded-read contract; the bounded-cursor oracle on the iOS twin falleth',
        'witness': 'testStableEvictionOrderIsDeterministic',
        'swift_filter': 'ReadinessT33Tests',
    },
    #
    #   The retention contract (android store/RetentionClock.kt + iOS twin
    #   Sources/GodstoneMesh/RetentionClock.swift) must implement the exact section14
    #   algorithm: NEVER replenish remaining lifetime on a reopen, COUNT a discontinuity
    #   on every unprovable reopen, and let a wall-clock ROLLBACK only shrink retention.
    #   RC1 injects the full-lifetime admit at the reopen site (the cards named
    #   falsification: reset full retention on every reopen), caught by the non-replenishing
    #   same-boot/repeat-crash oracle. RC2 removes the discontinuity increment, caught by the
    #   32-strike CLOCK_CONTINUITY_LOST oracle. RC3 removes the nonnegative clamp so a negative
    #   wall hint yields a negative debit that EXTENDS retention, caught by the rollback-never-
    #   extends oracle. Struck on BOTH isles. Roster runs in disposable worktrees; live tree untouched.
    {
        'id': 'T32-RC1-android-replenish-on-reopen',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/store/RetentionClock.kt',
        'find': '        val remaining = (cp.remainingMs - debit).coerceAtLeast(0L)                       // never below 0; never replenished',
        'replace': '        val remaining = (lifetimeMs.getValue(cp.kind) - debit).coerceAtLeast(0L)                       // (mutant) drain from the FULL lifetime, never the persisted remainder',
        'why': 'a reopen drains from the full canonical lifetime instead of the persisted remainder, so a malicious restart loop never loses the granted lifetime and the non-replenishing repeated-restart bound is lost; the repeated-malicious-crash (drain-only) oracle falleth',
        'witness': 'testRepeatedMaliciousCrashBoundAndTombstoneDiscipline',
        'gradle_filter': '*ReadinessT32Test*',
    },
    {'id': 'T32-RC2-android-discontinuity-no-increment', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/store/RetentionClock.kt', 'find': '            disc += 1', 'replace': '            // (mutant) the discontinuity is not counted, so the 32-strike clock-continuity bound never trips', 'why': 'unprovable reopens never accumulate toward the finite discontinuity limit, so a reboot loop is retained indefinitely instead of expiring CLOCK_CONTINUITY_LOST; the bounded-reboot oracle falleth', 'witness': 'testRebootWithoutContinuityIsBoundedAndEventuallyExpires', 'gradle_filter': '*ReadinessT32Test*'},
    {
        'id': 'T32-RC3-android-wall-rollback-extends',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/store/RetentionClock.kt',
        'find': '            debit = boundedWall.coerceAtLeast(MS_PER_HOUR)',
        'replace': '            debit = boundedWall   // (mutant) drop the one-hour floor: a negative hint yields a negative debit that EXTENDS retention',
        'why': 'the conservative one-hour floor is removed, so a rolled-back wall clock produces a negative debit that grows remainingMs beyond its start, defeating the rollback-never-extends law; the wall-rollback oracle falleth',
        'witness': 'testClockRollbackNeverExtendsRetention',
        'gradle_filter': '*ReadinessT32Test*',
    },
    {
        'id': 'T32-RC1-ios-replenish-on-reopen',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/RetentionClock.swift',
        'find': '        let remaining = max(0, cp.remainingMs - debit)                        // never below 0; never replenished',
        'replace': '        let remaining = max(0, RetentionPolicy.lifetimeMs[cp.kind]! - debit)                        // (mutant) drain from the FULL lifetime, never the persisted remainder',
        'why': 'a reopen drains from the full canonical lifetime instead of the persisted remainder, so a malicious restart loop never loses the granted lifetime and the non-replenishing repeated-restart bound is lost; the repeated-malicious-crash (drain-only) oracle falleth',
        'witness': 'testRepeatedMaliciousCrashBoundAndTombstoneDiscipline',
        'swift_filter': 'ReadinessT32Tests',
    },
    {'id': 'T32-RC2-ios-discontinuity-no-increment', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/RetentionClock.swift', 'find': '            disc += 1', 'replace': '            // (mutant) the discontinuity is not counted, so the 32-strike clock-continuity bound never trips', 'why': 'unprovable reopens never accumulate toward the finite discontinuity limit, so a reboot loop is retained indefinitely instead of expiring clockContinuityLost; the bounded-reboot oracle on the iOS twin falleth', 'witness': 'testRebootWithoutContinuityIsBoundedAndEventuallyExpires', 'swift_filter': 'ReadinessT32Tests'},
    {
        'id': 'T32-RC3-ios-wall-rollback-extends',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/RetentionClock.swift',
        'find': '            debit = max(msPerHour, boundedWall)',
        'replace': '            debit = boundedWall   // (mutant) drop the one-hour floor: a negative hint yields a negative debit that EXTENDS retention',
        'why': 'the conservative one-hour floor is removed, so a rolled-back wall clock produces a negative debit that grows remainingMs beyond its start, defeating the rollback-never-extends law; the wall-rollback oracle falleth',
        'witness': 'testClockRollbackNeverExtendsRetention',
        'swift_filter': 'ReadinessT32Tests',
    },
    # -------------------------------------------------------------- T31 (versioned schema migrations, dual-isle)
    #
    #   The migration engine/executor (android store/SchemaMigration.kt + its iOS twin
    #   Sources/GodstoneMesh/SchemaMigration.swift) must apply each ALTER ADD COLUMN as a
    #   non-destructive column add and must FAIL CLOSED on a future schema. SM1 makes a
    #   migration step DROP the table instead of adding a column (the cards named
    #   falsification: replace a migration with DROP TABLE), caught by the retained-data /
    #   byte-identical-immutable-fields oracle. SM2 disables the future-version gate so a
    #   future user_version is silently accepted (the second named falsification: ignore a
    #   future user_version), caught by the future-version UnsupportedVersion oracle. Struck
    #   on BOTH isles. Roster runs in disposable worktrees; the live tree is never touched.
    {'id': 'T31-SM1-android-migration-becomes-drop', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/store/SchemaMigration.kt', 'find': '            val cols = tables[tn]; if (cols != null && !cols.contains(c)) cols.add(c)', 'replace': '            tables.remove(tn); rows.remove(tn); violations += "migration dropped table (mutant ADD COLUMN becomes DROP)"', 'why': 'a migration step that should extend a table instead DROPs it, so the message ids and recipient bindings and the immutable columns are lost and the frozen fingerprint cannot hold; the retained-data / byte-identical-immutable-fields oracle falleth', 'witness': 'testImmutableFieldsByteIdenticalAndBindingsPreserved', 'gradle_filter': '*ReadinessT31Test*'},
    {'id': 'T31-SM2-android-future-version-ignored', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/store/SchemaMigration.kt', 'find': '        if (currentVersion > supportedMax) return MigrationResult.UnsupportedVersion(currentVersion, supportedMax)', 'replace': '        if (false && currentVersion > supportedMax) return MigrationResult.UnsupportedVersion(currentVersion, supportedMax)', 'why': 'a schema newer than the supported maximum is no longer refused; the engine proceeds to open or downgrade a store it cannot understand instead of failing closed with UnsupportedVersion; the future-version UnsupportedVersion oracle falleth', 'witness': 'testFutureVersionIsUnsupportedAndNothingDeleted', 'gradle_filter': '*ReadinessT31Test*'},
    {'id': 'T31-SM1-ios-migration-becomes-drop', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/SchemaMigration.swift', 'find': '            if var cols = tables[tn], !cols.contains(c) { cols.append(c); tables[tn] = cols }', 'replace': '            // (mutant) ADD COLUMN is silently skipped: the migration neither extends the schema nor preserves it (the DROP-TABLE falsification, crash-free)', 'why': 'a migration step that should extend a table silently does so not, so the frozen fingerprint can never be reached and the engine must refuse with RepairRequired instead of Upgraded; the retained-data / byte-identical-immutable-fields oracle on the iOS twin falleth', 'witness': 'testImmutableFieldsByteIdenticalAndBindingsPreserved', 'swift_filter': 'ReadinessT31Tests'},
    {'id': 'T31-SM2-ios-future-version-ignored', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/SchemaMigration.swift', 'find': '        if currentVersion > supportedMax { return .unsupportedVersion(found: currentVersion, supportedMax: supportedMax) }', 'replace': '        if currentVersion > supportedMax && false { return .unsupportedVersion(found: currentVersion, supportedMax: supportedMax) }   // (mutant) the future-version fail-closed gate is disabled', 'why': 'a schema newer than the supported maximum is no longer refused; the engine proceeds instead of failing closed with UnsupportedVersion; the future-version oracle on the iOS twin falleth', 'witness': 'testFutureVersionIsUnsupportedAndNothingDeleted', 'swift_filter': 'ReadinessT31Tests'},
    {
        "id": "T20-SM1-android-token-bypass",
        "platform": "jvm",
        "file": "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt",
        "find": "        if (client.clientToken != clientToken || client.gattGeneration != gattGen) {",
        "replace": "        if (false && (client.clientToken != clientToken || client.gattGeneration != gattGen)) {",
        "why": "the token validation of the central's disconnect arm is short-circuited: a stale event falls where a fresh one belonged, with every symbol and test present",
        "witness": "testTheCrossedTraceFromAForeignManagerIsRefusedAndTheWrongTokenDiscarded",
        "gradle_filter": "*ReadinessT20Test*",
    },
    {
        "id": "T20-SM2-android-advance-forever",
        "platform": "jvm",
        "file": "android/mesh/src/main/java/io/godstone/mesh/transport/BleRecord.kt",
        "find": "nowSec >= asm.lease.deadlineMono",
        "replace": "nowSec >= asm.lastActivityTimeSec + AssemblyLease.LEASE_SECONDS",
        "why": "the absolute term rides the refreshed activity stamp: a dribbling peer advances the deadline forever and the relation never falls through its owner",
        "witness": "testTheAbsoluteTermExpiresTheDribbledAssemblyThoughTheSlidingWindowIsRefreshed",
        "gradle_filter": "*ReadinessT20Test*",
    },
    {
        "id": "T20-SM3-ios-epoch-bypass",
        "platform": "swift",
        "file": "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift",
        # the first campaign confessed this needle EQUIVALENT in the steady
        # rig - there the lifetime record's own identical epoch check,
        # downstream, refuses the same misrepresented source, masking the
        # bypass. The mask lifts under rotation: the elder stale-manager
        # case rotates the context between the event's capture and its
        # delivery, and there this first clause stands alone at the gate -
        # observable, and killable. The witness is aimed at that case; the
        # twin class runs beside it to keep the whole field honest.
        "find": "        guard sourceEpoch == context.epoch, context.epoch == currentTransportEpoch else { return false }",
        # the second campaign's elimination argued further: the elder event
        # is refused at the second conjunct (context.epoch against the
        # transport's live counter), not the first - so a faithful bypass of
        # THE epoch check sweeps the whole first line, as the card's name
        # demands, and the retained clauses no longer stand keep
        "replace": "        guard true else { return false }",
        "why": "the epoch revalidation of the threefold authenticator is short-circuited: a misrepresented epoch is admitted, with every symbol and test present",
        # the twelfth case of the twin suite is the court of this clause
        # alone: the selfsame event shape at the selfsame door, every other
        # counsel true, the epoch only misrepresented - and the control at
        # the end proves the true epoch passes where the false one fell
        "witness": "testTheStaleEpochAtTheUnsubscribeDoorIsRefusedByTheEpochClauseAlone",
        "swift_filters": ["ReadinessT20Tests"],
    },
    {
        "id": "T20-SM4-ios-sender-bypass",
        "platform": "swift",
        "file": "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift",
        "find": "        guard sender === expectedManager else { return false }",
        "replace": "        guard true || sender === expectedManager else { return false }",
        "why": "the source-instance identity of the threefold authenticator is short-circuited: a foreign manager speaks, with every symbol and test present",
        "witness": "testTheCrossedTraceFromAForeignManagerIsRefusedAndTheWrongTokenDiscarded",
        "swift_filter": "ReadinessT20Tests",
    },
    {
        "id": "T20-SM5-ios-advance-forever",
        "platform": "swift",
        "file": "ios/Godstone/Sources/GodstoneMesh/BleRecord.swift",
        "find": "            if now >= asm.lease.deadlineMono {",
        "replace": "            if now >= asm.lastActivityTime + AssemblyLease.leaseSeconds {",
        "why": "the absolute term rides the refreshed activity stamp: a dribbling peer advances the deadline forever and the relation never falls through its owner",
        "witness": "testTheAbsoluteTermExpiresTheDribbledAssemblyThoughTheSlidingWindowIsRefreshed",
        "swift_filter": "ReadinessT20Tests",
    },
    {
        "id": "T21-HS1-android-ready-before-admission",
        "platform": "jvm",
        "file": "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt",
        "find": "        if (verdict !is TransportResult.Admitted) {\n            // the reservation failed or the queue fell Closed: no HS3 is",
        "replace": "        if (false) {\n            // the reservation failed or the queue fell Closed: no HS3 is",
        "why": "the HS3 reservation gate is short-circuited: the transport marketh the relation trusted READY though the writer refused the record, publishing a link that was never admitted",
        "witness": "testTheHS3ReservationFailureClosesTheRelationExactly",
        "gradle_filter": "*ReadinessT21Test*",
    },
    {
        "id": "T21-HS2-android-raw-noise-direct",
        "platform": "jvm",
        "file": "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt",
        "find": "        val hs3 = registry.initiatorProcessHs2(conn.peerId, record.payload, advertised) ?: run {\n            // trust rejected: HS3 is withheld and the exact relation closes\n            recordRejection(conn.peerId, \"hs.read.initiator\", \"hs2 rejected\")\n            closeInitiatorRelation(peerAddress)\n            return\n        }",
        "replace": "        val hs3 = registry.initiatorProcessHs2(conn.peerId, record.payload, advertised) ?: ByteArray(0)",
        "why": "the trust gate of the second message is swallowed: a rejected controller still marcheth, the transport carrying an empty HS3 into the ready state - untrusted raw Noise spoken directly over the link",
        "witness": "testTheTrustRejectionWithholdsHS3AndClosesTheRelationExactly",
        "gradle_filter": "*ReadinessT21Test*",
    },
    # ---------------------------------------------------------------- T22
    #
    #   The responders record path. The cards named control (mark ready after
    #   HS1 or HS2 rather than after the trusted HS3) is SM1/SM3; the stage gate
    #   and the unsealed third are SM2/SM4. Each witness is a case of the
    #   ReadinessT22 court; each must FAIL under the mutation and pass beside.

    {
        "id": "T22-SM1-android-ready-at-first",
        "platform": "jvm",
        "file": "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt",
        "find": '                conn.beginHandshake()',
        "replace": '                if (conn.beginHandshake() != false) conn.markTrustedReady()',
        "why": "the responders first arm marketh the connection trusted-ready at once, so the second is never proved - the card forbids marking ready before the trusted third",
        "witness": "testTheResponderAnswerethTheExpectedFirstWithTheQueuedSecond",
        "gradle_filter": "*ReadinessT22Test*",
    },
    {
        "id": "T22-SM2-android-stage-gate-open",
        "platform": "jvm",
        "file": "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt",
        "find": '                if (conn.state != BleConnectionState.HANDSHAKE_IN_PROGRESS) {',
        "replace": '                if (false) {',
        "why": "the stage gate of the third arm is cut away, so a third spoken out of order is carried to the registry instead of felled - section thirteen forbids this",
        "witness": "testTheThirdRecordBeforeTheFirstIsRefusedAndTheRelationFalleth",
        "gradle_filter": "*ReadinessT22Test*",
    },
    {
        "id": "T22-SM3-swift-ready-at-first",
        "platform": "swift",
        "file": "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift",
        "find": '            _ = conn.beginHandshake()',
        "replace": '            if conn.beginHandshake() { conn.markTrustedReady() }',
        "why": "the responders first arm upon the isle marketh ready at once, the second unproved - the selfsame card-forbidden mutation, isle dialect",
        "witness": "testTheResponderAnswerethTheExpectedFirstWithTheQueuedSecond",
        "swift_filters": ["ReadinessT22Tests"],
    },
    {
        "id": "T22-SM4-swift-accept-unsealed-third",
        "platform": "swift",
        "file": "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift",
        "find": '            guard registry.responderProcessHs3(centralId, hs3: record.payload, advertisedRemoteHint: hint) else {',
        "replace": '            guard true else {',
        "why": "the responders third arm accepteth the counsel though the controller never sealed it - the card saith only a trusted HS3 install eth a usable session",
        "witness": "testTheTamperedThirdPerishethTheRelationExactly",
        "swift_filters": ["ReadinessT22Tests"],
    },

    # ---------------------------------------------------------------- T23
    #
    #   Section thirteens handshake policy, both isles. The two named
    #   controls - expose LinkReady without the sealed key-confirmation
    #   (SM2), and feed a duplicate HS2 into the controller (SM1) - and
    #   the no-in-place-retransmission, the deadline/lease partition, and
    #   the never-forward-the-control laws are each broken on BOTH isles.
    {
        "id": "T23-SM1-android-dup-hs2-reruns-controller",
        "platform": "jvm",
        "file": "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt",
        "find": "        if (conn.transcript.knows(BleRecordType.HS2.typeCode.toInt() and 0xFF, record.recordSeq, record.payload)) {",
        "replace": "        if (false) {",
        "why": "the transcripts exact-duplicate guard of the second arm is short-circuited, so a byte-for-byte re-presenting HS2 runneth the Noise controller twice - section thirteen forbids retransmission in place",
        "witness": "testTheDuplicateSecondTaleRunnethNotTheControllerTwice",
        "gradle_filter": "*ReadinessT23Test*",
    },
    {
        "id": "T23-SM2-android-linkready-before-confirmation",
        "platform": "jvm",
        "file": "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt",
        "find": "                conn.transcript.remember(BleRecordType.HS3.typeCode.toInt() and 0xFF, record.recordSeq, record.payload)\n                if (!conn.markTrustedReady()) {",
        "replace": "                conn.transcript.remember(BleRecordType.HS3.typeCode.toInt() and 0xFF, record.recordSeq, record.payload)\n                publishApplicationLinkReadyOnce(conn.peerId)\n                if (!conn.markTrustedReady()) {",
        "why": "the trusted hour publisheth the application LinkReady at once, before any sealed key-confirmation - the cards named control: expose readiness without encrypted confirmation",
        "witness": "testTheTrustedHourAlonePublishethNoApplicationReadiness",
        "gradle_filter": "*ReadinessT23Test*",
    },
    {
        "id": "T23-SM3-android-accept-forged-echo",
        "platform": "jvm",
        "file": "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt",
        "find": "        if (conn.keyConfirmation.matchesAndConsume(frame.challenge)) {",
        "replace": "        if (true) {",
        "why": "the echo is never matched against the standing challenge, so a forged or stale response confirme the relation - section thirteen requireth a matching, single-shot echo",
        "witness": "testAForgedEchoIsRefusedAndPublishethNothing",
        "gradle_filter": "*ReadinessT23Test*",
    },
    {
        "id": "T23-SM4-android-deadline-reaps-inflight",
        "platform": "jvm",
        "file": "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt",
        "find": "            conn.leaseCountForTest() == 0) {\n            conn.handshakeDeadline.markFired()\n            conn.transcript.forgetAll()\n            conn.keyConfirmation.clear()\n            recordDispatchViolation(conn.peerId, \"hs.deadline\", HandshakeDispatchViolation.HANDSHAKE_DEADLINE_LAPSED)\n            recordRejection(conn.peerId, \"ingest.write\", \"handshake deadline lapsed\")",
        "replace": "            true) {\n            conn.handshakeDeadline.markFired()\n            conn.transcript.forgetAll()\n            conn.keyConfirmation.clear()\n            recordDispatchViolation(conn.peerId, \"hs.deadline\", HandshakeDispatchViolation.HANDSHAKE_DEADLINE_LAPSED)\n            recordRejection(conn.peerId, \"ingest.write\", \"handshake deadline lapsed\")",
        "why": "the nothing-in-flight clause of the deadline reap is cut away, so the owners hand reapeth a reassembly the assemblers lease doth govern - the twain must not quarrel",
        "witness": "testATravellingReassemblyIsLeftUntoTheLeaseNotReapedByTheHour",
        "gradle_filter": "*ReadinessT23Test*",
    },
    {
        "id": "T23-SM5-android-control-forwarded",
        "platform": "jvm",
        "file": "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt",
        "find": "                            if (!takeInboundKeyConfirmation(peerId, outcome.plaintext)) {\n                                trySend(peerId to outcome.plaintext)\n                            }",
        "replace": "                            takeInboundKeyConfirmation(peerId, outcome.plaintext)\n                            trySend(peerId to outcome.plaintext)",
        "why": "a sealed key-confirmation control, though hearkened by D2, is forwarded to the application - section thirteen saith the control PING is never forwarded nor persisted",
        "witness": "testTheSealedRoundCarriethToApplicationReadinessOnce",
        "gradle_filter": "*ReadinessT23Test*",
    },
    {
        "id": "T23-SM1-ios-dup-hs2-reruns-controller",
        "platform": "swift",
        "file": "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift",
        "find": "        if conn.transcript.knows(kind: Self.hsKind(.hs2),\n                                 sequence: Int(record.recordSeq),\n                                 payload: record.payload) {\n            recordRejection(peerId: peerId, site: \"hs.read.initiator\",\n                            reason: \"hs2 duplicate hearkened not\")\n            return\n        }",
        "replace": "        if false {\n            recordRejection(peerId: peerId, site: \"hs.read.initiator\",\n                            reason: \"hs2 duplicate hearkened not\")\n            return\n        }",
        "why": "the transcripts exact-duplicate guard of the second arm is short-circuited, so a byte-for-byte re-presenting HS2 runneth the Noise controller twice - section thirteen forbids retransmission in place",
        "witness": "testTheDuplicateSecondTaleRunnethNotTheControllerTwice",
        "swift_filters": ["ReadinessT23Tests"],
    },
    {
        "id": "T23-SM2-ios-linkready-before-confirmation",
        "platform": "swift",
        "file": "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift",
        "find": "            conn.transcript.remember(kind: Self.hsKind(.hs3),\n                                     sequence: Int(record.recordSeq),\n                                     payload: record.payload)\n            guard conn.markTrustedReady() else {",
        "replace": "            conn.transcript.remember(kind: Self.hsKind(.hs3),\n                                     sequence: Int(record.recordSeq),\n                                     payload: record.payload)\n            _ = publishApplicationLinkReadyOnce(conn.peerId)\n            guard conn.markTrustedReady() else {",
        "why": "the trusted hour publisheth the application LinkReady at once, before any sealed key-confirmation - the cards named control: expose readiness without encrypted confirmation",
        "witness": "testTheTrustedHourAlonePublishethNoApplicationReadiness",
        "swift_filters": ["ReadinessT23Tests"],
    },
    {
        "id": "T23-SM3-ios-accept-forged-echo",
        "platform": "swift",
        "file": "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift",
        "find": "        if conn.keyConfirmation.matchesAndConsume(frame.challenge) {",
        "replace": "        if true {",
        "why": "the echo is never matched against the standing challenge, so a forged or stale response confirme the relation - section thirteen requireth a matching, single-shot echo",
        "witness": "testAForgedEchoIsRefusedAndPublishethNothing",
        "swift_filters": ["ReadinessT23Tests"],
    },
    {
        "id": "T23-SM4-ios-deadline-reaps-inflight",
        "platform": "swift",
        "file": "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift",
        "find": "                let stalledExchange = conn.handshakeEngaged && conn.handshakeDeadlineExpired()\n                    && conn.leaseCount() == 0\n                let unansweredRound = conn.state == .ready && conn.keyConfirmation.isAwaitingEcho()\n                    && conn.keyConfirmation.echoLapsed() && conn.leaseCount() == 0\n                let ingested = conn.ingestInboundAttValue(v)",
        "replace": "                let stalledExchange = conn.handshakeEngaged && conn.handshakeDeadlineExpired()\n                    && true\n                let unansweredRound = conn.state == .ready && conn.keyConfirmation.isAwaitingEcho()\n                    && conn.keyConfirmation.echoLapsed() && conn.leaseCount() == 0\n                let ingested = conn.ingestInboundAttValue(v)",
        "why": "the nothing-in-flight clause of the deadline reap is cut away, so the owners hand reapeth a reassembly the assemblers lease doth govern - the twain must not quarrel",
        "witness": "testATravellingReassemblyIsLeftUntoTheLeaseNotReapedByTheHour",
        "swift_filters": ["ReadinessT23Tests"],
    },
    {
        "id": "T23-SM5-ios-control-forwarded",
        "platform": "swift",
        "file": "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift",
        "find": "                        if self.takeInboundKeyConfirmation(peerId: peerId, opened: clear) {\n                            return\n                        }\n                        self.delegate?.transportDidReceive(data: clear, peerId: peerId)",
        "replace": "                        _ = self.takeInboundKeyConfirmation(peerId: peerId, opened: clear)\n                        self.delegate?.transportDidReceive(data: clear, peerId: peerId)",
        "why": "a sealed key-confirmation control, though hearkened by D2, is forwarded to the application - section thirteen saith the control PING is never forwarded nor persisted",
        "witness": "testTheSealedRoundCarriethToApplicationReadinessOnce",
        "swift_filters": ["ReadinessT23Tests"],
    },
    # T36 -- SendDirectAuthority: the atomic authored DIRECT send command (card: SendDirect(recipientTrustRef,
    # utf8Body) returns an immutable logical message ID only after durable enqueue; retry loads
    # identical persisted bytes; changed recipient/body/priority creates a NEW logical send; the
    # 400-byte UTF-8 DIRECT profile is enforced BEFORE signing). Five named falsifications, two isles.
    {
        'id': 'T36-RC1-android-retry-recreated-the-logical-identity',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/SendDirectAuthority.kt',
        'find': '        if (pinned != null && pinned.bindingDigest.contentEquals(digest)) {',
        'replace': '        if (false && pinned != null && pinned.bindingDigest.contentEquals(digest)) {',
        'why': 'the replay branch never answers; the retry of the same intent token falls through to the fresh path and MINTS a new nonce and a NEW logical id -- identical persisted bytes are broken at the source',
        'witness': 'testRetryOfSameIntentTokenLoadsIdenticalPersistedBytes',
        'gradle_filter': '*ReadinessT36Test*',
    },
    {
        'id': 'T36-RC1-ios-retry-recreated-the-logical-identity',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/SendDirectAuthority.swift',
        'find': '        if let row = journal.load(command.intentId), row.bindingDigest == digest {',
        'replace': '        if let row = journal.load(command.intentId), false, row.bindingDigest == digest {',
        'why': 'the iOS twin: the pinned row is never recognised, the retry re-creates through the factory -- the replay-loads-identical-bytes law dies on this isle too',
        'witness': 'testRetryOfSameIntentTokenLoadsIdenticalPersistedBytes',
        'swift_filter': 'ReadinessT36Tests/testRetryOfSameIntentTokenLoadsIdenticalPersistedBytes',
    },
    {
        'id': 'T36-RC2-android-replay-re-resolved-the-recipient',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/SendDirectAuthority.kt',
        'find': '        if (pinned != null && pinned.bindingDigest.contentEquals(digest)) {',
        'replace': '        if (pinned != null && trustResolver.resolve(command.recipientTrustRef) != null && pinned.bindingDigest.contentEquals(digest)) {',
        'why': 'the replay path consults the trust table again; after a rotation the replay would resolve CURRENT material behind a token that must answer from the pinned generation -- the pin-the-generation law is defeated and the resolver counters move where they must not',
        'witness': 'testKeyRotationRacePinsTheAcceptedGeneration',
        'gradle_filter': '*ReadinessT36Test*',
    },
    {
        'id': 'T36-RC2-ios-replay-re-resolved-the-recipient',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/SendDirectAuthority.swift',
        'find': '        if let row = journal.load(command.intentId), row.bindingDigest == digest {',
        'replace': '        if let row = journal.load(command.intentId), trustResolver.resolve(recipientTrustRef: command.recipientTrustRef) == ResolvedRecipient.absent || true, row.bindingDigest == digest {',
        'why': 'the iOS twin resolves behind the pinned token on every replay; the resolver counter increments where the sealed law demands silence',
        'witness': 'testKeyRotationRacePinsTheAcceptedGeneration',
        'swift_filter': 'ReadinessT36Tests/testKeyRotationRacePinsTheAcceptedGeneration',
    },
    {
        'id': 'T36-RC3-android-id-handed-out-before-the-commit-proved',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/SendDirectAuthority.kt',
        'find': '            else -> mapEnqueueRejection(res)',
        'replace': '            else -> SendDirectResult.DurablyEnqueued(frame.msgId.copyOf(), true)',
        'why': 'the durable commit is never consulted before the immutable id leaves the authority: the disk-full refusal ships an id anyway -- an id for bytes that were never durably held',
        'witness': 'testDiskFullRefusesSendDistinguishingFailureFromEmpty',
        'gradle_filter': '*ReadinessT36Test*',
    },
    {
        'id': 'T36-RC3-ios-id-handed-out-before-the-commit-proved',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/SendDirectAuthority.swift',
        'find': '        switch enq {\n        case .created:\n            advanceQuietly(intentId: command.intentId, from: .authored, to: .committed)\n            return .durablyEnqueued(logicalMessageId: expectId, fromRetry: false)\n        case .alreadyQueuedSameBinding:\n            advanceQuietly(intentId: command.intentId, from: .authored, to: .committed)\n            return .durablyEnqueued(logicalMessageId: expectId, fromRetry: true)\n        case .canonicalFrameMismatch: return .rejected(reason: .enqueueCanonicMismatch)\n        case .rejectedCapacity:       return .rejected(reason: .enqueueCapacity)\n        case .conflictRecipient:      return .rejected(reason: .enqueueConflictRecipient)\n        case .rejectedTerminalState:  return .rejected(reason: .enqueueTerminalState)\n        case .inconsistentState:      return .rejected(reason: .enqueueInconsistent)\n        case .storageFailure:         return .rejected(reason: .enqueueStorageFailure)',
        'replace': '        switch enq {\n        case .created:\n            advanceQuietly(intentId: command.intentId, from: .authored, to: .committed)\n            return .durablyEnqueued(logicalMessageId: expectId, fromRetry: false)\n        case .alreadyQueuedSameBinding:\n            advanceQuietly(intentId: command.intentId, from: .authored, to: .committed)\n            return .durablyEnqueued(logicalMessageId: expectId, fromRetry: true)\n        case .canonicalFrameMismatch: return .rejected(reason: .enqueueCanonicMismatch)\n        case .rejectedCapacity:       return .rejected(reason: .enqueueCapacity)\n        case .conflictRecipient:      return .rejected(reason: .enqueueConflictRecipient)\n        case .rejectedTerminalState:  return .rejected(reason: .enqueueTerminalState)\n        case .inconsistentState:      return .rejected(reason: .enqueueInconsistent)\n        case .storageFailure:         return .durablyEnqueued(logicalMessageId: expectId, fromRetry: false)',
        'why': 'the iOS twin hands the id even when the store reports the storage fault; rejected carries no id is violated end to end',
        'witness': 'testDiskFullRefusesSendDistinguishingFailureFromEmpty',
        'swift_filter': 'ReadinessT36Tests/testDiskFullRefusesSendDistinguishingFailureFromEmpty',
    },
    {
        'id': 'T36-RC4-android-profile-gate-moved-after-authoring',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/SendDirectAuthority.kt',
        'find': '        if (body.size > SignedMessageV1.BODY_MAX) return SendDirectResult.Rejected(SendDirectRejection.BodyTooLarge)',
        'replace': '        if (false) return SendDirectResult.Rejected(SendDirectRejection.BodyTooLarge)',
        'why': 'the 400-byte profile stops gating before authoring: the oversize body reaches the resolver, the factory and the signing authority before the sealed author itself refuses -- the card law "profile BEFORE signing" is inverted',
        'witness': 'testBodyProfileGateBeforeAnyAuthoring',
        'gradle_filter': '*ReadinessT36Test*',
    },
    {
        'id': 'T36-RC4-ios-profile-gate-moved-after-authoring',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/SendDirectAuthority.swift',
        'find': '        guard command.bodyUtf8.count <= SignedMessageV1.bodyMax else { return .rejected(reason: .bodyTooLarge) }',
        'replace': '        guard command.bodyUtf8.count <= 4000 else { return .rejected(reason: .bodyTooLarge) }',
        'why': 'the iOS profile widens to let the oversize body travel to the authoring boundary before refusal; creates and resolves move where the gate must have stopped them',
        'witness': 'testBodyProfileGateBeforeAnyAuthoring',
        'swift_filter': 'ReadinessT36Tests/testBodyProfileGateBeforeAnyAuthoring',
    },
    {
        'id': 'T36-RC5-android-changed-content-replayed-the-pinned-row',
        'platform': 'jvm',
        'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/SendDirectAuthority.kt',
        'find': '        if (pinned != null && pinned.bindingDigest.contentEquals(digest)) {',
        'replace': '        if (pinned != null) {',
        'why': 'the binding digest stops being consulted: changed content under one intent token replays the OLD pinned row instead of creating a NEW logical send -- the changed-content-never-replays law falleth',
        'witness': 'testChangedRecipientOrBodyOrPriorityCreatesNewLogicalSend',
        'gradle_filter': '*ReadinessT36Test*',
    },
    {
        'id': 'T36-RC5-ios-changed-content-replayed-the-pinned-row',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/SendDirectAuthority.swift',
        'find': '        if let row = journal.load(command.intentId), row.bindingDigest == digest {',
        'replace': '        if let row = journal.load(command.intentId) {',
        'why': 'the iOS twin ignores the digest: the changed body under the same token replays the old id; the court counts the created sends and finds them short',
        'witness': 'testChangedRecipientOrBodyOrPriorityCreatesNewLogicalSend',
        'swift_filter': 'ReadinessT36Tests/testChangedRecipientOrBodyOrPriorityCreatesNewLogicalSend',
    },
]

EXEC_RE = re.compile(r"Executed ([0-9]+) tests, with ([0-9]+) failures")
# the failed-case extractor, stated as one expression: each legacy line that
# pronounces a method failed yields the method's name, and nothing else.
FAILED_CASE_RE = re.compile(r"Test Case '-\[[^\]]*? ([A-Za-z][A-Za-z0-9_]*?)\]' failed")
SWIFT_COMPILE_RE = re.compile(r"\.swift:[0-9]+:[0-9]+: error:")
KT_COMPILE_RE = re.compile(r"^e: ", re.M)


def _worktree_add(head, wt_path):
    subprocess.run(["git", "worktree", "add", "--force", "--detach", wt_path, head],
                   cwd=ROOT, check=True, capture_output=True, timeout=300)
    subprocess.run(["git", "checkout", "--force", head], cwd=wt_path, check=True,
                   capture_output=True, timeout=300)
    st = subprocess.run(["git", "status", "--porcelain"], cwd=wt_path, check=True,
                        capture_output=True, timeout=120).stdout.decode("utf-8", "replace")
    assert st.strip() == "", "the worktree is not pristine:\n" + st


def _worktree_remove(wt_path):
    subprocess.run(["git", "worktree", "remove", "--force", wt_path], cwd=ROOT,
                   capture_output=True, timeout=300)
    subprocess.run(["git", "worktree", "prune"], cwd=ROOT, capture_output=True, timeout=300)


def _run_harness(entry, wt_path, timeout=2400):
    """Run the witness set once. Returns (build_exit, tests_run, failed_set, blob)."""
    if entry["platform"] == "jvm":
        proc = subprocess.run(
            ["./gradlew", ":mesh:testDebugUnitTest", "--no-daemon", "-q",
             "--tests", entry["gradle_filter"]],
            cwd=os.path.join(wt_path, "android"), capture_output=True, text=True,
            timeout=timeout)
        blob = (proc.stdout or "") + (proc.stderr or "")
        build_exit = 1 if KT_COMPILE_RE.search(blob) else 0
        xml_dir = os.path.join(wt_path, "android", "mesh", "build", "test-results",
                               "testDebugUnitTest")
        run = 0
        fails = 0
        failed = set()
        if os.path.isdir(xml_dir):
            for name in sorted(os.listdir(xml_dir)):
                if not (name.startswith("TEST-") and name.endswith(".xml")):
                    continue
                t = open(os.path.join(xml_dir, name), encoding="utf-8").read()
                m = re.search(r'tests="([0-9]+)" skipped="[0-9]+" failures="([0-9]+)" errors="([0-9]+)"', t)
                if not m:
                    continue
                run += int(m.group(1))
                fails += int(m.group(2)) + int(m.group(3))
                for cn, _det in re.findall(
                        r'<testcase name="([^"]+)"[^>]*>\s*<(?:failure|error)[^>]*message="([^"]*)"', t):
                    failed.add(cn)
        return build_exit, (run if run else None), failed, blob
    # the class-form filter is this harness's dialect: the method-form
    # filter answers 'Test run with 0 tests' and blinds the oracle
    argv = ["swift", "test", "--package-path", "ios/Packages/GodstoneFoundation"]
    for flt in entry.get("swift_filters", [entry.get("swift_filter", "ReadinessT20Tests")]):
        argv += ["--filter", flt]
    proc = subprocess.run(argv, cwd=wt_path, capture_output=True, text=True, timeout=timeout)
    blob = (proc.stdout or "") + (proc.stderr or "")
    build_exit = 1 if SWIFT_COMPILE_RE.search(blob) else 0
    totals = [int(a) for a, b in EXEC_RE.findall(blob) if int(a) >= 1]
    run = max(totals) if totals else None
    failed = {n for n in FAILED_CASE_RE.findall(blob) if n}
    return build_exit, run, failed, blob


def _classify(entry, build_exit, run, failed, baseline_ok):
    if not baseline_ok:
        return "INVALID", "the baseline itself did not pass unmutated"
    if build_exit != 0:
        return "INVALID", "the mutant did not compile"
    witness_tail = entry["witness"].rpartition("/")[2].rpartition(".")[2]
    hit = any(witness_tail in f or f == witness_tail for f in failed)
    if hit:
        return "KILLED", "witness %s failed as intended (%d failed case(s))" % (
            witness_tail, len(failed))
    if run is None or run == 0:
        return "INVALID", "the harness executed nothing"
    if failed:
        return "ESCAPED", ("the named witness stayed green; other cases failed (" +
                           ", ".join(sorted(failed))[:180] + ") - inspect")
    return "ESCAPED", "the witness stayed green against the mutant"


def run_semantic(report_only, emit_dir, baseline_sha, work_parent):
    head = baseline_sha or subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True,
        text=True).stdout.strip()
    rows = []
    tally = {k: 0 for k in ("KILLED", "SKIPPED", "INVALID", "TIMEOUT", "ESCAPED")}
    print("SEMANTIC lineage (oracle: the readiness suites' named witnesses; "
          "disposable worktrees; the live tree is never touched)")
    for spec in SEMANTIC:
        entry = dict(spec)
        entry["patch_sha"] = _sha_text(entry["find"] + "\n==\n" + entry["replace"])
        entry["started_utc"] = _now_utc()
        entry["ended_utc"] = None
        wt_path = os.path.join(work_parent, "wt_" + entry["id"])
        if os.path.exists(wt_path):
            _worktree_remove(wt_path)
        try:
            _worktree_add(head, wt_path)
            # machine-local provisioning: the SDK pointer is uncommitted by
            # law, so the lab cannot inherit it from the revision. Copy it in
            # (provisioning, not test content) before any harness may speak.
            prov = os.path.join(ROOT, "android", "local.properties")
            if os.path.exists(prov):
                shutil.copyfile(prov, os.path.join(wt_path, "android", "local.properties"))
            # the mirrored package is the compiler's true input on the swift
            # side; regenerate it in the lab so the run reads the very sources
            # under audit, and let any drift show rather than be hidden
            subprocess.run([sys.executable, "scripts/sync_ios_foundation_package.py"],
                           cwd=wt_path, capture_output=True, timeout=300, check=True)
            target = os.path.join(wt_path, entry["file"])
            text = open(target, encoding="utf-8").read()
            anchor_count = text.count(entry["find"])
            if anchor_count != 1:
                tally["SKIPPED"] += 1
                rows.append(_row(entry, head, "semantic", anchor_count, None,
                                [entry["witness"]], None, "SKIPPED",
                                "anchor seen %d times; never counted as a catch" % anchor_count,
                                None))
                print("  SKIPPED  %-34s anchor %d -- the needle moved on"
                      % (entry["id"], anchor_count))
                continue
            # 1. the baseline must pass unmutated, or nothing below may claim a kill
            be0, run0, failed0, blob0 = _run_harness(entry, wt_path)
            baseline_ok = be0 == 0 and run0 not in (None, 0) and not failed0
            # 2. install the mutant, exactly once
            open(target, "w", encoding="utf-8").write(
                text.replace(entry["find"], entry["replace"], 1))
            post = open(target, encoding="utf-8").read()
            assert post.count(entry["replace"]) == 1 and post.count(entry["find"]) == 0, \
                "the mutation did not install cleanly"
            # the island's compiler reads the mirrored package: after any
            # mutation of a canonical source the mirror must be re-synced,
            # or the mutant never reaches the binary and a false escape is
            # recorded against a witness that never saw the mutation
            subprocess.run([sys.executable, "scripts/sync_ios_foundation_package.py"],
                           cwd=wt_path, capture_output=True, timeout=300, check=True)
            if entry["platform"] == "swift":
                # a witness may only swear upon the mirrored package it saw
                # with its own eyes: confirm the mutation is in the compiler's
                # true input, retrying the sync once should a racing teardown
                # of the previous harness have obscured it
                mir = os.path.join(wt_path, entry["file"].replace(
                    "ios/Godstone/Sources/", "ios/Packages/GodstoneFoundation/Sources/"))
                for _ in range(2):
                    mt = open(mir, encoding="utf-8").read()
                    if mt.count(entry["replace"]) == 1 and mt.count(entry["find"]) == 0:
                        break
                    subprocess.run([sys.executable, "scripts/sync_ios_foundation_package.py"],
                                   cwd=wt_path, capture_output=True, timeout=300, check=True)
                else:
                    raise AssertionError("the mutation never reached the mirrored package: " + mir)
            # 3. run the witnesses against the mutant
            try:
                be, run, failed, blob = _run_harness(entry, wt_path)
            except subprocess.TimeoutExpired:
                tally["TIMEOUT"] += 1
                rows.append(_row(entry, head, "semantic", anchor_count, None,
                                [entry["witness"]], None, "TIMEOUT",
                                "the harness did not settle inside the bound", None))
                print("  TIMEOUT  %s" % entry["id"])
                continue
            outcome, note = _classify(entry, be, run, failed, baseline_ok)
            tally[outcome] += 1
            entry["ended_utc"] = _now_utc()
            log_path = None
            if emit_dir:
                log_path = os.path.join(emit_dir, "logs", entry["id"] + ".semantic.log")
                os.makedirs(os.path.dirname(log_path), exist_ok=True)
                open(log_path, "w", encoding="utf-8").write(
                    "== baseline ==\n" + blob0[-4000:] + "\n== mutant ==\n" + blob[-12000:])
            rows.append(_row(entry, head, "semantic", anchor_count, be, [entry["witness"]],
                            run, outcome, note, log_path))
            print("  %-8s %-34s run=%s failed=%d :: %s"
                  % (outcome, entry["id"], run, len(failed), note[:140]))
        finally:
            _worktree_remove(wt_path)
    print("  per outcome: " + ", ".join("%s=%d" % (k, tally[k]) for k in
          ("KILLED", "SKIPPED", "INVALID", "TIMEOUT", "ESCAPED")))
    if emit_dir:
        os.makedirs(emit_dir, exist_ok=True)
        open(os.path.join(emit_dir, "manifest.json"), "w", encoding="utf-8").write(
            json.dumps(rows, indent=1) + "\n")
    bad = [r["id"] for r in rows if r["outcome"] != "KILLED"]
    if bad and not report_only:
        print("::error::semantic controls not killed: " + ", ".join(bad), file=sys.stderr)
        return 1
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true", help="do not fail on findings")
    ap.add_argument("--semantic", action="store_true", help="run the semantic lineage")
    ap.add_argument("--all", action="store_true", help="run both lineages")
    ap.add_argument("--emit-dir", default=None, help="write logs/ (and the semantic manifest) here")
    ap.add_argument("--baseline", default=None, help="pin the audited head sha for the run")
    ap.add_argument("--work-parent", default=os.path.join(
        os.path.expanduser("~"), ".cache", "godstone-mutation-worktrees"),
        help="parent directory for the disposable worktrees")
    a = ap.parse_args(argv)
    rc = 0
    if a.all or not a.semantic:
        rc |= run_structural(a.report, a.emit_dir, a.baseline or "live-tree")
    if a.semantic or a.all:
        os.makedirs(a.work_parent, exist_ok=True)
        rc |= run_semantic(a.report, a.emit_dir, a.baseline, a.work_parent)
    print("NO AGGREGATE: the two lineages are never summed; no run of this "
          "script may be quoted as a single killed percentage.")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
