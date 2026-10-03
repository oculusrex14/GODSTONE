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
    python3 ci/mutations.py --semantic --group board1 --baseline SHA --emit-dir DIR
                                            # THE BOARD 1 CAMPAIGN: run every required
                                            # rod in a disposable worktree at SHA and
                                            # write `manifest.json` + `logs/` (the phase
                                            # blobs) under DIR. The rows' paths are
                                            # RELATIVE TO DIR, so the downloaded artifact
                                            # is re-readable under any root.
    python3 ci/mutations.py --semantic --id T72-RC13   # only this rod (repeatable)
    python3 ci/mutations.py --all           # both, reported separately
    python3 ci/mutations.py --report        # do not fail on findings
    python3 ci/mutations.py --selftest-manifest --manifest-dir DIR
                                            # prove a campaign RAN: validate the envelope
                                            # at DIR (no stale default; also reads
                                            # $GODSTONE_BOARD1_CAMPAIGN_DIR). Refuseth a
                                            # stale manifest, a missing / DUPLICATE /
                                            # RENAMED rod, an absent restoration, a phase
                                            # log whose bytes moved, a path that escapes
                                            # DIR, or a tested tree that is not the bound
                                            # head's. Only `KILLED` is a catch.
    python3 ci/mutations.py --baseline SHA  # pin the audited head for a run

No aggregate is ever printed as a single killed percentage. The two lineages
are never summed. Every result row carries the section 21 schema fields
verbatim: id, baseline_sha, mutant_patch_sha, category, anchor_count,
build_exit, target_tests, tests_run, outcome, failed_assertion, log_sha.

A rod may also carry `type_enforced` -- BUT ONLY WHEN THE MUTANT BREAKS A
PRODUCTION, UNFORGEABLE CAPABILITY BOUNDARY (e.g. dropping a required
`PrivateRuntimePermit` parameter so a bad consumer surface cannot compile).
The compiler refusing the mutant is then the kill, recorded with
`kill_channel: "compiler"` against a `KILLED` row. **A test-source typo or a
compile regression in a TEST file is `BUILD_INVALID`, NEVER a semantic kill**
and never carrieth `type_enforced`. A rod also names its `platform` for the
witness: `python`, `swift`, `jvm`, `ios-ui`, `selftest` (a committed in-repo
selftest whose exit code is the witness), or `shell` (an INVOKED guard fixture,
never a source grep). A `swift` rod may also name `swift_target` (e.g.
`GodstoneCoreTests`): the harness then builds ONLY that target and runs its own
`xcrun xctest` bundle, so a sibling target's in-flight compile error in another
test file cannot report a phantom red against this rod.

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
import tempfile
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


# --------------------------------------------------------------------------
# PORTABLE CAMPAIGN PATHS -- RELATIVE TO THE CAMPAIGN ROOT, AND REFUSING TO
# ESCAPE IT.
#
# *** THE DEFECT THIS CLOSES, AND WHY IT MATTERS OFF-MACHINE. *** *A phase log's
# absolute path is portable only on the machine that wrote it: the hosted runner
# emits its campaign under `$RUNNER_TEMP/board1-campaign`, an auditor who
# downloads the artifact unzips it UNDER ANOTHER ROOT, and a row that carried
# `/Users/...` or `/private/var/...` could not be re-read from the downloaded
# evidence at all.* **SO EVERY PATH A ROW CARRIETH IS RELATIVE TO THE CAMPAIGN
# ROOT, and a reader resolves it against whichever root the artifact landed in.**
#
# *AND A RELATIVE PATH IS ALSO AN ATTACK SURFACE: `../../../etc/passwd` would make
# a manifest describable as naming evidence outside its own tree. So the resolver
# REFUSETH any path that escapes the root -- empty, absolute, or carrying a `..`
# component -- and says WHY, rather than silently joining it.*
# --------------------------------------------------------------------------

def _relative_to_campaign(path, campaign_root):
    """`path` as a POSIX path relative to `campaign_root`; refuses an escape.

    Returneth `None` for an absent path. Raiseth `ValueError` when the path is
    not inside the root (an absolute path under another root, a path whose
    resolution escapes it, or a non-relative result containing `..`).
    """
    if not path:
        return None
    root = os.path.abspath(str(campaign_root))
    target = os.path.abspath(str(path))
    if target != root and not target.startswith(root + os.sep):
        raise ValueError(f"path {path!r} is OUTSIDE the campaign root {root!r}")
    rel = os.path.relpath(target, root)
    if rel == os.pardir or rel.startswith(os.pardir + os.sep):
        raise ValueError(f"path {path!r} escapes the campaign root {root!r} via '..'")
    return rel.replace(os.sep, "/")


def _resolve_campaign_path(relative, campaign_root):
    """Resolve a RELATIVE campaign path against `campaign_root`, REFUSING ESCAPES.

    A reader calleth this with the row's recorded relative path and the root it
    downloaded the campaign into. An absolute path, an empty path, or any path
    whose `..` components would leave the root is refused BY NAME -- *so a
    manifest cannot be written that points at bytes outside its own evidence
    tree, and a tampered relative path is a named refusal rather than a read.*
    """
    if not relative:
        raise ValueError("an empty campaign path cannot be resolved")
    if os.path.isabs(relative):
        raise ValueError(f"campaign path {relative!r} is ABSOLUTE -- paths are relative to the campaign root")
    root = os.path.abspath(str(campaign_root))
    joined = os.path.normpath(os.path.join(root, relative))
    if joined != root and not joined.startswith(root + os.sep):
        raise ValueError(f"campaign path {relative!r} escapes the campaign root {root!r}")
    return joined


def _tested_tree_sha():
    """The canonical tree sha of the audited head: WHICH BLOB SET THIS RAN AGAINST.

    *`baseline_sha` is the COMMIT a campaign bound; `tested_tree_sha` is the TREE
    its bytes resolved to. The two are the exact candidate identity a reader
    needs, and a tree alone (or a commit alone) can be re-pointed or re-tagged --
    so both travel in the envelope and both can be re-derived read-only
    (`git rev-parse <sha>^{tree}`) without trusting the manifest's own field.*
    """
    for rev in ("HEAD^{tree}",):
        proc = subprocess.run(["git", "rev-parse", rev], cwd=ROOT,
                              capture_output=True, text=True)
        if proc.returncode == 0 and proc.stdout.strip():
            return proc.stdout.strip()
    return None


def _row(entry, baseline_sha, category, anchor_count, build_exit, target_tests,
         tests_run, outcome, failed_assertion, log_path, restored_green=None,
         campaign_root=None, kill_channel=None, structural=False):
    # *** A GUARD-ONLY ROD IS STRUCTURAL: ITS CATEGORY IS OVERRIDDEN SO THE TWO
    # POPULATIONS CANNOT BE SUMMED. ***
    if structural:
        category = "structural"
    # *** THE ROW'S PATHS ARE RELATIVE TO THE CAMPAIGN ROOT, SO A DOWNLOADED
    # ARTIFACT IS RE-READABLE UNDER ANY ROOT. *** *When the caller names a
    # campaign root the stored path is portable; an escape is refused here too,
    # so a manifest cannot be written that points outside its own evidence tree.*
    stored_log = log_path
    if log_path and campaign_root:
        stored_log = _relative_to_campaign(log_path, campaign_root)
    row = {"id": entry["id"], "baseline_sha": baseline_sha,
           "mutant_patch_sha": entry["patch_sha"], "category": category,
           "anchor_count": anchor_count, "build_exit": build_exit,
           "target_tests": list(target_tests), "tests_run": tests_run,
           "outcome": outcome, "failed_assertion": failed_assertion,
           "log_sha": _sha_file(log_path), "log_path": stored_log,
           "started_utc": entry.get("started_utc"), "ended_utc": entry.get("ended_utc")}
    if kill_channel is not None:
        row["kill_channel"] = kill_channel
    if restored_green is not None:
        # *** A KILL CARRIETH ITS RESTORATION, WITH A DIGEST PER PHASE LOG. ***
        # *Three full blobs (baseline, mutant, restored) are registered beside
        # the row, so a reader can re-derive the verdict from the artifacts
        # rather than from the verdict line -- and a row whose restored log is
        # absent cannot pass for a kill.*
        row["restored_green"] = restored_green
        if log_path:
            stem = log_path[:-len(".mutant.log")] if log_path.endswith(".mutant.log") \
                else log_path
            phases = {}
            for ph in ("baseline", "mutant", "restored"):
                full = stem + "." + ph + ".log"
                stored = _relative_to_campaign(full, campaign_root) if campaign_root else full
                phases[ph] = {"path": stored, "sha256": _sha_file(full)}
            row["phase_logs"] = phases
    return row


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
     # *** RE-ANCHORED 2026-09-19: THE OLD ANCHOR WAS THE TEST-ONLY OVERLOAD. *** *The rod used to mutate
     # `internal fun beginInitiator(peerId: ...)`, which liveth in the documented HOST-COURT vocabulary
     # ("PRODUCTION SPEAKETH THE KEYED SURFACE ABOVE ONLY"). G3 was a bare-verb regex, so deleting the
     # PRODUCTION overload left it silent -- MEASURED: the production voice vanished and the check reported
     # NOTHING. The rod was therefore ESCAPING (recorded as a "known ceiling" it never was) while testing a
     # surface production cannot even reach. It now removeth the PRODUCTION keyed voice, which G3 asserteth.*
     "    fun beginInitiator(admission: RelationKey, remoteHint: ByteArray): ByteArray? =",
     "    // fun beginInitiator(admission) REMOVED by M3\n"
     "    private fun _unused_beginInitiator(admission: RelationKey, remoteHint: ByteArray): ByteArray? =",
     "G3",
     "the production keyed handshake voice is gone; nothing can establish a session", False),

    ("M7-ios-handshake-removed",
     "ios/Godstone/Sources/GodstoneMesh/SessionManager.swift",
     # The shared contract, asserted on BOTH platforms. The iOS SessionManager carrieth the same two voices,
     # so the Android anchor alone would leave the iOS production door unguarded.
     "    public func beginInitiator(_ admission: RelationAdmission, remoteHint: Data) -> Data? {",
     "    // public func beginInitiator(_ admission) REMOVED by M7\n"
     "    private func _unusedBeginInitiator(_ admission: RelationAdmission, remoteHint: Data) -> Data? {",
     "G3",
     "the iOS production keyed handshake voice is gone", False),

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
# *** THE BOARD 1 REQUIRED-ID SET, WHICH `--group board1` SELECTETH. ***
#
# *`--id` SELECTS BY EXACT FULL ID, and that is right for a single rod but wrong for a campaign: naming 40 rods on a
# command line inviteth a typo that silently narroweth the population, and a narrowed population that still PASSES is
# the exact false-green this ledger's honesty rules exist to refuse.*
#
# **SO THE GROUP IS A NAMED SET IN THE SOURCE, AND `run_semantic` REFUSETH ANY ID IN IT THAT IS NOT IN `SEMANTIC`
# -- a group entry naming a rod the ledger has never carried is a hole in the campaign, and a hole that reads as a
# pass is worse than a missing rod.** *The set is deliberately the ids the Board 1 plan's steps 3-10 name, each a
# semantic control over real production behaviour with its own named witness and its opposite healthy control.*
BOARD1_REQUIRED_IDS: tuple[str, ...] = (
    # --- STEP 3: the three construction counters and the permit refusal (Android, zero private opens) ---
    "T72-RC13-android-private-construction-uncounted",
    "T72-RC14-android-permit-door-staleness-disabled",
    # --- STEP 4: the runtime-owner witnesses (pump, dispatcher admission, origin, invalidator, idle) ---
    "T72-RC15-android-ack-pump-not-handed-to-the-node",
    "T72-RC16-android-ack-dispatcher-admits-elsewhere",
    # --- STEP 5: the real transport -- default shipping gate, ingress, OS egress, LinkReady publication ---
    "T72-RC18-ios-transport-ingest-unwired",
    "T72-RC19-ios-egress-is-a-silent-noop",
    "T72-RC20-ios-ingress-empty-sender-restored",
    # --- STEP 6: hint/static/old-epoch refusal and the wipe ladder ---
    "T72-RC21-ios-resolver-stopeth-resolving-altogether",
    "T72-RC22-ios-link-readiness-falls-back-to-any-handle",
    "T72-RC23-ios-responder-dispatcher-ignores-the-destination-central",
    "T72-RC24-ios-confirmation-cas-ignores-the-displayed-generation",
    "T72-RC25-ios-confirmation-cas-ignores-the-key-digest",
    "T72-RC28-ios-os-egress-suppressed-while-advertising-success",
    "T72-RC29-android-message-store-construction-uncounted",
    "T72-RC30-android-peer-store-construction-uncounted",
    "T72-RC26-ios-confirmation-trusts-its-intent-not-the-readback",
    "T72-RC27-ios-lab-composes-the-author-over-memory-not-the-estate",
    "T55-RC4-a-failed-wipe-is-not-resumable",
    "T56-RC7-a-failed-wipe-is-not-resumable",
    # --- STEP 7: the real-owner resource releases, dedup and parser gates ---
    "T72-RC1-the-shutdown-releaseth-no-lease",
    "T72-RC3-the-inbox-dedup-is-asleep",
    "T72-RC11-ios-the-shutdown-releaseth-nothing",
    "T72-RC10-android-the-inbox-dedup-is-asleep",
    # *** `gs-stress-001.production-owner-mutation`: THE RODS THAT STRIKE A REAL RELEASE OWNER RATHER THAN A TEST
    # ACCESSOR. *** *The clause asketh for "at least one mutation in a REAL production resource guard/owner (leaked
    # session slot, unreleased writer reservation, uncancelled observer/timer, unretired ACK work) that the stress
    # court detects" -- and the rod the obligation used to cite mutated `slotCountForTest()`, which maketh the
    # MEASUREMENT lie without leaking anything. Each of these three striketh the owner's own release verb and is
    # witnessed by the step-7 arm in `GsStress001RealRuntimeDriverTests` that driveth that verb and readeth that
    # owner's own census.*
    "T72-RC31-ios-retirement-leaveth-the-session-slot-standing",
    "T72-RC32-ios-stop-leaveth-every-timer-lease-standing",
    "T72-RC33-ios-shutdown-leaveth-the-reservations-standing",
    # --- STEP 8: the rendered Trust/Approval journey -- stale candidate, confirmation CAS, revoke ---
    "T55-RC1-approve-the-current-rotation-not-the-displayed-one",
    "T56-RC1-verified-shown-before-the-durable-cas",
    "T56-RC5-the-displayed-candidate-is-not-what-travels",
    "T56-RC9-a-mismatching-confirmation-promoteth",
    "T56-RC12-revocation-leaveth-the-sessions-standing",
    "T57-RC5-the-compose-bound-is-characters-not-bytes",
    "T57-RC6-truncation-splitteth-a-character",
    "T57-RC11-a-duplicate-tap-sendeth-twice",
    "T57-RC12-the-relaunch-inventeth-an-armed-control",
    "T58-RC7-the-compose-bound-is-characters",
    "T58-RC8-a-bare-confirm-placeth-a-call",
    "T58-RC10-a-duplicate-arrival-becometh-two-rows",
    # --- STEP 9: the live accessibility semantics (targets, labels, traversal, clipping) ---
    "T60-RC1-a-label-less-essential-control-is-accepted",
    "T60-RC2-a-clipped-status-is-accepted-at-large-text",
    "T60-RC4-a-undersized-target-is-accepted",
    "T60-RC5-a-gapped-reading-order-is-accepted",
    "T60-RC11-ios-a-clipped-status-is-accepted",
    "T60-RC12-ios-the-touch-target-minimum-vanish",
    # --- STEP 10: SQLCipher's engine claim and the handle/provider lifetime ---
    "T72-RC17-ios-engine-claims-pinned-without-binding",
    # --- the shipping gate stays closed ---
    "T54-RC1-lab-isolation-gate-sleepeth-on-a-mesh-edge",
    "T54-RC2-lab-isolation-gate-sleepeth-on-a-readiness-override",
    "T54-RC3-lab-may-masquerade-as-the-shipping-identity",
    "T59-RC9-the-light-profile-claimeth-the-radio",
    "RS-CAP-01-forged-marker-laundered-an-internal-red",
    "RS-CAP-02-external-block-allowed-while-internal-red",
    "RS-REG-01-corrupt-register-classified-as-missing-input",
    "RS-NATIVE-01-native-stack-conflated-with-model-weights",
    "RS-NATIVE-02-absent-llama-source-tolerated",
    "RS-TRUST-01-replaced-image-digest-trusted-from-sidecar",
    "IOS-R10-second-store",
    "IOS-R10-no-dispatch",
    "IOS-R15-unrefreshed-snapshot",
    "IOS-R15-impossible-no-call",
    "NCR-01-swift-the-store-drops-the-owners-use-lock",
    "NCR-02-swift-the-owner-close-frees-without-draining",
    "NCR-03-swift-the-admission-always-admits",
    "NCR-04-swift-the-intent-read-folds-every-fault-into-absence",
    "NCR-05-swift-the-migration-stamp-runs-outside-the-edge-transaction",
    "NCR-06-swift-the-sweep-begin-fault-is-not-refused",
    "NCR-07-swift-the-sweep-publishes-without-an-acknowledged-commit",
    "NCR-08-swift-the-factory-admits-a-replayed-scope",
    "NCR-09-swift-the-engine-reports-a-generic-io-for-a-wrong-key",
    "NCR-10-swift-the-partial-open-handle-leaks",
    "NCR-11-swift-the-peer-transaction-reacquires-the-store-lock",
    "NCR-13-swift-the-corrupt-intent-row-is-absence-again",
    "ARCHIVE-PROV-001",
    "ARCHIVE-PROV-002",
    "ARCHIVE-PROV-003",
    "ARCHIVE-PROV-004",
    "ARCHIVE-PROV-005",
    "ARCHIVE-PROV-006",
    "ARCHIVE-PROV-007",
    "MUT-IOS-R1-PERMIT-NOT-CONSUMED",
    "MUT-IOS-R1-PERMIT-GENERATION-IGNORED",
    "MUT-IOS-R1-NORMAL-HELPER-BYPASS",
    "MUT-IOS-R2-GATE-CACHED-SNAPSHOT",
    "MUT-IOS-R2-ARTIFACT-ORACLE-CACHED",
    "MUT-IOS-R3-APPEND-IGNORES-COMMIT",
    "MUT-IOS-R3-COORDINATOR-IGNORES-ACK",
    "MUT-IOS-R4-WRONG-DEK-TAG",
    "MUT-IOS-R4-ERASE-UNVERIFIED",
    "MUT-IOS-R5-FRESH-DEAD-TRANSPORT",
    "MUT-IOS-R5-UNARMED-COLD",
    "MUT-IOS-R7-INVENTORY-IGNORED",
    "MUT-IOS-R8-PUBLISH-NOT-IDEMPOTENT",
    "MUT-IOS-R8-PUBLICATION-UNBOUND",
    "MUT-IOS-R11-WITNESS-DISCONNECTED",
    "ANDE-A9-01-CHECKPOINT-VERDICT-DISCARDED",
    "ANDE-A9-02-PERSISTED-RUNG-VERDICT-DISCARDED",
    "ANDE-A2-03-ABA-EPOCH-DROPPED-FROM-REVISION",
    "ANDE-A2-04-REVISION-FROM-COORDINATOR-SNAPSHOT",
    "ANDE-A2-05-PERMIT-NOT-REVALIDATED-AT-CONSUMPTION",
    "ANDE-A2-06-ADAPTER-LEGAL-NEXT-CHECK-DROPPED",
    "ANDE-A3-07-PUBLIC-PERMIT-FROM-A-BARE-DECISION",
    "ANDE-A13-08-PUBLIC-RAW-IDENTITY-FACTORY",
    "ANDE-A8-09-REENTRANCY-GUARD-DROPPED",
    "ANDE-A7-10-OPERATOR-RESOLUTION-SKIPS-THE-DURABLE-REQUEST",
    "IOS-TRANSPORT-001-nil-services-coerced-to-discovery-success",
    "LANE-ROD-6-android-runner-aborts-before-digests",
    "SH-R01-python-the-timer-release-defect-is-a-no-op",
    "SH-R02-python-shutdown-stops-releasing-the-timer-owner",
    "SH-R03-python-shutdown-stops-releasing-the-session-owner",
    "SH-R04-python-the-fault-liveness-clause-is-asleep",
    "SH-R05-python-the-category-is-carried-as-the-production-runtime",
    "SH-R06-python-the-unmeasured-invariant-set-is-silently-empty",
    "SH-R07-python-the-unmeasured-owner-kinds-are-unnamed",
    "SH-R08-jvm-the-not-measured-sentinel-collapses-into-zero",
    "SH-R09-jvm-the-unmeasured-invariants-set-is-never-filled",
    "SH-R10-jvm-the-category-is-carried-as-the-production-runtime",
    "SH-R11-jvm-the-missing-observer-unmeasured-branch-is-removed",
    "SH-R12-swift-shutdown-stops-releasing-the-timer-owner",
    "SH-R13-swift-the-unmeasured-set-omits-the-reservation-owner",
    "SH-R14-swift-the-protocol-default-answereth-a-constant-zero",

    # --- THE TERMINAL BOARD 1 ROUND: the guards landed after rc14 -- the recovery
    #     topology's post-landing arms (AndroidRecoveryUi), the true pre-private
    #     recovery rods (IosRecoveryUi), the lane control's own guards (LaneControls),
    #     the supply-chain surfaces (ReleaseSupply) and the gate-manifest/freeze
    #     contract (VerifyFreeze). ---
    "T72-RC35-android-identity-publication-sentinel-restored",
    "T72-RC36-android-admission-gate-raw-enum-restored",
    "T72-RC37-android-startup-decision-ignores-readability",
    "T72-RC38-android-lab-wipe-local-state-register",
    "T72-RC39-android-wipe-resume-offered-unconditionally",
    "T72-RC40-android-lab-wipe-progress-not-read-from-record",
    "T72-RC41-android-composition-issuer-mints-from-a-constant-decision",
    "T72-RC42-android-completed-wipe-collapsed-into-first-launch",
    "IOS-RECOVERY-001",
    "IOS-RECOVERY-002",
    "IOS-RECOVERY-003",
    "IOS-RECOVERY-004",
    "IOS-RECOVERY-005",
    "IOS-RECOVERY-006",
    "IOS-RECOVERY-007",
    "IOS-RECOVERY-008",
    "IOS-RECOVERY-009",
    "IOS-RETRY-001",
    "IOS-RETRY-002",
    "IOS-WIPE-UX-001",
    "IOS-WIPE-UX-002",
    "IOS-SOS-RETRY-001",
    "LANE-ROD-1-skip-refusal-disabled",
    "LANE-ROD-2-foundation-arm-omission-unguarded",
    "LANE-ROD-3-foundation-duplicate-arm-unrefused",
    "LANE-ROD-4-simulator-duplicate-narrowed-to-required",
    "LANE-ROD-5-known-red-allowance-repopulated",
    "RS-IOS-01-debug-symbols-asleep",
    "RS-IOS-02-undefined-mesh-import-asleep",
    "RS-IOS-03-excluded-resource-pattern-asleep",
    "RS-PROOF-01-fabricated-internal-verdict-tolerated",
    "RS-PROOF-02-record-self-digest-asleep",
    "RS-PROOF-03-misclassified-external-tolerated",
    "RS-PROOF-04-borrowed-sha-tolerated",
    "RS-DL-01-wrong-download-digest-asleep",
    "RS-DL-02-cached-tool-tree-digest-asleep",
    "RS-SBOM-01-face-coverage-asleep",
    "RS-SBOM-02-lock-version-drift-tolerated",
    "T86-B1M1-manifest-may-omit-a-required-gate",
    "T86-B1M2-nonzero-gate-reads-as-pass",
    "T86-B1M3-campaign-tested-inputs-may-move",
    "T86-B1M4-escaped-rod-counts-as-killed",
    "T86-B1M5-tampered-gate-log-is-believed",
    "T86-B1M6-a-narrowed-campaign-population-passes",
    "T86-B1M7-absent-lane-artifact-is-ignored",
    "T86-B1M8-stale-lane-digest-is-believed",
    "T86-B1M9-mid-run-lane-drift-is-ignored",
    "T86-B1M10-candidate-tree-need-not-be-stated",
    "T86-B1M11-dirty-freeze-tree-is-accepted",
    "T86-B1M12-lightweight-candidate-tag-is-accepted",
    "T86-B1M13-closure-counts-may-disagree",
    "T86-B1M14-builder-emits-a-partial-manifest",
    "T86-B1M15-relative-attest-path-crasheth",
    "T86-B1M16-bound-manifest-is-not-re-derived",
    "T86-B1M17-foreign-candidate-manifest-is-bound",
)


# --------------------------------------------------------------------------
# *** THE BOARD 1 SECURITY-CRITICAL SURFACE GROUP, WHICH `--group board1-trust-surface`
# SELECTETH. ***
#
# *The audit names four surfaces whose whole purpose is to be the LAST line of defence:
# the TRUST-HANDSHAKE controls (H01-H30 -- the typed inspection, the trust gate, the
# seal/open boundary), the PEER-IDENTITY store (the guarded CAS SQL, the trust-level
# encoding, fail-closed migrations), the BOUND RECIPIENT key resolver (read-only,
# verified-only, fail-closed) and the STORE-SCHEMA/quota controls (the fail-closed schema
# and the atomic authenticated ACK -- the "quota" the store enforces through its capacity
# and retire laws). Each rod below MUTATES the production control so that the REAL values
# that reach the validation -- a revoked key, an aliased payload, a caller's frame -- are
# the ones that change, and its witness is the guard's own refusal, EXECUTED against the
# mutant rather than grepped for.*
#
# **EVERY ROD NAMES THE EXACT REFUSAL THE GUARD MUST PRINT (`refusal_line`), AND IT MUST
# NAME A DIFFERENT ONE FROM EVERY SIBLING: an escape in one control may not be laundered
# by a co-reddening refusal in another, so the kills are ATTRIBUTABLE by construction.**
TRUST_SURFACE_REQUIRED_IDS: tuple[str, ...] = (
    # --- trust-handshake controls (ci/check_trusted_handshake_controls.py; H01-H30) ---
    "TH-01-ios-trusted-controller-restores-the-collapsed-hs2-hs3",
    "TH-02-android-noise-drops-the-typed-read-result",
    "TH-03-android-read-result-aliases-its-payload",
    "TH-04-ios-noise-restores-the-collapsed-hs2-hs3",
    # --- peer-identity store (ci/check_peer_identity_store_controls.py; S01-S83) ---
    "PI-01-first-seen-becometh-insert-or-ignore",
    "PI-02-ddl-admits-an-unrecognised-trust-level",
    "PI-03-rotation-approval-admits-a-revoked-peer",
    # --- bound recipient key resolver (ci/check_bound_recipient_key_resolver_controls.py; B01-B16) ---
    "BR-01-android-revoked-identity-resolveth-its-key",
    "BR-02-android-node-id-boundary-guard-removed",
    "BR-03-ios-node-id-boundary-guard-removed",
    "BR-04-resolver-returns-the-static-dh-key",
    "BR-05-quarantined-lookup-resolveth-a-key",
    # --- store-schema / quota (ci/check_store_schema_controls.py; C6.4.1/C6.6/C7.4) ---
    "SS-01-android-dispatch-transporteth-the-uncommitted-frame",
    "SS-02-ios-dispatch-transporteth-the-uncommitted-frame",
    "SS-03-ios-store-applyeth-a-literal-protection-class",
)


def _group_ids(name: str) -> list[str]:
    """The rod ids a named group selecteth, AND A HARD REFUSAL IF ANY IS NOT IN `SEMANTIC`.

    *A group entry with no matching rod is a hole in the campaign -- the campaign would report KILLED for every rod it
    ran while never running that one, which is the "a control that has never been observed failing is not a control"
    defect wearing a group's name.*
    """
    # *** TWO NAMED GROUPS, AND BOTH ARE REFUSED BY NAME RATHER THAN SKIPPED. *** *The
    # `board1` group is the plan's required population; `board1-trust-surface` is the
    # security-critical subset above, selectable WITHOUT the whole ledger. An id either
    # group names that the ledger does not carry is a hole, and a hole that reads as a
    # pass is worse than a missing rod.*
    groups: dict[str, tuple[str, ...]] = {
        "board1": BOARD1_REQUIRED_IDS,
        "board1-trust-surface": TRUST_SURFACE_REQUIRED_IDS,
    }
    if name not in groups:
        raise SystemExit(f"::error::unknown group {name!r}; the known groups are `board1` and "
                         f"`board1-trust-surface`")
    ids = groups[name]
    # *** AN ALIAS IS A KNOWN ID: its control is carried by its target rod. ***
    known = {s["id"] for s in SEMANTIC}
    missing = [i for i in ids if i not in known]
    if missing:
        raise SystemExit(f"::error::the `{name}` group names {len(missing)} id(s) that are NOT in the ledger: "
                         f"{missing} -- a group entry with no rod is a hole in the campaign, never a pass")
    return list(ids)


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
    {'id': 'T28-SM2-android-power-loss-not-uniform', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/identity/RuntimeLifecycle.kt', 'find': "            drainLocked()\n            capability = CapabilityStatus.TERMINAL_UNAVAILABLE", 'replace': "            drainLocked()   // (mutant) power-off merely drains, leaving the scanner and session live and non-terminal\n            seam.stopAdvertising()", 'why': 'power-off merely toggles advertising instead of uniformly invalidating: the scanner and session are left live and the capability never reaches the terminal state, so isReady stays true; the power-loss uniform-invalidation and terminal witness falleth', 'witness': 'testPowerLossUniformlyInvalidatesAndIsTerminalNeverReady', 'gradle_filter': '*ReadinessT28Test*'},
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
    {'id': 'T30-SM2-ios-swallow-protection-failure-reopen', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/EncryptedStoreFactory.swift', 'find': "        guard protection.isSuccess else { return .unavailable }\n        return finalize { try self.engine.reopenRequiringDEK(path: path, dek: dek) }", 'replace': "        if protection.isSuccess { _ = 0 }   // (mutant) the protection failure is swallowed\n        return finalize { try self.engine.reopenRequiringDEK(path: path, dek: dek) }", 'why': 'a failed file-protection apply on the REOPEN path is swallowed instead of failing closed, so a store that lost its at-rest protection is reopened as usable; the reopen-path never-swallow witness falleth', 'witness': 'testReopenProtectionFailureIsNeverSwallowed', 'swift_filter': 'ReadinessT30Tests'},
    {'id': 'T30-SM3-ios-reopen-without-dek-accepted', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/EncryptedStoreFactory.swift', 'find': '            case .dekNotFound, .keychainUnavailable, .deviceLocked, .dekWrongLength, .protectionFailure: return .unavailable', 'replace': '            case .dekNotFound: return .available(EncryptedStoreHandle(path: "x", kind: .pinnedSQLCipher, encryptedAtRest: true, cipherVersion: 4))\n            case .keychainUnavailable, .deviceLocked, .dekWrongLength, .protectionFailure: return .unavailable', 'why': 'a missing DEK on reopen is accepted as an encrypted Available store instead of refused, so the erasability guarantee collapses and a store reopens without its key; the reopen-without-DEK witness falleth (the cards named falsification)', 'witness': 'testReopenWithoutDEKIsRejectedNeverEmptyHealthy', 'swift_filter': 'ReadinessT30Tests'},
    {'id': 'T30-SM4-ios-select-before-verify', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/PlaintextToEncryptedMigration.swift', 'find': "        guard verification.isGood else { return failurePreservingSource(plaintextPath: plaintextPath, reason: .verificationMismatch) }  // never select an unverified copy", 'replace': "        if verification.isGood { _ = 0 }   // (mutant) select the encrypted copy even when verification says it is not good", 'why': 'the encrypted copy is selected even when the verify-before-select check reports a mismatch, so an unverified or corrupt copy could be promoted and the plaintext source retired; the failed-migration-preserves-recoverable-source witness falleth', 'witness': 'testFailedMigrationPreservesRecoverableSource', 'swift_filter': 'ReadinessT30Tests'},
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
        # *** ANCHOR REPOINTED (round 733): the receiver was RENAMED `client` -> `activeClient`, and the rod was left
        # behind -- `file.count(find)` was ZERO, so it could mutate NOTHING. *The semantics it guards are unchanged; only
        # the name moved.* *** A STALE ROD IS A CONTROL THAT COVERETH NOTHING WHILE OCCUPYING THE PLACE WHERE A LIVE ONE
        # WOULD STAND. ***
        "find": "        if (activeClient.clientToken != clientToken || activeClient.gattGeneration != gattGen) {",
        "replace": "        if (false && (activeClient.clientToken != clientToken || activeClient.gattGeneration != gattGen)) {",
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
        "find": "            // trust rejected: HS3 is withheld and the exact relation closes\n            recordRejection(conn.peerId, \"hs.read.initiator\", \"hs2 rejected\")\n            closeInitiatorRelation(peerAddress)\n            return",
        "replace": "            // (mutant) trust rejected is NOT recorded and the relation doeth NOT close\n            if (false) recordRejection(conn.peerId, \"hs.read.initiator\", \"hs2 rejected\")\n            if (false) closeInitiatorRelation(peerAddress)\n            return",
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
        "file": "ios/Godstone/Sources/GodstoneMesh/BleHandshakeAuthority.swift",
        "find": "        return sessions.responderProcessHs3(relation, hs3: hs3,\n                                            advertisedRemoteHint: advertisedRemoteHint)",
        "replace": "        return true   // (mutant) the responder third arm accepteth the counsel though the controller never sealed it",
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
        "find": "                            } else if (!takeInboundKeyConfirmation(peerId, outcome.plaintext)) {\n                                // T23: a sealed key-confirmation control is hearkened by D2\n                                // and never carrieth to the application; all else moveth on.\n                                trySend(peerId to outcome.plaintext)\n                            }",
        "replace": "                            } else if (takeInboundKeyConfirmation(peerId, outcome.plaintext)) {\n                                trySend(peerId to outcome.plaintext)\n                            }",
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
        "find": "                        if self.takeInboundKeyConfirmation(peerId: peerId, opened: clear) {\n                            return\n                        }",
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
        'replace': '        if (pinned != null && pinned.bindingDigest.contentEquals(digest) && false) {',
        'why': 'the replay branch never answers; the retry of the same intent token falls through to the fresh path and MINTS a new nonce and a NEW logical id -- identical persisted bytes are broken at the source',
        'witness': 'testRetryOfSameIntentTokenLoadsIdenticalPersistedBytes',
        'gradle_filter': '*ReadinessT36Test*',
    },
    {
        'id': 'T36-RC1-ios-retry-recreated-the-logical-identity',
        'platform': 'swift',
        'file': 'ios/Godstone/Sources/GodstoneMesh/SendDirectAuthority.swift',
        'find': "        if let row = loadedRow.entryOrNil, row.bindingDigest == digest {",
        'replace': "        if let row = loadedRow.entryOrNil, false, row.bindingDigest == digest {",
        'why': 'the iOS twin: the pinned row is never recognised, the retry re-creates through the factory -- the replay-loads-identical-bytes law dies on this isle too',
        'witness': 'testRetryOfSameIntentTokenLoadsIdenticalPersistedBytes',
        'swift_filter': 'ReadinessT36Tests',
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
        'find': "        if let row = loadedRow.entryOrNil, row.bindingDigest == digest {",
        'replace': "        if let row = loadedRow.entryOrNil, trustResolver.resolve(recipientTrustRef: command.recipientTrustRef) == ResolvedRecipient.absent || true, row.bindingDigest == digest {",
        'why': 'the iOS twin resolves behind the pinned token on every replay; the resolver counter increments where the sealed law demands silence',
        'witness': 'testKeyRotationRacePinsTheAcceptedGeneration',
        'swift_filter': 'ReadinessT36Tests',
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
        'swift_filter': 'ReadinessT36Tests',
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
        'swift_filter': 'ReadinessT36Tests',
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
        'find': "        if let row = loadedRow.entryOrNil, row.bindingDigest == digest {",
        'replace': "        if let row = loadedRow.entryOrNil {",
        'why': 'the iOS twin ignores the digest: the changed body under the same token replays the old id; the court counts the created sends and finds them short',
        'witness': 'testChangedRecipientOrBodyOrPriorityCreatesNewLogicalSend',
        'swift_filter': 'ReadinessT36Tests',
    },

    # ---------------------------------------------------------------- T83
    # section 14 recipient ACK return path: the two namespaces, the inbox-transaction
    # obligation, the bounded candidate census, the local cache key, the paired
    # retirement. Five named falsifications, two isles.
    {'id': 'T83-RC1-android-ack-rows-stored-in-the-message-namespace', 'platform': 'jvm', 'file': 'android/mesh/src/test/java/io/godstone/mesh/store/JdbcStoreDb.kt', 'find': '            db.insertAckFrameRow(row)\n        }\n        db.deleteObligation(msgId, recipientNodeId)', 'replace': '            db.insert(FrameV2(io.godstone.mesh.wire.v2.TypeV2.ACK, row.msgId, row.signature.copyOfRange(0, 4), 4, 0, 0, row.encodedFrame), row.msgId, 0L)\n        }\n        db.deleteObligation(msgId, recipientNodeId)', 'why': "the paired step files the ACK row into the MESSAGE namespace keyed by the reused msg_id -- the very collision section 14 opens ack_frames to prevent; the ack_frames table stays empty and the local-cache-key reader finds nothing. REDIRECTED after campaign attempt 2 ESCAPED: the row originally mutated the production SQLCipher engine's pair step, which no host witness executes (the SQL-leg witness drives the host Jdbc engine -- the falsifier was placed beyond the oracle's sight); the same falsification now targets the engine the witness actually runs, pre-verified in a scratch worktree to redden exactly the named witness", 'witness': 'testStorageFailureYieldsNeitherAckNorClaimedAcceptance', 'gradle_filter': 'ReadinessT83Test'},
    {'id': 'T83-RC2-android-obligation-omitted-from-the-inbox-transaction', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/store/MessageStore.kt', 'find': '        val obligationNew = when (val r = ackStoreInternal.insertIfAbsent(ob)) {', 'replace': '        val obligationNew = when (val r: ObligationInsertResult = ObligationInsertResult.Duplicate) {', 'why': 'the pending obligation is omitted from the recipient inbox transaction (the card names this falsification): the commit reports a bare Duplicate without ever inserting a row, so a crash before signing strands NOTHING to resume and the returnable ACK is lost', 'witness': 'testCrashAfterInboxCommitBeforeSigningResumesDeterministically', 'gradle_filter': 'ReadinessT83Test'},
    {'id': 'T83-RC3-android-ackkey-ignores-the-signature-candidates-collapse', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/AckObligationStore.kt', 'find': '        md.update(recipientNodeId)\n        md.update(signature)\n        return md.digest()', 'replace': '        md.update(recipientNodeId)\n        return md.digest()', 'why': 'the local cache key is computed WITHOUT the signature bytes, so different signature candidates for one (msg_id, recipient) pair share one key and dedup each other -- the first-stored copy suppresses every later one, the very dedup section 14 forbids', 'witness': 'testForgedCandidateThenValidSignatureAdmitsBothSlotsDistinguishable', 'gradle_filter': 'ReadinessT83Test'},
    {'id': 'T83-RC4-android-pair-quota-removed-fifth-candidate-admitted', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/AckObligationStore.kt', 'find': '        else if (countForPairLocked(record.msgId, record.recipientNodeId) >= ACK_CANDIDATES_PER_PAIR_LIMIT) {\n            AckAdmissionResult.RefusedQuotaPair\n        } else if (frames.size >= ACK_CANDIDATES_TOTAL_LIMIT) {', 'replace': '        else if (countForPairLocked(record.msgId, record.recipientNodeId) >= ACK_CANDIDATES_PER_PAIR_LIMIT && false) {\n            AckAdmissionResult.RefusedQuotaPair\n        } else if (frames.size >= ACK_CANDIDATES_TOTAL_LIMIT) {', 'why': 'the bounded-four-per-pair gate is cut from the admission path (falsity conjoined LAST, the house trailing form): a fifth distinct candidate for one pair is admitted silently instead of being refused explicitly at the bound', 'witness': 'testFourCandidateVariantsBoundedPerPair', 'gradle_filter': 'ReadinessT83Test'},
    {'id': 'T83-RC5-android-retirement-unbound-from-the-frame-insert', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/AckObligationStore.kt', 'find': '                frames[k] = record\n                if (obPresent) obligations.remove(obK)\n                FrameCommitResult.Committed', 'replace': '                frames[k] = record\n                FrameCommitResult.Committed', 'why': 'the retirement is unbound from the frame insert: the pair step files the frame yet leaves the obligation PENDING forever -- the resume scan re-signs and re-files the same reply again and again, the both-or-neither step broken', 'witness': 'testObligationRetiredOnlyWithFrameTransaction', 'gradle_filter': 'ReadinessT83Test'},
    {'id': 'T83-RC1-ios-ack-rows-stored-in-the-message-namespace', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/MessageStore.swift', 'find': '                _ = try insertAckFrameRowNoLock(db, row)\n            }\n            _ = try execGuardedNoLock(db, StoreSchema.retireObligationSql, [msgId, recipientNodeId])\n            return present ? .idempotent : .committed', 'replace': '                _ = try insertRowNoLockStrict(db, FrameV2(type: .ack, msgId: row.msgId, routingTag: Data([0, 0, 0, 0]), ttl: 4, hopCount: 0, flags: 0, payload: row.encodedFrame), receivedFrom: row.msgId, receivedAt: 0)\n            }\n            _ = try execGuardedNoLock(db, StoreSchema.retireObligationSql, [msgId, recipientNodeId])\n            return present ? .idempotent : .committed', 'why': 'the paired step files the ACK row into the MESSAGE namespace keyed by the reused msg_id -- the very collision section 14 opens ack_frames to prevent; the ack_frames table stays empty and the local-cache-key reader finds nothing', 'witness': 'testStorageFailureYieldsNeitherAckNorClaimedAcceptance', 'swift_filter': 'ReadinessT83Tests'},
    {'id': 'T83-RC2-ios-obligation-omitted-from-the-inbox-transaction', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/MessageStore.swift', 'find': '        let insert = ackStoreInternal.insertIfAbsent(ob)', 'replace': '        let insert: ObligationInsertResult = .duplicate', 'why': 'the pending obligation is omitted from the recipient inbox transaction (the card names this falsification): the commit reports a bare Duplicate without ever inserting a row, so a crash before signing strands NOTHING to resume and the returnable ACK is lost', 'witness': 'testCrashAfterInboxCommitBeforeSigningResumesDeterministically', 'swift_filter': 'ReadinessT83Tests'},
    {'id': 'T83-RC3-ios-ackkey-ignores-the-signature-candidates-collapse', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/AckObligationStore.swift', 'find': '        hasher.update(data: recipientNodeId)\n        hasher.update(data: signature)\n        let digest = hasher.finalize()', 'replace': '        hasher.update(data: recipientNodeId)\n        let digest = hasher.finalize()', 'why': 'the local cache key is computed WITHOUT the signature bytes, so different signature candidates for one (msg_id, recipient) pair share one key and dedup each other -- the first-stored copy suppresses every later one, the very dedup section 14 forbids', 'witness': 'testForgedCandidateThenValidSignatureAdmitsBothSlotsDistinguishable', 'swift_filter': 'ReadinessT83Tests'},
    {'id': 'T83-RC4-ios-pair-quota-removed-fifth-candidate-admitted', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/AckObligationStore.swift', 'find': '        if countForPairLocked(record.msgId, record.recipientNodeId) >= ackCandidatesPerPairLimit {\n            return .refusedQuotaPair\n        }\n        if frames.count >= ackCandidatesTotalLimit { return .refusedQuotaGlobal }\n        frames[record.ackKey] = record', 'replace': '        if countForPairLocked(record.msgId, record.recipientNodeId) >= ackCandidatesPerPairLimit && false {\n            return .refusedQuotaPair\n        }\n        if frames.count >= ackCandidatesTotalLimit { return .refusedQuotaGlobal }\n        frames[record.ackKey] = record', 'why': 'the bounded-four-per-pair gate is cut from the admission path (falsity conjoined LAST, the house trailing form): a fifth distinct candidate for one pair is admitted silently instead of being refused explicitly at the bound', 'witness': 'testFourCandidateVariantsBoundedPerPair', 'swift_filter': 'ReadinessT83Tests'},
    {'id': 'T83-RC5-ios-retirement-unbound-from-the-frame-insert', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/AckObligationStore.swift', 'find': '            frames[record.ackKey] = record\n            if obPresent { obligations[obKey(msgId, recipientNodeId)] = nil }\n            return .committed', 'replace': '            frames[record.ackKey] = record\n            return .committed', 'why': 'the retirement is unbound from the frame insert: the pair step files the frame yet leaves the obligation PENDING forever -- the resume scan re-signs and re-files the same reply again and again, the both-or-neither step broken', 'witness': 'testObligationRetiredOnlyWithFrameTransaction', 'swift_filter': 'ReadinessT83Tests'},

    # ---------------------------------------------------------------- T37
    # section 14 recipient inbox before ACK: the order of the pair step, the tag
    # as hint not identity, the stored-row duplicate answer, no ACK on storage
    # failure, the immediate-hop token never a sender identity.
    # Five named falsifications, two isles.
    {'id': 'T37-RC1-android-ack-signed-and-filed-before-the-inbox-commit', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/RecipientInboxRepository.kt', 'find': '        val commitOutcome = commitInbound(\n            frame, receivedFrom, ourNodeId, identityGeneration(),\n            ACK_RETENTION_MS, clockSeconds(), fault,\n        )\n        when (commitOutcome) {\n            is InboundCommitResult.Committed -> {}\n            InboundCommitResult.RejectedCapacity ->\n                return InboxCommitResult.Rejected(RejectionReason.CAPACITY)\n            InboundCommitResult.StorageFailure ->\n                return refuseStorage("inbox commit")\n            InboundCommitResult.InvalidArgument ->\n                return InboxCommitResult.Rejected(RejectionReason.WIDTHS, "commit args")\n        }\n        if (commitOutcome !is InboundCommitResult.Committed) {\n            // unreachable while the taxonomy is closed; defensive, never silent\n            return InboxCommitResult.Rejected(RejectionReason.STORAGE_FAILURE, "commit outcome vanished")\n        }\n\n        // -- step 6: AFTER the commit, the canonical recipient ACK, once ------\n        return issueOrRestoreAck(frame, receivedFrom, commitOutcome, fault)\n    }', 'replace': '        val hoisted = issueOrRestoreAck(frame, receivedFrom,\n            InboundCommitResult.Committed(true, true, false), fault)\n        val commitOutcome = commitInbound(\n            frame, receivedFrom, ourNodeId, identityGeneration(),\n            ACK_RETENTION_MS, clockSeconds(), fault,\n        )\n        when (commitOutcome) {\n            is InboundCommitResult.Committed -> {}\n            InboundCommitResult.RejectedCapacity ->\n                return InboxCommitResult.Rejected(RejectionReason.CAPACITY)\n            InboundCommitResult.StorageFailure ->\n                return refuseStorage("inbox commit")\n            InboundCommitResult.InvalidArgument ->\n                return InboxCommitResult.Rejected(RejectionReason.WIDTHS, "commit args")\n        }\n        if (commitOutcome !is InboundCommitResult.Committed) {\n            // unreachable while the taxonomy is closed; defensive, never silent\n            return InboxCommitResult.Rejected(RejectionReason.STORAGE_FAILURE, "commit outcome vanished")\n        }\n\n        // -- the ACK was signed and filed BEFORE the commit was ever consulted --\n        return hoisted\n    }', 'why': 'the canonical answer is signed and FILED before the inbox commit is ever consulted: the both-or-neither pair step can hand out an ACK for a delivery whose durable commit never ran (the W7/W8 order oracles -- a kill-at-signing run leaves a filed row and a missing held line)', 'witness': 'testProcessKillAfterCommitBeforeAckRegeneratesExactlyOnce', 'gradle_filter': 'ReadinessT37Test'},
    {'id': 'T37-RC2-android-routing-tag-gate-is-identity', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/RecipientInboxRepository.kt', 'find': '        var hintHit = false\n        var day = today - HINT_WINDOW_DAYS\n        while (day <= today + HINT_WINDOW_DAYS) {\n            if (SealedSender.routingTag(ourNodeId, day).contentEquals(frame.routingTag)) {\n                hintHit = true\n            }\n            day += 1L\n        }', 'replace': '        var hintHit = false\n        var admittedByTag = false\n        var day = today - HINT_WINDOW_DAYS\n        while (day <= today + HINT_WINDOW_DAYS) {\n            if (SealedSender.routingTag(ourNodeId, day).contentEquals(frame.routingTag)) {\n                hintHit = true\n                admittedByTag = true\n            }\n            day += 1L\n        }\n        if (!admittedByTag) {\n            return InboxCommitResult.Rejected(RejectionReason.NOT_FOR_US, "tag gate")\n        }', 'why': 'the 4-byte rotating tag is promoted from a charged hint to an admission gate: a clock-skewed node whose tag left the +-window can no longer deliver at all (section 14: "Incorrect clocks must not be mistaken for authentication failure of an identity")', 'witness': 'testStaleTagStillDeliversAndMatchedTagAdmitsNothingAlone', 'gradle_filter': 'ReadinessT37Test'},
    {'id': 'T37-RC3-android-duplicate-forgets-the-filed-row-and-re-signs', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/RecipientInboxRepository.kt', 'find': '                    if (rec.verificationClass != AckVerificationClass.VERIFIED_RECIPIENT) continue', 'replace': '                    if (rec.verificationClass == AckVerificationClass.VERIFIED_RECIPIENT) continue', 'why': 'the stored verified row is skipped on the duplicate read-back, so every re-delivery walks the fresh-signing path: on this isle the bytes repeat by determinism yet the signer census proves the re-signature, and on the randomized iOS isle the handed-out bytes would drift -- the stored row is the truth', 'witness': 'testDuplicateValidDeliveryRegeneratesSameAckWithoutDuplicateInbox', 'gradle_filter': 'ReadinessT37Test'},
    {'id': 'T37-RC4-android-storage-failure-still-hands-out-an-ack', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/RecipientInboxRepository.kt', 'find': '            InboundCommitResult.StorageFailure ->\n                return refuseStorage("inbox commit")', 'replace': '            InboundCommitResult.StorageFailure -> {\n                synchronized(countersLock) { counters.acksIssued += 1 }\n                return admitArm(true, AckFrame.build(\n                    frame.msgId, ByteArray(ACK_KEY_LEN), ourNodeId,\n                    ourNodeId.copyOfRange(0, ACK_HINT_LEN), ACK_INITIAL_TTL,\n                ))\n            }', 'why': 'the storage-failure arm admits a freshly built answer instead of refusing: "storage/verification failure: no ACK and no claimed local acceptance" -- the card\'s named negative, delivered straight from the failing commit', 'witness': 'testDiskFailureYieldsNeitherAckNorClaimedAcceptance', 'gradle_filter': 'ReadinessT37Test'},
    {'id': 'T37-RC5-android-immediate-hop-stands-in-for-the-sender', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/RecipientInboxRepository.kt', 'find': '            return InboxCommitResult.Rejected(RejectionReason.VERIFICATION_FAILED, "recipient binding")\n        }', 'replace': '            return InboxCommitResult.Rejected(RejectionReason.VERIFICATION_FAILED, "recipient-binding")\n        }\n        if (!receivedFrom.contentEquals(vm.senderNodeId)) {\n            synchronized(countersLock) { counters.acksRefusedKey += 1 }\n            return InboxCommitResult.Rejected(RejectionReason.KEY_UNAVAILABLE, "hop is not the sender")\n        }', 'why': 'the immediate-hop transport token is consulted as sender identity: a relayed delivery (hop != sender) is refused outright -- the task objective\'s named crime ("Use authenticated TrustedPeer only as immediate-hop identity"; section 14: "Do not use transport ID ... as either")', 'witness': 'testImmediateHopIsNotTheSenderAndReceiptStands', 'gradle_filter': 'ReadinessT37Test'},
    {'id': 'T37-RC1-ios-ack-signed-and-filed-before-the-inbox-commit', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/RecipientInboxRepository.swift', 'find': '        let outcome = try commitInbound(\n            frame, receivedFrom, ourNodeId, identityGeneration(),\n            ackRetentionMs, clockSeconds(), fault\n        )\n        let heldNew: Bool\n        let obligationStored: Bool\n        switch outcome {\n        case .committed(heldNew: let newHeld, obligationStored: let stored, duplicate: _):\n            heldNew = newHeld\n            obligationStored = stored\n        case .rejectedCapacity:\n            return .rejected(reason: .capacity, detail: nil)\n        case .storageFailure:\n            return refuseStorage("inbox commit")\n        case .invalidArgument:\n            return .rejected(reason: .widths, detail: "commit args")\n        }\n\n        // -- step 6: AFTER the commit, the canonical recipient ACK, once ------\n        return try issueOrRestoreAck(frame, receivedFrom: receivedFrom,\n                                     heldNew: heldNew, obligationStored: obligationStored,\n                                     fault: fault)\n    }', 'replace': '        let hoisted = try issueOrRestoreAck(frame, receivedFrom: receivedFrom, heldNew: true,\n                                             obligationStored: true, fault: fault)\n        let outcome = try commitInbound(\n            frame, receivedFrom, ourNodeId, identityGeneration(),\n            ackRetentionMs, clockSeconds(), fault\n        )\n        switch outcome {\n        case .committed:\n            break\n        case .rejectedCapacity:\n            return .rejected(reason: .capacity, detail: nil)\n        case .storageFailure:\n            return refuseStorage("inbox commit")\n        case .invalidArgument:\n            return .rejected(reason: .widths, detail: "commit args")\n        }\n\n        // -- the ACK was signed and filed BEFORE the commit was ever consulted --\n        return hoisted\n    }', 'why': 'the canonical answer is signed and FILED before the inbox commit is ever consulted: the both-or-neither pair step can hand out an ACK for a delivery whose durable commit never ran (the order oracles reddens when the dying run files a row without a held line)', 'witness': 'testProcessKillAfterCommitBeforeAckRegeneratesExactlyOnce', 'swift_filter': 'ReadinessT37Tests'},
    {'id': 'T37-RC2-ios-routing-tag-gate-is-identity', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/RecipientInboxRepository.swift', 'find': '        var hintHit = false\n        for day in (today - hintWindowDays)...(today + hintWindowDays) {\n            if SealedSender.routingTag(recipientNodeId: ourNodeId, epochDay: day) == frame.routingTag {\n                hintHit = true\n            }\n        }\n        bump(hintHit ? .hintHit : .hintMiss)', 'replace': '        var hintHit = false\n        var admittedByTag = false\n        for day in (today - hintWindowDays)...(today + hintWindowDays) {\n            if SealedSender.routingTag(recipientNodeId: ourNodeId, epochDay: day) == frame.routingTag {\n                hintHit = true\n                admittedByTag = true\n            }\n        }\n        bump(hintHit ? .hintHit : .hintMiss)\n        if !admittedByTag { return .rejected(reason: .notForUs, detail: "tag gate") }', 'why': 'the 4-byte rotating tag is promoted from a charged hint to an admission gate: a clock-skewed node whose tag left the +-window can no longer deliver at all', 'witness': 'testStaleTagStillDeliversAndMatchedTagAdmitsNothingAlone', 'swift_filter': 'ReadinessT37Tests'},
    {'id': 'T37-RC3-ios-duplicate-forgets-the-filed-row-and-re-signs', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/RecipientInboxRepository.swift', 'find': '                if rec.verificationClass != .verifiedRecipiant { continue }', 'replace': '                if rec.verificationClass == .verifiedRecipiant { continue }', 'why': "the stored verified row is skipped on the duplicate read-back, so every re-delivery walks the fresh-signing path: on the host's randomized Ed25519 layer the handed-out bytes drift apart and the asked-once census breaks -- the durable row, not a re-signature, is the truth", 'witness': 'testDuplicateValidDeliveryRegeneratesSameAckWithoutDuplicateInbox', 'swift_filter': 'ReadinessT37Tests'},
    {'id': 'T37-RC4-ios-storage-failure-still-hands-out-an-ack', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/RecipientInboxRepository.swift', 'find': '        case .storageFailure:\n            return refuseStorage("inbox commit")', 'replace': '        case .storageFailure:\n            bump(.issued)\n            let bogus = (try? AckFrame.build(\n                msgId: frame.msgId, recipientSigningPrivKey: Data(repeating: 0, count: 32),\n                recipientNodeId: ourNodeId, routingTag: Data(ourNodeId.prefix(4)), ttl: ackInitialTtl\n            )) ?? frame\n            return admitArm(true, bogus)', 'why': 'the storage-failure arm admits a freshly built answer instead of refusing: "storage/verification failure: no ACK and no claimed local acceptance" -- the card\'s named negative', 'witness': 'testDiskFailureYieldsNeitherAckNorClaimedAcceptance', 'swift_filter': 'ReadinessT37Tests'},
    {'id': 'T37-RC5-ios-immediate-hop-stands-in-for-the-sender', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/RecipientInboxRepository.swift', 'find': '            return .rejected(reason: .verificationFailed, detail: "recipient binding")\n        }', 'replace': '            return .rejected(reason: .verificationFailed, detail: "recipient-binding")\n        }\n        if receivedFrom != vm.senderNodeId {\n            bump(.key)\n            return .rejected(reason: .keyUnavailable, detail: "hop is not the sender")\n        }', 'why': "the immediate-hop transport token is consulted as sender identity: a relayed delivery (hop != sender) is refused outright -- the task objective's named crime", 'witness': 'testImmediateHopIsNotTheSenderAndReceiptStands', 'swift_filter': 'ReadinessT37Tests'},
    {'id': 'T38-RC1-android-zero-seal-sails-through', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/wire/v2/SignedSosV1.kt', 'find': 'if (!signatureOk) return unauth(Reason.SIGNATURE)', 'replace': 'if (!signatureOk && false) return unauth(Reason.SIGNATURE)', 'why': 'the final cryptographic gate authenticates vacuously: the all-zero signature slot of the structural fixture -- and any forged seal whatsoever -- sails through to Authenticated; the section-15 split (structural fixtures stay structural, runtime authentication refuses them by name) is exactly what this witness kills', 'witness': 'testRuntimeRejectsZeroSignatureStructuralFixture', 'gradle_filter': 'ReadinessT38Test'},
    {'id': 'T38-RC1-ios-zero-seal-sails-through', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/SignedSosV1.swift', 'find': 'signer.isValidSignature(signature, for: signatureTranscript(messageId: msgRe,', 'replace': 'true || signer.isValidSignature(signature, for: signatureTranscript(\n                                                              messageId: msgRe,', 'why': 'the final cryptographic gate is made vacuously true in the compound guard (the guard-else law forbids an empty else -- so the clause itself is neutered, the split closer keeping the needle absent after): the all-zero signature slot of the structural fixture -- and any forged seal whatsoever -- sails through to authenticated; the section-15 split is what the court kills', 'witness': 'testRuntimeRejectsZeroSignatureStructuralFixture', 'swift_filter': 'ReadinessT38Tests'},

    {'id': 'T38-RC2-android-transcript-without-magic', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/wire/v2/SignedSosV1.kt', 'find': 'messageId + SOS_MAGIC + unsigned', 'replace': 'messageId + unsigned', 'why': 'the signature transcript loses the envelope magic: seals struck over msg_id || unsigned alone would verify against JVM-struck pins re-matched by any conforming receiver -- cross-isle signature validity is precisely what the pinned vectors prove and this falsifier kills', 'witness': 'testAuthorProducesVerifiableSignatureAcrossIsles', 'gradle_filter': 'ReadinessT38Test'},
    {'id': 'T38-RC2-ios-transcript-without-magic', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/SignedSosV1.swift', 'find': 'out.append(contentsOf: magic)\n        out.append(unsigned)', 'replace': 'out.append(unsigned)', 'why': 'the signature transcript loses the envelope magic on the iOS twin: seals struck over msg_id || unsigned alone would not verify against the JVM-struck pins -- the cross-isle golden seal is what this falsifier kills', 'witness': 'testAuthorProducesVerifiableSignatureAcrossIsles', 'swift_filter': 'ReadinessT38Tests'},
    {'id': 'T38-RC3-android-msg-id-over-signed-span', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/wire/v2/SignedSosV1.kt', 'find': 'val msgRe = deriveMessageId(derivedNode, createdAt, nonce, unsigned)', 'replace': 'val msgRe = deriveMessageId(derivedNode, createdAt, nonce, frame.payload)', 'why': "the frozen formula is taken over the SIGNED span (the seal is hashed into the id it signs): every re-derivation mismatches the header and every conforming frame falls to message_id_mismatch before the signature gate can speak -- the court's msg_id-equality and named-reason assertions are what kill it", 'witness': 'testAuthorProducesVerifiableSignatureAcrossIsles', 'gradle_filter': 'ReadinessT38Test'},
    {'id': 'T38-RC3-ios-msg-id-over-signed-span', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/SignedSosV1.swift', 'find': 'messageNonce: nonce, unsigned: unsigned)', 'replace': 'messageNonce: nonce, unsigned: frame.payload)', 'why': 'the frozen formula on the iOS twin runs over the SIGNED span: every re-derivation mismatches the header, the zero-seal fixture is refused by message_id_mismatch where the court expects .signature -- named reasons are what the court enforces', 'witness': 'testRuntimeRejectsZeroSignatureStructuralFixture', 'swift_filter': 'ReadinessT38Tests'},
    {'id': 'T38-RC4-android-person-equation-flipped', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/wire/v2/SignedSosV1.kt', 'find': 'if (expectedNodeId != null && !derivedNode.contentEquals(expectedNodeId))', 'replace': 'if (expectedNodeId != null && derivedNode.contentEquals(expectedNodeId))', 'why': "the identity equation is flipped: the derived node is TRUSTED toward the claim instead of checked against it -- the stranger's own honest distress would be accepted under the victim's claimed person and the honest frame under its true claim would be refused; the authenticated key standing apart from the verified person is exactly what the court defends", 'witness': 'testMalformedIdentityBindingRefused', 'gradle_filter': 'ReadinessT38Test'},
    {'id': 'T38-RC4-ios-person-equation-flipped', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/SignedSosV1.swift', 'find': 'if let claim = expectedNodeId, derivedNode != claim {', 'replace': 'if let claim = expectedNodeId, derivedNode == claim {', 'why': "the identity equation is flipped on the iOS twin: the derived node is trusted toward the claim instead of checked against it -- the stranger's honest distress authenticates under the victim's claimed person and the honest frame under its true claim falls; the key/person distinction is what the court defends", 'witness': 'testMalformedIdentityBindingRefused', 'swift_filter': 'ReadinessT38Tests'},
    {'id': 'T38-RC5-android-missing-flags-gate-skipped', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/wire/v2/SignedSosV1.kt', 'find': '            SosFrameValidator.Verdict.MISSING_REQUIRED_FLAGS ->\n                return unauth(Reason.MISSING_REQUIRED_FLAGS)', 'replace': '            SosFrameValidator.Verdict.MISSING_REQUIRED_FLAGS -> Unit', 'why': "the required-flags verdict is neutered: a frame lacking ACK_REQ|RELAY_OK sails past the dispatcher into the cryptographic gates and, being otherwise honest, authenticates -- the frozen table's required flags and the court's named refusal are what this kills", 'witness': 'testFakeSosByOneBitTypeChangeRefused', 'gradle_filter': 'ReadinessT38Test'},
    {'id': 'T38-RC5-ios-missing-flags-gate-skipped', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/SignedSosV1.swift', 'find': 'case .missingRequiredFlags: return .refuse(.missingRequiredFlags)', 'replace': 'case .missingRequiredFlags: break', 'why': "the required-flags verdict is neutered on the iOS twin: a frame lacking ACK_REQ|RELAY_OK sails past the switch into the cryptographic gates and authenticates -- the frozen table's required flags and the court's named refusal are what this kills", 'witness': 'testFakeSosByOneBitTypeChangeRefused', 'swift_filter': 'ReadinessT38Tests'},
    {'id': 'T39-RC1-android-cancel-is-ui-only', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt', 'find': 'val result = deliveryTracker.cancelSosBroadcast(msgId)', 'replace': 'val result = io.godstone.mesh.SosCancelResult.Cancelled(false)', 'why': 'the named semantic negative of the card: cancel only clears the remembered projection and reports a lie -- the durable row never moves terminal, the held frame never retires, so the restart scan re-exposes the supposedly cancelled call, the duplicate cancel never sees the idempotent no-op, and the relayed truth is fabricated; killed by the restart witness, the mid-flight writer witness, the relayed-truth witness, the idempotence witness and the flag-truth scan', 'witness': 'testCancelOfARelayedCallTellsTheRelayedTruth', 'gradle_filter': 'ReadinessT39Test'},
    {'id': 'T39-RC1-ios-cancel-is-ui-only', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/MeshNode.swift', 'find': 'let outcome = deliveryTracker.cancelSosBroadcast(msgId)', 'replace': 'let outcome = SosCancelResult.cancelled(wasRelayed: false)', 'why': 'the card\'s named defect restored-as-mutation: the coordinator\'s era of cancel-means-idle returns -- the durable row is never moved and the held frame never retired, yet the arm reports a fresh cancellation; the restart scan re-exposes the call, duplicates lose their idempotent naming, and the relayed truth is contradicted; killed by the same five witnesses on the second isle', 'witness': 'testCancelOfARelayedCallTellsTheRelayedTruth', 'swift_filter': 'ReadinessT39Tests'},
    {'id': 'T39-RC2-android-pair-rollback-leaks-frame', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/store/MessageStore.kt', 'find': '        } catch (_e: Throwable) {\n            held.remove(key)\n            deliveryRows.remove(key)\n            notifyHeldSetChanged()\n            return OutboundEnqueueResult.StorageFailure\n        }', 'replace': '        } catch (_e: Throwable) {\n            deliveryRows.remove(key)\n            notifyHeldSetChanged()\n            return OutboundEnqueueResult.StorageFailure\n        }', 'why': 'the both-or-neither law broken at the second write: a fault injected at the delivery-insert seam leaves the held frame standing without its row -- precisely the orphan the task was named to abolish; the second-write-failure witness counts the surviving orphan and the cross-table census convicts', 'witness': 'testEnqueueSecondWriteFailureRollsTheWholePairBack', 'gradle_filter': 'ReadinessT39Test'},
    {'id': 'T39-RC2-ios-pair-rollback-leaks-frame', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/MessageStore.swift', 'find': '            } catch {\n                rows = backupRows\n                deliveryRows = backupDeliveryRows\n                return .storageFailure\n            }', 'replace': '            } catch {\n                deliveryRows = backupDeliveryRows\n                return .storageFailure\n            }', 'why': 'the restore of the frame backup is dropped from the fault rollback: an injected second-write failure leaves the held entry without its delivery row under the store\'s single lock -- the torn pair the card names; the second-write-failure witness enumerates the residue and convicts', 'witness': 'testEnqueueSecondWriteFailureRollsTheWholePairBack', 'swift_filter': 'ReadinessT39Tests'},
    {'id': 'T39-RC3-android-retry-stops-resuming', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt', 'find': 'it.msgId.contentEquals(msgId) && it.type == io.godstone.mesh.wire.v2.TypeV2.SOS', 'replace': 'it.msgId.contentEquals(msgId) && it.type == io.godstone.mesh.wire.v2.TypeV2.MESSAGE', 'why': 'the resume ceases to resume the authored distress bytes: the held SOS frame is no longer recognized by the retry arm (the type octet is the first filter of the search), so the call that the tables still carry is refused as nameless and the zero-sends law for strangers goes untested; the same-bytes witness, the mid-flight writer and the command-surface routing all three miss their marks', 'witness': 'testRetryResumesTheSameAuthoredBytesAndFailsTyped', 'gradle_filter': 'ReadinessT39Test'},
    {'id': 'T39-RC3-ios-retry-stops-resuming', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/MeshNode.swift', 'find': '$0.msgId == msgId && $0.type == .sos', 'replace': '$0.msgId == msgId && $0.type == .message', 'why': 'the second isle\'s resume loses its first filter: the held distress frame is no longer named by the retry scan, the queue never flows again, and the arm that must report the same authored bytes reports a typed failure instead; the bytewise-verbatim witness and the command routing are killed together', 'witness': 'testRetryResumesTheSameAuthoredBytesAndFailsTyped', 'swift_filter': 'ReadinessT39Tests'},
    {'id': 'T39-RC4-android-cancel-leaves-held-work', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryTracker.kt', 'find': '                if (spec.retiresHeld) store.removeHeld(msgId)', 'replace': '                // mutabor: the retirement stands not (T39 RC4)', 'why': 'the C7.5 retirement is struck from the terminating transitions: the row moves cancelled while the held frame keeps standing -- scheduled work that the cancellation was bound to remove survives, the cross-table invariant (a held frame iff its live row) is torn at every cancel step of the campaign, and the relayed-truth witness reports a frame the retractation never retracted', 'witness': 'testCancelOfARelayedCallTellsTheRelayedTruth', 'gradle_filter': 'ReadinessT39Test'},
    {'id': 'T39-RC4-ios-cancel-leaves-held-work', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/DeliveryTracker.swift', 'find': '            if spec.heldDisposition == .retireAtomically { _ = store.removeHeld(msgId) }', 'replace': '            // mutabor: the retirement stands not (T39 RC4)', 'why': 'the atomic retirement of the held frame is removed from the cancel disposition on the second isle: cancelled rows outlive their frames, the campaign invariant certifies a torn pair, and the local-queue display would promise a cancellation the tables never performed', 'witness': 'testCancelOfARelayedCallTellsTheRelayedTruth', 'swift_filter': 'ReadinessT39Tests'},
    {'id': 'T39-RC5-android-none-mode-admits-acks', 'platform': 'jvm', 'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryTracker.kt', 'find': 'if (rec.ackMode == AckMode.NONE) return AckResult.NotAckEligible', 'replace': 'if (rec.ackMode == AckMode.SINGLE_RECIPIENT) return AckResult.NotAckEligible', 'why': 'the mode gate is inverted: a broadcast obligation in NONE mode no longer falls to the not-eligible name and the authentication road is entered without a bound recipient (the durable row names none, so the corrupt read returns), letting an unowning frame forge a delivery the tables never promised; the rejection-before-cryptography witness convicts with the authenticator census', 'witness': 'testNoneModeAckIsRejectedBeforeCryptography', 'gradle_filter': 'ReadinessT39Test'},
    {'id': 'T39-RC5-ios-none-mode-admits-acks', 'platform': 'swift', 'file': 'ios/Godstone/Sources/GodstoneMesh/DeliveryTracker.swift', 'find': 'if rec.ackMode == .none { return .notAckEligible }', 'replace': 'if rec.ackMode == .singleRecipient { return .notAckEligible }', 'why': 'on the second isle the NONE-mode refusal is likewise inverted: the correctly signed ACK of a broadcast reaches past the mode gate and the authenticator is consulted though it must never be, returning unknown where the direct path must name notAckEligible; the rejection witness convicts twice -- by the census of the verifier and by the typed outcome', 'witness': 'testNoneModeAckIsRejectedBeforeCryptography', 'swift_filter': 'ReadinessT39Tests'},
    {'id': "T40-RC1-android-digest-from-seen-union", 'platform': "jvm", 'file': "android/mesh/src/main/java/io/godstone/mesh/router/SyncControlOwner.kt", 'find': "for (id in snap.ids) bloom.add(id)", 'replace': "for (id in (snap.ids + relations.values.flatMap { it.wantQueue })) bloom.add(id)", 'why': "the card's first named negative restored-as-mutation: the advertised filter is built over the seen-but-unheld union -- every received id still waiting in any relation's want queue gains entry in the bloom, so the peer is told the store holds what the durable store has never carried; the advertisement witness at the run's close -- an empty store with thirty-six received ids waiting unclaimed -- demands the all-zero filter of the captured vector; the union paints bits and is taken", 'witness': "testSequenceDisciplineOnReceivedPages", 'gradle_filter': "ReadinessT40Test"},
    {'id': "T40-RC1-ios-digest-from-seen-union", 'platform': "swift", 'file': "ios/Godstone/Sources/GodstoneMesh/SyncControlOwner.swift", 'find': "for id in snap.ids { bloom.add(id) }", 'replace': "for id in snap.ids + relations.values.flatMap({ $0.wantQueue }) { bloom.add(id) }", 'why': "on the second isle the same forgetting: the digest speaks of the queues of every relation as well as the captured vector; the advertisement assertion at the run's close (empty store, thirty-six received ids waiting unclaimed), that the bloom is the vector's own all-zero filter, is falsified the moment the queues lend their bits", 'witness': "testSequenceDisciplineOnReceivedPages", 'swift_filter': "ReadinessT40Tests"},
    {'id': "T40-RC2-android-exact-reconciliation-silent", 'platform': "jvm", 'file': "android/mesh/src/main/java/io/godstone/mesh/router/SyncControlOwner.kt", 'find': "if (wanted.contains(hexOf(frame.msgId))) answers.add(frame)", 'replace': "if (!wanted.contains(hexOf(frame.msgId))) answers.add(frame)", 'why': "the card's second named negative: exact reconciliation is disabled at the responder -- every held frame is delivered but the very ones asked for; the forced collision cannot converge because the wanted foreign id never crosses the wire, and the delivery-count assertion counts zero", 'witness': "testForcedBloomCollisionConvergesByExactReconciliation", 'gradle_filter': "ReadinessT40Test"},
    {'id': "T40-RC2-ios-exact-reconciliation-silent", 'platform': "swift", 'file': "ios/Godstone/Sources/GodstoneMesh/SyncControlOwner.swift", 'find': "if wanted.contains(ControlPayloadV1.hexOf(frame.msgId)) { answers.append(frame) }", 'replace': "if !wanted.contains(ControlPayloadV1.hexOf(frame.msgId)) { answers.append(frame) }", 'why': "the second isle answers wants by everything except the wanted: the responder's walk returns the complement of the request, the convergee is never conveyed, and the bytewise delivery assertion falls silent at zero frames", 'witness': "testForcedBloomCollisionConvergesByExactReconciliation", 'swift_filter': "ReadinessT40Tests"},
    {'id': "T40-RC3-android-ordering-predicate-inverted", 'platform': "jvm", 'file': "android/mesh/src/main/java/io/godstone/mesh/router/SyncControlOwner.kt", 'find': "if (ControlPayloadV1.lexicographicCompare(p.ids[k - 1], p.ids[k]) >= 0) {", 'replace': "if (ControlPayloadV1.lexicographicCompare(p.ids[k - 1], p.ids[k]) <= 0) {", 'why': "the ordering predicate is inverted: the lawful ascending stream of a page is refused as if disorderly, so the first well-formed page of the walk meets a sequence refusal before any id is received; the sequence witness expects acceptance of four pages and counts a refusal at the first", 'witness': "testSequenceDisciplineOnReceivedPages", 'gradle_filter': "ReadinessT40Test"},
    {'id': "T40-RC3-ios-ordering-predicate-inverted", 'platform': "swift", 'file': "ios/Godstone/Sources/GodstoneMesh/SyncControlOwner.swift", 'find': "if ControlPayloadV1.lexicographicCompare(p.ids[k - 1], p.ids[k]) >= 0 {", 'replace': "if ControlPayloadV1.lexicographicCompare(p.ids[k - 1], p.ids[k]) <= 0 {", 'why': "the order is reversed on the second isle: ascending is refused and the walk of the received pages breaks at its first step; the sequence witness reports the refusal where acceptance was counted", 'witness': "testSequenceDisciplineOnReceivedPages", 'swift_filter': "ReadinessT40Tests"},
    {'id': "T40-RC4-android-stale-digest-adopted", 'platform': "jvm", 'file': "android/mesh/src/main/java/io/godstone/mesh/router/SyncControlOwner.kt", 'find': "if (rel.trackedSid != 0L && d.snapshotId < rel.trackedSid) {", 'replace': "if (rel.trackedSid != 0L && d.snapshotId > rel.trackedSid) {", 'why': "the staleness gate is turned about: the elder digest is adopted and the fresher is ignored, so the tracked snapshot walks backwards and the stale-digest witness, which demands the tracked sid stand at the newer, counts the elder name", 'witness': "testStaleDigestIsIgnoredTheTrackedOneStands", 'gradle_filter': "ReadinessT40Test"},
    {'id': "T40-RC4-ios-stale-digest-adopted", 'platform': "swift", 'file': "ios/Godstone/Sources/GodstoneMesh/SyncControlOwner.swift", 'find': "if rel.trackedSid != 0 && d.snapshotId < rel.trackedSid {", 'replace': "if rel.trackedSid != 0 && d.snapshotId > rel.trackedSid {", 'why': "on the second isle the tracked elder yields to the stale: the comparison inverts, the stale digest is received and the fresh one cast away; the witness that the tracked one stands is broken", 'witness': "testStaleDigestIsIgnoredTheTrackedOneStands", 'swift_filter': "ReadinessT40Tests"},
    {'id': "T40-RC5-android-controls-not-demultiplexed", 'platform': "jvm", 'file': "android/mesh/src/main/java/io/godstone/mesh/router/FrameDispatcher.kt", 'find': "            TypeV2.PING, TypeV2.HELLO, TypeV2.DIGEST, TypeV2.WANT -> {", 'replace': "            TypeV2.DIGEST -> {   // (mutant) the control frames are not demultiplexed", 'why': "the dispatch statute is disobeyed at the ingress: the PING is no longer demultiplexed to the per-relation owner but falls to the refusal gate, so the keepalive goes unanswered, the reply that echoes the nonce is never offered, and the campaign census counts a leg the profile must accept", 'witness': "testControlCampaignNeverTouchesTheDurableStore", 'gradle_filter': "ReadinessT40Test"},
    {'id': "T40-RC5-ios-controls-not-demultiplexed", 'platform': "swift", 'file': "ios/Godstone/Sources/GodstoneMesh/FrameDispatcher.swift", 'find': "        case .ping, .hello, .digest, .want:", 'replace': "        case .digest:   // (mutant) the control frames are not demultiplexed", 'why': "the second isle unmultiplexes too: with the PING disjunct struck the control frame meets the bulk-refusal road and the owner never decides it; the outbox census finds the reply missing and the campaign witness condemns", 'witness': "testControlCampaignNeverTouchesTheDurableStore", 'swift_filter': "ReadinessT40Tests"},
    {'id': "T45-SM1-publish-without-validation", 'platform': "python", 'file': "content/ingest/build_archive.py", 'find': "      if not report.ok:\n          raise ArchiveValidationError(report)", 'replace': "      if not report.ok and False:\n          raise ArchiveValidationError(report)", 'why': "the card's named corruption struck home: the validation gate is deafened and the destination is replaced before the staged database has been read over -- integrity, foreign keys, counts, ordering, the FTS answer and the metadata round-trip are all demanded of in vain, and the wrong-measure embedder's misshapen vectors would be published whole. The pre-gate arm of the validation witness condemns: the build must raise ArchiveValidationError and the destination must never have stood", 'witness': "testValidationReportCoversTheWholeContract", 'py_dir': "tools/readiness/tests", 'py_pattern': "test_t45.py"},
    {'id': "T45-SM2-indexes-never-built", 'platform': "python", 'file': "content/ingest/build_archive.py", 'find': "        conn.executescript(indexes_sql)", 'replace': "        pass  # (mutant) the index, FTS rebuild, merge, ANALYZE and VACUUM never run", 'why': "the second script of the contract is skipped: no ordinary indexes, no FTS5 rebuild, no merge, no ANALYZE, no VACUUM -- the lexical road is silent and the shipped file is fat and crooked. The query witness condemns: the MATCH probe answereth nothing where it was bound to answer", 'witness': "testFtsQueryAnswersAfterANoEmbeddingBuild", 'py_dir': "tools/readiness/tests", 'py_pattern': "test_t45.py"},
    {'id': "T45-SM3-copy-not-replace", 'platform': "python", 'file': "content/ingest/build_archive.py", 'find': "            os.replace(self.temp, self.destination)", 'replace': "            self.destination.write_bytes(self.temp.read_bytes())", 'why': "the promotion ceaseth to be a rename and becometh a truncating write: no atomic publish, a reader may see half a page, and the staged temporary is left standing where it should have vanisht. The determinism witness condemns the residue census that must have been empty", 'witness': "testRepeatedBuildPublishesByteIdenticalArchives", 'py_dir': "tools/readiness/tests", 'py_pattern': "test_t45.py"},
    {'id': "T45-SM4-frozen-dir-guard-sleepeth", 'platform': "python", 'file': "content/ingest/build_archive.py", 'find': "        raise ArchiveUnsafeDestinationError(\n            f\"destination resolves inside the {label} ({guarded}); the build \"\n            f\"may not write there\")", 'replace': "        pass  # (mutant) the resolves-inside guard sleepeth", 'why': "the watchman at the frozen directories is benumb: a destination that resolves inside the schema home or the corpus seed walketh on, and the build writeth its database over the very contract files it was sworn to keep. The destination witness condemns: the sneak file must not exist", 'witness': "testUnsafeDestinationsAreRefusedBeforeAnyWrite", 'py_dir': "tools/readiness/tests", 'py_pattern': "test_t45.py"},
    {'id': "T45-SM5-ceiling-removed", 'platform': "python", 'file': "content/ingest/build_archive.py", 'find': "    if size > max_staged_bytes:", 'replace': "    if size > max_staged_bytes and False:", 'why': "the section 18 staging ceiling is struck out and nothing denieth the over-large artifact: a build beyond the bounds is published as if it were within. The ceiling witness condemns: the named ArchiveTooLargeError is not raised where it was bound to be", 'witness': "testOverLargeArtifactIsRefusedWithANamedError", 'py_dir': "tools/readiness/tests", 'py_pattern': "test_t45.py"},
    {'id': "T45-SM6-emptiness-misnomed", 'platform': "python", 'file': "content/ingest/build_archive.py", 'find': "        raise ArchiveEmptyError(f\"no documents qualify for tier {tier}\")", 'replace': "        raise ArchiveBuildError(f\"no documents qualify for tier {tier}\")", 'why': "the empty corpus is cryed out with the wrong name: a generic build error weareth the mask of emptiness, and the law that failure be distinguished from empty no-op success is broken at the very distinction. The emptiness witness condemns: assertRaises(ArchiveEmptyError) seeth no ArchiveEmptyError, for the parent is not the kind", 'witness': "testEmptyCorpusIsRefusedAsEmptyNotAsSilentSuccess", 'py_dir': "tools/readiness/tests", 'py_pattern': "test_t45.py"},
    {'id': "T45-SM7-corpus-read-backwards", 'platform': "python", 'file': "content/ingest/build_archive.py", 'find': "    for path in sorted((seed / \"docs\").rglob(\"*.md\"), key=lambda p: str(p)):", 'replace': "    for path in sorted((seed / \"docs\").rglob(\"*.md\"), key=lambda p: str(p), reverse=True):", 'why': "the corpus is gathered against the law of the sorted walk: document_ids are given in the reverse of the paths, so the ids cease their offices and the rows come in an order that is not the canonical one. The sorter witness at the unit court condemneth: the names are not the names in the order the law appoints", 'witness': "test_corpus_is_sorted_and_culled_by_tier", 'py_dir': "content/tests", 'py_pattern': "test_build_archive.py"},
    {'id': "T45-SM8-sidecar-version-gate-blind", 'platform': "python", 'file': "content/ingest/build_archive.py", 'find': "    if version != SIDECAR_SCHEMA:", 'replace': "    if version != SIDECAR_SCHEMA and False:", 'why': "the version gate at the sidecar is blind: a record from a future toolchain is taken for current truth, unknown schemas obeyed rather than refused. The hash witness condemns: the forged schema ninety-nine should have been refused with an ArchiveBuildError and was not", 'witness': "testResultRecordsLogicalDigestAndFinalByteHashTruthfully", 'py_dir': "tools/readiness/tests", 'py_pattern': "test_t45.py"},
    {'id': "T45-SM9-dependency-misnamed", 'platform': "python", 'file': "content/ingest/build_archive.py", 'find': "                raise ArchiveDependencyError(\n                    f\"embedding dependency unavailable: {exc}\") from exc", 'replace': "                raise ArchiveBuildError(\n                    f\"embedding dependency unavailable: {exc}\") from exc", 'why': "the missing native leg is cryed out as a common build error: ArchiveDependencyError, the name that parteth the absent toolchain from a broken artifact, is unspoken, and callers that would treat the two otherwise are deceived. The query witness condemns at its absent-model arm: the named dependency error is not the error raised", 'witness': "testFtsQueryAnswersAfterANoEmbeddingBuild", 'py_dir': "tools/readiness/tests", 'py_pattern': "test_t45.py"},
    {'id': "T46-SM1-nonempty-is-enough", 'platform': "python", 'file': "content/release_gate.py", 'find': "        return True\n    except (InvalidSignature, ValueError):\n        return False", 'replace': "        return True\n    except (InvalidSignature, ValueError):\n        return True  # (mutant) nonempty is enough for this purse", 'why': "the card's first named corruption struck home: the verifier of detached signatures is made to return the thing it was bound to refuse, so every seal is admitted on the strength of its ink alone; the transplant of two records' signatures, each well formed and each binding nothing, is accepted as proof. The court witness at the seal condemneth: the transplanted seals must be refused and are not", 'witness': "testNonemptySignatureIsNotApproval", 'py_dir': "tools/readiness/tests", 'py_pattern': "test_t46.py"},
    {'id': "T46-SM2-payload-nominates-keys", 'platform': "python", 'file': "content/release_gate.py", 'find': "        raise TrustPolicyError(\n            f\"{what} is nominated from inside the bundle: {resolved} resolves \"\n            f\"within {guarded}; trust is configured independently or not at all\")", 'replace': "        pass  # (mutant) the bundle may nominate whom it will trust", 'why': "the card's second named corruption struck home: the independence guard sleepeth, and a trust store carried inside the seed, the manifests, the approvals home or the destination tree is obeyed as though the operator had configured it; the bundle nameth its own trusted keys and self-sealeth. The self-signed witness condemneth: the smuggled store must be refused unread and is not", 'witness': "testSelfSignedBundleIsRefused", 'py_dir': "tools/readiness/tests", 'py_pattern': "test_t46.py"},
    {'id': "T46-SM3-warnings-unbound", 'platform': "python", 'file': "content/release_gate.py", 'find': "        if record.warnings_sha256 != warnings_digest:", 'replace': "        if False and record.warnings_sha256 != warnings_digest:", 'why': "the warnings are unbound from the seal: the verifier looketh no more at the warning-set digest, and a declaration moved in the manifest -- the harvest altered, the warnings changed under the approval since it was signed -- passeth for truth. The changed-warning witness condemneth: the named set-fault is not named", 'witness': "testChangedWarningBreaksTheApproval", 'py_dir': "tools/readiness/tests", 'py_pattern': "test_t46.py"},
    {'id': "T46-SM4-coverage-blinded", 'platform': "python", 'file': "content/release_gate.py", 'find': "    if uncovered:", 'replace': "    if False and uncovered:", 'why': "the proof of coverage is made blind to wanting: chunks that no approval ever covered are shipped as if they had been, the unapproved cry silenced. The coverage witness condemneth: the unapproved cry must be heard", 'witness': "testMissingCoverageIsRefused", 'py_dir': "tools/readiness/tests", 'py_pattern': "test_t46.py"},
    {'id': "T46-SM5-clock-inverted", 'platform': "python", 'file': "content/release_gate.py", 'find': "        if record.valid_until < today:", 'replace': "        if record.valid_until > today:", 'why': "the window observed is made to look the wrong way: the expired approval is fresh, the fresh is old, and none are admitted that are in force to-day. The expiry witness condemneth: 'approval expired' must be cried on the morrow and is not", 'witness': "testExpiryIsRefusedBothWays", 'py_dir': "tools/readiness/tests", 'py_pattern': "test_t46.py"},
    {'id': "T46-SM6-collapsing-reader", 'platform': "python", 'file': "content/archive_manifest.py", 'find': "            if key in seen:\n                raise ArchiveManifestError(f\"duplicate key {key!r} in {origin}\")", 'replace': "            if key in seen:\n                pass  # (mutant) the collapsing reader may collapse whom it will", 'why': "the duplicate-key hook is disarmed and the reader collapseth again: a manifest carrying a twin tier, a doubled schema, a second signature-value ad maietur in the same object, is parsed to the last-wins lie it speaketh. The duplicates witness condemneth: the smuggled twin must be refused at the archive face", 'witness': "testDuplicateManifestEntriesAreRefused", 'py_dir': "tools/readiness/tests", 'py_pattern': "test_t46.py"},
    {'id': "T46-SM7-warden-discharged", 'platform': "python", 'file': "content/ingest/build_archive.py", 'find': "        fault = _media_path_fault(rel)\n        if fault is not None:", 'replace': "        fault = None  # (mutant) every path is welcome home\n        if fault is not None:", 'why': "the media warden is discharged: an absolute way, a NUL byte, a backslash road, a drive-letter sign, and the .. that goeth up, are all made welcome to the rows of the table, though they be rogues. The traversal witness condemneth: the rogues must be refused at the gate", 'witness': "testPathTraversalIsRefused", 'py_dir': "tools/readiness/tests", 'py_pattern': "test_t46.py"},
    {'id': "T46-SM8-post-dup-blind", 'platform': "python", 'file': "scripts/prepare_release_assets.py", 'find': "        if source in sources_seen:", 'replace': "        if False and source in sources_seen:", 'why': "the duplicated source is overlooked at the staging post: the same bytes may ride to two names, and the post keepeth no count of the sources it hath staged. The duplicates witness condemneth this arm also: duplicate asset source must be cried and is not", 'witness': "testDuplicateManifestEntriesAreRefused", 'py_dir': "tools/readiness/tests", 'py_pattern': "test_t46.py"},
    {"id": "T47-SM1-serve-because-it-existeth", "platform": "jvm", "module": "core", "file": "android/core/src/main/java/io/godstone/core/archive/ArchiveInstaller.kt", "find": "current.length() == bundle.size.toLong() &&\n                runCatching { Sha256.hexOf(current) }.getOrNull() == digest", "replace": "current.length() == bundle.size.toLong()", "why": "the idempotence branch believeth existence and length alone; a tampered cache of the same length is declared already-installed and is never rewritten. The stale-cache witness condemneth -- the card's serve-a-cache-because-it-existeth falsification.", "witness": "testTheStaleCacheIsRenewedAndNeverServedBecauseItExisteth", "gradle_filter": "*ReadinessT47Test*", "court": "android/core/src/test/java/io/godstone/core/readiness/ReadinessT47Test.kt"},
    {"id": "T47-SM2-provenance-fabricated", "platform": "jvm", "module": "core", "file": "android/core/src/main/java/io/godstone/core/archive/ArchiveDatabase.kt", "find": "(connection as Any)::class.java.name", "replace": "\"androidx.sqlite.driver.bundled.ProvenanceFabricatedConnection\"", "why": "the road's provenance is fabricated instead of being spoken by the connection that opened it; the engine-identity witness (which now demandeth the word Bundled on the face of the name) condemneth -- the card's platform-substitution falsification at the provenance gate.", "witness": "testTheBundledEngineItselfAnswerethUnderTheCourt", "gradle_filter": "*ReadinessT47Test*", "court": "android/core/src/test/java/io/godstone/core/readiness/ReadinessT47Test.kt"},
    {"id": "T47-SM3-phrase-bound-widened", "platform": "jvm", "module": "core", "file": "android/core/src/main/java/io/godstone/core/archive/SearchQuery.kt", "find": "if (raw.length > MAX_PHRASE_CHARS) {", "replace": "if (raw.length > MAX_PHRASE_CHARS + 4096) {", "why": "the phrase bound is widened out of all service; a 600-character petition is entertained as though it were lawful. The bounds witness condemneth.", "witness": "testTheBoundsOfPhraseTermAndPageAreEachEnforcedAndReported", "gradle_filter": "*ReadinessT47Test*", "court": "android/core/src/test/java/io/godstone/core/readiness/ReadinessT47Test.kt"},
    {"id": "T47-SM4-term-bound-widened", "platform": "jvm", "module": "core", "file": "android/core/src/main/java/io/godstone/core/archive/SearchQuery.kt", "find": "if (terms.size > MAX_TERMS) {", "replace": "if (terms.size > MAX_TERMS + 100) {", "why": "the distinct-term bound is widened; a thirty-three-term petition marcheth through unrefused. The bounds witness condemneth.", "witness": "testTheBoundsOfPhraseTermAndPageAreEachEnforcedAndReported", "gradle_filter": "*ReadinessT47Test*", "court": "android/core/src/test/java/io/godstone/core/readiness/ReadinessT47Test.kt"},
    {"id": "T47-SM5-terms-unquoted", "platform": "jvm", "module": "core", "file": "android/core/src/main/java/io/godstone/core/archive/SearchQuery.kt", "find": "terms.joinToString(\" OR \") { \"\\\"\" + it + \"\\\"\" }", "replace": "terms.joinToString(\" OR \") { it }", "why": "the quote quarantine is broken; terms march bare into the MATCH grammar, where a stray word may steer the parser. The grammar witness (whose fullmatch assay alloweth only quoted phrasings joined by OR) condemneth.", "witness": "testNoRawMouthFullTextEnteretheMatchGrammarUnquoted", "gradle_filter": "*ReadinessT47Test*", "court": "android/core/src/test/java/io/godstone/core/readiness/ReadinessT47Test.kt"},
    {"id": "T47-SM6-page-bound-gone", "platform": "jvm", "module": "core", "file": "android/core/src/main/java/io/godstone/core/archive/SearchQuery.kt", "find": "fun bound(limit: Int): Int = limit.coerceIn(1, MAX_RESULTS)", "replace": "fun bound(limit: Int): Int = if (limit < 1) 1 else limit", "why": "the page bound is loosed from below only; a petition of 9999 rows is granted in full. The bounds witness condemneth.", "witness": "testTheBoundsOfPhraseTermAndPageAreEachEnforcedAndReported", "gradle_filter": "*ReadinessT47Test*", "court": "android/core/src/test/java/io/godstone/core/readiness/ReadinessT47Test.kt"},
    {"id": "T47-SM7-record-checks-sleep", "platform": "jvm", "module": "core", "file": "android/core/src/main/java/io/godstone/core/archive/ArchiveInstaller.kt", "find": "        if (digest != record.sha256) {\n            return InstallOutcome.Unavailable(\n                \"cache integrity: the installed bytes do not match their record\")\n        }\n        if (current.length() != record.bytes) {\n            return InstallOutcome.Unavailable(\n                \"cache integrity: the installed length does not match the record\")\n        }", "replace": "        if (false && digest != record.sha256) {\n            return InstallOutcome.Unavailable(\n                \"cache integrity: the installed bytes do not match their record\")\n        }\n        if (false && current.length() != record.bytes) {\n            return InstallOutcome.Unavailable(\n                \"cache integrity: the installed length does not match the record\")\n        }", "why": "the serve-time re-verification sleepeth through both its arms; existence and the record's bare word enshrine the cache. The existence witness (torn and smeared-deep arms) and the stale-cache witness's blind arm together condemneth -- the card's serve-because-it-existeth falsification in its serve-time dress.", "witness": "testServeIsNeverAnExistenceCheckAlone", "gradle_filter": "*ReadinessT47Test*", "court": "android/core/src/test/java/io/godstone/core/readiness/ReadinessT47Test.kt"},
    {"id": "T47-SM8-future-clause-blind", "platform": "jvm", "module": "core", "file": "android/core/src/main/java/io/godstone/core/archive/ArchiveManifest.kt", "find": "if (schema > MANIFEST_SCHEMA) {", "replace": "if (false && schema > MANIFEST_SCHEMA) {", "why": "the future-version clause is put out of its sight; a schema the build understandeth not stumbleth past the gate and is refused only by the plain-equality arm, whose cry lacketh the word future the witness now demandeth. The manifest witness condemneth.", "witness": "testTheManifestClauseRefusethFutureVersionsAndLies", "gradle_filter": "*ReadinessT47Test*", "court": "android/core/src/test/java/io/godstone/core/readiness/ReadinessT47Test.kt"},
    {"id": "T47-SM9-table-probe-blindfolded", "platform": "jvm", "module": "core", "file": "android/core/src/main/java/io/godstone/core/archive/ArchiveDatabase.kt", "find": "val missing = REQUIRED_TABLES.filterNot { name -> handle.hasTable(name) }", "replace": "val missing = emptyList<String>()", "why": "the required-tables probe is blindfolded; a bundle wanting documents, chunks, and the FTS5 index is welcomed to the slot with honour. The refusals witness (sparse-bundle arm) condemneth.", "witness": "testCorruptedOrMissingBundlesAreRefusedWithTheirCausesNamed", "gradle_filter": "*ReadinessT47Test*", "court": "android/core/src/test/java/io/godstone/core/readiness/ReadinessT47Test.kt"},
    {"id": "T47-SM10-integrity-arm-muzzled", "platform": "jvm", "module": "core", "file": "android/core/src/main/java/io/godstone/core/archive/ArchiveDatabase.kt", "find": "if (!integrity.startsWith(\"ok\")) {", "replace": "if (false && !integrity.startsWith(\"ok\")) {", "why": "the engine's own integrity cry is muzzled; page heads smeared to 0xFF FF stand accused and are cleared to the slot. The existence witness (smeared-deep arm) condemneth.", "witness": "testServeIsNeverAnExistenceCheckAlone", "gradle_filter": "*ReadinessT47Test*", "court": "android/core/src/test/java/io/godstone/core/readiness/ReadinessT47Test.kt"},
    {"id": "T48-SM1-tables-probe-blindfolded", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveRepository.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT48Tests.swift", "swift_filter": "ReadinessT48Tests", "find": "        for name in requiredTables {\n            if !hasTable(handle, name) {", "replace": "        for name in requiredTables.prefix(0) {\n            if !hasTable(handle, name) {", "why": "the required-tables probe is blindfolded: an archive wanting chunks_fts (or documents, or the meta) is welcomed to the slot with honour. The covenant witness condemns -- the missing index must be named and is not", "witness": "testTheSchemaCovenantRefusethByTwoRoads"},
    {"id": "T48-SM2-integrity-cry-muzzled", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveRepository.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT48Tests.swift", "swift_filter": "ReadinessT48Tests", "find": "        if report != \"ok\" {", "replace": "        if false && report != \"ok\" {", "why": "the engine's own integrity cry is muzzled; page heads defaced to 0xFF FF stand accused and are cleared to the slot, for the tables probe readeth the master page alone. The sound-header-defaced-body witness condemns -- the card's opened-is-not-usable falsification in its deepest dress", "witness": "testRandomBytesUnderASoundHeaderAreNotAnArchive"},
    {"id": "T48-SM3-documents-count-asleep", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveRepository.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT48Tests.swift", "swift_filter": "ReadinessT48Tests", "find": "        if countScalar(handle, \"SELECT COUNT(*) FROM documents\") == 0 {", "replace": "        if false && countScalar(handle, \"SELECT COUNT(*) FROM documents\") == 0 {", "why": "the non-contentment guard sleepeth on the documents arm; a husk empty of documents is judged only by whatever the chunks arm may cry. The empty-husk witness condemns: the cry must name what is wanting", "witness": "testTheEmptyHuskIsCorruptNotServable"},
    {"id": "T48-SM4-schema-covenant-true-always", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveRepository.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT48Tests.swift", "swift_filter": "ReadinessT48Tests", "find": "        guard schema == schemaVersion else {", "replace": "        guard schema == schemaVersion || true else {", "why": "the schema covenant is made tautological: a archive_meta declaring version 2 (or 99) passeth the gate unchallenged. The covenant witness condemns -- the refusal must tell found from understood and it hat not", "witness": "testTheSchemaCovenantRefusethByTwoRoads"},
    {"id": "T48-SM5-tier-pairing-unwedded", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveRepository.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT48Tests.swift", "swift_filter": "ReadinessT48Tests", "find": "        if let expectedTier, databaseName != expectedTier.archiveDatabaseName {", "replace": "        if let expectedTier, false && (databaseName != expectedTier.archiveDatabaseName) {", "why": "the tier and the file are unwedded: archive_light.db may serve a medium build unrefused. The pairing witness condemns -- the refusal must name the tier and the file it owns", "witness": "testTheTierAndTheFileMustPair"},
    {"id": "T48-SM6-return-empty-on-sql-failure", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveRepository.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT48Tests.swift", "swift_filter": "ReadinessT48Tests", "find": "            sqlite3_finalize(stmt)\n            throw ArchiveError.queryFailed(\"\\(why) [prepare \\(Self.ellipsis(sql))]\")", "replace": "            sqlite3_finalize(stmt)\n            return [] // (mutant) the card's own falsification: the woe collapseth into the empty list", "why": "THE CARD'S OWN FALSIFICATION, executed: 'Return [] for SQL failure: error-state/no-results distinction test fails'. The prepare-failure road returneth the empty lie instead of crying queryFailed. The distinction witness condemns -- the lying index must raise and it resteth silent", "witness": "testQueryFailureIsNotNoResults"},
    {"id": "T48-SM7-token-guard-sleepeth", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveReaderModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT48Tests.swift", "swift_filter": "ReadinessT48Tests", "find": "            guard activeRequest == requestID else { return } // stale: verbatim from the WIP", "replace": "            if activeRequest != requestID { } // (mutant) the token is consulted, not obeyed", "why": "the generation token is consulted but not obeyed: a superseded search, completing late, publisheth its stale page over the fresh browse. The stale-supersede witness condemns -- the card names the stale query response among the required cases", "witness": "testOlderSearchCannotReplaceNewBrowseResult"},
    {"id": "T48-SM8-mid-probe-deleted", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveReaderModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT48Tests.swift", "swift_filter": "ReadinessT48Tests", "find": "            try Task.checkCancellation()\n            guard activeRequest == requestID else { return } // stale: verbatim from the WIP", "replace": "            guard activeRequest == requestID else { return } // (mutant) the mid probe is dark", "why": "the cancellation probe between the read and the publish is struck out: a dismissed view, resuming late, publisheth its result after all. The cancellation witness condemns -- a cancelled road publisheth nothing and here it publisheth", "witness": "testCancelledViewCannotPublishLateResult"},
    {"id": "T48-SM9-phrase-bound-widened", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveAvailability.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT48Tests.swift", "swift_filter": "ReadinessT48Tests", "find": "        if raw.count > maxPhraseChars {", "replace": "        if raw.count > maxPhraseChars + 4096 {", "why": "the phrase bound is widened out of all service: a 600-character petition is entertained as though it were lawful. The bounds witness condemns, and the 513th character with it", "witness": "testBoundsOfPhraseTermAndPageAreEachEnforcedAndReported"},
    {"id": "T48-SM10-term-bound-widened", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveAvailability.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT48Tests.swift", "swift_filter": "ReadinessT48Tests", "find": "        if terms.count > maxTerms {", "replace": "        if terms.count > maxTerms + 100 {", "why": "the distinct-term bound is widened; a thirty-three-term petition marcheth through unrefused. The bounds witness condemns", "witness": "testBoundsOfPhraseTermAndPageAreEachEnforcedAndReported"},
    {"id": "T48-SM11-page-ceiling-loosed", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveAvailability.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT48Tests.swift", "swift_filter": "ReadinessT48Tests", "find": "        max(1, min(maxResults, limit))", "replace": "        max(1, limit)", "why": "the page ceiling is loosed from above: a petition of 9999 rows is granted in full. The bounds witness condemns -- the flood must be bounded to 200 and it overfloweth", "witness": "testBoundsOfPhraseTermAndPageAreEachEnforcedAndReported"},
    {"id": "T48-SM12-quotes-unquoted", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveAvailability.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT48Tests.swift", "swift_filter": "ReadinessT48Tests", "find": "terms.map { \"\\\"\\($0)\\\"\" }.joined(separator: \" OR \")", "replace": "terms.map { $0 }.joined(separator: \" OR \")", "why": "the quote quarantine is broken: terms march bare into the MATCH grammar, where a stray word may steer the parser. The bounds witness condemns -- the first and last terms must be quarantined and stand naked", "witness": "testBoundsOfPhraseTermAndPageAreEachEnforcedAndReported"},
    {"id": "T49-SM1-empty-lie-conflated", "platform": "jvm", "module": "app", "test_task": "testLightDebugUnitTest", "file": "android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT49Test.kt", "gradle_filter": "*ReadinessT49Test*", "find": "phase = if (hits.isEmpty()) BrowsePhase.NoResults else BrowsePhase.Ready,", "replace": "phase = if (hits.isEmpty()) BrowsePhase.Ready else BrowsePhase.Ready,", "why": "the honest empty and the served page are conflated: an unmatching word on a ready archive standeth proclaimed Ready. The distinction witness condemneth -- NoResults is a tale the road must tell in its own voice", "witness": "testTheUnavailableArchiveNeverMasqueradethAsAnEmptyOne"},
    {"id": "T49-SM2-presence-trusted-not-verdict", "platform": "jvm", "module": "app", "test_task": "testLightDebugUnitTest", "file": "android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT49Test.kt", "gradle_filter": "*ReadinessT49Test*", "find": "                onSuccess = { hits ->\n                    when (val verdict = archiveVerdict()) {\n                        is ArchiveState.Ready ->", "replace": "                onSuccess = { hits ->\n                    when (val verdict = ArchiveState.Ready(origin = \"assumed\", sha256 = \"\")) {\n                        is ArchiveState.Ready ->", "why": "THE CARD'S OWN FALSIFIER, executed: the search road ceaseth consulting the reader's typed verdict and trusteth presence alone -- an absent or defaced archive answereth the empty list and the field saith NoResults, a masquerade. The distinction witness condemneth, and the real-road witness with it", "witness": "testTheUnavailableArchiveNeverMasqueradethAsAnEmptyOne"},
    {"id": "T49-SM3-before-gate-sleepeth", "platform": "jvm", "module": "app", "test_task": "testLightDebugUnitTest", "file": "android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT49Test.kt", "gradle_filter": "*ReadinessT49Test*", "find": "if (generation.get() != token) return@launch          // stale before the road", "replace": "if (false) return@launch          // (mutant) the gate sleepeth", "why": "the token is not consulted before delivery: a superseded search walketh the road after the navigation passed  it. The queue witness condemneth -- searched must be empty, and it is not", "witness": "testQueuedSearchCannotOvertakeTheNewerNavigation"},
    {"id": "T49-SM4-after-gate-sleepeth", "platform": "jvm", "module": "app", "test_task": "testLightDebugUnitTest", "file": "android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT49Test.kt", "gradle_filter": "*ReadinessT49Test*", "find": "if (generation.get() != token) return@launch          // stale after the road", "replace": "if (false) return@launch          // (mutant) the gate sleepeth", "why": "the token is not revalidated after the road: an obsolete failure, late upon the workers, publisheth its woe over the newer results. The two-worker witness condemneth -- the newer tale must stand untampered", "witness": "testAnObsoleteFailureCannotOverwriteNewerResults"},
    {"id": "T49-SM5-the-banner-leaketh", "platform": "jvm", "module": "app", "test_task": "testLightDebugUnitTest", "file": "android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT49Test.kt", "gradle_filter": "*ReadinessT49Test*", "find": "            phase = BrowsePhase.Unavailable(\n                \"$what (\" + (exc::class.simpleName ?: \"unknown\") + \")\",\n                recoverable = true),", "replace": "            phase = BrowsePhase.Unavailable(\n                what + \": \" + (exc.message ?: exc::class.simpleName ?: \"unknown\"),\n                recoverable = true),", "why": "the sanitisation is struck: the cause's own words -- the private database path and all the engine may say -- travel into the banner the user readeth. The sanitised-tale witness condemneth, W5b whose arm alone speaketh of leaks", "witness": "testTheShownTaleIsSanitisedNotTheCausesOwnWords"},
    {"id": "T49-SM6-field-relabelleth", "platform": "jvm", "module": "app", "test_task": "testLightDebugUnitTest", "file": "android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT49Test.kt", "gradle_filter": "*ReadinessT49Test*", "find": "_state.value = _state.value.copy(query = value.take(SearchQuery.MAX_PHRASE_CHARS))", "replace": "_state.value = _state.value.copy(query = value.take(SearchQuery.MAX_PHRASE_CHARS), searchedQuery = if (value.isBlank()) _state.value.searchedQuery else value.trim())", "why": "the mutable field relabelleth the published identity: editing the query after a search mutateth what was searched. The immutability witness condemneth -- the submitted thing standeth immutable", "witness": "testEditingTheFieldNeverRelabellethSubmittedResults"},
    {"id": "T49-SM7-bound-striken", "platform": "jvm", "module": "app", "test_task": "testLightDebugUnitTest", "file": "android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT49Test.kt", "gradle_filter": "*ReadinessT49Test*", "find": "value.take(SearchQuery.MAX_PHRASE_CHARS)", "replace": "value.take(10000)", "why": "the viewmodel gate forgetteth its bounds: a ten-thousand-character petition floweth whole to the engine. The bounds witness condemneth -- the field must be capped at the fifty and twelve the engine commandeth", "witness": "testBlankSearchReturnethToDocumentsAndTheFieldIsBounded"},
    {"id": "T49-SM8-blank-became-search", "platform": "jvm", "module": "app", "test_task": "testLightDebugUnitTest", "file": "android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT49Test.kt", "gradle_filter": "*ReadinessT49Test*", "find": "        if (query.isEmpty()) {\n            backToDocuments()", "replace": "        if (false) {\n            backToDocuments()", "why": "the blank petition ceaseeth to be a return: whitespace searcheth as though it were a word, and the journey loseth its root. The blank-and-bounded witness condemneth", "witness": "testBlankSearchReturnethToDocumentsAndTheFieldIsBounded"},
    {"id": "T49-SM9-retry-unearned", "platform": "jvm", "module": "app", "test_task": "testLightDebugUnitTest", "file": "android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT49Test.kt", "gradle_filter": "*ReadinessT49Test*", "find": "if (_state.value.canRetry) lastRequest?.invoke()", "replace": "lastRequest?.invoke()", "why": "retry is freed of its warrant: the road is ridden again though no failure earned it. The earned-retry witness condemneth -- 'retry only for recoverable errors' is the card's own clause", "witness": "testRetryIsEarnedOnlyWhereTheRoadMayMend"},
    {"id": "T49-SM10-restore-amnesial-mode", "platform": "jvm", "module": "app", "test_task": "testLightDebugUnitTest", "file": "android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT49Test.kt", "gradle_filter": "*ReadinessT49Test*", "find": "    fun snapshotTo(handle: MutableMap<String, Any?>) {\n        val s = _state.value\n        handle[\"query\"] = s.query\n        handle[\"searchedQuery\"] = s.searchedQuery\n        handle[\"mode\"] = s.mode.name", "replace": "    fun snapshotTo(handle: MutableMap<String, Any?>) {\n        val s = _state.value\n        handle[\"query\"] = s.query\n        handle[\"searchedQuery\"] = s.searchedQuery\n        handle[\"mode\"] = BrowseMode.DOCUMENTS.name", "why": "the recreation witness forgetteth the scene: a journey interrupted in the document standeth reposed at the root. The recreation witness condemneth", "witness": "testProcessRecreationRestorethTheSameJourney"},
    {"id": "T49-SM11-restore-amnesial-identity", "platform": "jvm", "module": "app", "test_task": "testLightDebugUnitTest", "file": "android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT49Test.kt", "gradle_filter": "*ReadinessT49Test*", "find": "    fun snapshotTo(handle: MutableMap<String, Any?>) {\n        val s = _state.value\n        handle[\"query\"] = s.query\n        handle[\"searchedQuery\"] = s.searchedQuery\n        handle[\"mode\"] = s.mode.name\n        handle[\"openedDocumentId\"] = s.openedDocumentId", "replace": "    fun snapshotTo(handle: MutableMap<String, Any?>) {\n        val s = _state.value\n        handle[\"query\"] = s.query\n        handle[\"searchedQuery\"] = s.searchedQuery\n        handle[\"mode\"] = s.mode.name\n        handle[\"openedDocumentId\"] = null", "why": "the opened document identity is struck from the recreation handle: the journey returneth stripped of whom it was reading. The recreation witness condemneth -- restored query AND document identity are the card's words", "witness": "testProcessRecreationRestorethTheSameJourney"},
    {"id": "T49-SM12-status-muzzled", "platform": "jvm", "module": "app", "test_task": "testLightDebugUnitTest", "file": "android/core/src/main/java/io/godstone/core/archive/ArchiveRepository.kt", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT49Test.kt", "gradle_filter": "*ReadinessT49Test*", "find": "override fun status(): ArchiveState = arm.state", "replace": "override fun status(): ArchiveState = ArchiveState.Ready(origin = \"muzzled\", sha256 = \"\")", "why": "the real repository ceaseeth to speak its arm: defaced bytes answereth Ready evermore. The real-road witness condemneth -- W15, which no fake could ever have condemned", "witness": "testTheRealFrozenRoadCarriethProvenanceAndTellethTruth"},
    {"id": "T49-SM13-provenance-lie", "platform": "jvm", "module": "app", "test_task": "testLightDebugUnitTest", "file": "android/core/src/main/java/io/godstone/core/archive/ArchiveRepository.kt", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT49Test.kt", "gradle_filter": "*ReadinessT49Test*", "find": "sourceId = row[4] as String,", "replace": "sourceId = \"\",", "why": "the enrichment lies: the frozen source column is overwritten with the empty tale. The real-road witness condemneth -- 'source/revision display' must carry the true words", "witness": "testTheRealFrozenRoadCarriethProvenanceAndTellethTruth"},
    {"id": "T49-SM14-projection-unbound", "platform": "jvm", "module": "app", "test_task": "testLightDebugUnitTest", "file": "android/core/src/main/java/io/godstone/core/archive/ArchiveRepository.kt", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT49Test.kt", "gradle_filter": "*ReadinessT49Test*", "find": "\"FROM documents WHERE document_id = ?\",", "replace": "\"FROM documents WHERE 1 = 1,\",", "why": "the provenance projection is unbound from its key: any document nameth an unheard document's words. The real-road witness condemneth -- null must answer the unheard", "witness": "testTheRealFrozenRoadCarriethProvenanceAndTellethTruth"},
    {"id": "T50-SM1-absent-masqueth-ready", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests", "find": "        let hits = passagesOf(model.state)\n        switch reading.availability {\n        case .ready:\n            searchedQuery = petition.phrase", "replace": "        let hits = passagesOf(model.state)\n        switch ArchiveAvailability.ready(origin: \"the mutant trusteth presence\") {\n        case .ready:\n            searchedQuery = petition.phrase", "why": "THE CARD'S OWN FALSIFIER: the search road ceaseth consulting the typed verdict and trusteth presence alone -- an absent archive answereth the empty list and the field saith noResults, a masquerade. The distinction witness condemneth", "witness": "testTheHonestEmptyAndTheAbsentAreTalesToldApart"},
    {"id": "T50-SM2-empty-conflated-ready", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests", "find": "            if let hits, !hits.isEmpty {", "replace": "            if let hits, true || !hits.isEmpty {", "why": "the honest empty is conflated with the served page: an unmatching word on a ready archive standeth proclaimed ready. The distinction witness condemneth -- noResults is a tale the road must tell in its own voice", "witness": "testTheHonestEmptyAndTheAbsentAreTalesToldApart"},
    {"id": "T50-SM3-before-gate-sleepeth", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests", "find": "        if epoch != petition.token { return }   // stale before the road", "replace": "        if epoch != petition.token { }   // (mutant) the gate sleepeth", "why": "the token is not consulted before delivery: a superseded petition walketh the road and toucheth the engine at all. The before-gate witness condemneth -- the fake history must stay empty and it is not", "witness": "testTheGateBeforeTheRoadStoppetheTheSupersededPetition"},
    {"id": "T50-SM4-after-gate-sleepeth", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests", "find": "        await model.load(.search(petition.phrase))\n        if epoch != petition.token { return }   // stale after the road", "replace": "        await model.load(.search(petition.phrase))\n        if epoch != petition.token { }                       // (mutant) the gate sleepeth", "why": "the token is not revalidated after the road: an obsolete failure, wakened late, publisheth its woe over the younger tale. The after-gate witness condemneth -- the determinism law of T49, unenforced", "witness": "testAnObsoleteFailureCannotOverwriteNewerResults"},
    {"id": "T50-SM5-banner-leaketh", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests", "find": "            reason: ArchiveUserMessage.spoken(for: archiveError) + \" (\" + kindOf(archiveError) + \")\",\n            recoverable: mendable)", "replace": "            reason: ArchiveUserMessage.diagnostic(for: archiveError),\n            recoverable: mendable)", "why": "the sanitisation is struck: the banner carrieth the engine's own words -- prepare failures, errmsg fragments, SQL the user was never meant to see. The banner witness condemneth", "witness": "testTheBannerCarriethNoSQLWhispers"},
    {"id": "T50-SM6-field-not-trimmed", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests", "find": "            query = petition.phrase   // the trim publish: the field telleth what stands published", "replace": "            // (mutant) the field forgetteth what standeth published", "why": "the published road leave the field untrimmed: the user confronteth \"  water  \" where the identity saith water. The whole-journey witness condemneth -- the quarry law (assertEquals guide after the round trip) unfulfilled", "witness": "testSearchOpensTheWholeDocumentAndBackRestorethTheScene"},
    {"id": "T50-SM7-field-relabelleth", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests", "find": "    public func onQueryChanged(_ value: String) {\n        query = String(value.prefix(ArchiveSearchQuery.maxPhraseChars))\n    }", "replace": "    public func onQueryChanged(_ value: String) {\n        query = String(value.prefix(ArchiveSearchQuery.maxPhraseChars))\n        searchedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)\n    }", "why": "the mutable field reladleth the published identity: editing the query after a search mutateth what was searched. The immutability witness condemneth -- the submitted thing standeth immutable", "witness": "testEditingTheFieldNeverReladlethSubmittedResults"},
    {"id": "T50-SM8-blank-became-petition", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests", "find": "        guard !trimmed.isEmpty else { return nil }", "replace": "        if false, trimmed.isEmpty { return nil }", "why": "the blank petition ceaseth to be a return: whitespace searcheth as though it were a word, and the journey loseth its root. The blank-and-bounded witness condemneth", "witness": "testTheBlankPetitionIsAReturnAndTheFieldIsBounded"},
    {"id": "T50-SM9-bound-unbounded", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests", "find": "        query = String(value.prefix(ArchiveSearchQuery.maxPhraseChars))", "replace": "        query = String(value.prefix(10000))", "why": "the field gate forgetteth its bounds: a ten-thousand-character petition floweth whole to the engine. The bounds witness condemneth -- the fifty and twelve the engine commandeth", "witness": "testTheBlankPetitionIsAReturnAndTheFieldIsBounded"},
    {"id": "T50-SM10-retry-unearned", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests", "find": "    public func retry() async {\n        guard canRetry else { return }", "replace": "    public func retry() async {\n        if false { return }", "why": "retry is freed of its warrant: the road is ridden again though no failure earned it. The earned-retry witness condemneth -- 'retry only for recoverable errors' is the card's own clause", "witness": "testRetryIsEarnedOnlyWhereTheRoadMayMend"},
    {"id": "T50-SM11-recreation-amnesic", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests", "find": "        handle[\"mode\"] = mode.rawValue", "replace": "        handle[\"mode\"] = ArchiveSceneMode.documents.rawValue", "why": "the recreation handle forgetteth the scene: a journey broken in the document standeth reposed at the root. The recreation witness condemneth -- the place must survive the process", "witness": "testProcessRecreationRestorethTheSameJourney"},
    {"id": "T50-SM12-anchor-amnesic", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests", "find": "        scrollAnchor = ArchiveScrollAnchor(documentId: anchorDocument, passageId: anchorPassage)", "replace": "        scrollAnchor = nil", "why": "the scroll anchor is struck from the recreation: where the reader stood is forgot and the page returneth to the top unbid. The anchor witness condemneth -- preserve scroll is the card word for word", "witness": "testTheScrollAnchorIsNoteAndRemembered"},
    {"id": "T50-SM13-provenance-lied", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveRepository.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests", "find": "                sourceId: columnString(stmt, 2),", "replace": "                sourceId: \"\",", "why": "the enrichment lieth: the frozen source column is overwritten with the empty tale upon the real road. The real-road witness condemneth -- source/revision display must carry the true words", "witness": "testTheRealRoadProjectethProvenanceFromTheFrozenColumns"},
    {"id": "T50-SM14-projection-unbound", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveRepository.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests", "find": "+ \"FROM documents WHERE document_id = ?\"", "replace": "+ \"FROM documents WHERE document_id = ? OR 1 = 1\"", "why": "the provenance projection is unbound from its key: the unheard document answereth with the first row tale. The real-road witness condemneth -- nil must answer the unheard, by the bound parameter sworn", "witness": "testTheRealRoadProjectethProvenanceFromTheFrozenColumns"},
    {"id": "T51-SM1-name-length-cap-loosed", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ReleaseIntake.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT51Tests.swift", "swift_filter": "ReadinessT51Tests", "find": "guard !name.isEmpty, name.count <= maxLength else { return false }", "replace": "guard !name.isEmpty, name.count <= maxLength + 32 else { return false }", "why": "the measure of names is loosened by thirty-two: a sixty-five char petition passeth the gate at the road. The truth table witness condemneth -- the cap is the road's own counsel", "witness": "testTheResourceNameLawKeepethTheRoad"},
    {"id": "T51-SM2-characterset-gate-down", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ReleaseIntake.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT51Tests.swift", "swift_filter": "ReadinessT51Tests", "find": "if name.contains(where: { !allowed.contains($0) }) { return false }", "replace": "if false, name.contains(where: { !allowed.contains($0) }) { return false }", "why": "the characters admitted are no longer consulted: separators and spaces walk in. The truth table witness condemneth -- the NUL sentinel and the first/last and ending tests keep their stations, yet the alphabet gate is down", "witness": "testTheResourceNameLawKeepethTheRoad"},
    {"id": "T51-SM3-first-last-rule-struck", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ReleaseIntake.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT51Tests.swift", "swift_filter": "ReadinessT51Tests", "find": "if first == \".\" || last == \".\" { return false }", "replace": "if false { return false }", "why": "hidden files and dangling dots may enter: the first-character and last-character tests are struck. The truth table witness condemneth -- .hidden.db welcometh where it should be refused", "witness": "testTheResourceNameLawKeepethTheRoad"},
    {"id": "T51-SM4-ending-set-poisoned", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ReleaseIntake.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT51Tests.swift", "swift_filter": "ReadinessT51Tests", "find": "public static let allowedEndings: Set<String> = [\"db\", \"gguf\"]", "replace": "public static let allowedEndings: Set<String> = [\"db\", \"gguf\", \"g5\"]", "why": "the endings admitted are enlarged with a rogue: x.g5 passeth the gate. The truth table witness condemneth -- the register of endings is the road's law", "witness": "testTheResourceNameLawKeepethTheRoad"},
    {"id": "T51-SM5-resolver-guard-slept", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveRepository.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT51Tests.swift", "swift_filter": "ReadinessT51Tests", "find": "guard ArchiveResourceName.isWellFormed(databaseName) else { return nil }", "replace": "let unguarded = databaseName  // (mutant) the guardian slept at his post", "why": "THE GUARDIAN ROW: the name is asked of the bundle and of application-support before any proof. The traversal name walks out of archives/ onto the planted real archive and the road calleth it ready -- the isAvailable flip and the wrong-typed tale together condemn. This is the very escape the guard existeth to prevent", "witness": "testTheResolverRefusethForgeardNamesBeforeTheFilesystem"},
    {"id": "T51-SM6-missing-cry-muzzled", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ReleaseIntake.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT51Tests.swift", "swift_filter": "ReadinessT51Tests", "find": "faults.append(\"missing \\(key): \\(requirement)\")", "replace": "()  // (mutant) the missing-cry is muzzled", "why": "the absent executable is not cried: a bundle without CFBundleExecutable goeth unchallenged to the install. The launchservices witness condemneth -- the card's own negative put on mutation", "witness": "testALaunchServicesRefusethAnUnexecutableBundle"},
    {"id": "T51-SM7-placeholder-veil-rent", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ReleaseIntake.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT51Tests.swift", "swift_filter": "ReadinessT51Tests", "find": "if text.contains(\"$(\") || text.contains(\")\") {", "replace": "if false, text.contains(\"$(\") || text.contains(\")\") {", "why": "the unsubstituted placeholder passeth concealed: $(PRODUCT_NAME) goeth to the device whole. The remnant witness condemneth", "witness": "testPlaceholderRemnantsAreExposed"},
    {"id": "T51-SM8-prefix-rule-asleep", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ReleaseIntake.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT51Tests.swift", "swift_filter": "ReadinessT51Tests", "find": "if !identifier.hasPrefix(\"io.godstone\") {", "replace": "if false, !identifier.hasPrefix(\"io.godstone\") {", "why": "the firm is let go: com.evil.app beareth the bundle abroad under a borrowed name. The identifier witness condemneth -- the prefix is the house's, not the guest's", "witness": "testTheIdentifierMustBearTheFirm"},
    {"id": "T51-SM9-phone-counsel-struck", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ReleaseIntake.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT51Tests.swift", "swift_filter": "ReadinessT51Tests", "find": "if !allowUpsideDown, list.contains(\"UIInterfaceOrientationPortraitUpsideDown\") {", "replace": "if false, list.contains(\"UIInterfaceOrientationPortraitUpsideDown\") {", "why": "the phone may stand on its head: the prohibition is struck, the upside-down listeth unmoved. The counsel witness condemneth -- and the pad's free turning is undisturbed, proof the rod toucheth the phone's own clause", "witness": "testTheOrientationCounselIsKept"},
    {"id": "T51-SM10-schema-gate-wide", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ReleaseIntake.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT51Tests.swift", "swift_filter": "ReadinessT51Tests", "find": "guard receipt.schema == currentSchemaValue else { return nil }", "replace": "guard receipt.schema >= 0 else { return nil }", "why": "the version gate is set at large: a receipt of the second schema entereth as of right. The refusals witness condemneth -- unknown futures are refused, per the migration clause", "witness": "testTheApprovedGateRefusethForeignReceipts"},
    {"id": "T51-SM11-role-binding-loosed", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ReleaseIntake.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT51Tests.swift", "swift_filter": "ReadinessT51Tests", "find": "guard asset.role == \"archive\", asset.name == Tier.light.archiveDatabaseName else { return nil }", "replace": "guard asset.role == \"archive\" || asset.role == \"generation_model\", asset.name == Tier.light.archiveDatabaseName else { return nil }", "why": "the register of roles is betrayed: a generation_model sworn of archive bytes walk in. The refusals witness condemneth -- role and name are bound together by the LIGHT tier's own law", "witness": "testTheApprovedGateRefusethForeignReceipts"},
    {"id": "T51-SM12-hex-alphabet-enlarged", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ReleaseIntake.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT51Tests.swift", "swift_filter": "ReadinessT51Tests", "find": "let hex = Set(\"0123456789abcdef\".unicodeScalars)", "replace": "let hex = Set(\"0123456789abcdefzABCDEF\".unicodeScalars)", "why": "the digest register is enlarged with alien characters: z and E go unsworn through the gate. The refusals witness condemneth -- a SHA must be hex and only hex", "witness": "testTheApprovedGateRefusethForeignReceipts"},
    {"id": "T51-SM13-self-nomination-muzzled", "platform": "python", "file": "scripts/prepare_release_assets.py", "py_dir": "content/tests", "py_pattern": "test_prepare_release_assets.py", "find": "        errors.append(\"the trust store is selected by the operator, never by the manifest\")", "replace": "        pass  # (mutant) the self-nomination check slept", "why": "the bundle is let choose its own signing authority: the archive_trust_store key goeth unchallenged. The self-nomination witness condemneth -- the security clause made executable", "witness": "test_manifest_cannot_select_its_own_trust_root"},
    {"id": "T51-SM14-reverification-slept", "platform": "python", "file": "scripts/prepare_release_assets.py", "py_dir": "content/tests", "py_pattern": "test_prepare_release_assets.py", "find": "        if candidate.stat().st_size != expected_bytes or sha256(candidate) != expected_hash:\n            raise ValueError(\"archive changed during staging\")", "replace": "        if False:\n            raise ValueError(\"archive changed during staging\")", "why": "the re-verification after the copy is neglected: the mutated bytes are received into the destination. The mutation witness condemneth -- validate, stage, re-verify, replace: the law of the order", "witness": "test_source_mutation_during_copy_preserves_existing_output"},
    {"id": "T51-SM15-keyset-equality-struck", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ReleaseIntake.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT51Tests.swift", "swift_filter": "ReadinessT51Tests", "find": "guard Set(top.keys) == Set([\"schema\", \"tier\", \"application_id\", \"generated_by\", \"assets\"]) else { return nil }", "replace": "guard Set(top.keys).count >= 4 else { return nil }", "why": "the key-set equality is struck and a subset count set in its place: surprise goeth through with the rest. The refusals witness condemneth -- exactness is the gate's first word", "witness": "testTheApprovedGateRefusethForeignReceipts"},
    {"id": "T51-SM16-golden-space-inserted", "platform": "swift", "file": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT51Tests.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT51Tests.swift", "swift_filter": "ReadinessT51Tests", "find": "            + \"    - path: b.swift\\n\"", "replace": "            + \"    - path: b.swift \\n\"", "why": "one space is sown into the golden rendering's second path: the byte-pattern of determinism is disturbed by a single blank. The golden witness condemneth -- the same inputs shall ever render the same bytes", "witness": "testTheSourceOnlyRenderingIsDeterministicAndGolden"},
    {"id": "T51-SM17-optional-phantom-restored", "platform": "swift", "file": "ios/project.yml", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT51Tests.swift", "swift_filter": "ReadinessT51Tests", "find": "      - path: Godstone/PrivacyInfo.xcprivacy\n        buildPhase: resources", "replace": "      - path: Godstone/PrivacyInfo.xcprivacy\n        buildPhase : resources\n      - path: Godstone/Resources/Approved/archive_light.db\n        optional: true\n        buildPhase: resources", "why": "THE CARD'S OWN FALSIFIER, executed: the WIP's very entry -- a nonexistent Approved resource sown with optional: true -- is restored to the committed manifest, the build tool honoureth no optionality, the CpResource input is created for an absent path and the clean build faileth; the source-only witness, reading the file it inspecteth, crieth first", "witness": "testTheCommittedProjectManifestIsSourceOnlyUponInspection"},
    {"id": "T52-SM00-empty-census-muzzled", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "    if not artifacts:\n", "replace": "    if False:\n", "why": "the empty build root must fail closed; a muzzled census publisheth a vacuous pass over zero artifacts", "witness": "testNoArtifactsNoVerdictNoPublication"},
    {"id": "T52-SM01-dupe-guard-struck", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "                if dupes:\n", "replace": "                if False:\n", "why": "the duplicate-entry gate is the card's own prohibition; struck, two records of one name ride as one", "witness": "testDuplicateZipEntriesAreRefused"},
    {"id": "T52-SM02-symlink-census-zeroed", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "                report.symlink_entries = sum(1 for info in infos if _entry_is_symlink(info))\n", "replace": "                report.symlink_entries = 0\n", "why": "symlinks in a package are a traversal by another name; zeroing the census blinds the gate", "witness": "testSymlinkEntriesAreRefused"},
    {"id": "T52-SM03-traversal-body-struck", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "    return any(part == \"..\" for part in name.split(\"/\"))\n", "replace": "    return False\n", "why": "the dot-dot component test is the escape catcher; struck, '../escapeMe' walketh free", "witness": "testTraversalNamesAreRefused"},
    {"id": "T52-SM04-mode-guard-asleep", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "                if report.dangerous_modes:\n", "replace": "                if False:\n", "why": "world-writable and setuid entries are the permissions the merged manifest must not grant; the guard sleepeth", "witness": "testWorldWritableEntriesAreRefused"},
    {"id": "T52-SM05-empty-husk-guard-asleep", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "                        if info.file_size == 0:\n", "replace": "                        if False:\n", "why": "an empty packaged Archive is refused by name; asleep, the husk passeth and the probe fallows upon nothing", "witness": "testEmptyHuskIsRefused"},
    {"id": "T52-SM06-tier-gate-wide", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "            if report.tier != \"LIGHT\":\n", "replace": "            if False:\n", "why": "the cross-tier masquerade -- archive_light.db nam\u00e9d, tier MEDIUM swoun -- must be refused; wide, the medium rideth into the light package", "witness": "testTheCrossTierMasqueradeIsRefused"},
    {"id": "T52-SM07-counts-truth-struck", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "            if report.declared_counts[\"documents\"] != str(documents) or \\\n               report.declared_counts[\"chunks\"] != str(chunks):\n", "replace": "            if False:\n", "why": "the counts metadata sweareth; the comparison that catcheth the lie is struck, and nine declared over one actual passeth unchallenged", "witness": "testLyingCountsAreRefused"},
    {"id": "T52-SM08-fts-proof-blinded", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "            report.fts = \"ok\"\n", "replace": "            report.fts = None\n", "why": "the FTS proof is the usability oath of the archive; blinded to None, the report sweareth a false witness of searchability", "witness": "testTheUsableArchiveIsSwornIntoTheReport"},
    {"id": "T52-SM09-unrestorable-muzzled", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "                report.reject(f\"the FTS5 index is unrestorable: {exc}\")\n", "replace": "                pass\n", "why": "an index that cannot be restored must be refused by name; muzzled, the broken index rideth as 'ok'", "witness": "testTheUnrestorableIndexIsRefused"},
    {"id": "T52-SM10-absence-not-claimed", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "                            report.reject(\"the expected Archive is absent from the package\")\n", "replace": "                            pass\n", "why": "the card's own falsifier: remove the archive while keeping the exclusions -- with the presence refusal muzzled the release lane passeth an empty package", "witness": "testPresenceLaneRequirethTheArchive"},
    {"id": "T52-SM11-fixture-prohibition-struck", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "    if strict_lane and report.fixture_marker_found:\n", "replace": "    if False:\n", "why": "a development fixture packaged as production is the named prohibition; struck, the labelled husk ride[h] into the release", "witness": "testTheReleaseLaneProhibitethTheFixturesProse"},
    {"id": "T52-SM12-stale-publication-blind", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "        if approved_sha is not None and expected_sha != approved_sha:\n", "replace": "        if False:\n", "why": "the T51 publication and the staged bytes must agree; blinded, a stale APPROVED_ASSETS.json nameth bytes that are not the shipped ones", "witness": "testTheStalePublicationIsRefusedAtTheGate"},
    {"id": "T52-SM13-schema-gate-wide", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "    if type(data.get(\"schema\")) is not int or data.get(\"schema\") != APPROVED_SCHEMA:\n", "replace": "    if False:\n", "why": "the future schema is the false witness refused at the loader; the gate standeth wide and the twain assets are let pass", "witness": "testTheFutureSchemaAndFalseWitnessesAreRefused"},
    {"id": "T52-SM14-radio-scan-muzzled", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "            if named and named.group(1) in RADIO_GRANTS and 'node=\"remove\"' not in tag:\n", "replace": "            if False:\n", "why": "the merged manifest that granteth INTERNET is the permission the release must not carry; muzzled, the grant passeth the muster", "witness": "testTheMergedManifestGrantScanIsKept"},
    {"id": "T52-SM15-engine-claim-struck", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "                        if not any(BUNDLED_ENGINE_PREFIX in Path(n).name\n                                   for n in report.native_libraries):\n", "replace": "                        if False:\n", "why": "the resolved bundled engine is the road's own furniture; struck, a package without libsqliteJ* rideth unproven", "witness": "testTheRoadRequirethTheBundledEngine"},
    {"id": "T52-SM16-dex-claim-struck", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "                        if report.dex_entries == 0:\n", "replace": "                        if False:\n", "why": "the dex is the code the road runneth; struck, the package carrieth no classes and the gate seeth it not", "witness": "testTheRoadRequirethTheDex"},
    {"id": "T52-SM17-plist-oath-muzzled", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "                        elif b\"CFBundleExecutable\" not in zf.read(plist):\n", "replace": "                        elif False:\n", "why": "the embedded Info.plist that denieth CFBundleExecutable breaketh the T51 covenant; muzzled, the bundle sweareth what it listeth not", "witness": "testTheIpaCarriethExecutablePlistAndArchive"},
    {"id": "T52-SM18-inventory-undetermin\u00e9d", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "        json.dumps(inventories, indent=2, sort_keys=True) + \"\\n\", encoding=\"utf-8\")\n", "replace": "        json.dumps(inventories, indent=2, sort_keys=False) + \"\\n\", encoding=\"utf-8\")\n", "why": "the inventory is the evidence the auditor readeth; unordered, the same bytes give a different tale every time -- and the court's order oath (list of keys == sorted keys at every depth) now seeth the disorder a parse-and-re-dump witness never could", "witness": "testTheArtifactInventoryIsDeterministicInItsRecordStructure"},
    {"id": "T52-SM19-presence-undetermin\u00e9d", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "        json.dumps(presence, indent=2, sort_keys=True) + \"\\n\", encoding=\"utf-8\")\n", "replace": "        json.dumps(presence, indent=2, sort_keys=False) + \"\\n\", encoding=\"utf-8\")\n", "why": "the presence report is the signed evidence; unordered, the auditor's comparison fallieth -- the order oath now trialleth the publication's key sequence itself", "witness": "testThePresenceReportIsDeterministicAndFullyShaped"},
    {"id": "T52-SM20-absence-claimed", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "                            report.status = \"absent\"\n", "replace": "                            report.status = \"byte-matched\"\n", "why": "the card's heart: absences must be REPORTED; made to claim a byte-match over nothing, the exclusion lane prophesieth content it never proved", "witness": "testAbsenceIsReportedNotClaimed"},
    {"id": "T52-SM21-release-guard-asleep", "platform": "python", "file": "scripts/inspect_android_artifacts.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "    if release_candidate and expected_sha is None:\n", "replace": "    if False:\n", "why": "the release lane without an expected truth is the rogue wave caught at the door; asleep, it runneth upon unsworn bytes", "witness": "testTheReleaseLaneRequirethAnExpectedTruth"},
    {"id": "T52-SM22-operator-refusal-muzzled", "platform": "python", "file": "scripts/prepare_release_assets.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "    if trust_store_path is None:\n", "replace": "    if False:   # (mutant) the default path walketh without an operator store\n", "why": "the T51 law on EVERY path: the default release-validation path must REFUSE a bundle-nominated trust store; muzzled, it walketh the removed deputy face's bypass and self-nomination passeth the gate -- the witness condemneth", "witness": "testTheCliDeputyFaceIsGoneAndStillRequirethTheFlagForStaging"},
    {"id": "T52-SM23-dispatch-all-operator", "platform": "python", "file": "scripts/prepare_release_assets.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "    if not args.check_only and args.trust_store is None:\n", "replace": "    if False:   # (mutant) staging walketh without an operator store\n", "why": "staging requireth the operator-selected --trust-store; asleep, a staging run obtaineth the same bypass the default path refuseth -- the witness condemneth (the first form of this rod struck the dead refusal face, which no caller reacheth: a rod over dead code can never be killed, so the face was DELETED and the rod re-anchored on a LIVE guard of the same law)", "witness": "testTheCliDeputyFaceIsGoneAndStillRequirethTheFlagForStaging"},
    {"id": "T52-SM24-deputy-required-guard-struck", "platform": "python", "file": "scripts/prepare_release_assets.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "    if \"archive_trust_store\" in data:\n", "replace": "    if False:   # (mutant) the operator face alloweth a self-nominated trust\n", "why": "the operator face refuseth a document that nominateth its own trust store; struck, the bundle chooseth the key that verifieth it -- the witness condemneth", "witness": "testTheOperatorFaceStillRefusethSelfNomination"},
    {"id": "T52-SM25-gates-alarm-sleepeth", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "    mutate(\"duplicate gate\", lambda value: value[\"gates\"].append(copy.deepcopy(value[\"gates\"][0])))", "replace": "    # (mutant) the duplicate-gate control is stricken from the roll\n", "why": "the roll of twelve is the checker's own contract; strike one control from the roll and the counter, trusting his roll, returneth the false friend's nought while the duplicate cry is never heard -- the subprocess witness heareth the rc and dieth alone", "witness": "testTheGatesCheckerRefusethAllTwelveByName"},
    {"id": "T52-SM26-evidence-shape-widened", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "            if not isinstance(ev, str) or not FULL40.fullmatch(ev) or ev == \"0\" * 40:", "replace": "            if not isinstance(ev, str) or False or ev == \"0\" * 40:", "why": "a CLOSED gate's evidence is a full lowercase hexadecimal commit; widened to any forty bytes, the forged non-hex and upper-case shapes are no more refused -- the twelve originals still refuse by their own constructions, so the in-process oath upon the crafted shapes is the true witness and dieth alone", "witness": "testTheEvidenceShapeIsSwornFullLowercaseHex"},
    {"id": "T52-SM27-wiring-first-blind", "platform": "python", "file": "ci/check_content_release_integration.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "    missing = [item for item in required if item not in text]\n", "replace": "    missing = [item for item in required if item in text]\n", "why": "the builder's three faces are inverted in the census itself: every present face is counted absent, the gate crieth 'not wired' over a truthy file, and the subprocess witness of the counted faces dieth at the first assertion alone", "witness": "testTheIntegrationCheckerCountethItsFacesTruthfully"},
    {"id": "T52-SM28-presence-faces-unseen", "platform": "python", "file": "ci/check_content_release_integration.py", "court": "tools/readiness/tests/test_t52.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t52.py", "find": "    absent = [face for face in presence_faces if face not in body]\n", "replace": "    absent = [face for face in presence_faces if face in body]\n", "why": "the nineteen presence faces are inverted in the census: all are counted lost, the checker refuseth a true inspector, and the counted-faces witness dieth (its rc-assertion first) -- one victim, shared with SM27 by the T51 four-rods-one-witness precedent, each rod killing alone in its field", "witness": "testTheIntegrationCheckerCountethItsFacesTruthfully"},
    {"id": "T53-SM01-unknown-gate-roll-emptied", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "    for name in sorted(set(names) - set(REQUIRED)):\n", "replace": "    for name in sorted(set() - set(REQUIRED)):\n", "why": "the register of required gates is the one roll that refuseth a rogue gate; emptied, the gate 'rogue-gate' ride[s] in unchallenged and the unknown-gate witness, who sweareth the refusal by name, condemns", "witness": "testAnUnknownGateIsRefusedByName"},
    {"id": "T53-SM02-resolver-arm-sleepeth", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "            if not resolve(ev):\n", "replace": "            if False:  # (mutant) the resolver sleepeth, all oaths are whole\n", "why": "the pointer must resolve to a commit in the history; with the resolving arm benumb an unresolvable commit passeth the check (the classification's else arm crieth a different tale), and the stale-evidence witness, who requireth the words 'doth not resolve', condemns", "witness": "testStaleEvidenceDothNotResolve"},
    {"id": "T53-SM03-classification-forged", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "g.setdefault(\"_notes\", {})[\"classification\"] = \"historical\"", "replace": "g.setdefault(\"_notes\", {})[\"classification\"] = \"candidate\"", "why": "the classification is computed by the verdict, not carried from the document; forged to cry 'candidate' over a formal ancestor, the note is believed rather than recomputed and the recomputation witness condemns", "witness": "testTheClassificationIsRecomputed"},
    {"id": "T53-SM04-results-judgement-dead", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "        elif results[\"failed\"] != 0 or results[\"executed\"] <= 0:\n", "replace": "        elif False:\n", "why": "the law UNAVAILABLE is never PASS han: with the judgement of the results dead, zero-run and failed registers are accepted as green; the twin controls of the selftest are double-armed (shape and run id) and keep their refusals, and the never-PASS witness, whose own fixtures are clean ints, condemns alone", "witness": "testUnavailableIsNeverMappedToPass"},
    {"id": "T53-SM05-required-census-asleep", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "    for field in (profile[\"required\"] if profile else COMMON_CLOSED_REQUIREMENTS):", "replace": "    for field in ():", "why": "the profiled closure must bring its whole evidence; with the census of required fields asleep a LIGHT closure may ride without its APK and AAB oaths and the corpus without its digest -- the control that loseth a checksum is double-armed (run id) and keepeth its refusal, and the profile-partition witness, who counteth the 'evidence wanteth' cries, condemns", "witness": "testTheProfilesKeepLightAndCorpusApart"},
    {"id": "T53-SM06-checksum-shape-blind", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "    for sha_field in (\"apk_sha256\", \"aab_sha256\", \"corpus_sha256\"):\n        if sha_field in evidence:\n            value = evidence[sha_field]\n            if not isinstance(value, str) or not SHA256.fullmatch(value):", "replace": "    for sha_field in (\"apk_sha256\", \"aab_sha256\", \"corpus_sha256\"):\n        if sha_field in evidence:\n            value = evidence[sha_field]\n            if not isinstance(value, str) or (False and SHA256.fullmatch(value)):", "why": "the digests must be full lower-case SHA-256; blinded, forty uppercase characters and a truncated oath pass for hex; the control of the truncated checksum is double-armed (executor shape) and keepeth its refusal, and the field-format witness condemns (his upper/truncated arms)", "witness": "testTheEvidenceFieldFormatsAreStrict"},
    {"id": "T53-SM07-byte-tale-tells-lies", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "            if type(value) is not int or isinstance(value, bool) or value <= 0:\n", "replace": "            if False:  # (mutant) the byte tale may tell what it will\n", "why": "the byte counts must be positive integers; struck, '123', -7 and True are told as counts; no control leaneth upon this arm alone, and the field-format witness condemns (his bytes arms)", "witness": "testTheEvidenceFieldFormatsAreStrict"},
    {"id": "T53-SM08-run-id-unpinned", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "        if not isinstance(value, str) or not RUNID.fullmatch(value):\n", "replace": "        if False:  # (mutant) a run id may be any tale of digits\n", "why": "the run identifier is digits; unpinned, '42x' passeth; the substituted control is double-armed (the agreement arm) and keepeth its refusal, and the field-format witness condemns (his run-id arm)", "witness": "testTheEvidenceFieldFormatsAreStrict"},
    {"id": "T53-SM09-agreement-arm-struck", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "        elif isinstance(g.get(\"ci_job\"), str) and value != g[\"ci_job\"]:\n", "replace": "        elif False:  # (mutant) any green may be credited to any job\n", "why": "the evidence's executor must be the very job the gate nameth: a substituted green (another job's name) is a fixture's green; the control of the substituted executor is double-armed (run id '4x') and keepeth its refusal, and the never-PASS witness (his substitution arm) condemns", "witness": "testUnavailableIsNeverMappedToPass"},
    {"id": "T53-SM10-version-gate-wide", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "    if isinstance(version, bool) or type(version) is not int or version not in ACCEPTED_FILE_VERSIONS:\n", "replace": "    if False:  # (mutant) every version is the one version\n", "why": "the document is versioned and unknown futures are refused, not auto-detected; with the gate wide, schema 3, '2' and True are accepted as current law and the version witness condemns", "witness": "testTheFileVersionsAreAcceptedOrRefused"},
    {"id": "T53-SM11-skipped-job-countenanced", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "        if _DISABLED_CONDITION.match(raw):", "replace": "        if _DISABLED_CONDITION.match(raw) and False:", "why": "a job skipped by condition is UNAVAILABLE and may never be mapped to PASS; the selftest's skipped control is double-armed (its block loseth the inspection step too, so the must-hold arm refuseth still) and keepeth ringing, and the skipped-or-missing witness (his skipped arm) condemns", "witness": "testSkippedOrMissingJobMayNotClose"},
    {"id": "T53-SM12-missing-block-unmissed", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "        if not block:\n", "replace": "        if False:  # (mutant) the missing block is not missed\n", "why": "a job missing wholly from the workflow may not close a gate; the selftest's missing control is double-armed (the empty block faileth the must-hold census) and keepeth ringing, and the skipped-or-missing witness, who requireth the cry 'missing from release-gates.yml', condemns (his missing arm)", "witness": "testSkippedOrMissingJobMayNotClose"},
    {"id": "T53-SM13-must-hold-cut-away", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "            for held in (profile or {}).get(\"workflow_must_hold\", ()):", "replace": "            for held in ():", "why": "the profiled job must hold its water-marked wiring (--release for the corpus, the inspector for the archive-only release); cut away, both closures ride clean over amputated blocks; the two selftest controls are double-armed (checksum and run id) and keep their refusals, and the wiring witness condemns", "witness": "testTheProfiledWiringIsNeverCutAway"},
    {"id": "T53-SM14-honest-phrase-folded", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "an {status} gate shall not carry an evidence block \"", "replace": "XXX {status} gate XXXEM carry an evidence block \"", "why": "the record must not belie, and a gate that denieth closure shall not carry the record of one; the refusal still chaungeth, but the witness who readeth the honest phrase 'shall not carry an evidence block' is deafened and condemneth", "witness": "testOpenGatesShallNotCarryEvidence"},
    {"id": "T53-SM15-malformed-door-wide", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "    except (OSError, ValueError) as exc:\n", "replace": "    except () as exc:  # (mutant) the door keepeth no watch at all\n", "why": "malformed JSON and a missing file are both refused at the door with a cried message and exit 1; the handler emptied to the bare empty tuple, both the rotting document and the absent file stele through UNHANDLED: the exit code still falleth to nought, yet the cried message is never spoke, and the door witness, who hearkeneth for the cry, condemns", "witness": "testMalformedJSONIsRefusedAtTheDoor"},
    {"id": "T53-SM16-missing-roll-uncried", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "    for g in sorted(missing):\n        errors.append(f\"missing required gate: {g}\")\n", "replace": "    for g in sorted(missing):\n        pass  # (mutant) the roll goeth unread\n", "why": "every gate that is required must be represented; with the roll of the missing uncried a forgotten gate is mourned silently, and the never-forgotten witness, whose subTests compare the cries by name, condemns", "witness": "testEveryRequiredGateIsNeverForgotten"},
    {"id": "T53-SM17-twins-ride-free", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "        if name in gates:\n            errors.append(f\"duplicate gate: {name}\")\n", "replace": "        if name in gates:\n            pass  # (mutant) the twins ride free\n", "why": "a gate twin of another is stricken from the roll; with the smiting arm benumb the doubled entry passeth unchallenged and the duplicate witness condemns", "witness": "testDuplicateGatesAreStricken"},
    {"id": "T53-SM18-inspector-blinded", "platform": "python", "file": ".github/workflows/release-gates.yml", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "        run: python scripts/inspect_android_artifacts.py android/app/build artifacts/android\n", "replace": "        run: echo inspected by no inspector, the bytes are trusted\n", "why": "the archive-only release job must run the binary inspector over the assembled bytes; the second presence-eyeful invocation of the very inspector is left standing (the live validation and the guarded presence step are insensible to this stroke, which hitteth only the build-inspect step's whole invocation), and the twice-sworn witness condemns", "witness": "testTheWorkflowWiringIsSwornTwice"},
    {"id": "T53-SM19-release-flag-amputated", "platform": "python", "file": ".github/workflows/release-gates.yml", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "            --tier MEDIUM --out dist/archive_medium.db --release \\", "replace": "            --tier MEDIUM --out dist/archive_medium.db \\", "why": "the production corpus job buildeth the MEDIUM archive with --release, the flag that maketh the builder refuse examples and unsealed provenance; amputated (the T53 comment's prose token is not the invocation), the corpus closure would be closed on a permissive build and the twice-sworn witness condemns", "witness": "testTheWorkflowWiringIsSwornTwice"},
    {"id": "T53-SM20-verdict-remediated", "platform": "python", "file": "ci/check_status_consistency.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "EXPECTED_VERDICT = \"PARTIALLY_REMEDIATED_NOT_READY\"", "replace": "EXPECTED_VERDICT = \"PARTIALLY_REMEDIATED_READY\"", "why": "the canonical verdict is PARTIALLY_REMEDIATED_NOT_READY across the machine-readable authorities; turned to READY the keeper dreameth and the harmony witness, who runneth the keeper and requireth the PASS proclamation, condemneth", "witness": "testTheConsistencyKeeperSleepethNot"},
    {"id": "T53-SM21-bytes-to-nought", "platform": "python", "file": "docs/production/RELEASE_GATES_STATUS.json", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "\"apk_bytes\": 2381429", "replace": "\"apk_bytes\": 0", "why": "the real register's sworn APK byte tale is 2,381,429; forged to nought the positive-integer oath is broken and the clean-standing witness, who judgeth the real register with the real resolvers, condemneth (the transcription witness readeth the same field, but the rod is named for the clean-standing witness who runneth alone under the selector)", "witness": "testTheRealRegisterStandethClean"},
    {"id": "T53-SM22-run-id-flag-waters", "platform": "python", "file": "docs/production/RELEASE_GATES_STATUS.json", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "\"run_id\": \"31384944062\"", "replace": "\"run_id\": \"31384944062-x\"", "why": "the run identifier 31384944062 is sworn verbatim from the sealed reason; flagged with '-x' the transcription no longer answereth to the reason's own tale of the run, and the transcription witness condemns (the digits-arm of the clean-standing witness readeth this field too; the rod is named for the transcription witness who runneth alone)", "witness": "testTheByteCountsAreSwornToReason"},
    {"id": "T53-SM23-version-put-back", "platform": "python", "file": "docs/production/RELEASE_GATES_STATUS.json", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "\"schema_version\": 2", "replace": "\"schema_version\": 1", "why": "the authoritative register is versioned at 2, the exact-SHA age; put back to the legacy 1 its structured evidence is read by the old rules alone and the version witness, who requireth the real register's version to be sworn 2, condemneth (the shared arms judge the document by its version, so the legacy path itself answereth still; the rod is named for the version witness, who runneth alone under the selector)", "witness": "testTheFileVersionsAreAcceptedOrRefused"},
    {"id": "T53-SM24-aab-tale-refolded", "platform": "python", "file": "docs/production/RELEASE_GATES_STATUS.json", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "\"aab_bytes\": 4045846", "replace": "\"aab_bytes\": 4045840", "why": "the AAB byte tale is 4,045,846 as the sealed reason itself recordeth; refolded to the first draught's 4,045,840 (a six misread as a zero, the very fault the transcription witness was sown to catch) the equality to the reason's digits failmeth and the witness condemneth; the number remains positive, so the clean-standing witness is not moved", "witness": "testTheByteCountsAreSwornToReason"},
    {"id": "T53-SM25-legacy-veil-lifted", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "                errors.append(f\"{name}: CLOSED requires a full nonzero lowercase evidence_commit SHA\")", "replace": "                pass   # (mutant) a CLOSED gate without a well-formed commit passeth", "why": "the legacy (v1) style is kept byte-identical for the sealed courts' fixtures; with the early veil lifted, an unversioned fixture is judged by the v2 law also: the rogue gate is smitten that the legacy path should have passed in peace, and the byte-identical witness condemns (the twelve sealed controls carry all eight gates and are insensible to this stroke)", "witness": "testTheLegacyPathIsMigratedAndStrictlyRejected"},
    # ------------------------------------------------------- T61 (provenance)
    #
    #   Twenty-three rods upon the model-provenance law in its three isles: the
    #   python authority, the jvm twin and the island twin. Each find-string was
    #   sliced from the live bytes at entry; each replacement is a pure neutering
    #   of one law-clause, assembled so that it standeth not already in the file;
    #   each named witness was proved present in its court ere the row was borne.
    #
    {"id": "T61-PM01-hex64-class-widened", "platform": "python", "file": "scripts/model_provenance.py", "court": "tools/readiness/tests/test_t61.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t61.py", "find": "_HEX64 = re.compile(r\"[0-9a-f]{64}\")", "replace": "_HEX64 = re.compile(r\"[0-9a-f]{1,}\")", "witness": "test_w02b_malformed_digest_length_is_refused_at_the_register_door", "why": "the 64-hex class is grown until any run of hex digits passeth: an ill-lengthed digest, which the register door must refuse, would be swore as though it were a true oath", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-PM02-digest-limb-asleep", "platform": "python", "file": "scripts/model_provenance.py", "court": "tools/readiness/tests/test_t61.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t61.py", "find": "    if digest != artifact.sha256:", "replace": "    if False and (digest != artifact.sha256):", "witness": "test_w09_name_and_length_alone_are_not_trusted", "why": "the digest comparison is put to sleep while the length limb keepeth its watch: a lookalike vessel of the sworn name and the sworn length would be thought true -- the cards own named falsification, that the name and the dimensions be trusted alone", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-PM03-abi-compat-cross-check-asleep", "platform": "python", "file": "scripts/model_provenance.py", "court": "tools/readiness/tests/test_t61.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t61.py", "find": "                _require(art.native_abi in native.abis, ProvenanceError(", "replace": "                _require(True or (art.native_abi in native.abis), ProvenanceError(", "witness": "test_w22_native_abi_must_be_told_by_the_native_tale", "why": "the compatibility cross-check between the artifacts native ABI and the native tales list is asleep: an ABI the tale never told would be admitted, and the register would profess a compatibility it hath not sworn", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-PM04-positive-integer-law-asleep", "platform": "python", "file": "scripts/model_provenance.py", "court": "tools/readiness/tests/test_t61.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t61.py", "find": "    _require(type(value) is int and not isinstance(value, bool) and value > 0,", "replace": "    _require(True or (type(value) is int and not isinstance(value, bool) and value > 0),", "witness": "test_w17_zero_sized_sworn_thing_is_refused", "why": "the positive-integer law over the sworn sizes and contexts is asleep: a zero-sized or zero-context artifact would be swore, and the stock that cannot be measured would personate the measurable", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-PM05-unpinned-null-census-silent", "platform": "python", "file": "scripts/model_provenance.py", "court": "tools/readiness/tests/test_t61.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t61.py", "find": "                sworn_already = [k for k in PROVENANCE_KEYS if blob.get(k) is not None]", "replace": "                sworn_already = []", "witness": "test_w11_half_pinned_register_is_refused", "why": "the census of provenance fields upon an UNPINNED register is muzzled: a half-pinned register -- some oaths sworn, some left null -- would pass for a whole one, which is the very double-dealing the two-estate law forbiddeth", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-PM06-atomic-promotion-forgot", "platform": "python", "file": "scripts/model_provenance.py", "court": "tools/readiness/tests/test_t61.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t61.py", "find": "    os.replace(str(part), str(final))     # atomic promotion", "replace": "    pass  # (the mutint: the atomic promotion is forgot; the part standeth alone)", "witness": "test_w08_repeated_restore_is_determinist_and_leaveth_no_temporary", "why": "the atomic promotion is forgotten: the staged part is never set in its place, so a repeated restore could not be determinist and a temporary would outlive its purpose -- the bounded-temporary law seen through the reuse limb", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-PM07-duplicate-censures-both-asleep", "platform": "python", "file": "scripts/model_provenance.py", "court": "tools/readiness/tests/test_t61.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t61.py", "find": "            _require(label not in seen_ids, ProvenanceError(f\"duplicate artifact id {label!r}\"))\n            output = blob[\"output_file\"]\n            _require(output not in seen_outputs, ProvenanceError(\n                f\"duplicate output_file {output!r} (two ids, one destination is a collision)\"))", "replace": "            _require(True or (label not in seen_ids), ProvenanceError(f\"duplicate artifact id {label!r}\"))\n            output = blob[\"output_file\"]\n            _require(True or (output not in seen_outputs), ProvenanceError(\n                f\"duplicate output_file {output!r} (two ids, one destination is a collision)\"))", "witness": "test_w07b_duplicate_identifier_is_refused", "why": "both duplicate censures -- of identifiers and of destinations -- are asleep together: two artifacts might bear one id, or two ids one destination, and the register would see no fault", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-PM08-destination-census-asleep", "platform": "python", "file": "scripts/model_provenance.py", "court": "tools/readiness/tests/test_t61.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t61.py", "find": "            _require(output not in seen_outputs, ProvenanceError(", "replace": "            _require(True or (output not in seen_outputs), ProvenanceError(", "witness": "test_w05b_duplicate_destination_is_refused", "why": "the destination census alone is asleep: two ids claiming one output_file -- the very collision that turns one writing into another -- would be tolerated", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-PM09-walk-bound-asleep", "platform": "python", "file": "scripts/model_provenance.py", "court": "tools/readiness/tests/test_t61.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t61.py", "find": "        _require(len(buf) - at >= n, ProvenanceError(", "replace": "        _require(True or (len(buf) - at >= n), ProvenanceError(", "witness": "test_w07_truncated_container_is_refused_though_name_and_length_agree", "why": "the header walks bound is asleep: a container truncated amid its tensor infos would be walked to the end and cryèd nothing, though its name and length agree with the oath", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-PM10-legacy-null-digest-law-asleep", "platform": "python", "file": "scripts/model_provenance.py", "court": "tools/readiness/tests/test_t61.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t61.py", "find": "            _require(not sha, ProvenanceError(f\"{b.get('id')}: UNPINNED legacy artifact must keep sha256 null\"))", "replace": "            _require(True or (not sha), ProvenanceError(f\"{b.get('id')}: UNPINNED legacy artifact must keep sha256 null\"))", "witness": "test_w19_legacy_digests_must_stand_null", "why": "the legacy estates null-digest law is asleep: an UNPINNED schema-1 loc would carry a digest as though it were sworn, and the read-only estate would belie the strict one", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-JM01-hex64-class-widened", "platform": "jvm", "file": "android/llm/src/main/java/io/godstone/llm/provenance/ModelLock.kt", "court": "android/llm/src/test/java/io/godstone/llm/readiness/ReadinessT61Test.kt", "gradle_filter": "*ReadinessT61Test*", "module": "llm", "find": "private val HEX64 = Regex(\"[0-9a-f]{64}\")", "replace": "private val HEX64 = Regex(\"[0-9a-f]{1,}\")", "witness": "testShortHexDigestIsRefusedAtTheRegisterDoor", "why": "the twins 64-hex class is grown until any run of hex digits passeth: an ill-lengthed digest at the register door would be swore in the jvm isle too", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-JM02-digest-limb-asleep", "platform": "jvm", "file": "android/llm/src/main/java/io/godstone/llm/provenance/ModelLock.kt", "court": "android/llm/src/test/java/io/godstone/llm/readiness/ReadinessT61Test.kt", "gradle_filter": "*ReadinessT61Test*", "module": "llm", "find": "    if (digest != artifact.sha256) {", "replace": "    if (false && (digest != artifact.sha256)) {", "witness": "testFileNameAndLengthAloneAreNotTrusted", "why": "the twins digest comparison is put to sleep while the length limb keepeth watch: in the jvm isle also the lookalike vessel of sworn name and length would be thought true", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-JM03-abi-compat-cross-check-asleep", "platform": "jvm", "file": "android/llm/src/main/java/io/godstone/llm/provenance/ModelLock.kt", "court": "android/llm/src/test/java/io/godstone/llm/readiness/ReadinessT61Test.kt", "gradle_filter": "*ReadinessT61Test*", "module": "llm", "find": "                swear(art.nativeAbi in nativeLock.abis) {", "replace": "                swear(true || (art.nativeAbi in nativeLock.abis)) {", "witness": "testUnsupportedArchitectureIsRefused", "why": "the twins cross-check between the artifacts ABI and the native tale is asleep: the jvm register would profess a native compatibility it hath not sworn", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-JM04-duplicate-censures-both-asleep", "platform": "jvm", "file": "android/llm/src/main/java/io/godstone/llm/provenance/ModelLock.kt", "court": "android/llm/src/test/java/io/godstone/llm/readiness/ReadinessT61Test.kt", "gradle_filter": "*ReadinessT61Test*", "module": "llm", "find": "            swear(!seenIds.contains(id)) { \"duplicate artifact id '\" + id + \"'\" }\n            seenIds.add(id)\n            val output = blob[\"output_file\"] as? String\n            swear(output != null) { \"'\" + id + \"': wanteth output_file\" }\n            output!!\n            swear(!seenOutputs.contains(output)) { \"duplicate output_file '\" + output + \"' (two ids, one destination is a collision)\" }", "replace": "            swear(true || (!seenIds.contains(id))) { \"duplicate artifact id '\" + id + \"'\" }\n            seenIds.add(id)\n            val output = blob[\"output_file\"] as? String\n            swear(output != null) { \"'\" + id + \"': wanteth output_file\" }\n            output!!\n            swear(true || (!seenOutputs.contains(output))) { \"duplicate output_file '\" + output + \"' (two ids, one destination is a collision)\" }", "witness": "testDuplicateIdentifiersAreRefused", "why": "both twin duplicate censures in the jvm isle are asleep: one id twice, or one destination twice, would pass unnote", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-JM05-walk-bound-asleep", "platform": "jvm", "file": "android/llm/src/main/java/io/godstone/llm/provenance/ModelLock.kt", "court": "android/llm/src/test/java/io/godstone/llm/readiness/ReadinessT61Test.kt", "gradle_filter": "*ReadinessT61Test*", "module": "llm", "find": "        if (data.size - at < n) refuse(\"gguf header truncated: wanteth \" + n + \" byte(s) for \" + what + \", the container holdeth but \" + (data.size - at))", "replace": "        if (false && (data.size - at < n)) refuse(\"gguf header truncated: wanteth \" + n + \" byte(s) for \" + what + \", the container holdeth but \" + (data.size - at))", "witness": "testTruncatedGgufIsRefusedThoughNameAndLengthAgree", "why": "the twin walks bound is asleep in the jvm isle: a truncated container would be walked past its own end, and the header cry would be silent", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-JM06-token-gate-asleep", "platform": "jvm", "file": "android/llm/src/main/java/io/godstone/llm/provenance/ModelStaging.kt", "court": "android/llm/src/test/java/io/godstone/llm/readiness/ReadinessT61Test.kt", "gradle_filter": "*ReadinessT61Test*", "module": "llm", "find": "        if (token != null && token.isCancelled) {", "replace": "        if (false && (token != null && token.isCancelled)) {", "witness": "testTheTokenCeasethForwardingAndTheGateKeepethRecord", "why": "the gate that consulteth the cancellation token sleepeth: after the token is struck the tongue would still be put in motion, and the record would swell with pieces the listener hath renounced -- the state-owners law of one worker and an independent token", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-JM07-atomic-promotion-forgot", "platform": "jvm", "file": "android/llm/src/main/java/io/godstone/llm/provenance/ModelStaging.kt", "court": "android/llm/src/test/java/io/godstone/llm/readiness/ReadinessT61Test.kt", "gradle_filter": "*ReadinessT61Test*", "module": "llm", "find": "            if (!part.renameTo(final)) {", "replace": "            if (false && (!part.renameTo(final))) {", "witness": "testRepeatedRestoreIsDeterministAndLeavethNoTemporary", "why": "the promotion in the jvm isle is forgot (the rename is short-circuited away): the authoritative file would never come to be, and a repeated restore could not be determinist", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-SM01-hex-width-law-widened", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ModelProvenance.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT61Tests.swift", "swift_filter": "ReadinessT61Tests", "find": "private func t61IsHex(_ s: String, _ width: Int) -> Bool {\n    var n = 0\n    for c in s { if !t61In(c, t61HexSet) { return false }; n += 1 }\n    return n == width", "replace": "private func t61IsHex(_ s: String, _ width: Int) -> Bool {\n    var n = 0\n    for c in s { if !t61In(c, t61HexSet) { return false }; n += 1 }\n    return n >= width", "witness": "testW22MalformedDigestLengthIsRefusedAtTheRegisterDoor", "why": "the island twins width law is grown from equal to greater-or-equal: a digest of over-long hex would be swore at the island door as well", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-SM02-digest-limb-asleep", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ModelProvenance.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT61Tests.swift", "swift_filter": "ReadinessT61Tests", "find": "    if digest != artifact.sha256 {", "replace": "    if false && (digest != artifact.sha256) {", "witness": "testW10FileNameAndLengthAloneAreNotTrusted", "why": "the island twins digest limb is asleep: the lookalike vessel would be promoted in the island also, trusting the name and the length alone", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-SM03-abi-compat-cross-check-asleep", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ModelProvenance.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT61Tests.swift", "swift_filter": "ReadinessT61Tests", "find": "                    try t61Swear(native.abis.contains(where: { $0 == art.nativeAbi })) {", "replace": "                    try t61Swear(true || (native.abis.contains(where: { $0 == art.nativeAbi }))) {", "witness": "testW08UnsupportedArchitectureIsRefused", "why": "the islands cross-check of the ABI against the native tale is asleep: the register would tell a compatibility the tale never told", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-SM04-duplicate-censures-both-asleep", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ModelProvenance.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT61Tests.swift", "swift_filter": "ReadinessT61Tests", "find": "            try t61Swear(!seenIds.contains(label)) { \"duplicate artifact id '\" + label + \"'\" }\n            _ = seenIds.insert(label)\n            let output = (blob[\"output_file\"] as? String) ?? \"?\"\n            try t61Swear(!seenOutputs.contains(output)) {", "replace": "            try t61Swear(true || (!seenIds.contains(label))) { \"duplicate artifact id '\" + label + \"'\" }\n            _ = seenIds.insert(label)\n            let output = (blob[\"output_file\"] as? String) ?? \"?\"\n            try t61Swear(true || (!seenOutputs.contains(output))) {", "witness": "testW07DuplicateIdentifiersAreRefused", "why": "both island duplicate censures are asleep: twins in id or twins in destination would ride together through the strict estate unchallenged", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-SM05-header-cry-muted", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ModelProvenance.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT61Tests.swift", "swift_filter": "ReadinessT61Tests", "find": "public func verifyContentAddressed(_ artifact: ContentAddressedArtifact,\n                                    _ data: [UInt8]) -> [String] {\n    var cries: [String] = []\n    let digest = t61ShaHex(data)\n    if digest != artifact.sha256 {\n        cries.append(artifact.outputFile + \": content digest mismatch -- the lock sweareth \" +\n            artifact.sha256 + \", the bytes answer to \" + digest +\n            \" (a file of the same name and length is NOT the sworn content)\")\n    }\n    if data.count != artifact.sizeBytes {\n        cries.append(artifact.outputFile + \": length mismatch -- the lock sweareth \" +\n            t61Num(artifact.sizeBytes) + \" byte(s), the bytes count \" + t61Num(data.count))\n    }\n    do {\n        _ = try ggufWalk(data)\n    } catch let mischief as ProvenanceError {\n        cries.append(artifact.outputFile + \": \" + mischief.message)", "replace": "public func verifyContentAddressed(_ artifact: ContentAddressedArtifact,\n                                    _ data: [UInt8]) -> [String] {\n    var cries: [String] = []\n    let digest = t61ShaHex(data)\n    if digest != artifact.sha256 {\n        cries.append(artifact.outputFile + \": content digest mismatch -- the lock sweareth \" +\n            artifact.sha256 + \", the bytes answer to \" + digest +\n            \" (a file of the same name and length is NOT the sworn content)\")\n    }\n    if data.count != artifact.sizeBytes {\n        cries.append(artifact.outputFile + \": length mismatch -- the lock sweareth \" +\n            t61Num(artifact.sizeBytes) + \" byte(s), the bytes count \" + t61Num(data.count))\n    }\n    do {\n        _ = try ggufWalk(data)\n    } catch let mischief as ProvenanceError {\n        cries.append(artifact.outputFile + \": \" + \"the mutint speaketh not of the header\")", "witness": "testW06TruncatedGgufIsRefusedThoughNameAndLengthAgree", "why": "the header walks cry is muted in the bill of health: the walk itself still refuseth (so nothing crasheth), yet the truncated name of the fault is never told, and the witness that hearkèneth for the word truncated heareth none", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},
    {"id": "T61-SM06-token-gate-asleep", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ModelProvenance.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT61Tests.swift", "swift_filter": "ReadinessT61Tests", "find": "        if let t = token, t.isCancelled { return false }", "replace": "        if let t = token, false { return false }", "witness": "testW14TheTokenCeasethForwardingAndTheGateKeepethRecord", "why": "the island gate that consulteth the token sleepeth: the pieces would go forward after the strike, which the state-owner holds sacred -- one worker, and the token independent of the queue", "baseline": "green (T61 courts: 26 python, 21 jvm, 22 island mirrored)", "kind": "functional"},

    {"id": "T66-PM01-missing-case-censure-asleep", "platform": "python", "file": "content/eval/heldout.py", "court": "tools/readiness/tests/test_t66.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t66.py", "find": "    for case_id in declared:\n        if case_id not in seen:\n            errors.append(f\"case {case_id!r} carrieth no record: a held-out case may \"\n                          f\"never be silently excluded from its own ledger\")\n", "replace": "    for case_id in declared:\n        if False and case_id not in seen:\n            errors.append(f\"case {case_id!r} carrieth no record: a held-out case may \"\n                          f\"never be silently excluded from its own ledger\")\n", "witness": "test_w04_a_struck_case_is_a_completeness_failure", "why": "the censure that a declared case carrieth no record is asleep, so a failed case can be dropped out of the ledger by the harness that was supposed to keep the complete-case census -- the card's named semantic negative in its first limb, 'silently exclude failed cases'", "baseline": "green (T66 courts: 31 python in tools/readiness/tests/test_t66.py, 13 integration in content/tests/test_heldout_staging.py, 69 in the content subsystem)", "kind": "functional"},
    {"id": "T66-PM02-accepted-uncited-numeric-tolerated", "platform": "python", "file": "content/eval/heldout.py", "court": "tools/readiness/tests/test_t66.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t66.py", "find": "        if entry.get(\"answer_accepted\") and (audit.get(\"uncited\")\n                                             or audit.get(\"unsupported\")):\n", "replace": "        if False and (audit.get(\"uncited\") or audit.get(\"unsupported\")):\n", "witness": "test_w05_an_accepted_answer_with_uncited_numbers_faileth_completeness", "why": "the completeness law that refuseth an accepted answer carrying uncited numeric guidance is asleep: the card's named semantic negative, 'allow uncited numeric guidance ... completeness check fails', would no longer fire, and the ledger would call such an answer sound", "baseline": "green (T66 courts: 31 python in tools/readiness/tests/test_t66.py, 13 integration in content/tests/test_heldout_staging.py, 69 in the content subsystem)", "kind": "functional"},
    {"id": "T66-PM03-numeric-provenance-blind", "platform": "python", "file": "content/eval/heldout.py", "court": "tools/readiness/tests/test_t66.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t66.py", "find": "    supported, unsupported = numeric_provenance(answer, list(evidence))", "replace": "    supported, unsupported = True, []", "witness": "test_w01_a_supported_answer_passes_and_an_unsupported_number_is_refused", "why": "the answer audit hearkeneth no longer to the app's own numeric provenance: a number the retrieved evidence never carried (the poisoned shortcut's '10 litres') would be accepted as though the passage swore it", "baseline": "green (T66 courts: 31 python in tools/readiness/tests/test_t66.py, 13 integration in content/tests/test_heldout_staging.py, 69 in the content subsystem)", "kind": "functional"},
    {"id": "T66-PM04-citation-limb-asleep", "platform": "python", "file": "content/eval/heldout.py", "court": "tools/readiness/tests/test_t66.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t66.py", "find": "        if found and not cited:\n            uncited.extend(found)\n", "replace": "        if False and found and not cited:\n            uncited.extend(found)\n", "witness": "test_w31_a_number_without_a_citation_is_refused", "why": "the citation limb is asleep: a number the evidence does carry but no line citeth would pass as sourced, so guidance would travel under a source card it never named", "baseline": "green (T66 courts: 31 python in tools/readiness/tests/test_t66.py, 13 integration in content/tests/test_heldout_staging.py, 69 in the content subsystem)", "kind": "functional"},
    {"id": "T66-PM05-absent-review-as-consent", "platform": "python", "file": "content/eval/heldout.py", "court": "tools/readiness/tests/test_t66.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t66.py", "find": "            review=None if decision is None else decision.verdict,", "replace": "            review=\"accept\" if decision is None else decision.verdict,", "witness": "test_w06_an_absent_review_is_undecided_and_never_an_acceptance", "why": "an absent reviewer decision is counted as an acceptance: the ledger would publish a complete, reviewed evaluation on which no human ever spoke -- the fabrication the card forbids, achieved by defaulting", "baseline": "green (T66 courts: 31 python in tools/readiness/tests/test_t66.py, 13 integration in content/tests/test_heldout_staging.py, 69 in the content subsystem)", "kind": "functional"},
    {"id": "T66-PM06-false-allow-uncounted", "platform": "python", "file": "content/eval/heldout.py", "court": "tools/readiness/tests/test_t66.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t66.py", "find": "    if case.expectation == \"must_refuse\":\n        if allows:\n", "replace": "    if case.expectation == \"must_refuse\":\n        if False and allows:\n", "witness": "test_w02_an_allowed_case_the_manifest_refuses_standeth_a_false_allow", "why": "the false-allow limb is asleep: a case the manifest requireth refused, which the gate alloweth, would be recorded as nothing at all, so the worst finding this harness exists to surface would be invisible", "baseline": "green (T66 courts: 31 python in tools/readiness/tests/test_t66.py, 13 integration in content/tests/test_heldout_staging.py, 69 in the content subsystem)", "kind": "functional"},
    {"id": "T66-PM07-corpus-binding-asleep", "platform": "python", "file": "content/eval/heldout.py", "court": "tools/readiness/tests/test_t66.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t66.py", "find": "    _require(archive_digest == expected,", "replace": "    _require(True or (archive_digest == expected),", "witness": "test_w15_a_manifest_authored_against_another_corpus_is_refused", "why": "the corpus binding is asleep: a manifest authored against one Archive would be reported against another, which is exactly how an evaluation silently acquitteth bytes it never tested", "baseline": "green (T66 courts: 31 python in tools/readiness/tests/test_t66.py, 13 integration in content/tests/test_heldout_staging.py, 69 in the content subsystem)", "kind": "functional"},
    {"id": "T66-PM08-corrupt-lock-door-asleep", "platform": "python", "file": "content/eval/heldout.py", "court": "tools/readiness/tests/test_t66.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t66.py", "find": "        try:\n            lock = authority.ModelLockV1.load(model_lock_path)\n        except authority.ProvenanceError as exc:\n            raise HeldOutError(f\"the model lock is corrupt, so no evaluation may be \"\n                               f\"reported against it: {exc}\") from exc\n        lock_status = lock.status\n        lock_artifacts = len(lock.blobs)\n        _require(lock_status == manifest.model_lock.get(\"status\"),\n                 f\"the model lock standeth {lock_status}, not the \"\n                 f\"{manifest.model_lock.get('status')} this manifest was authored \"\n                 f\"against; re-author the manifest rather than reinterpreting it\")\n", "replace": "        try:\n            lock = authority.ModelLockV1.load(model_lock_path)\n        except authority.ProvenanceError:\n            lock = None\n        lock_status = (manifest.model_lock.get(\"status\") if lock is None\n                       else lock.status)\n        lock_artifacts = 0 if lock is None else len(lock.blobs)\n        _require(True or (lock_status == manifest.model_lock.get(\"status\")),\n                 f\"the model lock standeth {lock_status}, not the \"\n                 f\"{manifest.model_lock.get('status')} this manifest was authored \"\n                 f\"against; re-author the manifest rather than reinterpreting it\")\n", "witness": "test_w16_a_corrupt_model_lock_faileth_the_evaluation", "why": "the corrupt-register door is asleep and the manifest's own declaration is believed instead: an evaluation would be published against a lock the authority refuseth to read, which is the case the card nameth outright -- 'corrupt approval/model lock fails evaluation'", "baseline": "green (T66 courts: 31 python in tools/readiness/tests/test_t66.py, 13 integration in content/tests/test_heldout_staging.py, 69 in the content subsystem)", "kind": "functional"},
    {"id": "T66-PM09-blinding-leaketh-the-family", "platform": "python", "file": "content/eval/heldout.py", "court": "tools/readiness/tests/test_t66.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t66.py", "find": "            \"retrieval\": item.retrieval,\n            \"verdict\": entry[\"verdict\"],\n", "replace": "            \"retrieval\": item.retrieval,\n            \"family\": item.family,\n            \"verdict\": entry[\"verdict\"],\n", "witness": "test_w11_the_packet_withholds_the_family_the_expectation_and_the_category", "why": "the packet telleth the reviewer which adversarial family the case belongeth to: the reviewer would grade the harness's own answer key instead of the behaviour, and the blinding would be scenery", "baseline": "green (T66 courts: 31 python in tools/readiness/tests/test_t66.py, 13 integration in content/tests/test_heldout_staging.py, 69 in the content subsystem)", "kind": "functional"},
    {"id": "T66-PM10-stale-review-door-asleep", "platform": "python", "file": "content/eval/heldout.py", "court": "tools/readiness/tests/test_t66.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t66.py", "find": "    _require(blob.get(\"packet_id\") == packet[\"packet_id\"],", "replace": "    _require(True or (blob.get(\"packet_id\") == packet[\"packet_id\"]),", "witness": "test_w09_a_stale_review_is_refused", "why": "the stale-review door is asleep: a decision recorded against an older packet would be applied to new state, which is the stale event the card's lifecycle clause forbids", "baseline": "green (T66 courts: 31 python in tools/readiness/tests/test_t66.py, 13 integration in content/tests/test_heldout_staging.py, 69 in the content subsystem)", "kind": "functional"},
    {"id": "T66-PM11-duplicate-decision-asleep", "platform": "python", "file": "content/eval/heldout.py", "court": "tools/readiness/tests/test_t66.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t66.py", "find": "        _require(token not in seen,\n                 f\"{where}: case token {token[:12]}... was already decided by this \"\n                 f\"reviewer; duplicate completion is not a second opinion\")\n", "replace": "        _require(True or token not in seen,\n                 f\"{where}: case token {token[:12]}... was already decided by this \"\n                 f\"reviewer; duplicate completion is not a second opinion\")\n", "witness": "test_w08_duplicate_completion_is_refused", "why": "duplicate completion is tolerated: one reviewer's second thought would ride beside their first as though the case had been decided twice", "baseline": "green (T66 courts: 31 python in tools/readiness/tests/test_t66.py, 13 integration in content/tests/test_heldout_staging.py, 69 in the content subsystem)", "kind": "functional"},
    {"id": "T66-PM12-reviewer-pool-door-asleep", "platform": "python", "file": "content/eval/heldout.py", "court": "tools/readiness/tests/test_t66.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t66.py", "find": "    _require(reviewer_token in manifest.review_pool,", "replace": "    _require(True or reviewer_token in manifest.review_pool,", "witness": "test_w30_the_review_pool_is_the_only_door_to_a_packet", "why": "any identity may be issued a packet: the declared review pool would stop being the census of who may judge, and blinding would begin with an unaccounted hand", "baseline": "green (T66 courts: 31 python in tools/readiness/tests/test_t66.py, 13 integration in content/tests/test_heldout_staging.py, 69 in the content subsystem)", "kind": "functional"},
    {"id": "T66-PM13-future-schema-door-asleep", "platform": "python", "file": "content/eval/heldout.py", "court": "tools/readiness/tests/test_t66.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t66.py", "find": "        _require(schema <= MANIFEST_SCHEMA,", "replace": "        _require(True or schema <= MANIFEST_SCHEMA,", "witness": "test_w20_the_manifest_door_refuseth_future_schemas_and_bad_json", "why": "a manifest of a future schema is read partially instead of refused: versioned persisted JSON would silently lose whatever the newer version added", "baseline": "green (T66 courts: 31 python in tools/readiness/tests/test_t66.py, 13 integration in content/tests/test_heldout_staging.py, 69 in the content subsystem)", "kind": "functional"},
    {"id": "T66-PM14-staging-evaluation-findings-discarded", "platform": "python", "file": "scripts/prepare_release_assets.py", "court": "content/tests/test_heldout_staging.py", "py_dir": "content/tests", "py_pattern": "test_heldout_staging.py", "find": "                errors.extend(problems)\n", "replace": "                errors.extend([])\n", "witness": "test_a_false_allow_cannot_reach_the_approved_directory", "why": "the staging gate collecteth the evaluation's refusals and droppeth them: a ledger that reporteth a false allow, or one bound to another corpus, would be staged into the approved directory regardless", "baseline": "green (T66 courts: 31 python in tools/readiness/tests/test_t66.py, 13 integration in content/tests/test_heldout_staging.py, 69 in the content subsystem)", "kind": "functional"},
    {"id": "T66-PM15-published-evaluation-block-dropped", "platform": "python", "file": "scripts/prepare_release_assets.py", "court": "content/tests/test_heldout_staging.py", "py_dir": "content/tests", "py_pattern": "test_heldout_staging.py", "find": "    if evaluation is not None:\n        document[\"evaluation\"] = dict(evaluation)\n", "replace": "    if evaluation is not None:\n        pass\n", "witness": "test_a_complete_evaluation_travels_with_the_staged_archive", "why": "the verified evaluation is no longer transcribed into the published APPROVED_ASSETS.json: a consumer of the staged bytes could not tell which evaluation those bytes carry, and the release record would promise a bond it never published", "baseline": "green (T66 courts: 31 python in tools/readiness/tests/test_t66.py, 13 integration in content/tests/test_heldout_staging.py, 69 in the content subsystem)", "kind": "functional"},
    {"id": "T68-PM01-named-pin-refusals-asleep", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "        for token, why in ((\"://\", \"a direct URL\"), (\"git+\", \"a VCS coordinate\"),\n                           (\"@\", \"a direct URL\"), (\";\", \"an environment marker\"),\n                           (\"[\", \"an extra\"), (\">\", \"a range\"), (\"<\", \"a range\"),\n                           (\"~\", \"a compatible release\"), (\"*\", \"a wildcard\"),\n                           (\" \", \"a stray token\")):\n", "replace": "        for token, why in ():\n", "witness": "test_w01_a_line_that_is_not_an_exact_pin_is_refused", "why": "the refusal of a range, a URL, an extra or a marker is asleep: such a line would fall through to a generic complaint, or in the case of a range pass a door that was supposed to name exactly what it refused", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T68-PM02-closure-digest-cross-check-asleep", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "                if (entry.get(\"resolved_sha256\")\n                        and item.get(\"sha256\") != entry[\"resolved_sha256\"]):\n", "replace": "                if False and (entry.get(\"resolved_sha256\")\n                        and item.get(\"sha256\") != entry[\"resolved_sha256\"]):\n", "witness": "test_w04_a_distribution_that_is_not_pips_digest_is_refused", "why": "the cross-check between a closure entry's blob and the digest pip resolved is asleep: a lock could swear one set of bytes while pip resolved another", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T68-PM03-half-sworn-entry-tolerated", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "            if status == \"PINNED\" and not distributions:\n", "replace": "            if False and status == \"PINNED\" and not distributions:\n", "witness": "test_w05_a_half_sworn_manifest_is_refused", "why": "an entry claiming PINNED with no distribution digest is tolerated: a half-sworn mixture would pass the register door unchallenged", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T68-PM04-pin-resolution-disagreement-tolerated", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "                if entry[\"version\"] != pin:\n", "replace": "                if False and entry[\"version\"] != pin:\n", "witness": "test_w07_a_resolution_that_disagrees_with_the_pin_is_refused", "why": "a resolution disagreeing with the pinned source is accepted: the lock would silently prefer whichever version pip happened to choose", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T68-PM05-hash-invented-for-a-missing-blob", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "                    closure.append({\"name\": name, \"version\": entry[\"version\"],\n                                    \"origin\": origin, \"status\": \"UNPINNED\",\n                                    \"distributions\": [], \"reason\": reason,\n                                    \"resolved_sha256\": entry[\"sha256\"]})\n                    unresolved.append(f\"lane {lane}: {name}=={entry['version']}: \"\n                                      f\"{reason}\")\n                else:\n                    closure.append({\"name\": name, \"version\": entry[\"version\"],\n                                    \"origin\": origin, \"status\": \"PINNED\",\n                                    \"distributions\": [distribution],\n                                    \"resolved_sha256\": entry[\"sha256\"]})", "replace": "                    closure.append({\"name\": name, \"version\": entry[\"version\"],\n                                    \"origin\": origin, \"status\": \"PINNED\",\n                                    \"distributions\": [{\"file\": f\"{name}-{entry['version']}.whl\",\n                                                       \"kind\": \"wheel\", \"bytes\": 1,\n                                                       \"sha256\": entry[\"sha256\"]}],\n                                    \"resolved_sha256\": entry[\"sha256\"]})\n                else:\n                    closure.append({\"name\": name, \"version\": entry[\"version\"],\n                                    \"origin\": origin, \"status\": \"PINNED\",\n                                    \"distributions\": [distribution],\n                                    \"resolved_sha256\": entry[\"sha256\"]})", "witness": "test_w08_a_transitive_package_the_wheelhouse_lacketh_is_recorded_unpinned", "why": "a hash is INVENTED for a distribution the wheelhouse lacketh: pip's resolved digest is written beside a file that is not there, so the lock would swear bytes no restoration can produce", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T68-PM06-resolution-without-digest-tolerated", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "        _require(isinstance(digest, str) and bool(SHA256_RE.fullmatch(digest)),\n", "replace": "        _require(True or (isinstance(digest, str) and bool(SHA256_RE.fullmatch(digest))),\n", "witness": "test_w09_a_resolution_without_a_digest_is_refused", "why": "a resolution entry without a sha256 is tolerated: a resolution without a digest is not a pin, and the lock would carry an unbacked version", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T68-PM07-cache-symlink-tolerated", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "        _require(not path.is_symlink(),\n", "replace": "        _require(True or path.is_symlink(),\n", "witness": "test_w11_a_symlink_or_a_changed_blob_in_the_cache_is_refused", "why": "a symlink in the cache is manifested as though it were bytes: the manifest would swear a digest for a link that can be repointed after the fact", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T68-PM08-restore-writeth-before-it-verify'th", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "    plan = plan_restore(document, source_dir)\n", "replace": "    plan = [dict(entry) for entry in document[\"blobs\"]]\n", "witness": "test_w12_a_refusal_precedeth_every_write", "why": "the restoration skippeth the all-blobs-first verification: a poisoned cache would write its honest members into the destination before refusing", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T68-PM09-secret-scanner-asleep", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "    return [why for pattern, why in SECRET_PATTERNS if pattern.search(text or \"\")]\n", "replace": "    return [why for pattern, why in () if pattern.search(text or \"\")]\n", "witness": "test_w13_the_secret_scanner_refuseth_what_it_claimeth", "why": "the secret scanner replieth nothing at all: a private key or a bearer token would be written into a restoration log that claimeth to have been scanned", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T68-PM10-unpinned-lane-restored-as-pinned", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "        _require(entry.get(\"status\") == \"PINNED\" and entry.get(\"distributions\"),\n", "replace": "        _require(True or (entry.get(\"status\") == \"PINNED\" and entry.get(\"distributions\")),\n", "witness": "test_w14_an_unpinned_lane_cannot_be_restored", "why": "an UNPINNED lane is restored as though it were pinned: a success would be claimed for a lane whose closure nobody swore", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T68-PM11-install-door-believeth-a-changed-wheel", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "            _require(sha256_file(blob) == item[\"sha256\"],\n", "replace": "            _require(True or sha256_file(blob) == item[\"sha256\"],\n", "witness": "test_w15_a_changed_distribution_is_refused_at_the_install_door", "why": "the installation door believeth a cached distribution whose bytes changed: a same-version stranger would be installed under the hash lock's protection -- the card's named semantic negative", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T68-PM12-sbom-may-omit-a-component", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "                if not any(key.startswith(f\"pypi:{name}:\") for key in names):\n", "replace": "                if False and not any(key.startswith(f\"pypi:{name}:\") for key in names):\n", "witness": "test_w17_the_sbom_must_carry_every_component_the_locks_name", "why": "the SBOM may omit a package the dependency lock nameth: the inventory would quietly lose a component, which is exactly how an unattributed dependency reaches a release", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T68-PM13-licence-omission-tolerated", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "        if \"license\" not in entry:\n", "replace": "        if False and \"license\" not in entry:\n", "witness": "test_w17_the_sbom_must_carry_every_component_the_locks_name", "why": "a component with no licence field at all is tolerated: an unknown licence must be RECORDED as unknown, never omitted, or the census counteth a different inventory than the one it describeth", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T68-PM14-measured-mismatch-tolerated", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "        if entry.get(\"status\") == \"MISMATCH\":\n            errors.append(f\"tool {name!r} measureth {entry.get('measured')!r} where the \"\n                          f\"repository pinneth {entry.get('expected')!r}: a measured \"\n                          f\"tool that disagrees with its pin is a refusal, not a note\")\n", "replace": "        if entry.get(\"status\") == \"MISMATCH\":\n            pass\n", "witness": "test_w19_a_measured_tool_that_disagrees_with_its_pin_is_refused", "why": "a tool whose measured version disagrees with the repository's pin is a note rather than a refusal: the lock would record a discrepancy and let the build proceed as though the toolchain were the one that was pinned", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T68-PM15-namespace-blind-metadata-reader", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "    for component in [node for node in root.iter() if local(node, \"component\")]:\n", "replace": "    for component in root.iter(\"component\"):\n", "witness": "test_w21_the_metadata_is_parsed_through_its_namespace", "why": "Gradle's verification metadata is read tag-for-tag without its XML namespace: the reader findeth no component at all and would acquit an unverified dependency graph by silence (this is not hypothetical -- the bug was found by this very witness while the tool was being written)", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T68-PM16-same-version-bytes-tolerated", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "    if actual not in declared:\n", "replace": "    if False and actual not in declared:\n", "witness": "test_w22_a_same_version_artifact_with_different_bytes_is_refused", "why": "a same-version artifact with different bytes is accepted against the verification manifest: the card's named semantic negative, in its maven half", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T68-PM17-unexplained-divergence-tolerated", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "            if not reason or reason.startswith(\"no cause recorded\"):\n", "replace": "            if False:\n", "witness": "test_w23_two_runs_are_compared_by_content", "why": "a divergence with no recorded cause is tolerated: an unexplained difference between two runs would be filed as a note instead of a defect", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T68-PM18-interrupted-write-leaveth-a-partial-document", "platform": "python", "file": "tools/supplychain/supply_chain.py", "court": "tools/readiness/tests/test_t68.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t68.py", "find": "        os.replace(handle.name, path)\n", "replace": "        shutil.copyfile(handle.name, path)\n", "witness": "test_w26_an_interrupted_write_leaveth_the_previous_document", "why": "the document is copied over its predecessor instead of being replaced: a reader could observe a half-written lock, and an interruption would leave the authoritative document destroyed rather than intact", "baseline": "green (T68 court: 26 python in tools/readiness/tests/test_t68.py; the subsystem walketh 246 OK; the reviewed documents verify at rc=0)", "kind": "functional"},
    {"id": "T69-PM01-mesh-token-asleep", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t69.py", "find": "    for name in dylibs:\n        surface = _dylib_link_token(name)\n        if surface:", "replace": "    for name in dylibs:\n        surface = _dylib_link_token(name)\n        if False and surface:", "witness": "test_w10_the_mesh_linked_into_light_is_refused", "why": "the exclusion of a lab surface by its linked library is asleep: GodstoneMesh could be linked into the LIGHT release and the artifact would be called a candidate -- the card's named semantic negative, first limb"},
    {"id": "T69-PM02-resource-exclusions-asleep", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "court": "tools/readiness/tests/test_t69.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t69.py", "find": "        for pattern in FORBIDDEN_RESOURCE_PATTERNS:\n            if pattern.search(name):", "replace": "        for pattern in FORBIDDEN_RESOURCE_PATTERNS:\n            if False and pattern.search(name):", "witness": "test_w09_models_dylibs_and_test_bundles_are_refused_resources", "why": "the resource exclusions are asleep: a model, a dylib, a test bundle or an excluded tier archive would travel inside the release bundle unnoticed", "baseline": "green (T69 court: 26 python in tools/readiness/tests/test_t69.py; the subsystem walketh 272 OK; the real bundle inspecteth at PASS)", "kind": "functional"},
    {"id": "T69-PM03-absent-archive-tolerated", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "court": "tools/readiness/tests/test_t69.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t69.py", "find": "        if expected_digest is not None:\n            failures.append(\"the expected Archive is absent from the package\")", "replace": "        if False and expected_digest is not None:\n            failures.append(\"the expected Archive is absent from the package\")", "witness": "test_w04_an_absent_expected_archive_is_refused", "why": "an absent expected Archive is tolerated: a package that promiseth content and carrieth none would pass the presence law by silence", "baseline": "green (T69 court: 26 python in tools/readiness/tests/test_t69.py; the subsystem walketh 272 OK; the real bundle inspecteth at PASS)", "kind": "functional"},
    {"id": "T69-PM04-mismatched-archive-tolerated", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "court": "tools/readiness/tests/test_t69.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t69.py", "find": "            archive[\"status\"] = \"byte-mismatch\"\n            failures.append(\"the bundled Archive is not the approved Archive: \"\n                            f\"{archive['bundled_sha256']} != {expected_digest}\")", "replace": "            archive[\"status\"] = \"byte-mismatch\"", "witness": "test_w05_a_mismatched_archive_is_refused", "why": "a bundled Archive whose bytes are not the approved bytes is recorded but not refused: the very substitution the approval existeth to catch", "baseline": "green (T69 court: 26 python in tools/readiness/tests/test_t69.py; the subsystem walketh 272 OK; the real bundle inspecteth at PASS)", "kind": "functional"},
    {"id": "T69-PM05-presence-called-a-candidate", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "court": "tools/readiness/tests/test_t69.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t69.py", "find": "    elif archive[\"status\"] == \"byte-matched\" and approved is not None:\n        classification = \"release-candidate-content\"", "replace": "    elif archive[\"status\"] == \"byte-matched\":\n        classification = \"release-candidate-content\"", "witness": "test_w03_an_unapproved_archive_is_present_unverified", "why": "a met presence claim is classified as release-candidate content: a labelled fixture would be reported with the name reserved for approved content", "baseline": "green (T69 court: 26 python in tools/readiness/tests/test_t69.py; the subsystem walketh 272 OK; the real bundle inspecteth at PASS)", "kind": "functional"},
    {"id": "T69-PM06-privacy-may-be-absent", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "court": "tools/readiness/tests/test_t69.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t69.py", "find": "    if not candidates:\n        return {\"present\": False, \"failures\": [", "replace": "    if False and not candidates:\n        return {\"present\": False, \"failures\": [", "witness": "test_w17_the_privacy_manifest_must_be_present", "why": "a bundle without a privacy manifest is tolerated: the release would ship with no declaration of what it accesseth", "baseline": "green (T69 court: 26 python in tools/readiness/tests/test_t69.py; the subsystem walketh 272 OK; the real bundle inspecteth at PASS)", "kind": "functional"},
    {"id": "T69-PM07-tracking-tolerated", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "court": "tools/readiness/tests/test_t69.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t69.py", "find": "    if tracking is not False:", "replace": "    if False and tracking is not False:", "witness": "test_w18_tracking_must_be_false", "why": "a privacy manifest that declareth tracking is tolerated in an Archive-only release that collecteth and sendeth nothing", "baseline": "green (T69 court: 26 python in tools/readiness/tests/test_t69.py; the subsystem walketh 272 OK; the real bundle inspecteth at PASS)", "kind": "functional"},
    {"id": "T69-PM08-reason-code-asleep", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "court": "tools/readiness/tests/test_t69.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t69.py", "find": "        reasons = entry.get(\"NSPrivacyAccessedAPITypeReasons\")\n        if not isinstance(reasons, list) or not reasons:", "replace": "        reasons = entry.get(\"NSPrivacyAccessedAPITypeReasons\")\n        if False and (not isinstance(reasons, list) or not reasons):", "witness": "test_w19_every_accessed_api_carrieth_a_reason", "why": "a declared accessed API without a reason code is tolerated: the declaration would become a list of names with no justification behind it", "baseline": "green (T69 court: 26 python in tools/readiness/tests/test_t69.py; the subsystem walketh 272 OK; the real bundle inspecteth at PASS)", "kind": "functional"},
    {"id": "T69-PM09-collected-data-tolerated", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "court": "tools/readiness/tests/test_t69.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t69.py", "find": "    if collected:\n        failures.append(f\"the release declareth collected data types \"", "replace": "    if False and collected:\n        failures.append(f\"the release declareth collected data types \"", "witness": "test_w20_collected_data_types_are_refused", "why": "a release that declareth collected data types is tolerated: an Archive-only app that collecteth nothing would be allowed to say it collecteth something", "baseline": "green (T69 court: 26 python in tools/readiness/tests/test_t69.py; the subsystem walketh 272 OK; the real bundle inspecteth at PASS)", "kind": "functional"},
    {"id": "T69-PM10-simulator-slice-tolerated", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "court": "tools/readiness/tests/test_t69.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t69.py", "find": "    if simulator:\n        failures.append(f\"the bundle carrieth simulator slice(s) {simulator}: a \"", "replace": "    if False and simulator:\n        failures.append(f\"the bundle carrieth simulator slice(s) {simulator}: a \"", "witness": "test_w12_a_simulator_slice_is_not_a_release_candidate", "why": "a simulator slice inside the bundle is tolerated: a lab artifact would be classified as a device release", "baseline": "green (T69 court: 26 python in tools/readiness/tests/test_t69.py; the subsystem walketh 272 OK; the real bundle inspecteth at PASS)", "kind": "functional"},
    {"id": "T69-PM11-minimum-os-asleep", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "court": "tools/readiness/tests/test_t69.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t69.py", "find": "    if declared_min and declared_min < MINIMUM_OS:", "replace": "    if False and declared_min and declared_min < MINIMUM_OS:", "witness": "test_w13_the_deployment_minimum_is_enforced", "why": "the deployment minimum is not enforced: a bundle built for an older iOS would be reported as installable on the supported floor", "baseline": "green (T69 court: 26 python in tools/readiness/tests/test_t69.py; the subsystem walketh 272 OK; the real bundle inspecteth at PASS)", "kind": "functional"},
    {"id": "T69-PM12-entitlements-emptiness-asleep", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "court": "tools/readiness/tests/test_t69.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t69.py", "find": "        if declared_entitlements:\n            failures.append(\"the release entitlements must be empty for an \"", "replace": "        if False and declared_entitlements:\n            failures.append(\"the release entitlements must be empty for an \"", "witness": "test_w15_the_declared_release_entitlements_must_be_empty", "why": "non-empty release entitlements are tolerated: an Archive-only release could carry capabilities the release surface excludes", "baseline": "green (T69 court: 26 python in tools/readiness/tests/test_t69.py; the subsystem walketh 272 OK; the real bundle inspecteth at PASS)", "kind": "functional"},
    {"id": "T69-PM13-census-symlink-tolerated", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "court": "tools/readiness/tests/test_t69.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t69.py", "find": "        if path.is_symlink():\n            raise ArtifactError(f\"the bundle carrieth a symlink, {path.name}: a link \"", "replace": "        if False and path.is_symlink():\n            raise ArtifactError(f\"the bundle carrieth a symlink, {path.name}: a link \"", "witness": "test_w07_the_census_is_hashed_and_a_symlink_is_refused", "why": "a symlink inside the bundle is tolerated: the census would skip it, and a link can be repointed after the artifact was hashed", "baseline": "green (T69 court: 26 python in tools/readiness/tests/test_t69.py; the subsystem walketh 272 OK; the real bundle inspecteth at PASS)", "kind": "functional"},
    {"id": "T69-PM14-truncated-header-tolerated", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "court": "tools/readiness/tests/test_t69.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t69.py", "find": "    _require(len(data) >= offset + header_size, \"the Mach-O header is truncated\")", "replace": "    _require(True or len(data) >= offset + header_size, \"the Mach-O header is truncated\")", "witness": "test_w23_a_truncated_or_foreign_binary_is_refused", "why": "a truncated Mach-O header is not refused by name: the reader would walk past the end of the file and report on whatever it found there", "baseline": "green (T69 court: 26 python in tools/readiness/tests/test_t69.py; the subsystem walketh 272 OK; the real bundle inspecteth at PASS)", "kind": "functional"},
    {"id": "T69-PM15-ipa-traversal-tolerated", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "court": "tools/readiness/tests/test_t69.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t69.py", "find": "            if name.startswith(\"/\") or \"..\" in Path(name).parts:\n                raise ArtifactError(f\"the IPA carrieth a traversal entry: {name}\")", "replace": "            if False and (name.startswith(\"/\") or \"..\" in Path(name).parts):\n                raise ArtifactError(f\"the IPA carrieth a traversal entry: {name}\")", "witness": "test_w24_an_ipa_must_carrieth_one_clean_app", "why": "a traversal entry in the IPA is tolerated: extraction would write outside the destination it was given", "baseline": "green (T69 court: 26 python in tools/readiness/tests/test_t69.py; the subsystem walketh 272 OK; the real bundle inspecteth at PASS)", "kind": "functional"},
    {"id": "T69-PM16-device-claim-asserted", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "court": "tools/readiness/tests/test_t69.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t69.py", "find": "            \"installed\": \"UNVERIFIED (external: no device in this lane)\"", "replace": "            \"installed\": \"VERIFIED (this lane built it)\"", "witness": "test_w26_the_device_claim_is_unverified_and_the_door_reporteth", "why": "the report CLAIMETH installation it never observed: a source build would be reported as installed, which is the exact confusion this task existeth to prevent", "baseline": "green (T69 court: 26 python in tools/readiness/tests/test_t69.py; the subsystem walketh 272 OK; the real bundle inspecteth at PASS)", "kind": "functional"},
    {"id": "T69-PM17-candidate-claim-tolerated", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "court": "tools/readiness/tests/test_t69.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t69.py", "find": "    if release_candidate and classification != \"release-candidate-content\":", "replace": "    if False and release_candidate and classification != \"release-candidate-content\":", "witness": "test_w25_a_release_candidate_claim_against_a_source_build_is_refused", "why": "a release-candidate claim against a source-only build is tolerated: the claim would be recorded and the artifact published under it", "baseline": "green (T69 court: 26 python in tools/readiness/tests/test_t69.py; the subsystem walketh 272 OK; the real bundle inspecteth at PASS)", "kind": "functional"},
    {"id": "T70-PM01-required-abi-law-asleep", "platform": "python", "file": "scripts/inspect_android_release.py", "court": "tools/readiness/tests/test_t70.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t70.py", "find": "        if required not in abi:\n            failures.append(f\"the APK carrieth no native library for the required ABI \"", "replace": "        if False and required not in abi:\n            failures.append(f\"the APK carrieth no native library for the required ABI \"", "witness": "test_w01_a_missing_abi_is_refused", "why": "the required-ABI law is asleep: an APK with no arm64-v8a native library at all would be published to devices that cannot load it -- the card's named semantic negative", "baseline": "green (T70 court: 18 python in tools/readiness/tests/test_t70.py; the real release APK inspecteth at PASS over four ABIs)", "kind": "functional"},
    {"id": "T70-PM02-per-library-abi-coverage-asleep", "platform": "python", "file": "scripts/inspect_android_release.py", "court": "tools/readiness/tests/test_t70.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t70.py", "find": "        for abi_name in missing:\n            failures.append(f\"the native library {library} is absent from ABI \"", "replace": "        for abi_name in []:\n            failures.append(f\"the native library {library} is absent from ABI \"", "witness": "test_w02_a_library_missing_from_one_abi_is_named", "why": "a library present in one ABI and absent from another is tolerated: half the estate would install and fail at first query", "baseline": "green (T70 court: 18 python in tools/readiness/tests/test_t70.py; the real release APK inspecteth at PASS over four ABIs)", "kind": "functional"},
    {"id": "T70-PM03-aab-coverage-asleep", "platform": "python", "file": "scripts/inspect_android_release.py", "court": "tools/readiness/tests/test_t70.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t70.py", "find": "    if aab is not None:\n        aab = Path(aab)", "replace": "    if aab is not None and aab_abi:\n        for required in REQUIRED_ABIS:", "witness": "test_w03_the_aab_coverage_is_judged_separately", "why": "an AAB with no native library at all is tolerated: the App Bundle is what the store actually delivers, so its coverage mattereth as much as the APK's", "baseline": "green (T70 court: 18 python in tools/readiness/tests/test_t70.py; the real release APK inspecteth at PASS over four ABIs)", "kind": "functional"},
    {"id": "T70-PM04-page-size-law-asleep", "platform": "python", "file": "scripts/inspect_android_release.py", "court": "tools/readiness/tests/test_t70.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t70.py", "find": "            if worst < PAGE_SIZE_16K:\n                failures.append(f\"{abi_name}/{name} is not 16 KiB page compatible: \"", "replace": "            if False and worst < PAGE_SIZE_16K:\n                failures.append(f\"{abi_name}/{name} is not 16 KiB page compatible: \"", "witness": "test_w04_a_four_kib_alignment_is_refused", "why": "the 16 KiB page-size law is asleep: a library whose PT_LOAD segments are 4 KiB-aligned would be shipped to devices that cannot map it", "baseline": "green (T70 court: 18 python in tools/readiness/tests/test_t70.py; the real release APK inspecteth at PASS over four ABIs)", "kind": "functional"},
    {"id": "T70-PM05-forbidden-permission-asleep", "platform": "python", "file": "scripts/inspect_android_release.py", "court": "tools/readiness/tests/test_t70.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t70.py", "find": "        if permission in FORBIDDEN_PERMISSIONS:", "replace": "        if False and permission in FORBIDDEN_PERMISSIONS:", "witness": "test_w07_a_forbidden_permission_is_refused", "why": "a disabled permission in the merged release manifest is tolerated: the release surface would widen without anyone noticing", "baseline": "green (T70 court: 18 python in tools/readiness/tests/test_t70.py; the real release APK inspecteth at PASS over four ABIs)", "kind": "functional"},
    {"id": "T70-PM06-debuggable-tolerated", "platform": "python", "file": "scripts/inspect_android_release.py", "court": "tools/readiness/tests/test_t70.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t70.py", "find": "    if debuggable:\n        failures.append(\"the release manifest setteth android:debuggable=true\")", "replace": "    if False and debuggable:\n        failures.append(\"the release manifest setteth android:debuggable=true\")", "witness": "test_w08_a_debuggable_release_is_refused", "why": "a debuggable release manifest is tolerated: a shipping artifact would carry a debug flag", "baseline": "green (T70 court: 18 python in tools/readiness/tests/test_t70.py; the real release APK inspecteth at PASS over four ABIs)", "kind": "functional"},
    {"id": "T70-PM07-backup-exclusion-asleep", "platform": "python", "file": "scripts/inspect_android_release.py", "court": "tools/readiness/tests/test_t70.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t70.py", "find": "    if allow_backup != \"false\":", "replace": "    if False and allow_backup != \"false\":", "witness": "test_w09_the_backup_surface_must_be_excluded", "why": "the backup exclusion is asleep: an Archive-only release would let the platform copy whatever it found into somebody else's cloud", "baseline": "green (T70 court: 18 python in tools/readiness/tests/test_t70.py; the real release APK inspecteth at PASS over four ABIs)", "kind": "functional"},
    {"id": "T70-PM08-keep-rules-optional", "platform": "python", "file": "scripts/inspect_android_release.py", "court": "tools/readiness/tests/test_t70.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t70.py", "find": "    if not keep_rules:\n        failures.append(\"no -keep rule existeth for the release build: the JNI and \"", "replace": "    if False and not keep_rules:\n        failures.append(\"no -keep rule existeth for the release build: the JNI and \"", "witness": "test_w11_minification_and_its_mapping_are_both_required", "why": "a minified release with no keep rule at all is tolerated: R8 would rename the JNI and reflection surfaces the app reaches for by name", "baseline": "green (T70 court: 18 python in tools/readiness/tests/test_t70.py; the real release APK inspecteth at PASS over four ABIs)", "kind": "functional"},
    {"id": "T70-PM09-mapping-optional", "platform": "python", "file": "scripts/inspect_android_release.py", "court": "tools/readiness/tests/test_t70.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t70.py", "find": "    if minify_declared and not mapping_present:\n        failures.append(\"minification is declared and no mapping.txt was produced: \"", "replace": "    if False and minify_declared and not mapping_present:\n        failures.append(\"minification is declared and no mapping.txt was produced: \"", "witness": "test_w11_minification_and_its_mapping_are_both_required", "why": "a minified build with no mapping is tolerated: there would be no way to read a release crash report back to a method name", "baseline": "green (T70 court: 18 python in tools/readiness/tests/test_t70.py; the real release APK inspecteth at PASS over four ABIs)", "kind": "functional"},
    {"id": "T70-PM10-own-class-stripped-tolerated", "platform": "python", "file": "scripts/inspect_android_release.py", "court": "tools/readiness/tests/test_t70.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t70.py", "find": "    if shipped_missing:\n        failures.append(\"the keep rules name classes of THIS application that the \"", "replace": "    if False and shipped_missing:\n        failures.append(\"the keep rules name classes of THIS application that the \"", "witness": "test_w12_a_keep_rule_that_kept_nothing_of_ours_is_refused", "why": "a keep rule naming one of the application's OWN classes that the dex carrieth not is tolerated: the release-only reflection failure this task existeth to catch would pass unremarked", "baseline": "green (T70 court: 18 python in tools/readiness/tests/test_t70.py; the real release APK inspecteth at PASS over four ABIs)", "kind": "functional"},
    {"id": "T70-PM11-excluded-modules-unrecorded", "platform": "python", "file": "scripts/inspect_android_release.py", "court": "tools/readiness/tests/test_t70.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t70.py", "find": "            excluded_prefixes: Iterable[str] = (\"io.godstone.llm\",\n                                                \"io.godstone.mesh\")) -> dict[str, Any]:", "replace": "            excluded_prefixes: Iterable[str] = ()) -> dict[str, Any]:", "witness": "test_w13_a_rule_for_an_excluded_module_is_recorded_not_refused", "why": "the excluded-module census is emptied: the rules that prove the LIGHT exclusion was deliberate would be reported as inert mysteries instead of as the evidence they are", "baseline": "green (T70 court: 18 python in tools/readiness/tests/test_t70.py; the real release APK inspecteth at PASS over four ABIs)", "kind": "functional"},
    {"id": "T70-PM12-classpath-exclusion-asleep", "platform": "python", "file": "scripts/inspect_android_release.py", "court": "tools/readiness/tests/test_t70.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t70.py", "find": "    failures = [f\"the release runtime classpath carrieth the excluded module \"\n                f\"{coordinate}\" for coordinate in forbidden]", "replace": "    failures = []", "witness": "test_w15_the_classpath_may_not_carry_an_excluded_module", "why": "the release-runtime classpath is not checked for the excluded modules: :llm and :mesh could enter the shipping graph and the report would not say so", "baseline": "green (T70 court: 18 python in tools/readiness/tests/test_t70.py; the real release APK inspecteth at PASS over four ABIs)", "kind": "functional"},
    {"id": "T70-PM13-archive-mismatch-tolerated", "platform": "python", "file": "scripts/inspect_android_release.py", "court": "tools/readiness/tests/test_t70.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t70.py", "find": "        archive[\"status\"] = \"byte-mismatch\"\n        failures.append(\"the packaged Archive is not the approved Archive: \"\n                        f\"{archive['packaged_sha256']} != {expected_digest}\")", "replace": "        archive[\"status\"] = \"byte-mismatch\"", "witness": "test_w16_the_packaged_archive_is_judged_against_its_approval", "why": "a packaged Archive whose bytes are not the approved bytes is recorded but not refused: the substitution the approval existeth to catch", "baseline": "green (T70 court: 18 python in tools/readiness/tests/test_t70.py; the real release APK inspecteth at PASS over four ABIs)", "kind": "functional"},
    {"id": "T70-PM14-device-claim-asserted", "platform": "python", "file": "scripts/inspect_android_release.py", "court": "tools/readiness/tests/test_t70.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t70.py", "find": "            \"installed_min_api26\": \"UNVERIFIED (external: no device in this lane)\"", "replace": "            \"installed_min_api26\": \"VERIFIED on a minAPI26 device\"", "witness": "test_w18_the_device_claims_are_unverified_and_the_doors_report", "why": "the report CLAIMETH an installation it never observed: a build that was never on a device would be reported as installed and queried", "baseline": "green (T70 court: 18 python in tools/readiness/tests/test_t70.py; the real release APK inspecteth at PASS over four ABIs)", "kind": "functional"},
    {"id": "T70-PM15-container-hygiene-asleep", "platform": "python", "file": "scripts/inspect_android_release.py", "court": "tools/readiness/tests/test_t70.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t70.py", "find": "        if name.startswith(\"/\") or \"..\" in Path(name).parts:\n            raise ReleaseArtifactError(f\"{origin} carrieth a traversal entry: {name}\")", "replace": "        if False and (name.startswith(\"/\") or \"..\" in Path(name).parts):\n            raise ReleaseArtifactError(f\"{origin} carrieth a traversal entry: {name}\")", "witness": "test_w17_container_hygiene_and_the_signature_face", "why": "a traversal entry in the container is tolerated: the reader would follow a package's own names wherever they pointed", "baseline": "green (T70 court: 18 python in tools/readiness/tests/test_t70.py; the real release APK inspecteth at PASS over four ABIs)", "kind": "functional"},
    # ----------------------------------------------------------------------
    # T77 (s17): the Archive upgrade, failed-update and rollback recovery.
    #   The card's named semantic negative is PM01/PM02: "Open future schema
    #   and recreate it empty: upgrade/rollback preservation test fails."
    #   Each rod is anchored on the production line it striketh, and each
    #   is witnessed by its OWN named case in tools/readiness/tests/test_t77.py.
    #   The baseline is the T77 court in full: 23 witnesses, all green.
    # ----------------------------------------------------------------------
    {"id": "T77-PM01-future-candidate-recreated-empty", "platform": "python", "file": "scripts/upgrade_recovery.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "        if candidate > self.accepted_schema:\n", "replace": "        if False and candidate > self.accepted_schema:\n", "witness": "test_w17_a_future_schema_is_refused_and_the_estate_is_never_recreated_empty", "why": "the unknown FUTURE candidate schema is no longer refused by name: an archive this build cannot open would be placed over the estate and the preservation test, which requireth the refusal, condemneth -- the card's named semantic negative, first limb", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM02-future-installed-recreated-empty", "platform": "python", "file": "scripts/upgrade_recovery.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "        if installed > self.accepted_schema:\n", "replace": "        if False and installed > self.accepted_schema:\n", "witness": "test_w17_a_future_schema_is_refused_and_the_estate_is_never_recreated_empty", "why": "a FUTURE INSTALLED schema is no longer refused: the estate is treated as a lawful predecessor and a candidate is placed over an archive the build could never have opened; the second limb of the named semantic negative condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM03-downgrade-law-asleep", "platform": "python", "file": "scripts/upgrade_recovery.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "        if candidate < self.accepted_schema:\n", "replace": "        if False and candidate < self.accepted_schema:\n", "witness": "test_w02_the_unsupported_downgrade_is_refused_by_name", "why": "the unsupported DOWNGRADE is no longer refused by name: an older candidate schema would replace the installed estate before any write was refused, and the downgrade witness condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM04-migration-declaration-asleep", "platform": "python", "file": "scripts/upgrade_recovery.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "        if (installed, self.accepted_schema) not in self.migrations:\n", "replace": "        if False and (installed, self.accepted_schema) not in self.migrations:\n", "witness": "test_w03_a_declared_migration_is_applied_and_an_undeclared_one_is_not", "why": "an UNDECLARED migration is applied without its golden fixture: the declaration, which is the only thing that maketh a migration lawful, is never consulted and the migration witness condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM05-retention-never-taken", "platform": "python", "file": "scripts/upgrade_recovery.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "        if boundary == \"validated\" and self.installed.present:\n            self._retain_signed_record()\n", "replace": "        if False and boundary == \"validated\" and self.installed.present:\n            self._retain_signed_record()\n", "witness": "test_w10_the_replacement_is_applied_and_the_previous_pair_is_retained", "why": "the estate's OWN signed record is never retained: a rollback would restore bytes with no authority answering them, the retention is no longer a whole estate, and the retention witness condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM06-rollback-target-law-asleep", "platform": "python", "file": "scripts/upgrade_recovery.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "        if retained not in self.supported_installed:\n", "replace": "        if False and retained not in self.supported_installed:\n", "witness": "test_w12_a_rollback_to_a_schema_the_build_may_not_run_is_refused", "why": "a rollback to a schema this build may not RUN is permitted: the retained estate would be restored whole and the app would be left with an archive it cannot open -- the incompatible-retention witness condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM07-partial-estate-read-as-empty", "platform": "python", "file": "scripts/upgrade_recovery.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "    if len(present) != len(ESTATE_PAIR):\n", "replace": "    if False and len(present) != len(ESTATE_PAIR):\n", "witness": "test_w07_a_partial_estate_is_refused_as_partial_never_as_empty", "why": "a PARTIAL estate is no longer refused: one file of the pair present without the other would ride onward, and storage failure would be confused with missing data -- the partial-estate witness condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM08-absent-bytes-tolerated", "platform": "python", "file": "scripts/upgrade_recovery.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "    if sha256_file(archive_path) != digest or archive_path.stat().st_size != size:\n", "replace": "    if False and (sha256_file(archive_path) != digest or archive_path.stat().st_size != size):\n", "witness": "test_w08_the_published_manifest_must_name_bytes_that_are_present", "why": "the published manifest is believed though the bytes it nameth are not there: a mid-update or mid-wipe estate would read as a healthy one, and the absent-bytes witness condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM09-record-not-placed-with-the-bytes", "platform": "python", "file": "scripts/upgrade_recovery.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "        if boundary == \"published\":\n            self._place_signed_record()\n", "replace": "        if False and boundary == \"published\":\n            self._place_signed_record()\n", "witness": "test_w10_the_replacement_is_applied_and_the_previous_pair_is_retained", "why": "the signed record that answereth the new bytes is never placed: the estate endeth up naming an archive it does not hold, the transaction leaveth no whole estate behind, and the retention witness condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM10-interruption-never-fires", "platform": "python", "file": "scripts/upgrade_recovery.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "        if self.interruption == boundary:\n            raise RecoveryInterrupted(boundary)\n", "replace": "        if False and self.interruption == boundary:\n            raise RecoveryInterrupted(boundary)\n", "witness": "test_w13_an_interruption_after_the_placement_leaveth_the_previous_estate_whole", "why": "a rehearsed interruption never fireth, so the interruption witness, which requireth the boundary to be named and the previous estate to stand whole, condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM11-disk-full-swallowed", "platform": "python", "file": "scripts/upgrade_recovery.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "        if self.disk_fault == boundary:\n", "replace": "        if False and self.disk_fault == boundary:\n", "witness": "test_w16_a_full_disk_is_named_and_the_previous_estate_is_restored", "why": "a full disk no longer falleth at the boundary: the transaction completeth over an unwritable filesystem and the disk witness, which requireth the cause to be named and the previous estate restored, condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM12-crash-mended-by-memory", "platform": "python", "file": "scripts/upgrade_recovery.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "        if not settle_on_fault:\n            # the process DIED at the boundary: nothing mended the estate, and\n            # the recovery is the resumer's to prove from the record alone.\n            raise\n", "replace": "        if not settle_on_fault:\n            pass\n", "witness": "test_w15_a_real_crash_is_resumed_from_the_record_alone", "why": "a crash is mended inline instead of being left to the resumer: the estate never reacheth the inconsistent state the resumer existeth to settle, and the crash-resumption witness condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM13-settle-rolls-back-nothing", "platform": "python", "file": "scripts/upgrade_recovery.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "    if state in (ARCHIVE_REPLACE_INTENT, ARCHIVE_REPLACED, MANIFEST_PUBLISH_INTENT,\n                 MANIFEST_PUBLISHED):\n        # the transaction is complete only when its OWN record sayeth so: a\n        # boundary that fired before COMPLETED is journaled leaveth the\n        # previous authoritative estate standing, whole.\n        _restore_from_retention(estate, retained, trust_store, journal, record_dir)\n", "replace": "    if False:\n        _restore_from_retention(estate, retained, trust_store, journal, record_dir)\n", "witness": "test_w13_an_interruption_after_the_placement_leaveth_the_previous_estate_whole", "why": "the settlement no longer restoreth the previous estate after an interruption mid-transaction: a half-applied pair is left standing and the interruption witness condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM14-wipe-resumption-asleep", "platform": "python", "file": "scripts/upgrade_recovery.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "    if state in WIPE_CHAIN:\n        return wipe(", "replace": "    if False and state in WIPE_CHAIN:\n        return wipe(", "witness": "test_w19_the_wipe_is_journaled_and_a_mid_wipe_estate_resumeth_to_wiped", "why": "a wipe in progress is no longer carried to completion: the resumer falleth through to the update arms, the estate is never wiped, and the wipe witness condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM15-future-journal-auto-detected", "platform": "python", "file": "scripts/upgrade_recovery.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "        if version != JOURNAL_SCHEMA:\n", "replace": "        if False and version != JOURNAL_SCHEMA:\n", "witness": "test_w15_a_real_crash_is_resumed_from_the_record_alone", "why": "a FUTURE journal schema is auto-detected instead of refused: a record written by a later schema would be read as this one and the resumption would act on a tale it cannot understand; the future-journal arm of the crash witness condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM16-device-claim-asserted", "platform": "python", "file": "scripts/upgrade_recovery.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "DEVICE_CLAIM = \"UNVERIFIED (external: no device in this lane)\"", "replace": "DEVICE_CLAIM = \"VERIFIED (this lane built it)\"", "witness": "test_w22_the_report_carrieth_unverified_device_claims_and_is_deterministic", "why": "the report CLAIMETH an installation it never observed: a fixture rehearsal would be reported as a device result -- the exact confusion this task existeth to prevent -- and the claim witness condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM17-rehearsal-labelled-an-approval", "platform": "python", "file": "scripts/upgrade_recovery.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "\"rehearsal\": \"development fixtures only -- NOT an approval, NOT a device result\",", "replace": "\"rehearsal\": \"an approval -- development fixtures proven in this lane\",", "witness": "test_w23_both_doors_speak_for_themselves", "why": "the rehearsal report is relabelled an approval: a fixture ladder would be quotable as a production result, which the whole honesty law forbiddeth; the door witness condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM18-retention-half-pair-tolerated", "platform": "python", "file": "scripts/prepare_release_assets.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "    if present != (True, True):\n", "replace": "    if False and present != (True, True):\n", "witness": "test_w21_the_production_staging_face_carrieth_the_same_transaction", "why": "a HALF pair is retained as though it had been sworn: the retention record would swear bytes that were never whole, and the half-pair arm of the production witness condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM19-retention-inside-the-estate", "platform": "python", "file": "scripts/prepare_release_assets.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "    if retention.resolve() == output.resolve() or retention.resolve().is_relative_to(output.resolve()):\n", "replace": "    if False and (retention.resolve() == output.resolve() or retention.resolve().is_relative_to(output.resolve())):\n", "witness": "test_w21_the_production_staging_face_carrieth_the_same_transaction", "why": "a retention directory may live INSIDE the estate it retaineth: the estate would then carry an unexpected entry, the staging gate would refuse its own output, and the production witness condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    {"id": "T77-PM20-retention-never-taken-by-staging", "platform": "python", "file": "scripts/prepare_release_assets.py", "court": "tools/readiness/tests/test_t77.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t77.py", "find": "    if retention is not None:\n        _retain_previous_estate(output, retention, name)\n", "replace": "    if False and retention is not None:\n        _retain_previous_estate(output, retention, name)\n", "witness": "test_w21_the_production_staging_face_carrieth_the_same_transaction", "why": "the PRODUCTION staging transaction never retaineth the previous authoritative pair: the last-approved bytes would be destroyed by the very replacement they should survive, and the production witness condemneth", "baseline": "green (T77 court: 23 witnesses in tools/readiness/tests/test_t77.py; scripts/upgrade_recovery.py --selftest PASS; the rehearsal door 12 of 12 declared cases agreed)", "kind": "functional"},
    # ----------------------------------------------------------------------
    # T84 (s17): the durable ACK return path through intermediate relays.
    #   The card's named semantic negative is RC1/RC2/RC3 and their iOS twins
    #   RC12/RC14/RC13: "Drop relay UnknownMessage ACK, dedup it against the
    #   MESSAGE ID or retire after local ATT success: three-node delivery
    #   test fails." Each rod striketh one production line and is witnessed by
    #   its OWN named case; the baseline is the T84 courts in full (14 witnesses
    #   on each isle, all green).
    # ----------------------------------------------------------------------
    {"id": "T84-RC1-android-relay-ack-dropped", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/AckDispatcher.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT84Test.kt", "gradle_filter": "*ReadinessT84Test*", "find": "            is DeliveryLookup.NotFound -> Unit  // relay traffic: fall through\n", "replace": "            is DeliveryLookup.NotFound -> return AckDispatch.Refused(\n                AckRefusalReason.MALFORMED_PAYLOAD, \"no local delivery row: dropped\")\n", "witness": "test_w02_the_three_node_receipt_returneth_home_without_a_direct_link", "why": "the card's named falsification, FIRST limb: a relay UnknownMessage ACK is dropped instead of carried. The three-node witness, which requireth B's answer to travel R and reach DELIVERED at A with no A/B link, condemneth", "baseline": "green (T84 courts: 14 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT84Test*; 1050 in the whole :mesh suite) and 14 on the iOS twin (swift test --filter ReadinessT84Tests; 1057 in the whole package suite))", "kind": "functional"},
    {"id": "T84-RC2-android-relay-ack-deduped-against-the-message-id", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/AckDispatcher.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT84Test.kt", "gradle_filter": "*ReadinessT84Test*", "find": "                AckCacheKey.compute(frame.msgId, claimed,\n                    frame.payload.copyOfRange(0, ACK_SIG_LEN))", "replace": "                frame.msgId.copyOf()", "witness": "test_w03_relay_custody_never_entereth_the_message_namespace", "why": "the card's named falsification, SECOND limb: the candidate is deduped against the MESSAGE id. Different signature candidates of one pair would collapse into a single slot, the ack key would BE the message id, and the separate-namespace witness condemneth (his key assertion and his class assertion)", "baseline": "green (T84 courts: 14 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT84Test*; 1050 in the whole :mesh suite) and 14 on the iOS twin (swift test --filter ReadinessT84Tests; 1057 in the whole package suite))", "kind": "functional"},
    {"id": "T84-RC3-android-att-success-retireth-custody", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/AckDispatcher.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT84Test.kt", "gradle_filter": "*ReadinessT84Test*", "find": "    fun onForwardOutcome(copy: AckForwardCopy, peer: ByteArray, accepted: Boolean,\n                         now: Long = clock()) {\n        synchronized(lock) {\n            lastOffer[\"${copy.ackKey.hex()}|${peer.hex()}\"] = now\n        }\n    }", "replace": "    fun onForwardOutcome(copy: AckForwardCopy, peer: ByteArray, accepted: Boolean,\n                         now: Long = clock()) {\n        synchronized(lock) {\n            lastOffer[\"${copy.ackKey.hex()}|${peer.hex()}\"] = now\n            if (accepted) store.expireCandidate(copy.ackKey)\n        }\n    }", "witness": "test_w07_a_local_att_acceptance_never_retireth_custody", "why": "the card's named falsification, THIRD limb: a local ATT acceptance retireth ACK custody. A radio that accepted some bytes would destroy the receipt the relay existeth to carry, and the custody witness condemneth", "baseline": "green (T84 courts: 14 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT84Test*; 1050 in the whole :mesh suite) and 14 on the iOS twin (swift test --filter ReadinessT84Tests; 1057 in the whole package suite))", "kind": "functional"},
    {"id": "T84-RC4-android-forward-copy-taketh-no-decrement", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/AckDispatcher.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT84Test.kt", "gradle_filter": "*ReadinessT84Test*", "find": "            ttl = frame.ttl - 1,\n            hopCount = frame.hopCount + 1,", "replace": "            ttl = frame.ttl,\n            hopCount = frame.hopCount,", "witness": "test_w05_the_forward_copy_taketh_ttl_and_hop_exactly_once", "why": "a forwarded copy no longer decrementeth TTL nor incrementeth hop: the epidemic loop would never terminate, and the TTL/hop witness, which requireth eleven and one, condemneth", "baseline": "green (T84 courts: 14 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT84Test*; 1050 in the whole :mesh suite) and 14 on the iOS twin (swift test --filter ReadinessT84Tests; 1057 in the whole package suite))", "kind": "functional"},
    {"id": "T84-RC5-android-retry-window-open", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/AckDispatcher.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT84Test.kt", "gradle_filter": "*ReadinessT84Test*", "find": "                if (last != null && now - last < ACK_RELAY_RETRY_INTERVAL_MS) {\n                    refuse(AckForwardRefusal.RETRY_WINDOW)\n                    continue\n                }", "replace": "                if (false) {\n                    refuse(AckForwardRefusal.RETRY_WINDOW)\n                    continue\n                }", "witness": "test_w06_the_pump_is_scheduled_bounded_and_rate_limited", "why": "the 30 s retry window is asleep: the same candidate is offered on every turn, and the scheduling witness condemneth (his gated arm, which requireth nought copies inside the window)", "baseline": "green (T84 courts: 14 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT84Test*; 1050 in the whole :mesh suite) and 14 on the iOS twin (swift test --filter ReadinessT84Tests; 1057 in the whole package suite))", "kind": "functional"},
    {"id": "T84-RC6-android-echo-to-receivedfrom", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/AckDispatcher.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT84Test.kt", "gradle_filter": "*ReadinessT84Test*", "find": "                if (from != null && from.contentEquals(peer)) {\n                    refuse(AckForwardRefusal.RECEIVED_FROM_THIS_PEER)\n                    continue\n                }", "replace": "                if (false) {\n                    refuse(AckForwardRefusal.RECEIVED_FROM_THIS_PEER)\n                    continue\n                }", "witness": "test_w04_a_candidate_is_never_echoed_to_receivedFrom", "why": "an ACK is echoed back to the very peer it came from: the return path would bounce instead of travelling onward, and the never-echo witness condemneth", "baseline": "green (T84 courts: 14 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT84Test*; 1050 in the whole :mesh suite) and 14 on the iOS twin (swift test --filter ReadinessT84Tests; 1057 in the whole package suite))", "kind": "functional"},
    {"id": "T84-RC7-android-origin-verification-fabricated", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/AckDispatcher.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT84Test.kt", "gradle_filter": "*ReadinessT84Test*", "find": "                val result = try {\n                    verifyOrigin(frame)\n                } catch (_e: Throwable) {\n                    AckResult.StorageFailure\n                }\n                return AckDispatch.OriginVerification(result)", "replace": "                return AckDispatch.OriginVerification(AckResult.Applied)", "witness": "test_w09_a_forged_candidate_cannot_suppress_a_later_valid_signature", "why": "the origin road is fabricated: every candidate is reported applied without the expected-recipient/trust/CAS verification, so a forged or unintended ACK would claim DELIVERED -- the very confusion this path existeth to prevent. The origin witness condemneth (his rejected-candidate arm)", "baseline": "green (T84 courts: 14 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT84Test*; 1050 in the whole :mesh suite) and 14 on the iOS twin (swift test --filter ReadinessT84Tests; 1057 in the whole package suite))", "kind": "functional"},
    {"id": "T84-RC8-android-storage-failure-read-as-relay", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/AckDispatcher.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT84Test.kt", "gradle_filter": "*ReadinessT84Test*", "find": "            is DeliveryLookup.StorageFailure -> return AckDispatch.Refused(\n                AckRefusalReason.DELIVERY_STATE_UNREADABLE,\n                \"the delivery row for \" + frame.msgId.hex() + \" could not be read\",\n            )", "replace": "            is DeliveryLookup.StorageFailure -> Unit", "witness": "test_w13_malformed_frames_and_a_failed_lookup_are_refused_by_name", "why": "a correctness-critical storage failure is read as 'no row', silently reclassifying the fault as relay traffic (the doctrine forbiddeth a fabricated empty set); the refusal witness condemneth", "baseline": "green (T84 courts: 14 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT84Test*; 1050 in the whole :mesh suite) and 14 on the iOS twin (swift test --filter ReadinessT84Tests; 1057 in the whole package suite))", "kind": "functional"},
    {"id": "T84-RC9-android-canonical-flags-unchecked", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/AckDispatcher.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT84Test.kt", "gradle_filter": "*ReadinessT84Test*", "find": "        if (frame.flags != 0) {\n            // section 14: \"flags remain canonical0\". A non-zero flag would make\n            // this a different frame than the recipient signed.\n            return AckDispatch.Refused(\n                AckRefusalReason.NON_CANONICAL_FLAGS,\n                \"canonical ACK flags must be 0, found ${frame.flags}\",\n            )\n        }", "replace": "        if (false) {\n            return AckDispatch.Refused(AckRefusalReason.NON_CANONICAL_FLAGS, \"unreachable\")\n        }", "witness": "test_w13_malformed_frames_and_a_failed_lookup_are_refused_by_name", "why": "the canonical-flags law is asleep: a frame the recipient never signed (a RELAY_OK-flagged ACK) would be carried, and the refusal witness condemneth", "baseline": "green (T84 courts: 14 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT84Test*; 1050 in the whole :mesh suite) and 14 on the iOS twin (swift test --filter ReadinessT84Tests; 1057 in the whole package suite))", "kind": "functional"},
    {"id": "T84-RC10-android-capacity-refusal-silenced", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/AckDispatcher.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT84Test.kt", "gradle_filter": "*ReadinessT84Test*", "find": "            AckAdmissionResult.RefusedQuotaPair, AckAdmissionResult.RefusedQuotaGlobal ->\n                AckDispatch.Refused(\n                    AckRefusalReason.CANDIDATE_CAPACITY,\n                    \"the relay ACK window is full; new custody is refused explicitly \" +\n                        \"(the original message and the origin verification state are untouched)\",\n                )", "replace": "            AckAdmissionResult.RefusedQuotaPair, AckAdmissionResult.RefusedQuotaGlobal ->\n                AckDispatch.OpaqueRelay(admission)", "witness": "test_w12_candidate_capacity_is_refused_explicitly", "why": "the capacity refusal is silenced: exhausted custody is reported as a carried candidate, so a relay would believe it holdeth receipts it never stored, and the capacity witness condemneth", "baseline": "green (T84 courts: 14 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT84Test*; 1050 in the whole :mesh suite) and 14 on the iOS twin (swift test --filter ReadinessT84Tests; 1057 in the whole package suite))", "kind": "functional"},
    {"id": "T84-RC11-android-debit-may-replenish", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/AckObligationStore.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT84Test.kt", "gradle_filter": "*ReadinessT84Test*", "find": "            if (remainingLifetimeMs >= cur.remainingLifetimeMs) return@synchronized false\n", "replace": "            if (false) return@synchronized false\n", "witness": "test_w10_relay_process_death_and_reconnect_still_returneth_the_receipt", "why": "the non-replenishing guard -- the ONE owner of that law on the in-memory arm, twin of the SQL `remaining > ?` guard -- is asleep: a restart, a duplicate or a clock jump could EXTEND a candidate's life, and the process-death witness condemneth (his replenishment arms)", "baseline": "green (T84 courts: 14 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT84Test*; 1050 in the whole :mesh suite) and 14 on the iOS twin (swift test --filter ReadinessT84Tests; 1057 in the whole package suite))", "kind": "functional"},
    {"id": "T84-RC12-ios-relay-ack-dropped", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/AckDispatcher.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT84Tests.swift", "swift_filter": "ReadinessT84Tests", "find": "        case .notFound:\n            break  // relay traffic: fall through", "replace": "        case .notFound:\n            return .refused(.malformedPayload, \"no local delivery row: dropped\")", "witness": "testW02TheThreeNodeReceiptReturnethHomeWithoutADirectLink", "why": "the card's named falsification, FIRST limb, on the iOS twin: a relay UnknownMessage ACK is dropped instead of carried, and the three-node witness condemneth", "baseline": "green (T84 courts: 14 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT84Test*; 1050 in the whole :mesh suite) and 14 on the iOS twin (swift test --filter ReadinessT84Tests; 1057 in the whole package suite))", "kind": "functional"},
    {"id": "T84-RC13-ios-att-success-retireth-custody", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/AckDispatcher.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT84Tests.swift", "swift_filter": "ReadinessT84Tests", "find": "    func onForwardOutcome(_ copy: AckForwardCopy, peer: Data, accepted: Bool, now: Int? = nil) {\n        let instant = now ?? clock()\n        lock.lock(); defer { lock.unlock() }\n        lastOffer[\"\\(ackHex(copy.ackKey))|\\(ackHex(peer))\"] = instant\n    }", "replace": "    func onForwardOutcome(_ copy: AckForwardCopy, peer: Data, accepted: Bool, now: Int? = nil) {\n        let instant = now ?? clock()\n        lock.lock(); defer { lock.unlock() }\n        lastOffer[\"\\(ackHex(copy.ackKey))|\\(ackHex(peer))\"] = instant\n        if accepted { _ = store.expireCandidate(copy.ackKey) }\n    }", "witness": "testW07ALocalAttAcceptanceNeverRetirethCustody", "why": "the card's named falsification, THIRD limb, on the iOS twin: a local ATT acceptance retireth ACK custody, and the custody witness condemneth", "baseline": "green (T84 courts: 14 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT84Test*; 1050 in the whole :mesh suite) and 14 on the iOS twin (swift test --filter ReadinessT84Tests; 1057 in the whole package suite))", "kind": "functional"},
    {"id": "T84-RC14-ios-relay-ack-deduped-against-the-message-id", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/AckDispatcher.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT84Tests.swift", "swift_filter": "ReadinessT84Tests", "find": "        guard let key = AckCacheKey.compute(msgId: frame.msgId, recipientNodeId: Data(claimed),\n                                           signature: Data(signature)) else {\n            return AckAdmission(result: result, ackKey: nil, verificationClass: nil)\n        }", "replace": "        let key = frame.msgId", "witness": "testW03RelayCustodyNeverEnterethTheMessageNamespace", "why": "the card's named falsification, SECOND limb, on the iOS twin: the candidate is deduped against the MESSAGE id, so the admitted key would BE the message id and different signature candidates of one pair would collapse; the separate-namespace witness condemneth", "baseline": "green (T84 courts: 14 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT84Test*; 1050 in the whole :mesh suite) and 14 on the iOS twin (swift test --filter ReadinessT84Tests; 1057 in the whole package suite))", "kind": "functional"},
    # ----------------------------------------------------------------------
    # T41 (s17): the per-TrustedPeer bounded sync pump and the typed dispatch
    #   statute. The card's named semantic negative is PM01/PM02: "Call send
    #   before persist or leave scheduler unregistered: real MeshNode path test
    #   fails." Each rod striketh one production line and is witnessed by its OWN
    #   named case; the baseline is the T41 court in full (14 witnesses, green).
    # ----------------------------------------------------------------------
    {"id": "T41-PM01-android-send-before-persist", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt", "gradle_filter": "*ReadinessT41Test*", "find": "            if (relay) pumpFor().enqueueForward(frame, fromPeer)\n", "replace": "            pumpFor().enqueueForward(frame, fromPeer)\n", "witness": "test_w03_a_refused_persist_forwards_nothing", "why": "the card's named falsification, FIRST limb: the forward is queued whether or not the store accepted the frame, so a send precedeth its persist and a peer would relay bytes this node never durably held. The refused-persist witness condemneth", "baseline": "green (T41 court: 14 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt; the whole :mesh suite standeth green beside it)", "kind": "functional"},
    {"id": "T41-PM02-android-scheduler-unregistered", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt", "gradle_filter": "*ReadinessT41Test*", "find": "            is PeerEvent.Found -> pumpFor().register(event.peerId)\n", "replace": "            is PeerEvent.Found -> Unit\n", "witness": "test_w01_a_present_peer_gets_a_registered_scheduler", "why": "the card's named falsification, SECOND limb: a peer that became present registereth no relation, so nothing is ever scheduled and its held set never reconciles. The registration witness condemneth", "baseline": "green (T41 court: 14 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt; the whole :mesh suite standeth green beside it)", "kind": "functional"},
    {"id": "T41-PM03-android-forward-copy-not-decremented", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/router/SyncPump.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt", "gradle_filter": "*ReadinessT41Test*", "find": "        val copy = ForwardCopy(router.forwardCopy(frame), fromPeer?.copyOf())\n", "replace": "        val copy = ForwardCopy(frame, fromPeer?.copyOf())\n", "witness": "test_w02_the_three_node_path_forwards_after_durable_acceptance", "why": "a forwarded copy is not decremented or incremented: the epidemic would never terminate, and the three-node witness, which requireth eleven and one, condemneth", "baseline": "green (T41 court: 14 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt; the whole :mesh suite standeth green beside it)", "kind": "functional"},
    {"id": "T41-PM04-android-echo-to-receivedfrom", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/router/SyncPump.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt", "gradle_filter": "*ReadinessT41Test*", "find": "                if (fromPeer != null && rel.peerNodeId.contentEquals(fromPeer)) continue   // never echo\n", "replace": "                if (false) continue   // (mutant) the never-echo law is asleep\n", "witness": "test_w02_the_three_node_path_forwards_after_durable_acceptance", "why": "a frame is echoed back to the very hop it arrived from, and the witness requireth that the origin's peer queued NOTHING", "baseline": "green (T41 court: 14 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt; the whole :mesh suite standeth green beside it)", "kind": "functional"},
    {"id": "T41-PM05-android-ttl-exhaustion-unchecked", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/router/SyncPump.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt", "gradle_filter": "*ReadinessT41Test*", "find": "        if (frame.ttl <= 1) return ForwardOffer.Refused(SyncRefusal.TTL_EXHAUSTED)\n", "replace": "        if (false) return ForwardOffer.Refused(SyncRefusal.TTL_EXHAUSTED)\n", "witness": "test_w05_ttl_exhaustion_and_the_hop_ceiling_refuse_by_name", "why": "a local frame (TTL 0 or 1) is offered for forwarding: a link-local frame would travel the mesh, and the TTL witness condemneth", "baseline": "green (T41 court: 14 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt; the whole :mesh suite standeth green beside it)", "kind": "functional"},
    {"id": "T41-PM06-android-priority-order-asleep", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/router/SyncPump.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt", "gradle_filter": "*ReadinessT41Test*", "find": "                insertByPriority(queue, copy)\n", "replace": "                queue.addLast(copy)\n", "witness": "test_w12_the_forward_leg_is_strictly_priority_ordered", "why": "the strict priority order is asleep: the forward leg becometh pure FIFO, so a BULK frame can precede an SOS, and the priority witness condemneth", "baseline": "green (T41 court: 14 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt; the whole :mesh suite standeth green beside it)", "kind": "functional"},
    {"id": "T41-PM07-android-queue-bound-removed", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/router/SyncPump.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt", "gradle_filter": "*ReadinessT41Test*", "find": "                while (queue.size >= SYNC_MAX_FORWARD_QUEUE) {\n", "replace": "                while (false) {\n", "witness": "test_w13_the_forward_queue_is_bounded", "why": "the forward queue is unbounded: a flood groweth the pump's memory without limit, and the bounded-queue witness condemneth", "baseline": "green (T41 court: 14 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt; the whole :mesh suite standeth green beside it)", "kind": "functional"},
    {"id": "T41-PM08-android-turn-bound-removed", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/router/SyncPump.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt", "gradle_filter": "*ReadinessT41Test*", "find": "            while (queue.isNotEmpty() && out.size < SYNC_MAX_FORWARD_PER_TURN) {\n", "replace": "            while (queue.isNotEmpty() && out.size < Int.MAX_VALUE) {\n", "witness": "test_w13_the_forward_queue_is_bounded", "why": "a single turn is unbounded: one peer would drain the whole queue and starve the others, and the bounded-turn witness condemneth", "baseline": "green (T41 court: 14 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt; the whole :mesh suite standeth green beside it)", "kind": "functional"},
    {"id": "T41-PM09-android-digest-never-scheduled", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/router/SyncPump.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt", "gradle_filter": "*ReadinessT41Test*", "find": "        if (digestDue) {\n            val built = owner.buildDigestFrame()\n", "replace": "        if (false) {\n            val built = owner.buildDigestFrame()\n", "witness": "test_w01_a_present_peer_gets_a_registered_scheduler", "why": "the DIGEST is never scheduled, so no peer can ever open a run against our held set: reconciliation dieth at the first encounter, and the registration witness condemneth", "baseline": "green (T41 court: 14 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt; the whole :mesh suite standeth green beside it)", "kind": "functional"},
    {"id": "T41-PM10-android-cancel-leaveth-the-queue", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/router/SyncPump.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt", "gradle_filter": "*ReadinessT41Test*", "find": "            forwardQueues.remove(key)\n", "replace": "            // (mutant) the queue of a lost relation surviveth\n", "witness": "test_w06_relation_loss_cancels_the_schedule_and_the_estate_survives", "why": "a cancelled relation keepeth its pending forward queue: the resources of an operation that ended are held against a relation that no longer existeth, and the relation-loss witness condemneth", "baseline": "green (T41 court: 14 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt; the whole :mesh suite standeth green beside it)", "kind": "functional"},
    {"id": "T41-PM11-android-control-shepherd-sleepeth", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/router/FrameDispatcher.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt", "gradle_filter": "*ReadinessT41Test*", "find": "            TypeV2.PING, TypeV2.HELLO, TypeV2.DIGEST, TypeV2.WANT -> {\n", "replace": "            TypeV2.HELLO, TypeV2.DIGEST, TypeV2.WANT -> {\n", "witness": "test_w11_the_typed_dispatcher_routeth_in_the_statute_order", "why": "the control shepherd letteth PING fall out of the control arm: a link control would be refused (or, in another shape, reach the message road), and the dispatch-statute witness condemneth", "baseline": "green (T41 court: 14 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt; the whole :mesh suite standeth green beside it)", "kind": "functional"},
    {"id": "T41-PM12-android-unsupported-type-reaches-the-road", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/router/FrameDispatcher.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt", "gradle_filter": "*ReadinessT41Test*", "find": "            else -> return DispatchVerdict.Refused(\n                DispatchRefusal.UNSUPPORTED_TYPE,\n                \"the bulk pair, GOODBYE and anything unknown are refused in this profile \" +\n                    \"(section 14 dispatch statute); nothing is stored, nothing is relayed, \" +\n                    \"no trust is moved: ${frame.type}\",\n            )\n", "replace": "            else -> return DispatchVerdict.Message\n", "witness": "test_w11_the_typed_dispatcher_routeth_in_the_statute_order", "why": "an unsupported type (the bulk pair, GOODBYE, anything unknown) reacheth the durable message road instead of being refused by name: the statute witness condemneth (his GOODBYE arm, which requireth a refusal AND an empty store)", "baseline": "green (T41 court: 14 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt; the whole :mesh suite standeth green beside it)", "kind": "functional"},
    # ----------------------------------------------------------------------
    # T42 (s17): the iOS durable anti-entropy and forwarding wiring, the twin of
    #   T41. The card's NAMED semantic negative is RC1: "Persist optional/try?
    #   then report accepted: store-failure integration test fails." Each rod
    #   striketh one production line and is witnessed by its OWN named case; the
    #   baseline is the T42 court in full (16 witnesses, green) with the whole
    #   Swift package green beside it.
    # ----------------------------------------------------------------------
    {"id": "T42-RC1-ios-store-failure-reported-accepted", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/Router.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift", "swift_filter": "ReadinessT42Tests", "find": "        case .rejectedCapacity, .failedStorage:\n            return none", "replace": "        case .rejectedCapacity, .failedStorage:\n            seen.insert(frame.msgId)   // (mutant) a failed persist is reported accepted", "witness": "testW03ARefusedPersistForwardsNothingAndReportsNothing", "why": "the card's NAMED semantic negative: a persist that FAILED is reported accepted -- the memory-only success restored. The store-failure trace, which requireth a refusal, no held row, no queued copy and no send, condemneth (and W04's memory-only arms with it)", "baseline": "green (T42 court: 16 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift; the whole GodstoneFoundation package standeth at 1073 tests, 0 failures, beside it)", "kind": "functional"},
    {"id": "T42-RC2-ios-send-before-persist", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshNode.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift", "swift_filter": "ReadinessT42Tests", "find": "        if relay { _ = pumpFor().enqueueForward(frame, fromPeer: receivedFrom) }", "replace": "        _ = pumpFor().enqueueForward(frame, fromPeer: receivedFrom)", "witness": "testW03ARefusedPersistForwardsNothingAndReportsNothing", "why": "the forward is queued whether or not the store accepted the frame: a send precedeth its persist, and the store-failure trace condemneth", "baseline": "green (T42 court: 16 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift; the whole GodstoneFoundation package standeth at 1073 tests, 0 failures, beside it)", "kind": "functional"},
    {"id": "T42-RC3-ios-scheduler-unregistered", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshNode.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift", "swift_filter": "ReadinessT42Tests", "find": "        return pumpFor().register(nodeId)\n    }", "replace": "        false   // (mutant) a trusted relation registereth no scheduler\n    }", "witness": "testW01ATrustedPeerGetsARegisteredScheduler", "why": "a trusted peer that came up registereth no relation: nothing is ever scheduled and its held set never reconciles; the registration witness condemneth", "baseline": "green (T42 court: 16 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift; the whole GodstoneFoundation package standeth at 1073 tests, 0 failures, beside it)", "kind": "functional"},
    {"id": "T42-RC4-ios-digest-never-scheduled", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/SyncPump.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift", "swift_filter": "ReadinessT42Tests", "find": "        if digestDue, let built = owner.buildDigestFrame() {", "replace": "        if false, let built = owner.buildDigestFrame() {", "witness": "testW01ATrustedPeerGetsARegisteredScheduler", "why": "the DIGEST is never scheduled, so no peer can open a run against our held set; the registration witness (his digest arms) and the convergence witness condemn", "baseline": "green (T42 court: 16 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift; the whole GodstoneFoundation package standeth at 1073 tests, 0 failures, beside it)", "kind": "functional"},
    {"id": "T42-RC5-ios-forward-copy-not-decremented", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/SyncPump.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift", "swift_filter": "ReadinessT42Tests", "find": "        guard let forwarded = router.forwardCopy(frame) else { return .refused(.hopLimit) }", "replace": "        guard let forwarded = Optional(frame) else { return .refused(.hopLimit) }", "witness": "testW02TheThreeNodeTraceForwardsAfterDurableAcceptance", "why": "a forwarded copy is not decremented or incremented: the epidemic would never terminate, and the three-node trace, which requireth eleven and one, condemneth", "baseline": "green (T42 court: 16 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift; the whole GodstoneFoundation package standeth at 1073 tests, 0 failures, beside it)", "kind": "functional"},
    {"id": "T42-RC6-ios-echo-to-receivedfrom", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/SyncPump.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift", "swift_filter": "ReadinessT42Tests", "find": "            if let from = fromPeer, rel.peerNodeId == from { continue }   // never echo", "replace": "            if false { continue }   // (mutant) the never-echo law is asleep", "witness": "testW02TheThreeNodeTraceForwardsAfterDurableAcceptance", "why": "a frame is echoed back to the very hop it arrived from, and the three-node trace requireth that A's peer queued NOTHING; the witness condemneth", "baseline": "green (T42 court: 16 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift; the whole GodstoneFoundation package standeth at 1073 tests, 0 failures, beside it)", "kind": "functional"},
    {"id": "T42-RC7-ios-ttl-exhaustion-unchecked", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/SyncPump.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift", "swift_filter": "ReadinessT42Tests", "find": "        if frame.ttl <= 1 { return .refused(.ttlExhausted) }", "replace": "        if false { return .refused(.ttlExhausted) }", "witness": "testW08TtlExhaustionAndTheHopCeilingRefuseByName", "why": "a local frame (TTL 0 or 1) is offered for forwarding: a link-local frame would travel the mesh; the TTL witness condemneth", "baseline": "green (T42 court: 16 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift; the whole GodstoneFoundation package standeth at 1073 tests, 0 failures, beside it)", "kind": "functional"},
    {"id": "T42-RC8-ios-priority-order-asleep", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/SyncPump.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift", "swift_filter": "ReadinessT42Tests", "find": "            insertByPriority(&queue, copy)", "replace": "            queue.append(copy)", "witness": "testW10TheForwardLegIsStrictlyPriorityOrdered", "why": "the strict priority order is asleep: the forward leg becometh pure FIFO, so a BULK frame can precede an SOS, and the priority witness condemneth", "baseline": "green (T42 court: 16 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift; the whole GodstoneFoundation package standeth at 1073 tests, 0 failures, beside it)", "kind": "functional"},
    {"id": "T42-RC9-ios-canonical-bits-replaced-by-a-type-table", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/Router.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift", "swift_filter": "ReadinessT42Tests", "find": "        Priority.fromFlags(f.flags).rawValue\n    }", "replace": "        switch f.type {\n        case .sos: return 0\n        default: return 1\n        }\n    }", "witness": "testW10TheForwardLegIsStrictlyPriorityOrdered", "why": "the canonical priority bits are replaced by a TYPE table: a GROUP and a BULK message sort alike and the relay queue loseth its order; the witness (his router-queue arm) condemneth", "baseline": "green (T42 court: 16 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift; the whole GodstoneFoundation package standeth at 1073 tests, 0 failures, beside it)", "kind": "functional"},
    {"id": "T42-RC10-ios-queue-bound-removed", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/SyncPump.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift", "swift_filter": "ReadinessT42Tests", "find": "            while queue.count >= syncMaxForwardQueue {", "replace": "            while false {", "witness": "testW11TheForwardQueueAndTheTurnAreBounded", "why": "the forward queue is unbounded: a flood groweth the pump's memory without limit; the bounded-queue witness condemneth", "baseline": "green (T42 court: 16 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift; the whole GodstoneFoundation package standeth at 1073 tests, 0 failures, beside it)", "kind": "functional"},
    {"id": "T42-RC11-ios-unsupported-type-reaches-the-road", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/FrameDispatcher.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift", "swift_filter": "ReadinessT42Tests", "find": "        default:\n            return .refused(.unsupportedType,\n                            \"the bulk pair, GOODBYE and anything unknown are refused in this \" +\n                            \"profile (section 14 dispatch statute); nothing is stored, nothing \" +\n                            \"is relayed, no trust is moved: \\(frame.type)\")\n", "replace": "        default:\n            return .message\n", "witness": "testW12TheTypedDispatcherRoutethInTheStatuteOrder", "why": "the unsupported-type refusal is silenced: the bulk pair reaches the durable message road instead of being refused by name; the statute witness condemneth", "baseline": "green (T42 court: 16 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift; the whole GodstoneFoundation package standeth at 1073 tests, 0 failures, beside it)", "kind": "functional"},
    {"id": "T42-RC12-ios-control-shepherd-sleepeth", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/FrameDispatcher.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift", "swift_filter": "ReadinessT42Tests", "find": "        case .ping, .hello, .digest, .want:", "replace": "        case .hello, .digest, .want:", "witness": "testW12TheTypedDispatcherRoutethInTheStatuteOrder", "why": "the control shepherd letteth PING fall out of the control arm: a link control would be refused rather than owned by the relation; the statute witness condemneth", "baseline": "green (T42 court: 16 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift; the whole GodstoneFoundation package standeth at 1073 tests, 0 failures, beside it)", "kind": "functional"},
    {"id": "T42-RC13-ios-bloom-hint-ignored", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/Router.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift", "swift_filter": "ReadinessT42Tests", "find": "            if !peerDigest.mightContain(frame.msgId) {", "replace": "            if true {", "witness": "testW07AForcedBloomFalsePositiveDoesNotSuppressAFetch", "why": "the bloom hint is ignored: the producer-side offer stoppeth being a bloom decision at all, so the witness's PREMISE (that a saturated bloom really would suppress an offer) no longer holdeth and the witness condemneth -- the guard of the witness's own honesty", "baseline": "green (T42 court: 16 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT42Tests.swift; the whole GodstoneFoundation package standeth at 1073 tests, 0 failures, beside it)", "kind": "functional"},
    # ----------------------------------------------------------------------
    # T43 (s17): the honest delivery labels -- queued until an intended
    #   recipient ACK, with local link offers EPHEMERAL. The card's NAMED
    #   semantic negative is RC1/RC9: "Advance delivered/handed on send Boolean:
    #   authority projection tests fail." Each rod striketh one production line
    #   and is witnessed by its OWN named case; the baseline is the T43 courts
    #   in full (13 witnesses on each isle, green).
    # ----------------------------------------------------------------------
    {"id": "T43-RC1-android-send-boolean-advanceth-the-label", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT43Test.kt", "gradle_filter": "*ReadinessT43Test*", "find": "            linkOffers.record(canonicalFrame.msgId, peerId, admitted, controlClock())\n            if (admitted) handed++", "replace": "            linkOffers.record(canonicalFrame.msgId, peerId, admitted, controlClock())\n            if (admitted) { handed++; deliveryTracker.markHandedToRelay(canonicalFrame.msgId) }", "witness": "test_w01_att_success_without_remote_storage_leaveth_it_queued", "why": "the card's NAMED semantic negative: a Boolean send advances the durable label HANDED_TO_RELAY again, so a local ATT admission becometh a custody claim. The projection witness, which requireth QUEUED_DURABLY/OFFERED, condemneth", "baseline": "green (T43 courts: 13 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT43Test*) and 13 on the iOS twin (swift test --filter ReadinessT43Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T43-RC2-android-sos-send-advanceth-the-label", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT43Test.kt", "gradle_filter": "*ReadinessT43Test*", "find": "            linkOffers.record(frame.msgId, peerId, admitted, controlClock())\n            if (admitted) handed++", "replace": "            linkOffers.record(frame.msgId, peerId, admitted, controlClock())\n            if (admitted) { handed++; deliveryTracker.markHandedToRelay(frame.msgId) }", "witness": "test_w13_a_broadcast_send_leaveth_the_sos_label_queued", "why": "the SOS arm carrieth the same defect: the broadcast's Boolean send advances the durable row. The witness condemneth (and the T38/T39 composed witnesses with it)", "baseline": "green (T43 courts: 13 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT43Test*) and 13 on the iOS twin (swift test --filter ReadinessT43Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T43-RC3-android-offer-labelled-delivered", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryProjection.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT43Test.kt", "gradle_filter": "*ReadinessT43Test*", "find": "                DeliveryState.QUEUED_DURABLY ->\n                    if (linkOffers > 0) DeliveryLabel.OFFERED else DeliveryLabel.QUEUED", "replace": "                DeliveryState.QUEUED_DURABLY -> DeliveryLabel.DELIVERED", "witness": "test_w01_att_success_without_remote_storage_leaveth_it_queued", "why": "a local link offer is labelled DELIVERED: the label claimeth what no ACK produced. The projection witness condemneth (claimsDelivery and the label itself)", "baseline": "green (T43 courts: 13 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT43Test*) and 13 on the iOS twin (swift test --filter ReadinessT43Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T43-RC4-android-offer-cleareth-retryability", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryProjection.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT43Test.kt", "gradle_filter": "*ReadinessT43Test*", "find": "                retryable = effective == DeliveryState.QUEUED_DURABLY,", "replace": "                retryable = effective == DeliveryState.QUEUED_DURABLY && linkOffers == 0,", "witness": "test_w01_att_success_without_remote_storage_leaveth_it_queued", "why": "an offer clears retryability: a message whose bytes a radio took would stop being retried though nothing acknowledged it. The witness condemneth", "baseline": "green (T43 courts: 13 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT43Test*) and 13 on the iOS twin (swift test --filter ReadinessT43Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T43-RC5-android-legacy-row-read-as-custody", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryProjection.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT43Test.kt", "gradle_filter": "*ReadinessT43Test*", "find": "            val legacy = state == DeliveryState.HANDED_TO_RELAY", "replace": "            val legacy = false", "witness": "test_w08_a_legacy_handed_row_is_read_as_queued", "why": "a legacy HANDED_TO_RELAY row is no longer read as the queued estate it always was: it would stand as a custody claim and never migrate. The legacy witness condemneth", "baseline": "green (T43 courts: 13 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT43Test*) and 13 on the iOS twin (swift test --filter ReadinessT43Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T43-RC6-android-migration-rewriteth-the-wrong-way", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryProjection.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT43Test.kt", "gradle_filter": "*ReadinessT43Test*", "find": "        \"UPDATE $table SET $column = $MIGRATED_CODE WHERE $column = $LEGACY_CODE\",", "replace": "        \"UPDATE $table SET $column = $LEGACY_CODE WHERE $column = $MIGRATED_CODE\",", "witness": "test_w09_the_legacy_migration_rewriteth_through_the_engine", "why": "the migration rewriteth queued rows INTO the legacy label -- the exact inversion: every honest row would become a custody claim. The migration witness condemneth", "baseline": "green (T43 courts: 13 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT43Test*) and 13 on the iOS twin (swift test --filter ReadinessT43Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T43-RC7-android-offer-ledger-unbounded", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryProjection.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT43Test.kt", "gradle_filter": "*ReadinessT43Test*", "find": "            while (offers.size >= bound) {\n                offers.removeFirst()\n                dropped++\n            }", "replace": "            // (mutant) the offer ledger is unbounded", "witness": "test_w11_the_offer_ledger_is_bounded_and_fail_closed", "why": "the ephemeral ledger is unbounded: telemetry would grow without limit under a flood. The bounded-ledger witness condemneth", "baseline": "green (T43 courts: 13 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT43Test*) and 13 on the iOS twin (swift test --filter ReadinessT43Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T43-RC8-android-refused-offer-counted-as-admitted", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryProjection.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT43Test.kt", "gradle_filter": "*ReadinessT43Test*", "find": "    fun refusedCountFor(msgId: ByteArray): Int = synchronized(lock) {\n        offers.count { it.msgId.contentEquals(msgId) && !it.admitted }\n    }", "replace": "    fun refusedCountFor(msgId: ByteArray): Int = synchronized(lock) {\n        offers.count { it.msgId.contentEquals(msgId) && it.admitted }\n    }", "witness": "test_w02_a_refused_send_leaveth_the_label_queued", "why": "a refused local attempt is counted as admitted: the telemetry would report bytes leaving a device that refused them. The refused-offer witness condemneth", "baseline": "green (T43 courts: 13 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT43Test*) and 13 on the iOS twin (swift test --filter ReadinessT43Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T43-RC9-ios-send-boolean-advanceth-the-label", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshNode.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT43Tests.swift", "swift_filter": "ReadinessT43Tests", "find": "            let admitted = send(canonicalFrame, peer)\n            linkOffers.record(canonicalFrame.msgId, linkId: Self.linkBytes(peer), admitted: admitted,\n                              atMonoMillis: controlClock())\n            if admitted { handed += 1 }", "replace": "            let admitted = send(canonicalFrame, peer)\n            linkOffers.record(canonicalFrame.msgId, linkId: Self.linkBytes(peer), admitted: admitted,\n                              atMonoMillis: controlClock())\n            if admitted { count += 1; deliveryTracker.markHandedToRelay(canonicalFrame.msgId) }", "witness": "testW01AttSuccessWithoutRemoteStorageLeavethItQueued", "why": "the card's NAMED semantic negative on the iOS twin: a Boolean send advances the durable label again, and the projection witness condemneth", "baseline": "green (T43 courts: 13 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT43Test*) and 13 on the iOS twin (swift test --filter ReadinessT43Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T43-RC10-ios-offer-labelled-delivered", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/DeliveryProjection.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT43Tests.swift", "swift_filter": "ReadinessT43Tests", "find": "        case .queuedDurably: label = linkOffers > 0 ? .offered : .queued", "replace": "        case .queuedDurably: label = .delivered", "witness": "testW01AttSuccessWithoutRemoteStorageLeavethItQueued", "why": "a local link offer is labelled DELIVERED on the iOS twin: the label claimeth what no ACK produced. The witness condemneth", "baseline": "green (T43 courts: 13 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT43Test*) and 13 on the iOS twin (swift test --filter ReadinessT43Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T43-RC11-ios-legacy-row-read-as-custody", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/DeliveryProjection.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT43Tests.swift", "swift_filter": "ReadinessT43Tests", "find": "        let legacy = state == .handedToRelay", "replace": "        let legacy = false", "witness": "testW08ALegacyHandedRowIsReadAsQueued", "why": "a legacy handedToRelay row is no longer read as the queued estate it always was on the iOS twin; the legacy witness condemneth", "baseline": "green (T43 courts: 13 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT43Test*) and 13 on the iOS twin (swift test --filter ReadinessT43Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T43-RC12-ios-migration-rewriteth-the-wrong-way", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/DeliveryProjection.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT43Tests.swift", "swift_filter": "ReadinessT43Tests", "find": "        [\"UPDATE \\(table) SET \\(column) = \\(migratedCode) WHERE \\(column) = \\(legacyCode)\"]", "replace": "        [\"UPDATE \\(table) SET \\(column) = \\(legacyCode) WHERE \\(column) = \\(migratedCode)\"]", "witness": "testW09TheLegacyMigrationRewritethThroughTheEngine", "why": "the iOS migration rewriteth queued rows INTO the legacy label -- the exact inversion; the migration witness condemneth", "baseline": "green (T43 courts: 13 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT43Test*) and 13 on the iOS twin (swift test --filter ReadinessT43Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T43-RC13-ios-sos-send-advanceth-the-label", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshNode.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT43Tests.swift", "swift_filter": "ReadinessT43Tests", "find": "            let admitted = send(frame, peer)\n            linkOffers.record(frame.msgId, linkId: Self.linkBytes(peer), admitted: admitted,\n                              atMonoMillis: controlClock())\n            if admitted { handed += 1 }", "replace": "            let admitted = send(frame, peer)\n            linkOffers.record(frame.msgId, linkId: Self.linkBytes(peer), admitted: admitted,\n                              atMonoMillis: controlClock())\n            if admitted { count += 1; deliveryTracker.markHandedToRelay(frame.msgId) }", "witness": "testW13ABroadcastSendLeavethTheSosLabelQueued", "why": "the SOS arm carrieth the same defect on the iOS twin: the broadcast's Boolean send advances the durable row, and the SOS witness condemneth", "baseline": "green (T43 courts: 13 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT43Test*) and 13 on the iOS twin (swift test --filter ReadinessT43Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    # ----------------------------------------------------------------------
    # T44 (s17): the composed-runtime crash-safe multihop proof. The card's NAMED
    #   semantic negative is RC2/RC8: "Bypass the trusted runtime composition or
    #   durable inbound commit while keeping unit tests green: composed trace must
    #   fail." Each rod striketh one harness line and is witnessed by its OWN
    #   named case; the baseline is the T44 courts in full (12 witnesses each).
    # ----------------------------------------------------------------------
    {"id": "T44-RC1-android-seal-a-bare-body", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/runtime/ComposedRuntime.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT44Test.kt", "gradle_filter": "*ReadinessT44Test*", "find": "        val container = io.godstone.mesh.wire.v2.SignedMessageV1.author(", "replace": "        val container = plaintext   // (mutant) the sealed inner is NOT the signed container\n        val unusedAuthor = io.godstone.mesh.wire.v2.SignedMessageV1.author(", "witness": "test_w01_directed_delivery_reacheth_delivered_through_the_composition", "why": "the trusted runtime composition is bypassed at the payload: the sealed inner is no longer the frozen signed container, so the recipient's verifier must refuse it and no delivery can be claimed. RC1's sibling is RC2", "baseline": "green (T44 courts: 12 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT44Test*) and 12 on the iOS twin (swift test --filter ReadinessT44Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T44-RC2-android-send-without-the-durable-commit", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/runtime/ComposedRuntime.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT44Test.kt", "gradle_filter": "*ReadinessT44Test*", "find": "        if (admitted) {\n            // the radio DELIVERETH: the recorded bytes are handed to the receiving\n            // node's own dispatch statute, which is the only way anything enters\n            // its durable estate\n            val frame = FrameV2.decode(bytes)\n            if (frame != null) nodes[toLabel]?.node?.ingestInbound(frame, node.nodeId)\n        }", "replace": "        // (mutant) the durable inbound commit is bypassed: the bytes are recorded\n        // and never entered into the receiving node's estate", "witness": "test_w12_every_relayed_byte_belongeth_to_a_durably_held_frame", "why": "THE CARD'S NAMED NEGATIVE, first limb: the durable inbound commit is bypassed while every unit test stays green, so a frame would travel without ever entering an estate. The composed-trace witness condemneth", "baseline": "green (T44 courts: 12 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT44Test*) and 12 on the iOS twin (swift test --filter ReadinessT44Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T44-RC3-android-crash-seam-ignored", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/runtime/ComposedRuntime.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT44Test.kt", "gradle_filter": "*ReadinessT44Test*", "find": "        if (crashAt == SEAM_BEFORE_LINK) {\n            crashAt = null\n            trace.append(TraceEvent(\"crash\", clock.monoMillis(), mapOf(\"boundary\" to SEAM_BEFORE_LINK)))\n            throw ComposedCrash(SEAM_BEFORE_LINK)\n        }", "replace": "        // (mutant) the crash seam is asleep: the composition never interrupteth", "witness": "test_w05_a_crash_before_the_link_sendeth_nothing", "why": "a crash checkpoint that never fireth proveth nothing about recovery: the estate would be reported as tested while no interruption ever happened. The crash witness condemneth", "baseline": "green (T44 courts: 12 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT44Test*) and 12 on the iOS twin (swift test --filter ReadinessT44Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T44-RC4-android-wipe-letteth-the-send-through", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/runtime/ComposedRuntime.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT44Test.kt", "gradle_filter": "*ReadinessT44Test*", "find": "        if (wiped) {\n            trace.append(TraceEvent(\"send_refused\", clock.monoMillis(),\n                mapOf(\"node\" to node.label, \"reason\" to \"wipe_in_progress\")))\n            return false\n        }", "replace": "        // (mutant) a wipe no longer stoppeth a send: the pre-wipe epoch may publish", "witness": "test_w07_a_wipe_during_a_send_stops_every_epoch", "why": "the section 5 invariant 8 boundary is broken: a send is admitted while a wipe is in progress, so pre-wipe material could leave the device. The wipe witness condemneth", "baseline": "green (T44 courts: 12 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT44Test*) and 12 on the iOS twin (swift test --filter ReadinessT44Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T44-RC5-android-trace-bound-removed", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/runtime/ComposedRuntime.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT44Test.kt", "gradle_filter": "*ReadinessT44Test*", "find": "        while (events.size >= bound) {\n            events.removeAt(0)\n            dropped++\n        }\n        events.add(event)", "replace": "        events.add(event)   // (mutant) the trace is unbounded", "witness": "test_w09_resource_growth_is_finite", "why": "the trace groweth without limit: a composed run would leak memory in proportion to traffic. The finite-growth witness condemneth", "baseline": "green (T44 courts: 12 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT44Test*) and 12 on the iOS twin (swift test --filter ReadinessT44Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T44-RC6-android-future-schema-auto-detected", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/runtime/ComposedRuntime.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT44Test.kt", "gradle_filter": "*ReadinessT44Test*", "find": "            require(schema == SCHEMA) { \"the trace schema $schema is refused (only $SCHEMA is known)\" }", "replace": "            require(schema >= 1) { \"a trace schema must be positive\" }   // (mutant) auto-detect", "witness": "test_w10_the_trace_round_trippeth_and_refuseth_a_future_schema", "why": "a FUTURE trace schema is auto-detected instead of refused: a foreign isle's newer format would be read with this isle's meanings. The schema witness condemneth", "baseline": "green (T44 courts: 12 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT44Test*) and 12 on the iOS twin (swift test --filter ReadinessT44Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T44-RC7-android-replay-bypasseth-the-estate", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/runtime/ComposedRuntime.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT44Test.kt", "gradle_filter": "*ReadinessT44Test*", "find": "        trace.append(TraceEvent(\"replay_ingested\", clock.monoMillis(),\n            mapOf(\"from\" to from, \"to\" to to, \"msg_id\" to hex(frame.msgId))))\n        return b.node.ingestInbound(frame, a.nodeId)", "replace": "        return true   // (mutant) the replay never re-entereth the statute", "witness": "test_w08_a_replay_after_reconnect_is_a_duplicate", "why": "the replay never re-entereth the receiving statute and still reporteth success: the witness's own premise (that the same bytes came back through the statute, leaving the re-entry in the trace) would be false, and the witness condemneth", "baseline": "green (T44 courts: 12 witnesses on the android isle and 12 on the iOS twin)", "kind": "functional"},
    {"id": "T44-RC8-ios-send-without-the-durable-commit", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/ComposedRuntime.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT44Tests.swift", "swift_filter": "ReadinessT44Tests", "find": "        if admitted, let receiving = nodes[toLabel], let frame = FrameV2.decode(bytes) {\n            // the radio DELIVERETH: the recorded bytes are handed to the receiving\n            // node's own dispatch statute, which is the only way anything enters\n            // its durable estate\n            _ = receiving.node.ingestInbound(frame, receivedFrom: node.nodeId)\n        }", "replace": "        // (mutant) the durable inbound commit is bypassed on this isle", "witness": "testW12EveryRelayedByteBelongethToADurablyHeldFrame", "why": "THE CARD'S NAMED NEGATIVE on the iOS twin: the durable inbound commit is bypassed while the unit tests stay green, and the composed-trace witness condemneth", "baseline": "green (T44 courts: 12 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT44Test*) and 12 on the iOS twin (swift test --filter ReadinessT44Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T44-RC9-ios-seal-a-bare-body", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/ComposedRuntime.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT44Tests.swift", "swift_filter": "ReadinessT44Tests", "find": "        let container = try SignedMessageV1.author(", "replace": "        let container = plaintext   // (mutant) the sealed inner is NOT the signed container\n        _ = try SignedMessageV1.author(", "witness": "testW01DirectedDeliveryReachethDeliveredThroughTheComposition", "why": "the trusted runtime composition is bypassed at the payload on the iOS twin: the recipient's frozen verifier must refuse it. The delivery witness condemneth", "baseline": "green (T44 courts: 12 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT44Test*) and 12 on the iOS twin (swift test --filter ReadinessT44Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T44-RC10-ios-crash-seam-ignored", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/ComposedRuntime.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT44Tests.swift", "swift_filter": "ReadinessT44Tests", "find": "        if crashAt == ComposedRuntimeHarness.seamBeforeLink {\n            crashAt = nil\n            trace.append(TraceEvent(kind: \"crash\", atMonoMillis: clock.monoMillis(),\n                                    fields: [\"boundary\": ComposedRuntimeHarness.seamBeforeLink]))\n            return false\n        }", "replace": "        // (mutant) the crash seam is asleep on this isle", "witness": "testW05ACrashBeforeTheLinkSendethNothing", "why": "a crash checkpoint that never fireth proveth nothing about recovery on the iOS twin; the crash witness condemneth", "baseline": "green (T44 courts: 12 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT44Test*) and 12 on the iOS twin (swift test --filter ReadinessT44Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T44-RC11-ios-wipe-letteth-the-send-through", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/ComposedRuntime.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT44Tests.swift", "swift_filter": "ReadinessT44Tests", "find": "        if wiped {\n            trace.append(TraceEvent(kind: \"send_refused\", atMonoMillis: clock.monoMillis(),\n                                    fields: [\"node\": node.label, \"reason\": \"wipe_in_progress\"]))\n            return false\n        }", "replace": "        // (mutant) a wipe no longer stoppeth a send, and recordeth no epoch boundary", "witness": "testW07AWipeDuringASendStopsEveryEpoch", "why": "the wipe boundary is broken on the iOS twin: a send is admitted mid-wipe and no refusal is recorded; the wipe witness condemneth", "baseline": "green (T44 courts: 12 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT44Test*) and 12 on the iOS twin (swift test --filter ReadinessT44Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    {"id": "T44-RC12-ios-trace-bound-removed", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/ComposedRuntime.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT44Tests.swift", "swift_filter": "ReadinessT44Tests", "find": "        while events.count >= bound {\n            events.removeFirst()\n            dropped += 1\n        }\n        events.append(event)", "replace": "        events.append(event)   // (mutant) the trace is unbounded", "witness": "testW09ResourceGrowthIsFinite", "why": "the trace groweth without limit on the iOS twin; the finite-growth witness condemneth", "baseline": "green (T44 courts: 12 witnesses on the android isle (gradlew :mesh:testDebugUnitTest --tests *ReadinessT44Test*) and 12 on the iOS twin (swift test --filter ReadinessT44Tests); the subsystem isles stand green beside them)", "kind": "functional"},
    # ----------------------------------------------------------------------
    # T54 (s24-28): the lab-isolation gate and its profile resolver. The card's
    #   NAMED semantic negative is RC1/RC2: "Include a lab source set or readiness
    #   override in LIGHT release: binary/profile gate fails." Each rod striketh one
    #   gate or resolver line and is witnessed by its OWN named case in
    #   tools/readiness/tests/test_t54.py.
    # ----------------------------------------------------------------------
    {"id": "T54-RC1-lab-isolation-gate-sleepeth-on-a-mesh-edge", "platform": "python", "file": "ci/check_lab_isolation.py", "court": "tools/readiness/tests/test_t54.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t54.py", "find": "    for mod in profile.link_map:\n        if mod in FORBIDDEN_ANDROID_MODULES:", "replace": "    for mod in []:   # (mutant) the shipping :mesh edge is no longer refused\n        if mod in FORBIDDEN_ANDROID_MODULES:", "witness": "test_w02_the_light_release_carrieth_no_lab_and_no_mesh_edge", "why": "the gate no longer refuseth a :mesh edge on the LIGHT shipping profile: the lab's module could be linked into the release and every other check would stay green. The isolation witness condemneth", "baseline": "green (the T54 court: 12 witnesses in tools/readiness/tests/test_t54.py, driven by the real resolver and the real gate over this repository; the gate's own --selftest carrieth ten corrupted fixtures, each refused by name)", "kind": "functional"},
    {"id": "T54-RC2-lab-isolation-gate-sleepeth-on-a-readiness-override", "platform": "python", "file": "ci/check_lab_isolation.py", "court": "tools/readiness/tests/test_t54.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t54.py", "find": "        if field_name in READINESS_FIELDS and value.lower() not in (\"false\", \"0\", \"\"):", "replace": "        if False and field_name in READINESS_FIELDS:   # (mutant) overrides unchecked", "witness": "test_w03_a_readiness_override_in_the_light_flavour_is_refused", "why": "a readiness override in the shipping flavour is no longer refused: MESH_ENABLED=true would ship and the gate would pass. The override witness condemneth", "baseline": "green (the T54 court: 12 witnesses in tools/readiness/tests/test_t54.py, driven by the real resolver and the real gate over this repository; the gate's own --selftest carrieth ten corrupted fixtures, each refused by name)", "kind": "functional"},
    {"id": "T54-RC3-lab-may-masquerade-as-the-shipping-identity", "platform": "python", "file": "ci/check_lab_isolation.py", "court": "tools/readiness/tests/test_t54.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t54.py", "find": "    elif ident == shipping_id:\n        f.error(f\"LAB {platform}: carrieth the SHIPPING identity {ident!r} -- a lab \"\n                f\"install could be confused with the release\")", "replace": "    elif False:   # (mutant) a lab may carry the shipping identity\n        f.error(f\"LAB {platform}: carrieth the SHIPPING identity {ident!r}\")", "witness": "test_w05_the_lab_carrieth_its_own_distinct_identity", "why": "a lab that carrieth the SHIPPING application id is accepted: an experimental install could be upgraded over, or confused with, the release. The identity witness condemneth", "baseline": "green (the T54 court: 12 witnesses in tools/readiness/tests/test_t54.py, driven by the real resolver and the real gate over this repository; the gate's own --selftest carrieth ten corrupted fixtures, each refused by name)", "kind": "functional"},
    {"id": "T54-RC4-lab-need-not-reach-the-canonical-runtime", "platform": "python", "file": "ci/check_lab_isolation.py", "court": "tools/readiness/tests/test_t54.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t54.py", "find": "        if \"mesh\" not in reached:\n            f.error(\"LAB android: the lab does not reach :mesh, so it would test a \"\n                    \"twin rather than the canonical runtime\")", "replace": "        # (mutant) a lab that reacheth no canonical module is accepted", "witness": "test_w06_the_lab_reacheth_the_canonical_components", "why": "the lab may drop :mesh and still pass, so the lab would test a twin rather than the canonical runtime. The canonical-components witness condemneth", "baseline": "green (the T54 court: 12 witnesses in tools/readiness/tests/test_t54.py, driven by the real resolver and the real gate over this repository; the gate's own --selftest carrieth ten corrupted fixtures, each refused by name)", "kind": "functional"},
    {"id": "T54-RC5-a-synthetic-ready-setter-is-waved-through", "platform": "python", "file": "ci/check_lab_isolation.py", "court": "tools/readiness/tests/test_t54.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t54.py", "find": "        for pattern in READY_SETTER_PATTERNS:", "replace": "        for pattern in []:   # (mutant) a synthetic READY setter is waved through", "witness": "test_w07_the_lab_cannot_manufacture_readiness", "why": "a lab that manufactureth crypto readiness (a forceReady()/setReady(true) setter) is accepted, which is exactly what the card forbiddeth. The readiness witness condemneth", "baseline": "green (the T54 court: 12 witnesses in tools/readiness/tests/test_t54.py, driven by the real resolver and the real gate over this repository; the gate's own --selftest carrieth ten corrupted fixtures, each refused by name)", "kind": "functional"},
    {"id": "T54-RC6-a-gate-may-cite-the-lab", "platform": "python", "file": "ci/check_lab_isolation.py", "court": "tools/readiness/tests/test_t54.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t54.py", "find": "        for needle in lab_needles:\n            if needle in text:", "replace": "        for needle in []:   # (mutant) a release gate may cite the lab\n            if needle in text:", "witness": "test_w09_the_release_manifest_is_unchanged", "why": "a release gate may cite a lab measurement: an experimental target could then move a gate. The manifest witness condemneth", "baseline": "green (the T54 court: 12 witnesses in tools/readiness/tests/test_t54.py, driven by the real resolver and the real gate over this repository; the gate's own --selftest carrieth ten corrupted fixtures, each refused by name)", "kind": "functional"},
    {"id": "T54-RC7-the-resolver-blindeth-itself-to-a-declared-srcDir", "platform": "python", "file": "ci/profile_resolver.py", "court": "tools/readiness/tests/test_t54.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t54.py", "find": "    for m in re.finditer(r'srcDirs?\\(\\s*\"([^\"]+)\"\\s*\\)', text):\n        rel = m.group(1).rstrip(\"/\")\n        if rel not in roots:\n            roots.append(rel)", "replace": "    # (mutant) a DECLARED source root is invisible: only materialized dirs count", "witness": "test_w12_a_declared_srcDir_is_seen_even_when_not_materialized", "why": "the resolver blindeth itself to a declared srcDir(...), so a lab source set declared rather than materialized would be MISSED by every check built on it. This is the escape the first resolver actually allowed, and the witness condemneth it", "baseline": "green (the T54 court: 12 witnesses in tools/readiness/tests/test_t54.py, driven by the real resolver and the real gate over this repository; the gate's own --selftest carrieth ten corrupted fixtures, each refused by name)", "kind": "functional"},
    {"id": "T54-RC8-the-light-ios-app-may-link-the-mesh-product", "platform": "python", "file": "ci/check_lab_isolation.py", "court": "tools/readiness/tests/test_t54.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t54.py", "find": "    for product in profile.products:\n        if product in FORBIDDEN_IOS_PRODUCTS:", "replace": "    for product in []:   # (mutant) the LIGHT app may product-link GodstoneMesh\n        if product in FORBIDDEN_IOS_PRODUCTS:", "witness": "test_w04_the_light_ios_app_links_only_the_core_product", "why": "the LIGHT iOS app may product-link GodstoneMesh and still pass: the shipping app would carry the mesh runtime it intentionally excludes. The iOS witness condemneth", "baseline": "green (the T54 court: 12 witnesses in tools/readiness/tests/test_t54.py, driven by the real resolver and the real gate over this repository; the gate's own --selftest carrieth ten corrupted fixtures, each refused by name)", "kind": "functional"},
    # ----------------------------------------------------------------------
    # T55 (s17): the identity verification, rotation and wipe UX. The card's NAMED
    #   semantic negative is RC1: "Approve whichever rotation is current instead of
    #   the displayed candidate: CAS/UI integration fails." Each rod striketh one
    #   app-layer line and is witnessed by its OWN named case in
    #   android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt.
    # ----------------------------------------------------------------------
    {"id": "T55-RC1-approve-the-current-rotation-not-the-displayed-one", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/trust/IdentityTrustViewModel.kt", "module": "app", "test_task": "testLightDebugUnitTest", "gradle_filter": "*ReadinessT55Test*", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt", "find": "        val outcome = port.approveRotation(candidate)", "replace": "        // (mutant) THE CARD'S NAMED NEGATIVE: re-read \"the current\" pending\n        // rotation and approve WHATEVER it is, ignoring which candidate the user\n        // actually compared and tapped\n        val current = project(lastOutcome = null, error = null)\n            .contact(candidate.nodeIdCopy())?.pendingRotation ?: candidate\n        val outcome = port.approveRotation(current)", "witness": "test_w02_the_displayed_candidate_is_the_one_approved", "why": "the app approveth whichever rotation is CURRENT instead of the one the screen displayed: a user who compared the elder key would silently bless a newer one. The competing-candidates witness condemneth (and W03 with it)", "baseline": "green (the T55 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt, driven by the real IdentityTrustViewModel and the real QR policy against a deterministic port that mirrors the durable repository's CAS semantics)", "kind": "functional"},
    {"id": "T55-RC2-compare-promoteth-without-the-authority", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/trust/IdentityTrustViewModel.kt", "module": "app", "test_task": "testLightDebugUnitTest", "gradle_filter": "*ReadinessT55Test*", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt", "find": "port.confirmVerified(nodeId, contact.fingerprintHex)) {", "replace": "(ConfirmOutcome.Confirmed(nodeId, contact.acceptedGeneration))) {   // (mutant) the authority is never asked", "witness": "test_w01_one_contact_is_verified_only_after_the_compare", "why": "a locally-matching digest is treated as a DURABLE verification: the authority is never asked to record it, so first-use trust would be promoted in the UI alone and a relaunch would forget it. The verify witness condemneth", "baseline": "green (the T55 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt, driven by the real IdentityTrustViewModel and the real QR policy against a deterministic port that mirrors the durable repository's CAS semantics)", "kind": "functional"},
    {"id": "T55-RC3-a-mismatch-promoteth-anyway", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/trust/IdentityTrustViewModel.kt", "module": "app", "test_task": "testLightDebugUnitTest", "gradle_filter": "*ReadinessT55Test*", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt", "find": "        if (!contact.fingerprintHex.equals(displayedHex, ignoreCase = true)) {", "replace": "        if (false) {   // (mutant) a mismatching fingerprint promoteth trust anyway", "witness": "test_w11_a_mismatching_fingerprint_is_refused", "why": "a fingerprint that DIFFERETH is accepted: the whole point of the compare (defeating a man in the middle who substituted a key) is defeated silently. The mismatch witness condemneth", "baseline": "green (the T55 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt, driven by the real IdentityTrustViewModel and the real QR policy against a deterministic port that mirrors the durable repository's CAS semantics)", "kind": "functional"},
    {"id": "T55-RC4-a-failed-wipe-is-not-resumable", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/trust/TrustContracts.kt", "module": "app", "test_task": "testLightDebugUnitTest", "gradle_filter": "*ReadinessT55Test*", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt", "find": "    val isResumable: Boolean get() = this is InProgress && resumable", "replace": "    val isResumable: Boolean get() = false   // (mutant) a failed wipe cannot be resumed", "witness": "test_w06_a_failed_wipe_surviveth_a_relaunch", "why": "an interrupted wipe is no longer resumable, so a persistent failure would leave the estate standing while the screen claimeth nothing to do. The relaunch witness condemneth", "baseline": "green (the T55 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt, driven by the real IdentityTrustViewModel and the real QR policy against a deterministic port that mirrors the durable repository's CAS semantics)", "kind": "functional"},
    {"id": "T55-RC5-a-completed-wipe-blocketh-ordinary-use", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/trust/TrustContracts.kt", "module": "app", "test_task": "testLightDebugUnitTest", "gradle_filter": "*ReadinessT55Test*", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt", "find": "    val blocksOrdinaryUse: Boolean get() = this is InProgress", "replace": "    val blocksOrdinaryUse: Boolean get() = this !is Idle   // (mutant) complete blocketh too", "witness": "test_w06_a_failed_wipe_surviveth_a_relaunch", "why": "a COMPLETE wipe is reported as blocking ordinary use -- the opposite of the truth, and the very defect the first form of this type carried until its witness caught it. The relaunch witness condemneth", "baseline": "green (the T55 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt, driven by the real IdentityTrustViewModel and the real QR policy against a deterministic port that mirrors the durable repository's CAS semantics)", "kind": "functional"},
    {"id": "T55-RC6-a-dismissed-rotation-is-silently-approved", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/trust/IdentityTrustViewModel.kt", "module": "app", "test_task": "testLightDebugUnitTest", "gradle_filter": "*ReadinessT55Test*", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt", "find": "        if (contact.pendingRotation == null) {\n            return withError(\"there is no pending rotation to dismiss\")\n        }\n        return project(lastOutcome = \"rotation review dismissed; trust unchanged\", error = null)", "replace": "        // (mutant) the DISMISSAL approves the standing candidate: the card's law\n        // \"a canceled rotation leaves old trust unchanged\" is broken while the\n        // screen still sayeth the review was dismissed\n        port.approveRotation(contact.pendingRotation!!)\n        return project(lastOutcome = \"rotation review dismissed; trust unchanged\", error = null)", "witness": "test_w02_the_displayed_candidate_is_the_one_approved", "why": "a rotation the user DISMISSED is approved anyway: the old trust is retired without the user ever blessing the new key. The competing-candidates witness (its dismissal arm) condemneth", "baseline": "green (the T55 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt, driven by the real IdentityTrustViewModel and the real QR policy against a deterministic port that mirrors the durable repository's CAS semantics)", "kind": "functional"},
    {"id": "T55-RC7-the-qr-payload-is-unbounded", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/trust/QrPayloadPolicy.kt", "module": "app", "test_task": "testLightDebugUnitTest", "gradle_filter": "*ReadinessT55Test*", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt", "find": "        if (payload.length > MAX_PAYLOAD_CHARS) {", "replace": "        if (false) {   // (mutant) the size bound is gone: a hostile QR is decoded", "witness": "test_w08_an_oversized_payload_is_refused_before_decoding", "why": "an unbounded QR payload is decoded, so a hostile code can drive an allocation the screen never asked for. The oversized-payload witness condemneth", "baseline": "green (the T55 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt, driven by the real IdentityTrustViewModel and the real QR policy against a deterministic port that mirrors the durable repository's CAS semantics)", "kind": "functional"},
    {"id": "T55-RC8-a-truncated-payload-is-accepted", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/trust/QrPayloadPolicy.kt", "module": "app", "test_task": "testLightDebugUnitTest", "gradle_filter": "*ReadinessT55Test*", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt", "find": "        if (decoded.size != EXPECTED_BYTES) {", "replace": "        if (false) {   // (mutant) the exact decoded width is unchecked", "witness": "test_w07_a_malformed_payload_is_refused", "why": "a truncated or padded payload is accepted into a binding, so a partial key could be imported as if it were a whole one. The malformed-payload witness condemneth", "baseline": "green (the T55 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt, driven by the real IdentityTrustViewModel and the real QR policy against a deterministic port that mirrors the durable repository's CAS semantics)", "kind": "functional"},
    {"id": "T55-RC9-the-screenshot-policy-is-always-on", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/trust/IdentityTrustViewModel.kt", "module": "app", "test_task": "testLightDebugUnitTest", "gradle_filter": "*ReadinessT55Test*", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt", "find": "            redacted = own != null,", "replace": "            redacted = true,   // (mutant) the policy no longer followeth the material", "witness": "test_w10_the_screenshot_policy_followeth_the_material", "why": "the screenshot policy no longer followeth what is on the screen: it claimeth protection where there is nothing to protect and would be ignored by the Activity. The policy witness condemneth", "baseline": "green (the T55 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt, driven by the real IdentityTrustViewModel and the real QR policy against a deterministic port that mirrors the durable repository's CAS semantics)", "kind": "functional"},
    {"id": "T55-RC10-corruption-is-hidden-as-an-empty-estate", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/trust/IdentityTrustViewModel.kt", "module": "app", "test_task": "testLightDebugUnitTest", "gradle_filter": "*ReadinessT55Test*", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt", "find": "        val census = port.contacts()\n        val contacts = (census as? TrustCensus.Readable)?.contacts ?: emptyList()", "replace": "        // (mutant) an UNREADABLE store is quietly re-labelled as an ordinary\n        // empty estate, so the screen claimeth a clean census it cannot read\n        val census: TrustCensus = when (val seen = port.contacts()) {\n            is TrustCensus.Corrupt -> TrustCensus.Readable(emptyList())\n            else -> seen\n        }\n        val contacts = (census as? TrustCensus.Readable)?.contacts ?: emptyList()", "witness": "test_w05_a_corrupt_trust_store_claimeth_nothing", "why": "a CORRUPT trust store is projected as an ordinary empty census instead of a typed CORRUPT marker: the user would be told they have no contacts rather than that their trust store cannot be read, and every refusal built on that marker would vanish. The corrupt-store witness condemneth", "baseline": "green (the T55 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt, driven by the real IdentityTrustViewModel and the real QR policy against a deterministic port that mirrors the durable repository's CAS semantics)", "kind": "functional"},
    {"id": "T55-RC11-a-local-refusal-re-projecteth-anyway", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/trust/IdentityTrustViewModel.kt", "module": "app", "test_task": "testLightDebugUnitTest", "gradle_filter": "*ReadinessT55Test*", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt", "find": "    private fun withError(message: String): TrustUiState {\n        state = state.copy(error = message, revision = state.revision + 1)\n        return state\n    }", "replace": "    private fun withError(message: String): TrustUiState =\n        project(lastOutcome = null, error = message)   // (mutant) read the estate anyway", "witness": "test_w07_a_malformed_payload_is_refused", "why": "a LOCALLY-refused command reacheth the durable authority anyway, so a malformed payload would drive a store read it never needed -- and the two refusal roads become indistinguishable. The malformed-payload witness condemneth", "baseline": "green (the T55 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt, driven by the real IdentityTrustViewModel and the real QR policy against a deterministic port that mirrors the durable repository's CAS semantics)", "kind": "functional"},
    {"id": "T55-RC12-the-ref-ignores-the-pending-generation", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/trust/TrustContracts.kt", "module": "app", "test_task": "testLightDebugUnitTest", "gradle_filter": "*ReadinessT55Test*", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt", "find": "        nodeId.contentEquals(other.nodeId) &&\n            pendingGeneration == other.pendingGeneration &&\n            pendingStaticDhPublicKey.contentEquals(other.pendingStaticDhPublicKey)", "replace": "        // (mutant) the pending GENERATION is ignored: two candidates with the\n        // same key at different generations compare equal, so the CAS's\n        // generation half would be defeated by the app's own ref\n        nodeId.contentEquals(other.nodeId) &&\n            pendingStaticDhPublicKey.contentEquals(other.pendingStaticDhPublicKey)", "witness": "test_w13_the_ref_matcheth_the_durable_cas_signature", "why": "two candidates with the SAME key at DIFFERENT generations compare equal, so the generation half of the durable CAS would be defeated by the app's own ref. The CAS-signature witness condemneth", "baseline": "green (the T55 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT55Test.kt, re-run after T56 taught both isles to carry the pending static KEY in the ref rather than a digest)", "kind": "functional"},
    # ----------------------------------------------------------------------
    # T56 (s17): the iOS identity, rotation and wipe UX -- the twin of T55. The
    #   card's NAMED semantic negative is RC1/RC2: "Show USER_VERIFIED before
    #   durable CAS succeeds: UI authority test fails." Each rod striketh one
    #   model line and is witnessed by its OWN named case in
    #   ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift.
    # ----------------------------------------------------------------------
    {"id": "T56-RC1-verified-shown-before-the-durable-cas", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/TrustUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift", "swift_filter": "ReadinessT56Tests", "find": "        switch authority.confirmVerified(nodeId: nodeId, fingerprintHex: contact.fingerprintHex,\n                                         displayedGeneration: contact.acceptedGeneration) {", "replace": "        // (mutant) THE CARD'S NAMED NEGATIVE: the UI claimeth USER_VERIFIED from a\n        // LOCAL match alone, never asking the durable authority to record it\n        _ = authority.confirmVerified(nodeId: nodeId, fingerprintHex: contact.fingerprintHex, displayedGeneration: contact.acceptedGeneration)\n        switch ConfirmOutcome.confirmed(nodeId: nodeId, acceptedGeneration: contact.acceptedGeneration) {", "witness": "testW02ARefusedCasNeverShowethUserVerified", "why": "the card's NAMED semantic negative: the UI claimeth USER_VERIFIED from a local match alone, overriding whatever the durable CAS answered -- so a REFUSED confirmation is rendered as a verification. The refused-CAS witness condemneth (the first form of this rod named W01, which the mutant still satisfieth because its `_ = authority.confirmVerified(...)` line really does move the durable row; the witness was re-pointed at the case that owneth the law)", "baseline": "green (the T56 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift, driven by the real TrustUXModel against a deterministic authority that mirrors PeerIdentityRepository's CAS semantics)", "kind": "functional"},
    {"id": "T56-RC2-a-refused-cas-still-showeth-user-verified", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/TrustUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift", "swift_filter": "ReadinessT56Tests", "find": "        case .refused(let reason):\n            return withAuthorityError(\"confirmation refused: \" + reason)", "replace": "        case .refused:\n            // (mutant) a REFUSED durable confirmation is shown as a verification\n            return project(lastOutcome: \"fingerprint confirmed for \" + contact.label, error: nil)", "witness": "testW02ARefusedCasNeverShowethUserVerified", "why": "an authority that REFUSED the confirmation is rendered as a successful verification: the screen would claim a trust the durable store never granted. The refused-CAS witness condemneth", "baseline": "green (the T56 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift, driven by the real TrustUXModel against a deterministic authority that mirrors PeerIdentityRepository's CAS semantics)", "kind": "functional"},
    {"id": "T56-RC3-a-locked-store-claimeth-a-stale-cache", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/TrustUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift", "swift_filter": "ReadinessT56Tests", "find": "        guard protectedData.isProtectedDataAvailable() else {\n            let locked = TrustUIState(\n                availability: .protectedDataUnavailable,\n                own: nil,\n                contacts: [],", "replace": "        guard protectedData.isProtectedDataAvailable() else {\n            // (mutant) the locked store is rendered from the PREVIOUS projection\n            let locked = TrustUIState(\n                availability: .protectedDataUnavailable,\n                own: state.own,\n                contacts: state.contacts,", "witness": "testW04ALockedPrivateStoreClaimethNothing", "why": "a LOCKED private store is rendered from the previous projection, so contacts and the own identity would stand on screen while the device is locked -- exactly what the protected-data rule forbiddeth. The locked-store witness condemneth", "baseline": "green (the T56 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift, driven by the real TrustUXModel against a deterministic authority that mirrors PeerIdentityRepository's CAS semantics)", "kind": "functional"},
    {"id": "T56-RC4-a-locked-command-mutates-anyway", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/TrustUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift", "swift_filter": "ReadinessT56Tests", "find": "        if !protectedData.isProtectedDataAvailable() {\n            switch command {\n            case .refresh, .clearError, .showOwnIdentity:\n                return project(lastOutcome: nil, error: nil)\n            default:\n                return project(lastOutcome: nil,\n                               error: \"the device is locked; unlock to review or change your contacts\")\n            }\n        }", "replace": "        if false {   // (mutant) a locked device no longer stoppeth a mutating command\n            return project(lastOutcome: nil, error: nil)\n        }", "witness": "testW05ALockDuringVerificationPromotethNothing", "why": "a mutating command reacheth the authority while the device is locked, so a verification could half-apply behind the lock screen. The lock-during-verification witness condemneth", "baseline": "green (the T56 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift, driven by the real TrustUXModel against a deterministic authority that mirrors PeerIdentityRepository's CAS semantics)", "kind": "functional"},
    {"id": "T56-RC5-the-displayed-candidate-is-not-what-travels", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/TrustUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift", "swift_filter": "ReadinessT56Tests", "find": "        let outcome = authority.approvePendingRotation(\n            nodeId: candidate.nodeId,\n            expectedPendingGeneration: candidate.pendingGeneration,\n            expectedPendingStaticDhPublicKey: candidate.pendingStaticDhPublicKey)", "replace": "        // (mutant) \"the current\" pending rotation is approved instead of the one\n        // the screen displayed\n        let current = project(lastOutcome: nil, error: nil).contact(candidate.nodeId)?.pendingRotation\n        let outcome = authority.approvePendingRotation(\n            nodeId: candidate.nodeId,\n            expectedPendingGeneration: (current ?? candidate).pendingGeneration,\n            expectedPendingStaticDhPublicKey: (current ?? candidate).pendingStaticDhPublicKey)", "witness": "testW03TheDisplayedCandidateIsTheOneApproved", "why": "the model approveth whichever rotation is CURRENT rather than the displayed candidate: a user who compared the elder key would silently bless a newer one. The competing-candidates witness condemneth", "baseline": "green (the T56 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift, driven by the real TrustUXModel against a deterministic authority that mirrors PeerIdentityRepository's CAS semantics)", "kind": "functional"},
    {"id": "T56-RC6-a-dismissal-approveth-the-candidate", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/TrustUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift", "swift_filter": "ReadinessT56Tests", "find": "        guard contact.pendingRotation != nil else {\n            return withError(\"there is no pending rotation to dismiss\")\n        }\n        // a dismissal is a UI decision, not an authority mutation: the pending row\n        // standeth and the old trust keepeth working", "replace": "        // (mutant) a DISMISSAL silently approveth the standing candidate\n        if let standing = contact.pendingRotation {\n            _ = authority.approvePendingRotation(\n                nodeId: standing.nodeId,\n                expectedPendingGeneration: standing.pendingGeneration,\n                expectedPendingStaticDhPublicKey: standing.pendingStaticDhPublicKey)\n        }\n        return project(lastOutcome: \"rotation review dismissed; trust unchanged\", error: nil)", "witness": "testW03TheDisplayedCandidateIsTheOneApproved", "why": "a rotation the user DISMISSED is approved anyway, retiring the old trust without the user ever blessing the new key. The dismissal arm of the competing-candidates witness condemneth", "baseline": "green (the T56 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift, driven by the real TrustUXModel against a deterministic authority that mirrors PeerIdentityRepository's CAS semantics)", "kind": "functional"},
    {"id": "T56-RC7-a-failed-wipe-is-not-resumable", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/TrustUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift", "swift_filter": "ReadinessT56Tests", "find": "        if case .inProgress(_, _, let resumable, _) = self { return resumable }\n        return false", "replace": "        return false   // (mutant) an interrupted wipe is no longer resumable", "witness": "testW08AFailedWipeSurvivethARelaunch", "why": "an interrupted wipe is reported as unresumable, so a persistent Keychain failure would leave the estate standing while the screen claimeth nothing to do. The relaunch witness condemneth", "baseline": "green (the T56 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift, driven by the real TrustUXModel against a deterministic authority that mirrors PeerIdentityRepository's CAS semantics)", "kind": "functional"},
    {"id": "T56-RC8-a-completed-wipe-blocketh-ordinary-use", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/TrustUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift", "swift_filter": "ReadinessT56Tests", "find": "        if case .inProgress = self { return true }\n        return false", "replace": "        return true   // (mutant) a COMPLETE wipe blocketh ordinary use too", "witness": "testW08AFailedWipeSurvivethARelaunch", "why": "a finished wipe is reported as blocking ordinary use -- the opposite of the truth, and the same defect the Android type carried until its witness caught it. The relaunch witness condemneth", "baseline": "green (the T56 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift, driven by the real TrustUXModel against a deterministic authority that mirrors PeerIdentityRepository's CAS semantics)", "kind": "functional"},
    {"id": "T56-RC9-a-mismatching-confirmation-promoteth", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/TrustUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift", "swift_filter": "ReadinessT56Tests", "find": "        guard contact.fingerprintHex.lowercased() == displayedHex.lowercased() else {\n            return withError(\"those fingerprints differ; the contact was NOT verified and trust is unchanged\")\n        }", "replace": "        // (mutant) a mismatching fingerprint promoteth trust anyway", "witness": "testW09AStaleConfirmationPromotethNothing", "why": "a fingerprint that DIFFERETH is accepted, defeating the whole point of the out-of-band comparison. The stale-confirmation witness condemneth", "baseline": "green (the T56 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift, driven by the real TrustUXModel against a deterministic authority that mirrors PeerIdentityRepository's CAS semantics)", "kind": "functional"},
    {"id": "T56-RC10-the-voice-labels-become-indistinguishable", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/TrustUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift", "swift_filter": "ReadinessT56Tests", "find": "    case .verified: return \"verified: you compared this fingerprint yourself\"\n    case .tofuUnverified: return \"not verified: trusted on first use only\"", "replace": "    case .verified: return \"contact\"\n    case .tofuUnverified: return \"contact\"", "witness": "testW07VoiceLabelsDistinguishEveryTrustLevel", "why": "a verified contact and a first-use contact SOUND alike: a screen-reader user could not tell a compared key from an unverified one, which is the accessibility failure this witness owneth. It condemneth", "baseline": "green (the T56 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift, driven by the real TrustUXModel against a deterministic authority that mirrors PeerIdentityRepository's CAS semantics)", "kind": "functional"},
    {"id": "T56-RC11-the-binding-payload-is-unbounded", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/TrustUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift", "swift_filter": "ReadinessT56Tests", "find": "        if payload.count > maxPayloadChars {", "replace": "        if false {   // (mutant) the size bound is gone: a hostile code is decoded", "witness": "testW12TheBindingPayloadIsBounded", "why": "an unbounded binding payload is decoded, so a hostile QR could drive an allocation the screen never asked for. The bounded-payload witness condemneth", "baseline": "green (the T56 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift, driven by the real TrustUXModel against a deterministic authority that mirrors PeerIdentityRepository's CAS semantics)", "kind": "functional"},
    {"id": "T56-RC12-revocation-leaveth-the-sessions-standing", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/TrustUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift", "swift_filter": "ReadinessT56Tests", "find": "        case .revoked:\n            // revocation invalidates the affected sessions\n            authority.invalidateSessions(for: nodeId)", "replace": "        case .revoked:\n            // (mutant) revocation no longer invalidates the affected sessions", "witness": "testW10RotationAndRevocationInvalidateSessions", "why": "a revoked contact's live sessions keep working: the peer is blocked on paper while the session it holds still carrieth traffic. The session-invalidation witness condemneth", "baseline": "green (the T56 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift, driven by the real TrustUXModel against a deterministic authority that mirrors PeerIdentityRepository's CAS semantics)", "kind": "functional"},
    # ----------------------------------------------------------------------
    # T57 (s17): the direct messaging and honest SOS controls. The card's NAMED
    #   semantic negative is RC1: "Project DELIVERED from transport Boolean:
    #   end-to-end UI test fails." Each rod striketh one app-layer line and is
    #   witnessed by its OWN named case in
    #   android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt.
    # ----------------------------------------------------------------------
    {"id": "T57-RC1-delivered-on-the-transport-boolean", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/mesh/MeshViewModel.kt", "module": "app", "test_task": "testLightDebugUnitTest", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt", "gradle_filter": "*ReadinessT57Test*", "find": "            is SendOutcome.Queued -> {\n                // law 1: the outcome is \"queued\", NOT \"sent\" and NOT \"delivered\":\n                // the authority's projected row is what the screen will show\n                val cleared = state.copy(draft = \"\", draftBytes = 0)\n                state = cleared\n                project(lastOutcome = \"queued for \" + recipient.label, error = null)\n            }", "replace": "            is SendOutcome.Queued -> {\n                // (mutant) THE CARD'S NAMED NEGATIVE: the UI projecteth a delivery\n                // from the transport Boolean alone\n                val cleared = state.copy(draft = \"\", draftBytes = 0)\n                state = cleared\n                val projected = project(lastOutcome = \"sent to \" + recipient.label, error = null)\n                state = projected.copy(lastOutcome = \"delivered to \" + recipient.label)\n                state\n            }", "witness": "test_w02_a_transport_boolean_never_projecteth_delivered", "why": "the UI claimeth a DELIVERY on a transport Boolean: the user would be told the recipient received a message that no ACK ever confirmed -- the card's named semantic negative. The transport-Boolean witness condemneth", "baseline": "green (the T57 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt, driven by the real MeshViewModel and the real compose policy against a deterministic port that projects statuses the way the durable authority would)", "kind": "functional"},
    {"id": "T57-RC2-an-att-acceptance-is-called-sent", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/ui/mesh/MeshScreens.kt", "module": "app", "test_task": "testLightDebugUnitTest", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt", "gradle_filter": "*ReadinessT57Test*", "find": "    MessageStatus.QUEUED -> \"Queued on this phone; it will be retried.\"", "replace": "    MessageStatus.QUEUED -> \"Sent.\"   // (mutant) a queued row is called SENT", "witness": "test_w01_offline_then_a_peer_then_the_ack", "why": "a durably QUEUED message is rendered as \"Sent\", which is the word the card forbiddeth on ATT acceptance: the user loseth the ability to tell queued from sent. The offline-journey witness condemneth", "baseline": "green (the T57 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt, driven by the real MeshViewModel and the real compose policy against a deterministic port that projects statuses the way the durable authority would)", "kind": "functional"},
    {"id": "T57-RC3-attempting-is-rendered-as-delivered", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/ui/mesh/MeshScreens.kt", "module": "app", "test_task": "testLightDebugUnitTest", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt", "gradle_filter": "*ReadinessT57Test*", "find": "    MessageStatus.ATTEMPTING -> \"On its way; no answer yet.\"", "replace": "    MessageStatus.ATTEMPTING -> \"Delivered: the recipient confirmed it.\"   // (mutant) ATT == delivered", "witness": "test_w01_offline_then_a_peer_then_the_ack", "why": "an ATT acceptance is rendered with the DELIVERY words: the single most dangerous substitution in the whole surface. The journey witness condemneth", "baseline": "green (the T57 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt, driven by the real MeshViewModel and the real compose policy against a deterministic port that projects statuses the way the durable authority would)", "kind": "functional"},
    {"id": "T57-RC4-secure-without-a-confirmed-key", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/mesh/MeshContracts.kt", "module": "app", "test_task": "testLightDebugUnitTest", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt", "gradle_filter": "*ReadinessT57Test*", "find": "    val isSecure: Boolean get() = selectedRecipient?.isVerified == true", "replace": "    val isSecure: Boolean get() = selectedRecipient?.hasTrustedKey == true   // (mutant) pinned counts", "witness": "test_w12_nothing_is_secure_before_the_key_is_confirmed", "why": "a merely PINNED key is called secure, so a first-use contact whose key nobody compared standeth behind a security chip. The key-confirmation witness condemneth", "baseline": "green (the T57 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt, driven by the real MeshViewModel and the real compose policy against a deterministic port that projects statuses the way the durable authority would)", "kind": "functional"},
    {"id": "T57-RC5-the-compose-bound-is-characters-not-bytes", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/mesh/MeshContracts.kt", "module": "app", "test_task": "testLightDebugUnitTest", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt", "gradle_filter": "*ReadinessT57Test*", "find": "    fun byteCount(body: String): Int = body.toByteArray(Charsets.UTF_8).size", "replace": "    fun byteCount(body: String): Int = body.length   // (mutant) characters, not UTF-8 bytes", "witness": "test_w06_the_compose_bound_is_bytes_not_characters", "why": "the 400-byte budget is computed in CHARACTERS, so a 200-character CJK body (600 bytes) would pass and overflow the documented budget on the wire. The byte-bound witness condemneth", "baseline": "green (the T57 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt, driven by the real MeshViewModel and the real compose policy against a deterministic port that projects statuses the way the durable authority would)", "kind": "functional"},
    {"id": "T57-RC6-truncation-splitteth-a-character", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/mesh/MeshContracts.kt", "module": "app", "test_task": "testLightDebugUnitTest", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt", "gradle_filter": "*ReadinessT57Test*", "find": "        var end = 0\n        for (index in body.indices) {\n            val candidate = body.substring(0, index + 1)\n            if (byteCount(candidate) > MAX_BODY_BYTES) break\n            end = index + 1\n        }\n        return body.substring(0, end)", "replace": "        // (mutant) the cut is made on a BYTE count and can split a character\n        return body.toByteArray(Charsets.UTF_8).copyOf(MAX_BODY_BYTES)\n            .toString(Charsets.UTF_8)", "witness": "test_w06_the_compose_bound_is_bytes_not_characters", "why": "truncation cutteth on a byte boundary and can split a multi-byte character into invalid UTF-8. The byte-bound witness condemneth", "baseline": "green (the T57 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt, driven by the real MeshViewModel and the real compose policy against a deterministic port that projects statuses the way the durable authority would)", "kind": "functional"},
    {"id": "T57-RC7-a-bare-tap-placeth-a-call", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/mesh/MeshViewModel.kt", "module": "app", "test_task": "testLightDebugUnitTest", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt", "gradle_filter": "*ReadinessT57Test*", "find": "        if (!state.sosArmed) {\n            return withError(\"hold the SOS control to place a call\")\n        }", "replace": "        // (mutant) the arm is no longer required: a bare TAP placeth a call", "witness": "test_w07_the_sos_control_requireth_an_arm", "why": "the hold-to-confirm law is gone, so a stray tap (or a pocket) can place a distress call. The held-control witness condemneth", "baseline": "green (the T57 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt, driven by the real MeshViewModel and the real compose policy against a deterministic port that projects statuses the way the durable authority would)", "kind": "functional"},
    {"id": "T57-RC8-cancel-implieth-recall", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/mesh/MeshContracts.kt", "module": "app", "test_task": "testLightDebugUnitTest", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt", "gradle_filter": "*ReadinessT57Test*", "find": "            \"Cancelling stops this phone retrying. Copies already handed to relays cannot be recalled.\"\n        } else {", "replace": "            \"Cancelling recalls every copy, including those already handed to relays.\"\n        } else {", "witness": "test_w08_cancel_nameth_the_relayed_copy_limitation", "why": "the cancel claimeth that relayed copies can be recalled -- a promise no radio can keep, and the exact limitation the card requireth be stated. The cancel witness condemneth", "baseline": "green (the T57 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt, driven by the real MeshViewModel and the real compose policy against a deterministic port that projects statuses the way the durable authority would)", "kind": "functional"},
    {"id": "T57-RC9-a-denied-permission-is-not-explained", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/mesh/MeshContracts.kt", "module": "app", "test_task": "testLightDebugUnitTest", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt", "gradle_filter": "*ReadinessT57Test*", "find": "            is PermissionDenied ->\n                \"Godstone cannot reach the radio: the nearby-devices permission was denied. \" +\n                    \"Messages stay queued until it is granted in Settings.\"", "replace": "            is PermissionDenied -> \"Something went wrong.\"   // (mutant) no explanation", "witness": "test_w10_a_denied_permission_is_explained", "why": "a denied permission becometh an unexplained failure, so the user cannot tell a settings problem from a radio problem and cannot act. The permission witness condemneth", "baseline": "green (the T57 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt, driven by the real MeshViewModel and the real compose policy against a deterministic port that projects statuses the way the durable authority would)", "kind": "functional"},
    {"id": "T57-RC10-the-draft-is-discarded-on-a-refusal", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/mesh/MeshViewModel.kt", "module": "app", "test_task": "testLightDebugUnitTest", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt", "gradle_filter": "*ReadinessT57Test*", "find": "            is SendOutcome.Refused -> withAuthorityError(\"send refused: \" + outcome.reason)", "replace": "            is SendOutcome.Refused -> {\n                // (mutant) a refused send throweth the user's text away\n                state = state.copy(draft = \"\", draftBytes = 0)\n                withAuthorityError(\"send refused: \" + outcome.reason)\n            }", "witness": "test_w03_failed_storage_leaveth_the_estate_and_the_draft", "why": "a refused send discards what the user wrote, so a storage failure costeth them their message. The failed-storage witness condemneth", "baseline": "green (the T57 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt, driven by the real MeshViewModel and the real compose policy against a deterministic port that projects statuses the way the durable authority would)", "kind": "functional"},
    {"id": "T57-RC11-a-duplicate-tap-sendeth-twice", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/mesh/MeshViewModel.kt", "module": "app", "test_task": "testLightDebugUnitTest", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt", "gradle_filter": "*ReadinessT57Test*", "find": "        if (DirectComposePolicy.isBlank(state.draft)) {\n            return withError(\"there is nothing to send\")\n        }", "replace": "        // (mutant) an empty draft is sent anyway: the second tap createth a row", "witness": "test_w04_duplicate_taps_create_one_row", "why": "the duplicate-tap guard is gone, so a second tap on Send createth a second durable row from an empty draft. The duplicate-tap witness condemneth", "baseline": "green (the T57 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt, driven by the real MeshViewModel and the real compose policy against a deterministic port that projects statuses the way the durable authority would)", "kind": "functional"},
    {"id": "T57-RC12-the-relaunch-inventeth-an-armed-control", "platform": "jvm", "file": "android/app/src/main/java/io/godstone/app/mesh/MeshViewModel.kt", "module": "app", "test_task": "testLightDebugUnitTest", "court": "android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt", "gradle_filter": "*ReadinessT57Test*", "find": "            sosArmed = state.sosArmed,", "replace": "            sosArmed = true,   // (mutant) a relaunch carrieth an ARMED sos control", "witness": "test_w09_a_relaunch_restoreth_the_active_call", "why": "a relaunched model carrieth an ARMED distress control, so the next tap would place a call the user never began. The relaunch witness condemneth", "baseline": "green (the T57 court: 13 witnesses in android/app/src/test/java/io/godstone/app/readiness/ReadinessT57Test.kt, driven by the real MeshViewModel and the real compose policy against a deterministic port that projects statuses the way the durable authority would)", "kind": "functional"},
    # ----------------------------------------------------------------------
    # T58 (s17): the iOS message and SOS journeys -- the twin of T57. The card's
    #   NAMED semantic negative is RC1: "Only reset coordinator UI on cancel:
    #   relaunch shows remaining work and the test fails." Each rod striketh one
    #   model line and is witnessed by its OWN named case in
    #   ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift.
    # ----------------------------------------------------------------------
    {"id": "T58-RC1-a-scene-changeover-resetteth-the-work", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "swift_filter": "ReadinessT58Tests", "find": "        return project(lastOutcome: state.lastOutcome, error: state.error)\n    }", "replace": "        // (mutant) THE CARD'S NAMED NEGATIVE: a scene changeover RESETTETH the\n        // coordinator UI, so remaining work vanisheth on background/foreground\n        state = MeshUIState(\n            availability: state.availability, link: state.link, scenePhase: phase,\n            recipients: [], selectedRecipient: nil, draft: state.draft,\n            draftBytes: state.draftBytes, messages: [], sos: nil, sosArmed: false,\n            error: state.error, lastOutcome: nil, revision: state.revision + 1)\n        return state\n    }", "witness": "testW02RemainingWorkSurvivethASceneChangeoverAndARelaunch", "why": "a background/foreground cycle resetteth the surface, so the remaining work vanisheth from the screen until the user forceth a refresh. The scene-changeover witness condemneth", "baseline": "green (the T58 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift, driven by the real MeshUXModel against a deterministic authority that projects statuses the way the durable repository would)", "kind": "functional"},
    {"id": "T58-RC2-delivered-on-the-transport-boolean", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "swift_filter": "ReadinessT58Tests", "find": "        case .queued:\n            // law 1: the outcome is \"queued\", NOT \"sent\" and NOT \"delivered\"\n            state = stateCopy(draft: \"\", draftBytes: 0)\n            return project(lastOutcome: \"queued for \" + recipient.label, error: nil)", "replace": "        case .queued:\n            // (mutant) the UI claimeth a DELIVERY from the transport Boolean\n            state = stateCopy(draft: \"\", draftBytes: 0)\n            _ = project(lastOutcome: \"delivered to \" + recipient.label, error: nil)\n            state = stateCopy(error: nil)\n            return state", "witness": "testW01OfflineThenAPeerThenTheAck", "why": "the UI claimeth a DELIVERY on the transport Boolean's own outcome, so the user is told the recipient received a message no ACK ever confirmed. The journey witness condemneth", "baseline": "green (the T58 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift, driven by the real MeshUXModel against a deterministic authority that projects statuses the way the durable repository would)", "kind": "functional"},
    {"id": "T58-RC3-an-att-acceptance-is-spoken-as-delivered", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "swift_filter": "ReadinessT58Tests", "find": "    case .attempting: return \"on its way; no answer yet\"", "replace": "    case .attempting: return \"delivered: the recipient confirmed it\"   // (mutant) ATT == delivered", "witness": "testW01OfflineThenAPeerThenTheAck", "why": "an ATT acceptance is SPOKEN to VoiceOver as a delivery, which is the most dangerous substitution on the whole surface: a screen-reader user would be told a message arrived that no recipient confirmed. The journey witness condemneth", "baseline": "green (the T58 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift, driven by the real MeshUXModel against a deterministic authority that projects statuses the way the durable repository would)", "kind": "functional"},
    {"id": "T58-RC4-secure-without-a-confirmed-key", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "swift_filter": "ReadinessT58Tests", "find": "    public var isSecure: Bool { selectedRecipient?.isVerified == true }", "replace": "    public var isSecure: Bool { selectedRecipient?.hasTrustedKey == true }   // (mutant) pinned counts", "witness": "testW11AnUnsupportedRadioIsExplainedDistinctly", "why": "a merely PINNED key is called secure, so a first-use contact whose key nobody compared standeth behind a security chip -- exactly what the card's second law forbiddeth. The unsupported/pinned witness condemneth", "baseline": "green (the T58 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift, driven by the real MeshUXModel against a deterministic authority that projects statuses the way the durable repository would)", "kind": "functional"},
    {"id": "T58-RC5-a-locked-store-claimeth-its-cache", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "swift_filter": "ReadinessT58Tests", "find": "            let lockedSelection = state.selectedRecipient.map {\n                RecipientProjection(nodeId: $0.nodeId, label: $0.label, trust: .unknown)\n            }", "replace": "            // (mutant) the locked store carrieth its previous trust verdict\n            let lockedSelection = state.selectedRecipient", "witness": "testW03ALockedDeviceClaimethNothing", "why": "a locked store carrieth its previous trust verdict, so the security chip could keep saying Secure behind the lock screen. The locked-device witness condemneth", "baseline": "green (the T58 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift, driven by the real MeshUXModel against a deterministic authority that projects statuses the way the durable repository would)", "kind": "functional"},
    {"id": "T58-RC6-a-locked-device-letteth-a-send-through", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "swift_filter": "ReadinessT58Tests", "find": "            default:\n                return project(lastOutcome: nil,\n                               error: \"the device is locked; unlock to review or send\")\n            }", "replace": "            default:\n                break   // (mutant) a locked device no longer stoppeth a mutating command\n            }", "witness": "testW03ALockedDeviceClaimethNothing", "why": "a mutating command reacheth the authority while the device is locked, so a send could half-apply behind the lock screen. The locked-device witness condemneth", "baseline": "green (the T58 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift, driven by the real MeshUXModel against a deterministic authority that projects statuses the way the durable repository would)", "kind": "functional"},
    {"id": "T58-RC7-the-compose-bound-is-characters", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "swift_filter": "ReadinessT58Tests", "find": "    public static func byteCount(_ body: String) -> Int {\n        body.utf8.count\n    }", "replace": "    public static func byteCount(_ body: String) -> Int {\n        body.count   // (mutant) characters, not UTF-8 bytes\n    }", "witness": "testW06TheComposeBoundIsBytesNotCharacters", "why": "the 400-byte budget is computed in CHARACTERS, so a 200-character CJK body (600 bytes) would pass and overflow the documented budget. The byte-bound witness condemneth", "baseline": "green (the T58 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift, driven by the real MeshUXModel against a deterministic authority that projects statuses the way the durable repository would)", "kind": "functional"},
    {"id": "T58-RC8-a-bare-confirm-placeth-a-call", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "swift_filter": "ReadinessT58Tests", "find": "        guard state.sosArmed else {\n            return withError(\"hold the SOS control to place a call\")\n        }", "replace": "        // (mutant) the arm is no longer required on this isle either", "witness": "testW07TheSosControlRequirethAnArm", "why": "a bare confirm placeth a distress call without the held gesture, so a stray tap can call for help. The held-control witness condemneth", "baseline": "green (the T58 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift, driven by the real MeshUXModel against a deterministic authority that projects statuses the way the durable repository would)", "kind": "functional"},
    {"id": "T58-RC9-cancel-implieth-recall", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "swift_filter": "ReadinessT58Tests", "find": "            ? \"Cancelling stops this phone retrying. Copies already handed to relays cannot be recalled.\"\n            : \"Cancelling stops this phone retrying. No copy has left this device yet.\"", "replace": "            ? \"Cancelling recalls every copy, including those already handed to relays.\"\n            : \"Cancelling recalls every copy.\"", "witness": "testW08CancelNamethTheRelayedCopyLimitation", "why": "the cancel claimeth that relayed copies can be recalled, which no radio can promise, and the limitation the card requireth be stated vanisheth. The cancel witness condemneth", "baseline": "green (the T58 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift, driven by the real MeshUXModel against a deterministic authority that projects statuses the way the durable repository would)", "kind": "functional"},
    {"id": "T58-RC10-a-duplicate-arrival-becometh-two-rows", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "swift_filter": "ReadinessT58Tests", "find": "messages: port().messages(),", "replace": "messages: port().messages() + port().messages(),   // (mutant) every row is projected twice", "witness": "testW04AnIncomingDuplicateIsOneRow", "why": "the projection duplicates inbound rows, so one arrival would be shown (and counted to VoiceOver) twice. The duplicate-arrival witness condemneth", "baseline": "green (the T58 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift, driven by the real MeshUXModel against a deterministic authority that projects statuses the way the durable repository would)", "kind": "functional"},
    {"id": "T58-RC11-a-denied-permission-is-not-explained", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "swift_filter": "ReadinessT58Tests", "find": "        case .permissionDenied:\n            return \"Godstone cannot reach the radio: the nearby-devices permission was denied. \"\n                + \"Messages stay queued until it is granted in Settings.\"", "replace": "        case .permissionDenied:\n            return \"Something went wrong.\"   // (mutant) no explanation", "witness": "testW10ADeniedPermissionIsExplained", "why": "a denied permission becometh an unexplained failure, so the user cannot tell a settings problem from a radio problem and cannot act on it. The permission witness condemneth", "baseline": "green (the T58 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift, driven by the real MeshUXModel against a deterministic authority that projects statuses the way the durable repository would)", "kind": "functional"},
    {"id": "T58-RC12-the-models-own-state-is-dropped", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "swift_filter": "ReadinessT58Tests", "find": "            selectedRecipient: selectedRecipient ?? state.selectedRecipient,\n            draft: draft ?? state.draft, draftBytes: draftBytes ?? state.draftBytes,", "replace": "            // (mutant) the model's own state is dropped: a lock or a relaunch\n            // silently discardeth the selection and the draft\n            selectedRecipient: nil,\n            draft: \"\", draftBytes: 0,", "witness": "testW03ALockedDeviceClaimethNothing", "why": "the model's own state (selection and draft) is dropped on every state copy, so a lock would silently discard what the user was doing -- the same defect class as the T57 SelectRecipient bug. The locked-device witness condemneth", "baseline": "green (the T58 court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift, driven by the real MeshUXModel against a deterministic authority that projects statuses the way the durable repository would)", "kind": "functional"},
    # ----------------------------------------------------------------------
    # T59 (s24-28): the platform capability matrix. The card's NAMED semantic
    #   negative is RC1/RC2: "Force iOS central based on platform or claim
    #   background availability independent of hint role: capability matrix test
    #   fails." Each rod striketh one resolver line and is witnessed by its OWN
    #   named case in tools/readiness/tests/test_t59.py.
    # ----------------------------------------------------------------------
    {"id": "T59-RC1-the-role-is-forced-from-the-platform", "platform": "python", "file": "tools/readiness/capabilities.py", "court": "tools/readiness/tests/test_t59.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t59.py", "find": "    background = _ALLOWED\n    if inputs.app_state is AppState.BACKGROUND:\n        if inputs.platform is Platform.IOS:", "replace": "    background = _ALLOWED\n    if inputs.app_state is AppState.BACKGROUND:\n        if inputs.platform is Platform.IOS and False:   # (mutant) the platform decideth", "witness": "test_w02_ios_central_is_never_forced_from_the_platform", "why": "the iOS background rule is switched off by PLATFORM alone, so a central-role iPhone would be told it may discover peripherals in the background -- the card's named negative in its FIRST limb, and the lie ADR-002 forbiddeth. The capability-matrix witness condemneth", "baseline": "green (the T59 court: 13 witnesses in tools/readiness/tests/test_t59.py, driven by the real capability matrix over this repository's own manifests, ADR and section 19)", "kind": "functional"},
    {"id": "T59-RC2-background-availability-ignores-the-hint", "platform": "python", "file": "tools/readiness/capabilities.py", "court": "tools/readiness/tests/test_t59.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t59.py", "find": "            if inputs.hint_role is HintRole.CENTRAL:\n                scan = _refuse(\n                    RefusalReason.IOS_BACKGROUND_CENTRAL_UNSUPPORTED,", "replace": "            if False:   # (mutant) the hint role no longer giveth the asymmetry\n                scan = _refuse(\n                    RefusalReason.IOS_BACKGROUND_CENTRAL_UNSUPPORTED,", "witness": "test_w03_background_availability_is_never_independent_of_the_hint", "why": "background availability becometh independent of the hint role: both orientations would be told the same thing, hiding iOS's asymmetry -- the card's named negative in its SECOND limb. The orientation witness condemneth", "baseline": "green (the T59 court: 13 witnesses in tools/readiness/tests/test_t59.py, driven by the real capability matrix over this repository's own manifests, ADR and section 19)", "kind": "functional"},
    {"id": "T59-RC3-a-permanently-denied-permission-is-requestable", "platform": "python", "file": "tools/readiness/capabilities.py", "court": "tools/readiness/tests/test_t59.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t59.py", "find": "    requestable = inputs.authorization in (Authorization.DENIED, Authorization.NOT_DETERMINED)", "replace": "    requestable = inputs.authorization is not Authorization.GRANTED   # (mutant) ask anyway", "witness": "test_w04_deny_permanent_deny_revoke_restore", "why": "a permanently-denied (or restricted) permission is treated as requestable, so the app would ask again and again for something only Settings can change. The permission witness condemneth", "baseline": "green (the T59 court: 13 witnesses in tools/readiness/tests/test_t59.py, driven by the real capability matrix over this repository's own manifests, ADR and section 19)", "kind": "functional"},
    {"id": "T59-RC4-a-locked-store-may-be-written", "platform": "python", "file": "tools/readiness/capabilities.py", "court": "tools/readiness/tests/test_t59.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t59.py", "find": "    keychain_write = _ALLOWED if inputs.protected_data is ProtectedData.AVAILABLE else _refuse(", "replace": "    keychain_write = _ALLOWED if True else _refuse(   # (mutant) the lock is ignored", "witness": "test_w09_a_locked_store_carrieth_no_custody_claim", "why": "the locked protected store is written anyway: a key could be persisted while the device is locked, which is the custody claim the card forbiddeth. The locked-store witness condemneth", "baseline": "green (the T59 court: 13 witnesses in tools/readiness/tests/test_t59.py, driven by the real capability matrix over this repository's own manifests, ADR and section 19)", "kind": "functional"},
    {"id": "T59-RC5-a-force-quit-promiseth-restoration", "platform": "python", "file": "tools/readiness/capabilities.py", "court": "tools/readiness/tests/test_t59.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t59.py", "find": "        if self.inputs.app_state is AppState.FORCE_QUIT:\n            return False\n        return self.inputs.platform is Platform.IOS", "replace": "        return self.inputs.platform is Platform.IOS   # (mutant) a force quit promiseth restoration", "witness": "test_w06_a_force_quit_is_unsupported", "why": "a FORCE-QUIT process is promised state restoration, which the platform refuseth: the documented lie this task existeth to remove. The force-quit witness condemneth", "baseline": "green (the T59 court: 13 witnesses in tools/readiness/tests/test_t59.py, driven by the real capability matrix over this repository's own manifests, ADR and section 19)", "kind": "functional"},
    {"id": "T59-RC6-a-force-quit-may-still-scan", "platform": "python", "file": "tools/readiness/capabilities.py", "court": "tools/readiness/tests/test_t59.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t59.py", "find": "    if inputs.app_state is AppState.FORCE_QUIT:\n        return _refuse(\n            RefusalReason.FORCE_QUIT_UNSUPPORTED,", "replace": "    if False:   # (mutant) a force-quit process may still reach the radio\n        return _refuse(\n            RefusalReason.FORCE_QUIT_UNSUPPORTED,", "witness": "test_w06_a_force_quit_is_unsupported", "why": "a force-quit process may reach the radio, so a screen could claim work is happening in an app the OS will not relaunch. The force-quit witness condemneth", "baseline": "green (the T59 court: 13 witnesses in tools/readiness/tests/test_t59.py, driven by the real capability matrix over this repository's own manifests, ADR and section 19)", "kind": "functional"},
    {"id": "T59-RC7-a-stopped-process-may-scan", "platform": "python", "file": "tools/readiness/capabilities.py", "court": "tools/readiness/tests/test_t59.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t59.py", "find": "    if inputs.app_state is AppState.STOPPED:\n        return _refuse(\n            RefusalReason.PROCESS_STOPPED,", "replace": "    if False:   # (mutant) a stopped process may still scan\n        return _refuse(\n            RefusalReason.PROCESS_STOPPED,", "witness": "test_w07_no_scan_from_a_stopped_state", "why": "a STOPPED process is allowed to scan, so the matrix would claim radio work from a state that carrieth none. The stopped-state witness condemneth", "baseline": "green (the T59 court: 13 witnesses in tools/readiness/tests/test_t59.py, driven by the real capability matrix over this repository's own manifests, ADR and section 19)", "kind": "functional"},
    {"id": "T59-RC8-an-unknown-power-state-guesseth", "platform": "python", "file": "tools/readiness/capabilities.py", "court": "tools/readiness/tests/test_t59.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t59.py", "find": "    if inputs.power is Power.UNKNOWN:\n        return _refuse(\n            RefusalReason.RADIO_POWER_UNKNOWN,", "replace": "    if False:   # (mutant) an UNKNOWN power state guesseth that the radio is on\n        return _refuse(\n            RefusalReason.RADIO_POWER_UNKNOWN,", "witness": "test_w05_the_power_toggle_refuseth_both_ways", "why": "an UNKNOWN radio power state is treated as ON, so the app would claim a capability it cannot verify. The power witness condemneth", "baseline": "green (the T59 court: 13 witnesses in tools/readiness/tests/test_t59.py, driven by the real capability matrix over this repository's own manifests, ADR and section 19)", "kind": "functional"},
    {"id": "T59-RC9-the-light-profile-claimeth-the-radio", "platform": "python", "file": "tools/readiness/capabilities.py", "court": "tools/readiness/tests/test_t59.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t59.py", "find": "    if inputs.profile is Profile.LIGHT:\n        return _refuse(\n            RefusalReason.PROFILE_CARRIES_NO_RADIO,", "replace": "    if False:   # (mutant) the LIGHT profile claimeth a radio it never declared\n        return _refuse(\n            RefusalReason.PROFILE_CARRIES_NO_RADIO,", "witness": "test_w10_the_light_profile_carrieth_no_radio_capability", "why": "the LIGHT Archive-only build claimeth a radio capability, though its manifest declares no Bluetooth permission at all -- a build that cannot ask claiming it can. The profile witness condemneth", "baseline": "green (the T59 court: 13 witnesses in tools/readiness/tests/test_t59.py, driven by the real capability matrix over this repository's own manifests, ADR and section 19)", "kind": "functional"},
    {"id": "T59-RC10-android-background-needeth-no-service", "platform": "python", "file": "tools/readiness/capabilities.py", "court": "tools/readiness/tests/test_t59.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t59.py", "find": "            if not inputs.android_foreground_service:\n                background = _refuse(\n                    RefusalReason.ANDROID_BACKGROUND_NEEDS_FOREGROUND_SERVICE,", "replace": "            if False:   # (mutant) Android background work needeth no foreground service\n                background = _refuse(\n                    RefusalReason.ANDROID_BACKGROUND_NEEDS_FOREGROUND_SERVICE,", "witness": "test_w08_android_background_needeth_its_foreground_service", "why": "Android is told background radio work is possible without the foreground service the platform requireth, so the app would be killed in the background while claiming to listen. The Android witness condemneth", "baseline": "green (the T59 court: 13 witnesses in tools/readiness/tests/test_t59.py, driven by the real capability matrix over this repository's own manifests, ADR and section 19)", "kind": "functional"},
    {"id": "T59-RC11-a-refusal-carrieth-no-reason", "platform": "python", "file": "tools/readiness/capabilities.py", "court": "tools/readiness/tests/test_t59.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t59.py", "find": "def _refuse(reason: RefusalReason, detail: str) -> Verdict:\n    return Verdict(False, reason, detail)", "replace": "def _refuse(reason: RefusalReason, detail: str) -> Verdict:\n    return Verdict(False, None, \"\")   # (mutant) a refusal sayeth nothing", "witness": "test_w13_the_matrix_is_total", "why": "every refusal loseth its typed reason, so a screen could not tell a denial from a stopped process and the court could not assert a refusal BY NAME. The totality witness condemneth", "baseline": "green (the T59 court: 13 witnesses in tools/readiness/tests/test_t59.py, driven by the real capability matrix over this repository's own manifests, ADR and section 19)", "kind": "functional"},
    {"id": "T59-RC12-the-hint-role-is-ignored-for-advertising", "platform": "python", "file": "tools/readiness/capabilities.py", "court": "tools/readiness/tests/test_t59.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t59.py", "find": "    advertise = _ALLOWED if role_allows(HintRole.PERIPHERAL) else _refuse(", "replace": "    advertise = _ALLOWED if True else _refuse(   # (mutant) everybody advertiseth", "witness": "test_w01_the_matrix_is_resolved_from_facts", "why": "every device advertiseth whatever the election's hint sayeth, so a CENTRAL would advertise and a peer could connect to a role it does not hold. The matrix witness condemneth", "baseline": "green (the T59 court: 13 witnesses in tools/readiness/tests/test_t59.py, driven by the real capability matrix over this repository's own manifests, ADR and section 19)", "kind": "functional"},
    # ----------------------------------------------------------------------
    # T60 (s24-28): the automated accessibility and restoration checks. The
    #   card's NAMED semantic negative is RC1/RC2: "Remove an essential control
    #   label or clip status at large text: UI/accessibility check fails." Each
    #   rod striketh one check on ONE lane and is witnessed by its OWN named case
    #   on that lane (python conductor, Android contract, iOS contract).
    # ----------------------------------------------------------------------
    {"id": "T60-RC1-a-label-less-essential-control-is-accepted", "platform": "python", "file": "tools/readiness/accessibility.py", "court": "tools/readiness/tests/test_t60.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t60.py", "find": "            if not node.label.strip():\n                return False, f\"{control_id}: the visible label is empty\"", "replace": "            if False:\n                return False, f\"{control_id}: the visible label is empty\"", "witness": "test_w03_an_essential_control_without_a_label_is_refused", "why": "an essential control with NO visible label is accepted -- the card's named negative in its first limb, and a control a screen-reader user cannot find. The label witness condemneth", "baseline": "green (the T60 python court: 13 witnesses in tools/readiness/tests/test_t60.py, driven by the real conductor)", "kind": "functional"},
    {"id": "T60-RC2-a-clipped-status-is-accepted-at-large-text", "platform": "python", "file": "tools/readiness/accessibility.py", "court": "tools/readiness/tests/test_t60.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t60.py", "find": "            if node.state_words and node.truncated:", "replace": "            if False and node.state_words:   # (mutant) a clipped status is accepted", "witness": "test_w04_a_clipped_status_is_refused_at_large_text", "why": "a status CLIPPED at the largest text scale is accepted -- the named negative's second limb, and the truncation of 'Delivered' into 'Deliv' is a false delivery claim. The clipping witness condemneth", "baseline": "green (the T60 python court: 13 witnesses in tools/readiness/tests/test_t60.py, driven by the real conductor)", "kind": "functional"},
    {"id": "T60-RC3-a-colour-only-state-is-accepted", "platform": "python", "file": "tools/readiness/accessibility.py", "court": "tools/readiness/tests/test_t60.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t60.py", "find": "            if node.colour_token and not node.state_words:", "replace": "            if False:   # (mutant) a colour with no words is accepted", "witness": "test_w05_no_colour_only_state", "why": "a state carrieth a colour token and NO words, so a screen reader would hear nothing about it and colour becometh the only channel. The colour witness condemneth", "baseline": "green (the T60 python court: 13 witnesses in tools/readiness/tests/test_t60.py, driven by the real conductor)", "kind": "functional"},
    {"id": "T60-RC4-a-undersized-target-is-accepted", "platform": "python", "file": "tools/readiness/accessibility.py", "court": "tools/readiness/tests/test_t60.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t60.py", "find": "            if node.touch_width < minimum or node.touch_height < minimum:", "replace": "            if False:   # (mutant) an undersized touch target is accepted", "witness": "test_w06_the_touch_target_minimums_differ_by_platform", "why": "a control below its platform's minimum touch target is accepted, so a motor-impaired user cannot reliably hit it. The target witness condemneth", "baseline": "green (the T60 python court: 13 witnesses in tools/readiness/tests/test_t60.py, driven by the real conductor)", "kind": "functional"},
    {"id": "T60-RC5-a-gapped-reading-order-is-accepted", "platform": "python", "file": "tools/readiness/accessibility.py", "court": "tools/readiness/tests/test_t60.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t60.py", "find": "        if sorted(orders) != list(range(len(orders))):", "replace": "        if False:   # (mutant) a gapped reading order is accepted", "witness": "test_w07_the_reading_order_is_contiguous_and_complete", "why": "a gap in the reading order is accepted, so a switch-navigation user cannot walk the essential controls in order. The order witness condemneth", "baseline": "green (the T60 python court: 13 witnesses in tools/readiness/tests/test_t60.py, driven by the real conductor)", "kind": "functional"},
    {"id": "T60-RC6-a-mirrored-meaning-is-accepted", "platform": "python", "file": "tools/readiness/accessibility.py", "court": "tools/readiness/tests/test_t60.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t60.py", "find": "            if node.mirrored and node.mirrors_meaning:", "replace": "            if False:   # (mutant) a mirrored MEANING is accepted in RTL", "witness": "test_w08_rtl_mirror_may_not_move_a_meaning", "why": "a directional control's MEANING mirrors with the RTL layout, so a send arrow would point the wrong way for the very user the mirror existeth for. The RTL witness condemneth", "baseline": "green (the T60 python court: 13 witnesses in tools/readiness/tests/test_t60.py, driven by the real conductor)", "kind": "functional"},
    {"id": "T60-RC7-a-clipped-long-content-label-is-accepted", "platform": "python", "file": "tools/readiness/accessibility.py", "court": "tools/readiness/tests/test_t60.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t60.py", "find": "            if node.truncated and node.control_id in ESSENTIAL_CONTROLS:", "replace": "            if False:   # (mutant) a clipped essential label is accepted", "witness": "test_w09_long_content_locale_fixtures_fit", "why": "a clipped essential label in a long-content locale is accepted, so a Finnish or German user loseth the control's name. The long-content witness condemneth", "baseline": "green (the T60 python court: 13 witnesses in tools/readiness/tests/test_t60.py, driven by the real conductor)", "kind": "functional"},
    {"id": "T60-RC8-android-a-label-less-control-is-accepted", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/a11y/AccessibilityContract.kt", "module": "mesh", "test_task": "testDebugUnitTest", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT60Test.kt", "gradle_filter": "*ReadinessT60Test*", "find": "            if (node.label.isBlank()) return Verdict.fail(\"$controlId: the visible label is empty\")", "replace": "            // (mutant) a label-less essential control is accepted on this isle", "witness": "test_w03_an_essential_control_without_a_label_is_refused", "why": "the Android isle accepteth a label-less essential control, so the named negative is closed on one isle and open on the other. The Android witness condemneth", "baseline": "green (the T60 Android court: 13 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT60Test.kt, driven by the real AccessibilityContract)", "kind": "functional"},
    {"id": "T60-RC9-android-a-clipped-status-is-accepted", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/a11y/AccessibilityContract.kt", "module": "mesh", "test_task": "testDebugUnitTest", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT60Test.kt", "gradle_filter": "*ReadinessT60Test*", "find": "            if (node.stateWords.isNotEmpty() && node.truncated) {", "replace": "            if (false) {   // (mutant) a clipped status is accepted on this isle", "witness": "test_w04_a_clipped_status_is_refused_at_large_text", "why": "the Android isle accepteth a status clipped at the largest text scale. The Android clipping witness condemneth", "baseline": "green (the T60 Android court: 13 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT60Test.kt, driven by the real AccessibilityContract)", "kind": "functional"},
    {"id": "T60-RC10-android-the-colour-channel-standeth-alone", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/a11y/AccessibilityContract.kt", "module": "mesh", "test_task": "testDebugUnitTest", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT60Test.kt", "gradle_filter": "*ReadinessT60Test*", "find": "            if (node.colourToken.isNotEmpty() && node.stateWords.isEmpty()) {", "replace": "            if (false) {   // (mutant) a colour with no words is accepted on this isle", "witness": "test_w05_no_colour_only_state", "why": "the Android isle accepteth a colour with no words, so colour becometh the only channel there. The Android colour witness condemneth", "baseline": "green (the T60 Android court: 13 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT60Test.kt, driven by the real AccessibilityContract)", "kind": "functional"},
    {"id": "T60-RC11-ios-a-clipped-status-is-accepted", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/AccessibilityContract.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT60Tests.swift", "swift_filter": "ReadinessT60Tests", "find": "        for node in nodes where !node.stateWords.isEmpty && node.truncated {", "replace": "        // (mutant) a status CLIPPED at the largest Dynamic Type size is accepted\n        for node in nodes where false && !node.stateWords.isEmpty && node.truncated {", "witness": "testW04AClippedStatusIsRefusedAtLargeText", "why": "the iOS isle accepteth a status clipped at the largest Dynamic Type size, so the named negative is closed on one isle and open on the other. The iOS clipping witness condemneth", "baseline": "green (the T60 iOS court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT60Tests.swift, driven by the real AccessibilityContract)", "kind": "functional"},
    {"id": "T60-RC12-ios-the-touch-target-minimum-vanish", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/AccessibilityContract.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT60Tests.swift", "swift_filter": "ReadinessT60Tests", "find": "        for node in nodes where node.role != .staticText {", "replace": "        // (mutant) no touch target is too small on this isle\n        for node in nodes where false && node.role != .staticText {", "witness": "testW06TheTouchTargetMinimumsDifferByPlatform", "why": "the iOS isle accepteth any touch target, so a control below 44pt would pass on the isle that requireth it most. The iOS target witness condemneth", "baseline": "green (the T60 iOS court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT60Tests.swift, driven by the real AccessibilityContract)", "kind": "functional"},
    # ----------------------------------------------------------------------
    # T67 (s24-28): the FIVE PRODUCTION-PATH CONTROLS the card requireth --
    #   lifetime bypass, pre-auth replay commit, ACK-before-persist, plaintext
    #   fallback and stale status evidence -- each struck on the REAL authority
    #   and witnessed by an existing court case (T84, T37, T35, T53).
    # ----------------------------------------------------------------------
    {"id": "T67-C1-lifetime-bypass-an-expired-candidate-standeth", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/AckObligationStore.kt", "module": "mesh", "test_task": "testDebugUnitTest", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT84Test.kt", "gradle_filter": "*ReadinessT84Test*", "find": "            if (remainingLifetimeMs >= cur.remainingLifetimeMs) return@synchronized false", "replace": "            // (mutant) the non-replenishing guard is BYPASSED: an equal or greater\n            // lifetime is accepted, so a restart or a duplicate could EXTEND a life\n            if (false) return@synchronized false", "witness": "test_w10_relay_process_death_and_reconnect_still_returneth_the_receipt", "why": "the non-replenishing lifetime guard is bypassed: an equal or greater debited lifetime is accepted, so a restart or a duplicate could EXTEND a relay candidate's life -- the lifetime-bypass control the card requireth. The T84 relay-process-death witness (which re-reads the candidate after a restart) condemneth it", "baseline": "green (the T84 court: 14 witnesses)", "kind": "functional"},
    {"id": "T67-C2-pre-auth-replay-commit", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/AckObligationStore.kt", "module": "mesh", "test_task": "testDebugUnitTest", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT84Test.kt", "gradle_filter": "*ReadinessT84Test*", "find": "            if (!ok) return AckAdmissionResult.RefusedKnownInvalid\n            AckVerificationClass.VERIFIED_RECIPIENT", "replace": "            // (mutant) the candidate entereth the replay namespace BEFORE its origin\n            // is authenticated: a forged ACK's key would occupy the slot first\n            AckVerificationClass.VERIFIED_RECIPIENT", "witness": "test_w09_a_forged_candidate_cannot_suppress_a_later_valid_signature", "why": "a candidate with a BAD signature is committed rather than refused, so a forged ACK's cache key occupieth the replay slot and the genuine answer is suppressed -- the pre-auth replay commit the card requireth. The T84 forged-candidate witness condemneth", "baseline": "green (the T84 court: 14 witnesses)", "kind": "functional"},
    {"id": "T67-C3-ack-offered-before-the-persist", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/delivery/RecipientInboxRepository.kt", "module": "mesh", "test_task": "testDebugUnitTest", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT37Test.kt", "gradle_filter": "*ReadinessT37Test*", "find": "        when (commitOutcome) {\n            is InboundCommitResult.Committed -> {}\n            InboundCommitResult.RejectedCapacity ->\n                return InboxCommitResult.Rejected(RejectionReason.CAPACITY)\n            InboundCommitResult.StorageFailure ->\n                return refuseStorage(\"inbox commit\")\n            InboundCommitResult.InvalidArgument ->\n                return InboxCommitResult.Rejected(RejectionReason.WIDTHS, \"commit args\")\n        }\n        if (commitOutcome !is InboundCommitResult.Committed) {\n            // unreachable while the taxonomy is closed; defensive, never silent\n            return InboxCommitResult.Rejected(RejectionReason.STORAGE_FAILURE, \"commit outcome vanished\")\n        }", "replace": "        // (mutant) the commit outcome is DISCARDED: the ACK road is entered even\n        // when the durable commit REFUSED, so a receipt would claim a custody this\n        // node never held -- the ACK-before-persist control the card requireth\n        return issueOrRestoreAck(frame, receivedFrom,\n            commitOutcome as InboundCommitResult.Committed, fault)", "witness": "testDiskFailureYieldsNeitherAckNorClaimedAcceptance", "why": "the ACK is issued on the SAME road whether or not the durable commit landed (the refusal arms above are removed), so a sender would be told the recipient received a message no durable row ever held -- the ACK-before-persist control the card requireth. The T37 disk-failure witness condemneth", "baseline": "green (the T37 court)", "kind": "functional"},
    {"id": "T67-C4-plaintext-fallback-accepted", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/wire/v2/SignedMessageV1.kt", "module": "mesh", "test_task": "testDebugUnitTest", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT35Test.kt", "gradle_filter": "*ReadinessT35Test*", "find": "        if (signedPlaintext[i].toInt() and 0xFF != VERSION) return SenderVerificationResult.Invalid(\"unknown version; there is no legacy plaintext fallback\")", "replace": "        // (mutant) an UNKNOWN version is accepted: a legacy plaintext fallback\n        if (false) return SenderVerificationResult.Invalid(\"unknown version; there is no legacy plaintext fallback\")", "witness": "testMalformedLengthAndUtf8RejectedFailClosed", "why": "a payload of an UNKNOWN version is accepted, which is the legacy plaintext fallback the frozen sender law forbiddeth: an attacker could present unsigned bytes as a message. The T35 witness condemneth", "baseline": "green (the T35 court)", "kind": "functional"},
    {"id": "T67-C5-stale-status-evidence-accepted", "platform": "python", "file": "ci/check_release_gates_status.py", "court": "tools/readiness/tests/test_t53.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t53.py", "find": "                elif is_ancestor(ev):\n                    classification = \"ancestor-historical\"", "replace": "                elif True:   # (mutant) the ancestor check is bypassed: a stale head is\n                    # accepted as current evidence\n                    classification = \"ancestor-historical\"", "witness": "testStaleEvidenceDothNotResolve", "why": "a recorded head that is NOT an ancestor is classified as historical evidence anyway, so a stale BUILD_STATE could vouch for a boundary the repository never had -- the stale status evidence control the card requireth. The T53 stale-evidence witness condemneth", "baseline": "green (the T53 court: 19 witnesses)", "kind": "functional"},
    # ----------------------------------------------------------------------
    # T71 (s24-28): bounded diagnostics without private telemetry. The card's
    #   NAMED semantic negative is RC1/RC3: "Log a message body or allow
    #   diagnostic ring growth unbounded: privacy/resource test fails." Each rod
    #   striketh one recorder line on ONE lane and is witnessed by its OWN named
    #   case (python conductor, Android twin, iOS twin).
    # ----------------------------------------------------------------------
    {"id": "T71-RC1-a-message-body-is-logged-as-a-metric", "platform": "python", "file": "tools/readiness/diagnostics.py", "court": "tools/readiness/tests/test_t71.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t71.py", "find": "        if not isinstance(metric, str) or metric not in METRIC_NAMES:", "replace": "        if not isinstance(metric, str):   # (mutant) any string may name a metric", "witness": "test_w02_a_body_or_a_key_is_refused_by_name", "why": "the vocabulary is OPEN, so a message body offered as a metric name is logged -- the card's named negative in its first limb, and a direct privacy leak. The refusal witness condemneth", "baseline": "green (the T71 python court: 13 witnesses in tools/readiness/tests/test_t71.py, driven by the real conductor)", "kind": "functional"},
    {"id": "T71-RC2-a-string-value-is-logged", "platform": "python", "file": "tools/readiness/diagnostics.py", "court": "tools/readiness/tests/test_t71.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t71.py", "find": "        raise DiagnosticsRefusal(\n            \"a diagnostic value must be a number; %r is a %s, and a string is exactly how a \"\n            \"message body or a key fragment would enter the log\" % (value, type(value).__name__))", "replace": "        # (mutant) a non-number value is stringified into the log\n        return min(len(str(value)), COUNTER_CEILING)", "witness": "test_w10_redaction_is_by_refusal", "why": "a string, a byte string or a list is stringified INTO the log rather than refused, which is exactly how a key fragment or a body would enter it. The redaction witness condemneth", "baseline": "green (the T71 python court: 13 witnesses in tools/readiness/tests/test_t71.py, driven by the real conductor)", "kind": "functional"},
    {"id": "T71-RC3-the-ring-groweth-unbounded", "platform": "python", "file": "tools/readiness/diagnostics.py", "court": "tools/readiness/tests/test_t71.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t71.py", "find": "        if len(self.lines) >= self.capacity:\n            self.lines.pop(0)                          # drop-oldest, and COUNT it\n            self.superseded += 1", "replace": "        # (mutant) the ring is unbounded: a flood groweth memory without limit", "witness": "test_w03_the_ring_is_bounded_and_drop_oldest_is_counted", "why": "the ring is unbounded, so a queue flood would grow memory without limit -- the card's named negative in its second limb. The bounded-ring witness condemneth", "baseline": "green (the T71 python court: 13 witnesses in tools/readiness/tests/test_t71.py, driven by the real conductor)", "kind": "functional"},
    {"id": "T71-RC4-the-counter-ceiling-is-gone", "platform": "python", "file": "tools/readiness/diagnostics.py", "court": "tools/readiness/tests/test_t71.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t71.py", "find": "            return max(0, min(value, COUNTER_CEILING))", "replace": "            return max(0, value)   # (mutant) a counter may grow past its ceiling", "witness": "test_w04_counters_saturate_and_gauges_never_go_negative", "why": "a counter is no longer saturating, so a flood could overflow into nonsense. The saturating-counter witness condemneth", "baseline": "green (the T71 python court: 13 witnesses in tools/readiness/tests/test_t71.py, driven by the real conductor)", "kind": "functional"},
    {"id": "T71-RC5-a-wall-clock-date-is-recorded", "platform": "python", "file": "tools/readiness/diagnostics.py", "court": "tools/readiness/tests/test_t71.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t71.py", "find": "    def render(self) -> str:\n        \"\"\"The whole output, as it would be written. THE ONLY ROAD OUT.\"\"\"\n        header = \"diagnostics mode=%s lines=%d superseded=%d refusals=%d\\n\" % (\n            self.mode, self.ring_size, self.superseded, self.refusals)", "replace": "    def render(self) -> str:\n        \"\"\"(mutant) the output carrieth a WALL-CLOCK date, so logs correlate by time\"\"\"\n        header = \"diagnostics mode=%s lines=%d superseded=%d refusals=%d at=2026-09-15T00:00:00Z epoch=1757894400\\n\" % (\n            self.mode, self.ring_size, self.superseded, self.refusals)", "witness": "test_w05_durations_are_monotonic_microseconds", "why": "a wall-clock date and an epoch second enter the output, so two logs recorded on two devices could be correlated by time -- the tracking the card forbiddeth. The monotonic-duration witness condemneth", "baseline": "green (the T71 python court: 13 witnesses in tools/readiness/tests/test_t71.py, driven by the real conductor)", "kind": "functional"},
    {"id": "T71-RC6-a-peer-key-becometh-the-relation-id", "platform": "python", "file": "tools/readiness/diagnostics.py", "court": "tools/readiness/tests/test_t71.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t71.py", "find": "            self._relation_by_key[key] = \"r%d\" % self._relation_seq", "replace": "            return str(key)   # (mutant) the caller KEY itself becometh the relation id", "witness": "test_w06_relation_ids_are_ephemeral_and_opaque", "why": "the relation id becometh the caller's own key, so a peer's identifier would be written into every line and persist across runs -- neither ephemeral nor opaque. The ephemeral-id witness condemneth", "baseline": "green (the T71 python court: 13 witnesses in tools/readiness/tests/test_t71.py, driven by the real conductor)", "kind": "functional"},
    {"id": "T71-RC7-the-recorder-counteth-while-off", "platform": "python", "file": "tools/readiness/diagnostics.py", "court": "tools/readiness/tests/test_t71.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t71.py", "find": "        if not self.is_on:\n            return 0                                  # OFF recordeth nothing at all", "replace": "        if False:\n            return 0   # (mutant) the recorder counteth even while OFF", "witness": "test_w01_the_recorder_is_opt_in", "why": "the recorder counteth and ringeth while OFF, so a build that was never asked for diagnostics carrieth them anyway. The opt-in witness condemneth", "baseline": "green (the T71 python court: 13 witnesses in tools/readiness/tests/test_t71.py, driven by the real conductor)", "kind": "functional"},
    {"id": "T71-RC8-android-the-body-is-logged", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/diag/Diagnostics.kt", "module": "mesh", "test_task": "testDebugUnitTest", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT71Test.kt", "gradle_filter": "*ReadinessT71Test*", "find": "        if (metric == null || metric !in METRIC_NAMES) {", "replace": "        // (mutant) the VOCABULARY is not checked on this isle: any string\n        // may name a metric, so a message body is logged\n        if (metric == null) {", "witness": "test_w02_a_body_or_a_key_is_refused_by_name", "why": "the Android isle accepteth any string as a metric name, so a message body is logged there -- the named negative closed on one isle and open on the other. The Android refusal witness condemneth", "baseline": "green (the T71 Android court: 13 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT71Test.kt, driven by io.godstone.mesh.diag.Diagnostics)", "kind": "functional"},
    {"id": "T71-RC9-android-the-ring-groweth-unbounded", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/diag/Diagnostics.kt", "module": "mesh", "test_task": "testDebugUnitTest", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT71Test.kt", "gradle_filter": "*ReadinessT71Test*", "find": "        if (lines.size >= capacity) {\n            lines.removeFirst()          // drop-oldest, and COUNT it\n            superseded++\n        }", "replace": "        // (mutant) the ring is unbounded on this isle", "witness": "test_w03_the_ring_is_bounded_and_drop_oldest_is_counted", "why": "the Android ring is unbounded, so a flood groweth memory without limit there. The Android bounded-ring witness condemneth", "baseline": "green (the T71 Android court: 13 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT71Test.kt, driven by io.godstone.mesh.diag.Diagnostics)", "kind": "functional"},
    {"id": "T71-RC10-android-the-value-is-stringified", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/diag/Diagnostics.kt", "module": "mesh", "test_task": "testDebugUnitTest", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT71Test.kt", "gradle_filter": "*ReadinessT71Test*", "find": "            else -> throw DiagnosticsRefusal(\n                \"a diagnostic value must be a number; '${value?.let { it::class.simpleName }}' is \" +\n                    \"exactly how a message body or a key fragment would enter the log\")", "replace": "            // (mutant) a non-number value is accepted as a count on this isle\n            else -> 1L", "witness": "test_w10_redaction_is_by_refusal", "why": "a non-number value is accepted instead of refused on the Android isle, so a key fragment would enter the log. The Android redaction witness condemneth", "baseline": "green (the T71 Android court: 13 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT71Test.kt, driven by io.godstone.mesh.diag.Diagnostics)", "kind": "functional"},
    {"id": "T71-RC11-ios-the-ring-groweth-unbounded", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/Diagnostics.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT71Tests.swift", "swift_filter": "ReadinessT71Tests", "find": "        if lines.count >= capacity {\n            lines.removeFirst()                     // drop-oldest, and COUNT it\n            superseded += 1\n        }", "replace": "        // (mutant) the ring is unbounded on this isle", "witness": "testW03TheRingIsBoundedAndDropOldestIsCounted", "why": "the iOS ring is unbounded, so a flood groweth memory without limit there. The iOS bounded-ring witness condemneth", "baseline": "green (the T71 iOS court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT71Tests.swift, driven by the Swift twin)", "kind": "functional"},
    {"id": "T71-RC12-ios-the-epoch-entereth-the-output", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/Diagnostics.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT71Tests.swift", "swift_filter": "ReadinessT71Tests", "find": "        let header = \"diagnostics mode=\\(mode.rawValue) lines=\\(lines.count) \"\n            + \"superseded=\\(superseded) refusals=\\(refusals)\"", "replace": "        // (mutant) a wall-clock date and epoch second enter the output\n        let header = \"diagnostics mode=\\(mode.rawValue) lines=\\(lines.count) \"\n            + \"superseded=\\(superseded) refusals=\\(refusals) at=2026-09-15T00:00:00Z epoch=1757894400\"", "witness": "testW05DurationsAreMonotonicMicroseconds", "why": "a wall-clock date and an epoch second enter the iOS output, so logs could be correlated by time. The iOS monotonic-duration witness condemneth", "baseline": "green (the T71 iOS court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT71Tests.swift, driven by the Swift twin)", "kind": "functional"},
    # ----------------------------------------------------------------------
    # T72 (s24-28): the production-path stress and deterministic fault campaigns.
    #   The card's NAMED semantic negative is RC1/RC2: "Disable one capacity
    #   release or retry cap: stress invariant fails." Each rod striketh one
    #   campaign line on ONE lane and is witnessed by its OWN named case.
    # ----------------------------------------------------------------------
    {"id": "T72-RC1-the-shutdown-releaseth-no-lease", "platform": "python", "file": "tools/readiness/stress.py", "court": "tools/readiness/tests/test_t72.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t72.py", "find": "        if self.defect == CampaignDefect.NO_LEASE_RELEASE:\n            return\n        if self.defect != CampaignDefect.NO_TIMER_RELEASE:\n            self.timers = 0\n        if self.defect != CampaignDefect.NO_SESSION_RELEASE:\n            self.sessions = 0\n        self.leases = 0", "replace": "        # (mutant) shutdown releaseth NOTHING: every owned resource leaketh\n        return", "witness": "test_w02_zero_leaked_leases_timers_sessions_after_shutdown", "why": "shutdown no longer releaseth the leases, timers or sessions it owned, so every campaign would leak its capacity -- the card's named negative in its first limb. The leak witness condemneth", "baseline": "green (the T72 python court: 13 witnesses in tools/readiness/tests/test_t72.py, driven by the real conductor: 10k cycles pass, and each of the five defects is caught)", "kind": "functional"},
    {"id": "T72-RC2-the-retry-cap-is-disabled", "platform": "python", "file": "tools/readiness/stress.py", "court": "tools/readiness/tests/test_t72.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t72.py", "find": "        if self.defect == CampaignDefect.NO_RETRY_CAP or used < RETRY_CAP:", "replace": "        if True:   # (mutant) the retry cap is disabled: retries grow without bound", "witness": "test_w04_no_duplicate_delivery_under_the_retry_cap", "why": "the retry cap is disabled, so a delivery row is advanced without limit -- the card's named negative in its second limb. The retry-cap witness condemneth", "baseline": "green (the T72 python court: 13 witnesses in tools/readiness/tests/test_t72.py, driven by the real conductor: 10k cycles pass, and each of the five defects is caught)", "kind": "functional"},
    {"id": "T72-RC3-the-inbox-dedup-is-asleep", "platform": "python", "file": "tools/readiness/stress.py", "court": "tools/readiness/tests/test_t72.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t72.py", "find": "        if self.defect == CampaignDefect.NO_DEDUP or msg not in self.inbox:", "replace": "        if True:   # (mutant) dedup is asleep: one msg_id entereth the inbox many times", "witness": "test_w03_no_duplicate_inbox_row", "why": "the inbox dedup is asleep, so one msg_id entereth the inbox as many times as it arriveth -- a duplicate delivery the card forbiddeth. The dedup witness condemneth", "baseline": "green (the T72 python court: 13 witnesses in tools/readiness/tests/test_t72.py, driven by the real conductor: 10k cycles pass, and each of the five defects is caught)", "kind": "functional"},
    {"id": "T72-RC4-malformed-input-escapeth-the-loop", "platform": "python", "file": "tools/readiness/stress.py", "court": "tools/readiness/tests/test_t72.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t72.py", "find": "            if self.defect == CampaignDefect.MALFORMED_ESCAPES:\n                raise ValueError(\"the malformed record escaped the loop\")", "replace": "            # (mutant) a malformed record throweth out of the loop, uncaught\n            raise ValueError(\"the malformed record escaped the loop\")", "witness": "test_w05_no_uncaught_malformed_input", "why": "a malformed record throweth out of the lifecycle loop, so malformed input would kill a campaign rather than being refused and counted. The malformed-input witness condemneth", "baseline": "green (the T72 python court: 13 witnesses in tools/readiness/tests/test_t72.py, driven by the real conductor: 10k cycles pass, and each of the five defects is caught)", "kind": "functional"},
    {"id": "T72-RC5-the-census-groweth-with-the-cycles", "platform": "python", "file": "tools/readiness/stress.py", "court": "tools/readiness/tests/test_t72.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t72.py", "find": "        if self.defect == CampaignDefect.UNBOUNDED_CENSUS or self.leases < LEASE_CAPACITY:\n            self.leases += 1\n        if not in_flight and self.defect not in (CampaignDefect.NO_LEASE_RELEASE,\n                                                CampaignDefect.UNBOUNDED_CENSUS):\n            self.leases = max(0, self.leases - 1)", "replace": "        # (mutant) the CAPACITY and the RELEASE are both gone: the live census\n        # groweth with the CYCLE COUNT and never plateaueth\n        self.leases += 1", "witness": "test_w06_the_census_plateau_is_a_structural_formula", "why": "the lease capacity AND the per-cycle release are both removed, so the live census groweth with the CYCLE COUNT and never plateaueth -- the resource bound the card requireth. The plateau witness condemneth. (The campaign taught that a RELEASE-ONLY defect cannot grow the census: the capacity boundeth it, which is a finding about WHERE the plateau cometh from.)", "baseline": "green (the T72 python court: 13 witnesses in tools/readiness/tests/test_t72.py, driven by the real conductor: 10k cycles pass, and each of the five defects is caught)", "kind": "functional"},
    {"id": "T72-RC6-the-seed-no-longer-determineth-the-trace", "platform": "python", "file": "tools/readiness/stress.py", "court": "tools/readiness/tests/test_t72.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t72.py", "find": "        self.rng = random.Random(seed)", "replace": "        self.rng = random.Random()   # (mutant) the seed no longer determineth the trace", "witness": "test_w10_a_failed_seed_is_recorded_and_reproducible", "why": "the campaign no longer seedeth its generator, so a red run cannot be replayed and the failure is a rumour rather than evidence. The reproducible-seed witness condemneth", "baseline": "green (the T72 python court: 13 witnesses in tools/readiness/tests/test_t72.py, driven by the real conductor: 10k cycles pass, and each of the five defects is caught)", "kind": "functional"},
    {"id": "T72-RC7-the-fault-schedule-is-ignored", "platform": "python", "file": "tools/readiness/stress.py", "court": "tools/readiness/tests/test_t72.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t72.py", "find": "        for fault in self.schedule.at(step):\n            self.apply(fault)", "replace": "        pass   # (mutant) the fault schedule is never applied", "witness": "test_w08_the_five_faults_are_applied_at_their_steps", "why": "the fault schedule is never applied, so the campaign would report a clean run while exercising NO fault at all -- the adapter failure modes it existeth to cover. The fault witness condemneth", "baseline": "green (the T72 python court: 13 witnesses in tools/readiness/tests/test_t72.py, driven by the real conductor: 10k cycles pass, and each of the five defects is caught)", "kind": "functional"},
    {"id": "T72-RC8-android-the-shutdown-releaseth-nothing", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/stress/StressCampaign.kt", "module": "mesh", "test_task": "testDebugUnitTest", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT72Test.kt", "gradle_filter": "*ReadinessT72Test*", "find": "        if (defect == CampaignDefect.NO_LEASE_RELEASE) return\n        if (defect != CampaignDefect.NO_TIMER_RELEASE) timers = 0\n        if (defect != CampaignDefect.NO_SESSION_RELEASE) sessions = 0\n        leases = 0", "replace": "        // (mutant) shutdown releaseth NOTHING on this isle\n        return", "witness": "test_w02_zero_leaks_after_shutdown", "why": "the Android isle's shutdown releaseth nothing, so every campaign leaketh its capacity there. The Android leak witness condemneth", "baseline": "green (the T72 Android court: 13 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT72Test.kt, driven by io.godstone.mesh.stress.StressCampaign)", "kind": "functional"},
    {"id": "T72-RC9-android-the-retry-cap-is-disabled", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/stress/StressCampaign.kt", "module": "mesh", "test_task": "testDebugUnitTest", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT72Test.kt", "gradle_filter": "*ReadinessT72Test*", "find": "        if (defect == CampaignDefect.NO_RETRY_CAP || used < RETRY_CAP) {", "replace": "        if (true) {   // (mutant) the retry cap is disabled on this isle", "witness": "test_w04_no_duplicate_delivery_under_the_retry_cap", "why": "the Android retry cap is disabled, so a delivery row advances without limit there. The Android retry witness condemneth", "baseline": "green (the T72 Android court: 13 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT72Test.kt, driven by io.godstone.mesh.stress.StressCampaign)", "kind": "functional"},
    {"id": "T72-RC10-android-the-inbox-dedup-is-asleep", "platform": "jvm", "file": "android/mesh/src/main/java/io/godstone/mesh/stress/StressCampaign.kt", "module": "mesh", "test_task": "testDebugUnitTest", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT72Test.kt", "gradle_filter": "*ReadinessT72Test*", "find": "        if (defect == CampaignDefect.NO_DEDUP || !inbox.containsKey(msg)) {", "replace": "        if (true) {   // (mutant) dedup is asleep on this isle", "witness": "test_w03_no_duplicate_inbox_row", "why": "the Android inbox dedup is asleep, so one msg_id entereth the inbox many times there. The Android dedup witness condemneth", "baseline": "green (the T72 Android court: 13 witnesses in android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT72Test.kt, driven by io.godstone.mesh.stress.StressCampaign)", "kind": "functional"},
    {"id": "T72-RC11-ios-the-shutdown-releaseth-nothing", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/StressCampaign.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT72Tests.swift", "swift_filter": "ReadinessT72Tests", "find": "        if defect == CampaignDefect.noLeaseRelease { return }\n        if defect != CampaignDefect.noTimerRelease { timers = 0 }\n        if defect != CampaignDefect.noSessionRelease { sessions = 0 }\n        leases = 0", "replace": "        // (mutant) shutdown releaseth NOTHING on this isle\n        return", "witness": "testW02ZeroLeaksAfterShutdown", "why": "the iOS isle's shutdown releaseth nothing, so every campaign leaketh its capacity there. The iOS leak witness condemneth", "baseline": "green (the T72 iOS court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT72Tests.swift, driven by the Swift twin)", "kind": "functional"},
    {"id": "T72-RC12-ios-the-retry-cap-is-disabled", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/StressCampaign.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT72Tests.swift", "swift_filter": "ReadinessT72Tests", "find": "        if defect == CampaignDefect.noRetryCap || used < StressCampaign.retryCap {", "replace": "        if true {   // (mutant) the retry cap is disabled on this isle", "witness": "testW04NoDuplicateDeliveryUnderTheRetryCap", "why": "the iOS retry cap is disabled, so a delivery row advances without limit there. The iOS retry witness condemneth", "baseline": "green (the T72 iOS court: 13 witnesses in ios/Godstone/Tests/GodstoneMeshTests/ReadinessT72Tests.swift, driven by the Swift twin)", "kind": "functional"},
    # ----------------------------------------------------------------------
    # GS-FINAL-003 `zero-private-opens` (Board 1): the ANDROID CONSTRUCTION COUNTERS.
    #   *THE OBLIGATION'S OWN WORDS ASK FOR "PROVEN AT THE REAL CONSTRUCTION
    #   SEAMS WITH COUNTERS", so the rods strike THE COUNTER CALLS themselves
    #   rather than the decision or the permit -- both of which had arms before
    #   this obligation was written, and neither of which is the clause.*
    # ----------------------------------------------------------------------
    {"id": "T72-RC13-android-private-construction-uncounted", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003ZeroPrivateOpensTest.kt", "gradle_filter": "*GsFinal003ZeroPrivateOpensTest*", "find": "        PrivateConstructionCounter.noteAttempt(PrivateConstructionCounter.Seam.IDENTITY, permit.issuedFrom)\n        return Identity.loadOrCreate(ctx, ownerToken)", "replace": "        // (mutant) the identity construction is NOT counted at the seam\n        return Identity.loadOrCreate(ctx, ownerToken)", "witness": "thePermittedRoadCountsOneAttemptPerSeamAtThePlatform", "why": "unchanged law, re-anchored to the CURRENT source: the same production guard, struck byte-exact (the permit is now consumed as a parameter and the member renamed, but the law is the same)."},
    {"id": "T72-RC14-android-permit-door-staleness-disabled", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003PrePrivateRecoveryGraphTest.kt", "gradle_filter": "*GsFinal003PrePrivateRecoveryGraphTest*", "find": "        if (evidence.estateRevision == currentRevision) PrivateStorePermit.issue(evidence) else null", "replace": "        PrivateStorePermit.issue(evidence)", "witness": "aPermitIsWithheldWhenTheDurableEstateMoved", "why": "unchanged law, re-anchored to the CURRENT source: the same production guard, struck byte-exact (the permit is now consumed as a parameter and the member renamed, but the law is the same)."},
    # ----------------------------------------------------------------------
    # GS-RUNTIME-001 `mutations` (Board 1): the ANDROID RUNTIME-OWNERSHIP WIRING.
    #   *Each rod deleteth ONE owner assignment from the production provider and
    #   requires the arm that observes THAT owner through a foreign consumer.*
    # ----------------------------------------------------------------------
    {"id": "T72-RC15-android-ack-pump-not-handed-to-the-node", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003GraphComponentTest.kt", "gradle_filter": "*GsFinal003GraphComponentTest*", "find": "        node.ackPump = pump\n", "replace": "        // (mutant) the pump is manufactured and injected and handed to nobody\n", "witness": "theProductionProviderHandsTheNodeThePumpItWasGiven", "why": "the production provider manufactureth and receiveth the pump and handeth it to nobody, so the node's own dispatcher has no durable ACK road. The pump-identity witness condemneth.", "baseline": "green (the GS-FINAL-003 graph component court in android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003GraphComponentTest.kt)", "kind": "semantic"},
    {"id": "T72-RC16-android-ack-dispatcher-admits-elsewhere", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003GraphComponentTest.kt", "gradle_filter": "*GsFinal003GraphComponentTest*", "find": "            admitCandidate = { encoded, from -> pump.admit(encoded, from) },", "replace": "            admitCandidate = { encoded, from -> pump.admit(encoded.reversedArray(), from) },", "witness": "theDispatcherAdmitsThroughTheGivenPumpOnly", "why": "the dispatcher's admission closure handeth the pump DIFFERENT BYTES than the frame the node received, so the custody the real pump anchors belongs to a candidate nobody sent -- the route is nominally the given pump and reaches it with the wrong material, which a same-object assertion could not see. The admission-identity witness condemneth.", "baseline": "green (the GS-FINAL-003 graph component court, driven over real on-disk stores)", "kind": "semantic"},
    # ----------------------------------------------------------------------
    # GS-STORE-002 / GS-FINAL-004 `native-engine-half` (Board 1): the ENGINE ADAPTER.
    #   *The rod makes the engine CLAIM at-rest without running the cipher probe --
    #   the "an enum value called pinnedSQLCipher is not engine verification"
    #   defect, in code rather than in a name.*
    # ----------------------------------------------------------------------
    {"id": "T72-RC17-ios-engine-claims-pinned-without-binding", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/SqlCipherDylibEngine.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT30Tests.swift", "swift_filter": "ReadinessT30Tests", "find": "    public var kind: StoreEngineKind { (isBound && !isArbitraryPath) ? .pinnedSQLCipher : .plainSQLite }", "replace": "    public var kind: StoreEngineKind { isBound ? .pinnedSQLCipher : .plainSQLite }", "witness": "testTheDylibEngineReportethPlainWhenThePinnedLibraryIsAbsent", "why": "re-anchored: the engine's own pinned/plain claim stops discriminating the ARBITRARY path, so a dylib bound at a non-canonical path still claims pinned SQLCipher. Same guard, byte-exact against today's source."},
    # ----------------------------------------------------------------------
    # GS-INTEGRATION-001 (Board 1): the REAL-TRANSPORT RIG and the ingress fix.
    #   *RC18 makes the transport ingest NOTHING (the delegate wiring deleted);
    #   RC19 makes the egress a SILENT NO-OP; RC20 restores the empty-`receivedFrom`
    #   defect; RC21 makes the wipe gate always open.*
    # ----------------------------------------------------------------------
    {"id": "T72-RC18-ios-transport-ingest-unwired", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsIntegration001ScenarioTests.swift", "swift_filter": "GsIntegration001ScenarioTests", "find": "                            if let ingressSender {\n                                self.delegate?.transportDidReceive(data: clear, peerId: centralId,\n                                                                  receivedFrom: ingressSender)", "replace": "                            if false, let ingressSender {\n                                self.delegate?.transportDidReceive(data: clear, peerId: centralId,\n                                                                  receivedFrom: ingressSender)", "witness": "testARBEstablishesOverOSFacadesOnlyThenDeliversADirectFrameAndTheRecipientAck", "why": "the responder's ingress never hands the opened payload to the node's `ingestInbound`, so no INBOX commit and no recipient ACK can follow. *MEASURED: this escaped when witnessed on the D arm, because D's durable claim is satisfied by `Router.ingest` alone -- the ARB arm is the one that requires the INBOX, so it is the honest witness.*", "baseline": "green (GsIntegration001ScenarioTests 6/6 + GsIntegration001RealTransportTests 18/18, over the real composition on disk)", "kind": "semantic"},
    {"id": "T72-RC19-ios-egress-is-a-silent-noop", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/RealTransportHostRig.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsIntegration001ScenarioTests.swift", "swift_filter": "GsIntegration001ScenarioTests", "find": "            fabric.record(from: relay.aLabel, to: relay.bLabel, bytes: bytes,\n                          characteristic: uuid == BleTransport.linkInfoCharacteristicUuid ? \"linkInfo\" : \"inbox\")", "replace": "            // (mutant) the write is a silent no-op: nothing is recorded, so egress readeth zero\n            _ = bytes", "witness": "testARBEstablishesOverOSFacadesOnlyThenDeliversADirectFrameAndTheRecipientAck", "why": "every `writeValue` waveth past the fabric, so the egress gate can never show a byte and a silent writer would look identical to an honest one. The egress-observing witness condemneth. *MEASURED, AND BOTH EARLIER FAULTS ARE FIXED HERE: the find carrieth TWELVE spaces of indent (the file's own, not eight) and the witness is the A-R-B arm, whose `egressBytes > 0` assertion is the one that readeth the fabric -- the DEFAULT-LANE twin never looks at egress at all.*", "baseline": "green (GsIntegration001ScenarioTests 6/6 + GsIntegration001RealTransportTests 18/18)", "kind": "semantic"},
    {"id": "T72-RC20-ios-ingress-empty-sender-restored", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsIntegration001ScenarioTests.swift", "swift_filter": "GsIntegration001ScenarioTests", "find": "                            let ingressSender = capturedPeers[centralId]?.nodeId16\n                                ?? (chargedIdentity.count == 16 ? chargedIdentity : nil)", "replace": "                            let ingressSender = capturedPeers[centralId]?.nodeId16   // (mutant) the authenticated identity is discarded", "witness": "testARBEstablishesOverOSFacadesOnlyThenDeliversADirectFrameAndTheRecipientAck", "why": "the responder's ingress reverteth to the empty `receivedFrom`, so the inbox refuseth at gate 0 (zero-width sender) BEFORE any counter moves, while the router still persisteth the frame. The recipient-ACK witness condemneth.", "baseline": "green (GsIntegration001ScenarioTests 6/6 over the real composition)", "kind": "semantic"},
    {"id": "T72-RC21-ios-resolver-stopeth-resolving-altogether", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/BoundRecipientKeyResolver.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsIntegration001ScenarioTests.swift", "swift_filter": "GsIntegration001ScenarioTests", "find": "        case .verified(let identity):\n            switch identity.trustLevel {\n            case .tofuPinned, .userVerified:\n                return identity.signingPublicKey", "replace": "        case .verified(let identity):\n            switch identity.trustLevel {\n            case .tofuPinned, .userVerified:\n                return nil   // (mutant) a verified pinned identity resolves NO key", "witness": "testEWipeDuringASuspendedWriteRefusesStorageFailureThenReopens", "why": "the resolver stopeth resolving for a verified pinned peer, so the E arm's OWN POSITIVE CONTROL reddens -- *the `XCTAssertNotNil` that proveth the lookup road is live BEFORE the wipe.* **MEASURED, AND THE PLACEMENT IS THE FINDING: THE E ARM'S `publicSigningKey` REFUSAL IS OVER-DETERMINED -- the outer `wipeGate.allowsSensitiveUse()` AND the inner `lifecycleGate.isActive` AND the store drain EACH refuse while a wipe standeth, so striking ANY ONE of them leaveth the others refusing and the arm green (two placements were tried and both escaped).** *The one condition the arm OBSERVES BOTH WAYS is the POSITIVE one, so that is where the rod must stand: a gate whose refusal is triply redundant can only be watched from its permit side.*", "baseline": "green (GsIntegration001ScenarioTests 6/6)", "kind": "semantic"},
    # ----------------------------------------------------------------------
    # *** STEP 13 (rc11): THE RIG'S OWN READINESS PREDICATE, WHICH REPLACED A COUNT. ***
    #
    #   *MEASURED IN THE HOSTED RUN AND REPRODUCED LOCALLY: the A–R–B arm accepted
    #   `trustedHandles(opener).count > 0` for BOTH hops, so when one node opened both hops the SECOND
    #   relation's readiness was satisfied by the FIRST's handle and the arm dispatched into a receiver
    #   whose handshake had not crossed -- the all-zero census. THE REPAIR IS `isLinkReady`, WHICH REQUIRETH
    #   THE RELATION'S OWN EXACT HANDLE IN BOTH OF THE OPENER'S VIEWS.*
    #
    #   **THIS ROD PUTTETH THE OLD ANY-READY-HANDLE RULE BACK, AND THE HELD-SECOND-LINK REGRESSION MUST REDDEN.**
    #   *The plan requires the mutation AT THE RIG (where `isLinkReady` liveth), NOT on a scenario predicate the
    #   regression never calls -- reverting a predicate outside the exercised path would prove nothing.*
    {"id": "T72-RC22-ios-link-readiness-falls-back-to-any-handle", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/RealTransportHostRig.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsIntegration001RealTransportTests.swift", "swift_filter": "GsIntegration001RealTransportTests", "find": "        return n.ble.linkReadyPeersForTest().contains(handle)\n            && n.node.knownPeersForTest().contains(handle)", "replace": "        // (mutant) the OLD rule: ANY ready handle satisfieth this relation\n        return !n.ble.linkReadyPeersForTest().isEmpty\n            && !n.node.knownPeersForTest().isEmpty", "witness": "testGSINT001ASecondLinksReadinessIsNotSatisfiedByTheFirstLinksHandle", "why": "the exact-handle readiness predicate is replaced by the any-ready-handle count, so a SECOND relation opened by the SAME node inherits the FIRST's readiness -- the measured hosted defect. The held-second-link regression condemneth, because its second hop is provably not ready while the mutant sayeth it is.", "baseline": "green (GsIntegration001RealTransportTests: the held-second-link, ACK-boundary, deallocation and lane arms, plus GsIntegration001ScenarioTests, all pass on the unmutated tree)"},
    # *** THE RESPONDER DISPATCHER, WHICH ROUTES BY DESTINATION CENTRAL RATHER THAN "THE LAST WIRED LINK". ***
    #
    #   *MEASURED BY READING THE OLD WIRING: `responder.factory.lastPeripheralManager?.onUpdate` was set ONCE PER LINK,
    #   EACH TIME OVERWRITING THE LAST, and the closure ignored the destination-central argument. So when one node
    #   carrieth TWO relations, its single manager's `updateValue` closure belonged to whichever link was wired last,
    #   and a value staged for the OTHER central was delivered to the WRONG initiator.*
    #
    #   **THIS ROD PUTTETH THE OLD "ANY LINK FOR THIS RESPONDER" RULE BACK, AND `testGSINT001ATwoRelationResponderNever
    #   CrossDelivers` MUST REDDEN. THE ARM WAS CORRECTED ONCE ALREADY: my first arrangement made the hub the OPENER of
    #   both hops, which gave each peer exactly ONE relation and let this rod ESCAPE -- so the arm now makes the HUB the
    #   RESPONDER of both hops, which is the only shape in which one manager carrieth two relations.**
    {"id": "T72-RC23-ios-responder-dispatcher-ignores-the-destination-central", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/RealTransportHostRig.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsIntegration001RealTransportTests.swift", "swift_filter": "GsIntegration001RealTransportTests", "find": "                let key = ResponderKey(responderLabel: responder.label, centralId: centralId)\n                guard let route = responderDispatch[key] else { return }", "replace": "                // (mutant) the OLD per-link overwrite: ignore the destination central\n                _ = centralId\n                guard let route = responderDispatch.values.first(where: { $0.relay.bLabel == responder.label }) else { return }", "witness": "testGSINT001ATwoRelationResponderNeverCrossDelivers", "why": "the responder dispatcher stops routing by the destination central and picks ANY route for its own label, so a value staged for one relation is delivered to the WRONG initiator -- cross-delivery, the misrouting class this programme hunts. The two-relation arm condemneth (the handshakes refuse and neither store receives its own frame).", "baseline": "green (GsIntegration001RealTransportTests 22 arms, GsIntegration001ScenarioTests 6 arms, 0 failures)"},
    # *** RC24: THE FINGERPRINT-CONFIRMATION CAS ITSELF, NOT MERELY THE UI'S CALL TO IT. ***
    #
    #   *`T56-RC1` PROVETH THE UI ASKETH THE AUTHORITY; IT CANNOT PROVE THE AUTHORITY GUARDETH. This rod striketh the
    #   CAS's GENERATION PREDICATE, so a confirmation captured against a display that has SINCE MOVED would promote the
    #   row anyway -- the "stale confirmation changes nothing" clause.*
    #
    #   **THE WITNESS IS THE DURABLE ROW, NOT THE RETURN VALUE: `testAStaleOrMismatchedConfirmationChangesNothing`
    #   readeth the store before and after and requireth them equal.**
    # *** RC25: THE FINGERPRINT ITSELF, NOT ONLY THE GENERATION. ***
    #
    #   *A CAS that checked the generation but not the KEY DIGEST would promote a row whose accepted key had been
    #   replaced by a rotation that kept the generation -- the same "displayed reference" law, one predicate over.*
    # *** RC26: THE POST-MUTATION READBACK, WHICH IS WHAT MAKETH A FORGED PROJECTION DETECTABLE. ***
    #
    #   *`testAConfirmationWhoseReadbackDisagreesRollsBackRatherThanReportingSuccess` proveth that a `.confirmed`
    #   projection beside an UNMOVED row is refused. This rod removes the readback comparison, so the intent alone
    #   would be reported as success -- exactly the forged projection the clause names.*
    {"id": "T72-RC26-ios-confirmation-trusts-its-intent-not-the-readback", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/PeerIdentityRepository.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/PeerIdentityRepositoryTests.swift", "swift_filter": "PeerIdentityRepositoryTests", "find": "                guard readback == expected else {\n                    throw ApplyTxnAbort.corrupt(.mutationReadbackMismatch(\"confirmVerified readback mismatch\"))\n                }", "replace": "                // (mutant) the intent is trusted: a success is reported without the row agreeing\n                _ = expected\n                _ = readback", "witness": "testAConfirmationWhoseReadbackDisagreesRollsBackRatherThanReportingSuccess", "why": "the post-mutation readback comparison is removed, so a confirmation whose UPDATE affected NOTHING still reports `.confirmed` -- a forged success projection beside an unmoved durable row. The readback witness condemneth.", "baseline": "green (PeerIdentityRepositoryTests, 0 failures)"},
    # *** RC27: THE DURABLE SOS AUTHORITY, WHICH IS WHAT MAKETH A RELAUNCH READ A ROW RATHER THAN A REGISTER. ***
    #
    #   *THE DEFECT THIS REPLACES WAS REAL AND MEASURED: the lab composed its nodes over in-memory stores, so the SOS
    #   row died with the process and `sosStateNames()` read a DISPLAY REGISTER. The repair buildeth the author's node
    #   over a retained `SqliteMessageStore`.* **This rod striketh that binding -- the node is built over the in-memory
    #   store again -- and the on-disk journey arm must redden at its FIRST durable-row assertion.**
    {"id": "T72-RC27-ios-lab-composes-the-author-over-memory-not-the-estate", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/LabRuntime.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsUx001TrustSurfaceTests.swift", "swift_filter": "GsUx001TrustSurfaceTests", "find": "            _ = try harness.addNode(label, seedByte: next, durableStore: durable)", "replace": "            // (mutant) the author is composed over MEMORY again: the SOS row never reacheth the file\n            _ = try harness.addNode(label, seedByte: next, durableStore: nil)", "witness": "test07bTheDistressJourneyIsDurableOnDiskAcrossRelaunches", "why": "the lab stops building its nodes over the retained estate, so the SOS row is authored into memory and the durable row readeth nil -- the display-register defect this clause closes. The on-disk journey arm condemneth at its first `durableDeliveryState` assertion.", "baseline": "green (GsUx001TrustSurfaceTests 10 arms, 0 failures)"},
    # ----------------------------------------------------------------------
    # *** rc11, STEP 8: THE FINGERPRINT-CONFIRMATION CAS'S OWN PREDICATES. ***
    #
    #   *`T56-RC1`/`T56-RC2` PROVE THE UI ASKS THE AUTHORITY; THEY CANNOT PROVE THE AUTHORITY GUARDS. These two rods
    #   strike the two predicates of the CAS itself, each witnessed by the DURABLE ROW the clause is about.*
    #
    #   **RC24 STRIKES THE DISPLAYED GENERATION, RC25 THE DISPLAYED FINGERPRINT.** *Both are exercised by
    #   `testAStaleOrMismatchedConfirmationChangesNothing`, which reads the store before and after and requireth the
    #   rows equal -- so a stale confirmation that CHANGED anything reddens.*
    {"id": "T72-RC24-ios-confirmation-cas-ignores-the-displayed-generation", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/PeerIdentityRepository.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/PeerIdentityRepositoryTests.swift", "swift_filter": "PeerIdentityRepositoryTests", "find": "                guard current.acceptedGeneration == expectedAcceptedGeneration,\n                      ExactRotationCandidateRef.digestHex(current.acceptedStaticDhPublicKey)\n                        .lowercased() == expectedFingerprintHex.lowercased() else {\n                    throw ConfirmationAbort.stale\n                }", "replace": "                // (mutant) the DISPLAYED generation is ignored, so a stale confirmation promoteth\n                guard ExactRotationCandidateRef.digestHex(current.acceptedStaticDhPublicKey)\n                        .lowercased() == expectedFingerprintHex.lowercased() else {\n                    throw ConfirmationAbort.stale\n                }", "witness": "testAStaleOrMismatchedConfirmationChangesNothing", "why": "the CAS stops checking the DISPLAYED accepted generation, so a confirmation captured before a key rotation would promote the row it no longer describeth -- the stale-display defect the clause forbids. The durable-row witness condemneth.", "baseline": "green (PeerIdentityRepositoryTests: the three confirmation arms plus the existing repository court, 0 failures)"},
    {"id": "T72-RC25-ios-confirmation-cas-ignores-the-key-digest", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/PeerIdentityRepository.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/PeerIdentityRepositoryTests.swift", "swift_filter": "PeerIdentityRepositoryTests", "find": "                guard current.acceptedGeneration == expectedAcceptedGeneration,\n                      ExactRotationCandidateRef.digestHex(current.acceptedStaticDhPublicKey)\n                        .lowercased() == expectedFingerprintHex.lowercased() else {\n                    throw ConfirmationAbort.stale\n                }", "replace": "                // (mutant) the displayed FINGERPRINT is ignored, so any key at the right generation promoteth\n                guard current.acceptedGeneration == expectedAcceptedGeneration else {\n                    throw ConfirmationAbort.stale\n                }", "witness": "testAStaleOrMismatchedConfirmationChangesNothing", "why": "the CAS stops comparing the fingerprint against the ROW's accepted key, so a confirmation of one key would promote a row carrying another -- the contact's key changed since you read that fingerprint becomes false. The durable-row witness condemneth (its wrong-digest arm).", "baseline": "green (PeerIdentityRepositoryTests, 0 failures)"},
    # *** rc11, STEP 5: THE ACTUAL OS-FACADE WRITE, SUPPRESSED WHILE ITS SUCCESS IS STILL ADVERTISED. ***
    #
    #   *THE PLAN'S OWN CLAUSE: "add a separate control that suppresseth the actual OS-facade write/notification
    #   while preserving its advertised success; the recipient/delivery verdict must fail."* **RC19 DELETES
    #   `fabric.record` -- THE RECORDER -- so the bytes still cross and only the MEASUREMENT breaks. THIS rod strikes
    #   the DELIVERY ITSELF: `processPeripheralUpdateValue` is the initiator's REAL CoreBluetooth entry, so suppressing
    #   it meaneth the record NEVER REACHES the recipient while the relay's `updateValue` still returned `true`.**
    #   *The witness is the A-R-B arm's egress-and-inbox gate and the two-relation arm: a frame whose bytes left and
    #   whose recipient holdeth nothing is exactly the silent-writer the egress law exists to catch.*
    {"id": "T72-RC28-ios-os-egress-suppressed-while-advertising-success", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/RealTransportHostRig.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsIntegration001ScenarioTests.swift", "swift_filter": "GsIntegration001ScenarioTests", "find": "            _ = initiator.ble.processPeripheralUpdateValue(unsafeBitCast(link.peripheral, to: CBPeripheral.self),\n                                                          delegate: iDelegate, characteristic: ch, error: nil)\n            initiator.ble.processPeripheralIsReady(unsafeBitCast(link.peripheral, to: CBPeripheral.self),\n                                                   delegate: iDelegate)", "replace": "            // (mutant) THE OS-FACADE WRITE IS SUPPRESSED while the advertised success stands: the record never\n            // reaches the recipient's own entry, and no recorder is touched -- so a recorder-only control would miss it\n            _ = ch\n            _ = iDelegate", "witness": "testARBEstablishesOverOSFacadesOnlyThenDeliversADirectFrameAndTheRecipientAck", "why": "the initiator's REAL CoreBluetooth notification entry is never called, so a record the relay 'successfully' staged NEVER reaches the recipient -- the silent-transport defect the recorder-only RC19 cannot see. The A-R-B arm condemneth at its durable-inbox gate (egress bytes exist, the row never commit).", "baseline": "green (GsIntegration001ScenarioTests 6 arms + GsIntegration001RealTransportTests 22 arms, 0 failures)"},
    # *** rc11, STEP 3: EACH CONSTRUCTION SEAM'S OWN CONTROL, NOT ONLY THE IDENTITY'S. ***
    #
    #   *THE PLAN'S CLAUSE: "Keep `T72-RC13` and add SEPARATE message-store and peer-store note deletions, EACH KILLED
    #   BY THAT SEAM'S POSITIVE WITNESS."* **RC13 removeth only the IDENTITY seam's note; a counter that stopped
    #   counting the MESSAGE_STORE or PEER_STORE seam would escape it, because the identity delta would still move.**
    #   *Each rod is witnessed by `thePermittedRoadCountsOneAttemptPerSeamAtThePlatform`, whose per-seam loop asserteth
    #   a delta of exactly 1 AND the authority -- so the seam it strikes reddens by name.*
    {"id": "T72-RC29-android-message-store-construction-uncounted", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003ZeroPrivateOpensTest.kt", "gradle_filter": "*GsFinal003ZeroPrivateOpensTest*", "find": "        PrivateConstructionCounter.noteAttempt(PrivateConstructionCounter.Seam.MESSAGE_STORE, permit.issuedFrom)\n        return SqliteMessageStore(ctx, STORE_MAX_BYTES, ownerToken)", "replace": "        // (mutant) the MESSAGE-STORE construction is NOT counted at its own seam\n        return SqliteMessageStore(ctx, STORE_MAX_BYTES, ownerToken)", "witness": "thePermittedRoadCountsOneAttemptPerSeamAtThePlatform", "why": "unchanged law, re-anchored to the CURRENT source: the same production guard, struck byte-exact (the permit is now consumed as a parameter and the member renamed, but the law is the same)."},
    {"id": "T72-RC30-android-peer-store-construction-uncounted", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003ZeroPrivateOpensTest.kt", "gradle_filter": "*GsFinal003ZeroPrivateOpensTest*", "find": "        PrivateConstructionCounter.noteAttempt(PrivateConstructionCounter.Seam.PEER_STORE, permit.issuedFrom)\n        return SqlcipherPeerIdentityStore(ctx, ownerToken)", "replace": "        // (mutant) the PEER-STORE construction is NOT counted at its own seam\n        return SqlcipherPeerIdentityStore(ctx, ownerToken)", "witness": "thePermittedRoadCountsOneAttemptPerSeamAtThePlatform", "why": "unchanged law, re-anchored to the CURRENT source: the same production guard, struck byte-exact (the permit is now consumed as a parameter and the member renamed, but the law is the same)."},
    {"id": "T72-RC31-ios-retirement-leaveth-the-session-slot-standing", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/SessionManager.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsStress001RealRuntimeDriverTests.swift", "swift_filters": ["GsStress001RealRuntimeDriverTests/testGSSTRESS001RelationRetirementReleasesTheOwnersOwnSlot"], "find": "                if let slot = controllers.removeValue(forKey: handle) { doomed.append(slot) }", "replace": "                // (mutant) the registry entry is LEFT STANDING: the departed peer's slot leaketh\n                _ = handle", "witness": "testGSSTRESS001RelationRetirementReleasesTheOwnersOwnSlot", "why": "THE PRODUCTION RELEASE VERB `retireIncarnations(ofPeerId:)` STOPS REMOVING THE RELATION FROM ITS OWN REGISTRY: the `SessionSlot` -- and the `TrustedHandshakeController` it holdeth -- surviveth the departure it was called for, so a live session slot is leaked in exactly the owner that allocateth it. **Nothing downstream observeth it: the transport's retire notice is a different road, so only the owner's own `slotCountForTest()` census condemneth** -- and the named arm driveth that verb and requireth the census to return to zero, so a STANDING slot reddeneth it by name"},
    {"id": "T72-RC32-ios-stop-leaveth-every-timer-lease-standing", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsStress001RealRuntimeDriverTests.swift", "swift_filters": ["GsStress001RealRuntimeDriverTests/testGSSTRESS001TransportStopReleasesEveryHeldTimerLease"], "find": "    private func cancelAllTimerLeasesLocked() {\n        for (_, lease) in timerLeases {\n            lease.timer.invalidate()\n        }\n        timerLeases.removeAll()\n        timerSlots.removeAll()\n    }", "replace": "    private func cancelAllTimerLeasesLocked() {\n        // (mutant) the terminal and lifecycle sweep releaseth NOTHING: every lease\n        // (and its armed Timer) standeth past the stop it was swept by\n    }", "witness": "testGSSTRESS001TransportStopReleasesEveryHeldTimerLease", "why": "THE TERMINAL SWEEP `cancelAllTimerLeasesLocked()` -- the release `BleTransport.stop()` reacheth -- IS STRUCK ENTIRE: the armed `Timer` is never invalidated and never evicted, so a stopped transport keepeth BOTH its lease registration and its pending fire. **The reading is the transport's OWN `timerLeaseCountForTest()` census, and the named arm armeth a lease through the REAL admission road, stoppeth the lifecycle owner and requireth the register to empty -- a standing lease reddeneth it by name**"},
    {"id": "T72-RC33-ios-shutdown-leaveth-the-reservations-standing", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/RecordWriter.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsStress001RealRuntimeDriverTests.swift", "swift_filters": ["GsStress001RealRuntimeDriverTests/testGSSTRESS001WriterShutdownReleasesTheOwnersOwnReservations"], "find": "        reserved.removeAll()\n        reservationCapacity.removeAll()\n        closed = true", "replace": "        // (mutant) the close path releaseth NO reservation: the tickets stand past shutdown\n        closed = true", "witness": "testGSSTRESS001WriterShutdownReleasesTheOwnersOwnReservations", "why": "THE WRITER'S OWN CLOSE PATH `shutdown()` STOPS RELEASING ITS RESERVATION TABLE: a closed relation that accepteth nothing further still HOLDETH the tickets it admitted -- the exact leak class `Invariants.noLeakedReservations` nameth. **The reading is the writer's own `reservedCountForTest()`, and the named arm bindeth a writer through the REAL send road (a ready session over a standing connection), filleth its bound, callth `shutdown()` and requireth zero -- the standing tickets redden it by name**"},
    # ----------------------------------------------------------------------
    # T82 (s24-28): the explicitly closed tier and bulk-plane promises. The
    #   card's NAMED semantic negative is RC1/RC2: "Advertise bulk transfer or
    #   constraint test fails." Each rod striketh one checker rule and is
    #   witnessed by its OWN named case in tools/readiness/tests/test_t82.py.
    # ----------------------------------------------------------------------
    {"id": "T82-RC1-an-advertised-promise-is-not-checked", "platform": "python", "file": "tools/readiness/promises.py", "court": "tools/readiness/tests/test_t82.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t82.py", "find": "    for capability in refused_promises():\n        findings.append(Finding(\n            \"advertised-but-not-enabled\",", "replace": "    for capability in []:   # (mutant) an advertised promise need not be enabled\n        findings.append(Finding(\n            \"advertised-but-not-enabled\",", "witness": "test_w02_the_law_advertised_implies_enabled", "why": "the card's NAMED semantic negative: the law that an advertised capability must have its enabling code ENABLED is asleep, so a product could advertise bulk transfer or an INTERNET build while the code saith no. W02 -- which FEEDETH the checker an advertised DISABLED capability -- condemneth it (the first form of this rod named W12, which the mutant satisfieth, because the repository carrieth no refused promise either way)", "baseline": "green (the T82 court: 13 witnesses in tools/readiness/tests/test_t82.py, driven by the real promise ledger over this repository's own manifests, tier table, ADR, stub, release manifest and blocker register)", "kind": "functional"},
    {"id": "T82-RC2-the-internet-removal-is-not-checked", "platform": "python", "file": "tools/readiness/promises.py", "court": "tools/readiness/tests/test_t82.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t82.py", "find": "    if 'android.permission.INTERNET\" tools:node=\"remove\"' not in manifest:", "replace": "    if False:   # (mutant) INTERNET may be granted to the Archive-only build", "witness": "test_w04_internet_in_the_archive_only_manifest_is_refused", "why": "the INTERNET check is asleep, so the offline Archive-only product could quietly gain the permission that maketh it an online product -- the card's named negative in its second limb. The INTERNET witness condemneth", "baseline": "green (the T82 court: 13 witnesses in tools/readiness/tests/test_t82.py, driven by the real promise ledger over this repository's own manifests, tier table, ADR, stub, release manifest and blocker register)", "kind": "functional"},
    {"id": "T82-RC3-the-profile-flags-are-not-checked", "platform": "python", "file": "tools/readiness/promises.py", "court": "tools/readiness/tests/test_t82.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t82.py", "find": "        if expected not in gradle:\n            findings.append(Finding(\n                \"profile-flag-not-disabled\",", "replace": "        if False:   # (mutant) a profile flag may be true without a finding\n            findings.append(Finding(\n                \"profile-flag-not-disabled\",", "witness": "test_w05_the_light_profile_declares_every_capability_false", "why": "a capability flag flipped TRUE in the shipping flavour is no longer reported, so bulk, mesh, SOS or the Oracle could be enabled silently. The profile-flag witness condemneth", "baseline": "green (the T82 court: 13 witnesses in tools/readiness/tests/test_t82.py, driven by the real promise ledger over this repository's own manifests, tier table, ADR, stub, release manifest and blocker register)", "kind": "functional"},
    {"id": "T82-RC4-the-tier-table-may-carry-two-shipping-tiers", "platform": "python", "file": "tools/readiness/promises.py", "court": "tools/readiness/tests/test_t82.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t82.py", "find": "    if shipping_true != 1:", "replace": "    if False:   # (mutant) any number of shipping tiers is acceptable", "witness": "test_w06_exactly_one_shipping_tier_and_it_is_light", "why": "the tier table may mark several tiers shipping, so a research-only MEDIUM or LARGE product -- with NO store-compatible asset delivery design -- could ship. The tier witness condemneth", "baseline": "green (the T82 court: 13 witnesses in tools/readiness/tests/test_t82.py, driven by the real promise ledger over this repository's own manifests, tier table, ADR, stub, release manifest and blocker register)", "kind": "functional"},
    {"id": "T82-RC5-a-closed-capability-need-not-be-closed-in-words", "platform": "python", "file": "tools/readiness/promises.py", "court": "tools/readiness/tests/test_t82.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t82.py", "find": "            for word in required:\n                if word.lower() not in text.lower():", "replace": "            for word in []:   # (mutant) a closure need not be stated in words\n                if word.lower() not in text.lower():", "witness": "test_w07_a_closed_tier_must_be_closed_in_words", "why": "a document may MENTION a disabled tier as though it were a product without stating the closure, and a reader would take the mention for a promise. The closure-in-words witness condemneth", "baseline": "green (the T82 court: 13 witnesses in tools/readiness/tests/test_t82.py, driven by the real promise ledger over this repository's own manifests, tier table, ADR, stub, release manifest and blocker register)", "kind": "functional"},
    {"id": "T82-RC6-the-bulk-stub-may-pretend-to-send", "platform": "python", "file": "tools/readiness/promises.py", "court": "tools/readiness/tests/test_t82.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t82.py", "find": "    if \"unavailable\" not in bulk_ios.lower():", "replace": "    if False:   # (mutant) the bulk stub need not report unavailable", "witness": "test_w08_the_bulk_plane_is_closed_in_words", "why": "the iOS bulk transport may stop reporting unavailable -- the false-success path V4 removed -- without a finding. The bulk-stub witness condemneth", "baseline": "green (the T82 court: 13 witnesses in tools/readiness/tests/test_t82.py, driven by the real promise ledger over this repository's own manifests, tier table, ADR, stub, release manifest and blocker register)", "kind": "functional"},
    {"id": "T82-RC7-the-ios-surface-may-advertise-bulk", "platform": "python", "file": "tools/readiness/promises.py", "court": "tools/readiness/tests/test_t82.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t82.py", "find": "        if forbidden in ios_plist:", "replace": "        if False:   # (mutant) the shipping plist may declare bulk capabilities", "witness": "test_w09_the_ios_shipping_surface_advertises_no_bulk_capability", "why": "the shipping iOS surface may declare a local-network usage string or a background mode -- advertising a bulk plane the build cannot perform. The iOS-surface witness condemneth", "baseline": "green (the T82 court: 13 witnesses in tools/readiness/tests/test_t82.py, driven by the real promise ledger over this repository's own manifests, tier table, ADR, stub, release manifest and blocker register)", "kind": "functional"},
    {"id": "T82-RC8-an-open-decision-need-not-be-recorded", "platform": "python", "file": "tools/readiness/promises.py", "court": "tools/readiness/tests/test_t82.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t82.py", "find": "        if token not in gates.upper() and token not in blockers.upper():", "replace": "        if False:   # (mutant) an open external decision need not be recorded", "witness": "test_w10_every_open_decision_is_recorded", "why": "a capability may be closed as an OPEN external decision that no register carrieth, so a reader could not tell an undecided promise from a deliberate one. The open-decision witness condemneth", "baseline": "green (the T82 court: 13 witnesses in tools/readiness/tests/test_t82.py, driven by the real promise ledger over this repository's own manifests, tier table, ADR, stub, release manifest and blocker register)", "kind": "functional"},
    {"id": "T82-RC9-a-stub-may-be-advertised", "platform": "python", "file": "tools/readiness/promises.py", "court": "tools/readiness/tests/test_t82.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t82.py", "find": "        if capability.status == Status.UNSUPPORTED_STUB and capability.is_advertised:", "replace": "        if False:   # (mutant) a stub may be advertised", "witness": "test_w11_no_advertised_capability_is_a_stub", "why": "the loudest and emptiest promise -- an advertised UNSUPPORTED STUB -- is no longer reported. The stub witness condemneth", "baseline": "green (the T82 court: 13 witnesses in tools/readiness/tests/test_t82.py, driven by the real promise ledger over this repository's own manifests, tier table, ADR, stub, release manifest and blocker register)", "kind": "functional"},
    {"id": "T82-RC10-the-ledger-forgetteth-the-bulk-plane", "platform": "python", "file": "tools/readiness/promises.py", "court": "tools/readiness/tests/test_t82.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t82.py", "find": "    Capability(\n        id=\"bulk_transfer\",", "replace": "    Capability(\n        id=\"bulk_transfer_renamed_away\",", "witness": "test_w01_every_capability_carrieth_its_enabling_code_and_status", "why": "the bulk-plane capability vanish eth from the ledger, so nothing would report that the repository discusseth a capability its code disableth. The ledger witness condemneth", "baseline": "green (the T82 court: 13 witnesses in tools/readiness/tests/test_t82.py, driven by the real promise ledger over this repository's own manifests, tier table, ADR, stub, release manifest and blocker register)", "kind": "functional"},
    {"id": "T82-RC11-the-media-tier-promise-is-silent", "platform": "python", "file": "tools/readiness/promises.py", "court": "tools/readiness/tests/test_t82.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t82.py", "find": "        external_decision=\"APPROVED_CONTENT\",\n    ),\n    Capability(\n        id=\"large_tier\",", "replace": "    ),\n    Capability(\n        id=\"large_tier\",", "witness": "test_w10_every_open_decision_is_recorded", "why": "the MEDIUM tier loseth its named open decision, so the ledger would claim a closed capability whose design nobody hath decided. The open-decision witness condemneth", "baseline": "green (the T82 court: 13 witnesses in tools/readiness/tests/test_t82.py, driven by the real promise ledger over this repository's own manifests, tier table, ADR, stub, release manifest and blocker register)", "kind": "functional"},
    {"id": "T82-RC12-a-media-tier-may-be-marked-shipping", "platform": "python", "file": "tools/readiness/promises.py", "court": "tools/readiness/tests/test_t82.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t82.py", "find": "    for tier in (\"MEDIUM\", \"LARGE\"):", "replace": "    for tier in []:   # (mutant) a research-only tier need not stay research-only", "witness": "test_w06_exactly_one_shipping_tier_and_it_is_light", "why": "a research-only tier's own `shipping: false` is no longer asserted, so the tier table's second product could drift into a shippable one. The tier witness condemneth", "baseline": "green (the T82 court: 13 witnesses in tools/readiness/tests/test_t82.py, driven by the real promise ledger over this repository's own manifests, tier table, ADR, stub, release manifest and blocker register)", "kind": "functional"},
    # ----------------------------------------------------------------------
    # *** THE TERMINAL BOARD 1 ROUND (AndroidRecoveryUi): THE RECOVERY TOPOLOGY'S
    # POST-LANDING GUARDS. *** *Each rod strikes ONE production guard in the
    # recovery/startup/private composition or the rendered lab wipe, witnessed by
    # a named arm of the court the repair landed with.*
    # ----------------------------------------------------------------------
    {"id": "T72-RC35-android-identity-publication-sentinel-restored", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/identity/WipePrivateEstate.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003PrePrivateRecoveryGraphTest.kt", "gradle_filter": "*GsFinal003PrePrivateRecoveryGraphTest*", "find": "    } catch (e: Throwable) {\n        // NOT PUBLISHED, NAMED AS SUCH BY THE SEAM'S `null` -- never a sentinel string the ladder could mistake.\n        null\n    }", "replace": "    } catch (e: Throwable) {\n        // (mutant) a failed regeneration answers a NON-NULL sentinel the ladder mistakes for a published identity\n        \"identity-generation-failed\"\n    }", "witness": "aFailedPublicationKeepsTheWipePending", "why": "the production identity material answers a NON-NULL sentinel on a failed regeneration, so the coordinator cannot branch on `null`: the ladder records NEW_IDENTITY then IDLE over an identity that was never created."},
    {"id": "T72-RC36-android-admission-gate-raw-enum-restored", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003PrePrivateRecoveryGraphTest.kt", "gradle_filter": "*GsFinal003PrePrivateRecoveryGraphTest*", "find": "        StartupRecoveryGraph.decisionAtRest(FileWipeJournal(ctx)).allowsPrivateConstruction", "replace": "        io.godstone.mesh.identity.FileWipeJournal(ctx).read() == io.godstone.mesh.identity.PanicWipe.WipeState.IDLE", "witness": "anUnreadableDurableRecordIsCorruptAndRefusedOnBothRoads", "why": "the admission gate returns to reading the RAW coerced enum, so an UNREADABLE record (ordinal 9999 read as IDLE) PERMITS sensitive use while the barrier refuses the same record."},
    {"id": "T72-RC37-android-startup-decision-ignores-readability", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003PrePrivateRecoveryGraphTest.kt", "gradle_filter": "*GsFinal003PrePrivateRecoveryGraphTest*", "find": "        get() = StartupRecoveryGraph.decisionOf(authority, outcome)", "replace": "        get() = decide(outcome, readable = true)", "witness": "anUnreadableDurableRecordIsCorruptAndRefusedOnBothRoads", "why": "the startup decision is derived from the ladder's coerced answer alone, so an unreadable record reads as Refused(NOTHING_TO_RESUME) and is judged CLEAN_START -- opening private stores over material that may be mid-erasure."},
    {"id": "T72-RC41-android-composition-issuer-mints-from-a-constant-decision", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003PrePrivateRecoveryGraphTest.kt", "gradle_filter": "*GsFinal003PrePrivateRecoveryGraphTest*", "find": "            permit.requireLiveFor(live, PrivateOwnerToken.forNormalConstruction(permit))", "replace": "            requireNotNull(permit)", "witness": "aPermitIsWithheldWhenTheDurableEstateMoved", "why": "unchanged law, re-anchored to the CURRENT source: the same production guard, struck byte-exact (the permit is now consumed as a parameter and the member renamed, but the law is the same)."},
    {"id": "T72-RC39-android-wipe-resume-offered-unconditionally", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/lab/LabWipeJourneyTest.kt", "gradle_filter": "*LabWipeJourneyTest*", "find": "    StartupWipeDecision.CLEAN_START,\n    StartupWipeDecision.WIPE_COMPLETED,\n    StartupWipeDecision.CORRUPT_JOURNAL,\n    StartupWipeDecision.TERMINAL_FAILURE -> false", "replace": "    StartupWipeDecision.CLEAN_START,\n    StartupWipeDecision.WIPE_COMPLETED,\n    StartupWipeDecision.CORRUPT_JOURNAL,\n    StartupWipeDecision.TERMINAL_FAILURE -> true,", "witness": "theRecoveryContractIsStateAwareAndExhaustive", "why": "the recovery contract stops being state-aware and permits a resume for EVERY decision, so a rendered resume control offers to resume work that cannot be resumed."},
    {"id": "T72-RC42-android-completed-wipe-collapsed-into-first-launch", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003PrePrivateRecoveryGraphTest.kt", "gradle_filter": "*GsFinal003PrePrivateRecoveryGraphTest*", "find": "        if (reachedTerminal) return StartupWipeDecision.WIPE_COMPLETED", "replace": "        if (reachedTerminal) return StartupWipeDecision.CLEAN_START", "witness": "aWipeThatRanToItsEndReadsAsWipeCompleted", "why": "a wipe that RAN to its end is reported as a FIRST LAUNCH, so a surface can no longer tell a user whether their device was ever wiped -- the iOS contract's `wipeCompleted` collapses into `cleanStart`."},
    {"id": "T72-RC38-android-lab-wipe-local-state-register", "platform": "jvm", "module": "labmesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/lab/LabWipeJourney.kt", "court": "android/labmesh/src/test/java/io/godstone/labmesh/LabMeshJourneyBoundTest.kt", "gradle_filter": "*LabMeshJourneyBoundTest*", "find": "    fun begin(): Step {\n        // *** (1) OLD WORK REFUSED, BEFORE THE LADDER MOVES. ***\n        live()?.retireLiveOwners()\n        // *** (2) AND THE LADDER, OVER THE REAL CAPABILITIES. ***\n        return fromDrive(StartupRecoveryGraph.requestWipe(journal, seams()))\n    }", "replace": "    fun begin(): Step {\n        // (mutant) the rendered REQUEST becomes a harness-local register: the durable journal is never written\n        live()?.retireLiveOwners()\n        return progress().copy(rung = WipeJournalState.REQUESTED, pending = true)\n    }", "witness": "test_the_rendered_wipe_reaches_the_durable_record_and_survives_a_reopen", "why": "re-anchored: the rendered wipe's REQUEST becomes a harness-local register, so the durable journal is never written and a relaunch finds a clean device."},
    {"id": "T72-RC40-android-lab-wipe-progress-not-read-from-record", "platform": "jvm", "module": "labmesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/lab/LabWipeJourney.kt", "court": "android/labmesh/src/test/java/io/godstone/labmesh/LabMeshJourneyBoundTest.kt", "gradle_filter": "*LabMeshJourneyBoundTest*", "find": "    fun progress(): Step {\n        val decision = StartupRecoveryGraph.decisionAtRest(journal)", "replace": "    fun progress(): Step {\n        val decision = StartupWipeDecision.CLEAN_START", "witness": "test_the_rendered_wipe_reaches_the_durable_record_and_survives_a_reopen", "why": "the rendered progress stops DERIVING its decision from the durable record and answers a constant, so a device mid-wipe renders a clean status forever."},
    # ----------------------------------------------------------------------
    # *** THE TERMINAL BOARD 1 ROUND (IosRecoveryUi): THE TRUE PRE-PRIVATE
    # RECOVERY TOPOLOGY AND THE RENDERED RETRY/WIPE SURFACES. *** *Anchors are
    # byte-exact against the post-landing tree; IOS-RECOVERY-006 is the
    # type-enforcement rod (the compiler refusing the mutant IS the kill).*
    # ----------------------------------------------------------------------
    {"id": "IOS-RECOVERY-001", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/StartupRecoveryDecision.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsFinal003RecoveryTopologyTests.swift", "swift_filter": "GsFinal003RecoveryTopologyTests/testGSFINAL003_thePermitIsEstateBoundGenerationBoundAndOneShot", "find": "        guard self.estateId == estateId else { return nil }", "replace": "        // estate guard struck: a wrong-estate permit is accepted", "witness": "testGSFINAL003_thePermitIsEstateBoundGenerationBoundAndOneShot", "why": "re-anchored to the CURRENT source: the same production guard, struck byte-exact after the landing moved it (no fabricated old anchor, no old baseline)."},
    {"id": "IOS-RECOVERY-002", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/StartupRecoveryDecision.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsFinal003RecoveryTopologyTests.swift", "swift_filter": "GsFinal003RecoveryTopologyTests", "find": "        case .recoveryPending, .retryableFailure:\n            // *** AN OUTSTANDING WIPE: A DECISION AND NOTHING ELSE. *** *No permit exists for this case, so no", "replace": "        case .recoveryPending, .retryableFailure:\n            if let permit = PrivateRuntimePermit(evidence: RecoveryEvidence(decision: .cleanStart, durableRung: nil, droveTheLadder: false)) {\n                return .normal(permit)\n            }\n            // *** AN OUTSTANDING WIPE: A DECISION AND NOTHING ELSE. *** *No permit exists for this case, so no", "witness": "testGSFINAL003_theTypedTopologyIssuesTheRightPermitAndRefusesTheThirdRoad", "why": "an outstanding estate yields a permit-bearing road: construction-before-terminal returns and the private graph opens over the key a later resume will erase"},
    {"id": "IOS-RECOVERY-003", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/StartupRecoveryDecision.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsFinal003RecoveryTopologyTests.swift", "swift_filter": "GsFinal003RecoveryTopologyTests", "find": "        case .corruptJournal, .terminalFailure:\n            return .refused(decision)\n        }\n    }", "replace": "        case .corruptJournal, .terminalFailure:\n            return .recoveryOnly(decision)\n        }\n    }", "witness": "testGSFINAL003_aCorruptJournalRefusesConstructionAndRequiresAnOperator", "why": "an unreadable record stops refusing: a runtime is built over a record whose gate oracle cannot be read, instead of demanding an operator"},
    {"id": "IOS-RECOVERY-004", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/StartupRecoveryDecision.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsFinal003RecoveryTopologyTests.swift", "swift_filter": "GsFinal003RecoveryTopologyTests/testGSFINAL003_theRecoveryTransportStandsBeforeAndIndependentlyOfTheStoreGraph", "find": "    public var isComplete: Bool {\n        decision == .wipeCompleted && artifactsRemaining.isEmpty\n    }", "replace": "    public var isComplete: Bool {\n        decision == .wipeCompleted\n    }", "witness": "testGSFINAL003_theRecoveryTransportStandsBeforeAndIndependentlyOfTheStoreGraph", "why": "isComplete stops requiring the filesystem half, so a ladder that reached IDLE while a private artifact still stands renders a completed wipe."},
    {"id": "IOS-RECOVERY-005", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsFinal003RecoveryTopologyTests.swift", "swift_filter": "GsFinal003RecoveryTopologyTests", "find": "        case .recoveryPending, .retryableFailure:\n            // *** THE RECOVERY-ONLY ROAD: IT OWNS RECOVERY CAPABILITIES AND CONSTRUCTS NOTHING SENSITIVE. ***\n            //", "replace": "        case .recoveryPending, .retryableFailure:\n            throw MeshRuntimeError.startupRefusedByRecovery(\n                decision: createTimeDecision.name,\n                reason: \"MUTANT: no recovery-only drive\")\n            // *** THE RECOVERY-ONLY ROAD: IT OWNS RECOVERY CAPABILITIES AND CONSTRUCTS NOTHING SENSITIVE. ***\n            //", "witness": "testGSFINAL003_aPendingWipeResolvesThroughThePrePrivateRecoveryBeforeAnyPrivateStore", "why": "an outstanding wipe skips the live pre-private drive, so the journal is never advanced and the ladder's drain guarantee is lost while the composition still answers"},
    {"id": "IOS-RECOVERY-006", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsFinal004OwnedConnectionTests.swift", "swift_filter": "GsFinal004OwnedConnectionTests", "find": "        permit: PrivateRuntimePermit,\n        compositionLane: CompositionLane = .shipping\n    ) throws -> MeshRuntime {", "replace": "        permit: PrivateRuntimePermit? = nil,\n        compositionLane: CompositionLane = .shipping\n    ) throws -> MeshRuntime {", "witness": "testGF004TheCompositionRunsItsStoresOnTheEnginesConnections", "why": "the private road loses its permit parameter, so a caller reaches a keyed private composition without a typed decision: the compiler refuses the mutant, which IS the kill for a type-enforced guard", "type_enforced": True},
    {"id": "IOS-RECOVERY-007", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsFinal003RecoveryTopologyTests.swift", "swift_filter": "GsFinal003RecoveryTopologyTests/testGSFINAL003_aCorruptJournalRefusesConstructionAndRequiresAnOperator", "find": "        switch startupDecision {\n        case .corruptJournal, .terminalFailure:\n            throw MeshRuntimeError.startupRefusedByRecovery(\n                decision: startupDecision.name,\n                reason: startupDecision.refusalReason ?? \"the durable wipe record cannot be read\")\n        case .cleanStart, .wipeCompleted, .recoveryPending, .retryableFailure:", "replace": "        switch startupDecision {\n        case .corruptJournal, .terminalFailure:\n            break\n        case .cleanStart, .wipeCompleted, .recoveryPending, .retryableFailure:", "witness": "testGSFINAL003_aCorruptJournalRefusesConstructionAndRequiresAnOperator", "why": "re-anchored to the CURRENT source: the same production guard, struck byte-exact after the landing moved it (no fabricated old anchor, no old baseline)."},
    {"id": "IOS-RECOVERY-008", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsFinal003RecoveryTopologyTests.swift", "swift_filter": "GsFinal003RecoveryTopologyTests/testGSFINAL003_theRecoveryTransportStandsBeforeAndIndependentlyOfTheStoreGraph", "find": "            runtime: transport,", "replace": "            runtime: WipeDeferredTransportSeam(),", "witness": "testGSFINAL003_theRecoveryTransportStandsBeforeAndIndependentlyOfTheStoreGraph", "why": "re-anchored to the CURRENT source: the same production guard, struck byte-exact after the landing moved it (no fabricated old anchor, no old baseline)."},
    {"id": "IOS-RECOVERY-009", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsFinal003RecoveryTopologyTests.swift", "swift_filter": "GsFinal003RecoveryTopologyTests/testGSFINAL003_theRecoveryTransportStandsBeforeAndIndependentlyOfTheStoreGraph", "find": "            \"mesh.db-wal\": URL(fileURLWithPath: messageStoreUrl.path + \"-wal\"),\n            \"mesh.db-shm\": URL(fileURLWithPath: messageStoreUrl.path + \"-shm\"),\n            \"peer.db\": peerStoreUrl,\n            \"peer.db-wal\": URL(fileURLWithPath: peerStoreUrl.path + \"-wal\"),\n            \"peer.db-shm\": URL(fileURLWithPath: peerStoreUrl.path + \"-shm\"),", "replace": "            \"mesh.db-wal\": URL(fileURLWithPath: messageStoreUrl.path + \"-wal\"),\n            \"mesh.db-shm\": URL(fileURLWithPath: messageStoreUrl.path + \"-shm\"),", "witness": "testGSFINAL003_theRecoveryTransportStandsBeforeAndIndependentlyOfTheStoreGraph", "why": "The artifact map stops naming the sidecars (the GS-STORE-002 step-5 clause and the measured 'every deletion answered .absent' defect), so a wipe completes with mesh.db-wal still holding the rows the main file lacks."},
    {"id": "IOS-RETRY-001", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "swift_filter": "ReadinessT58Tests/testW14ANonTerminalMessageIsResumableEvenWhenTheProjectionUnderReportsIt", "find": "        guard known.isRetryable else {", "replace": "        guard known.retryable else {", "witness": "testW14ANonTerminalMessageIsResumableEvenWhenTheProjectionUnderReportsIt", "why": "The retry guard returns to a projected boolean, so a stale/defaulted projection flag silently omits the retry the user is owed for a non-terminal message."},
    {"id": "IOS-RETRY-002", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshUXModel.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "swift_filter": "ReadinessT58Tests", "find": "    public var permitsResume: Bool {\n        switch self {\n        case .queued, .attempting: return true\n        case .delivered, .cancelled, .expired, .failed: return false\n        }\n    }", "replace": "    public var permitsResume: Bool { true }", "witness": "testW15ATerminalStateIsRefusedAndTheRefusalNamesIt", "why": "A terminal state becomes resumable: the state law is inverted so DELIVERED/CANCELLED rows may be transmitted again."},
    {"id": "IOS-WIPE-UX-001", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/TrustAuthorityAdapter.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT56Tests.swift", "swift_filter": "ReadinessT56Tests/testW14AWipeMayReportCompleteOnlyFromTheDurableOutcome", "find": "        currentWipeState = Self.progress(from: wipeHandler())\n        return currentWipeState\n    }\n\n    /// *** AND THE RESUME IS A REAL RESUME, NOT A SECOND `.complete`. ***", "replace": "        _ = wipeHandler\n        currentWipeState = .complete\n        return currentWipeState\n    }\n\n    /// *** AND THE RESUME IS A REAL RESUME, NOT A SECOND `.complete`. ***", "witness": "testW14AWipeMayReportCompleteOnlyFromTheDurableOutcome", "why": "The trust surface claims a completed wipe it never performed (the measured pre-repair shape): state set before the handler runs, and resume returning .complete without calling anything."},
    {"id": "IOS-WIPE-UX-002", "platform": "ios-ui", "file": "ios/Godstone/Sources/GodstoneMesh/LabRuntime.swift", "court": "ios/Godstone/Tests/LabMeshUITests/LabMeshUITests.swift", "find": "    public func wipeStateName() -> String {\n        let rungs = Self.recoveryLadderRungs()", "replace": "    public func wipeStateName() -> String {\n        if harness.isWiped() { return \"wiped\" }\n        let rungs = Self.recoveryLadderRungs()", "witness": "testGSINT001TheWipeControlReportsTheRuntimesOwnState", "why": "The lab's rendered wipe state returns to a register that owns no ladder, so 'wipe progress from the real reopened store' is a label claiming a rung it never read."},
    {"id": "IOS-SOS-RETRY-001", "platform": "ios-ui", "file": "ios/Godstone/Sources/LabMesh/LabMeshRootApp.swift", "court": "ios/Godstone/Tests/LabMeshUITests/LabMeshUITests.swift", "find": "            Button(\"Retry\") { retrySos() }\n                .accessibilityLabel(\"Retry\")\n                .labTouchTarget()\n                .accessibilityIdentifier(\"lab.sos.retry\")", "replace": "", "witness": "testGSINT001TheEssentialRetryControlStandsAndActs", "why": "The contract's fifth essential control is omitted: no rendered Retry reaches the wired MeshNode.handleSosCommand(.retry) arm, so a user whose call never left can do nothing while a source grep still finds 'retry'."},
    # ----------------------------------------------------------------------
    # *** THE TERMINAL BOARD 1 ROUND (LaneControls / ReleaseSupply /
    # VerifyFreeze): THE LANE CONTROL'S OWN GUARDS, THE POST-RC14 SUPPLY-CHAIN
    # SURFACES, AND THE GATE-MANIFEST/FREEZE CONTRACT. *** *Each rod strikes
    # one production guard; the witness is a committed selftest family, a named
    # court arm, or (for the runner script) an asserted shell invariant.*
    # ----------------------------------------------------------------------
    {"id": "LANE-ROD-1-skip-refusal-disabled", "expect_escaped": ["6", "7a"], "platform": "selftest", "file": "ci/check_lane_results.py", "control": "ci/check_lane_results.py", "selftest_flag": "--selftest-foundation", "find": "    for m in IOS_SKIPPED_ARM.finditer(text):\n        arm = m.group(1).strip()\n        reason = skip_annotation.get(arm, \"\")", "replace": "    for m in []:  # (mutant) the skip refusal is DISABLED: every skipped arm is silently tolerated again\n        arm = m.group(1).strip()\n        reason = skip_annotation.get(arm, \"\")", "witness": "lane-selftest:--selftest-foundation", "why": "EVERY skip must be refused, whatever its reason (the external-blocked allowance is retired). Disabling the refusal loop lets any skipped arm slip through; cases 6 and 7a (an ordinary internal skip, and the historical EXTERNAL-BLOCKED + pinned-artifact reason) both escape."},
    {"id": "LANE-ROD-2-foundation-arm-omission-unguarded", "expect_escaped": ["7b"], "platform": "selftest", "file": "ci/check_lane_results.py", "control": "ci/check_lane_results.py", "selftest_flag": "--selftest-foundation", "find": "    omitted = sorted(required_arms - observed_arms)", "replace": "    omitted = []  # (mutant) the count reconciliation alone is trusted again", "witness": "lane-selftest:--selftest-foundation", "why": "The foundation lane must observe every source-declared arm BY NAME, not merely reconcile a total against a count."},
    {"id": "LANE-ROD-3-foundation-duplicate-arm-unrefused", "expect_escaped": ["7d"], "platform": "selftest", "file": "ci/check_lane_results.py", "control": "ci/check_lane_results.py", "selftest_flag": "--selftest-foundation", "find": "            problems.append(f\"the iOS lane carrieth {times} verdicts for arm {key} -- a duplicated arm would be \"\n                            f\"double-counted\")", "replace": "            pass  # (mutant) a duplicated arm is tolerated", "witness": "lane-selftest:--selftest-foundation", "why": "A duplicated verdict for one arm must be refused (the foundation lane carried no duplicate guard)."},
    {"id": "LANE-ROD-4-simulator-duplicate-narrowed-to-required", "expect_escaped": ["10"], "platform": "selftest", "file": "ci/check_lane_results.py", "control": "ci/check_lane_results.py", "selftest_flag": "--selftest-simulator", "find": "            problems.append(f\"the iOS simulator lane carrieth {times} verdicts for arm {key} -- a duplicated arm \"\n                            f\"would be double-counted\")", "replace": "            pass  # (mutant) only required arms were guarded before", "witness": "lane-selftest:--selftest-simulator", "why": "The simulator duplicate guard must cover EVERY verdict, not only roster-declared arms -- otherwise a duplicated UNDECLARED arm escapes both this guard and the unexpected-arm guard."},
    {"id": "LANE-ROD-5-known-red-allowance-repopulated", "expect_escaped": ["6c"], "platform": "selftest", "file": "ci/check_lane_results.py", "control": "ci/check_lane_results.py", "selftest_flag": "--selftest-ui", "find": "IOS_UI_KNOWN_RED: dict[str, dict] = {}", "replace": "IOS_UI_KNOWN_RED: dict[str, dict] = {\"GodstoneArchiveUITests.testGSA005DocumentReopensAfterCleanProcessDeath\": {\"obligation\": \"x\", \"signature\": \"y\"}}  # (mutant) the stale allowance restored", "witness": "lane-selftest:--selftest-ui", "why": "The retired known-red UI allowance must stay EMPTY: repopulating it would swallow a NEW break of a formerly-known-red arm, and the retirement is enforced by the court."},
    {"id": "LANE-ROD-6-android-runner-aborts-before-digests", "platform": "shell", "file": "tools/readiness/run_android_lanes.sh", "script": "tools/readiness/run_android_lanes.sh", "find": "    --rerun-tasks --no-daemon --console=plain || rc=$?", "replace": "    --rerun-tasks --no-daemon --console=plain\nrc=$?", "witness": "the-runner-keeps-the-lane-alive-under-set-e", "why": "Under `set -e`, a non-zero gradle must NOT abort the runner before it writes post-run digests and runs the pre/post drift check -- the runner PRODUCES evidence and the checker DECIDES.", "guard_only": True, "category_expect": ["structural"], "guard_command": "sh tools/readiness/tests/mutation_runner_keepalive_probe.sh tools/readiness/run_android_lanes.sh"},
    {"id": "RS-IOS-01-debug-symbols-asleep", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_audit_supplychain_harness.py", "find": "    if symbols[\"debug_count\"]:\n", "replace": "    if False and symbols[\"debug_count\"]:\n", "witness": "test_a_debug_laden_image_is_refused", "why": "the debug (stabbing) symbol census is struck: a debug-laden LIGHT image would be called a release candidate instead of being refused as unstripped"},
    {"id": "RS-IOS-02-undefined-mesh-import-asleep", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_audit_supplychain_harness.py", "find": "    for name in symbols[\"undefined\"]:\n        surface = _prohibited_symbol(name)\n        if surface:\n", "replace": "    for name in symbols[\"undefined\"]:\n        surface = _prohibited_symbol(name)\n        if False and surface:\n", "witness": "IosContentInventoryCourt.test_a_mesh_importing_image_is_refused_by_its_symbol_table", "why": "the undefined-symbol exclusion is asleep: a binary that IMPORTS a GodstoneMesh symbol would ride into LIGHT because its load-command dylib list was clean"},
    {"id": "RS-IOS-03-excluded-resource-pattern-asleep", "platform": "python", "file": "scripts/inspect_ios_artifacts.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_audit_supplychain_harness.py", "find": "        for pattern in FORBIDDEN_RESOURCE_PATTERNS:\n            if pattern.search(name):\n", "replace": "        for pattern in FORBIDDEN_RESOURCE_PATTERNS:\n            if False and pattern.search(name):\n", "witness": "IosContentInventoryCourt.test_an_excluded_binary_resource_is_refused", "why": "the excluded-resource scan is asleep: a GodstoneMesh.dylib, an excluded tier archive or a model would travel inside the release bundle unnamed"},
    {"id": "RS-PROOF-01-fabricated-internal-verdict-tolerated", "platform": "python", "file": "tools/supplychain/verify_release_proof.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_audit_supplychain_harness.py", "find": "            if step.get(\"name\") == \"artifact-inspection\" and sv == \"SKIPPED\":\n", "replace": "            if False and step.get(\"name\") == \"artifact-inspection\" and sv == \"SKIPPED\":\n", "witness": "ReleaseProofCourt.test_a_skipped_internal_inspection_is_refused", "why": "the skipped-internal-control gate is struck: a job that SKIPPED its artifact inspection would still be believed under an internal PASS"},
    {"id": "RS-PROOF-02-record-self-digest-asleep", "platform": "python", "file": "tools/supplychain/verify_release_proof.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_audit_supplychain_harness.py", "find": "    elif filed != canonical_document_sha256(document):\n", "replace": "    elif False:\n", "witness": "ReleaseProofCourt.test_an_edited_body_is_caught_by_its_self_digest", "why": "the self-digest recomputation is asleep: a record edited after it was sealed would recompute nothing and be believed"},
    {"id": "RS-PROOF-03-misclassified-external-tolerated", "platform": "python", "file": "tools/supplychain/verify_release_proof.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_audit_supplychain_harness.py", "find": "            if boundary not in EXTERNAL_BOUNDARIES:\n", "replace": "            if False and boundary not in EXTERNAL_BOUNDARIES:\n", "witness": "ReleaseProofCourt.test_an_internal_failure_misclassified_as_external_is_refused", "why": "the external-boundary allowlist is struck: an internal prerequisite failure (an unrelated compile error) could wear an external name and be filed as an external blocker"},
    {"id": "RS-PROOF-04-borrowed-sha-tolerated", "platform": "python", "file": "tools/supplychain/verify_release_proof.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_audit_supplychain_harness.py", "find": "    elif run.get(\"head_sha\") != candidate.get(\"sha\"):\n", "replace": "    elif False:\n", "witness": "ReleaseProofCourt.test_a_borrowed_sha_is_refused", "why": "the run-head-equals-candidate gate is struck: a run that built a BORROWED other sha would be bound to the candidate it did not build"},
    {"id": "RS-DL-01-wrong-download-digest-asleep", "platform": "python", "file": "tools/supplychain/verify_toolchain_download.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_audit_supplychain_harness.py", "find": "    if actual_sha256 != entry[\"sha256\"]:\n", "replace": "    if False and actual_sha256 != entry[\"sha256\"]:\n", "witness": "ToolchainDownloadCourt.test_a_wrong_digest_is_refused_by_name", "why": "the archive's digest comparison is struck: a substituted command-line-tools tarball (same URL, different bytes) would be unzipped and handed to sdkmanager"},
    {"id": "RS-SBOM-01-face-coverage-asleep", "platform": "python", "file": "tools/supplychain/supply_chain.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_audit_supplychain_harness.py", "find": "    missing = sorted(locked - seen)\n", "replace": "    missing = []\n", "witness": "CycloneDxCoverageCourt.test_a_face_that_omits_a_locked_component_is_refused", "why": "the face-coverage control is muzzled: a published CycloneDX face that omiteth a locked component would pass, so the inventory could quietly lose a dependency"},
    {"id": "RS-SBOM-02-lock-version-drift-tolerated", "platform": "python", "file": "tools/supplychain/supply_chain.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_audit_supplychain_harness.py", "find": "                key = f\"pypi:{name}:{entry.get('version')}\"\n                if key not in names:\n", "replace": "                key = f\"pypi:{name}:{entry.get('version')}\"\n                if False and key not in names:\n", "witness": "SbomVersionDriftCourt.test_a_moved_version_is_refused_by_name", "why": "the exact-version binding is asleep: a lock pin whose VERSION moved without the SBOM being rebuilt would pass because only the name is matched"},
    {"id": "RS-DL-02-cached-tool-tree-digest-asleep", "platform": "python", "file": "tools/supplychain/verify_toolchain_download.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_audit_supplychain_harness.py", "find": "    if digest != extracted.get(\"tree_sha256\"):\n", "replace": "    if False and digest != extracted.get(\"tree_sha256\"):\n", "witness": "ToolchainDownloadCourt.test_a_cached_tree_that_is_not_the_pinned_contents_is_refused", "why": "the extracted-tree content digest is struck: a preexisting $ANDROID_HOME/cmdline-tools/<version> that is NOT the pinned contents would be silently trusted instead of refused"},
    {"id": "T86-B1M1-manifest-may-omit-a-required-gate", "platform": "python", "file": "ci/check_board1_manifest.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_board1_gate_manifest.py", "find": "    missing = [g for g in expected if g not in recorded]", "replace": "    missing = []  # (mutant) a manifest may omit a required gate and still PASS", "witness": "test_a_manifest_omitting_a_required_gate_is_refused", "why": "THE CENTRAL DEFECT THIS CONTRACT EXISTS TO REFUSE: a manifest that dropped a required gate row would read as a COMPLETE run while the omitted gate never ran. A reader would re-run the manifest and reproduce four of five gates. The witness `test_a_manifest_omitting_a_required_gate_is_refused` condemneth: an omitted gate must be named, not tolerated."},
    {"id": "T86-B1M2-nonzero-gate-reads-as-pass", "platform": "python", "file": "ci/check_board1_manifest.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_board1_gate_manifest.py", "find": "        if row.get(\"verdict\") != \"PASS\" or row.get(\"rc\") != 0:", "replace": "        if False:  # (mutant) a non-zero gate exit passeth for a PASS manifest", "witness": "test_a_gate_that_returned_nonzero_is_refused", "why": "A FAILING GATE IS THE ONE THING A PASS MANIFEST MUST NEVER CARRIED. Muzzled, a run in which the readiness suites returned 1 would emit a green manifest naming that gate, and the freeze would bind it. The witness `test_a_gate_that_returned_nonzero_is_refused` condemneth; the builder-side companion `test_the_builder_refuses_to_emit_after_a_nonzero_gate` proves the EMISSION door is shut too."},
    {"id": "T86-B1M3-campaign-tested-inputs-may-move", "platform": "python", "file": "ci/check_board1_manifest.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_board1_gate_manifest.py", "find": "            elif tested[key] != current[key]:", "replace": "            elif False:  # (mutant) a campaign may have run against other bytes", "witness": "test_a_campaign_whose_tested_input_moved_is_refused", "why": "A KILL RECORDED AGAINST A DIFFERENT TREE IS NOT EVIDENCE ABOUT THIS ONE. Muzzled, a campaign whose Swift sources, Kotlin sources, `ios/project.yml` or `ci/mutations.py` changed AFTER it ran still reads as bound. The witness `test_a_campaign_whose_tested_input_moved_is_refused` condemneth."},
    {"id": "T86-B1M4-escaped-rod-counts-as-killed", "platform": "python", "file": "ci/check_board1_manifest.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_board1_gate_manifest.py", "find": "    bad = sorted(i for i in required if outcomes.get(i) != \"KILLED\")", "replace": "    bad = []  # (mutant) a rod that ESCAPED counteth as a kill", "witness": "test_a_rod_that_escaped_is_refused", "why": "AN ESCAPED ROD IS THE HONEST NAME OF A CONTROL THAT DOES NOT BITE; counting it as a kill is the false-green the ledger's own rules spend their length refusing. The witness `test_a_rod_that_escaped_is_refused` condemneth."},
    {"id": "T86-B1M5-tampered-gate-log-is-believed", "platform": "python", "file": "ci/check_board1_manifest.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_board1_gate_manifest.py", "find": "        if sha256_bytes(blob) != log.get(\"sha256\"):", "replace": "        if False:  # (mutant) a gate log edited after binding is believed", "witness": "test_a_gate_log_edited_after_binding_is_refused", "why": "THE LOG IS THE GATE'S ONLY RETAINED EVIDENCE; a digest that is recorded but never recomputed is a digest that only LOOKS like a binding. The witness `test_a_gate_log_edited_after_binding_is_refused` condemneth."},
    {"id": "T86-B1M6-a-narrowed-campaign-population-passes", "platform": "python", "file": "ci/check_board1_manifest.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_board1_gate_manifest.py", "find": "    omitted = sorted(required - selected)", "replace": "    omitted = []  # (mutant) a campaign may select a subset of the required ids", "witness": "test_a_campaign_population_that_disagrees_with_the_ledger_is_refused", "why": "*** A NARROWED POPULATION THAT STILL PASSES IS THE FALSE-GREEN THE MANIFEST CONTRACT NAMES IN ITS OWN DOCSTRING. *** A campaign that ran twelve of fifty rods and recorded twelve killed rows would read as 'the campaign passed'. The witness `test_a_campaign_population_that_disagrees_with_the_ledger_is_refused` condemneth on the required_ids leg and the selected_ids leg alike."},
    {"id": "T86-B1M7-absent-lane-artifact-is-ignored", "platform": "python", "file": "ci/check_board1_manifest.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_board1_gate_manifest.py", "find": "    missing = [l for l in REQUIRED_LANES if l not in recorded]", "replace": "    missing = []  # (mutant) a lane that produced no artifact may be silently absent", "witness": "test_a_manifest_omitting_a_required_lane_is_refused", "why": "A LANE THAT PRODUCED NOTHING IS EXACTLY WHAT A GREEN SUMMARY HIDES: the simulator lane is the one whose absence was measured before. The witness `test_a_manifest_omitting_a_required_lane_is_refused` condemneth, and the companion `test_a_lane_absent_from_the_artifact_but_unidentified_is_refused` proves the artifact level too."},
    {"id": "T86-B1M8-stale-lane-digest-is-believed", "platform": "python", "file": "ci/check_board1_manifest.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_board1_gate_manifest.py", "find": "                if lane.get(\"digest\") != live:", "replace": "                if False:  # (mutant) a lane whose sources moved since it ran is believed", "witness": "test_a_stale_lane_source_digest_is_refused", "why": "A LANE LOG WHOSE SOURCE DIGEST NO LONGER MATCHES THE TREE DESCRIBES A REVISION NOBODY CAN NAME. The witness `test_a_stale_lane_source_digest_is_refused` condemneth."},
    {"id": "T86-B1M9-mid-run-lane-drift-is-ignored", "platform": "python", "file": "ci/check_board1_manifest.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_board1_gate_manifest.py", "find": "        if pre_text and post_text and pre_text != post_text:", "replace": "        if False:  # (mutant) a lane input that changed mid-run is ignored", "witness": "test_a_lane_whose_pre_and_post_digests_disagree_is_refused", "why": "THE PRE/POST DIGEST PAIR IS THE ONLY THING THAT DISTINGUISHES 'one revision was compiled' FROM 'the sidecar was rewritten after an edit'. The witness `test_a_lane_whose_pre_and_post_digests_disagree_is_refused` condemneth."},
    {"id": "T86-B1M10-candidate-tree-need-not-be-stated", "platform": "python", "file": "ci/check_board1_manifest.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_board1_gate_manifest.py", "find": "        if not _is_full_sha(tree):", "replace": "        if False:  # (mutant) an unstaked tree is accepted", "witness": "test_a_manifest_with_no_candidate_sha_or_tree_is_refused", "why": "A CANDIDATE BINDING THAT NAMES A COMMIT WHOSE BYTES NOBODY STATED IS UNFALSIFIABLE -- the reader has no tree to compare and the freeze's own tree clause has nothing to bite on. The witness `test_a_manifest_with_no_candidate_sha_or_tree_is_refused` condemneth on the tree leg."},
    {"id": "T86-B1M11-dirty-freeze-tree-is-accepted", "platform": "python", "file": "ci/check_board1_manifest.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_board1_gate_manifest.py", "find": "        if not block.get(\"ok\"):", "replace": "        if False:  # (mutant) a dirty working tree may still be frozen", "witness": "test_a_dirty_start_or_end_is_refused", "why": "A FREEZE TAKEN WITH UNCOMMITTED TRACKED CHANGES COMPILES BYTES THE CANDIDATE NEVER HAD. The witness `test_a_dirty_start_or_end_is_refused` condemneth for both the start and the end."},
    {"id": "T86-B1M12-lightweight-candidate-tag-is-accepted", "platform": "python", "file": "ci/check_board1_manifest.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_board1_gate_manifest.py", "find": "            if not ident.get(\"annotated\"):", "replace": "            if False:  # (mutant) a lightweight candidate tag is accepted", "witness": "test_a_lightweight_candidate_tag_is_refused", "why": "A LIGHTWEIGHT TAG CARRIETH NO TAG OBJECT AND CAN BE RE-POINTED WITHOUT TRACE, so the SHA binding the whole design rests on would be a bare pointer. The witness `test_a_lightweight_candidate_tag_is_refused` condemneth."},
    {"id": "T86-B1M13-closure-counts-may-disagree", "platform": "python", "file": "ci/check_board1_manifest.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_board1_gate_manifest.py", "find": "                    problems.append(f\"structured counts DISAGREE: manifest {key}={derived.get(key)!r} != derived \"\n                                    f\"{live.get(key)!r} -- the closure ledger mismatch this contract refuses\")", "replace": "                    pass  # (mutant) two structured representations of one state may disagree", "witness": "test_a_manifest_whose_structured_counts_drift_from_the_ledger_is_refused", "why": "THE CLOSURE LEDGER MISMATCH NAMED IN THE ASSIGNMENT: persisted counts that no longer agree with the derivation are a second, stale representation of the same state -- and a reader cannot tell which is authority. The witness `test_a_manifest_whose_structured_counts_drift_from_the_ledger_is_refused` condemneth."},
    {"id": "T86-B1M14-builder-emits-a-partial-manifest", "platform": "python", "file": "ci/check_board1_manifest.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_board1_gate_manifest.py", "find": "    if missing or unreadable or nonzero or unlogged:\n        raise ManifestRefused(_accounting_problems(missing, unreadable, nonzero, unlogged))", "replace": "    if False:  # (mutant) a partial run may still emit a PASS manifest\n        raise ManifestRefused(_accounting_problems(missing, unreadable, nonzero, unlogged))", "witness": "test_the_builder_refuses_to_emit_from_an_incomplete_gate_run", "why": "*** 'NO PARTIAL SUCCESS' IS ENFORCED BY CONSTRUCTION: THE BUILDER IS THE ONLY DOOR TO A PASS DOCUMENT. *** *Opened, a subset or failing run EMITS a manifest and every downstream reader treats it as the whole gate set.* The witness `test_the_builder_refuses_to_emit_from_an_incomplete_gate_run` condemneth (the builder must RAISE, so an accepted document fails the `assertRaises`)."},
    {"id": "T86-B1M15-relative-attest-path-crasheth", "platform": "python", "file": "tools/readiness/board1.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_board1_gate_manifest.py", "find": "    attest_abs = attest_out if attest_out.is_absolute() else (ROOT / attest_out)\n    try:\n        attest_rel = str(attest_abs.resolve().relative_to(ROOT.resolve()))", "replace": "    attest_abs = attest_out\n    try:\n        attest_rel = str(attest_abs.relative_to(ROOT))", "witness": "test_a_relative_attestation_path_is_resolved_and_never_crashes", "why": "*** THE MEASURED PRODUCTION DEFECT: `attest_out.relative_to(ROOT)` RAISETH `ValueError` ON THE RELATIVE `--attest-out docs/remediation/evidence/FREEZE_ATTESTATION_rcNN.json` THE PLAN'S OWN COMMAND LINE USES, SO THE FREEZE DIED WITH A PYTHON TRACEBACK BEFORE ANY CHECK COULD SPEAK. *** *Restored, the freeze crashes instead of writing the attestation, so the witness fails.* The witness `test_a_relative_attestation_path_is_resolved_and_never_crashes` condemneth; its companion `test_an_attestation_path_outside_the_repository_is_refused_by_name` proves the outside-tree leg is a NAMED refusal rather than a crash."},
    {"id": "T86-B1M16-bound-manifest-is-not-re-derived", "platform": "python", "file": "tools/readiness/board1.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_board1_gate_manifest.py", "find": "            if _sha256(manifest_path) != bound.get(\"sha256\"):", "replace": "            if False:  # (mutant) the attestation's bound manifest is never re-derived", "witness": "test_a_manifest_edited_after_the_attestation_bound_it_is_refused", "why": "AN ATTESTATION THAT NAMETH A MANIFEST WHOSE BYTES MOVED IS CLAIMING INTERNAL GATE EVIDENCE THAT IS NO LONGER THERE. The witness `test_a_manifest_edited_after_the_attestation_bound_it_is_refused` condemneth."},
    {"id": "T86-B1M17-foreign-candidate-manifest-is-bound", "platform": "python", "file": "tools/readiness/board1.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_board1_gate_manifest.py", "find": "    if m_cand.get(\"sha\") != peeled:", "replace": "    if False:  # (mutant) a manifest describing another tree may be bound", "witness": "test_a_manifest_bound_to_another_candidate_is_refused_by_the_freeze", "why": "THE STALE-AUTHORITY DEFECT THE WHOLE BINDING EXISTS TO REFUSE, ONE LAYER UP: a freeze that bound a manifest whose `candidate.sha` is not the tag's peel would certify internal gates that ran against some OTHER tree. The witness `test_a_manifest_bound_to_another_candidate_is_refused_by_the_freeze` condemneth."},
    # ----------------------------------------------------------------------
    # *** THE TERMINAL BOARD 1 ROUND (StressHonesty): THE T72 RESOURCE-MODEL
    # CONDUCTOR AND ITS JVM/SWIFT TWINS. *** *Each rod strikes a named defect class
    # (vacuous measured/unmeasured census, relabelled category, self-agreeing number,
    # constant-zero observer, deaf fault campaign); the witness is a named court arm.*
    # ----------------------------------------------------------------------
    {"id": "SH-R01-python-the-timer-release-defect-is-a-no-op", "platform": "python", "file": "tools/readiness/stress.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t72.py", "find": "        if not in_flight and self.defect != CampaignDefect.NO_TIMER_RELEASE:\n            self.timers = max(0, self.timers - 1)", "replace": "        # (mutant) the PER-OWNER timer defect is a no-op: the timer owner can no longer be leaked alone\n        self.timers = max(0, self.timers - 1)", "witness": "test_w09_the_named_negative_each_defect_is_caught_by_name", "why": "Per-owner negative control: the timer owner's own defect must actually leak it, or `no_leaked_timers` has no independent falsifier."},
    {"id": "SH-R02-python-shutdown-stops-releasing-the-timer-owner", "platform": "python", "file": "tools/readiness/stress.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t72.py", "find": "        if self.defect != CampaignDefect.NO_TIMER_RELEASE:\n            self.timers = 0", "replace": "        # (mutant) shutdown releases the timer owner unconditionally: the defect is masked\n        self.timers = 0", "witness": "test_w09_the_named_negative_each_defect_is_caught_by_name", "why": "Shutdown must release EACH owner by its own clause; a masked owner is an unmeasured one."},
    {"id": "SH-R03-python-shutdown-stops-releasing-the-session-owner", "platform": "python", "file": "tools/readiness/stress.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t72.py", "find": "        if self.defect != CampaignDefect.NO_SESSION_RELEASE:\n            self.sessions = 0", "replace": "        # (mutant) shutdown releases the session owner unconditionally: the defect is masked\n        self.sessions = 0", "witness": "test_w09_the_named_negative_each_defect_is_caught_by_name", "why": "Same class as SH-R02, for the session owner."},
    {"id": "SH-R04-python-the-fault-liveness-clause-is-asleep", "platform": "python", "file": "tools/readiness/stress.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t72.py", "find": "        if refusals_expected and result.refusals < refusals_expected:", "replace": "        if False and refusals_expected and result.refusals < refusals_expected:", "witness": "test_w08b_the_fault_liveness_clause_biteth", "why": "A scheduled refusing fault that never fired (a DEAF campaign) must be reported; a control gap must not pass as a clean run."},
    {"id": "SH-R05-python-the-category-is-carried-as-the-production-runtime", "platform": "python", "file": "tools/readiness/stress.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t72.py", "find": "    category: str = Category.RESOURCE_MODEL", "replace": "    category: str = Category.PRODUCTION_RUNTIME  # (mutant) the model carrieth the runtime's name", "witness": "test_w14b_the_category_is_carried_on_the_result_and_in_the_report", "why": "The category must be CARRIED as `resource-model`; the audit asked by name for a rod that makes a model result quotable as a runtime result."},
    {"id": "SH-R06-python-the-unmeasured-invariant-set-is-silently-empty", "platform": "python", "file": "tools/readiness/stress.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t72.py", "find": "    unmeasured_invariants: tuple = Invariant.UNMEASURED", "replace": "    unmeasured_invariants: tuple = ()  # (mutant) nobody was asked, and the result sayeth nothing", "witness": "test_w09b_the_measured_and_unmeasured_sets_are_typed_and_carried", "why": "The four owner-kind names must be CARRIED as unmeasured when nothing can ask them -- 'nothing is leaking' must not be collapsed with 'nobody asked my kind of owner'."},
    {"id": "SH-R07-python-the-unmeasured-owner-kinds-are-unnamed", "platform": "python", "file": "tools/readiness/stress.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_t72.py", "find": "    unmeasured_owners: tuple = UNMEASURED_OWNER_KINDS", "replace": "    unmeasured_owners: tuple = ()  # (mutant) the unasked owner kinds are unnamed", "witness": "test_w09b_the_measured_and_unmeasured_sets_are_typed_and_carried", "why": "The result must NAME the owner kinds it could not ask, not merely the invariants."},
    {"id": "SH-R08-jvm-the-not-measured-sentinel-collapses-into-zero", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/stress/StressCampaign.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT72Test.kt", "gradle_filter": "*ReadinessT72Test*", "find": "        const val NOT_MEASURED: Int = -1", "replace": "        const val NOT_MEASURED: Int = 0   // (mutant) unmeasured collapses into a convenient zero", "witness": "testGSSTRESS001aMeasuredCleanOwnerIsNeitherAccusedNorUnmeasured", "why": "An owner whose kind cannot be censused must answer NOT_MEASURED (-1), never a convenient zero; collapsing the sentinel makes an unmeasured owner indistinguishable from a clean one."},
    {"id": "SH-R09-jvm-the-unmeasured-invariants-set-is-never-filled", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/stress/StressCampaign.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT72Test.kt", "gradle_filter": "*ReadinessT72Test*", "find": "        if (owners.isEmpty()) unmeasuredInvariants.addAll(Invariants.OWNER_KIND)", "replace": "        if (false) unmeasuredInvariants.addAll(Invariants.OWNER_KIND)   // (mutant) the unasked are unnamed", "witness": "test_w09c_the_result_carrieth_its_category_and_its_unmeasured_set", "why": "A campaign that asked no owner must NAME the four owner-kind invariants unmeasured."},
    {"id": "SH-R10-jvm-the-category-is-carried-as-the-production-runtime", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/stress/StressCampaign.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT72Test.kt", "gradle_filter": "*ReadinessT72Test*", "find": "    val category: String = Category.RESOURCE_MODEL,", "replace": "    val category: String = Category.PRODUCTION_RUNTIME,   // (mutant) the model weareth the runtime's name", "witness": "test_w09c_the_result_carrieth_its_category_and_its_unmeasured_set", "why": "The carried category must be `resource-model`."},
    {"id": "SH-R11-jvm-the-missing-observer-unmeasured-branch-is-removed", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/stress/StressCampaign.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT72Test.kt", "gradle_filter": "*ReadinessT72Test*", "find": "                observers == ResourceCensusSource.NOT_MEASURED -> {\n                    unmeasuredOwners.add(\"${owner.ownerName} (observers)\")\n                    unmeasuredInvariants.add(Invariants.NO_LEAKED_OBSERVERS)\n                }", "replace": "                observers == -2 -> {   // (mutant) the observer kind's unmeasured branch is unreachable\n                    unmeasuredOwners.add(\"${owner.ownerName} (observers)\")\n                    unmeasuredInvariants.add(Invariants.NO_LEAKED_OBSERVERS)\n                }", "witness": "testGSSTRESS001anUnmeasurableOwnerIsNamedRatherThanAssumedClean", "why": "An owner that answers NOT_MEASURED for the observer kind must be NAMED unmeasured, never accused and never treated clean."},
    {"id": "SH-R12-swift-shutdown-stops-releasing-the-timer-owner", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/StressCampaign.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT72Tests.swift", "swift_filter": "ReadinessT72Tests", "find": "        if defect != CampaignDefect.noTimerRelease { timers = 0 }", "replace": "        timers = 0   // (mutant) shutdown releases the timer owner unconditionally: the defect is masked", "witness": "testW09EachDefectIsCaughtByName", "why": "Shutdown must release each owner by its own clause."},
    {"id": "SH-R13-swift-the-unmeasured-set-omits-the-reservation-owner", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/StressCampaign.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT72Tests.swift", "swift_filter": "ReadinessT72Tests", "find": "        if owners.isEmpty { unmeasuredInvariants.insert(Invariants.noLeakedReservations, at: 0) }", "replace": "        if false { unmeasuredInvariants.insert(Invariants.noLeakedReservations, at: 0) }   // (mutant) unasked, unnamed", "witness": "testW15bTheResultCarriethItsCategoryAndItsUnmeasuredSet", "why": "With no owner handed in, the reservation kind must be NAMED unmeasured."},
    {"id": "SH-R14-swift-the-protocol-default-answereth-a-constant-zero", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/StressCampaign.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT72Tests.swift", "swift_filter": "ReadinessT72Tests", "find": "    func liveReservations() -> Int { NOT_MEASURED }", "replace": "    func liveReservations() -> Int { 0 }   // (mutant) an unmeasurable owner answereth a convenient zero", "witness": "testW15cTheReservationOwnerIsCensusedOnThisIsleToo", "why": "An owner that carrieth no reservations must answer NOT_MEASURED, never 0."},
    # ----------------------------------------------------------------------
    # *** IOS-TRANSPORT-001 (IosRecoveryUi, retained scope): the BLE service-discovery
    # nil-coercion defect. ***
    # ----------------------------------------------------------------------
    {"id": "IOS-TRANSPORT-001-nil-services-coerced-to-discovery-success", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/BleLinkSubstrateTests.swift", "swift_filter": "BleLinkSubstrateTests", "swift_target": "GodstoneMeshTests", "find": "        let observedService = p?.services?.first(where: { $0.uuid == BleTransport.serviceUuid })\n        // *The `?? true` is gone: `first(where:)` yieldeth `nil` for a nil peripheral, a nil `services` array, an\n        // empty list or a list carrieth no mesh service -- and NOTHING is coerced here, so an observ'd absence\n        // stayeth an absence and the driver is told so. Only an OBSERVED mesh service can turn this `true`.*\n        let success = (error == nil && observedService != nil)", "replace": "        let observedService = p?.services?.first(where: { $0.uuid == BleTransport.serviceUuid })\n        let success = (error == nil && ((p?.services?.contains(where: { $0.uuid == BleTransport.serviceUuid })) ?? true))", "witness": "testGSINT001ADiscoveryThatObservedNoMeshServiceIsNotReportedAsSuccess", "why": "an observed absence (nil peripheral / nil or empty services / wrong-uuid list) is coerced back to discovery SUCCESS by the `?? true`, so the driver is told a mesh service was found and proceeds without characteristics until the deadline. Only an OBSERVED mesh service may turn the verdict true."},
    # ----------------------------------------------------------------------
    # *** ANDROID ESTATE-AUTHORITY CUTOVER (AndroidEstateAuthority): A2/A3/A7/A8/A9/A13.
    # *** *Supersedes the prose-only AndroidAuthority set; every witness is an arm of
    # GsFinal003EstateAuthorityCourtsTest.kt.*
    # ----------------------------------------------------------------------
    {"id": "ANDE-A9-01-CHECKPOINT-VERDICT-DISCARDED", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/identity/CrashResumableWipe.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003EstateAuthorityCourtsTest.kt", "gradle_filter": "*GsFinal003EstateAuthorityCourtsTest*", "find": "        if (!store.appendJournalDurably(WipeJournalState.REQUESTED.name)) return false", "replace": "        store.appendJournalDurably(WipeJournalState.REQUESTED.name)", "witness": "aFailedCheckpointStopsTheLadderBeforeAnyEffect", "why": "A9: the request checkpoint's verdict is discarded, so a record that never reached disk is treated as durable and the ladder runs its effects (drain, key erase, artifact delete) over an estate the record still describes as untouched. The court counts the real seam effects and reddens."},
    {"id": "ANDE-A9-02-PERSISTED-RUNG-VERDICT-DISCARDED", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/identity/CrashResumableWipe.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003EstateAuthorityCourtsTest.kt", "gradle_filter": "*GsFinal003EstateAuthorityCourtsTest*", "find": "        if (!store.appendJournalDurably(to.name)) return false", "replace": "        store.appendJournalDurably(to.name)", "witness": "aFailedCheckpointStopsTheLadderBeforeAnyEffect", "why": "A9: a NON-terminal rung's checkpoint is not consulted, so the ladder steps to the NEXT rung after a write that never landed -- the coordinator and the record disagree about how far the erasure has advanced. Reddens the same effect-counting arm."},
    {"id": "ANDE-A2-03-ABA-EPOCH-DROPPED-FROM-REVISION", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/identity/CrashResumableWipe.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003EstateAuthorityCourtsTest.kt", "gradle_filter": "*GsFinal003EstateAuthorityCourtsTest*", "find": "        return view.joinToString(\",\") { it!!.name } + \"|true|\" + epoch", "replace": "        return view.joinToString(\",\") { it!!.name } + \"|true\"", "witness": "aCompletedWipeIsADifferentEstate", "why": "A2/A8 noABA: the durable generation is dropped from the live revision, so IDLE -> wipe -> IDLE yields the SAME revision string and a permit minted over the pre-wipe estate is accepted over the post-wipe one. The court asserts before != after across a full ladder."},
    {"id": "ANDE-A2-04-REVISION-FROM-COORDINATOR-SNAPSHOT", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/identity/CrashResumableWipe.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003EstateAuthorityCourtsTest.kt", "gradle_filter": "*GsFinal003EstateAuthorityCourtsTest*", "find": "        val lines = store.readJournal()", "replace": "        val lines = journal.toList()", "witness": "aCompletedWipeIsADifferentEstate", "why": "A2: the revision is derived from the in-memory mirror instead of re-reading the store, so a write by ANOTHER instance (or an operator) leaves the revision unchanged -- the exact 'revisionOf reads coordinator snapshot not live journal' defect."},
    {"id": "ANDE-A2-05-PERMIT-NOT-REVALIDATED-AT-CONSUMPTION", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/di/EstateAuthority.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003EstateAuthorityCourtsTest.kt", "gradle_filter": "*GsFinal003EstateAuthorityCourtsTest*", "find": "        require(estateRevision == executingRevision) {", "replace": "        require(true) {", "witness": "aCompletedWipeIsADifferentEstate", "why": "A2 stale/wrongestate: the consumption-time estate equality check is disabled, so a permit minted before a wipe admits construction after it. The court requires that requireLiveFor FAILS against the moved estate."},
    {"id": "ANDE-A2-06-ADAPTER-LEGAL-NEXT-CHECK-DROPPED", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/identity/WipeJournalDurabilityAdapter.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003EstateAuthorityCourtsTest.kt", "gradle_filter": "*GsFinal003EstateAuthorityCourtsTest*", "find": "            if (!isLegalNext(current, state)) return false", "replace": "            if (false) return false", "witness": "theProductionJournalReportsItsCommitVerdict", "why": "A2/A8 second-owner checkpoint regression: the strict-monotone guard is struck, so a stale writer moves the single durable value BACKWARD and the record stops describing the erasure that actually ran. The court asserts a backward write is refused and the record stays put."},
    {"id": "ANDE-A3-07-PUBLIC-PERMIT-FROM-A-BARE-DECISION", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/di/EstateAuthority.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003EstateAuthorityCourtsTest.kt", "gradle_filter": "*GsFinal003EstateAuthorityCourtsTest*", "find": "        fun issue(evidence: RecoveryEvidence): PrivateStorePermit? =", "replace": "        fun issue(decision: StartupWipeDecision, revision: String): PrivateStorePermit =\n            PrivateStorePermit(decision, revision)\n\n        fun issue(evidence: RecoveryEvidence): PrivateStorePermit? =", "witness": "thePermitDoorAdmitsOnlyNonConstructibleEvidence", "why": "A3 self-mint: a public door that takes a bare enum (+ string) is restored, so any :mesh caller -- including a runtime constructor -- can mint the authority the gate exists to withhold. The court asserts the PUBLIC overload set is exactly [RecoveryEvidence]."},
    {"id": "ANDE-A13-08-PUBLIC-RAW-IDENTITY-FACTORY", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/identity/Identity.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003EstateAuthorityCourtsTest.kt", "gradle_filter": "*GsFinal003EstateAuthorityCourtsTest*", "find": "        internal fun loadOrCreate(ctx: Context, token: PrivateOwnerToken): Identity =", "replace": "        fun loadOrCreate(ctx: Context): Identity =\n            loadOrCreate(EncryptedSharedPreferencesStorage(ctx), SecureRandom())\n\n        internal fun loadOrCreate(ctx: Context, token: PrivateOwnerToken): Identity =", "witness": "thePermitDoorAdmitsOnlyNonConstructibleEvidence", "why": "A13 raw bypass: the public single-argument private-identity factory is restored, so a caller opens real Keystore-backed identity material without ever consulting the durable estate. The court asserts NO public onearg loadOrCreate exists."},
    {"id": "ANDE-A8-09-REENTRANCY-GUARD-DROPPED", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/di/EstateAuthority.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003EstateAuthorityCourtsTest.kt", "gradle_filter": "*GsFinal003EstateAuthorityCourtsTest*", "find": "        require(!inDrive) { \"GS-FINAL-003: a drive of this estate is already in progress on this thread\" }", "replace": "        require(true) { \"unused\" }", "witness": "aReentrantDriveOnTheOneOwnerIsRefused", "why": "A8 duplicate effects: a reentrant drive on the one owner is no longer refused, so an injected hook/seam re-enters and runs the ladder twice over one durable record. The court asserts the inner drive is refused AND that the guard clears in a finally."},
    {"id": "ANDE-A7-10-OPERATOR-RESOLUTION-SKIPS-THE-DURABLE-REQUEST", "platform": "jvm", "module": "mesh", "test_task": "testDebugUnitTest", "file": "android/mesh/src/main/java/io/godstone/mesh/di/EstateAuthority.kt", "court": "android/mesh/src/test/java/io/godstone/mesh/di/GsFinal003EstateAuthorityCourtsTest.kt", "gradle_filter": "*GsFinal003EstateAuthorityCourtsTest*", "find": "        if (!coordinator.recordRequestDurably()) {", "replace": "        if (false) {", "witness": "theCorruptResolutionErasesAndNeverClaimsCleanStart", "why": "A7 clear-then-clean: the operator's resolution no longer durably records REQUESTED over the corrupt marker, so the following resume refuses the unreadable record and NOTHING is erased while the UI is told an operator acted. The court counts the real key/artifact effects."},
    # ----------------------------------------------------------------------
    # *** IOS RECOVERY/ESTATE AUTHORITY (IosRecoveryAuthority): IOS-R1,R2,R3,R4,R5,
    # R7,R8,R11,R14. *** *Witnesses in GsFinal003RecoveryTopologyTests /
    # GsFinal003StartupPermitTests; MUT-IOS-R14-CORRUPT-ARG is the compile-negative.*
    # ----------------------------------------------------------------------
    {"id": "MUT-IOS-R1-PERMIT-NOT-CONSUMED", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/StartupRecoveryDecision.swift", "court": "GsFinal003RecoveryTopologyTests", "swift_filter": "testGSFINAL003_thePermitIsEstateBoundGenerationBoundAndOneShot", "find": "        guard consumption.consume() else { return nil }", "replace": "        _ = consumption.consume()", "witness": "testGSFINAL003_thePermitIsEstateBoundGenerationBoundAndOneShot", "why": "the one-shot consumption no longer refuses a replay, so the REUSED clause of the permit witness must fail"},
    {"id": "MUT-IOS-R1-PERMIT-GENERATION-IGNORED", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/StartupRecoveryDecision.swift", "court": "GsFinal003RecoveryTopologyTests", "swift_filter": "testGSFINAL003_thePermitIsEstateBoundGenerationBoundAndOneShot", "find": "        guard let liveGeneration, self.generation == liveGeneration else { return nil }", "replace": "        // generation guard removed: unknown/stale generations are accepted", "witness": "testGSFINAL003_thePermitIsEstateBoundGenerationBoundAndOneShot", "why": "the stale/ABA clause of the permit witness reddens"},
    {"id": "MUT-IOS-R1-NORMAL-HELPER-BYPASS", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift", "court": "GsFinal003RecoveryTopologyTests", "swift_filter": "testGSFINAL003_aRecoveryThatCannotSettleRefusesAndOpensNothing", "find": "            let admission = try Self.requirePermitConsumption(\n                permit: permit,\n                messageStoreUrl: messageStoreUrl,\n                peerStoreUrl: peerStoreUrl,\n                generation: liveGeneration)", "replace": "            let admission = (estateId: Self.recoveryEstateId(artifactPaths: Self.wipeArtifactPaths(messageStoreUrl: messageStoreUrl, peerStoreUrl: peerStoreUrl)), generation: liveGeneration ?? 0)", "witness": "testGSFINAL003_aRecoveryThatCannotSettleRefusesAndOpensNothing", "why": "a refused permit no longer stops construction (the bypass), so the zero-opens arm reddens"},
    {"id": "MUT-IOS-R2-GATE-CACHED-SNAPSHOT", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/CrashResumableWipe.swift", "court": "GsFinal003RecoveryTopologyTests", "swift_filter": "testGSFINAL003_aRetainedOwnerObservesAnotherOwnersWipe", "find": "    private func liveJournal() -> [String] { store.readJournal() }", "replace": "    private func liveJournal() -> [String] { journal }", "witness": "testGSFINAL003_aRetainedOwnerObservesAnotherOwnersWipe", "why": "the gate reads the birth-time mirror, so another owner's wipe is invisible and the witness fails"},
    {"id": "MUT-IOS-R2-ARTIFACT-ORACLE-CACHED", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/WipeArtifactFileSystemSeam.swift", "court": "GsFinal003RecoveryTopologyTests", "swift_filter": "testGSFINAL003_aRetainedOwnerObservesAnotherOwnersWipe", "find": "        let rungs = liveRung()", "replace": "        let rungs = [String]()   // cached: the live oracle is never consulted", "witness": "testGSFINAL003_aRetainedOwnerObservesAnotherOwnersWipe", "why": "an artifact stays readable during another owner's wipe (the mutation the review named)"},
    {"id": "MUT-IOS-R3-APPEND-IGNORES-COMMIT", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/WipeJournalDurabilityAdapter.swift", "court": "GsFinal003RecoveryTopologyTests", "swift_filter": "testGSFINAL003_aDroppedTerminalCheckpointNeverSettles", "find": "        guard written.synchronized else {", "replace": "        guard true else {", "witness": "testGSFINAL003_aDroppedTerminalCheckpointNeverSettles", "why": "a dropped write always reports .committed, so the ladder advances to a terminal state it never committed"},
    {"id": "MUT-IOS-R3-COORDINATOR-IGNORES-ACK", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/CrashResumableWipe.swift", "court": "GsFinal003RecoveryTopologyTests", "swift_filter": "testGSFINAL003_aDroppedTerminalCheckpointNeverSettles", "find": "        guard case .committed = checkpoint else {", "replace": "        guard case .committed = checkpoint || true else {", "witness": "testGSFINAL003_aDroppedTerminalCheckpointNeverSettles", "why": "the coordinator advances even when the append refused (uncommitted terminal reaches IDLE and publishes)"},
    {"id": "MUT-IOS-R4-WRONG-DEK-TAG", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/WipeKeyVaultSeam.swift", "court": "GsFinal003RecoveryTopologyTests", "swift_filter": "testGSFINAL003_aPendingWipeResolvesThroughThePrePrivateRecoveryBeforeAnyPrivateStore", "find": "            return eraseStoreDEK(name: name, tag: Self.messageStoreDEKTag)", "replace": "            return eraseStoreDEK(name: name, tag: \"godstone.store.dek\")", "witness": "testGSFINAL003_aPendingWipeResolvesThroughThePrePrivateRecoveryBeforeAnyPrivateStore", "why": "the message store's real DEK survives (the original IOS-R4 defect); the two-real-account assertion reddens"},
    {"id": "MUT-IOS-R4-ERASE-UNVERIFIED", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/WipeKeyVaultSeam.swift", "court": "GsFinal003RecoveryTopologyTests", "swift_filter": "testGSFINAL003_aDEKThatSurvivesItsDeletionIsNotReportedErased", "find": "            return .failed(keyName: name, retryable: true,\n                           reason: \"the DEK for '\\(tag)' surviveth its own deletion\")", "replace": "            return .verifiedAbsent(name: name)", "witness": "testGSFINAL003_aDEKThatSurvivesItsDeletionIsNotReportedErased", "why": "a surviving DEK is reported erased, so the survival witness reddens"},
    {"id": "MUT-IOS-R5-FRESH-DEAD-TRANSPORT", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift", "court": "GsFinal003RecoveryTopologyTests", "swift_filter": "testGSFINAL003_aLiveOwnerThatCannotBeDrainedKeepsTheWipePending", "find": "            if let live = estate.liveTransport {", "replace": "            if false, let live = estate.liveTransport {", "witness": "testGSFINAL003_aLiveOwnerThatCannotBeDrainedKeepsTheWipePending", "why": "the estate's live transport is never consulted, so a cold/dead path could advance over live owners"},
    {"id": "MUT-IOS-R5-UNARMED-COLD", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/EstateOwnerRegistry.swift", "court": "GsFinal003RecoveryTopologyTests", "swift_filter": "testGSFINAL003_coldRequiresAPositivelyVerifiedEstate", "find": "            return armed\n                ? .cold(reason: \"the estate registry is armed and positively holds no live owner\")", "replace": "            return .cold(reason: \"empty registry\")", "witness": "testGSFINAL003_coldRequiresAPositivelyVerifiedEstate", "why": "an unarmed registry claims cold (the exact IOS-R5 defect), so the unarmed-witness reddens"},
    {"id": "MUT-IOS-R7-INVENTORY-IGNORED", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/CrashResumableWipe.swift", "court": "GsFinal003RecoveryTopologyTests", "swift_filter": "testGSFINAL003_theCoordinatorIteratesTheEstatesOwnArtifacts", "find": "                for name in estateArtifacts where !inventory.contains(name) { inventory.append(name) }", "replace": "                // the estate's own inventory is ignored", "witness": "testGSFINAL003_theCoordinatorIteratesTheEstatesOwnArtifacts", "why": "the lab's own names are never deleted and the ladder stalls (the IOS-R7 stall)"},
    {"id": "MUT-IOS-R8-PUBLISH-NOT-IDEMPOTENT", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/WipeIdentityAuthoritySeam.swift", "court": "GsFinal003RecoveryTopologyTests", "swift_filter": "testGSFINAL003_aCrashAfterIdentityPublicationStillSettlesOnOneIdentity", "find": "        if let record = readPublication(), record.generation == wipeGeneration {", "replace": "        if false, let record = readPublication(), record.generation == wipeGeneration {", "witness": "testGSFINAL003_aCrashAfterIdentityPublicationStillSettlesOnOneIdentity", "why": "the adopt-by-record branch is removed; a re-opened drive no longer adopts and can refuse (brick)"},
    {"id": "MUT-IOS-R8-PUBLICATION-UNBOUND", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/WipeIdentityAuthoritySeam.swift", "court": "GsFinal003RecoveryTopologyTests", "swift_filter": "testGSFINAL003_aCrashAfterIdentityPublicationStillSettlesOnOneIdentity", "find": "        let raw = \"\\(publication.generation)|\\(publication.hint)|\\(publication.signingPublicKeyHex)|\\(publication.staticDhPublicKeyHex)\"", "replace": "        let raw = \"\\(publication.hint)\"", "witness": "testGSFINAL003_aCrashAfterIdentityPublicationStillSettlesOnOneIdentity", "why": "the publication record is not bound to the generation, so adoption cannot verify and the boundary witness reddens"},
    {"id": "MUT-IOS-R11-WITNESS-DISCONNECTED", "platform": "swift", "file": "ios/Godstone/Tests/GodstoneMeshTests/GsFinal003StartupPermitTests.swift", "court": "GsFinal003StartupPermitTests", "swift_filter": "testGSFINAL003_theWitnessCountersObserveARealAcceptedConstruction", "find": "            counter.openedStore(path: path)", "replace": "            // witness disconnected from the real construction boundary", "witness": "testGSFINAL003_theWitnessCountersObserveARealAcceptedConstruction", "why": "the open witness no longer observes construction, so the positive control must redden (counter stuck at 0)"},
    # ----------------------------------------------------------------------
    # *** ARCHIVE PROVENANCE (ArchiveProvenance): the archive library/repository/
    # scene/view provenance road. *** *Witnesses in GodstoneCoreTests/ReadinessT50Tests;
    # ARCHIVE-PROV-007 is guard_only (structural-plus-executed-smoke: its semantic
    # proof is the parent's executed iOS UI smoke, never the structural kill).*
    # ----------------------------------------------------------------------
    {"id": "ARCHIVE-PROV-001", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveReaderModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests/testTheRealMetadataFaultIsToldAsTypedWoeAndNeverAsAbsence", "swift_target": "GodstoneCoreTests", "find": "        try repository.sourceMetadataChecked(documentId: documentId)", "replace": "        (try? repository.sourceMetadataChecked(documentId: documentId)) ?? nil", "witness": "testTheRealMetadataFaultIsToldAsTypedWoeAndNeverAsAbsence", "why": "Reinstate the swallow: the provenance probe again answereth a storage fault as absence (the card's own defect, in the face the scene and the destination both consult)."},
    {"id": "ARCHIVE-PROV-002", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveReaderModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests/(testTheRealRoadProjectethProvenanceFromTheFrozenColumns|testW15TheLibrariesProvenanceProbeAnswerethTheDocumentsOwnMetadata|testTheRealMetadataFaultIsToldAsTypedWoeAndNeverAsAbsence)", "swift_target": "GodstoneCoreTests", "find": "        try repository.sourceMetadataChecked(documentId: documentId)", "replace": "        return nil", "witness": "testTheRealRoadProjectethProvenanceFromTheFrozenColumns", "why": "Answer the probe without ever consulting the stock (a blind nil). This is the vacuity control: it proveth the POSITIVE arms -- the exact projection over the provided fixture, and W15's semantic -- are witnesses and not decorations."},
    {"id": "ARCHIVE-PROV-003", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests/(testTheScenePresentethTheMetadataWoeAndTheRetryBringethTheProjectionBack|testTheRealMetadataFaultIsToldAsTypedWoeAndNeverAsAbsence|testTheSameRoadTellethAbsenceAndFaultApartAtOneProbe)", "swift_target": "GodstoneCoreTests", "find": "            } catch let archiveError as ArchiveError {\n                publishFailure(archiveError)\n            } catch {\n                publishFailure(.queryFailed(String(describing: error)))\n            }\n", "replace": "            } catch {\n                mode = .document\n                documents = []\n                passages = found ?? []\n                openedDocumentId = id\n                openedTitle = title\n                openedSource = nil\n                phase = .ready\n            }\n", "witness": "testTheScenePresentethTheMetadataWoeAndTheRetryBringethTheProjectionBack", "why": "Collapse the metadata fault to absence at the STATE OWNER: the scene keepeth the document open, claims .ready and publisheth no provenance -- the false green the card names, with the reader shown a citation-stripped document and no word of why."},
    {"id": "ARCHIVE-PROV-004", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests/(testTheRealMetadataFaultIsToldAsTypedWoeAndNeverAsAbsence|testTheScenePresentethTheMetadataWoeAndTheRetryBringethTheProjectionBack|testTheMetadataTaxonomyTravellethUntouchedAndTheUntouchableIsNotOfferedAKnock)", "swift_target": "GodstoneCoreTests", "find": "            } catch let archiveError as ArchiveError {\n                publishFailure(archiveError)\n", "replace": "            } catch let archiveError as ArchiveError {\n                publishFailure(.corrupt(\"the archive could not be read\"))\n", "witness": "testTheRealMetadataFaultIsToldAsTypedWoeAndNeverAsAbsence", "why": "Fabricate a cause the checked path never met: tell every metadata fault as a corrupt archive (the card's 'metadata error must not fabricate a corruption cause')."},
    {"id": "ARCHIVE-PROV-005", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveRepository.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests", "swift_target": "GodstoneCoreTests", "find": "    public func sourceMetadataChecked(documentId: Int64) throws -> ArchiveSourceMetadata? {\n        let sql = \"SELECT document_id, title, source_id, licence, revision, is_critical \"\n", "replace": "    public func sourceMetadataChecked(documentId: Int64) throws -> ArchiveSourceMetadata? {\n        if closed { return nil }\n        let sql = \"SELECT document_id, title, source_id, licence, revision, is_critical \"\n", "witness": "testTheClosedCandidateAnswerethTheMetadataProbeWithTypedNoHandle", "why": "A stale/closed candidate answereth the probe with ABSENCE instead of the typed no-handle woe -- the 'stable candidate, stale/closed state, typed no handle' edge. The document read and the probe now disagree about whether the road is walkable at all."},
    {"id": "ARCHIVE-PROV-006", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests/testTheMetadataTaxonomyTravellethUntouchedAndTheUntouchableIsNotOfferedAKnock", "swift_target": "GodstoneCoreTests", "find": "        case .queryFailed, .unreadable:\n            mendable = true\n", "replace": "        case .queryFailed, .unreadable, .corrupt, .missing, .noSuchTable:\n            mendable = true\n", "witness": "testTheMetadataTaxonomyTravellethUntouchedAndTheUntouchableIsNotOfferedAKnock", "why": "Broaden the retry: offer a knock for woes no reader can mend (installation woes become retriable again at the provenance road)."},
    {"id": "ARCHIVE-PROV-007", "platform": "swift", "file": "ios/Godstone/Sources/App/ArchiveView.swift", "court": "ios/Godstone/Tests/GodstoneCoreTests/ReadinessT50Tests.swift", "swift_filter": "ReadinessT50Tests/testW14TheDocumentDestinationPublishethItsOwnCheckedProvenance", "swift_target": "GodstoneCoreTests", "find": "        case .failure(let archiveError):\n            HStack(spacing: 8) {\n                Text(ArchiveUserMessage.spoken(for: archiveError))\n                    .font(.subheadline)\n                    .foregroundStyle(.secondary)\n                    .accessibilityIdentifier(\"archive.provenance.error\")\n                if provenanceMayMend(archiveError) {\n                    Button(\"Try again\") { retry &+= 1 }\n                        .font(.caption)\n                        .accessibilityIdentifier(\"archive.provenance.retry\")\n                }\n            }\n", "replace": "        case .failure:\n            EmptyView()\n", "witness": "testW14TheDocumentDestinationPublishethItsOwnCheckedProvenance", "why": "The destination OMITETH the failure: the checked face crieth and the reader is shewn a citation-stripped document with neither the line nor a telling (the UI-omission half of the card's negative control).", "guard_only": True},
    # ----------------------------------------------------------------------
    # *** NATIVE CONNECTION/ENCRYPTION REPAIRS (NativeConnectionRepair): SQLITE-REVIEW-1..8.
    # *** *Witnesses in NativeConnectionRepairTests (swift_target GodstoneMeshTests);
    # pinned-image arms XCTSkip DISTINGUISHABLY on a host without the library, never a
    # green pass.*
    # ----------------------------------------------------------------------
    {"id": "NCR-01-swift-the-store-drops-the-owners-use-lock", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/NativeConnectionRepairTests.swift", "swift_filter": "NativeConnectionRepairTests", "swift_target": "GodstoneMeshTests", "find": "        if let owner { return try owner.usingConnection { _ in try self.dbSectionThrowing(body) } }\n        return try dbSectionThrowing(body)", "replace": "        return try dbSectionThrowing(body)", "witness": "testReview2OwnerCloseWaitsForActiveUseAndRefusesAfterwards", "why": "every throwing store operation stops admitting itself against the owner's shared use/close critical section, so a concurrent OwnedConnection.close() can free the handle under an open statement; the close-vs-use witness reddens (and the post-close use becomes a stale dispatch rather than a typed refusal)."},
    {"id": "NCR-02-swift-the-owner-close-frees-without-draining", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/OwnedVerifiedConnection.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/NativeConnectionRepairTests.swift", "swift_filter": "NativeConnectionRepairTests", "swift_target": "GodstoneMeshTests", "find": "        lifecycle.markClosed()          // refuse NEW use, so the drain below terminates\n        lifecycle.waitUntilUnused()     // wait for the uses already in flight", "replace": "        lifecycle.markClosed()          // refuse NEW use, so the drain below terminates", "witness": "testReview2OwnerCloseWaitsForActiveUseAndRefusesAfterwards", "why": "close stops waiting for active uses, so it frees the handle while a worker is between prepare/step/finalize; the 'close has not returned while a use is in flight' assertion reddens."},
    {"id": "NCR-03-swift-the-admission-always-admits", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/OwnedVerifiedConnection.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/NativeConnectionRepairTests.swift", "swift_filter": "NativeConnectionRepairTests", "swift_target": "GodstoneMeshTests", "find": "        guard lifecycle.beginUse() else { throw StoreConnectionError.ownerClosed }", "replace": "        guard lifecycle.beginUse() || true else { throw StoreConnectionError.ownerClosed }", "witness": "testReview2OwnerCloseWaitsForActiveUseAndRefusesAfterwards", "why": "the closed-state admission always admits, so a post-owner-close call dispatches a STALE handle to SQLite instead of the typed ownerClosed refusal; the post-close refusal assertion reddens."},
    {"id": "NCR-04-swift-the-intent-read-folds-every-fault-into-absence", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/NativeConnectionRepairTests.swift", "swift_filter": "NativeConnectionRepairTests", "swift_target": "GodstoneMeshTests", "find": "        if rc == SQLITE_DONE { return nil }        // no row -- absence, NOT a fault\n        guard rc == SQLITE_ROW else { throw StoreError.stepFailed }   // BUSY/IOERR/NOTADB -> typed storage failure", "replace": "        guard rc == SQLITE_ROW else { return nil }", "witness": "testReview8IntentReadFaultIsStorageFailureNeverAbsence", "why": "every non-ROW step result (BUSY/IOERR/NOTADB) is folded into nil, and SqliteOutboundIntentJournal translates nil to .notFound -- which SendDirectAuthority treats as permission to enter fresh trust resolution and nonce creation; the 'a storage fault THROWS (not nil)' assertion and the journal's .storageFailure mapping both redden."},
    {"id": "NCR-05-swift-the-migration-stamp-runs-outside-the-edge-transaction", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/NativeConnectionRepairTests.swift", "swift_filter": "NativeConnectionRepairTests", "swift_target": "GodstoneMeshTests", "find": "                guard stampRC == SQLITE_OK else { throw StoreError.execFailed }", "replace": "                _ = stampRC", "witness": "testReview4TornMigrationStampLeavesDurableVersionUnadvanced", "why": "a failed durable stamp no longer rolls the edge back or refuses it, so the DDL commits while user_version never moves and the store publishes success over an unadvanced revision; the 'durable user_version still 9' assertion reddens."},
    {"id": "NCR-06-swift-the-sweep-begin-fault-is-not-refused", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/NativeConnectionRepairTests.swift", "swift_filter": "NativeConnectionRepairTests", "swift_target": "GodstoneMeshTests", "find": "            guard beginRC == SQLITE_OK else {\n                return sweepFault(.beginFailed(code: beginRC), db: db, rolledBack: false)\n            }", "replace": "            _ = beginRC", "witness": "testReviewSweepRefusesWithoutTransactionAndWithoutCommit", "why": "a refused BEGIN no longer stops the sweep, so every DELETE/INSERT/UPDATE runs outside a SQL transaction (autocommitting one-by-one, the half-retirement the repair existeth to prevent); the 'refused BEGIN -> 0 mutations dispatched' assertion reddens."},
    {"id": "NCR-07-swift-the-sweep-publishes-without-an-acknowledged-commit", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/NativeConnectionRepairTests.swift", "swift_filter": "NativeConnectionRepairTests", "swift_target": "GodstoneMeshTests", "find": "            guard commitRC == SQLITE_OK else {\n                return sweepFault(.commitFailed(code: commitRC), db: db, rolledBack: true)\n            }", "replace": "            _ = commitRC", "witness": "testReviewSweepRefusesWithoutTransactionAndWithoutCommit", "why": "a failed COMMIT no longer refuses the step, so the swept rows are published as retired while the file keeps them and an observer is notified of a retirement that never happened; the 'failed COMMIT -> typed fault' assertion reddens."},
    {"id": "NCR-08-swift-the-factory-admits-a-replayed-scope", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/EncryptedStoreFactory.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/NativeConnectionRepairTests.swift", "swift_filter": "NativeConnectionRepairTests", "swift_target": "GodstoneMeshTests", "find": "        guard EncryptedStoreAdmissionLedger.shared.claimIfAvailable(\n            scope.mint, estateId: scope.estateId, generation: scope.generation,\n            storeTag: scope.storeTag, storePath: scope.storePath) else {\n            return .notMinted          // never issued, bound elsewhere, or already spent -- all a fail-closed refusal\n        }", "replace": "        _ = EncryptedStoreAdmissionLedger.shared.claimIfAvailable(\n            scope.mint, estateId: scope.estateId, generation: scope.generation,\n            storeTag: scope.storeTag, storePath: scope.storePath)", "witness": "testAdmissionRefusesASpentMintAndAnUnissuedOne", "why": "the factory stops validating AND atomically claiming the scope, so a replayed permit opens a private store a second time; the admission-replay witness reddens."},
    {"id": "NCR-09-swift-the-engine-reports-a-generic-io-for-a-wrong-key", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/SqlCipherDylibEngine.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/NativeConnectionRepairTests.swift", "swift_filter": "NativeConnectionRepairTests", "swift_target": "GodstoneMeshTests", "find": "            if stepRC == 26 { throw StoreOpenFault.wrongKey } // SQLITE_NOTADB\n            // *** THE LABEL NAMES THE PROBE, SO A LIBRARY THAT ANSWERETH `DONE` WITH NO ROWS IS DIAGNOSABLE. ***", "replace": "            if stepRC == 26 { throw StoreOpenFault.io(\"notadb at step (rc=\\(stepRC))\") }\n            // *** THE LABEL NAMES THE PROBE, SO A LIBRARY THAT ANSWERETH `DONE` WITH NO ROWS IS DIAGNOSABLE. ***", "witness": "testReview6RealPinnedRoundTripExactBytesAndWrongKeyRefusal", "why": "SQLite's NOTADB from a wrong key stops being normalised to the typed .wrongKey; the 'wrong DEK refused as typed .wrongKey' assertion reddens."},
    {"id": "NCR-10-swift-the-partial-open-handle-leaks", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/SqlCipherDylibEngine.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/GsFinal004OwnedConnectionTests.swift", "swift_filter": "GsFinal004OwnedConnectionTests", "swift_target": "GodstoneMeshTests", "find": "            if let partial = db { _ = s.closeV2(partial) }", "replace": "            // (mutant) the partial handle is leaked rather than closed", "witness": "testGF004APartialProviderBindIsRefusedAndAKeyFaultIsTyped", "why": "a failed sqlite3_open_v2 that returned a NONNULL (partial) handle no longer closes it before the throw, leaking a connection; the instrumented table's close-count assertion (close > 0) reddens. Needs no pinned library, so this rod always fires."},
    # ----------------------------------------------------------------------
    # *** IOS LAB ESTATE/PRODUCTION (IosLabProduction): IOS-R10 durable send
    # composition and IOS-R15 model projection witnesses. ***
    # ----------------------------------------------------------------------
    {"id": "IOS-R10-second-store", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/ComposedRuntime.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT36Tests.swift", "swift_target": "GodstoneMeshTests", "swift_filter": "ReadinessT36Tests", "find": "        let nodeStore: MessageStore = durableStore ?? store", "replace": "        let nodeStore: MessageStore = store", "witness": "testCRYPTO005_theCompositionPinsTheIntentBeforeTheRadioAndSurvivesAReopen", "why": "The node must run on the durable store it owns; an in-memory node cannot carry a durable intent."},
    {"id": "IOS-R10-no-dispatch", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/ComposedRuntime.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT36Tests.swift", "swift_target": "GodstoneMeshTests", "swift_filter": "ReadinessT36Tests", "find": "            _ = hand(a, toLabel: recipientLabel, bytes: frame.encode())", "replace": "            _ = frame", "witness": "testCRYPTO005_theSendBoundaryAfterTheDurableEnqueueIsRestartableFromDisk", "why": "A send that pins an intent and never dispatches proves nothing about delivery (IOS-R10)."},
    {"id": "IOS-R15-unrefreshed-snapshot", "platform": "swift", "file": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "swift_target": "GodstoneMeshTests", "swift_filter": "ReadinessT58Tests", "find": "        _ = model.refresh()\n        let row = try XCTUnwrap(model.uiState().messages.first { $0.msgId == msgId })", "replace": "        let row = try XCTUnwrap(model.uiState().messages.first { $0.msgId == msgId })", "witness": "testW14ANonTerminalMessageIsResumableEvenWhenTheProjectionUnderReportsIt", "why": "Proves the projection witness is real: without the refresh the under-reported flag assertion cannot hold. Mutant stays compilable."},
    {"id": "IOS-R15-impossible-no-call", "platform": "swift", "file": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/ReadinessT58Tests.swift", "swift_target": "GodstoneMeshTests", "swift_filter": "ReadinessT58Tests", "find": "            authority.retries, retriesBefore + 1,\n            \"*** THE STALE PROJECTION MAKES THE MODEL'S OWN STATE-AWARE ANSWER TRUE", "replace": "            authority.retries, retriesBefore,\n            \"*** THE STALE PROJECTION MAKES THE MODEL'S OWN STATE-AWARE ANSWER TRUE", "witness": "testW17AStaleSnapshotReachesTheAuthorityAndCarriesItsTypedRefusal", "why": "Proves the stale-snapshot arm asserts a real call (not an impossible no-call). Mutant stays compilable."},
    {"id": "NCR-11-swift-the-peer-transaction-reacquires-the-store-lock", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/PeerIdentityStore.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/NativeConnectionRepairTests.swift", "swift_filter": "NativeConnectionRepairTests", "swift_target": "GodstoneMeshTests", "find": "        try usingConnection { db in try self.transactionSectionLocked(db, block) }", "replace": "        lock.lock()\n        defer { lock.unlock() }\n        guard let db = handle else { throw PeerStoreError.handleMissing }\n        try self.transactionSectionLocked(db, block)", "witness": "testPeerTransactionCompletesWithoutDeadlock", "why": "the peer transaction re-acquires the store's non-recursive NSLock (the pre-C1 shape), so every binding/approve/confirm/revoke self-deadlocks; the bounded 'transaction completes' assertion reddens."},
    {"id": "NCR-13-swift-the-corrupt-intent-row-is-absence-again", "platform": "swift", "file": "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift", "court": "ios/Godstone/Tests/GodstoneMeshTests/NativeConnectionRepairTests.swift", "swift_filter": "NativeConnectionRepairTests", "swift_target": "GodstoneMeshTests", "find": "        guard let entry = JournalEntry(intentId: intent, logicalMessageId: logical,\n                                       signedPlaintextBytes: plaintext, canonicalFrameBytes: frame,\n                                       recipientNodeId: recipient, recipientStaticDhPub: recipientDh,\n                                       acceptedGeneration: generation, bindingDigest: digest,\n                                       createdAtEpochSeconds: created, messageNonce: nonce,\n                                       priorityCode: priority, stateRank: rank) else {\n            // *The row STANDETH but cannot be rebuilt -- a corruption, never an absence.*\n            throw StoreError.stepFailed\n        }\n        return entry", "replace": "        return JournalEntry(intentId: intent, logicalMessageId: logical, signedPlaintextBytes: plaintext,\n                            canonicalFrameBytes: frame, recipientNodeId: recipient,\n                            recipientStaticDhPub: recipientDh, acceptedGeneration: generation,\n                            bindingDigest: digest, createdAtEpochSeconds: created, messageNonce: nonce,\n                            priorityCode: priority, stateRank: rank)", "witness": "testIntentCorruptExistingRowIsStorageFailureNotAbsence", "why": "a malformed existing intent row is collapsed back into nil/absence, so SendDirectAuthority enters fresh authoring instead of stopping; the corruption-refusal assertion reddens."},
    # ----------------------------------------------------------------------
    # *** RELEASE SUPPLY CHAIN AND TRUST EXPANSION (ReleaseSupply): RS-CAP, REG, NATIVE, TRUST. ***
    # ----------------------------------------------------------------------
    {"id": "RS-CAP-01-forged-marker-laundered-an-internal-red", "platform": "python", "file": "tools/supplychain/capture_release_proof.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_audit_supplychain_harness.py", "find": "    text = log_text or \"\"\n", "replace": "    text = \"\"\n", "witness": "test_an_internal_compile_failure_with_a_forged_marker_is_not_external", "why": "the internal-failure evidence detector is blinded (text forced empty): a TRUE failed :llm:compileReleaseKotlin carrying a well-formed boundary marker would be filed BLOCKED_EXTERNAL, laundering an internal red as external; note a HEALTHY run that merely PRINTS the task name must still be accepted, so the detector must key on FAILURE markers (FAILED/BUILD FAILED/compiler error), not the task name"},
    {"id": "RS-CAP-02-external-block-allowed-while-internal-red", "platform": "python", "file": "tools/supplychain/capture_release_proof.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_audit_supplychain_harness.py", "find": "    if not internal_ok:\n", "replace": "    if False:\n", "witness": "test_no_external_block_is_allowed_while_the_internal_road_is_red", "why": "the ordering gate is struck: an external job could be filed BLOCKED_EXTERNAL while an internal prerequisite never succeeded, so a job that never reached any boundary blamesth an external input for its own failure"},
    {"id": "RS-REG-01-corrupt-register-classified-as-missing-input", "platform": "python", "file": "tools/supplychain/emit_boundary.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_audit_supplychain_harness.py", "find": "        except RegisterError as exc:\n", "replace": "        except KeyboardInterrupt as exc:\n", "witness": "test_a_corrupt_register_is_an_error_never_a_missing_input", "why": "the unjudgeable-register guard is struck: a CORRUPT lock would fall through and be reported as an absent external input (exit 1, a boundary) instead of exit 2 -- a parse failure is not evidence that content is missing"},
    {"id": "RS-NATIVE-01-native-stack-conflated-with-model-weights", "platform": "python", "file": "tools/supplychain/emit_boundary.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_audit_supplychain_harness.py", "find": "    revision = native.get(\"llama_revision\")\n", "replace": "    revision = \"pinned\"\n", "witness": "test_the_native_stack_is_not_the_model_weights", "why": "the native.llama_revision pin is assumed: the native boundary would pass on a UNPINNED llama.cpp revision and the model-weight register would stand in for the native prerequisite -- the exact conflation the split existeth to forbid"},
    {"id": "RS-NATIVE-02-absent-llama-source-tolerated", "platform": "python", "file": "tools/supplychain/emit_boundary.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_audit_supplychain_harness.py", "find": "    if not source.is_dir():\n", "replace": "    if False:\n", "witness": "test_a_pinned_revision_with_absent_source_is_a_measured_absence", "why": "the source-tree presence check is struck: a pinned llama_revision whose third_party/llama.cpp tree is ABSENT would be judged present, so the native stack would be claimed buildable while nothing is there"},
    {"id": "RS-TRUST-01-replaced-image-digest-trusted-from-sidecar", "platform": "python", "file": "tools/supplychain/verify_sqlcipher_artifact.py", "py_dir": "tools/readiness/tests", "py_pattern": "test_audit_supplychain_harness.py", "find": "    if actual_sha != want[\"sha256\"]:\n", "replace": "    if False:\n", "witness": "test_a_replaced_image_is_refused_by_name", "why": "the trusted-output digest gate is struck: a REPLACED image (any bytes) would pass because the expectation was not enforced against the register -- the exact 'sidecar/image trust the staging dir' defect. The register, not a co-located sidecar, must authorize the bytes."},
    # ----------------------------------------------------------------------
    # *** CANONICAL TERMINAL MANIFEST/FREEZE/BINDING (CanonicalTerminalRepair):
    # the executing-successor relation, hosted-manifest authentication, evidence-root
    # derivation and gate-log rebind. ***
    # ----------------------------------------------------------------------
    # ----------------------------------------------------------------------
    # *** BOARD 1 SECURITY-CRITICAL SURFACES (--group board1-trust-surface): the
    # trust handshake, the peer-identity store, the bound recipient key resolver
    # and the store-schema/quota controls. ***
    #
    # *These rods MUTATE THE PRODUCTION CONTROL, NOT the guard, and the guard's
    # committed checker is RUN against the mutant as the oracle. The kill is
    # ATTRIBUTED BY NAME -- each rod names a `refusal_line` no sibling can raise, so
    # a non-zero rc from a co-reddening invariant is EXEC_INVALID, never a catch.*
    # ----------------------------------------------------------------------
    {'id': 'TH-01-ios-trusted-controller-restores-the-collapsed-hs2-hs3', 'platform': 'swift',
     'file': 'ios/Godstone/Sources/GodstoneMesh/TrustedHandshakeController.swift',
     'guard_file': 'ci/check_trusted_handshake_controls.py',
     'refusal_line': 'iOS TrustedHandshakeController must NOT call readMessage2AndWrite3 (H04)',
     'witness': 'check_trusted_handshake_controls:H04-ios-collapsed-hs2-hs3-restored',
     'find': '        let readResult: HandshakeReadResult\n        do {\n            readResult = try noiseSession.readMessage2(hs2)\n        } catch {',
     'replace': '        let readResult: HandshakeReadResult\n        do {\n            readResult = try noiseSession.readMessage2AndWrite3(hs2)   // (mutant) HS2+HS3 collapsed into the untrusted helper\n        } catch {',
     'why': 'THE TRUSTED HANDSHAKE CONTROLLER FALLS BACK TO THE COLLAPSED readMessage2AndWrite3 HELPER THAT ADR-003 SPLIT APART. The helper reads message 2 AND writes message 3 in one untrusted call, so the authentication of the remote static (and the identity binding it must validate) is no longer a separate, inspectable step - the exact reversion the H04/H20 zero-call controls exist to refuse.'},
    {'id': 'TH-02-android-noise-drops-the-typed-read-result', 'platform': 'jvm', 'module': 'mesh',
     'file': 'android/mesh/src/main/java/io/godstone/mesh/crypto/NoiseSession.kt',
     'guard_file': 'ci/check_trusted_handshake_controls.py',
     'refusal_line': 'Android NoiseSession must define class HandshakeReadResult with authenticatedRemoteStaticKey (H01)',
     'witness': 'check_trusted_handshake_controls:H01-android-typed-read-result',
     'find': 'class HandshakeReadResult',
     'replace': 'class LegacyHandshakeResult   // (mutant) the typed read result perishes',
     'why': 'THE TYPED HandshakeReadResult VANISHES FROM NoiseSession, so the authenticated remote static (and the payload it carries) can no longer be inspected before trust is applied - the handshake degrades to an untyped read and the whole C8.4A typed-inspection boundary is gone.'},
    {'id': 'TH-03-android-read-result-aliases-its-payload', 'platform': 'jvm', 'module': 'mesh',
     'file': 'android/mesh/src/main/java/io/godstone/mesh/crypto/NoiseSession.kt',
     'guard_file': 'ci/check_trusted_handshake_controls.py',
     'refusal_line': 'Android HandshakeReadResult constructor must copy input payload (H21)',
     'witness': 'check_trusted_handshake_controls:H21-android-aliased-payload',
     'find': '_payload: ByteArray = payload.copyOf()',
     'replace': '_payload: ByteArray = payload   // (mutant) the payload is aliased, not defensively copied',
     'why': 'THE READ RESULT ALIASES THE CALLER-OWNED PAYLOAD INSTEAD OF DEFENSIVELY COPYING IT, so a holder can mutate the buffer AFTER the validation that cleared it - the trusted binding is validated against bytes that can then be changed under it. H21 exists precisely so the validated bytes cannot move.'},
    {'id': 'TH-04-ios-noise-restores-the-collapsed-hs2-hs3', 'platform': 'swift',
     'file': 'ios/Godstone/Sources/GodstoneMesh/NoiseSession.swift',
     'guard_file': 'ci/check_trusted_handshake_controls.py',
     'refusal_line': 'iOS NoiseSession must NOT contain readMessage2AndWrite3 (H20)',
     'witness': 'check_trusted_handshake_controls:H20-ios-collapsed-helper-restored',
     'find': 'import GodstoneCore\n\n/// Noise_XX_25519_ChaChaPoly_BLAKE2s.',
     'replace': 'import GodstoneCore\n\n// (mutant) the collapsed readMessage2AndWrite3 helper returneth to the noise core\npublic func readMessage2AndWrite3(_ x: Data) throws -> Data { fatalError() }\n\n/// Noise_XX_25519_ChaChaPoly_BLAKE2s.',
     'why': 'THE COLLAPSED readMessage2AndWrite3 HELPER RETURNS TO THE NOISE CORE, reopening the untrusted one-shot call the ADR-003 split retired. Any production path that reaches it can complete the handshake without a separate, validated message-3 step.'},
    {'id': 'PI-01-first-seen-becometh-insert-or-ignore', 'platform': 'jvm', 'module': 'mesh',
     'file': 'android/mesh/src/main/java/io/godstone/mesh/identity/PeerIdentitySchema.kt',
     'guard_file': 'ci/check_peer_identity_store_controls.py',
     'refusal_line': 'Android first-seen must use standard INSERT, not OR IGNORE/REPLACE (S27)',
     'witness': 'check_peer_identity_store_controls:S27-first-seen-insert-or-ignore',
     'find': '        INSERT INTO peer_identities (',
     'replace': '        INSERT OR IGNORE INTO peer_identities (   -- (mutant) a re-pinned first-seen is silently ignored',
     'why': 'THE FIRST-SEEN INSERT BECOMES INSERT OR IGNORE, so a peer whose identity CHANGED is silently accepted with its OLD pinned key left standing (the new binding is dropped as a conflict). TOFU loses its teeth: a key rotation that should pin-first-seen or quarantine instead reads as a benign no-op.'},
    {'id': 'PI-02-ddl-admits-an-unrecognised-trust-level', 'platform': 'jvm', 'module': 'mesh',
     'file': 'android/mesh/src/main/java/io/godstone/mesh/identity/PeerIdentitySchema.kt',
     'guard_file': 'ci/check_peer_identity_store_controls.py',
     'refusal_line': 'Android DDL missing trust_level IN (1,2,3) CHECK (S12)',
     'witness': 'check_peer_identity_store_controls:S12-unrecognised-trust-level',
     'find': 'trust_level IN (1,2,3)',
     'replace': 'trust_level IN (0,1,2,3)',
     'why': 'THE DDL TRUST-LEVEL CHECK IS WIDENED TO ADMIT 0, a value the trust model does not define. A corrupted or adversarially written trust_level=0 row can then persist and be read back as an unrecognised state, defeating the store-owns-the-encoding invariant the resolver depends on to fail closed.'},
    {'id': 'PI-03-rotation-approval-admits-a-revoked-peer', 'platform': 'jvm', 'module': 'mesh',
     'file': 'android/mesh/src/main/java/io/godstone/mesh/identity/PeerIdentitySchema.kt',
     'guard_file': 'ci/check_peer_identity_store_controls.py',
     'refusal_line': 'Android approval SQL missing trust_level IN (1,2) predicate (S52)',
     'witness': 'check_peer_identity_store_controls:S52-revoked-peer-approves',
     'find': '          AND pending_generation = ?\n          AND trust_level IN (1,2)\n    """',
     'replace': '          AND pending_generation = ?\n          AND 1 = 1   -- (mutant) a REVOKED peer can approve a rotation\n    """',
     'why': 'THE ROTATION-APPROVAL CAS LOSES ITS live-level (IN (1,2)) GUARD, so a peer that was REVOKED (level 3) can still promote a pending rotation - a revoked identity re-authorises itself, the exact resurrection the trust-level predicate forbids.'},
    {'id': 'BR-01-android-revoked-identity-resolveth-its-key', 'platform': 'jvm', 'module': 'mesh',
     'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/BoundRecipientKeyResolver.kt',
     'guard_file': 'ci/check_bound_recipient_key_resolver_controls.py',
     'refusal_line': 'Android BoundRecipientKeyResolver must accept only TOFU_PINNED/USER_VERIFIED and reject REVOKED (B07)',
     'witness': 'check_bound_recipient_key_resolver_controls:B07-revoked-identity-resolves',
     'find': '                    PeerTrustLevel.REVOKED -> null',
     'replace': '                    PeerTrustLevel.REVOKED -> lookup.identity.signingPublicKey.clone()   // (mutant) a REVOKED identity still resolveth a key',
     'why': 'THE RESOLVER RETURNS A SIGNING KEY FOR A REVOKED IDENTITY. The real ACK-signing path would then accept frames signed by a key its owner has revoked - a revoked peer keeps its delivery authority, which is the whole failure the fail-closed matrix exists to prevent.'},
    {'id': 'BR-02-android-node-id-boundary-guard-removed', 'platform': 'jvm', 'module': 'mesh',
     'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/BoundRecipientKeyResolver.kt',
     'guard_file': 'ci/check_bound_recipient_key_resolver_controls.py',
     'refusal_line': 'Android BoundRecipientKeyResolver missing 16-byte nodeId boundary guard (B03)',
     'witness': 'check_bound_recipient_key_resolver_controls:B03-android-boundary-guard',
     'find': '        if (nodeId.size != 16) {\n            return null\n        }',
     'replace': '        // (mutant) the 16-byte nodeId boundary guard is REMOVED',
     'why': 'THE 16-BYTE nodeId BOUNDARY GUARD IS REMOVED, so a malformed (short/long) node id is handed straight to the durable lookup. The boundary is the store-independent shape check that keeps a truncated recipient id from matching some other row.'},
    {'id': 'BR-03-ios-node-id-boundary-guard-removed', 'platform': 'swift',
     'file': 'ios/Godstone/Sources/GodstoneMesh/BoundRecipientKeyResolver.swift',
     'guard_file': 'ci/check_bound_recipient_key_resolver_controls.py',
     'refusal_line': 'iOS BoundRecipientKeyResolver missing 16-byte nodeId boundary guard (B03)',
     'witness': 'check_bound_recipient_key_resolver_controls:B03-ios-boundary-guard',
     'find': '        guard nodeId.count == 16 else {\n            return nil\n        }',
     'replace': '        // (mutant) the 16-byte nodeId boundary guard is REMOVED',
     'why': 'THE iOS TWIN LOSES THE 16-BYTE nodeId BOUNDARY GUARD, so a malformed recipient id reaches the lookup - the isle-symmetric half of BR-02.'},
    {'id': 'BR-04-resolver-returns-the-static-dh-key', 'platform': 'jvm', 'module': 'mesh',
     'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/BoundRecipientKeyResolver.kt',
     'guard_file': 'ci/check_bound_recipient_key_resolver_controls.py',
     'refusal_line': 'Android BoundRecipientKeyResolver must not reference static DH keys (B06)',
     'witness': 'check_bound_recipient_key_resolver_controls:B06-static-dh-key-returned',
     'find': 'PeerTrustLevel.USER_VERIFIED -> lookup.identity.signingPublicKey.clone()',
     'replace': 'PeerTrustLevel.USER_VERIFIED -> lookup.identity.acceptedStaticDhPublicKey.clone()   // (mutant) the ACK signer is bound to the static DH key',
     'why': 'THE RESOLVER BINDS THE ACK SIGNER TO THE STATIC DH KEY RATHER THAN THE Ed25519 SIGNING KEY. Every recipient resolves to a key that never signed the ACK, so the delivery authentication is bound to the wrong identity material - exactly what B06 names.'},
    {'id': 'BR-05-quarantined-lookup-resolveth-a-key', 'platform': 'jvm', 'module': 'mesh',
     'file': 'android/mesh/src/main/java/io/godstone/mesh/delivery/BoundRecipientKeyResolver.kt',
     'guard_file': 'ci/check_bound_recipient_key_resolver_controls.py',
     'refusal_line': 'Both platforms must restrict non-null key returns to Verified lookup (B05)',
     'witness': 'check_bound_recipient_key_resolver_controls:B05-quarantined-resolves',
     'find': '            is PeerIdentityLookup.Verified -> {',
     'replace': '            is PeerIdentityLookup.Quarantined -> {   // (mutant) a QUARANTINED lookup resolveth a key',
     'why': 'A QUARANTINED PEER NOW RESOLVES A KEY: the branch that must fail closed on a key change instead treats quarantine as verified, so a peer whose identity is under dispute signs the ACK.'},
    {'id': 'SS-01-android-dispatch-transporteth-the-uncommitted-frame', 'platform': 'jvm', 'module': 'mesh',
     'file': 'android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt',
     'guard_file': 'ci/check_store_schema_controls.py',
     'refusal_line': 'dispatchDirect must encode canonicalFrame',
     'witness': 'check_store_schema_controls:android-dispatch-canonical-frame',
     'find': '        val bytes = canonicalFrame.encode()',
     'replace': '        val bytes = frame.encode()   // (mutant) the caller frame travels, not the store-returned canonical frame',
     'why': 'dispatchDirect TRANSPORTS THE CALLER FRAME INSTEAD OF THE STORE-RETURNED CANONICAL FRAME, so what leaves the device is not the frame the store committed (its msgId/provenance binding is bypassed) - the C6.6.1 canonical-frame law is broken at the transmit seam.'},
    {'id': 'SS-02-ios-dispatch-transporteth-the-uncommitted-frame', 'platform': 'swift',
     'file': 'ios/Godstone/Sources/GodstoneMesh/MeshNode.swift',
     'guard_file': 'ci/check_store_schema_controls.py',
     'refusal_line': 'dispatchDirect must transport canonicalFrame',
     'witness': 'check_store_schema_controls:ios-dispatch-canonical-frame',
     'find': 'send(canonicalFrame, peer)',
     'replace': 'send(frame, peer)   // (mutant) the caller frame travels, not the store-returned canonical frame',
     'why': 'THE iOS TWIN SENDS THE CALLER FRAME RATHER THAN THE CANONICAL ONE - the isle-symmetric half of SS-01.'},
    {'id': 'SS-03-ios-store-applyeth-a-literal-protection-class', 'platform': 'swift',
     'file': 'ios/Godstone/Sources/GodstoneMesh/MessageStore.swift',
     'guard_file': 'ci/check_store_schema_controls.py',
     'refusal_line': 'the init must APPLY the `fileProtection` it was given (`protectionKey: fileProtection`)',
     'witness': 'check_store_schema_controls:ios-at-rest-applied-protection',
     'find': '                [.protectionKey: fileProtection], ofItemAtPath: path)',
     'replace': '                [.protectionKey: FileProtectionType.none], ofItemAtPath: path)   // (mutant) applies .none while still declaring .complete',
     'why': 'THE iOS STORE APPLIES .none WHILE ITS `fileProtection` STILL DECLARES .complete - the store lies about the at-rest protection it gave the file. The behavioural arm cannot see this (a read-back returns the host default either way), so this is the structural at-rest control the audit names.'},
]

#: Rods documented as an EXPECTED escape. There are NONE: an escape is a finding,
#: never a success, and a rod named here could never be counted as a catch.
EXPECTED_ESCAPES: tuple = ()

# *** THE SINGULAR IS PART OF THE LANGUAGE, AND THE PRECISE KILL IS THE ONE THAT WEARS IT. ***
#
# *XCTest printeth "with 0 failures", "with 1 failure" AND "with N failures" -- the SINGULAR form for exactly one
# failed case.* **A REGEX THAT DEMANDED THE PLURAL MISREAD THE IDEAL MUTATION: a rod whose mutant reddens EXACTLY ONE
# named witness printeth "Executed 13 tests, with 1 failure", `run` stayed `None`, and the rod was reported
# `EXEC_INVALID :: the harness executed nothing` -- a FALSE NON-CATCH ON A REAL CATCH, the mirror of the false green
# this harness existeth to prevent.** *The campaign logs of T56-RC9/T56-RC12 carried the proof: `Executed 13 tests,
# with 1 failure` with the named witness's own `Test Case ... failed` line, and nine such lines across the rods.*
# **So the plural `s` is OPTIONAL ON BOTH NOUNS** -- XCTest printeth "Executed 1 test, with 1 failure" for the
# single-arm case, and a regex demanding "tests" misreads it the same way. `FAILED_CASE_RE` (which already readeth
# the singular `failed` case line) is the independent witness that agrees with the count.
#
# *** AND THE LINE CARRIETH AN OPTIONAL `and N test(s) skipped` INFIX, WHICH IS A THIRD FORM. *** *MEASURED on
# `ReadinessT30Tests`: `Executed 22 tests, with 1 test skipped and 0 failures` -- a class that ran 22 arms, PASSED
# all of them, and SKIPPED one (the EXTERNAL-BLOCKED pinned-library arm).* **A regex without that infix readeth
# `run=None`, so a whole CLASS OF GREEN-AND-ONE-HONEST-SKIP baselines were booked `BASELINE_INVALID` (measured:
# `T72-RC17-ios-engine-claims-pinned-without-binding`).** *The `skipped` count is a SEPARATE clause and is read
# elsewhere; this pattern need only reach the failures figure, so it tolerareth any `and N test(s) skipped` infix.*
EXEC_RE = re.compile(r"Executed ([0-9]+) tests?, with (?:[0-9]+ tests? skipped and )?([0-9]+) failures?")
# the failed-case extractor, stated as one expression: each legacy line that
# pronounces a method failed yields the method's name, and nothing else.
FAILED_CASE_RE = re.compile(r"Test Case '-\[[^\]]*? ([A-Za-z][A-Za-z0-9_]*?)\]' failed")
SWIFT_COMPILE_RE = re.compile(r"\.swift:[0-9]+:[0-9]+: error:")
# the daemon's own restart warning arrieth prefixed 'e: ' and is no compile
# woe: the build ever surviveth it and the tests e'en run whole -- the
# classifier must not taste it as one (the T49 campaign caught the roulette)
KT_COMPILE_RE = re.compile(r"^e: (?!The daemon has terminated unexpectedly)", re.M)
# the XCUITest lane's own line shapes: every arm's verdict BY NAME, and the
# explicit skip line -- *the two readings the `ios-ui` executor is built from.*
UI_CASE_RE = re.compile(r"Test Case '-\[([\w.]+) ([\w]+)\]' (passed|failed)")
UI_SKIP_RE = re.compile(r"Test Case '[^']+' skipped")


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
    """Run the witness set once.

    Returns a RESULT DICT: {"build_exit", "run", "skipped", "failed", "blob"}.
    `run` is None when the harness printed no roster line at all; `skipped`
    counteth arms the toolchain refused to execute -- **a skip measureth
    nothing, so a roster answered by skips is EXEC_INVALID, never a green.**
    """
    if entry["platform"] == "ios-ui":
        # the XCUITest lane: the runner produceth a log, this control readeth it.
        # The roster is SOURCE-DERIVED by the committed checker (one source of
        # truth, two consumers), and every arm's own verdict is read by name.
        ui_log = entry.get("ui_log", "ios-ui-lane.log")
        proc = subprocess.run(["sh", "tools/readiness/run_ios_ui_lane.sh", ui_log],
                              cwd=wt_path, capture_output=True, text=True,
                              timeout=timeout)
        blob = (proc.stdout or "") + (proc.stderr or "")
        log_file = os.path.join(wt_path, ui_log)
        if os.path.isfile(log_file):
            blob += "\n" + open(log_file, encoding="utf-8", errors="replace").read()
        build_exit = 1 if SWIFT_COMPILE_RE.search(blob) else 0
        cases = UI_CASE_RE.findall(blob)
        run = len(cases) if cases else None
        skipped = len(UI_SKIP_RE.findall(blob))
        failed = {n for _c, n, v in cases if v == "failed"}
        return {"build_exit": build_exit, "run": run, "skipped": skipped,
                "failed": failed, "blob": blob}
    if entry.get("guard_file") and entry.get("refusal_line"):
        # *** A ROD WHOSE WITNESS IS A COMMITTED REGRESSION CONTROL, EXECUTED AS THE ORACLE. ***
        #
        # *This branch standeth FIRST, before every platform branch, because the oracle is
        # the same whatever the mutated file's platform: the guard reads the REAL bytes in
        # the worktree and decides its family of invariants. The four Board 1 security-surface
        # guards (`ci/check_trusted_handshake_controls.py`, `check_peer_identity_store_controls.py`,
        # `check_bound_recipient_key_resolver_controls.py`, `check_store_schema_controls.py`) each
        # decide a whole family at once, so a rod here MUTATES that production control (not the
        # guard) and the guard is RUN against the mutant: it exits non-zero iff the invariant it
        # owns is actually broken.
        #
        # **THE KILL IS ATTRIBUTED BY NAME, NOT BY EXIT CODE.** *A guard decides MANY invariants
        # at once, so a non-zero rc from ANY of them is not this rod's claim: the mutant could
        # redden an invariant the rod never aimed at while the one it aimed at slept. So the rod
        # NAMES the exact refusal line the guard must print (`refusal_line`), and a non-zero rc
        # WITHOUT that line is EXEC_INVALID -- an unattributed failure is never a catch. Each
        # refusal line is DISTINCT across the group, so each kill is provably its own.*
        guard_path = os.path.join(wt_path, entry["guard_file"])
        if not os.path.isfile(guard_path):
            return {"build_exit": 0, "run": None, "skipped": 0, "failed": set(),
                    "blob": f"the guard control {entry['guard_file']} is ABSENT from the tree -- cannot aim the rod"}
        try:
            compile(open(guard_path, encoding="utf-8").read(), guard_path, "exec")
        except SyntaxError as exc:
            return {"build_exit": 1, "run": None, "skipped": 0, "failed": set(),
                    "blob": f"the guard control does not parse: {exc}"}
        proc = subprocess.run([sys.executable, "-B", entry["guard_file"]], cwd=wt_path,
                              capture_output=True, text=True, timeout=timeout)
        blob = (proc.stdout or "") + (proc.stderr or "")
        # the guard speaks one line per invariant; strip the `::error::<Label> control error: `
        # (or the store-schema `  - ` bullet) prefix so a rod names the invariant's own sentence.
        refusals = {ln.split("control error: ", 1)[1].strip()
                    for ln in blob.splitlines() if "::error::" in ln and "control error: " in ln}
        refusals |= {ln.split("- ", 1)[1].strip() for ln in blob.splitlines()
                     if ln.strip().startswith("- ")}
        aimed = entry["refusal_line"]
        hit_line = any(aimed in r or r in aimed for r in refusals)
        failed = {entry["witness"]} if (proc.returncode != 0 and hit_line) else set()
        # *** ONLY THE AIMED REFUSAL IS A KILL; ANY OTHER non-zero rc (or a green guard) is not. ***
        return {"build_exit": 0, "run": 1, "skipped": 0, "failed": failed,
                "blob": blob + ("\n(the rod aimed at %r; reddened refusals were %s)"
                                % (aimed, sorted(refusals) if not hit_line else "the aimed one"))}
    if entry["platform"] == "jvm":
        # the module axis: sealed rows name no module and keep the mesh
        # road byte-identical; a :core court declaréth "module": "core"
        module = entry.get("module", "mesh")
        # the task axis: the app isle buildeth the LIGHT flavor alone, so its
        # unit road is testLightDebugUnitTest; sealed rows name no task and
        # keep the plain one byte-identical
        task = entry.get("test_task", "testDebugUnitTest")
        # *** PHASE 5 (round 603): THE ANDROID LINEAGE'S INSTRUMENT DEFECT, FOUND BY READING A ROD'S OWN LOG. ***
        #
        # EVERY ANDROID ROD RETURNED `INVALID :: the baseline itself did not pass unmutated`, WHICH READS LIKE A CODE
        # PROBLEM AND IS NOT ONE. **THE LOG SAID IT PLAINLY:**
        #     "A problem occurred configuring project ':llm'. > SDK location not found. Define a valid SDK location
        #      with an ANDROID_HOME environment variable ..."
        # **THIS SUBPROCESS WAS RUN WITH NO `env=`, SO THE DISPOSABLE WORKTREE'S GRADLE INHERITED NOTHING AND COULD NOT
        # EVEN CONFIGURE** -- the mutant never built, so no rod could ever be KILLED on this isle. The macOS shell
        # that runs the suite exports `JAVA_HOME`/`ANDROID_HOME`; `subprocess.run` does not see them by DEFAULT.
        #
        # AND THE ROOT-CAUSE SHAPE IS THE SAME ONE THIS PROGRAMME KEEPS FINDING: **A TOOL REPORTING "INVALID" IS NOT A
        # RESULT ABOUT THE CODE, AND READING THE LOG RATHER THAN THE VERDICT IS WHAT SETTLED IT.**
        _gradle_env = dict(os.environ)
        _gradle_env.setdefault("JAVA_HOME", "/opt/homebrew/opt/openjdk@17")
        _gradle_env.setdefault("ANDROID_HOME", os.path.expanduser("~/Library/Android/sdk"))
        # *** AND THE ROSTER MAY NOT BE ANSWERED BY A CACHED GENERATION. ***
        #
        # *Gradle's `UP-TO-DATE` and `FROM-CACHE` are HONEST about a task whose
        # INPUTS have not changed -- and a mutant is an input change it may not
        # notice across the phases of one rod: the baseline write, the mutant
        # write and the restore all land inside one daemon-less invocation
        # each, but a build cache keyed on the previous phase's bytes would
        # hand back the PREVIOUS phase's XML.* **So the task directory is
        # DELETED before every run and `--rerun-tasks` is passed, and a roster
        # that did not actually execute cannot satisfy a rod.**
        xml_dir = os.path.join(wt_path, "android", module, "build", "test-results",
                               task)
        shutil.rmtree(xml_dir, ignore_errors=True)
        proc = subprocess.run(
            ["./gradlew", ":" + module + ":" + task, "--no-daemon", "-q",
             "--rerun-tasks", "--tests", entry["gradle_filter"]],
            cwd=os.path.join(wt_path, "android"), capture_output=True, text=True,
            env=_gradle_env,
            timeout=timeout)
        blob = (proc.stdout or "") + (proc.stderr or "")
        build_exit = 1 if KT_COMPILE_RE.search(blob) else 0
        run = 0
        skipped = 0
        fails = 0
        failed = set()
        # *** THE ROSTER IS RENDERED INTO THE BLOB, BECAUSE GRADLE `-q` PRINTS NOTHING ON A GREEN RUN. ***
        #
        # *THE DEFECT THIS CLOSES, MEASURED: the jvm branch deriveth its verdict from the JUnit XML but wrote the
        # GRADLE output as the phase blob -- and `-q` emiteth NOTHING when the build succeedeth, so the BASELINE and
        # RESTORED phase logs were EMPTY FILES (`e3b0c442...`, the empty-string digest) for 26 of 49 required rods.*
        # **A kill whose baseline and restored logs are empty is EVIDENCE-INCOMPLETE: a reader cannot re-check that
        # the unmutated tree passed or that the restoration returned to green -- the manifest's `ok=true` would be the
        # only witness, which is precisely the downstream-substitution trap.** *So the roster the classifier READ is
        # rendered back into the blob as its own evidence, per suite and per case, and travels into the phase log.*
        roster_lines: list[str] = []
        if os.path.isdir(xml_dir):
            for name in sorted(os.listdir(xml_dir)):
                if not (name.startswith("TEST-") and name.endswith(".xml")):
                    continue
                t = open(os.path.join(xml_dir, name), encoding="utf-8").read()
                m = re.search(r'tests="([0-9]+)" skipped="([0-9]+)" failures="([0-9]+)" errors="([0-9]+)"', t)
                if not m:
                    continue
                roster_lines.append(
                    "TEST-SUITE %s tests=%s skipped=%s failures=%s errors=%s"
                    % (name, m.group(1), m.group(2), m.group(3), m.group(4)))
                run += int(m.group(1))
                skipped += int(m.group(2))
                fails += int(m.group(3)) + int(m.group(4))
                for cn in re.findall(r'<testcase name="([^"]+)"[^>]*/>', t):
                    roster_lines.append("TEST-CASE PASS %s" % cn)
                for cn, _det in re.findall(
                        r'<testcase name="([^"]+)"[^>]*>\s*<(?:failure|error)[^>]*message="([^"]*)"', t):
                    failed.add(cn)
                    roster_lines.append("TEST-CASE FAIL %s" % cn)
        if roster_lines:
            blob = blob + "\n" + "\n".join(roster_lines) + "\n"
        return {"build_exit": build_exit, "run": (run if run else None),
                "skipped": skipped, "failed": failed, "blob": blob}
    if entry["platform"] in ("shell", "selftest"):
        # *** A CONTROL WHOSE WITNESS IS A COMMITTED SELFTEST, OR A SHELL GUARD. ***
        #
        # *Some production controls prove themselves with an in-repo selftest -- e.g.
        # `ci/check_lane_results.py --selftest-foundation` runs a family of mutations
        # against the control and requirith each to be REFUSED.* **The witness is the
        # selftest's EXIT CODE: the baseline exiteth 0, the mutant exiteth non-zero
        # (a mutation ESCAPED its guard), and the named-case line is captured so the
        # failure is attributable rather than a bare rc.**
        #
        # *** A SHELL ROD'S WITNESS IS A STATIC GUARD ASSERTION, NEVER A RUN OF THE
        # SCRIPT. *** *The runner script compiles the whole Android tree when
        # executed -- running it inside a mutation harness would be slow and would
        # touch the live environment. So the shell witness is a pair of static
        # checks the rod names: `sh -n` (the mutated script still PARSES) plus a
        # `guard_pattern` that MUST be present in the mutated file. An omission rod
        # that removes the guard makes the pattern vanish, and the witness reddens
        # -- an asserted invariant of the script, measured without executing it.*
        if entry["platform"] == "selftest":
            # *** A MUTANT THAT DOES NOT PARSE IS NOT A KILL. ***
            #
            # *MEASURED, FROM A REAL DEFECT: a rod whose `find` was TRUNCATED to the
            # first line of a two-line statement produced an `IndentationError` -- the
            # control exited non-zero because the FILE WAS BROKEN, not because a
            # mutation ESCAPED its guard, and the rod was booked KILLED. **A mutation
            # that only breaks the parser proves nothing.** So the mutated control is
            # compiled FIRST; a parse failure is BUILD_INVALID (a bad mutant), never a
            # catch, whichever platform the witness belongs to.*
            control = os.path.join(wt_path, entry["control"])
            try:
                compile(open(control, encoding="utf-8").read(), control, "exec")
            except SyntaxError as exc:
                return {"build_exit": 1, "run": None, "skipped": 0, "failed": set(),
                        "blob": f"the mutated control does not parse: {exc}"}
            argv = [sys.executable, "-B", entry["control"], entry["selftest_flag"]]
            proc = subprocess.run(argv, cwd=wt_path, capture_output=True, text=True,
                                  timeout=timeout)
            blob = (proc.stdout or "") + (proc.stderr or "")
            # *** THE PER-CASE TABLE IS `<label>. <name>  expect=… got=… <VERDICT>`.
            # THE LABEL IS AT LINE START; the rod names which labels must go red. ***
            failed = set()
            for line in blob.splitlines():
                if "ESCAPED" not in line and "FAIL" not in line:
                    continue
                # `<label>. <name>  expect=… got=… <VERDICT>` (lane selftests)
                m = re.match(r"\s*([0-9]+[a-z]?)\.", line)
                if m:
                    failed.add(m.group(1))
                # `FAIL: <label> -- ...` (the manifest module selftest)
                f = re.match(r"\s*FAIL:\s*(.+?)\s*--", line)
                if f:
                    failed.add(f.group(1).strip())
            # the alternate shapes
            failed |= {m for m in re.findall(r"^\s*ESCAPED\s+([0-9]+[a-z]?)", blob, re.M)}
            failed |= {m.strip() for m in re.findall(r"^\s*FAIL:\s*(.+?)\s*--", blob, re.M)}
            # *** THE RUN COUNT: the lane selftests print `expect=… got=…` per case;
            # the manifest module selftest instead prints `N/M mutations killed`. ***
            run = len(re.findall(r"expect=\S+\s+got=\S+", blob)) or None
            if run is None:
                msum = re.search(r"(\d+)\s*/\s*(\d+)\s+mutations killed", blob)
                if msum:
                    run = int(msum.group(2))
            build_exit = 0
            # *** THE KILL MUST BE ATTRIBUTED TO THE INTENDED NAMED CONTROL. ***
            #
            # *A rod's whole claim is "mutate THIS guard and THIS negative fixture goes
            # red". A non-zero rc from ANY control is not that claim: the intended
            # fixture could still be green while some unrelated case reddened (a host
            # quirk, a moved anchor). So when the rod names `expect_escaped`, the
            # executor requirith one of those labels in the ESCAPED set -- the witness
            # that reddened must be the one the rod was built to provoke, or the rod is
            # EXEC_INVALID (unattributed), never a catch.*
            #
            # *** THE LABELS ARE PER-FAMILY, AND THAT IS WHY EACH ROD RUNS EXACTLY ONE
            # FAMILY: `foundation` and `simulator` each carry their own `7a`/`7b`/`10`
            # with DIFFERENT meanings. A rod's `expect_escaped` is therefore read
            # against ITS OWN `selftest_flag`'s output alone -- a label of the same
            # number in another family can never satisfy it, because that family's
            # process is not what this rod ran. ***
            expected = set(entry.get("expect_escaped") or [])
            if expected:
                if proc.returncode != 0 and (expected & failed):
                    # the INTENDED negative fixture escaped: a genuine kill
                    return {"build_exit": 0, "run": run, "skipped": 0,
                            "failed": {entry["witness"]}, "blob": blob}
                return {"build_exit": 0, "run": None, "skipped": 0, "failed": set(),
                        "blob": blob + f"\n(the intended control(s) {sorted(expected)} did NOT escape -- "
                                       f"observed ESCAPED={sorted(failed)}; an unattributed failure is not a kill)"}
            if proc.returncode != 0 and not failed:
                return {"build_exit": 0, "run": None, "skipped": 0, "failed": set(),
                        "blob": blob + "\n(the control exited non-zero but no ESCAPED fixture was named -- an "
                                       "unattributed failure is not a kill)"}
            return {"build_exit": build_exit, "run": run if run is not None else 0,
                    "skipped": 0, "failed": failed, "blob": blob}
        # *** THE SHELL WITNESS RUNS THE RUNNER'S OWN GUARD, UNDER A CONTROLLED
        # FIXTURE, RATHER THAN GREPPING ITS SOURCE. ***
        #
        # *"A pattern is present in the file" is a WIRING assertion, not a
        # behavioural one, and the user's sections 8/37 forbid counting it as a
        # semantic kill. So the guard is EXECUTED: the rod names a `guard_command`
        # that drives the runner's protection under a controlled fixture and exits
        # non-zero when the protection is absent. A source greple is deliberately
        # NOT accepted here.*
        guard = entry.get("guard_command")
        if not guard:
            # a shell rod with no invoked guard cannot make a semantic claim
            return {"build_exit": 0, "run": None, "skipped": 0, "failed": set(),
                    "blob": "the shell rod names no guard_command -- a source grep is not a behavioural witness"}
        target = os.path.join(wt_path, entry["script"])
        syntax = subprocess.run(["sh", "-n", target], capture_output=True, text=True,
                                timeout=120)
        proc = subprocess.run(["sh", "-c", guard], cwd=wt_path, capture_output=True,
                              text=True, timeout=timeout)
        blob = (f"sh -n rc={syntax.returncode}\nguard: {guard}\nguard rc={proc.returncode}\n"
                + (syntax.stdout or "") + (syntax.stderr or "")
                + (proc.stdout or "") + (proc.stderr or ""))
        failed = set()
        # the guard FAILING against the mutant is the witness reddening
        if proc.returncode != 0:
            failed.add(entry["witness"])
        return {"build_exit": 0, "run": 1, "skipped": 0, "failed": failed, "blob": blob}
    if entry["platform"] == "python":
        # the py court sits in whichever home the row names; the single
        # witness is chosen by -k, and its verdict is read from unittest's
        # own records: "Ran N tests", the (FAIL)/(ERROR) proclamations,
        # and the verbose per-test lines. A SyntaxError or ImportError
        # that keeps the named witness from ever speaking is a broken
        # mutant, not an escape.
        # before the court sits, purge every stale bytecode cache: an equal-
        # length mutation landed inside one second of the checkout keeps the
        # (mtime, size) cache key of the faithful file and the timestamp pyc
        # would stay believed -- the court would execute old code against new
        # bytes and acquit the guilty (learned the hard way from the SM6
        # ArchiveEmptyError/ArchiveBuildError pair, seventeen bytes both).
        for _dirpath, _dirnames, _filenames in os.walk(wt_path):
            if _dirnames and _dirpath.endswith("__pycache__"):
                shutil.rmtree(_dirpath, ignore_errors=True)
                _dirnames[:] = []
        proc = subprocess.run(
            [sys.executable, "-B", "-m", "unittest", "discover",
             "-s", entry.get("py_dir", "tools/readiness/tests"),
             "-p", entry.get("py_pattern", "test_t45.py"),
             "-k", entry["witness"], "-v"],
            cwd=wt_path, capture_output=True, text=True, timeout=timeout)
        blob = (proc.stdout or "") + (proc.stderr or "")
        m = re.search(r"Ran ([0-9]+) tests?", blob)
        run = int(m.group(1)) if m else None
        failed = set(re.findall(r"(?:^|\n)(?:FAIL|ERROR): (\S+)", blob))
        failed |= set(re.findall(
            r"(test_[A-Za-z0-9_]+) \([^)]*\) \.\.\. (?:FAIL|ERROR)", blob))
        spoke = re.search(
            re.escape(entry["witness"]) + r" \([^)]*\) \.\.\. ok", blob)
        build_exit = 1 if (
            spoke is None
            and re.search(r"\b(?:SyntaxError|ImportError)\b", blob)) else 0
        # unittest reporteth a skip as `skipped 'reason'` on the verbose line:
        # *a court that answered by skipping is a court that measured nothing.*
        return {"build_exit": build_exit, "run": run,
                "skipped": len(re.findall(r"\.\.\. skipped", blob)),
                "failed": failed, "blob": blob}
    # the class-form filter is this harness's dialect: the method-form
    # filter answers 'Test run with 0 tests' and blinds the oracle
    # *** THE TWO-STEP LANE: BUILD THE ROD'S OWN TARGET, THEN RUN IT WITHOUT
    # REBUILDING THE WHOLE PACKAGE. ***
    #
    # *MEASURED: an unscoped `swift test` compiles EVERY target, so a sibling's
    # in-flight test file in ANOTHER target (e.g. a GodstoneMeshTests file that does
    # not yet compile) reports a BUILD failure that is NOT this rod's -- a phantom
    # red that would masquerade as a non-catch. So a rod may name the `swift_target`
    # it lives in; the harness builds JUST that target, then runs with `--skip-build`
    # so the foreign target is never compiled. A rod without `swift_target` keeps the
    # one-shot `swift test` (unchanged for the existing ledger).*
    swift_target = entry.get("swift_target")
    pre_blob = ""
    argv = ["swift", "test", "--package-path", "ios/Packages/GodstoneFoundation"]
    if swift_target:
        # *** BUILD JUST THIS TARGET, THEN RUN ITS OWN xctest BUNDLE DIRECTLY. ***
        #
        # *`swift test --skip-build` still ENUMERATES every test bundle and dies when a
        # SIBLING target's bundle was never built ("...LabMeshTests.xctest doesn't exist
        # in file system") -- so it is not a lane. Running the built bundle with
        # `xcrun xctest` touches ONLY this target's tests: a foreign target's in-flight
        # compile error can no longer report a phantom red against this rod.*
        build = subprocess.run(
            ["swift", "build", "--package-path", "ios/Packages/GodstoneFoundation",
             "--target", swift_target],
            cwd=wt_path, capture_output=True, text=True, timeout=timeout)
        pre_blob = ("=== swift build --target %s ===\n" % swift_target
                    + (build.stdout or "") + (build.stderr or "") + "\n")
        if SWIFT_COMPILE_RE.search(pre_blob) or build.returncode != 0:
            # the rod's OWN target did not compile: a bad mutant, not an escape
            return {"build_exit": 1, "run": None, "skipped": 0, "failed": set(),
                    "blob": pre_blob}
        import glob as _glob
        root = os.path.join(wt_path, "ios", "Packages", "GodstoneFoundation", ".build",
                            "out", "Products")
        bundles = _glob.glob(os.path.join(root, "*", swift_target + ".xctest"))
        # *** THE BUNDLE MUST BE UNAMBIGUOUS, AND THE HOST'S. *** *`.build/out/Products/`
        # can carrieth BOTH `Debug/` and `Debug-iphonesimulator/`; an unguarded `*` would
        # bind whichever the filesystem returneth first, quietly handing the host
        # `xcrun xctest` a SIMULATOR bundle. So the host bundle (`Debug/`) is preferred,
        # and ANY residual ambiguity is a NAMED refusal rather than a silent pick.*
        host = os.path.join(root, "Debug", swift_target + ".xctest")
        if os.path.isdir(host):
            chosen = host
        elif len(bundles) == 1:
            chosen = bundles[0]
        else:
            return {"build_exit": 1, "run": None, "skipped": 0, "failed": set(),
                    "blob": pre_blob + f"\n(no unambiguous host bundle for {swift_target!r}: "
                                       f"candidates={sorted(bundles)})"}
        # *THE BUNDLE TAKES A CLASS-LEVEL `-XCTest` SELECTOR, not a `--filter` path:
        # the class part of the rod's filter is selected, and the named witness is then
        # attributed from the case lines. A method-path selector matches ZERO tests.*
        flt = entry.get("swift_filters", [entry.get("swift_filter")])[0] or ""
        klass = flt.split("/")[0] or swift_target
        proc = subprocess.run(["xcrun", "xctest", "-XCTest", klass, chosen],
                              cwd=wt_path, capture_output=True, text=True, timeout=timeout)
        blob = pre_blob + (proc.stdout or "") + (proc.stderr or "")
        build_exit = 1 if SWIFT_COMPILE_RE.search(blob) else 0
        totals = [int(a) for a, b in EXEC_RE.findall(blob) if int(a) >= 1]
        run = max(totals) if totals else None
        failed = {n for n in FAILED_CASE_RE.findall(blob) if n}
        return {"build_exit": build_exit, "run": run,
                "skipped": len(re.findall(r"Test Case '.*' skipped", blob)),
                "failed": failed, "blob": blob}
    for flt in entry.get("swift_filters", [entry.get("swift_filter", "ReadinessT20Tests")]):
        argv += ["--filter", flt]
    proc = subprocess.run(argv, cwd=wt_path, capture_output=True, text=True, timeout=timeout)
    blob = pre_blob + (proc.stdout or "") + (proc.stderr or "")
    build_exit = 1 if SWIFT_COMPILE_RE.search(blob) else 0
    totals = [int(a) for a, b in EXEC_RE.findall(blob) if int(a) >= 1]
    run = max(totals) if totals else None
    failed = {n for n in FAILED_CASE_RE.findall(blob) if n}
    return {"build_exit": build_exit, "run": run,
            "skipped": len(re.findall(r"Test Case '.*' skipped", blob)),
            "failed": failed, "blob": blob}


# ---------------------------------------------------------------------------
# T67 -- THE CLASSIFIER'S RULES ARE DATA, so that they can be BROKEN ON PURPOSE.
#
# "Existing mutations can count missing/skipped anchors as killed." A classifier
# whose rules are only code can only be TRUSTED; a classifier whose rules are a
# POLICY can be PROVEN -- the selftest injecteth deliberately broken policies and
# requireth that at least one known-answer case catch each of them. The named
# negative is `skipped_is_killed`: a harness that counted a SKIPPED rod (a moved
# anchor) as a kill MUST fail the selftest.
# ---------------------------------------------------------------------------

class ClassifyPolicy:
    """The rules a verdict obeyeth. The default is the only honest one."""

    __slots__ = ("require_baseline", "require_build", "require_anchor", "require_run",
                 "require_restored", "killed_on_hit", "skipped_is_killed",
                 "escaped_is_killed", "invalid_is_killed", "timeout_is_killed")

    def __init__(self, require_baseline=True, require_build=True, require_anchor=True,
                 require_run=True, require_restored=True, killed_on_hit=True,
                 skipped_is_killed=False, escaped_is_killed=False,
                 invalid_is_killed=False, timeout_is_killed=False):
        self.require_baseline = require_baseline
        self.require_build = require_build
        self.require_anchor = require_anchor
        self.require_run = require_run
        # *a kill without its restored-green companion is an unproven kill.*
        self.require_restored = require_restored
        self.killed_on_hit = killed_on_hit
        self.skipped_is_killed = skipped_is_killed
        self.escaped_is_killed = escaped_is_killed
        self.invalid_is_killed = invalid_is_killed
        self.timeout_is_killed = timeout_is_killed

    def name(self):
        broken = [k for k in ("skipped_is_killed", "escaped_is_killed",
                              "invalid_is_killed", "timeout_is_killed")
                  if getattr(self, k)]
        if not self.require_baseline:
            broken.append("baseline_unchecked")
        if not self.require_build:
            broken.append("build_unchecked")
        if not self.require_run:
            broken.append("run_unchecked")
        if not self.require_restored:
            broken.append("restoration_unchecked")
        return "default" if not broken else "broken:" + "+".join(broken)


DEFAULT_POLICY = ClassifyPolicy()


def _classify_with(policy, entry, build_exit, run, failed, baseline_ok, anchor_count=1,
                   skipped=0, restored_green=None):
    """One verdict, from the policy's rules. ONLY KILLED is a catch.

    *** THE VERDICTS ARE ATTRIBUTABLE, WHICH IS THE WHOLE POINT. *** *A single
    `INVALID` conflated two different instrument failures with two different
    repairs -- a mutant that never compiled is a BAD MUTANT, a roster that never
    executed is a BAD INVOCATION -- so the outcome now names WHICH:* **BUILD_INVALID**
    the compiler refused the mutant; **EXEC_INVALID** the roster executed zero
    cases or answered by SKIPPING (a skip measureth nothing); **BASELINE_INVALID**
    the unmutated tree itself did not pass; **INCOMPLETE** the restored-green
    companion never executed, so a kill is unproven. *Every one of those is a
    refusal, and none is a catch.*
    """
    if policy.require_anchor and anchor_count != 1:
        note = "the anchor was seen %d times, not exactly once" % anchor_count
        return ("KILLED", note) if policy.skipped_is_killed else ("SKIPPED", note)
    if policy.require_baseline and not baseline_ok:
        note = "the baseline itself did not pass unmutated"
        return ("KILLED", note) if policy.invalid_is_killed else ("BASELINE_INVALID", note)
    if policy.require_build and build_exit != 0:
        # *** A COMPILE FAILURE IS A KILL ONLY WHEN THE PROPERTY THE ROD STRIKES
        # **IS** TYPE ENFORCEMENT. *** *A rod whose whole mechanism is "a caller
        # cannot reach this without the parameter" is PROVEN by the compiler
        # refusing the mutant -- and only such a rod may claim it. Any other rod
        # whose mutant happens not to compile is BUILD_INVALID, a bad mutant, not
        # a catch. The distinction is data on the entry (`type_enforced`), so it is
        # declared where the rod is written rather than inferred from a log. The
        # OUTCOME stays `KILLED` -- the vocabulary is unchanged -- and the row's
        # `kill_channel` sayeth the compiler did it.*
        if entry.get("type_enforced"):
            return "KILLED", ("the mutant did not compile -- and TYPE ENFORCEMENT is the property this rod strikes, "
                              "so the compiler's refusal IS the kill")
        note = "the mutant did not compile"
        return ("KILLED", note) if policy.invalid_is_killed else ("BUILD_INVALID", note)
    witness_tail = entry["witness"].rpartition("/")[2].rpartition(".")[2]
    hit = any(witness_tail in f or f == witness_tail for f in failed)
    if policy.require_run and skipped:
        note = "%d arm(s) SKIPPED -- a skip measureth nothing" % skipped
        return ("KILLED", note) if policy.invalid_is_killed else ("EXEC_INVALID", note)
    if policy.require_run and (run is None or run == 0):
        note = "the harness executed nothing"
        return ("KILLED", note) if policy.invalid_is_killed else ("EXEC_INVALID", note)
    if hit and policy.killed_on_hit:
        # *** A KILL IS ONLY A KILL WHEN THE RESTORATION IS SHOWN. ***
        if policy.require_restored and not (restored_green and restored_green.get("ok")):
            note = ("witness %s failed as intended, BUT the restored-green rerun never "
                    "executed the roster -- an unproven kill is not a catch"
                    % witness_tail)
            return ("KILLED", note) if policy.invalid_is_killed else ("INCOMPLETE", note)
        return "KILLED", "witness %s failed as intended (%d failed case(s)); the restored " \
                         "tree ran the roster green" % (witness_tail, len(failed))
    if failed:
        note = ("the named witness stayed green; other cases failed (" +
                ", ".join(sorted(failed))[:180] + ") - inspect")
        return ("KILLED", note) if policy.escaped_is_killed else ("ESCAPED", note)
    note = ("the witness stayed green against the mutant" if not hit else
            "the named witness was seen but the kill rule is asleep")
    return ("KILLED", note) if policy.escaped_is_killed else ("ESCAPED", note)


def _classify(entry, build_exit, run, failed, baseline_ok, anchor_count=1, skipped=0,
              restored_green=None):
    return _classify_with(DEFAULT_POLICY, entry, build_exit, run, failed, baseline_ok,
                          anchor_count, skipped, restored_green)


def _tested_input_digests() -> dict:
    """A digest per file-family the campaign MUTATES AND READS, plus the runner itself.

    *A digest map, not one number: a reader who see'th a mismatch must be able to NAME which family moved, and one
    digest over everything would only say "something changed".* **`ci/mutations.py` is included because the rods'
    `find`/`replace` pairs live in ITS bytes -- a manifest that bound only the mutated tree would not notice a rod
    definition changing under the run.**
    """
    families = {
        "swift_sources": ("ios/Godstone/Sources", "*.swift"),
        "swift_tests": ("ios/Godstone/Tests", "*.swift"),
        "mirror_sources": ("ios/Packages/GodstoneFoundation/Sources", "*.swift"),
        "mirror_tests": ("ios/Packages/GodstoneFoundation/Tests", "*.swift"),
        "android_sources": ("android/mesh/src", "*.kt"),
        "android_labmesh": ("android/labmesh/src", "*.kt"),
    }
    out: dict[str, str] = {}
    for name, (rel, pattern) in families.items():
        h = hashlib.sha256()
        base = os.path.join(ROOT, rel)
        if os.path.isdir(base):
            matches: list[str] = []
            for dirpath, _dirnames, filenames in os.walk(base):
                for fn in filenames:
                    if fn.endswith(pattern.lstrip("*")):
                        matches.append(os.path.join(dirpath, fn))
            for path in sorted(matches):
                h.update(os.path.relpath(path, ROOT).encode())
                h.update(b"\0")
                with open(path, "rb") as stream:
                    h.update(stream.read())
                h.update(b"\0")
        out[name] = h.hexdigest()
    for rel in ("ci/mutations.py", "ios/project.yml", "android/settings.gradle.kts"):
        path = os.path.join(ROOT, rel)
        out[rel] = _sha_file(path) or "absent"
    # *** EVERY OTHER FILE A ROD MUTATES, BY ITS OWN DIGEST. ***
    #
    # *The family digests above cover the Swift/Kotlin source trees, but a rod may
    # strike a PYTHON control, a SUPPLY-CHAIN tool, a SHELL runner or the lane
    # checker -- and a manifest that bound none of those would not notice one of
    # them changing under a kill. So each rod's own `file` is digested by its
    # repo-relative path, and a rod whose target is not otherwise covered becomes
    # a bound input the moment the rod exists.*
    for spec in SEMANTIC:
        for rel in (spec.get("file"), spec.get("guard_file")):
            if not rel or rel in out:
                continue
            out[rel] = _sha_file(os.path.join(ROOT, rel)) or "absent"
    return out


def _toolchain_probe() -> dict:
    """The toolchain versions the campaign ran under, PROBED rather than asserted.

    *A campaign whose compiler version is unrecorded cannot be re-executed: the same sources under a different Swift or
    JDK can compile differently, and a KILL obtained under an unrecorded toolchain is a verdict nobody can reproduce.*
    """
    out: dict[str, str] = {}
    for name, argv in (("swift", ["swift", "--version"]),
                       ("xcodebuild", ["xcodebuild", "-version"]),
                       ("java", ["java", "-version"])):
        try:
            proc = subprocess.run(argv, capture_output=True, text=True, timeout=60)
            blob = (proc.stdout or "") + (proc.stderr or "")
            out[name] = blob.strip().splitlines()[0] if blob.strip() else "no output"
        except Exception as exc:  # noqa: BLE001 - an unobtainable version must be NAMED, not omitted
            out[name] = f"unavailable: {type(exc).__name__}"
    return out


def run_semantic(report_only, emit_dir, baseline_sha, work_parent, only_ids=None, group=None):
    head = baseline_sha or subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True,
        text=True).stdout.strip()
    # *** `--id` SELECTETH A SUBSET, SO A CAMPAIGN MAY RUN THE RODS IT OWNS
    # WITHOUT THE WHOLE LEDGER. *** *An unselected row is UNTOUCHED: no
    # worktree, no run, no row -- so a subset run CANNOT be quoted as a full
    # ledger, and its manifest sayeth which ids it judged.*
    #
    # *** AND `--group NAME` IS THE SAME SELECTION FROM A NAMED SET IN THE SOURCE. *** *Forty ids on a command line
    # inviteth a typo that silently narroweth the population while still PASSING -- so the Board 1 campaign names its
    # group, and an unknown id inside that group is refused above rather than skipped.*
    if group:
        only_ids = list(only_ids or []) + _group_ids(group)
    selected = [s for s in SEMANTIC if not only_ids or s["id"] in set(only_ids)]
    unknown = sorted(set(only_ids or ()) - {s["id"] for s in SEMANTIC})
    if unknown:
        print("::error::unknown rod id(s): " + ", ".join(unknown), file=sys.stderr)
        return 1
    rows = []
    tally = {k: 0 for k in ("KILLED", "SKIPPED", "BUILD_INVALID", "EXEC_INVALID",
                            "BASELINE_INVALID", "INCOMPLETE", "TIMEOUT", "ESCAPED")}
    # *** EVERY ROW'S PATH IS STORED RELATIVE TO THE CAMPAIGN ROOT. *** *A
    # downloaded artifact lands under an arbitrary root, so a path relative to
    # the emit-dir is the only form a reader can resolve; the binding is done
    # once here rather than at each of the seven row sites.*
    campaign_root = emit_dir
    tested_tree = _tested_tree_sha()

    # *** `guard_only` RODS ARE STRUCTURAL, NOT SEMANTIC, AND COUNTED SEPARATELY. ***
    #
    # *A rod whose witness is a SOURCE-SHAPE assertion (a wiring/pattern check) may NOT
    # be booked as a semantic kill: the user's sections 8/37 require a MEANINGFUL
    # behavioural mutation, and "the pattern vanished from the file" proves nothing
    # about behaviour. Such a rod is recorded with category="structural" and is kept
    # OUT of the semantic counts -- the two populations are never summed.*
    def _mrow(*args, **kwargs):
        kwargs.setdefault("campaign_root", campaign_root)
        entry = args[0]
        if entry.get("guard_only"):
            kwargs["structural"] = True
        row = _row(*args, **kwargs)
        # *** THE ROW CARRIETH THE EXACT CANDIDATE TREE IT RAN AGAINST. *** *The
        # envelope names it once; each row repeats it so a row lifted out of its
        # envelope still says which bytes its kill is about.*
        row["tested_tree_sha"] = tested_tree
        return row

    print("SEMANTIC lineage (oracle: the readiness suites' named witnesses; "
          "disposable worktrees; the live tree is never touched)")
    if only_ids:
        print("  (subset: %d of %d row(s), selected by --id)" % (len(selected), len(SEMANTIC)))
    for spec in selected:
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
            # under audit, and let any drift show rather than be hidden.
            # *** A GUARD-SCRIPT ROD COMPILES NOTHING: its oracle is the guard's
            # own process, which reads the worktree directly, so re-syncing the
            # Swift mirror would be pure cost on a rod whose file is not a mirror
            # source at all. ***
            sync_needed = not entry.get("guard_file")
            if sync_needed:
                subprocess.run([sys.executable, "scripts/sync_ios_foundation_package.py"],
                               cwd=wt_path, capture_output=True, timeout=300, check=True)
            target = os.path.join(wt_path, entry["file"])
            text = open(target, encoding="utf-8").read()
            anchor_count = text.count(entry["find"])
            if anchor_count != 1:
                tally["SKIPPED"] += 1
                rows.append(_mrow(entry, head, "semantic", anchor_count, None,
                                [entry["witness"]], None, "SKIPPED",
                                "anchor seen %d times; never counted as a catch" % anchor_count,
                                None))
                print("  SKIPPED  %-34s anchor %d -- the needle moved on"
                      % (entry["id"], anchor_count))
                continue
            # *** WITNESS-PRESENCE PREFLIGHT: THE NAMED ARM MUST EXIST IN THE COURT
            # AT THE AUDITED COMMIT, OR THE ROD CANNOT BE AIMED. ***
            #
            # *A witness that is ABSENT from a court bundle runs ZERO tests that match
            # it, so the "baseline green" is a green over a class that never contained
            # the witness -- the exact false-green section 21 refuses. This is also the
            # MIRROR-DRIFT signal: a lane built from the GENERATED package will present
            # a stale class if the sync did not run, so a missing witness is refused BY
            # NAME here rather than emerging later as an innocent-looking SKIP.*
            court = entry.get("court")
            witness = entry.get("witness")
            if court and witness and not witness.startswith("COMPILE_NEGATIVE"):
                court_path = os.path.join(wt_path, court)
                if os.path.isfile(court_path):
                    body = open(court_path, encoding="utf-8").read()
                    # swift `func`, python `def`, kotlin `fun` -- the named arm's decl
                    present = any(("%s %s(" % (kw, witness)) in body
                                  for kw in ("func", "def", "fun"))
                    if not present:
                        tally["SKIPPED"] += 1
                        rows.append(_mrow(entry, head, "semantic", 0, None,
                                        [witness], None, "SKIPPED",
                                        f"the named witness {witness!r} is ABSENT from {court} at this commit -- "
                                        f"a court that never contained the witness cannot be aimed (a missing sync "
                                        f"or an unlanded arm), never a catch", None))
                        print("  SKIPPED  %-34s witness ABSENT from the court" % entry["id"])
                        continue
            # 1. the baseline must pass unmutated, or nothing below may claim a kill
            #
            # *** A BASELINE THAT HANGS OR THROWS IS RECORDED, NOT DROPPED. ***
            #
            # *THE DEFECT THIS CLOSES: `_run_harness` was called with NO guard, so a baseline `TimeoutExpired` escaped
            # the per-rod `try` and reached... the outer handler, where `rows` never received a row for this rod. **A
            # campaign that crashes on rod 12 produceth a manifest with eleven rows and an exception traceback -- and
            # eleven KILLED rows in a file named `manifest.json` read as a complete, green campaign.** So the baseline
            # is guarded exactly as the mutant and the restoration already are, its raw stderr is retained, and the
            # row is written with an explicit outcome.*
            try:
                base = _run_harness(entry, wt_path)
            except subprocess.TimeoutExpired as exc:
                tally["TIMEOUT"] += 1
                row = _mrow(entry, head, "semantic", anchor_count, None,
                           [entry["witness"]], None, "TIMEOUT",
                           "the BASELINE harness did not settle inside the bound", None)
                if emit_dir:
                    log_dir = os.path.join(emit_dir, "logs")
                    os.makedirs(log_dir, exist_ok=True)
                    blob = (exc.stdout or b"") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
                    if isinstance(blob, bytes):
                        blob = blob.decode("utf-8", "replace")
                    open(os.path.join(log_dir, entry["id"] + ".baseline.log"), "w",
                         encoding="utf-8").write(str(blob) + "\n\n"
                                                 "(the baseline harness timed out; partial stdout above)")
                rows.append(row)
                print("  TIMEOUT  %s (baseline)" % entry["id"])
                continue
            except Exception as exc:  # noqa: BLE001 - a baseline exception must be a ROW, never a lost rod
                tally["BASELINE_INVALID"] += 1
                rows.append(_mrow(entry, head, "semantic", anchor_count, None,
                                 [entry["witness"]], None, "BASELINE_INVALID",
                                 f"the baseline harness raised {type(exc).__name__}: {exc}", None))
                print("  BASELINE_INVALID  %s :: %s" % (entry["id"], exc))
                continue
            baseline_ok = (base["build_exit"] == 0 and base["run"] not in (None, 0)
                           and not base["failed"] and not base["skipped"])
            # 2. install the mutant, exactly once
            open(target, "w", encoding="utf-8").write(
                text.replace(entry["find"], entry["replace"], 1))
            post = open(target, encoding="utf-8").read()
            if entry["replace"]:
                assert post.count(entry["replace"]) == 1 and post.count(entry["find"]) == 0, \
                    "the mutation did not install cleanly"
            else:
                # *** AN OMISSION ROD DELETES ITS ANCHOR. *** *A control that
                # strikes a rendered control by REMOVING it has an empty
                # replacement, so the install proof is that the anchor is gone
                # and the file SHRANK by exactly its length -- never that the
                # empty string "appears once".*
                assert post.count(entry["find"]) == 0 and len(post) == len(text) - len(entry["find"]), \
                    "the omission did not install cleanly"
            # the island's compiler reads the mirrored package: after any
            # mutation of a canonical source the mirror must be re-synced,
            # or the mutant never reaches the binary and a false escape is
            # recorded against a witness that never saw the mutation
            if sync_needed:
                subprocess.run([sys.executable, "scripts/sync_ios_foundation_package.py"],
                               cwd=wt_path, capture_output=True, timeout=300, check=True)
            if entry["platform"] == "swift" and sync_needed:
                # a witness may only swear upon the mirrored package it saw
                # with its own eyes: confirm the mutation is in the compiler's
                # true input, retrying the sync once should a racing teardown
                # of the previous harness have obscured it
                mir = os.path.join(wt_path, entry["file"].replace(
                    "ios/Godstone/Sources/", "ios/Packages/GodstoneFoundation/Sources/"))
                for _ in range(2):
                    mt = open(mir, encoding="utf-8").read()
                    # *** THE MIRROR MUST BE THE MUTANT SOURCE, BYTE FOR BYTE. ***
                    # *For an insertion rod that meaneth the replacement is present
                    # once and the anchor gone; for an OMISSION rod (empty
                    # replacement) it meaneth the anchor is gone and the file is
                    # exactly the mutant target -- an "the empty string appears
                    # once" test would be vacuous.*
                    if mt == open(target, encoding="utf-8").read():
                        break
                    subprocess.run([sys.executable, "scripts/sync_ios_foundation_package.py"],
                                   cwd=wt_path, capture_output=True, timeout=300, check=True)
                else:
                    raise AssertionError("the mutation never reached the mirrored package: " + mir)
            # 3. run the witnesses against the mutant
            try:
                mutant = _run_harness(entry, wt_path)
            except subprocess.TimeoutExpired:
                tally["TIMEOUT"] += 1
                rows.append(_mrow(entry, head, "semantic", anchor_count, None,
                                [entry["witness"]], None, "TIMEOUT",
                                "the harness did not settle inside the bound", None))
                print("  TIMEOUT  %s" % entry["id"])
                continue
            # *** 4. RESTORE THE TREE AND RUN THE ROSTER ONCE MORE. ***
            #
            # *A kill is only attributable if the SAME roster passeth on the
            # restored tree: without this phase, a witness that failed for a
            # reason that has nothing to do with the mutation -- a flaky arm,
            # a dirty mirror, a wedged device -- is recorded as a catch.* **So
            # the restore is EXECUTED, not asserted, and a row without it is
            # INCOMPLETE rather than KILLED.**
            open(target, "w", encoding="utf-8").write(text)
            if sync_needed:
                subprocess.run([sys.executable, "scripts/sync_ios_foundation_package.py"],
                               cwd=wt_path, capture_output=True, timeout=300, check=True)
            try:
                restr = _run_harness(entry, wt_path)
                restored_green = {
                    "ok": (restr["build_exit"] == 0 and restr["run"] not in (None, 0)
                           and not restr["failed"] and not restr["skipped"]),
                    "run": restr["run"], "skipped": restr["skipped"],
                    "failed": sorted(restr["failed"])}
                restored_blob = restr["blob"]
            except subprocess.TimeoutExpired:
                restored_green = {"ok": False, "run": None, "skipped": None,
                                  "failed": [], "note": "the restored-green rerun timed out"}
                restored_blob = "(the restored-green rerun did not settle inside the bound)"
            outcome, note = _classify(entry, mutant["build_exit"], mutant["run"],
                                      mutant["failed"], baseline_ok, anchor_count,
                                      mutant["skipped"], restored_green)
            # *** WHICH INSTRUMENT DID THE KILLING: `compiler` OR `witness`. ***
            # *A type-enforcement rod is killed by the compiler refusing the mutant
            # (build_exit != 0); every other kill is the named witness failing. The
            # two are recorded so a reader can see the compiler carried the kill
            # rather than having to infer it from a green test log.*
            kill_channel = ("compiler" if (outcome == "KILLED" and mutant["build_exit"] != 0)
                            else ("witness" if outcome == "KILLED" else None))
            tally[outcome] += 1
            entry["ended_utc"] = _now_utc()
            log_path = None
            if emit_dir:
                # *** THE COMPLETE BLOBS, NEVER A TRUNCATION. *** *The old runner
                # kept `blob0[-4000:]` and `blob[-12000:]`, so a rod whose
                # evidence lived earlier in its own log had nothing to re-read
                # and the retained artifact could not settle a dispute about the
                # run. THREE PHASES, THREE FULL LOGS, EACH WITH ITS OWN DIGEST.*
                log_dir = os.path.join(emit_dir, "logs")
                os.makedirs(log_dir, exist_ok=True)
                for phase, payload in (("baseline", base["blob"]),
                                       ("mutant", mutant["blob"]),
                                       ("restored", restored_blob)):
                    open(os.path.join(log_dir, entry["id"] + "." + phase + ".log"),
                         "w", encoding="utf-8").write(payload)
                log_path = os.path.join(log_dir, entry["id"] + ".mutant.log")
            rows.append(_mrow(entry, head, "semantic", anchor_count, mutant["build_exit"],
                            [entry["witness"]], mutant["run"], outcome, note, log_path,
                            restored_green=restored_green, kill_channel=kill_channel))
            print("  %-14s %-34s run=%s skipped=%s failed=%d restored_green=%s :: %s"
                  % (outcome, entry["id"], mutant["run"], mutant["skipped"],
                     len(mutant["failed"]), restored_green.get("ok"), note[:120]))
        except Exception as exc:  # noqa: BLE001 - NO ROD MAY BE LOST TO AN EXCEPTION
            # *** THE CATCH-ALL THAT MAKES A PARTIAL CAMPAIGN VISIBLE. ***
            #
            # *An exception anywhere in the per-rod body -- an anchor assert, a worktree failure, a mirror sync error --
            # used to escape this loop entirely, so the row for this rod was simply ABSENT from the manifest. **A
            # manifest with an omitted rod reads as a campaign with fewer rods, not as a campaign that crashed, and the
            # rods it DID carry are all KILLED.** So the failure is recorded as an explicit row with the exception's
            # type and text, and the tally carrieth it.*
            tally["EXEC_INVALID"] += 1
            rows.append(_mrow(entry, head, "semantic", 0, None, [entry.get("witness")], None,
                             "EXEC_INVALID",
                             f"the rod body raised {type(exc).__name__}: {exc}", None))
            print("  EXEC_INVALID  %s :: %s" % (entry["id"], exc))
        finally:
            _worktree_remove(wt_path)
    print("  per outcome: " + ", ".join("%s=%d" % (k, tally[k]) for k in
          ("KILLED", "SKIPPED", "BUILD_INVALID", "EXEC_INVALID", "BASELINE_INVALID",
           "INCOMPLETE", "TIMEOUT", "ESCAPED")))
    if emit_dir:
        os.makedirs(emit_dir, exist_ok=True)
        # *** THE MANIFEST CARRIETH A SCHEMA, THE SELECTED SET, THE FULL SOURCE COMMIT, THE TESTED-INPUT DIGEST MAP AND
        # THE TOOLCHAIN -- SO A CAMPAIGN ROW CAN BE BOUND TO THE BYTES IT RAN AGAINST. ***
        #
        # *A BARE LIST OF ROWS IS NOT EVIDENCE OF A CAMPAIGN: it sayeth which rods ran and nothing about WHICH TREE,
        # WHICH INPUTS or WHICH TOOLCHAIN produced them. So the rows travel inside an envelope, and the envelope's
        # `required_ids`/`selected_ids` make the difference between "the whole Board 1 group passed" and "a subset
        # passed" READABLE FROM THE ARTIFACT rather than from the command line a reader never saw.*
        env = {
            "schema": 1,
            "lineage": "semantic",
            "baseline_sha": head,
            # *** THE EXACT CANDIDATE IDENTITY: THE COMMIT **AND** THE TREE IT
            # RESOLVED TO. *** *A commit can be re-pointed by a tag and a tree
            # alone does not name a commit, so BOTH travel -- and both can be
            # re-derived read-only (`git rev-parse <sha>^{tree}`) so a validator
            # need not trust either field's shape.*
            "tested_tree_sha": _tested_tree_sha(),
            "group": group,
            "required_ids": list(BOARD1_REQUIRED_IDS) if group == "board1" else [],
            "selected_ids": [s["id"] for s in selected],
            "unselected_ids": [s["id"] for s in SEMANTIC if s not in selected],
            "inputs": _tested_input_digests(),
            "toolchain": _toolchain_probe(),
            "generated_utc": _now_utc(),
            # *** THE PATHS IN `rows` ARE RELATIVE TO THIS ROOT. *** *A reader
            # resolves them against wherever the downloaded artifact landed,
            # so the same evidence is re-readable off the machine that ran it.*
            "campaign_root": ".",
            "rows": rows,
        }
        open(os.path.join(emit_dir, "manifest.json"), "w", encoding="utf-8").write(
            json.dumps(env, indent=1) + "\n")
    bad = [r["id"] for r in rows if r["outcome"] != "KILLED"]
    if bad and not report_only:
        print("::error::semantic controls not killed: " + ", ".join(bad), file=sys.stderr)
        return 1
    return 0


def run(report_only):
    """T61 verification-repair: the pre-reform face that ci/integration.py's
    --selftest delegate still expecteth. The baseline carried
    `def run(report_only: bool) -> int` (the MUTATIONS negative-control walk);
    T20's two-lineage reform (fc93abc) divided the ledger into
    run_structural/run_semantic and the old single entry point perished with
    it, leaving integration --selftest crying AttributeError. The structural
    lineage is its faithful modern counterpart: the ledger's anchors,
    categories and evidence invariants, judged without touching the live
    tree. The semantic lineage remaineth the heavy negative control, run by
    the campaigns alone."""
    return run_structural(report_only, None, "live-tree")


# ---------------------------------------------------------------------------
# T67 -- THE HARNESS'S OWN SELFTEST.
#
# Every rod is judged by `_classify_with`, and a judge that cannot be WRONG cannot
# be TRUSTED. So this selftest carrieth:
#
#   * a KNOWN-ANSWER table: seven scenarios, each with the verdict the honest rules
#     must return (a missing anchor, a DUPLICATE anchor, a compile failure, a
#     timeout, a surviving semantic mutant, a crashed worker, and a baseline that
#     did not pass);
#   * BROKEN POLICIES, each of which must be CAUGHT by at least one known-answer
#     case -- the named negative is `skipped_is_killed`, where a harness that
#     counted a MOVED ANCHOR as a kill must fail;
#   * a LIVE-TREE control: a disposable worktree is created and removed, and the
#     live tree's HEAD and status are compared before and after, so "mutants run
#     only in disposable worktrees" is EXECUTED rather than asserted.
#
# It returneth 0 iff every known-answer case matched under the honest rules AND
# every broken policy was caught. A harness that passeth this cannot count a
# skipped rod as a catch.
# ---------------------------------------------------------------------------

#: (scenario, anchor_count, build_exit, run, failed, baseline_ok, skipped,
#:  restored_green, expected). The restored-green companion is present wherever a
#: KILL is expected -- *a kill without its restoration is INCOMPLETE, and the
#: table proves the runner knows the difference.*
_GREEN = {"ok": True, "run": 12, "skipped": 0, "failed": []}
KNOWN_ANSWER_CASES = (
    ("a missing anchor (the needle moved)", 0, 0, 12, set(), True, 0, _GREEN, "SKIPPED"),
    ("a DUPLICATE anchor (seen twice)", 2, 0, 12, set(), True, 0, _GREEN, "SKIPPED"),
    ("a compile failure", 1, 1, None, set(), True, 0, _GREEN, "BUILD_INVALID"),
    # a compile failure WITH test output: the ONLY rule that can refuse this is the
    # build rule, so the table can SEE that rule fall asleep (the first form of this
    # table could not, and the selftest reported its own blind spot)
    ("a compile failure despite test output", 1, 1, 12, {"the_named_witness"}, True, 0,
     _GREEN, "BUILD_INVALID"),
    ("a baseline that did not pass", 1, 0, 12, set(), False, 0, _GREEN,
     "BASELINE_INVALID"),
    ("a worker that executed nothing", 1, 0, None, set(), True, 0, _GREEN,
     "EXEC_INVALID"),
    ("a roster answered by SKIPS", 1, 0, 12, set(), True, 3, _GREEN, "EXEC_INVALID"),
    # *** A SKIPPED ROSTER MUST OUTRANK A WITNESS HIT: a case may not be "killed" by a
    # run that skipped the very arms it counted. ***
    ("a skipped roster that also reports a hit", 1, 0, 12, {"the_named_witness"}, True, 1,
     _GREEN, "EXEC_INVALID"),
    ("a surviving semantic mutant", 1, 0, 12, set(), True, 0, _GREEN, "ESCAPED"),
    ("the named witness killed, restored green", 1, 0, 12, {"the_named_witness"}, True, 0,
     _GREEN, "KILLED"),
    # *** THE RESTORATION IS MANDATORY: a hit without a restored-green companion is
    # INCOMPLETE -- *the verdict that stops a flaky failure from being booked as a catch.*
    ("a hit whose restored-green never executed", 1, 0, 12, {"the_named_witness"}, True, 0,
     None, "INCOMPLETE"),
    ("a hit whose restored-green did not pass", 1, 0, 12, {"the_named_witness"}, True, 0,
     {"ok": False, "run": 12, "skipped": 0, "failed": ["the_named_witness"]}, "INCOMPLETE"),
    ("a TIMEOUT (no harness output at all)", 1, 0, None, set(), True, 0, _GREEN,
     "EXEC_INVALID"),
)

#: The broken policies, each of which the known-answer table MUST catch.
BROKEN_POLICIES = (
    ("skipped counted as KILLED (the named negative)", ClassifyPolicy(skipped_is_killed=True)),
    ("an escaped mutant counted as KILLED", ClassifyPolicy(escaped_is_killed=True)),
    ("an invalid run counted as KILLED", ClassifyPolicy(invalid_is_killed=True)),
    ("a baseline failure left unchecked", ClassifyPolicy(require_baseline=False)),
    ("a compile failure left unchecked", ClassifyPolicy(require_build=False)),
    ("a run that executed nothing left unchecked", ClassifyPolicy(require_run=False)),
    # *** THE RESTORATION LEFT UNCHECKED: *this is the policy that would book a flaky
    # witness failure as a kill, and it must be visible to the table.* ***
    ("the restored-green companion left unchecked", ClassifyPolicy(require_restored=False)),
    ("the anchor count left unchecked", ClassifyPolicy(require_anchor=False)),
)


def _selftest_entry():
    return {"id": "selftest", "witness": "the_named_witness", "file": "x", "find": "a",
            "replace": "b"}


def classify_selftest():
    """The known-answer table under ONE policy. Returneth (mismatches, checks)."""
    entry = _selftest_entry()
    mismatches = []
    checks = 0
    for (scenario, anchors, build_exit, run, failed, baseline_ok, skipped,
         restored_green, expected) in KNOWN_ANSWER_CASES:
        verdict, _note = _classify_with(DEFAULT_POLICY, entry, build_exit, run, failed,
                                        baseline_ok, anchors, skipped, restored_green)
        checks += 1
        if verdict != expected:
            mismatches.append("%s: expected %s, got %s" % (scenario, expected, verdict))
    return mismatches, checks


# *** NO STALE FIXED DIRECTORY. *** *The board1 campaign used to be validated
# from a hard-coded `docs/remediation/evidence/board1-rc11-rods` path, so a
# terminal run that emitted a FRESH campaign under `$RUNNER_TEMP` was never the
# thing the gate judged -- the gate blessed a stale committed artifact while the
# run it was supposed to prove went unexamined.* **SO THE CAMPAIGN DIR IS NOW
# EXPLICIT: named on `--manifest-dir`, or through the environment, and a run with
# NO dir is REFUSED BY NAME rather than silently falling back to a tracked path.**
#
# *THE HISTORICAL rc11 EVIDENCE IS PRESERVED, NOT DELETED: a reader may still
# point `--manifest-dir` at it, and its bytes are untouched. What changed is that
# the DEFAULT no longer resolves there -- the campaign a gate validates must be the
# campaign the run just produced.*
MANIFEST_DIR_ENV = "GODSTONE_BOARD1_CAMPAIGN_DIR"
#: Retained for callers that import the historical location for READ-ONLY
#: reference (evidence preservation). It is NEVER used as a validation default.
MANIFEST_DIR_HISTORICAL = os.path.join(ROOT, "docs", "remediation", "evidence", "board1-rc11-rods")


def resolve_campaign_dir(manifest_dir=None):
    """The explicit campaign directory, or a NAMED refusal -- never a stale default.

    Resolution order: the `--manifest-dir` argument, then `$GODSTONE_BOARD1_CAMPAIGN_DIR`.
    A RELATIVE path is resolved against the CURRENT WORKING DIRECTORY (not the
    repository), so the same command works from a downloaded artifact root. *An
    unset dir is REFUSED rather than quietly pointing at the committed rc11
    evidence -- the "a stale artifact is not a pass" rule, applied to the path.*
    """
    chosen = manifest_dir or os.environ.get(MANIFEST_DIR_ENV)
    if not chosen:
        raise SystemExit(
            "::error::no campaign directory named -- pass `--manifest-dir DIR` (or set "
            f"${MANIFEST_DIR_ENV}). A campaign manifest is validated WHERE THE RUN WROTE IT; "
            "there is no default because a stale committed evidence directory is not the campaign "
            "the gate existeth to prove.")
    return os.path.abspath(chosen)


def _campaign_row_problems(env, required_ids, baseline, expected_tree, campaign_dir):
    """The per-row hostile controls, each refusal BY NAME.

    *** A ROW IS NOT EVIDENCE BY BEING PRESENT: it must carry its own restoration,
    its own phase-log digests, and the same candidate the envelope names. ***
    """
    problems: list[str] = []
    rows_raw = env.get("rows") or []
    # *** DUPLICATE ROD: two rows for one id is an ambiguous population -- one of
    # them a KILLED, the other not -- and a reader cannot tell which ran. ***
    seen: dict[str, int] = {}
    for r in rows_raw:
        rid = r.get("id")
        seen[rid] = seen.get(rid, 0) + 1
    duplicated = sorted(i for i, n in seen.items() if n > 1)
    if duplicated:
        problems.append(f"the manifest carrieth DUPLICATE row(s) for id(s): {duplicated[:6]} -- a duplicated rod is "
                        f"an ambiguous population, never a pass")
    rows = {r.get("id"): r for r in rows_raw}
    known = {s["id"]: s for s in SEMANTIC}
    ledger = known
    unknown = sorted(set(rows) - set(ledger))
    if unknown:
        problems.append(f"the manifest carrieth row(s) for id(s) the ledger does NOT know: {unknown[:6]} -- a renamed "
                        f"rod leaves the required id unrun while a stranger fills its place")
    for rid in required_ids:
        r = rows.get(rid)
        if r is None:
            problems.append(f"required rod {rid} has NO row in the manifest")
            continue
        # *** A REQUIRED ROD MUST BE KILLED **AND** RECORDED UNDER THE CATEGORY THE
        # LEDGER DECLARES FOR IT. *** *The expected category is read from the rod's
        # own `guard_only` flag, so a STRUCTURAL guard may not be counted among the
        # semantic population and a SEMANTIC rod may not be filed as structural to
        # escape the behavioural-KILLED requirement.*
        spec = ledger.get(rid) or {}
        expected_category = spec.get("category_expect") or (
            ["structural"] if spec.get("guard_only") else ["semantic"])
        if r.get("category") not in expected_category:
            problems.append(f"rod {rid} is recorded category {r.get('category')!r}, but the ledger declares it "
                            f"{expected_category} -- a rod must be counted under the population it belongs to")
        if r.get("outcome") != "KILLED":
            problems.append(f"required rod {rid} is {r.get('outcome')!r}, not KILLED")
        if r.get("baseline_sha") != baseline:
            problems.append(f"rod {rid} carries baseline_sha {r.get('baseline_sha')} != the manifest's {baseline}")
        if r.get("tested_tree_sha") not in (None, expected_tree):
            problems.append(f"rod {rid} carries tested_tree_sha {r.get('tested_tree_sha')} != the envelope's "
                            f"{expected_tree}")
        rg = r.get("restored_green")
        if not (isinstance(rg, dict) and rg.get("ok")):
            problems.append(f"rod {rid} has no GREEN restored-green companion -- a kill without its restoration is "
                            f"not provable")
        # *** THE THREE PHASE LOGS, EACH PRESENT, PORTABLE AND DIGEST-CHECKED. ***
        phases = r.get("phase_logs")
        if not isinstance(phases, dict):
            problems.append(f"rod {rid} carrieth NO phase_logs -- the baseline/mutant/restored blobs are the kill's "
                            f"evidence and cannot be asserted away")
            continue
        for ph in ("baseline", "mutant", "restored"):
            rec = phases.get(ph)
            if not isinstance(rec, dict) or not rec.get("sha256"):
                problems.append(f"rod {rid}: phase log {ph!r} is absent or carries no digest")
                continue
            try:
                resolved = _resolve_campaign_path(rec.get("path"), campaign_dir)
            except ValueError as exc:
                problems.append(f"rod {rid}: phase log {ph!r} path is not portable: {exc}")
                continue
            if not os.path.isfile(resolved):
                problems.append(f"rod {rid}: phase log {ph!r} ({rec.get('path')!r}) is NOT PRESENT under the "
                                f"campaign root")
            elif _sha_file(resolved) != rec.get("sha256"):
                problems.append(f"rod {rid}: phase log {ph!r} does not recompute its digest -- the blob was edited "
                                f"after it was bound")
    return problems


def validate_campaign_manifest(manifest_dir=None, group="board1") -> int:
    """*** `board1 verify` GATE: PROVE A CAMPAIGN RAN, NOT MERELY THAT THE HARNESS DECIDETH. ***

    *THE DEFECT THIS CLOSES: `board1 verify` ran `ci/mutations.py --selftest` and nothing else -- **so it passed while
    the last real campaign, the one whose KILLED rows the closure cites, had never run against this tree.*** *The
    selftest proveth the CLASSIFIER; this proveth the CAMPAIGN.*

    It refuseth, BY NAME:
      * an UNNAMED campaign dir (no stale default) or an ABSENT manifest;
      * a manifest whose `group` is not the required one, or whose `required_ids` differ from the source set;
      * any required id missing, or not KILLED, or without its restored-green companion;
      * a DUPLICATE or RENAMED/unknown rod row (an ambiguous or shifted population);
      * any row whose candidate (`baseline_sha` / `tested_tree_sha`) disagrees with the envelope's;
      * any phase log that is missing, whose digest does not recompute, or whose path ESCAPES the campaign root;
      * a `selected_ids` set that omits a required id (a narrowed campaign that still passed);
      * a manifest whose `inputs` do not match the tree's (a campaign against other bytes);
      * a manifest whose recorded tested tree is not the tree of the bound head (a source change after the run).
    """
    campaign_dir = resolve_campaign_dir(manifest_dir)
    path = os.path.join(campaign_dir, "manifest.json")
    if not os.path.isfile(path):
        print(f"::error::no campaign manifest at {path} -- an unrun campaign is not a pass; run "
              f"`ci/mutations.py --semantic --group {group} --baseline <SHA> --emit-dir {campaign_dir}`",
              file=sys.stderr)
        return 1
    try:
        env = json.load(open(path, encoding="utf-8"))
    except ValueError as exc:
        print(f"::error::the campaign manifest is not valid JSON: {exc}", file=sys.stderr)
        return 1
    problems: list[str] = []
    if not isinstance(env, dict) or "rows" not in env:
        print(f"::error::the campaign manifest at {path} is a bare row list with NO envelope -- it bindeth no source "
              f"commit, no tested inputs and no selected set", file=sys.stderr)
        return 1
    if env.get("lineage") != "semantic":
        problems.append(f"the manifest's lineage is {env.get('lineage')!r}, not 'semantic'")
    required_ids = list(BOARD1_REQUIRED_IDS) if group == "board1" else []
    baseline = env.get("baseline_sha")
    if not baseline:
        problems.append("campaign.baseline_sha is absent -- a campaign bound to no commit proves nothing")
    # *** THE EXACT CANDIDATE: the commit AND the tree. *** *A commit's tree is
    # re-derived READ-ONLY from git rather than trusted from the field's shape,
    # and the envelope's recorded tree must be the one that commit resolves to --
    # so a manifest written against other bytes than the commit it names is
    # refused even when every field is well-formed.*
    expected_tree = env.get("tested_tree_sha")
    derived_tree = None
    if baseline:
        proc = subprocess.run(["git", "rev-parse", f"{baseline}^{{tree}}"], cwd=ROOT,
                              capture_output=True, text=True)
        if proc.returncode != 0:
            problems.append(f"campaign.baseline_sha {baseline!r} does not resolve to a commit in this repository")
        else:
            derived_tree = proc.stdout.strip()
            if expected_tree and expected_tree != derived_tree:
                problems.append(f"campaign.tested_tree_sha {expected_tree} does not match the tree {derived_tree} "
                                f"that baseline {baseline} resolves to -- the manifest names bytes its commit never had")
    if not expected_tree:
        problems.append("campaign.tested_tree_sha is absent -- a campaign that names no tree is an unfalsifiable binding")
    if group == "board1":
        required = set(BOARD1_REQUIRED_IDS)
        if set(env.get("required_ids") or []) != required:
            problems.append(f"the manifest's required_ids differ from the source set: missing "
                            f"{sorted(required - set(env.get('required_ids') or []))}, extra "
                            f"{sorted(set(env.get('required_ids') or []) - required)}")
        selected = set(env.get("selected_ids") or [])
        omitted = sorted(required - selected)
        if omitted:
            problems.append(f"the campaign OMITTED {len(omitted)} required id(s) from its selection: {omitted[:6]}")
    problems.extend(_campaign_row_problems(env, required_ids, baseline, derived_tree or expected_tree, campaign_dir))
    # tested-input equality: the campaign ran against THESE bytes
    current = _tested_input_digests()
    recorded = env.get("inputs") or {}
    if not recorded:
        problems.append("the manifest binds NO tested-input digests -- a campaign that bound no input family is a "
                        "claim about nothing in particular")
    for key in sorted(set(recorded) | set(current)):
        val = recorded.get(key)
        if key not in recorded:
            problems.append(f"the manifest omits input family {key!r} (the tree derives one)")
        elif key not in current:
            problems.append(f"the manifest binds input family {key!r} that no longer exists")
        elif current[key] != val:
            problems.append(f"input family {key!r} has MOVED since the campaign: manifest {str(val)[:16]}… != tree "
                            f"{str(current[key])[:16]}… -- the campaign ran against other bytes")
    # *** STRUCTURAL AND SEMANTIC COUNTS ARE REPORTED SEPARATELY, NEVER SUMMED. ***
    rows_all = env.get("rows") or []
    semantic_rows = [r for r in rows_all if r.get("category") == "semantic"]
    structural_rows = [r for r in rows_all if r.get("category") == "structural"]
    if problems:
        for p in problems:
            print(f"::error::{p}", file=sys.stderr)
        return 1
    print(f"campaign manifest OK: group={env.get('group')}, {len(semantic_rows)} semantic row(s) "
          f"({len(required_ids)} required, all KILLED with restorations) and {len(structural_rows)} structural row(s) "
          f"reported SEPARATELY, phase logs digest-checked and portable under {campaign_dir}, inputs match the tree, "
          f"candidate {str(baseline)[:12]}… tree {str(derived_tree or expected_tree)[:12]}…")
    return 0


def run_selftest(emit=None):
    """Prove the harness decideth. Returneth 0 iff every control behaved."""
    ok = True
    print("MUTATION HARNESS SELFTEST (T67)")
    print("  ONLY KILLED is a catch; every other verdict is not.")

    # (1) the honest rules against the known-answer table
    mismatches, checks = classify_selftest()
    if mismatches:
        ok = False
        print("  FAIL the honest rules misclassified:")
        for m in mismatches:
            print("       " + m)
    else:
        print("  PASS the honest rules classified %d known-answer cases correctly" % checks)

    # (1b) *** THE PARSE LAYER IS EXERCISED AGAINST REAL XCTEST TEXT, NOT ONLY AGAINST PRE-PARSED `run=`. ***
    #
    # *THE DEFECT THIS CLOSES, MEASURED: `EXEC_RE` demanded the PLURAL "failures", but XCTest printeth "with 1
    # failure" for a SINGLE failed case -- so the IDEAL mutation (one named witness reddened) parsed to `run=None` and
    # was reported `EXEC_INVALID`, a FALSE NON-CATCH ON A REAL CATCH.* **The known-answer table above could not see
    # this, because it hands `_classify_with` an already-parsed `run`: the bug lived in the extraction, one layer
    # BELOW the classifier the table testeth.** *So the extraction is measured directly here, on the very strings
    # XCTest emit.*
    _PARSE_CASES = (
        # (real XCTest line fragment, expected run, expected failure count)
        ("\t Executed 13 tests, with 1 failure (0 unexpected) in 0.224 (0.224) seconds", 13, 1),
        ("\t Executed 13 tests, with 0 failures (0 unexpected) in 0.002 (0.002) seconds", 13, 0),
        ("\t Executed 7 tests, with 3 failures (0 unexpected) in 1.0 (1.0) seconds", 7, 3),
        ("\t Executed 1 test, with 1 failure (0 unexpected) in 0.1 (0.1) seconds", 1, 1),
        # *** THE SKIPPED INFIX: a whole class green WITH one honest skip -- measured on ReadinessT30Tests, whose
        # pinned-library arm is EXTERNAL-BLOCKED. A pattern blind to the infix booked it BASELINE_INVALID. ***
        ("\t Executed 22 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.017 (0.017) seconds", 22, 0),
        ("\t Executed 7 tests, with 2 tests skipped and 1 failure (0 unexpected) in 0.2 (0.2) seconds", 7, 1),
    )
    parse_bad = []
    for text, want_run, want_fail in _PARSE_CASES:
        m = EXEC_RE.search(text)
        got = (int(m.group(1)), int(m.group(2))) if m else (None, None)
        if got != (want_run, want_fail):
            parse_bad.append("  %r -> %s, wanted (%d, %d)" % (text.strip(), got, want_run, want_fail))
    # and the FAILED-case extractor must read the SINGULAR case line the singular count announces
    _failed_line = "Test Case '-[GodstoneMeshTests.ReadinessT56Tests testW09AStaleConfirmationPromotethNothing]' failed (0.212 seconds)."
    if FAILED_CASE_RE.findall(_failed_line) != ["testW09AStaleConfirmationPromotethNothing"]:
        parse_bad.append("  the singular failed-case line did not yield its witness: %r" % _failed_line)
    if parse_bad:
        ok = False
        print("  FAIL the extraction mis-parsed real XCTest text:")
        for line in parse_bad:
            print("       " + line)
    else:
        print("  PASS the extraction parsed %d real XCTest line(s) incl. the SINGULAR '1 failure'"
              % len(_PARSE_CASES))

    # (2) every broken policy must be CAUGHT by that same table
    for name, policy in BROKEN_POLICIES:
        entry = _selftest_entry()
        caught = False
        detail = ""
        for (scenario, anchors, build_exit, run, failed, baseline_ok, skipped,
             restored_green, expected) in KNOWN_ANSWER_CASES:
            verdict, _note = _classify_with(policy, entry, build_exit, run, failed,
                                            baseline_ok, anchors, skipped, restored_green)
            if verdict != expected:
                caught = True
                detail = "%s: %s -> %s" % (scenario, expected, verdict)
                break
        if caught:
            print("  KILLED   %s (%s)" % (name, detail))
        else:
            ok = False
            print("  ESCAPED  %s -- the selftest cannot see this breakage" % name)

    # (3) the DISPOSABLE WORKTREE control, EXECUTED: the live tree is untouched
    try:
        head_before = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                     capture_output=True, text=True).stdout.strip()
        status_before = subprocess.run(["git", "status", "--porcelain=v1"], cwd=ROOT,
                                      capture_output=True, text=True).stdout
        parent = tempfile.mkdtemp(prefix="godstone-selftest-wt-")
        wt = os.path.join(parent, "probe")
        _worktree_add(head_before, wt)
        inside = os.path.isfile(os.path.join(wt, "ci", "mutations.py"))
        _worktree_remove(wt)
        gone = not os.path.exists(wt)
        head_after = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                    capture_output=True, text=True).stdout.strip()
        status_after = subprocess.run(["git", "status", "--porcelain=v1"], cwd=ROOT,
                                     capture_output=True, text=True).stdout
        shutil.rmtree(parent, ignore_errors=True)
        if inside and gone and head_before == head_after and status_before == status_after:
            print("  PASS a disposable worktree was created, used and REMOVED, and the "
                  "live tree's HEAD and status are unchanged")
        else:
            ok = False
            print("  FAIL the disposable-worktree control: created=%s removed=%s "
                  "head_same=%s status_same=%s"
                  % (inside, gone, head_before == head_after, status_before == status_after))
    except Exception as exc:                      # a control that cannot run is a FAILURE
        ok = False
        print("  FAIL the disposable-worktree control raised: %s" % exc)

    # (4) the tally rule: a non-KILLED rod must never be counted as a catch
    sample = [{"id": "a", "outcome": "KILLED"}, {"id": "b", "outcome": "SKIPPED"},
              {"id": "c", "outcome": "ESCAPED"}, {"id": "d", "outcome": "EXEC_INVALID"},
              {"id": "e", "outcome": "BUILD_INVALID"},
              {"id": "f", "outcome": "INCOMPLETE"}]
    cats = [r["id"] for r in sample if r["outcome"] != "KILLED"]
    if cats == ["b", "c", "d", "e", "f"]:
        print("  PASS only KILLED counteth: SKIPPED, ESCAPED, EXEC_INVALID, "
              "BUILD_INVALID and INCOMPLETE are all refused as catches")
    else:
        ok = False
        print("  FAIL the tally rule: %r" % (cats,))

    # (5) the documented EXPECTED escape is never counted as success
    if not EXPECTED_ESCAPES:
        print("  PASS no rod is documented as an expected escape, so none can be "
              "counted as a success")
    else:
        for mid in EXPECTED_ESCAPES:
            print("  NOTE %s is documented as an EXPECTED escape and is NOT a catch"
                  % mid)

    print("SELFTEST %s" % ("OK" if ok else "FAILED"))
    if emit:
        with open(emit, "w", encoding="utf-8") as stream:
            stream.write("ok=%s checks=%d\n" % (ok, checks))
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true",
                    help="prove the harness's own classifier and worktree discipline")
    ap.add_argument("--selftest-manifest", action="store_true",
                    help="prove a real CAMPAIGN ran: validate the board1 campaign manifest (required ids all KILLED "
                         "with restorations, phase hashes, tested-input equality). Requires --manifest-dir.")
    ap.add_argument("--manifest-dir", default=None,
                    help="with --selftest-manifest: the campaign's emit-dir, EXPLICIT (no stale default; also reads "
                         f"${MANIFEST_DIR_ENV}); a relative path resolves against the current directory so a "
                         "downloaded campaign is re-readable under any root")
    ap.add_argument("--report", action="store_true", help="do not fail on findings")
    ap.add_argument("--semantic", action="store_true", help="run the semantic lineage")
    ap.add_argument("--id", action="append", default=None,
                    help="run only this rod id (repeatable); unselected rows are untouched")
    ap.add_argument("--group", default=None,
                    help="run a NAMED required-id set from the source (`board1`); an id in the group that the "
                         "ledger does not carry is refused rather than skipped")
    ap.add_argument("--all", action="store_true", help="run both lineages")
    ap.add_argument("--emit-dir", default=None, help="write logs/ (and the semantic manifest) here")
    ap.add_argument("--baseline", default=None, help="pin the audited head sha for the run")
    ap.add_argument("--work-parent", default=os.path.join(
        os.path.expanduser("~"), ".cache", "godstone-mutation-worktrees"),
        help="parent directory for the disposable worktrees")
    a = ap.parse_args(argv)
    if a.selftest:
        return run_selftest()
    if a.selftest_manifest:
        return validate_campaign_manifest(a.manifest_dir, a.group or "board1")
    rc = 0
    if a.all or not a.semantic:
        rc |= run_structural(a.report, a.emit_dir, a.baseline or "live-tree")
    if a.semantic or a.all:
        os.makedirs(a.work_parent, exist_ok=True)
        rc |= run_semantic(a.report, a.emit_dir, a.baseline, a.work_parent, a.id, a.group)
    print("NO AGGREGATE: the two lineages are never summed; no run of this "
          "script may be quoted as a single killed percentage.")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
