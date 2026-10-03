#!/usr/bin/env python3
"""*** THE ONE CANONICAL BOARD 1 INTERNAL GATE DEFINITION, AND THE CANDIDATE-BOUND MANIFEST IT EMITS. ***

*THIS FILE OWNS ONE THING, AND EVERY OTHER ROAD IMPORTS IT RATHER THAN COPYING IT:*

    **THE REQUIRED INTERNAL GATE SET (`GATE_DEFINITIONS`), THE MANIFEST SCHEMA, THE BUILDER AND THE VALIDATOR.**

*THE DEFECT THIS CLOSES.* *Before this file, `tools/readiness/board1.py` carried the gate list as a private literal
and printed ONE verdict; nothing recorded WHICH gates ran, with WHICH argv, WHAT exit code, WHICH log, or WHAT the
campaign/lane/closure populations were. A verdict line is not evidence: a reader could not tell a full run from a
subset, a fresh run from a stale one, or a candidate-bound run from a borrowed one.* **So a full run now EMITS a
manifest whose every claim is a digest, a count or an exact identifier, and a validator re-derives all of them.**

*** ONLY A FULL, REQUIRED, ACCOUNTED INTERNAL GATE RUN MAY EMIT A PASS MANIFEST. *** *A subset run, a run with a
missing or unreadable gate log, and a run where a required gate returned non-zero each REFUSE TO EMIT ONE AT ALL --
"no partial success" is enforced by construction, because the builder is only reached after every required gate has
been accounted for and has returned zero.*

## WHAT THE MANIFEST BINDS, AND WHY EACH PART IS NEEDED

  * **candidate**  -- the exact SHA and TREE. *Derived from the annotated tag or the clean work tree, NEVER from a
    self-referential closure field: a commit cannot name itself, and a record that tried would be describing a tree
    it never had.*
  * **clean_start / clean_end** -- the tracked-path dirt at the beginning and the end of the run. *A freeze taken
    outside a clean tree is not the candidate's bytes.*
  * **gates** -- for EVERY required id: the exact argv, the raw exit code, and the full log's path, byte count and
    sha256. *"The suite passed" is not a gate row; `{id, argv, rc, log{path,sha256}}` is.*
  * **campaign** -- the mutation campaign's directory digest, its required/selected population, its row count, the
    tested-input digest map, and the resolved baseline commit. *A campaign manifest that is merely PRESENT proves
    nothing: the population, the inputs and the digests are what make it a claim about THIS tree.*
  * **lanes** -- per lane: its source digest, its pre/post sidecars, its source-derived roster size, its parsed
    counts, and digests for every artifact it produced. *A lane log is evidence only when it is bound to the bytes it
    compiled and the roster it was supposed to run.*
  * **closure / ledger** -- the file digests, the closure status, `verified_fixed`, and the STRUCTURED counts.
    *A closure record whose counts disagree with the derivation is a second, stale representation of the same state.*
  * **external_evidence** -- the external-blocker register, the release-gate status register, the historical evidence
    identities, and the (optional) exact-candidate release-proof records supplied by the supply-chain owner.
    *External claims are recorded by IDENTITY, never inferred green from absence.*

## USAGE

    python3 ci/check_board1_manifest.py --build --gate-dir DIR [--campaign-dir DIR] [--tag T] --out PATH
    python3 tools/readiness/run.py board1 verify [--campaign-dir DIR] --manifest-out PATH
    python3 ci/check_board1_manifest.py --manifest PATH [--json]            # read-only validation
    python3 ci/check_board1_manifest.py --selftest                          # adversarial, deterministic

*A PASS manifest is emitted ONLY by `board1 verify --manifest-out` (a live, in-process gate run) or by
`build_from_gates()`; the `--build --gate-dir` road readeth a directory of downloaded artifact files and can therefore
only DIAGNOSE (it never emits, because caller-created bytes cannot back a PASS).*

EXIT: 0 when every required claim is present, accounted for and re-derived; non-zero with a named refusal otherwise.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / "ci") not in sys.path:
    sys.path.insert(0, str(ROOT / "ci"))

MANIFEST_SCHEMA = 2
MANIFEST_KIND = "board1-gate-manifest"
MANIFEST_PATH_DEFAULT = ROOT / "docs" / "remediation" / "evidence" / "board1-gate-manifest.json"

#: *** THE REQUIRED INTERNAL GATE SET -- ORDERED, NAMED, ONE SOURCE OF TRUTH. ***
#:
#: *`("label", argv)`. The order is the order a reader should run them: the cheap structural checks first, then the
#: lanes, then the campaign that runs harnesses. `label` is the stable id used by `--only`, the manifest's gate rows
#: and the hosted per-gate artifacts; it is NEVER derived from the argv, so renaming a command cannot silently rename
#: a gate.*
CAMPAIGN_DIR_TOKEN = "{campaign_dir}"
PROOF_DIR_TOKEN = "{proof_dir}"
IOS_APP_TOKEN = "{ios_app}"
ANDROID_APK_ROOT_TOKEN = "{android_apk_root}"
ARCHIVE_LIGHT_DB_TOKEN = "{archive_light_db}"
INTEGRATION_REPORT_TOKEN = "{integration_report}"
SDK_TREE_TOKEN = "{sdk_tree}"
SDK_ARCHIVE_TOKEN = "{sdk_archive}"
EVIDENCE_ROOT_TOKEN = "{evidence_root}"

#: *** THE SUBSTITUTION TOKENS, AND THE ENVIRONMENT EACH ONE READS. ***
#:
#: *A gate whose SUBJECT is an artifact the hosted terminal job DOWNLOADS cannot name a repository-relative path: the
#: bytes are not in the checkout, and dropping them into the checkout would make `git status` dirty and the run
#: non-clean. So the contract names a TOKEN, and the runner resolves it from `--<flag>` or the named environment
#: variable. The SUBSTITUTED argv is what the manifest row records, so a reader seeth WHICH directory was judged.*
#:
#: *** AND AN UNRESOLVED TOKEN IS A FAILURE, NEVER A PASS. *** *`argv_problems` refuseth a recorded row that still
#: carrieth a literal token, and the command itself cannot succeed against a path called `{ios_app}` -- so a MISSING
#: actual dataset reddens the gate rather than letting a selftest stand in for the real thing.*
GATE_INPUT_TOKENS: dict[str, tuple[str, ...]] = {
    CAMPAIGN_DIR_TOKEN: ("GODSTONE_BOARD1_CAMPAIGN_DIR",),
    PROOF_DIR_TOKEN: ("GODSTONE_BOARD1_PROOF_DIR", "RUNNER_TEMP"),
    IOS_APP_TOKEN: ("GODSTONE_BOARD1_IOS_APP",),
    ANDROID_APK_ROOT_TOKEN: ("GODSTONE_BOARD1_ANDROID_APK_ROOT",),
    ARCHIVE_LIGHT_DB_TOKEN: ("GODSTONE_BOARD1_ARCHIVE_LIGHT_DB",),
    INTEGRATION_REPORT_TOKEN: ("GODSTONE_BOARD1_INTEGRATION_REPORT",),
    SDK_TREE_TOKEN: ("GODSTONE_BOARD1_SDK_CMDLINE_TOOLS",),
    SDK_ARCHIVE_TOKEN: ("GODSTONE_BOARD1_SDK_ARCHIVE",),
    EVIDENCE_ROOT_TOKEN: ("GODSTONE_BOARD1_EVIDENCE_ROOT",),
}


def resolve_gate_inputs(*, campaign_dir=None, proof_dir=None, ios_app=None, android_apk_root=None,
                        archive_light_db=None, integration_report=None,
                        sdk_tree=None, sdk_archive=None, evidence_root=None, environ: dict | None = None) -> dict[str, str]:
    """*** RESOLVE EVERY GATE INPUT TOKEN, IN ONE PLACE, FROM FLAG-THEN-ENVIRONMENT. ***

    *The declared interface the hosted terminal job filleth: each artifact the terminal job DOWNLOADS is named by a
    `--flag` or its environment variable, and the proof/report root is the runner's own scratch root so no gate output
    ever lands inside the candidate tree.*

    *** AN UNDECLARED ACTUAL INPUT IS LEFT AS ITS OWN TOKEN. *** *Deliberate: the gate then cannot pass, which is the
    honest outcome for a run that never obtained the bytes it pretends to judge. Silence here would be the
    "machinery exists but is not the gate" shape this programme keeps removing.*
    """
    env = os.environ if environ is None else environ
    direct = {CAMPAIGN_DIR_TOKEN: campaign_dir, PROOF_DIR_TOKEN: proof_dir, IOS_APP_TOKEN: ios_app,
              ANDROID_APK_ROOT_TOKEN: android_apk_root, ARCHIVE_LIGHT_DB_TOKEN: archive_light_db,
              INTEGRATION_REPORT_TOKEN: integration_report, SDK_TREE_TOKEN: sdk_tree,
              SDK_ARCHIVE_TOKEN: sdk_archive, EVIDENCE_ROOT_TOKEN: evidence_root}
    resolved: dict[str, str] = {}
    for token, names in GATE_INPUT_TOKENS.items():
        value = direct.get(token)
        if value in (None, ""):
            for name in names:
                value = env.get(name)
                if value:
                    break
        if value not in (None, ""):
            path = Path(value).expanduser()
            resolved[token] = str(path.resolve() if path.is_absolute() else (ROOT / path).resolve())
    return resolved


GATE_DEFINITIONS: list[dict] = [
    {"id": "candidate-binding-selftest",
     "label": "candidate binding selftest",
     "argv": [sys.executable, "ci/check_candidate_binding.py", "--selftest"]},
    {"id": "closure-law",
     "label": "closure law",
     "argv": [sys.executable, "scripts/build_structured_closure.py", "--check"]},
    {"id": "required-runs",
     "label": "required runs",
     "argv": [sys.executable, "ci/check_required_runs.py"]},
    {"id": "evidence-digests",
     "label": "evidence digests",
     "argv": [sys.executable, "ci/check_evidence_digests.py"]},
    {"id": "release-gates-status",
     "label": "release gates status",
     "argv": [sys.executable, "ci/check_release_gates_status.py"]},
    {"id": "blockers",
     "label": "blockers",
     "argv": [sys.executable, "tools/readiness/blockers.py", "--check"]},
    # Lifecycle records reject expected failures, unexpected successes and unaccounted skips.
    {"id": "readiness-suites",
     "label": "readiness suites",
     "argv": [sys.executable, "tools/readiness/check_suite_roster.py", "--run",
              "--log", PROOF_DIR_TOKEN + "/readiness.log",
              "--roster", PROOF_DIR_TOKEN + "/readiness-roster.json"]},
    {"id": "lane-results",
     "label": "lane results",
     "argv": [sys.executable, "ci/check_lane_results.py", "--scope", "all",
              "--evidence-root", EVIDENCE_ROOT_TOKEN]},
    {"id": "mutation-harness-selftest",
     "label": "mutation harness selftest",
     "argv": [sys.executable, "ci/mutations.py", "--selftest"]},
    # *** AND THE CAMPAIGN MANIFEST ITSELF. *** *The selftest above proves the harness DECIDETH; this gate proves a
    # campaign RAN, with the required Board 1 ids all killed, the tested-input digests bound, and the phase rosters
    # equal. `{campaign_dir}` is resolved from `--campaign-dir`, and the checker refuseth an absent or unbound one
    # rather than reading absence as success.*
    {"id": "board1-campaign-manifest",
     "label": "board1 campaign manifest",
     "argv": [sys.executable, "ci/mutations.py", "--selftest-manifest", "--group", "board1",
              "--manifest-dir", CAMPAIGN_DIR_TOKEN]},
    # *** AND THE ARTIFACT INSPECTORS -- THE ACTUAL APK/DEX/AXML AND Mach-O/LINK-CLOSURE CONTENT CONTROLS. ***
    #
    # *THE DEFECT THIS CLOSES: the required set judged the SOURCE and the LANE LOGS but never the BUILT ARTIFACTS. A
    # candidate could pass every source control while shipping an APK carrying a forbidden component or an app binary
    # whose link closure opened a private framework -- the inspectors and their NEGATIVE CONTROLS are the gates that
    # read those bytes, and they were run only inside the workflow's own steps, never accounted for as required
    # gates.*
    {"id": "android-artifact-inspectors",
     "label": "android artifact inspectors (APK/DEX/AXML + negative controls)",
     "argv": [sys.executable, "scripts/inspect_android_artifacts.py", "--selftest"]},
    {"id": "ios-artifact-inspectors",
     "label": "ios artifact inspectors (Mach-O/link closure + negative controls)",
     "argv": [sys.executable, "scripts/inspect_ios_artifacts.py", "--selftest"]},
    {"id": "android-release-inspector",
     "label": "android release inspector (packaged manifest + negative controls)",
     "argv": [sys.executable, "scripts/inspect_android_release.py", "--selftest"]},
    {"id": "android-artifact",
     "label": "actual Android Archive-only artifact",
     "argv": [sys.executable, "scripts/inspect_android_artifacts.py", ANDROID_APK_ROOT_TOKEN,
              PROOF_DIR_TOKEN + "/android-artifact", "--expected-archive", ARCHIVE_LIGHT_DB_TOKEN]},
    {"id": "ios-artifact",
     "label": "actual iOS Archive-only artifact",
     "argv": [sys.executable, "scripts/inspect_ios_artifacts.py", IOS_APP_TOKEN,
              "--entitlements", "ios/Godstone/Godstone.entitlements",
              "--out", PROOF_DIR_TOKEN + "/ios-artifact"]},
    # *** AND THE CROSS-PLATFORM / PROCESS-DEATH INTEGRATION EVIDENCE, JUDGED BY CONTENT. ***
    #
    # *The coordinator PRODUCETH; `ci/check_integration_evidence.py` JUDGETH. Its selftest drives the real gate over
    # its own fixture reports and requires every refusal (missing arm, flipped outcome, swapped digest, copied
    # fixture, missing durable row) to bite -- which is the eight-combination matrix, the verified-death campaign and
    # the durable-query clause the assignment names.*
    {"id": "integration-evidence",
     "label": "integration evidence negative controls",
     "argv": [sys.executable, "ci/check_integration_evidence.py", "--selftest"]},
    {"id": "integration-report",
     "label": "actual cross-platform and process-death integration evidence",
     "argv": [sys.executable, "ci/check_integration_evidence.py",
              "--report", INTEGRATION_REPORT_TOKEN, "--require-mode", "all"]},
    {"id": "sdk-controls",
     "label": "SDK archive and extracted-tree negative controls",
     "argv": [sys.executable, "tools/supplychain/verify_toolchain_download.py", "--selftest"]},
    {"id": "sdk-archive",
     "label": "actual pinned Android SDK bootstrap archive",
     "argv": [sys.executable, "tools/supplychain/verify_toolchain_download.py",
              "--id", "android-commandlinetools-macos", SDK_ARCHIVE_TOKEN]},
    {"id": "sdk-tree",
     "label": "actual pinned Android SDK bootstrap tree",
     "argv": [sys.executable, "tools/supplychain/verify_toolchain_download.py",
              "--id", "android-commandlinetools-macos", "--verify-tree", SDK_TREE_TOKEN]},
    # *** AND THE SUPPLY CHAIN: SDK PINS, THE SBOM AND ITS EXPORTED FACES. ***
    {"id": "supply-chain-verify",
     "label": "supply chain verify --all",
     "argv": [sys.executable, "tools/supplychain/supply_chain.py", "verify", "--all"]},
    {"id": "supply-chain-sbom-export",
     "label": "supply chain sbom export --check",
     "argv": [sys.executable, "tools/supplychain/supply_chain.py", "sbom-export", "--check"]},
    {"id": "evidence-bundle",
     "label": "evidence bundle",
     "argv": [sys.executable, "scripts/build_evidence_bundle.py", "--check"]},
    {"id": "current-assessment",
     "label": "current assessment",
     "argv": [sys.executable, "ci/check_current_assessment.py"]},
    # *** AND THE TWO RELEASE-PROOF CONTROLS: THE OWNER'S OWN VERIFIER AND CAPTURE SELFTESTS. ***
    {"id": "release-proof-selftest",
     "label": "release proof verifier selftest",
     "argv": [sys.executable, "tools/supplychain/verify_release_proof.py", "--selftest"]},
    {"id": "release-capture-selftest",
     "label": "release proof capture selftest",
     "argv": [sys.executable, "tools/supplychain/capture_release_proof.py", "--selftest"]},
    # *** AND THIS CONTRACT'S OWN ADVERSARIAL SELFTEST. *** *Every OTHER gate is a control; this one proves the control
    # that judges them is itself falsifiable -- it runs the manifest contract against a real throwaway repository and
    # requires every refusal to be observed. A contract whose own refusals were never exercised would be the same
    # "machinery exists but is not the gate" shape this programme keeps removing.*
    {"id": "board1-manifest-selftest",
     "label": "board1 manifest selftest",
     "argv": [sys.executable, "ci/check_board1_manifest.py", "--selftest"]},
]

#: *The campaign directory substitution token: the CONTRACT names the token, and a manifest row records the RESOLVED
#: path, so the row says which directory was actually judged.*
REQUIRED_GATE_IDS: tuple[str, ...] = tuple(g["id"] for g in GATE_DEFINITIONS)

#: *** THE REQUIRED LANE POPULATION. *** *Named here so a lane that produced no artifact is a REFUSAL with the lane's
#: name on it, rather than a lane silently absent from a green summary.*
REQUIRED_LANES: tuple[str, ...] = (
    "android:app", "android:core", "android:mesh", "android:labmesh",
    "android:ui", "android:simulator", "android:production",
    "ios:foundation", "ios:ui", "ios:simulator",
)

LANE_SOURCES: dict[str, dict] = {
    "android:app": {"result_glob": "android/app/build/test-results/testLightDebugUnitTest/*.xml",
                    "sidecars": ("android-app.sources.sha256", "android-app.pre.sha256")},
    "android:core": {"result_glob": "android/core/build/test-results/testDebugUnitTest/*.xml",
                     "sidecars": ("android-core.sources.sha256", "android-core.pre.sha256")},
    "android:mesh": {"result_glob": "android/mesh/build/test-results/testDebugUnitTest/*.xml",
                     "sidecars": ("android-mesh.sources.sha256", "android-mesh.pre.sha256")},
    "android:labmesh": {"result_glob": "android/labmesh/build/test-results/testDebugUnitTest/*.xml",
                        "sidecars": ("android-labmesh.sources.sha256", "android-labmesh.pre.sha256")},
    # *** THE THREE REPORT LANES. `tools/readiness/lane_registry.py` IS THE ONE AUTHORITY FOR THEIR SHAPE. ***
    #
    # *These lanes carry their OWN evidence root, report and sidecars (the registry's `verify_lane_report`
    # re-derives every verdict from the copied XML, the child's own status and the digest pair). This table only
    # says WHERE the manifest looks; the selftest arm refuses any field here that drifts from the registry, so the
    # two tables can never disagree silently.*
    "android:ui": {"result_glob": "android-ui-results/*.xml",
                   "sidecars": ("android-ui.sources.sha256", "android-ui.pre.sha256")},
    "android:simulator": {"result_glob": "android-simulator-results/*.xml",
                          "sidecars": ("android-simulator.sources.sha256", "android-simulator.pre.sha256")},
    "android:production": {"result_glob": "android-production-results/*.xml",
                          "sidecars": ("android-production.sources.sha256", "android-production.pre.sha256")},
    "ios:foundation": {"result_glob": "ios-lane.log",
                       "sidecars": ("ios-lane.log.sources.sha256", "ios-lane.log.pre.sha256")},
    "ios:ui": {"result_glob": "ios-ui-lane.log",
               "sidecars": ("ios-ui-lane.log.sources.sha256", "ios-ui-lane.log.pre.sha256")},
    "ios:simulator": {"result_glob": "ios-simulator-lane.log",
                      "sidecars": ("ios-simulator-lane.log.sources.sha256",
                                   "ios-simulator-lane.log.pre.sha256"),
                      "extra": ("ios-simulator-lane.xcresult",)},
}

CAMPAIGN_DIR_DEFAULT = ROOT / "docs" / "remediation" / "evidence" / "board1-rc11-rods"
CLOSURE = ROOT / "docs" / "production-readiness" / "BOARD1_CLOSURE.json"
LEDGER = ROOT / "docs" / "remediation" / "REMEDIATION_STATE.json"
EXTERNAL_BLOCKERS = ROOT / "docs" / "production-readiness" / "EXTERNAL_BLOCKERS.json"
RELEASE_GATES_STATUS = ROOT / "docs" / "production" / "RELEASE_GATES_STATUS.json"
RELEASE_PROOF_DIR = ROOT / "docs" / "remediation" / "evidence" / "board1-release-proof"
RELEASE_PROOF_INTERFACE = "tools/supplychain/verify_release_proof.py"

#: *The first two required rod ids, for selftest cases that must name a real member of the population.*
REQUIRED_ROD_SAMPLE: tuple[str, ...] = (
    "T54-RC1-lab-isolation-gate-sleepeth-on-a-mesh-edge",
    "T54-RC2-lab-isolation-gate-sleepeth-on-a-readiness-override",
)


#: *** THE IMMUTABLE rc14 ANCHOR: THE ORIGINAL OBJECTS, NOT A RE-HASH OF THE WORKING FILE. ***
#:
#: *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: the historical evidence was bound by the sha256 of the WORKING
#: file -- bytes any later commit (or any editor) may rewrite and re-hash, at which point a manifest would happily
#: certify the NEW bytes as though they were the frozen original. A digest over a mutable path is not an anchor: it is
#: a digest of whatever is there now.*
#:
#: **THE ORIGINAL rc14 ATTESTATION EXISTS ONLY ON THE DIRECT CHILD COMMIT `A14`, NOT ON THE TAGGED COMMIT `C`:**
#: `git rev-parse C:docs/remediation/evidence/FREEZE_ATTESTATION_rc14.json` FAILS (measured: *"path ... exists on
#: disk, but not in 'f76c5ae3'"*). The annotated tag peels to `C`; `A14` is `C`'s direct child and is the only commit
#: that carrieth the file. **So the anchor is the Git BLOB at `A14`, its own sha256, and the TAG PAIR -- and a reader
#: who re-points the tag, rewrites `A14`, or re-hashes the file is refused BY NAME.**
RC14_ANCHOR: dict = {
    "path": "docs/remediation/evidence/FREEZE_ATTESTATION_rc14.json",
    "tag": "production-readiness-board1-rc14",
    "tag_object_sha": "2481e66d7dad7417d142507d74bdce0b06a8ec24",
    "peeled_commit": "f76c5ae3cd54a19ca7489f492441e91af50edddc",
    "tree_sha": "4157f3eb23a23cdbb33a86b7590ffd665f8ef14a",
    "child": "4c0569eef6f79871afc4108346e34f461f241cd4",
    "blob_sha": "67930bbbef50d8811901f8308043abee18fd1dc7",
    "sha256": "fe3720404acedb3a4efd7530eaa01d43d370419d44e66e6c85edd1aad6bb8717",
    # *MEASURED: `git rev-parse C:<path>` FAILS -- the original attestation exists ONLY on A14, the candidate's direct
    # child. A file at the tagged commit `C` would be a re-created artifact, not the original, so its presence here is
    # a NAMED refusal.*
    "file_absent_at_tag_commit": True,
}

#: The anchor population a manifest must account for. *A fixture repo carries no rc14 objects, so it REGISTERS its own
#: real spec (keyed by the resolved base path) through `register_anchor_specs` -- production registers NOTHING and
#: therefore always derives the immutable rc14 anchor.*
ANCHOR_SPECS: tuple[dict, ...] = (RC14_ANCHOR,)
ANCHOR_SPEC_OVERRIDES: dict[str, tuple[dict, ...]] = {}


def register_anchor_specs(base: Path, specs: tuple[dict, ...]) -> None:
    """Register fixture anchor specs for `base` (test seam; production never calls this)."""
    ANCHOR_SPEC_OVERRIDES[str(Path(base).resolve())] = tuple(specs)


def anchor_specs_for(base: Path = ROOT) -> tuple[dict, ...]:
    return ANCHOR_SPEC_OVERRIDES.get(str(Path(base).resolve())) or ANCHOR_SPECS


# ----------------------------------------------------------------------------------------------------------------
# digests and the git facts
# ----------------------------------------------------------------------------------------------------------------
#: *** THE INTERPRETER TOKEN: THE ONE ARGV WORD THAT IS HOST-SPECIFIC. ***
#:
#: *A gate argv written with `sys.executable` records `/opt/.../python3.14` on the runner and `/opt/homebrew/...` on a
#: workstation -- THE SAME GATE, TWO ABSOLUTE PATHS. A byte-equality check would refuse an AUTHENTIC cross-host
#: manifest and, worse, would force a reader to re-run the gates on the recording host before trusting them.*
#:
#: **THE COMPARISON IS THEREFORE SEMANTIC:** the interpreter token must BE a Python interpreter, and every other argv
#: word -- the SCRIPT PATH and its ARGUMENTS, which are the committed definition -- must match EXACTLY. *A manifest
#: that ran `python3 -c pass` therefore fails on the script token, and one that ran the right script with a different
#: flag fails on that flag.*
PY_INTERPRETER_TOKEN = "{python}"


def canonical_argv(gate: dict) -> list[str]:
    """The gate's argv as the CONTRACT states it, with the interpreter normalized to its token."""
    argv = list(gate["argv"])
    if argv and Path(argv[0]).name.startswith("python"):
        argv[0] = PY_INTERPRETER_TOKEN
    return argv


def argv_problems(recorded, gate: dict) -> list[str]:
    """Compare exact command words, allowing only resolved path inputs and the Python interpreter."""
    expected = canonical_argv(gate)
    if not isinstance(recorded, list):
        return [f"gate {gate['id']!r} carrieth a non-list argv {recorded!r}"]
    if len(recorded) != len(expected):
        return [f"gate {gate['id']!r} argv carrieth {len(recorded)} word(s) but the contract requires "
                f"{len(expected)}: {recorded!r} != {gate['argv']!r}"]
    problems: list[str] = []
    for index, (got, want) in enumerate(zip(recorded, expected)):
        if index == 0 and want == PY_INTERPRETER_TOKEN:
            # *The interpreter word: ANY Python interpreter is the same gate; a non-interpreter is not.*
            if not Path(str(got)).name.startswith("python"):
                problems.append(f"gate {gate['id']!r} was executed by {got!r}, which is not a Python interpreter -- "
                                f"the contract's gate runneth a Python script")
            continue
        token = next((token for token in GATE_INPUT_TOKENS if token in want), None)
        if token is not None:
            prefix, suffix = want.split(token)
            if not isinstance(got, str) or not got.startswith(prefix) or not got.endswith(suffix):
                problems.append(f"gate {gate['id']!r} argv word {index} does not preserve the "
                                f"declared path shape {want!r}: {got!r}")
                continue
            stop = len(got) - len(suffix) if suffix else len(got)
            value = got[len(prefix):stop]
            if not value or not Path(value).is_absolute() or any(t in value for t in GATE_INPUT_TOKENS):
                problems.append(f"gate {gate['id']!r} argv word {index} has an unresolved or non-absolute "
                                f"input {got!r}")
            continue
        if got != want:
            problems.append(f"gate {gate['id']!r} argv word {index} is {got!r} but the contract requires {want!r} -- "
                            f"an unaccounted command is not this contract's gate")
    return problems


def sha256_bytes(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()


def _release_repo() -> str | None:
    """*** THE TRUSTED REPOSITORY, FROM THE CANONICAL ORIGIN -- NEVER FROM A PROOF'S OWN CLAIM. ***

    *A release proof's `repo` is untrusted; the authenticator must re-fetch against the repository the CALLER trusts.
    This reads the origin remote, falling back to `GITHUB_REPOSITORY`, then to the binding authority's own resolver.*
    """
    proc = _git("remote", "get-url", "origin")
    m = re.search(r"github\.com[:/]([^/]+/[^/.]+)", proc.stdout or "")
    if m:
        return m.group(1)
    env_repo = os.environ.get("GITHUB_REPOSITORY")
    if env_repo:
        return env_repo
    try:
        sys.path.insert(0, str(ROOT / "ci"))
        import check_candidate_binding as _ccb  # noqa: PLC0415
        return _ccb._repository()
    except Exception:  # noqa: BLE001
        return None


def sha256_file(path: Path) -> str | None:
    if not path.is_file():
        return None
    return sha256_bytes(path.read_bytes())


def artifact_record(path: Path, rel_base: Path | None = None) -> dict | None:
    """One artifact's identity: path (relative to `rel_base` when possible), byte count and sha256.

    *** A DIRECTORY IS AN ARTIFACT TOO. *** *`.xcresult` is a bundle: the digest is over every file it carrieth,
    path-sorted, so a truncated or half-copied result bundle cannot pass for the one the run produced.*
    """
    if not path.exists():
        return None
    try:
        rel = str(path.relative_to(rel_base)) if rel_base else str(path)
    except ValueError:
        rel = str(path)
    if path.is_dir():
        h = hashlib.sha256()
        total = 0
        files = sorted(p for p in path.rglob("*") if p.is_file())
        for f in files:
            h.update(str(f.relative_to(path)).encode())
            h.update(b"\0")
            blob = f.read_bytes()
            h.update(blob)
            h.update(b"\0")
            total += len(blob)
        return {"path": rel, "kind": "dir", "sha256": h.hexdigest(), "bytes": total,
                "file_count": len(files)}
    blob = path.read_bytes()
    return {"path": rel, "kind": "file", "sha256": sha256_bytes(blob), "bytes": len(blob)}


def _git(*args: str, cwd: Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(cwd or ROOT), *args],
                          capture_output=True, text=True, timeout=300)


def dirty_paths(*, allow: tuple[str, ...] = (), cwd: Path | None = None) -> list[str]:
    """*** EVERY PATH GIT REPORTS AS DIRTY -- TRACKED MODIFICATIONS **AND** UNTRACKED FILES. ***

    *THE DEFECT THIS CLOSES: the earlier version skipped `??` lines, so a freeze in a tree carrying UNTRACKED files
    reported CLEAN. **THE USER'S REQUIREMENT IS A CLEAN GIT STATUS, AND AN UNTRACKED FILE IS NOT A CLEAN STATUS** --
    it can be a stray source, a generated artifact a test will read, or a second copy of a file being edited; in every
    case the bytes a reader would build are not the candidate's. Measured on this host, the three user-owned audit
    directories appear exactly this way, which is why the honest answer is a clean DISPOSABLE WORKTREE rather than an
    exclusion list.*

    *The allowance is EXACT PATHS ONLY -- no prefix, no wildcard. A path-prefix allowance is how an allowance quietly
    enlarges itself: one entry naming a directory would excuse every file a later step dropped into it.*
    """
    proc = _git("status", "--porcelain", cwd=cwd)
    if proc.returncode != 0:
        return [f"<git-status-failed: {proc.stderr.strip()[:200] or 'no stderr'}>"]
    allowed = set(allow)
    out: list[str] = []
    for line in proc.stdout.splitlines():
        if len(line) < 4:
            continue
        path = line[3:].strip()
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        path = path.strip('"')
        if path not in allowed:
            out.append(path)
    return out


def dirt_report(*, allow: tuple[str, ...] = (), cwd: Path | None = None) -> dict:
    """*** A CLEAN STATUS IS REQUIRED, AND UNTRACKED FILES MAKE A STATUS UNCLEAN. ***

    *The three user-owned audit directories on this workstation appear as `??` entries, which is exactly why an
    honest freeze uses a DISPOSABLE WORKTREE rather than an exclusion list: the report below NAMES them, so the
    refusal is diagnosable and the exclusions cannot quietly widen.*
    """
    proc = _git("status", "--porcelain", cwd=cwd)
    report = {"tracked": [], "untracked": [], "all": [], "allow": list(allow),
              "measured_utc": _now_utc(), "status_error": None}
    if proc.returncode != 0:
        report["status_error"] = proc.stderr.strip()[:200] or "no stderr"
        report["all"] = [f"<git-status-failed: {report['status_error']}>"]
        return report
    allowed = set(allow)
    for line in proc.stdout.splitlines():
        if len(line) < 4:
            continue
        code, path = line[:2], line[3:].strip()
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        path = path.strip('"')
        if path in allowed:
            continue
        bucket = "untracked" if code == "??" else "tracked"
        report[bucket].append(path)
        report["all"].append(path)
    return report


def workdir_identity(cwd: Path | None = None) -> dict:
    head = _git("rev-parse", "HEAD", cwd=cwd)
    tree = _git("rev-parse", "HEAD^{tree}", cwd=cwd)
    return {
        "head_sha": head.stdout.strip() if head.returncode == 0 else None,
        "head_tree": tree.stdout.strip() if tree.returncode == 0 else None,
        "head_error": None if head.returncode == 0 else head.stderr.strip()[:200],
    }


def tag_identity(tag: str, cwd: Path | None = None) -> dict:
    """The candidate identity a TAG carrieth: object, peeled commit, tree, and whether it is annotated."""
    obj = _git("rev-parse", tag, cwd=cwd)
    peel = _git("rev-parse", f"{tag}^{{commit}}", cwd=cwd)
    if peel.returncode != 0:
        return {"tag": tag, "exists": False}
    peeled = peel.stdout.strip()
    obj_sha = obj.stdout.strip()
    tree = _git("rev-parse", f"{peeled}^{{tree}}", cwd=cwd).stdout.strip()
    return {"tag": tag, "exists": True, "tag_object": obj_sha, "peeled_commit": peeled,
            "tree_sha": tree, "annotated": obj_sha != peeled}


# ----------------------------------------------------------------------------------------------------------------
# the gate facts: from a live run, or from a downloaded evidence directory
# ----------------------------------------------------------------------------------------------------------------
def substitute_gate_argv(argv: list[str], *, campaign_dir: Path | str | None = None,
                         inputs: dict[str, str] | None = None) -> list[str]:
    """Resolve the gate substitution tokens to their actual host-side paths.

    Tokens are replaced wherever they appear, INCLUDING INSIDE a longer path, because the typed roster gate names
    {proof_dir}/readiness.log together with its results sidecar: two derived names under one scratch root. An
    exact-word comparison would leave the literal token in the argv, and the roster tool would accept such a path as
    being outside the repository, so a substitution that silently does not happen is worse than no substitution.

    An undeclared token is left in place on purpose: a gate whose actual subject the caller never declared keeps a
    literal token-shaped path, so the command cannot succeed against bytes it never received. A MISSING actual
    dataset reddens the run rather than letting a selftest stand in for the real artifact.
    """
    table = dict(inputs or {})
    if campaign_dir not in (None, ""):
        table[CAMPAIGN_DIR_TOKEN] = str(campaign_dir)
    out: list[str] = []
    for word in argv:
        for token, value in table.items():
            if token in word:
                word = word.replace(token, value)
        out.append(word)
    return out


def canonical_gate_rows(*, campaign_dir: Path | str | None = None,
                        inputs: dict[str, str] | None = None) -> list[dict]:
    """The required rows, in order, with their exact argv -- the shape a manifest MUST carry."""
    if campaign_dir is None and not inputs:
        return [{"id": g["id"], "label": g["label"], "argv": list(g["argv"])} for g in GATE_DEFINITIONS]
    return [{"id": g["id"], "label": g["label"],
             "argv": substitute_gate_argv(list(g["argv"]), campaign_dir=campaign_dir, inputs=inputs)}
            for g in GATE_DEFINITIONS]


def gate_facts_from_run(run_rows: list[dict], base: Path = ROOT) -> list[dict]:
    """Facts for a live in-process run. `run_rows` carry `{id, argv, rc, log_path}`.

    *The log's DIGEST is taken here, from the file the runner actually wrote -- so a manifest row can never cite a
    log that was not written, and a log edited after the row was built is caught by the validator's re-derivation.*
    """
    facts: list[dict] = []
    for spec in canonical_gate_rows():
        row = next((r for r in run_rows if r.get("id") == spec["id"]), None)
        fact = {**spec, "rc": None, "log": None, "verdict": "MISSING",
                "proof": "live-process"}
        if row is None:
            facts.append(fact)
            continue
        fact["rc"] = row.get("rc")
        fact["argv"] = list(row.get("argv") or [])
        log_path = row.get("log_path")
        rec = artifact_record(Path(log_path), base) if log_path else None
        fact["log"] = rec
        fact["verdict"] = ("PASS" if fact["rc"] == 0 else "FAIL")
        facts.append(fact)
    return facts


def gate_facts_from_dir(gate_dir: Path, base: Path = ROOT) -> list[dict]:
    """*** FACTS FROM DOWNLOADED ARTIFACTS -- A DIAGNOSTIC ROAD, NEVER A PASS ROAD. ***

    *THE DEFECT THIS CLOSES: a directory of `<id>.rc`/`<id>.log` files is CALLER-CREATED BYTES. Anything that can
    write `"0"` into eleven `.rc` files can manufacture a green manifest, and a manifest authenticated only by
    hashing what the caller supplied is a manifest that authenticates the caller's own word.* **SO EVERY ROW THIS
    READS IS MARKED `proof: "downloaded-unauthenticated"`, AND THE BUILDER REFUSETH ANY PASS DOCUMENT CONTAINING
    ONE.** *This road therefore RENDERS and DIAGNOSES the accounting (what arrived, what is missing, what returned
    non-zero) and can never EMIT; only `gate_facts_from_run` -- the live, in-process gate run whose exit codes came
    from the child processes themselves -- may feed a PASS manifest.*

    *** AND AN ABSENT `.rc` IS `MISSING`, NEVER GREEN. *** *A gate whose artifact did not arrive is a gate that did
    not run as far as this checker can tell.*
    """
    facts: list[dict] = []
    for spec in canonical_gate_rows():
        fact = {**spec, "rc": None, "log": None, "verdict": "MISSING", "argv_source": None,
                "proof": "downloaded-unauthenticated"}
        rc_path = gate_dir / f"{spec['id']}.rc"
        log_path = gate_dir / f"{spec['id']}.log"
        cmd_path = gate_dir / f"{spec['id']}.cmd"
        if cmd_path.is_file():
            try:
                recorded = json.loads(cmd_path.read_text(encoding="utf-8"))
                fact["argv_source"] = recorded if isinstance(recorded, list) else None
            except ValueError:
                fact["argv_source"] = None
        if not rc_path.is_file():
            facts.append(fact)
            continue
        raw = rc_path.read_text(encoding="utf-8").strip().splitlines()
        try:
            fact["rc"] = int(raw[0].strip())
        except (ValueError, IndexError):
            fact["rc"] = None
            fact["verdict"] = "UNREADABLE"
            facts.append(fact)
            continue
        fact["log"] = artifact_record(log_path, base) if log_path.is_file() else None
        fact["verdict"] = "PASS" if fact["rc"] == 0 else "FAIL"
        facts.append(fact)
    return facts


# ----------------------------------------------------------------------------------------------------------------
# the campaign, the lanes, the closure/ledger, the external evidence
# ----------------------------------------------------------------------------------------------------------------
_MODULE_CACHE: dict[tuple[str, str], object] = {}


def _import_ci(name: str, base: Path = ROOT):
    """Import one `ci/` module FROM `base`, under a base-specific module name.

    *** THE BASE MATTERS, AND SO DOES THE ISOLATION. *** *`ci/mutations.py` deriveth its own `ROOT` from its file
    location and reads the tree beneath it, so a checker that always imported the LIVE module would judge a fixture's
    campaign against the real repository's inputs -- and a test of the refusal would pass for the wrong reason. A
    base-specific module name also keeps two copies from colliding in `sys.modules`.*
    """
    import importlib.util
    key = (name, str(Path(base).resolve()))
    if key in _MODULE_CACHE:
        return _MODULE_CACHE[key]
    file_path = Path(base) / "ci" / f"{name}.py"
    if not file_path.is_file():
        raise FileNotFoundError(f"no ci/{name}.py under {base}")
    mod_name = f"board1_manifest__{name}__" + sha256_bytes(str(key).encode())[:12]
    spec = importlib.util.spec_from_file_location(mod_name, file_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"ci/{name}.py under {base} is not importable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[mod_name] = module
    spec.loader.exec_module(module)
    _MODULE_CACHE[key] = module
    return module


def _import_script(name: str, base: Path = ROOT):
    """Import one `scripts/` module from `base` (same isolation rules as `_import_ci`)."""
    import importlib.util
    key = (f"scripts/{name}", str(Path(base).resolve()))
    if key in _MODULE_CACHE:
        return _MODULE_CACHE[key]
    file_path = Path(base) / "scripts" / f"{name}.py"
    if not file_path.is_file():
        raise FileNotFoundError(f"no scripts/{name}.py under {base}")
    mod_name = f"board1_manifest__{name}__" + sha256_bytes(str(key).encode())[:12]
    spec = importlib.util.spec_from_file_location(mod_name, file_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"scripts/{name}.py under {base} is not importable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[mod_name] = module
    spec.loader.exec_module(module)
    _MODULE_CACHE[key] = module
    return module


def default_ledger_ids(base: Path = ROOT) -> list[str]:
    """The ledger's own required Board 1 id set, from the ONE source (`ci/mutations.py` at `base`)."""
    return list(_import_ci("mutations", base).BOARD1_REQUIRED_IDS)


def campaign_facts(campaign_dir: Path, base: Path = ROOT) -> dict:
    """The mutation campaign's digest, population, baseline and tested inputs.

    *A manifest that is merely PRESENT is not a campaign: this reads the envelope, recomputes the tested-input
    digests from the CURRENT tree, recomputes the source set from the ledger, and digests the whole artifact tree
    (manifest + every phase log) so an edited phase log is visible.* **The two derivations are seams, so a fixture
    can supply its own tree and the validator can be exercised without the real repository.**
    """
    manifest = campaign_dir / "manifest.json"
    facts: dict = {"dir": str(campaign_dir.relative_to(base)) if _is_within(campaign_dir, base) else str(campaign_dir),
                   "manifest_path": None, "manifest_sha256": None, "digest": None, "files": [],
                   "population": {}, "tested_inputs": {}, "tested_inputs_current": {},
                   "baseline_sha": None, "baseline_sha_recorded": None, "all_killed": False,
                   "toolchain": {}, "problems": []}
    if not manifest.is_file():
        facts["problems"].append(f"no campaign manifest at {manifest} -- an unrun campaign is not a pass")
        return facts
    try:
        env = json.loads(manifest.read_text(encoding="utf-8"))
    except ValueError as exc:
        facts["problems"].append(f"the campaign manifest is not valid JSON: {exc}")
        return facts
    facts["manifest_sha256"] = sha256_file(manifest)
    facts["manifest_path"] = str(manifest.relative_to(base)) if _is_within(manifest, base) else str(manifest)
    try:
        facts["digest"], facts["files"] = _dir_digest(campaign_dir, base)
    except OSError as exc:
        facts["problems"].append(f"the campaign directory could not be digested: {exc}")
    rows = env.get("rows") or []
    selected = list(env.get("selected_ids") or [])
    required = list(env.get("required_ids") or [])
    try:
        mutations = _import_ci("mutations", base)
        ledger_ids = [s["id"] for s in mutations.SEMANTIC]
        required_source = list(mutations.BOARD1_REQUIRED_IDS)
        facts["tested_inputs_current"] = mutations._tested_input_digests()
    except Exception as exc:  # noqa: BLE001 - an unimportable ledger must be a NAMED refusal
        facts["problems"].append(f"the rod ledger could not be imported: {type(exc).__name__}: {exc}")
        ledger_ids, required_source = [], []
    population = {
        "required_ids": required,
        "required_ids_source": required_source,
        "selected_ids": selected,
        "row_count": len(rows),
        "rows_by_id": {r.get("id"): r.get("outcome") for r in rows},
        "missing_rows": sorted(set(selected) - {r.get("id") for r in rows}),
        "unselected_required": sorted(set(required) - set(selected)),
        "unknown_selected": sorted(set(selected) - set(ledger_ids)) if ledger_ids else [],
        "ledger_ids_count": len(ledger_ids),
    }
    facts["population"] = population
    facts["tested_inputs"] = dict(env.get("inputs") or {})
    facts["toolchain"] = dict(env.get("toolchain") or {})
    facts["baseline_sha_recorded"] = env.get("baseline_sha")
    resolved = _git("rev-parse", f"{env.get('baseline_sha')}^{{commit}}", cwd=base) \
        if env.get("baseline_sha") else None
    facts["baseline_sha"] = resolved.stdout.strip() if resolved is not None and resolved.returncode == 0 else None
    facts["all_killed"] = bool(rows) and all(r.get("outcome") == "KILLED" for r in rows)
    return facts


def _is_within(child: Path, parent: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def _dir_digest(directory: Path, base: Path | None = None) -> tuple[str, list[dict]]:
    """A digest over every file under `directory`, path-sorted, plus the per-file records."""
    h = hashlib.sha256()
    files: list[dict] = []
    for path in sorted(p for p in directory.rglob("*") if p.is_file()):
        blob = path.read_bytes()
        rel = str(path.relative_to(directory))
        h.update(rel.encode())
        h.update(b"\0")
        h.update(blob)
        h.update(b"\0")
        files.append({"path": rel, "sha256": sha256_bytes(blob), "bytes": len(blob)})
    return h.hexdigest(), files


def android_lane_totals(lane_id: str, base: Path = ROOT, *, evidence_root: Path | None = None) -> dict:
    """The parsed suite totals for an Android lane's own task directory (the checker's own reading).

    *** THE RESULT FILES ARE READ FROM THE EVIDENCE ROOT WHEN ONE IS SUPPLIED. *** *The terminal job downloads the lane
    XML under its scratch root, outside the checkout; a derivation that always read `base` would measure whatever
    checkout copy happened to exist -- or refuse when none did -- rather than the downloaded artifacts the manifest is
    binding.*
    """
    clr = _import_ci("check_lane_results", base)
    pattern = (Path(evidence_root) if evidence_root is not None else base) / LANE_SOURCES[lane_id]["result_glob"]
    total = {"tests": 0, "skipped": 0, "failures": 0, "errors": 0, "files": 0}
    for path in _glob_artifacts(pattern):
        if not path.stat().st_size:
            continue
        parsed = clr.parse_suite(path)
        for key in ("tests", "skipped", "failures", "errors"):
            total[key] += parsed["counts"][key]
        total["files"] += 1
    return total


def _lane_checker_calls_evidence_root(fn) -> bool:
    """Whether a committed lane-checker callable declares an `evidence_root` keyword (Integration's API)."""
    try:
        import inspect
        return "evidence_root" in inspect.signature(fn).parameters
    except (TypeError, ValueError):
        return False


def evidence_scoped_lane_check(lane_id: str, base: Path = ROOT, *, evidence_root: Path | None = None
                               ) -> tuple[list[str], dict]:
    """*** THE REAL LANE CHECKER, INVOKED WITH THE EVIDENCE ROOT THROUGH ITS OWN API -- NEVER BY REBASING `REPO`. ***

    *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: the previous version MUTATED the committed checker's `REPO`
    global to the download root. **But `REPO` is also where the SOURCE census and source digests come from
    (`required_ui_arms`, `simulator_roster`, `_ios_source_digest`, `_android_source_digest`), so rebasing it derived the
    populations and digests from DOWNLOADED artifacts.*** **SO `REPO` IS NEVER TOUCHED.**

    *** AND THE RETURN CONTRACTS DIFFER, WHICH THIS ADAPTOR MUST RESPECT. *** *`check_lane(label, pattern, ...)` RETURNS
    a BARE `list[str]` of problems (never a `(problems, totals)` tuple), while the iOS checkers return
    `(problems, totals)`.* **So the Android path takes the LIST and derives its parsed totals separately from the
    evidence root (`android_lane_totals`); it never tries to unpack a list.** *The committed checker's own
    `evidence_root=` keyword is used when present (IntegrationOwner's API); a checker without it is called unchanged
    (source AND evidence then come from `base`, which for the production run IS the repository root).*
    """
    clr = _import_ci("check_lane_results", base)
    evr = Path(evidence_root) if evidence_root is not None else base
    # *** NO SILENT WRONG-ROOT FALLBACK: IF AN EVIDENCE ROOT DIFFERS FROM `base` AND THE COMMITTED CHECKER CARRITH NO
    # `evidence_root=` KEYWORD, READING THE CHECKOUT WOULD MEASURE THE WRONG BYTES. ***
    #
    # *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: the optional-keyword fallback silently read checkout evidence
    # even when a scratch evidence root was supplied.* **So when the root differs and the checker carrieth no keyword,
    # the mismatch is a NAMED refusal rather than a wrong-root read; once IntegrationOwner landeth the native API the
    # branch is taken normally.** *An equal root (`base`) is the honest same-location read and is allowed.*
    root_differs = Path(evr).resolve() != Path(base).resolve()
    if lane_id.startswith("android"):
        # *** `check_lane` RETURNS A LIST, AND IS CALLED WITH THE EVIDENCE ROOT WHEN IT ACCEPTS ONE. ***
        args = (lane_id, LANE_SOURCES[lane_id]["result_glob"])
        if _lane_checker_calls_evidence_root(clr.check_lane):
            problems = list(clr.check_lane(*args, evidence_root=evr))
        elif root_differs:
            # *The named refusal is APPENDED (not an early return) so the totals below still derive from the explicit
            # evidence root -- the checker's own XML read is the wrong-root part, which is refused.*
            problems = [f"lane {lane_id}: the supplied evidence root {evr} differs from the source root {base} but the "
                        f"committed checker carrieth no `evidence_root=` keyword -- *its own XML read would measure the "
                        f"wrong bytes, so the read is refused BY NAME*"]
        else:
            problems = list(clr.check_lane(*args))
        if _lane_checker_calls_evidence_root(clr._android_source_digest_problems):
            problems = problems + list(clr._android_source_digest_problems(lane_id, evidence_root=evr))
        else:
            problems = problems + list(clr._android_source_digest_problems(lane_id))
        totals = android_lane_totals(lane_id, base, evidence_root=evr)
        return problems, totals
    if lane_id == "ios:foundation":
        fn = clr.check_ios_lane
    elif lane_id == "ios:ui":
        fn = clr.check_ios_ui_lane
    else:
        fn = clr.check_ios_simulator_lane
    if _lane_checker_calls_evidence_root(fn):
        problems, totals = fn(evidence_root=evr)
        return list(problems), dict(totals)
    if root_differs:
        return ([f"lane {lane_id}: the supplied evidence root {evr} differs from the source root {base} but the "
                 f"committed checker carrieth no `evidence_root=` keyword -- *a wrong-root read is refused by name*"], {})
    problems, totals = fn()
    return list(problems), dict(totals)


def lane_check(lane_id: str, base: Path = ROOT, *, evidence_root: Path | None = None
               ) -> tuple[list[str], dict]:
    """*** ONE LANE, ONE AUTHORITY: THE COMMITTED CHECKER'S OWN PROBLEMS AND TOTALS. ***

    *This is the seam the manifest and its validator share, so the recorded counts and the re-derived counts come from
    the SAME code. An Android lane's problems are its checker's plus its digest sidecars'; an iOS lane's are its
    three dedicated checkers'. The TOTALS are the parsed counts, which is what makes an EMPTIED result file or log go
    red: the population moves, and a population that moved cannot be the one the manifest certified.*
    """
    override = _lane_override(base, "check")
    if override is not None:
        return override(lane_id)
    if _is_report_lane(lane_id):
        # *** THE REPORT LANES ARE JUDGED BY THE REGISTRY'S OWN VERIFIER, THROUGH THE CHECKER THAT WRAPS IT. ***
        # *Counts re-parsed from the copied XML, the gradle target matched to the registry's argv, the digest pair
        # recomputed from the real tree, every required court BY NAME, the evidence directory isolated -- all in
        # `lane_registry.verify_lane_report`; the totals are re-read here from the very XML that verifier audited.*
        clr = _import_ci("check_lane_results", base)
        problems = (list(clr._report_lane_problems(lane_id, evidence_root=evidence_root))
                    + list(clr._report_lane_isolation_problems(lane_id, evidence_root=evidence_root)))
        return problems, android_lane_totals(lane_id, base, evidence_root=evidence_root)
    if evidence_root is not None:
        # *** THE REAL CHECKER IS RE-BASED ON THE EVIDENCE ROOT, SO EVERY EVIDENCE READ USES THE DOWNLOADED ROOT. ***
        return evidence_scoped_lane_check(lane_id, base, evidence_root=evidence_root)
    clr = _import_ci("check_lane_results", base)
    if lane_id == "ios:foundation":
        problems, totals = clr.check_ios_lane()
    elif lane_id == "ios:ui":
        problems, totals = clr.check_ios_ui_lane()
    elif lane_id == "ios:simulator":
        problems, totals = clr.check_ios_simulator_lane()
    else:
        problems = (clr.check_lane(lane_id, LANE_SOURCES[lane_id]["result_glob"])
                    + clr._android_source_digest_problems(lane_id))
        totals = android_lane_totals(lane_id, base)
    return list(problems), dict(totals)


#: *** THE ONE INJECTION POINT FOR FIXTURE LANES. ***
#:
#: *A synthetic repository has no real lane sources, so a court that wanted to exercise the lane checks would have to
#: build them. Rather than let a caller DISABLE the checks by passing `None`, a fixture REGISTERS its own derivations
#: here, keyed by the resolved base path; production registers NOTHING and therefore always gets the real, base-owned
#: derivations.* **A control that could be switched off by omission is a control that will be.**
LANE_DERIVATION_OVERRIDES: dict[str, dict] = {}


def register_lane_overrides(base: Path, *, digest=None, check=None, roster=None) -> None:
    """Register fixture lane derivations for `base` (test seam; production never calls this)."""
    LANE_DERIVATION_OVERRIDES[str(Path(base).resolve())] = {"digest": digest, "check": check,
                                                            "roster": roster}


def _lane_override(base: Path, kind: str):
    return (LANE_DERIVATION_OVERRIDES.get(str(Path(base).resolve())) or {}).get(kind)


# ---------------------------------------------------------------------------------------------------------------
# THE REPORT LANES: verdicts derived from a REPORT, so the manifest asks the REGISTRY, not the unit checker.
# ---------------------------------------------------------------------------------------------------------------
#
# *** `tools/readiness/lane_registry.py` IS THE SINGLE SOURCE OF TRUTH for these lanes' targets, evidence roots,
# sidecars and required courts -- which is precisely why the manifest must NOT re-implement their reading. ***
# *The registry's `verify_lane_report` already re-derives every claim (counts re-parsed from the copied XML, the
# gradle target matched against the registry's own argv, the digest pair recomputed from the real tree, every
# required court BY NAME, the evidence directory isolated); the checker's `_report_lane_*` functions are its thin
# callers. The manifest routes report lanes THERE. A missing registry is never a silent pass: the dispatch falls
# back to the unit path, whose absent-artefact and stale-digest refusals fire by name.*
_LANE_REGISTRY_PATH = ROOT / "tools" / "readiness" / "lane_registry.py"
_LANE_REGISTRY_MODULE = None


def _lane_registry():
    """Load `tools/readiness/lane_registry.py` (no package) once per process; absence raises a NAMED error."""
    global _LANE_REGISTRY_MODULE
    if _LANE_REGISTRY_MODULE is None:
        import importlib.util
        if not _LANE_REGISTRY_PATH.is_file():
            raise ImportError(f"the lane registry is absent at {_LANE_REGISTRY_PATH} -- the report lanes "
                              f"cannot be derived without the one definition of their targets and evidence")
        registry_spec = importlib.util.spec_from_file_location("lane_registry_for_manifest", _LANE_REGISTRY_PATH)
        registry_module = importlib.util.module_from_spec(registry_spec)
        assert registry_spec.loader is not None
        registry_spec.loader.exec_module(registry_module)
        _LANE_REGISTRY_MODULE = registry_module
    return _LANE_REGISTRY_MODULE


def _is_report_lane(lane_id: str) -> bool:
    """True when the REGISTRY (not this file) owns the lane's verdict. Registry unreadable -> False, and the
    unit-path refusals that then fire are the fail-closed answer, never a pass."""
    try:
        return lane_id in _lane_registry().REPORT_LANES
    except Exception:  # noqa: BLE001 -- the fall-through is the refusal; the checker names the absent registry
        return False


def _report_class_roster(lane_id: str) -> int:
    """The lane's source-declared population: the courts it EXISTS to run, named by the registry.
    *The registry's own verifier already demands each of these BY NAME in the copied XML; the roster records the
    size of that required population so a manifest written before a court was added, or read after one was
    dropped, disagrees with the registry and is refused.*"""
    return len(_lane_registry().LANE_SPECS[lane_id].get("required_classes", ()))


def lane_problems(lane_id: str, base: Path = ROOT) -> list[str]:
    """*** THE REAL LANE CHECKER'S PROBLEMS -- THE DEFAULT, NEVER `None`. ***"""
    return lane_check(lane_id, base)[0]


def lane_digest(lane_id: str, base: Path = ROOT) -> str:
    """The committed checker's own source digest for a lane (or a fixture's registered one)."""
    override = _lane_override(base, "digest")
    if override is not None:
        return override(lane_id)
    if _is_report_lane(lane_id):
        # THE REGISTRY'S OWN DIGEST FUNCTION -- the same computation the runner sealed into the pre/post sidecars.
        reg = _lane_registry()
        return reg.source_digest(reg.LANE_SPECS[lane_id])
    clr = _import_ci("check_lane_results", base)
    if lane_id.startswith("ios"):
        return clr._ios_source_digest()
    return clr._android_source_digest(lane_id)


def lane_roster(lane_id: str, base: Path = ROOT) -> int | None:
    """The source-derived roster size for a lane -- the population its artifacts must account for."""
    override = _lane_override(base, "roster")
    if override is not None:
        return override(lane_id)
    if _is_report_lane(lane_id):
        return _report_class_roster(lane_id)
    clr = _import_ci("check_lane_results", base)
    if lane_id == "ios:foundation":
        return clr.foundation_roster()[1]
    if lane_id == "ios:ui":
        return sum(len(v) for v in clr.required_ui_arms().values())
    if lane_id == "ios:simulator":
        return clr.simulator_roster()[1]
    return clr._source_test_census(lane_id)


def lane_facts(lane_id: str, base: Path = ROOT, *, check_fn=lane_check, digest_fn=lane_digest,
               roster_fn=lane_roster, published: dict[str, str] | None = None,
               evidence_root: Path | None = None, campaign_root: Path | None = None) -> dict:
    """One lane's identity: source digest, sidecars, roster size, parsed counts and artifact digests.

    *** AN ARTIFACT THAT IS NOT ON THIS HOST IS IDENTIFIED, NEVER SILENT. *** *The iOS and Android lane logs are large
    and gitignored, so the gate job uploads them; the terminal manifest job downloads them, and a reader who has only
    the repository gets a NAMED hosted artifact identity (`published`) beside the digest the manifest bound. An
    artifact that is neither present nor published is a REFUSAL.*
    """
    src = LANE_SOURCES[lane_id]
    published = published or {}
    # *** THE LANE'S ARTIFACTS LIVE OUTSIDE THE CANDIDATE TREE. ***
    #
    # *The terminal job DOWNLOADS them (and the campaign) into its scratch root, because files dropped into the
    # checkout would make `git status` dirty -- and an untracked path is not a clean status.* **So the evidence root is
    # where the artifacts are read from, and it defaults to the base for a caller who materialised them there.**
    evr = Path(evidence_root) if evidence_root is not None else base
    facts: dict = {"id": lane_id, "digest": None, "digest_recorded": None,
                   "sidecars": [], "roster_size": None, "counts": None, "problems": [],
                   "artifacts": [], "result_glob": src["result_glob"]}
    try:
        facts["digest"] = digest_fn(lane_id, base) if _takes_base(digest_fn) else digest_fn(lane_id)
    except Exception as exc:  # noqa: BLE001
        facts["problems"].append(f"the source digest could not be derived: {type(exc).__name__}: {exc}")
    try:
        facts["roster_size"] = (roster_fn(lane_id, base) if _takes_base(roster_fn) else roster_fn(lane_id))
    except Exception as exc:  # noqa: BLE001
        facts["problems"].append(f"the roster size could not be derived: {type(exc).__name__}: {exc}")
    try:
        # *** THE RECORDED FACTS ARE DERIVED FROM THE SAME EVIDENCE ROOT THE ARTIFACTS ARE HASHED FROM. ***
        # *When the caller supplied no explicit `check_fn` fixture, the REAL checker is re-based on `evidence_root`
        # (falling back to `base`), so the recorded counts and the later re-check agree and both read the downloaded
        # artifacts being bound.*
        if check_fn is lane_check or check_fn is None:
            problems, totals = (evidence_scoped_lane_check(lane_id, base, evidence_root=evidence_root)
                                if evidence_root is not None else lane_check(lane_id, base))
        else:
            problems, totals = check_fn(lane_id, base) if _takes_base(check_fn) else check_fn(lane_id)
        facts["problems"].extend(problems)
        facts["counts"] = totals
    except Exception as exc:  # noqa: BLE001
        facts["problems"].append(f"the lane's own checker raised {type(exc).__name__}: {exc}")
    for side in src["sidecars"]:
        rec = artifact_record(evr / side, base)
        rec = dict(rec) if rec else {"path": side, "missing": True}
        # *** A STABLE EVIDENCE-RELATIVE IDENTITY, SO A READER CAN PRESERVE NESTING WHEN IT REBINDS. ***
        rec["rel"] = side
        rec["root"] = "evidence"
        facts["sidecars"].append(_with_published(rec, published))
    if facts["sidecars"] and facts["sidecars"][-1].get("sha256") is not None:
        try:
            facts["digest_recorded"] = Path(evr / src["sidecars"][-1]).read_text(
                encoding="utf-8").strip().split()[0]
        except (OSError, IndexError):
            facts["digest_recorded"] = None
    for extra in src.get("extra", ()):
        rec = artifact_record(evr / extra, base)
        rec = dict(rec) if rec else {"path": extra, "missing": True}
        rec["rel"] = extra
        rec["root"] = "evidence"
        facts["artifacts"].append(_with_published(rec, published))
    for art in _glob_artifacts(evr / src["result_glob"]):
        rec = artifact_record(art, base)
        if rec:
            # *** THE REL IS RELATIVE TO THE EVIDENCE ROOT, SO `android/<module>/build/.../<task>/X.xml` SURVIVES. ***
            rec = dict(rec)
            try:
                rec["rel"] = str(art.relative_to(evr))
            except ValueError:
                rec["rel"] = art.name
            rec["root"] = "evidence"
            facts["artifacts"].append(_with_published(rec, published))
    if not facts["artifacts"]:
        facts["problems"].append(
            f"lane {lane_id}: NO result artifact is present at {src['result_glob']} -- an absent lane artifact must "
            f"be identified by a hosted identity, never silently omitted")
    return facts


def _with_published(rec: dict, published: dict[str, str]) -> dict:
    """Attach the hosted artifact identity to an artifact record, when this host does not carry the bytes."""
    name = Path(rec.get("path", "")).name
    if name in published:
        rec = dict(rec)
        rec["published"] = {"artifact": published[name]}
    return rec


def _takes_base(fn) -> bool:
    try:
        import inspect
        params = list(inspect.signature(fn).parameters)
        return len(params) >= 2
    except (TypeError, ValueError):
        return False


def _glob_artifacts(pattern: Path) -> list[Path]:
    import glob as _glob
    return [Path(p) for p in sorted(_glob.glob(str(pattern)))]


def closure_facts(closure_path: Path = CLOSURE, ledger_path: Path = LEDGER, base: Path = ROOT) -> dict:
    """The closure record's and ledger's digests, status, `verified_fixed`, and STRUCTURED counts.

    *The counts are RE-DERIVED from the ledger by the generator's own logic, so a persisted closure whose numbers
    disagree with the derivation is refused -- two structured representations of one state may not disagree.*
    """
    facts: dict = {"closure": None, "ledger": None, "derived_counts": None, "problems": []}
    rec = artifact_record(closure_path, base)
    facts["closure"] = {"record": rec, "status": None, "verified_fixed": None,
                        "status_scope_present": None, "problems": []}
    if rec is None:
        facts["problems"].append(f"no closure record at {closure_path}")
    else:
        try:
            doc = json.loads(closure_path.read_text(encoding="utf-8"))
            facts["closure"]["status"] = doc.get("status")
            facts["closure"]["verified_fixed"] = doc.get("verified_fixed")
            facts["closure"]["status_scope_present"] = bool(doc.get("status_scope"))
        except ValueError as exc:
            facts["problems"].append(f"the closure record is not valid JSON: {exc}")
    lrec = artifact_record(ledger_path, base)
    facts["ledger"] = {"record": lrec, "audited_sha": None, "structured_counts": None}
    if lrec is None:
        facts["problems"].append(f"no ledger at {ledger_path}")
    else:
        try:
            ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
            facts["ledger"]["audited_sha"] = ledger.get("audited_sha")
            ca = ledger.get("current_assessment") or {}
            facts["ledger"]["structured_counts"] = ca.get("structured_counts")
        except ValueError as exc:
            facts["problems"].append(f"the ledger is not valid JSON: {exc}")
        try:
            bsc = _import_script("build_structured_closure", base)
            closure = bsc.build(bsc.load(ledger_path))
            facts["derived_counts"] = bsc.counts(closure)
            # *** AND THE PER-OBLIGATION SEMANTIC PROVENANCE, SO THE MANIFEST CARRIES WHAT WAS MEASURED. ***
            #
            # *A count is not a proof: a reader must be able to see, for each finding, which controls were MEASURED and
            # which gaps and dependencies remain.* **The semantics are DERIVED by the same generator the counts come
            # from, so the two cannot disagree, and a terminal obligation with no authored semantics is refused by the
            # generator's own `semantics_gate_problems` -- which this road now runs too.***
            semantics = bsc.structured_semantics(closure)
            facts["closure"]["semantics"] = semantics
            facts["semantics_problems"] = list(bsc.semantics_gate_problems(semantics))
            facts["closure"]["internal_obligations_open"] = facts["derived_counts"].get("internal_obligations_open")
            # *** AND THE GENERATOR'S OWN SEMANTIC GATE PROBLEMS ARE CARRIED AS NAMED PROBLEMS. ***
            #
            # *A DISCHARGED obligation with no authored `structured_discharge` is a terminal claim the instrument cannot
            # measure; the generator names it in `semantics_gate_problems`, and the manifest must reproduce that
            # refusal rather than hash a document whose own instrument refuseth it.*
            for p in facts["semantics_problems"]:
                facts["problems"].append(f"structured semantics: {p}")
                facts["closure"]["problems"].append(f"structured semantics: {p}")
        except Exception as exc:  # noqa: BLE001
            facts["problems"].append(f"the structured counts could not be derived: {type(exc).__name__}: {exc}")
    return facts


def external_evidence_facts(base: Path = ROOT, *, blockers_path: Path | None = None,
                            gates_status_path: Path | None = None,
                            proof_dir: Path | None = None) -> dict:
    """The external/historical identities the manifest binds.

    *External claims are recorded by IDENTITY and DIGEST -- the register's own id, its declared class and status --
    and a claim that is absent is recorded as absent, never inferred green. The release-proof block nameth the
    interface it consumes; when that interface is not importable the block sayeth so and is NOT counted as satisfied.*
    """
    # *** THE BUNDLES ARE RESOLVED UNDER `base`, SO A DISPOSABLE WORKTREE CARRIETH ITS OWN. ***
    blockers_path = blockers_path or (base / "docs/production-readiness/EXTERNAL_BLOCKERS.json")
    gates_status_path = gates_status_path or (base / "docs/production/RELEASE_GATES_STATUS.json")
    proof_dir = proof_dir or (base / "docs/remediation/evidence/board1-release-proof")
    facts: dict = {"blockers": None, "release_gates": None, "historical": [], "release_proof": None,
                   "problems": []}
    rec = artifact_record(blockers_path, base)
    if rec is None:
        facts["problems"].append(f"no external blocker register at {blockers_path}")
    else:
        facts["blockers"] = {"record": rec, "count": None, "statuses": {}}
        try:
            doc = json.loads(blockers_path.read_text(encoding="utf-8"))
            rows = doc.get("blockers") or []
            facts["blockers"]["count"] = len(rows)
            facts["blockers"]["statuses"] = {r.get("id"): r.get("status") for r in rows}
        except ValueError as exc:
            facts["problems"].append(f"the external blocker register is not valid JSON: {exc}")
    grep = artifact_record(gates_status_path, base)
    if grep is None:
        facts["release_gates"] = {"record": None, "note": "no release-gate status register on this host"}
    else:
        facts["release_gates"] = {"record": grep}
        try:
            doc = json.loads(gates_status_path.read_text(encoding="utf-8"))
            gates = doc.get("gates") or []
            facts["release_gates"]["count"] = len(gates)
            facts["release_gates"]["statuses"] = {g.get("id"): g.get("status") for g in gates}
        except ValueError as exc:
            facts["problems"].append(f"the release-gate status register is not valid JSON: {exc}")
    # *** THE HISTORICAL POPULATION IS THE ANCHOR POPULATION. ***
    #
    # *THE DEFECT THIS CLOSES: `historical` was a STATIC tuple naming rc14's path, so a fixture (or a disposable
    # candidate) that registers its own real anchor still reported rc14 as "MISSING" -- and, worse, a manifest could
    # satisfy the historical clause with the digest of a working file while the ANCHOR clause (the git objects) was
    # the only thing that actually preserved the original. So the historical rows are DERIVED from the same anchor
    # specs the anchor block useth: one population, one derivation, and the working digest is an observation.*
    for spec in anchor_specs_for(base):
        rel = spec["path"]
        rec = artifact_record(base / rel, base)
        facts["historical"].append({**(rec or {"path": rel}), "anchor": spec["sha256"]})
    # *** AND THE IMMUTABLE ANCHORS -- THE ORIGINAL OBJECTS, RE-DERIVED FROM GIT. ***
    facts["anchors"] = anchor_facts(base)
    facts["release_proof"] = release_proof_facts(proof_dir, base)
    return facts


def anchor_facts(base: Path = ROOT, *, specs: tuple[dict, ...] | None = None) -> dict:
    """*** THE IMMUTABLE ANCHORS, RE-DERIVED FROM THE GIT OBJECTS THEMSELVES. ***

    *THE DEFECT THIS CLOSES: the historical evidence was only a digest of the WORKING file, so a manifest could
    certify re-hashed bytes as the frozen original, and a re-pointed tag would go unnoticed. Here EVERY identity of the
    anchor is derived from git -- the tag object, the peeled commit, the tree, the direct child, and the BLOB at that
    child -- and the file's own sha256 must equal the immutable value.*

    *An anchor that does not resolve, or whose objects disagree, is a NAMED problem in the returned block; the digest
    of the working file is recorded only as an ADDITIONAL observation, never as the anchor itself.*
    """
    specs = specs if specs is not None else anchor_specs_for(base)
    rows: list[dict] = []
    problems: list[str] = []
    for spec in specs:
        row: dict = {"spec": dict(spec), "tag_object": None, "peeled_commit": None, "tree_sha": None,
                     "blob_sha": None, "blob_sha256": None, "child_ok": None, "working_sha256": None,
                     "problems": []}
        ident = tag_identity(spec["tag"], cwd=base)
        if not ident.get("exists"):
            row["problems"].append(f"the anchor tag {spec['tag']!r} does not resolve -- an unreadable anchor is not "
                                   f"an immutable one")
        else:
            row["tag_object"] = ident.get("tag_object")
            row["peeled_commit"] = ident.get("peeled_commit")
            row["tree_sha"] = ident.get("tree_sha")
            if ident.get("tag_object") != spec["tag_object_sha"]:
                row["problems"].append(f"the anchor tag {spec['tag']!r} now carrieth object "
                                       f"{ident.get('tag_object')}, not {spec['tag_object_sha']} -- *the tag was "
                                       f"RE-POINTED or re-created, so it no longer names the frozen annotation*")
            if ident.get("peeled_commit") != spec["peeled_commit"]:
                row["problems"].append(f"the anchor tag {spec['tag']!r} peels to {ident.get('peeled_commit')}, not "
                                       f"{spec['peeled_commit']} -- a moved tag is not the frozen candidate")
            if ident.get("tree_sha") != spec["tree_sha"]:
                row["problems"].append(f"the anchor tag {spec['tag']!r} carrieth tree {ident.get('tree_sha')}, not "
                                       f"{spec['tree_sha']}")
            # *** THE CHILD IS THE ONLY COMMIT THAT CARRIETH THE FILE. ***
            child_check = _git("rev-parse", f"{spec['child']}", cwd=base)
            if child_check.returncode != 0:
                row["child_ok"] = False
                row["problems"].append(f"the anchor child commit {spec['child']} does not resolve -- *the original "
                                       f"attestation exists ONLY on the candidate's direct child, so an unresolvable "
                                       f"child means the anchor cannot be re-derived*")
            else:
                row["child_ok"] = True
                parent = _git("rev-parse", f"{spec['child']}^1", cwd=base).stdout.strip()
                if parent != spec["peeled_commit"]:
                    row["problems"].append(f"the anchor child {spec['child']} carrieth parent {parent}, not the "
                                           f"candidate {spec['peeled_commit']} -- *the attestation must be the "
                                           f"candidate's DIRECT child, not a descendant on some other road*")
            # *** THE BLOB SHA AND ITS BYTES, FROM GIT -- NEVER FROM THE WORKING TREE. ***
            blob = _git("rev-parse", f"{spec['child']}:{spec['path']}", cwd=base)
            if blob.returncode != 0:
                row["problems"].append(f"the anchor child {spec['child']} carrieth no {spec['path']} at all")
            else:
                row["blob_sha"] = blob.stdout.strip()
                if row["blob_sha"] != spec["blob_sha"]:
                    row["problems"].append(f"{spec['path']} at {spec['child']} carrieth blob {row['blob_sha']}, not "
                                           f"{spec['blob_sha']} -- *the anchored attestation was REWRITTEN*")
                content = _git("cat-file", "blob", spec["blob_sha"], cwd=base)
                if content.returncode != 0:
                    row["problems"].append(f"the anchor blob {spec['blob_sha']} could not be read")
                else:
                    digest = sha256_bytes(content.stdout.encode("utf-8"))
                    row["blob_sha256"] = digest
                    if digest != spec["sha256"]:
                        row["problems"].append(f"the anchor blob {spec['blob_sha']} carrieth sha256 {digest}, not "
                                               f"{spec['sha256']} -- *the attestation bytes were RE-HASHED by some "
                                               f"later edit*")
            # *** THE TAGGED COMMIT C, WHICH DOES *NOT* CARRY THE ORIGINAL FILE -- THE MEASURED ASYMMETRY. ***
            at_c = _git("rev-parse", f"{spec['peeled_commit']}:{spec['path']}", cwd=base)
            row["tagged_commit_carries_file"] = at_c.returncode == 0
            if spec.get("file_absent_at_tag_commit") and at_c.returncode == 0:
                row["problems"].append(f"the tagged commit {spec['peeled_commit']} carrieth {spec['path']}, but the "
                                       f"original attestation exists ONLY on the direct child {spec['child']} -- *a "
                                       f"file placed at the tagged commit is not the original attestation, and "
                                       f"treating it as one re-hashes history*")
        working = base / spec["path"]
        row["working_sha256"] = sha256_file(working)
        # *** THE WORKING COPY IS AN OBSERVATION, NOT THE ANCHOR. ***
        #
        # *MEASURED: the ORIGINAL rc14 attestation exists only on the candidate's DIRECT CHILD `A14`; the tagged
        # commit `C` does NOT carry it, so a CLEAN WORKTREE AT `C` -- which is exactly where a phase-3 manifest is
        # emitted -- legitimately has no such file. Requiring its presence would red the correct run.* **The ANCHOR is
        # the Git blob and its sha256. When the working file IS present it must equal the anchored blob, so an edit in
        # the work tree is still caught; when it is absent the row records that, and no claim is inferred from
        # absence.**
        if row["working_sha256"] is not None and row["blob_sha256"] \
                and row["working_sha256"] != row["blob_sha256"]:
            row["problems"].append(f"the working copy {spec['path']} carrieth sha256 {row['working_sha256']}, not the "
                                   f"anchored blob's {row['blob_sha256']} -- *the historical artifact was edited in "
                                   f"the work tree, and a digest of those bytes would certify the EDIT*")
        rows.append(row)
        problems.extend(row["problems"])
    return {"anchors": rows, "problems": problems, "count": len(rows)}


def _anchor_problems(block: dict, *, base: Path) -> list[str]:
    """Re-derive every anchor from git, refusing a re-pointed tag, a rewritten blob or a re-hashed file."""
    problems: list[str] = []
    if not isinstance(block, dict) or not block.get("anchors"):
        return ["the manifest carrieth NO immutable-anchor block -- *historical evidence recorded only as the digest "
                "of a working file is a digest of whatever is there now, not an anchor to the original objects*"]
    live = anchor_facts(base)
    live_by_path = {r["spec"]["path"]: r for r in live["anchors"]}
    for row in block.get("anchors") or []:
        spec = row.get("spec") or {}
        path = spec.get("path")
        if path not in live_by_path:
            problems.append(f"the manifest binds anchor {path!r} which this repository does not define")
            continue
        for p in row.get("problems") or []:
            problems.append(f"anchor {path}: {p}")
        # *** AND THE LIVE OBJECTS ARE COMPARED, SO A MANIFEST THAT OMITTED A PROBLEM IS STILL CAUGHT. ***
        actual = live_by_path[path]
        for key in ("tag_object", "peeled_commit", "tree_sha", "blob_sha", "blob_sha256", "child_ok"):
            if row.get(key) != actual.get(key):
                problems.append(f"anchor {path}: the manifest stateth {key}={row.get(key)!r} but the repository "
                                f"deriveth {actual.get(key)!r}")
        if spec != actual.get("spec"):
            problems.append(f"anchor {path}: the manifest's recorded spec differs from the repository's immutable "
                            f"rc14 specification")
        # *** AND THE LIVE DERIVATION'S OWN PROBLEMS ARE EMITTED, NOT ONLY COMPARED AGAINST. ***
        #
        # *THE DEFECT THIS CLOSES: a manifest whose recorded row AGREED with the live row's FIELDS could still hide a
        # live problem -- e.g. a re-pointed tag whose `tag_object` field the manifest recorded faithfully. The live
        # row carrieth the refusal that no field comparison would surface.*
        for p in actual.get("problems") or []:
            msg = f"anchor {path}: {p}"
            if msg not in problems:
                problems.append(msg)
    return problems


def release_proof_facts(proof_dir: Path, base: Path = ROOT) -> dict:
    """The exact-candidate release evidence supplied by the supply-chain owner, through its named interface.

    *THE CONSUMER SIDE OF ONE INTERFACE: `tools/supplychain/verify_release_proof.py:verify_release_proof(document)
    -> list[str]`. The records live one-per-attempt under `docs/remediation/evidence/board1-release-proof/`; each is
    validated by THAT owner's verifier, bound to a candidate SHA/tag and to its own document digest. When the
    interface is not importable the block is explicitly `available: false` -- so an absent interface is VISIBLE and
    can never be counted as satisfied evidence.*
    """
    # *** THE EXACT-CANDIDATE RELEASE PROOF IS MANDATORY AT FULL-C BUILD. ***
    #
    # *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: the manifest used to RECORD the release block's availability
    # (`required: false`) on the theory that the exact-candidate release run "does not exist until `C` is pushed". **But
    # the terminal C job CAPTURETH that proof BEFORE it emitteth this manifest, so a full-C manifest without a
    # candidate-bound release proof is an incomplete candidate -- and a `required: false` default was the weak Phase-3
    # shape that let a proof-less manifest stand.*** *The block is returned `required: true`; `check_manifest` ALWAYS
    # requireth the population (there is no boolean opt-out), so an absent/incomplete population REFUSES.*
    block: dict = {"interface": RELEASE_PROOF_INTERFACE, "available": False, "required": True,
                   "records": [], "problems": []}
    vrp = None
    # *** THE INTERFACE LIVES IN THE TOOL TREE (`tools/supplychain/`), NOT IN THE CANDIDATE TREE. *** *So the running
    # tool's own `ROOT` is searched too -- otherwise a fixture or a downloaded-tree validation could not import the
    # ONE named interface and would mis-read an importable authority as absent.*
    for root in (str(base), str(base / "tools" / "supplychain"),
                 str(ROOT), str(ROOT / "tools" / "supplychain")):
        if root not in sys.path:
            sys.path.insert(0, root)
    try:
        from tools.supplychain.verify_release_proof import verify_release_proof as _v  # noqa: PLC0415
        vrp = _v
    except Exception:  # noqa: BLE001
        try:
            import importlib  # noqa: PLC0415
            vrp = getattr(importlib.import_module("verify_release_proof"), "verify_release_proof", None)
        except Exception:  # noqa: BLE001 - an absent interface is recorded, not fatal here
            vrp = None
    block["available"] = callable(vrp)
    if callable(vrp):
        block["module"] = getattr(vrp, "__module__", None)
    if proof_dir.is_dir():
        for path in sorted(proof_dir.glob("*.json")):
            rec = artifact_record(path, base)
            entry = {"record": rec, "document_sha256": None, "candidate": None,
                     "run_id": None, "run_attempt": None, "problems": []}
            try:
                doc = json.loads(path.read_text(encoding="utf-8"))
            except ValueError as exc:
                entry["problems"].append(f"not valid JSON: {exc}")
                block["records"].append(entry)
                continue
            entry["document_sha256"] = doc.get("document_sha256")
            entry["candidate"] = doc.get("candidate")
            # *** THE OWNER'S SCHEMA-2 DOCUMENT CARRIETH `run:{id,attempt}` AND `candidate:{sha,tree_sha}` -- NO
            # TOP-LEVEL run_id/run_attempt AND NO REQUIRED candidate.tag. ***
            #
            # *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: this reader looked for nonexistent top-level
            # `doc.run_id`/`doc.run_attempt` (so the bound keys were None and post-attestation replay refused) and the
            # checks below required a `candidate.tag` the owner never emits.* **So the keys are read from
            # `doc['run']['id']`/`['attempt']`, the exact SHA and TREE are what bind, and the tag is checked ONLY when
            # present.** *The sealed document is never rewritten.*
            run = doc.get("run") or {}
            entry["run_id"] = run.get("id")
            entry["run_attempt"] = run.get("attempt")
            body = {k: v for k, v in doc.items() if k != "document_sha256"}
            recomputed = sha256_bytes(json.dumps(body, sort_keys=True, separators=(",", ":")).encode("utf-8"))
            if entry["document_sha256"] != recomputed:
                entry["problems"].append(
                    "document_sha256 does not recompute over the record body (tampered or hand-written)")
            if block["available"]:
                try:
                    entry["problems"].extend(list(vrp(doc) or []))
                except Exception as exc:  # noqa: BLE001
                    entry["problems"].append(f"the release-proof verifier raised {type(exc).__name__}: {exc}")
            else:
                entry["problems"].append("the release-proof interface is not importable on this host")
            block["records"].append(entry)
    return block


def _load_release_verifier():
    """The supply-chain owner's verifier, imported through the ONE named interface."""
    vrp = None
    for root in (str(ROOT), str(ROOT / "tools" / "supplychain")):
        if root not in sys.path:
            sys.path.insert(0, root)
    try:
        from tools.supplychain.verify_release_proof import verify_release_proof as _v  # noqa: PLC0415
        return _v
    except Exception:  # noqa: BLE001
        try:
            import importlib  # noqa: PLC0415
            return getattr(importlib.import_module("verify_release_proof"), "verify_release_proof", None)
        except Exception:  # noqa: BLE001
            return None


def _load_release_authenticator():
    """Import the owner's MANDATORY hosted authenticator `RP.authenticate_release_proof` (via the ONE interface).

    *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: `RP.seal` is an integrity seal, NOT authentication -- a self-sealed
    JSON passed freeze/the shared reader because nothing re-fetched the claimed hosted run. **So the consumer now calls
    the owner's `authenticate_release_proof`, which structurally checks the document, re-captures the claimed host run,
    recomputes the canonical body digest and REQUIRES the exact candidate TREE.*** *An unimportable authenticator is a
    NAMED refusal, never silence.*
    """
    for root in (str(ROOT), str(ROOT / "tools" / "supplychain")):
        if root not in sys.path:
            sys.path.insert(0, root)
    try:
        from tools.supplychain.verify_release_proof import authenticate_release_proof as _a  # noqa: PLC0415
        return _a
    except Exception:  # noqa: BLE001
        try:
            import importlib  # noqa: PLC0415
            return getattr(importlib.import_module("verify_release_proof"),
                           "authenticate_release_proof", None)
        except Exception:  # noqa: BLE001
            return None


def verify_release_record(doc: dict, *, candidate_sha: str | None, candidate_tree_sha: str | None = None,
                          repo: str | None = None) -> list[str]:
    """Re-verify ONE release record MANDATORILY against the hosted run, bound to the candidate SHA AND TREE.

    *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: `verify_release_proof` (the local structural reader) accepteth a
    SELF-SEALED document, so a hand-written record passed the freeze and the shared reader -- the seal is integrity, not
    authentication.* **So this consumer REQUIRES the owner's `RP.authenticate_release_proof(document, repo=, 
    candidate_sha=, candidate_tree_sha=)`: it re-fetches the claimed hosted run, recomputes the canonical body digest and
    requires the proof's `candidate.tree_sha` to equal the exact candidate tree.** *The trusted `repo` cometh from the
    canonical origin/run, never from the proof's own claim; the record's `document_sha256` is recomputed first, so an
    edited file is refused before any network read. `verify_release_proof` is still run as the cheap structural
    pre-check.*
    """
    problems: list[str] = []
    body = {k: v for k, v in doc.items() if k != "document_sha256"}
    recomputed = sha256_bytes(json.dumps(body, sort_keys=True, separators=(",", ":")).encode("utf-8"))
    if doc.get("document_sha256") != recomputed:
        problems.append("document_sha256 does not recompute over the record body (tampered or hand-written)")
    verifier = _load_release_verifier()
    if not callable(verifier):
        problems.append(f"the release-proof interface {RELEASE_PROOF_INTERFACE!r} is not importable")
    else:
        try:
            problems.extend(list(verifier(doc) or []))
        except Exception as exc:  # noqa: BLE001
            problems.append(f"the release-proof verifier raised {type(exc).__name__}: {exc}")
    cand = doc.get("candidate") or {}
    if candidate_sha and str(cand.get("sha") or "").lower() != candidate_sha.lower():
        problems.append(f"the record bindeth candidate {cand.get('sha')!r}, not {candidate_sha!r}")
    if candidate_tree_sha and str(cand.get("tree_sha") or "") != candidate_tree_sha:
        problems.append(f"the record bindeth candidate tree {cand.get('tree_sha')!r}, not {candidate_tree_sha!r} -- "
                        f"*the TREE is a first-class binding, never the tag*")
    # *** AND THE MANDATORY HOSTED AUTHENTICATION -- A SELF-SEALED DOCUMENT IS NOT EVIDENCE. ***
    authenticator = _load_release_authenticator()
    if not callable(authenticator):
        problems.append("the release-proof AUTHENTICATOR `authenticate_release_proof` is not importable -- *a "
                        "self-sealed document cannot be trusted, so a missing authenticator REFUSES*")
        return problems
    if not candidate_sha or not candidate_tree_sha:
        problems.append("the caller supplied no candidate SHA/TREE to authenticate the release proof against")
        return problems
    try:
        problems.extend(list(authenticator(doc, repo=repo, candidate_sha=candidate_sha,
                                           candidate_tree_sha=candidate_tree_sha) or []))
    except Exception as exc:  # noqa: BLE001
        problems.append(f"the release-proof authenticator raised {type(exc).__name__}: {exc}")
    return problems


def _release_population_problems(block: dict, *, candidate_sha: str | None,
                                 candidate_tag: str | None,
                                 candidate_tree_sha: str | None = None) -> list[str]:
    """*** THE POPULATION/BINDING HALF -- NO REMOTE AUTHENTICATION. *** *Private: the shared reader useth it to judge
    the block's shape before it runneth the ONE full per-record authority itself. It is NEVER a public admission path;
    `release_evidence_problems` (below) always addeth the mandatory hosted authentication.*
    """
    problems: list[str] = []
    if not isinstance(block, dict):
        return ["the manifest carrieth NO release-evidence block -- external release proof must be recorded or "
                "explicitly marked unavailable, never omitted"]
    # *** MANDATORY LAW: THERE IS NO `required` BOOLEAN AND NO OPT-OUT. *** *An absent interface or an empty record
    # population REFUSETH, always: the exact-candidate release proof is mandatory at every admission.*
    if not block.get("available"):
        problems.append(f"exact-candidate release evidence is REQUIRED but the interface "
                        f"{block.get('interface')!r} is not importable on this host")
    if not block.get("records"):
        problems.append("exact-candidate release evidence is REQUIRED but no record is bound")
    for entry in block.get("records") or []:
        rec = entry.get("record") or {}
        name = rec.get("path") or "<unnamed record>"
        for p in entry.get("problems") or []:
            problems.append(f"release proof {name}: {p}")
        cand = entry.get("candidate") or {}
        if candidate_sha and str(cand.get("sha") or "").lower() != candidate_sha.lower():
            problems.append(f"release proof {name} bindeth candidate sha {cand.get('sha')!r}, not the candidate "
                            f"{candidate_sha!r}")
        # *** THE TAG IS CHECKED ONLY WHEN THE OWNER'S PROOF ACTUALLY CARRITH ONE. ***
        if candidate_tag and cand.get("tag") is not None and cand.get("tag") != candidate_tag:
            problems.append(f"release proof {name} bindeth candidate tag {cand.get('tag')!r}, not {candidate_tag!r}")
        if candidate_tree_sha and cand.get("tree_sha") and str(cand.get("tree_sha")) != candidate_tree_sha:
            problems.append(f"release proof {name} bindeth candidate tree {cand.get('tree_sha')!r}, not the candidate "
                            f"tree {candidate_tree_sha!r}")
        if cand.get("tree_sha"):
            tree = str(cand.get("tree_sha"))
            if len(tree) != 40 or any(c not in "0123456789abcdef" for c in tree.lower()):
                problems.append(f"release proof {name} carrieth a malformed candidate.tree_sha {tree!r}")
    return problems


def release_evidence_problems(block: dict, *, candidate_sha: str | None,
                              candidate_tag: str | None,
                              candidate_tree_sha: str | None = None,
                              repo: str | None = None) -> list[str]:
    """A manifest's release-evidence block must ACCOUNT for itself -- present, verified, candidate-bound AND
    **hosted-authenticated**.

    *** IT IS MANDATORY LAW: THERE IS NO `required` BOOLEAN. *** *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: an
    `authenticate=False`/`required=False` shortcut would be a public weaker path -- the same escape-hatch shape as the
    removed `terminal=False`.* **So the block must always be present with a non-empty record population, and every
    record is run through `verify_release_record`, which performeth the MANDATORY hosted authentication
    (`RP.authenticate_release_proof`) bound to the exact candidate SHA and TREE.** *A caller that has ALREADY
    authenticated the records (the shared reader) uses the PRIVATE `_release_population_problems` for the block shape
    and runneth `verify_release_record` itself -- so the remote recapture happens exactly once and no public boolean
    can skip it.*
    """
    problems = _release_population_problems(block, candidate_sha=candidate_sha,
                                            candidate_tag=candidate_tag,
                                            candidate_tree_sha=candidate_tree_sha)
    if not isinstance(block, dict):
        return problems
    for entry in block.get("records") or []:
        rec = entry.get("record") or {}
        name = rec.get("path") or "<unnamed record>"
        disk = Path(rec.get("path", ""))
        disk = disk if disk.is_absolute() else (ROOT / disk)
        if not disk.is_file():
            continue
        try:
            doc = json.loads(disk.read_text(encoding="utf-8"))
        except ValueError as exc:
            problems.append(f"release proof {name} is not valid JSON: {exc}")
        else:
            for p in verify_release_record(doc, candidate_sha=candidate_sha,
                                           candidate_tree_sha=candidate_tree_sha, repo=repo):
                problems.append(f"release proof {name}: {p}")
    return problems


# ----------------------------------------------------------------------------------------------------------------
# the builder -- reached ONLY after a full, required, accounted, zero-exit gate run
# ----------------------------------------------------------------------------------------------------------------
def _now_utc() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _host_identity() -> dict:
    """The runner's identity: repository slug, run id/attempt, job, and the commit/ref GitHub supplied.

    *These come from the environment the HOST sets (`GITHUB_*`), so on a runner they are facts the workflow did not
    hand to the checker; on a workstation they are ABSENT and recorded as absent, never fabricated.*
    """
    return {
        "repository": os.environ.get("GITHUB_REPOSITORY") or None,
        "server_url": os.environ.get("GITHUB_SERVER_URL") or None,
        "run_id": os.environ.get("GITHUB_RUN_ID") or None,
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT") or None,
        "job": os.environ.get("GITHUB_JOB") or None,
        "workflow": os.environ.get("GITHUB_WORKFLOW") or None,
        "event_name": os.environ.get("GITHUB_EVENT_NAME") or None,
        "ref": os.environ.get("GITHUB_REF") or None,
        "sha": os.environ.get("GITHUB_SHA") or None,
        "runner_os": os.environ.get("RUNNER_OS") or None,
    }


def build_manifest(*, gate_facts: list[dict], base: Path = ROOT, candidate: dict | None = None,
                   campaign: dict | None = None, lanes: list[dict] | None = None,
                   closure: dict | None = None, external: dict | None = None,
                   clean_start: dict | None = None, clean_end: dict | None = None,
                   campaign_dir_override: Path | None = None,
                   lane_digest_fn=None, lane_problems_fn=None, lane_roster_fn=None,
                   ledger_ids_fn=None, tested_inputs_fn=None,
                   evidence_root: Path | None = None, rebind=None, frozen_rebind=None) -> dict:
    """Assemble the manifest document from already-gathered facts.

    *** IT REFUSES TO ASSEMBLE A PASS FROM AN INCOMPLETE RUN. *** *A missing/`UNREADABLE` gate, or any required gate
    with a non-zero exit, raises `ManifestRefused` -- so a partial run cannot EMIT a manifest at all, rather than
    emitting one a reader must remember not to trust.*
    """
    gate_rows = []
    for fact in gate_facts:
        row = {"id": fact["id"], "label": fact.get("label"), "argv": fact.get("argv"),
               "rc": fact.get("rc"), "log": fact.get("log"), "verdict": fact.get("verdict", "MISSING"),
               # *** THE GATE'S PROVENANCE IS PART OF ITS ROW. *** *`live-process` means the exit code came from the
               # child process this run spawned; `downloaded-unauthenticated` means the bytes came from a directory.*
               "proof": fact.get("proof", "live-process"),
               "argv_source": fact.get("argv_source")}
        gate_rows.append(row)
    accounted = [r for r in gate_rows if r["verdict"] in ("PASS", "FAIL")]
    missing = [r["id"] for r in gate_rows if r["verdict"] == "MISSING"]
    unreadable = [r["id"] for r in gate_rows if r["verdict"] == "UNREADABLE"]
    nonzero = [r["id"] for r in gate_rows if r["verdict"] == "FAIL"]
    unlogged = [r["id"] for r in gate_rows if r["verdict"] == "PASS" and not r.get("log")]
    if missing or unreadable or nonzero or unlogged:
        raise ManifestRefused(_accounting_problems(missing, unreadable, nonzero, unlogged))
    # *** AND A PASS MANIFEST MAY NOT REST ON CALLER-CREATED ARTIFACTS. ***
    #
    # *A directory of `<id>.rc` files is bytes ANYTHING can write; eleven zeroes authenticate the writer's word, not
    # the gates. So only a LIVE run may emit, and this refusal is by name.*
    downloaded = [r["id"] for r in gate_rows if r.get("proof") != "live-process"]
    if downloaded:
        raise ManifestRefused([
            "THE GATE FACTS CAME FROM DOWNLOADED FILES, SO NO PASS MANIFEST MAY BE EMITTED: "
            f"{downloaded} -- *a `.rc` file is caller-created bytes, and a manifest that hashed what the caller "
            f"supplied would authenticate the caller rather than the gates. The `--gate-dir` road is a DIAGNOSTIC "
            f"road; a PASS manifest is emitted only by `board1 verify --manifest-out`, whose exit codes came from "
            f"the child processes it spawned.*"])
    campaign = campaign or {}
    lanes = lanes or []
    closure = closure or {}
    external = external or {}
    doc = {
        "schema": MANIFEST_SCHEMA,
        "kind": MANIFEST_KIND,
        "started_utc": (clean_start or {}).get("measured_utc") or _now_utc(),
        "completed_utc": _now_utc(),
        "producer": {"tool": "ci/check_board1_manifest.py",
                     "tool_sha256": sha256_file(Path(__file__).resolve()),
                     "host": _host_identity()},
        "candidate": candidate or {},
        "clean_start": clean_start or {},
        "clean_end": clean_end or {},
        "gates": {
            "required_ids": list(REQUIRED_GATE_IDS),
            "rows": gate_rows,
            "population": {"required": len(REQUIRED_GATE_IDS), "accounted": len(accounted),
                           "missing": missing, "unreadable": unreadable, "nonzero": nonzero,
                           "unlogged": unlogged},
        },
        "campaign": campaign,
        "lanes": lanes,
        "closure": closure.get("closure"),
        "ledger": closure.get("ledger"),
        "derived_counts": closure.get("derived_counts"),
        "external_evidence": external,
        "verdict": "PASS",
    }
    problems = check_manifest(doc, base=base, require_candidate=True,
                              campaign_dir_override=campaign_dir_override,
                              lane_digest_fn=lane_digest_fn, lane_problems_fn=lane_problems_fn,
                              lane_roster_fn=lane_roster_fn,
                              ledger_ids_fn=ledger_ids_fn, tested_inputs_fn=tested_inputs_fn,
                              evidence_root=evidence_root, rebind=rebind, frozen_rebind=frozen_rebind)
    if problems:
        raise ManifestRefused(problems)
    return doc


def _accounting_problems(missing, unreadable, nonzero, unlogged) -> list[str]:
    out = ["THE RUN IS INCOMPLETE, SO NO MANIFEST MAY BE EMITTED -- *a manifest that omitted an unaccounted gate "
           "would be a partial result wearing a complete one's shape.*"]
    if missing:
        out.append(f"required gate(s) with NO artifact at all: {missing}")
    if unreadable:
        out.append(f"required gate(s) whose exit code could not be read: {unreadable}")
    if nonzero:
        out.append(f"required gate(s) that returned NON-ZERO: {nonzero}")
    if unlogged:
        out.append(f"required gate(s) marked PASS with NO log artifact: {unlogged}")
    return out


class _StubClosure:
    """A stand-in for the closure generator whose counts are FIXED -- used only to isolate the closure-law refusal.

    *Without it, a manifest carrying open obligations would ALSO disagree with the ledger's derivation, and the case
    would pass for the wrong reason: the point of the case is that the LAW bites when the counts AGREE and are
    non-zero.*
    """

    def __init__(self, counts: dict):
        self._counts = counts

    def build(self, _ledger):
        return {}

    def load(self, _path):
        return {}

    def counts(self, _closure):
        return dict(self._counts)


class ManifestRefused(Exception):
    """Raised when a run's facts are insufficient to emit a PASS manifest."""

    def __init__(self, problems: list[str]):
        super().__init__("; ".join(problems))
        self.problems = problems


# ----------------------------------------------------------------------------------------------------------------
# the validator -- read-only, re-derives every claim
# ----------------------------------------------------------------------------------------------------------------
def _rebind_artifact_path(rec: dict, rebind: Path | None, base: Path) -> Path:
    """Map a lane artifact/sidecar record to a reader-side path, PRESERVING its recorded nesting.

    *** THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: flattening `root/basename` collapses the real workflow layout
    (`android/<module>/build/test-results/<task>/X.xml`), loses the semantic recheck and mis-joins duplicate basenames.
    *** *When a record carrieth an evidence-RELATIVE identity (`rel`, recorded by `lane_facts`), it is joined under the
    reader's evidence root preserving every path component; otherwise the recorded path is used against `base`. A
    `dir` record (an `.xcresult` bundle) is treated the same way -- a directory is a single artifact whose subtree is
    re-digested.*
    """
    if rebind is not None:
        rel = rec.get("rel") or rec.get("path")
        return Path(rebind) / rel
    disk = Path(rec.get("path", ""))
    return disk if disk.is_absolute() else (base / disk)


def _manifest_rebind_roots(rebind) -> dict:
    """Resolve the reader-side rebind mapping for the manifest validator, importing the ONE helper from the binding
    authority (never restating its class names here)."""
    if not rebind:
        return {}
    sys.path.insert(0, str(ROOT / "ci"))
    import check_candidate_binding as _ccb  # noqa: PLC0415 - the ONE rebind authority
    return _ccb._rebind_roots(rebind)


def _frozen_rebind_map(frozen_rebind) -> dict | None:
    """Normalize the DISTINCT frozen-C relocation context (the four --frozen-* roots) for successor authentication.

    *Kept SEPARATE from the fresh-A `rebind`: passing the fresh-A roots would remap the frozen-C records to A's
    directories, which is wrong. The map is resolved through the ONE rebind authority.*
    """
    if not frozen_rebind:
        return None
    sys.path.insert(0, str(ROOT / "ci"))
    import check_candidate_binding as _ccb  # noqa: PLC0415 - the ONE rebind authority
    return _ccb._rebind_roots(frozen_rebind) or None


def _ccb_attest_exclusion_policy_delta(candidate: str, successor: str, att_rel: str, base: Path) -> list[str]:
    """The relation proof over the FIXTURE's own git, so a case can exercise the delta law without the process-global
    `ccb.ROOT`. *Production callers use `ccb.executing_successor_problems` (which reads the real repository); this
    helper readeth the candidate's delta from `base` for the selftest.*"""
    sys.path.insert(0, str(ROOT / "ci"))
    import check_candidate_binding as _ccb  # noqa: PLC0415 - the ONE successor-policy authority
    proc = _git("diff", "--name-only", f"{candidate}..{successor}", cwd=base)
    if proc.returncode != 0:
        return [f"<fixture-diff-failed: {proc.stderr.strip()[:120]}>"]
    fixture_delta = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip()]
    carried = _git("cat-file", "-e", f"{candidate}:{att_rel}", cwd=base).returncode == 0
    return _ccb.attest_exclusion_policy(future_path=att_rel, candidate=candidate, successor=successor,
                                        delta=fixture_delta, attestation=att_rel,
                                        candidate_carries_future=carried)


def check_manifest(doc: dict, *, base: Path = ROOT, require_candidate: bool = True,
                   ledger_ids_fn=None, tested_inputs_fn=None,
                   lane_digest_fn=lane_digest, lane_problems_fn=None, lane_roster_fn=lane_roster,
                   _unused=None,
                   campaign_dir_override: Path | None = None,
                   evidence_root: Path | None = None,
                   rebind=None, strict_candidate: str | None = None,
                   frozen_rebind=None) -> list[str]:
    """*** RE-DERIVE EVERY CLAIM AN MANIFEST MAKES. EMPTY LIST = VALID. ***

    *It WRITES NOTHING and takes no timestamp, so it is safe on a successor commit and safe to run twice. Every
    refusal nameth the exact field it refused.*

    *** `evidence_root` AND `rebind` LET A FRESH READER JUDGE THE DOWNLOADED BYTES. *** *The hosted runner's gate logs,
    campaign tree and lane results live under its scratch root; `evidence_root` points the lane derivations at the
    reader's downloaded copy while the SOURCE census still cometh from `base`, and `rebind` maps the gate-log,
    campaign and release-proof records by identity -- each still required to carry the ORIGINAL bound digest.*
    """
    problems: list[str] = []
    if not isinstance(doc, dict):
        return ["the manifest is not a JSON object"]
    # *** RESOLVE THE READER-SIDE REBIND ONCE, FROM THE ONE REBIND HELPERS IN THE BINDING AUTHORITY. ***
    rebind_roots = _manifest_rebind_roots(rebind)
    if doc.get("kind") != MANIFEST_KIND:
        problems.append(f"the manifest's kind is {doc.get('kind')!r}, not {MANIFEST_KIND!r}")
    if doc.get("schema") != MANIFEST_SCHEMA:
        problems.append(f"the manifest's schema is {doc.get('schema')!r}, not {MANIFEST_SCHEMA}")

    # ---- candidate: exact SHA and TREE ----
    cand = doc.get("candidate") or {}
    sha, tree = cand.get("sha"), cand.get("tree_sha")
    if require_candidate:
        if cand.get("sha_source") not in ("workdir", "tag"):
            problems.append(f"candidate.sha_source is {cand.get('sha_source')!r} -- *the manifest must say WHICH "
                            f"revision its gates executed: the working HEAD it derived, or a tag's peel*")
        if not _is_full_sha(sha):
            problems.append(f"candidate.sha {sha!r} is not a full 40-hex commit -- a candidate binding must name the "
                            f"exact commit it froze")
        if not _is_full_sha(tree):
            problems.append(f"candidate.tree_sha {tree!r} is not a full 40-hex tree -- *an unstaked tree is an "
                            f"unfalsifiable binding: the manifest would name a commit whose bytes nobody stated*")
    tag = cand.get("tag")
    tag_state = cand.get("tag_state")           # "annotated" (phase 4) or "provisional" (phase 3)
    if _is_full_sha(sha):
        # *** THE TREE IS DERIVED FROM THE COMMIT ITSELF, NEVER TAKEN ON THE MANIFEST'S WORD. ***
        #
        # *THE DEFECT THIS CLOSES: the tree was only checked for HEXADECIMAL SHAPE, so `tree_sha = "0"*40` passed. A
        # candidate binding whose tree nobody derived is unfalsifiable -- the reader has no bytes to compare.*
        resolved = _git("rev-parse", f"{sha}^{{tree}}", cwd=base)
        if resolved.returncode != 0:
            problems.append(f"candidate.sha {sha} DOES NOT RESOLVE to a commit in this repository -- a binding to an "
                            f"unknown commit is no binding")
        else:
            actual_tree = resolved.stdout.strip()
            if actual_tree != tree:
                problems.append(f"candidate.sha {sha} carrieth tree {actual_tree} but the manifest stateth tree "
                                f"{tree} -- *the tree is DERIVED from the commit, so a stated one that disagrees is "
                                f"describing other bytes*")
    if tag:
        ident = tag_identity(tag, cwd=base)
        if not ident.get("exists"):
            # *** PHASE 3 IS THE HONEST WINDOW IN WHICH THE TAG DOES NOT YET EXIST. ***
            #
            # *The candidate commit `C` must exist BEFORE the tag can point at it, so a full verification run at `C`
            # legitimately names an intended-but-uncreated ref.* **It is accepted ONLY when the manifest SAYETH it is
            # provisional AND its SHA/tree were derived from the executing HEAD; phase 4 then requirith the real
            # annotated tag to peel to exactly `C`.**
            if tag_state != "provisional":
                problems.append(f"candidate.tag {tag!r} does not resolve to a commit and the manifest does not mark "
                                f"it `provisional` -- a freeze binds an EXISTING annotated tag")
        else:
            if not ident.get("annotated"):
                problems.append(f"candidate.tag {tag!r} is LIGHTWEIGHT -- it carrieth no tag object and can be "
                                f"re-pointed without trace")
            if _is_full_sha(sha) and ident.get("peeled_commit") != sha:
                problems.append(f"candidate.tag {tag!r} peels to {ident.get('peeled_commit')} but the manifest "
                                f"stateth sha {sha} -- a binding whose two halves disagree")
            if tree and ident.get("tree_sha") != tree:
                problems.append(f"candidate.tag {tag!r} carrieth tree {ident.get('tree_sha')} but the manifest "
                                f"stateth tree {tree}")

    # ---- clean start / clean end ----
    for label in ("clean_start", "clean_end"):
        block = doc.get(label) or {}
        if block.get("status_error"):
            problems.append(f"{label}: `git status` FAILED ({block['status_error']}) -- an unmeasurable tree is not a "
                            f"clean one")
        if not block.get("ok"):
            problems.append(f"{label}.ok is {block.get('ok')!r} -- a candidate-bound run must begin and end with a "
                            f"CLEAN git status")
        if block.get("tracked"):
            problems.append(f"{label} carrieth {len(block['tracked'])} uncommitted TRACKED change(s): "
                            f"{block['tracked'][:5]}")
        if block.get("untracked"):
            problems.append(f"{label} carrieth {len(block['untracked'])} UNTRACKED path(s): "
                            f"{block['untracked'][:5]} -- *an untracked file is not a clean status: the bytes a "
                            f"reader would build are not the candidate's. Run from a disposable worktree.*")
        if not block.get("measured_utc"):
            problems.append(f"{label} carrieth no measurement timestamp")

    # *** AND THE GATES MUST HAVE EXECUTED THE CANDIDATE'S OWN COMMIT AND TREE. ***
    #
    # *THE DEFECT THIS CLOSES: the manifest could bind candidate `C` -- derived from a passed `--tag` -- while the
    # gate run executed in a DIFFERENT checkout, and nothing compared the two. **`clean_start` is the pre-gate
    # snapshot, so the executing revision it carrieth must equal the candidate's, and a manifest that recorded no
    # executing revision at all is refused rather than assumed to have run at the candidate.***
    # *** AT THE SUCCESSOR `A`, THE EXECUTING REVISION IS `A` AND THE FROZEN CANDIDATE IS STILL `C`. ***
    #
    # *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: the final-main verification must run the SAME canonical runner
    # FRESHLY on `A`, so the manifest's executing revision is `A` while the frozen candidate remains `C`. **The
    # difference is admitted ONLY when it is the exact attestation-only direct child -- proven from git by the canonical
    # authority `ccb.attest_exclusion_policy` BEFORE any endpoint comparison -- and then BOTH measured execution
    # endpoints (`clean_start` and `clean_end`) are compared against the PROVEN executing `A`, while the frozen `C`
    # stays pinned and start/end drift is still refused.*** *A generic ancestor, a filename prefix, a second changed
    # path, or an unproven relation is refused BY NAME, and the endpoints then fall back to the strict `C` comparison.*
    frozen = cand.get("frozen") or {}
    executing = cand.get("executing") or {}
    proven_a: str | None = None
    # *** IN STRICT-C MODE THE MANIFEST MAY NOT CARRY A SUCCESSOR CLAUSE AT ALL. ***
    #
    # *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: re-entering the successor law while authenticating an embedded
    # `C` manifest would recurse. **So an embedded strict-C manifest carrieth NO `frozen`/`executing` block and is
    # judged by the plain candidate checks below; a successor clause in strict mode is a NAMED refusal.***
    if strict_candidate is not None:
        if frozen or executing:
            problems.append("a STRICT-C manifest carrieth a `frozen`/`executing` successor clause -- *the embedded "
                            "candidate document must describe C alone, with no successor admission inside it*")
        if sha != strict_candidate:
            problems.append(f"a STRICT-C manifest must bind candidate {strict_candidate}, not {sha}")
        # *** AND SUCCESSOR ADMISSION IS SKIPPED ENTIRELY IN STRICT-C MODE -- NO RECURSION. ***
        #
        # *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: the guard appended a refusal but FELL THROUGH into the
        # `if frozen:` branch, which re-invoked `executing_successor_problems` and strict-C validation again -- a
        # malformed embedded manifest could therefore recurse.* **So in strict-C mode the successor branch is SKIPPED:
        # the named refusal above is the whole verdict, and no re-entry occurs.***
        frozen, executing = {}, {}
    if frozen:
        if frozen.get("sha") != sha or frozen.get("tree_sha") != tree:
            problems.append(f"candidate.frozen carrieth {frozen.get('sha')}/{frozen.get('tree_sha')} but the "
                            f"candidate binding is {sha}/{tree} -- the frozen half must be the tag's own peel")
        exec_sha = executing.get("sha")
        if exec_sha and exec_sha != sha:
            sys.path.insert(0, str(ROOT / "ci"))
            import check_candidate_binding as _ccb  # noqa: PLC0415 - the ONE successor-policy authority
            att_rel = executing.get("attestation") or _ccb.FREEZE_ATTESTATION_SUCCESSOR_PATH
            # *** THE RELATION IS ADJUDICATED BY THE ONE SHARED HELPER, WITH THE FROZEN-C RELOCATION CONTEXT. ***
            #
            # *`frozen_rebind` is the DISTINCT frozen-C evidence map, kept SEPARATE from the fresh-A `rebind` -- passing
            # the fresh-A roots would remap the C records to A's directories, which is wrong.*
            rel_problems = _ccb.executing_successor_problems(
                candidate=sha, successor=exec_sha, attestation_path=att_rel,
                rebind=_frozen_rebind_map(frozen_rebind))
            for p in rel_problems:
                problems.append(f"executing-A: {p}")
            if not rel_problems:
                # *ONLY a PROVEN relation admits the A endpoints; an unproven one leaves `proven_a` None so the strict
                # C comparison below still bites.*
                proven_a = exec_sha
                if executing.get("tree_sha") and not _is_full_sha(executing.get("tree_sha")):
                    problems.append(f"executing-A: the executing tree {executing.get('tree_sha')!r} is not a full "
                                    f"40-hex tree")
            if (executing.get("frozen_sha") or sha) != sha:
                problems.append("candidate.executing.frozen_sha must be the frozen candidate's own SHA")
    # *** THE ENDPOINT THE EXECUTING RUN MUST MATCH: `A` WHEN PROVEN, ELSE THE CANDIDATE. ***
    exec_expected_sha = proven_a or sha
    exec_expected_tree = (executing.get("tree_sha") if proven_a else tree)
    start = doc.get("clean_start") or {}
    exec_head, exec_tree = start.get("head_sha"), start.get("head_tree")
    if require_candidate and _is_full_sha(sha):
        if not _is_full_sha(exec_head):
            problems.append(f"clean_start carrieth NO executing HEAD ({exec_head!r}) -- *a gate run whose revision "
                            f"nobody recorded cannot be shown to have judged the candidate*")
        elif exec_head != exec_expected_sha:
            problems.append(f"the gates executed at HEAD {exec_head} but the manifest requireth the executing revision "
                            f"{exec_expected_sha} -- *a gate run from another checkout is evidence about no candidate*")
        if not _is_full_sha(exec_tree):
            problems.append(f"clean_start carrieth NO executing TREE ({exec_tree!r})")
        elif exec_expected_tree and exec_tree != exec_expected_tree:
            problems.append(f"the gates executed on tree {exec_tree} but the manifest requireth {exec_expected_tree}")
    if start.get("head_sha") and (doc.get("clean_end") or {}).get("head_sha") \
            and start["head_sha"] != doc["clean_end"]["head_sha"]:
        problems.append(f"the tree's HEAD MOVED during the gate run: {start['head_sha']} -> "
                        f"{doc['clean_end']['head_sha']} -- *a run whose revision changed underneath it is evidence "
                        f"about neither revision*")

    # *** AND THE END IDENTITY IS MEASURED AND AGREES WITH THE SAME EXPECTED EXECUTING REVISION. ***
    #
    # *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: `build_from_gates` omitted `head_sha`/`head_tree` from
    # `clean_end`, and the validator compared the two heads only WHEN the end one happened to exist -- so a run that
    # recorded no end identity, or whose end TREE had drifted, was accepted by omission. **The ends are the same
    # measurement at two moments: a missing end HEAD/TREE, an end that disagrees with the PROVEN executing revision, or
    # a start/end head-or-tree drift is refused BY NAME, never skipped.***
    end = doc.get("clean_end") or {}
    end_head, end_tree = end.get("head_sha"), end.get("head_tree")
    if require_candidate and _is_full_sha(sha):
        if not _is_full_sha(end_head):
            problems.append(f"clean_end carrieth NO executing HEAD ({end_head!r}) -- *a gate run whose ENDING revision "
                            f"nobody recorded cannot be shown to have finished on the candidate*")
        elif end_head != exec_expected_sha:
            problems.append(f"the gate run ENDED at HEAD {end_head} but the manifest requireth the executing revision "
                            f"{exec_expected_sha} -- *a run that ended on another revision is evidence about nothing*")
        if not _is_full_sha(end_tree):
            problems.append(f"clean_end carrieth NO executing TREE ({end_tree!r}) -- *a missing end tree is the "
                            f"missing-proof this contract refuses, never a field to skip*")
        elif exec_expected_tree and end_tree != exec_expected_tree:
            problems.append(f"the gate run ENDED on tree {end_tree} but the manifest requireth {exec_expected_tree} -- "
                            f"the tree DRIFTED during the run")
    if start.get("head_tree") and end_tree and start["head_tree"] != end_tree:
        problems.append(f"the tree's TREE MOVED during the gate run: {start['head_tree']} -> {end_tree} -- *a run whose "
                        f"tree changed underneath it is evidence about neither revision*")

    # ---- gates: exact ids, argv, rc, logs ----
    gates = doc.get("gates") or {}
    rows = gates.get("rows") or []
    expected = list(REQUIRED_GATE_IDS)
    recorded = [r.get("id") for r in rows]
    missing = [g for g in expected if g not in recorded]
    extra = [g for g in recorded if g not in expected]
    duplicates = sorted({g for g in recorded if recorded.count(g) > 1})
    if missing:
        problems.append(f"the manifest omits required gate(s): {missing} -- the required set is NAMED, and a "
                        f"shrunken one proves less than the one this contract names")
    if extra:
        problems.append(f"the manifest carrieth gate(s) this contract does not define: {extra}")
    if duplicates:
        problems.append(f"the manifest carrieth duplicated gate id(s): {duplicates}")
    if list(gates.get("required_ids") or []) != expected:
        problems.append(f"gates.required_ids {gates.get('required_ids')!r} differ from the contract's "
                        f"{expected!r}")
    for row in rows:
        gid = row.get("id")
        if gid not in expected:
            continue
        # *** THE GATE'S OWN DEFINITION IS RESOLVED BEFORE EITHER ARGV CHECK. ***
        #
        # *THE DEFECT THIS CLOSES: `gate_spec` was assigned AFTER the `argv_source` check, so a manifest carrying one
        # raised `UnboundLocalError` -- the checker CRASHED on a field it had asked for.*
        gate_spec = next(g for g in GATE_DEFINITIONS if g["id"] == gid)
        # *** ONLY A LIVE, IN-PROCESS RUN MAY HAVE PRODUCED A PASS ROW. ***
        if row.get("proof") != "live-process":
            problems.append(f"gate {gid!r} carrieth proof {row.get('proof')!r} -- *only a live run whose exit codes "
                            f"came from the child processes it spawned may back a PASS manifest; caller-created "
                            f"`.rc` files are not gate evidence*")
        else:
            recorded_argv = row.get("argv_source")
            if recorded_argv is not None:
                for problem in argv_problems(recorded_argv, gate_spec):
                    problems.append(f"gate {gid!r}: its own `.cmd` artifact {problem}")
        problems.extend(argv_problems(row.get("argv"), gate_spec))
        if row.get("verdict") != "PASS" or row.get("rc") != 0:
            problems.append(f"gate {gid!r} is {row.get('verdict')!r} with rc={row.get('rc')!r} -- only a full run "
                            f"in which EVERY required gate returned zero may emit a PASS manifest")
        log = row.get("log")
        if not isinstance(log, dict) or not log.get("sha256"):
            problems.append(f"gate {gid!r} carrieth NO log identity -- an exit code with no retained output cannot "
                            f"be re-checked")
            continue
        path = log.get("path")
        if not path:
            problems.append(f"gate {gid!r} carrieth a log record with no path")
            continue
        # *** A FRESH READER MAPS THE GATE LOG BY ITS RECORDED RELATIVE IDENTITY (BASENAME: THE GATE DIR IS FLAT). ***
        remap_gates = rebind_roots.get("gates")
        on_disk = (Path(remap_gates) / Path(path).name) if remap_gates is not None else (base / path)
        if not on_disk.is_file():
            problems.append(f"gate {gid!r} names log {path} which is NOT PRESENT")
            continue
        blob = on_disk.read_bytes()
        if sha256_bytes(blob) != log.get("sha256"):
            problems.append(f"gate {gid!r} log {path} carrieth sha256 {sha256_bytes(blob)} but the manifest "
                            f"stateth {log.get('sha256')} -- the log was EDITED after the manifest bound it")
        elif log.get("bytes") is not None and len(blob) != log.get("bytes"):
            problems.append(f"gate {gid!r} log {path} carrieth {len(blob)} bytes but the manifest stateth "
                            f"{log.get('bytes')}")
    pop = gates.get("population") or {}
    if pop.get("accounted") != len(expected) or pop.get("missing") or pop.get("nonzero") or pop.get("unreadable") \
            or pop.get("unlogged"):
        problems.append(f"gates.population is not fully accounted: {pop!r}")

    # ---- campaign ----
    problems.extend(_campaign_problems(doc.get("campaign") or {}, base=base,
                                       override=campaign_dir_override,
                                       ledger_ids_fn=ledger_ids_fn,
                                       tested_inputs_fn=tested_inputs_fn,
                                       rebind=rebind_roots.get("campaign"),
                                       executing_sha=executing.get("sha"),
                                       candidate_sha=(doc.get("candidate") or {}).get("sha")))

    # ---- lanes ----
    problems.extend(_lane_problems(doc.get("lanes") or [], base=base, digest_fn=lane_digest_fn,
                                   problems_fn=lane_problems_fn, roster_fn=lane_roster_fn,
                                   evidence_root=evidence_root, rebind=rebind_roots.get("evidence")))

    # ---- closure / ledger ----
    problems.extend(_closure_problems(doc, base=base))

    # ---- external evidence ----
    problems.extend(_external_problems(doc.get("external_evidence") or {}, base=base,
                                       rebind=rebind_roots.get("proof"),
                                       candidate_tree_sha=tree, repo=_release_repo(),
                                       candidate_sha=sha, candidate_tag=tag))

    # ---- timestamps and the run's own identity ----
    for field in ("started_utc", "completed_utc"):
        if not doc.get(field):
            problems.append(f"the manifest carrieth NO {field} -- a run whose start and completion are unrecorded "
                            f"cannot be dated, and an undatable manifest is not evidence about any revision")
    if doc.get("started_utc") and doc.get("completed_utc") and doc["started_utc"] > doc["completed_utc"]:
        problems.append(f"the manifest's started_utc {doc['started_utc']!r} is AFTER its completed_utc "
                        f"{doc['completed_utc']!r}")
    producer = doc.get("producer") or {}
    if "host" not in producer:
        problems.append("the manifest's producer carrieth NO host block -- the recording environment must be named "
                        "(`GITHUB_*` on a runner, explicit nulls on a workstation), never omitted")
    if doc.get("verdict") != "PASS":
        problems.append(f"the manifest's own verdict is {doc.get('verdict')!r}, not 'PASS'")
    return problems


def _is_full_sha(value) -> bool:
    return isinstance(value, str) and len(value) == 40 and all(c in "0123456789abcdef" for c in value.lower())


def _campaign_problems(campaign: dict, *, base: Path, override: Path | None = None,
                       ledger_ids_fn=None, tested_inputs_fn=None,
                       rebind: Path | None = None, executing_sha: str | None = None,
                       candidate_sha: str | None = None) -> list[str]:
    problems: list[str] = list(campaign.get("problems") or [])
    if not campaign:
        return ["the manifest carrieth NO campaign block -- the mutation campaign's population and tested inputs "
                "must be bound"]
    manifest_path = campaign.get("manifest_path")
    if not manifest_path:
        problems.append("campaign.manifest_path is absent")
        return problems
    # *** A FRESH READER MAPS THE CAMPAIGN BY IDENTITY: `--campaign-dir` (override) OR `rebind['campaign']`. ***
    # *The hosted runner wrote the envelope under its scratch root; a reader with the downloaded campaign tree names it
    # explicitly. The mapped file is still required to carry the ORIGINAL bound digest.*
    if rebind is not None:
        on_disk = Path(rebind) / Path(manifest_path).name
        digest_root = Path(rebind)
    else:
        on_disk = base / manifest_path
        digest_root = override.resolve() if override else on_disk.parent.resolve()
    if not on_disk.is_file():
        problems.append(f"campaign manifest {manifest_path} is NOT PRESENT")
        return problems
    if sha256_file(on_disk) != campaign.get("manifest_sha256"):
        problems.append(f"campaign manifest {manifest_path} does not match the digest the manifest bound")
    if campaign.get("digest") is not None:
        try:
            live_digest, _files = _dir_digest(digest_root, base)
        except OSError as exc:
            problems.append(f"the campaign directory could not be re-digested: {exc}")
        else:
            if live_digest != campaign.get("digest"):
                problems.append("the campaign directory digest does not recompute -- a phase log or the manifest "
                                "itself was edited after it was bound")
    # *** THE ENVELOPE IS RE-READ AND ITS FACTS RE-DERIVED -- NEVER TAKEN FROM THE MANIFEST'S OWN SUMMARY. ***
    #
    # *THE DEFECT THIS CLOSES: the validator hashed the envelope but trusted the manifest's `population` block. A
    # manifest could therefore retain a valid envelope hash while recording EMPTY required/selected sets and
    # `all_killed: true`, and the check would read the manifest's own claim rather than the artifact's.*
    envelope: dict = {}
    try:
        envelope = json.loads(on_disk.read_text(encoding="utf-8"))
    except ValueError as exc:
        problems.append(f"the campaign envelope at {manifest_path} is not valid JSON: {exc}")
        return problems
    env_rows = {r.get("id"): r for r in (envelope.get("rows") or [])}
    env_required = list(envelope.get("required_ids") or [])
    env_selected = list(envelope.get("selected_ids") or [])
    if ledger_ids_fn is None:
        ledger_ids_fn = lambda: default_ledger_ids(base)      # noqa: E731
    try:
        ledger_ids = set(ledger_ids_fn())
    except Exception as exc:  # noqa: BLE001
        problems.append(f"the ledger's required id set could not be derived: {type(exc).__name__}: {exc}")
        ledger_ids = set()
    if ledger_ids:
        if set(env_required) != ledger_ids:
            problems.append(f"the campaign ENVELOPE's required_ids differ from the ledger's own set: missing "
                            f"{sorted(ledger_ids - set(env_required))[:4]}, extra "
                            f"{sorted(set(env_required) - ledger_ids)[:4]}")
        if set(env_selected) != ledger_ids:
            omitted = sorted(ledger_ids - set(env_selected))
            if omitted:
                problems.append(f"the campaign ENVELOPE ran only {len(env_selected)} of {len(ledger_ids)} required "
                                f"rod(s): {omitted[:4]} -- *a narrowed campaign that still passed is the "
                                f"false-green this contract refuses*")
    bad_env = sorted(i for i in env_required if (env_rows.get(i) or {}).get("outcome") != "KILLED")
    if bad_env:
        problems.append(f"the campaign ENVELOPE carrieth non-KILLED required rod(s): {bad_env[:4]}")
    missing_env = sorted(set(env_selected) - set(env_rows))
    if missing_env:
        problems.append(f"the campaign ENVELOPE carrieth NO row for selected id(s): {missing_env[:4]}")
    # *** AND THE MANIFEST'S SUMMARY MUST MATCH THE ENVELOPE IT BOUND. ***
    pop = campaign.get("population") or {}
    required = set(pop.get("required_ids") or [])
    required_source = set(pop.get("required_ids_source") or [])
    selected = set(pop.get("selected_ids") or [])
    if required and required != set(env_required):
        problems.append(f"the manifest's recorded required_ids differ from the ENVELOPE's {sorted(env_required)[:4]}")
    if selected and selected != set(env_selected):
        problems.append(f"the manifest's recorded selected_ids differ from the ENVELOPE's")
    if not required_source:
        problems.append("campaign.population.required_ids_source is EMPTY -- *the ledger's own set must be recorded, "
                        "or the equality check above cannot run*")
    if required_source and required != required_source:
        problems.append(f"campaign.required_ids differ from the ledger's own set: missing "
                        f"{sorted(required_source - required)}, extra {sorted(required - required_source)}")
    omitted = sorted(required - selected)
    if omitted:
        problems.append(f"the campaign OMITTED {len(omitted)} required id(s) from its selection: {omitted[:6]} -- a "
                        f"narrowed campaign that still passed is the false-green this contract refuses")
    if pop.get("row_count") != len(selected):
        problems.append(f"campaign.population.row_count is {pop.get('row_count')!r} while the selection carrieth "
                        f"{len(selected)} id(s) -- a row is missing or duplicated")
    if pop.get("missing_rows"):
        problems.append(f"the campaign carrieth NO row for selected id(s): {pop.get('missing_rows')[:6]}")
    if pop.get("unselected_required"):
        problems.append(f"campaign.population.unselected_required is non-empty: {pop.get('unselected_required')[:6]}")
    if pop.get("unknown_selected"):
        problems.append(f"the campaign selected id(s) the ledger does not carry: {pop.get('unknown_selected')[:6]}")
    outcomes = pop.get("rows_by_id") or {}
    bad = sorted(i for i in required if outcomes.get(i) != "KILLED")
    if bad:
        problems.append(f"required rod(s) not KILLED: {bad[:6]} -- a rod that escaped, timed out or was skipped is "
                        f"not a kill")
    if not campaign.get("all_killed"):
        problems.append("campaign.all_killed is false")
    # tested inputs: the campaign's map must equal the CURRENT tree's derivation
    tested = campaign.get("tested_inputs") or {}
    try:
        current = _import_ci("mutations", base)._tested_input_digests()
    except Exception as exc:  # noqa: BLE001
        current = None
        problems.append(f"the tested-input digests could not be re-derived: {type(exc).__name__}: {exc}")
    if current is not None:
        if not tested:
            problems.append("campaign.tested_inputs is EMPTY -- a campaign that bound no tested input is a claim "
                            "about nothing in particular")
        for key in sorted(set(tested) | set(current)):
            if key not in tested:
                problems.append(f"campaign.tested_inputs omits {key!r} (the tree derives one)")
            elif key not in current:
                problems.append(f"campaign.tested_inputs binds {key!r}, which no longer exists")
            elif tested[key] != current[key]:
                problems.append(f"campaign tested input {key!r} has MOVED since the campaign: manifest "
                                f"{str(tested[key])[:16]}… != tree {str(current[key])[:16]}… -- the campaign ran "
                                f"against other bytes")
    if not campaign.get("baseline_sha"):
        problems.append(f"campaign.baseline_sha {campaign.get('baseline_sha_recorded')!r} does not resolve to a "
                        f"commit in this repository")
    # *** AND THE ENVELOPE'S OWN `tested_tree_sha` IS RE-DERIVED FROM ITS BASELINE. ***
    #
    # *A campaign records the TREE it tested. If the envelope's `tested_tree_sha` disagrees with
    # `git rev-parse <baseline_sha>^{tree}`, the envelope describes bytes no commit carries.*
    tested_tree = envelope.get("tested_tree_sha")
    if tested_tree is None:
        problems.append("the campaign ENVELOPE carrieth no `tested_tree_sha` -- *a campaign that named no tree cannot "
                        "be bound to a revision*")
    elif envelope.get("baseline_sha"):
        resolved_tree = _git("rev-parse", f"{envelope['baseline_sha']}^{{tree}}", cwd=base)
        if resolved_tree.returncode != 0:
            problems.append(f"the campaign ENVELOPE's baseline {str(envelope.get('baseline_sha'))[:12]}… does not "
                            f"resolve in this repository")
        elif resolved_tree.stdout.strip() != tested_tree:
            problems.append(f"the campaign ENVELOPE carrieth tested_tree_sha {tested_tree} but its baseline carrieth "
                            f"tree {resolved_tree.stdout.strip()}")
    for rid, row in sorted(env_rows.items()):
        if row.get("tested_tree_sha") is None:
            problems.append(f"campaign row {rid} carrieth no tested_tree_sha")
        elif tested_tree is not None and row["tested_tree_sha"] != tested_tree:
            problems.append(f"campaign row {rid} carrieth tested_tree_sha {row['tested_tree_sha']}, not the "
                            f"envelope's {tested_tree}")
    # *** AND THE ROW'S THREE PHASE LOGS ARE RE-HASHED UNDER THE CAMPAIGN ROOT, REFUSING TRAVERSAL. ***
    for rid, row in sorted(env_rows.items()):
        phase_logs = row.get("phase_logs") or {}
        for phase in ("baseline", "mutant", "restored"):
            entry = phase_logs.get(phase) or {}
            rel = entry.get("path")
            if not rel:
                problems.append(f"campaign row {rid} carrieth no {phase} phase-log path")
                continue
            candidate_path = (digest_root / rel).resolve()
            if not _is_within(candidate_path, digest_root.resolve()):
                problems.append(f"campaign row {rid} {phase} phase log {rel!r} ESCAPES the campaign root")
                continue
            if not candidate_path.is_file():
                problems.append(f"campaign row {rid} {phase} phase log {rel!r} is NOT PRESENT")
                continue
            if sha256_file(candidate_path) != entry.get("sha256"):
                problems.append(f"campaign row {rid} {phase} phase log {rel!r} does not match its recorded sha256")
    # *** AND THE CAMPAIGN MUST HAVE RUN AGAINST THE EXECUTING REVISION. ***
    #
    # *THE DEFECT THIS CLOSES: `baseline_sha` need only be truthy and resolvable, so a campaign run at an OLD commit
    # whose tested-input FAMILIES happened to hash alike would satisfy the manifest.* **The rods must have run at the
    # EXECUTING revision: for a fresh `A` verification that is the PROVEN executing `A`; otherwise the candidate `C`.
    # The STRICT C campaign authentication stays inside the embedded C manifest (which bindeth C alone).**
    expected_baseline = executing_sha or candidate_sha
    if not campaign.get("baseline_sha"):
        pass          # (reported above)
    elif expected_baseline and envelope.get("baseline_sha") != expected_baseline:
        problems.append(f"the campaign ran at baseline {str(envelope.get('baseline_sha'))[:12]}… but the manifest's "
                        f"executing revision is {expected_baseline[:12]}… -- *a campaign at another commit is not proof "
                        f"about this one*")
    return problems


def _lane_problems(lanes: list, *, base: Path, digest_fn, problems_fn, roster_fn,
                   evidence_root: Path | None = None, rebind: Path | None = None) -> list[str]:
    problems: list[str] = []
    recorded = {l.get("id") for l in lanes}
    missing = [l for l in REQUIRED_LANES if l not in recorded]
    if missing:
        problems.append(f"the manifest omits required lane(s): {missing} -- *a lane that produced no artifact is a "
                        f"refusal with the lane's name on it, never a lane silently absent from a green summary*")
    for lane in lanes:
        lid = lane.get("id")
        if lid not in LANE_SOURCES:
            problems.append(f"the manifest carrieth lane {lid!r} this contract does not define")
            continue
        for p in lane.get("problems") or []:
            problems.append(f"lane {lid}: {p}")
        # the sidecars must exist, agree, and equal the derived digest
        sides = lane.get("sidecars") or []
        present = [s for s in sides if isinstance(s, dict) and s.get("sha256") and not s.get("missing")]
        if len(present) != len(LANE_SOURCES[lid]["sidecars"]):
            problems.append(f"lane {lid}: {len(present)} of {len(LANE_SOURCES[lid]['sidecars'])} digest sidecar(s) "
                            f"are present -- *an undatable lane is not evidence about any revision*")
            continue
        for s in present:
            disk = _rebind_artifact_path(s, rebind, base)
            if not disk.is_file():
                problems.append(f"lane {lid}: sidecar {s['path']} is NOT PRESENT")
            elif sha256_file(disk) != s.get("sha256"):
                problems.append(f"lane {lid}: sidecar {s['path']} does not match the digest the manifest bound")
        pre_disk = _rebind_artifact_path(present[0], rebind, base)
        post_disk = _rebind_artifact_path(present[-1], rebind, base)
        pre_text = pre_disk.read_text(encoding="utf-8").strip().split()[0] if pre_disk.is_file() else ""
        post_text = post_disk.read_text(encoding="utf-8").strip().split()[0] if post_disk.is_file() else ""
        if pre_text and post_text and pre_text != post_text:
            problems.append(f"lane {lid}: PRE-RUN digest {pre_text[:16]}… does not match POST-RUN {post_text[:16]}… "
                            f"-- an input changed WHILE the lane ran, so its artifacts describe no single revision")
        if lane.get("digest_recorded") and lane.get("digest") and lane["digest_recorded"] != lane["digest"]:
            problems.append(f"lane {lid}: recorded source digest {lane['digest_recorded'][:16]}… does not match the "
                            f"manifest's own derived digest {lane['digest'][:16]}…")
        # re-derive the digest from the CURRENT tree and require agreement (staleness)
        if digest_fn is not None:
            try:
                live = digest_fn(lid, base) if _takes_base(digest_fn) else digest_fn(lid)
            except Exception as exc:  # noqa: BLE001
                problems.append(f"lane {lid}: the source digest could not be re-derived: {type(exc).__name__}: {exc}")
            else:
                if lane.get("digest") != live:
                    problems.append(f"lane {lid}: the manifest bound source digest {str(lane.get('digest'))[:16]}… "
                                    f"but the tree derives {str(live)[:16]}… -- THE LANE IS STALE")
        # *** AND THE LANE'S OWN CHECKER IS RE-RUN BY DEFAULT -- never left disabled. ***
        #
        # *THE DEFECT THIS CLOSES: all three hooks defaulted to `None`, and the real CLI/freeze callers passed none, so
        # the digest re-derivation, the lane checker and the roster re-derivation were SKIPPED in production while the
        # manifest still read PASS.* **Silence is not consent: a lane whose checker cannot be run is a refusal, not a
        # pass.** *The default is therefore the real, base-owned checker; a caller who WANTS a fixture may pass a
        # callable explicitly, but cannot disable the control by passing nothing.*
        if problems_fn is None:
            problems_fn = lane_problems       # *** THE REAL, BASE-OWNED CHECKER IS THE DEFAULT. ***
        # *** THE RE-CHECK USES THE SAME EVIDENCE ROOT AS THE RECORDED FACTS. *** *A checker re-run against the
        # checkout while the manifest bound a downloaded root would certify counts from different bytes.*
        if True:
            try:
                if problems_fn is lane_problems and evidence_root is not None:
                    live_problems = lane_check(lid, base, evidence_root=evidence_root)[0]
                else:
                    live_problems = problems_fn(lid, base) if _takes_base(problems_fn) else problems_fn(lid)
            except Exception as exc:  # noqa: BLE001
                problems.append(f"lane {lid}: its checker raised {type(exc).__name__}: {exc}")
            else:
                for p in live_problems:
                    problems.append(f"lane {lid} (re-checked): {p}")
        # the roster must be present and re-derived
        if lane.get("roster_size") is None:
            problems.append(f"lane {lid}: the manifest carrieth NO roster size -- a count with no source-derived "
                            f"roster cannot show that every declared arm ran")
        elif roster_fn is not None:
            try:
                live_roster = roster_fn(lid, base) if _takes_base(roster_fn) else roster_fn(lid)
            except Exception as exc:  # noqa: BLE001
                problems.append(f"lane {lid}: the roster could not be re-derived: {type(exc).__name__}: {exc}")
            else:
                if live_roster is not None and lane["roster_size"] != live_roster:
                    problems.append(f"lane {lid}: roster size {lane['roster_size']!r} but the sources declare "
                                    f"{live_roster!r} arms -- an arm added or removed since the run")
        # artifacts must exist with the recorded digests (or be PUBLISHED, so a reader knows where the bytes are)
        for art in lane.get("artifacts") or []:
            if not isinstance(art, dict) or art.get("missing"):
                problems.append(f"lane {lid}: artifact {art!r} is MISSING")
                continue
            # *** A FRESH READER MAPS THE ARTIFACT BY ITS RECORDED EVIDENCE-RELATIVE PATH (NESTING PRESERVED). ***
            disk = _rebind_artifact_path(art, rebind, base)
            if not disk.exists():
                if not (art.get("published") or {}).get("artifact"):
                    problems.append(f"lane {lid}: artifact {art['path']} is NOT PRESENT and names NO hosted artifact "
                                    f"-- an absent artifact must be identified, never silently omitted")
                continue
            live = artifact_record(disk, base)
            if live and live.get("sha256") != art.get("sha256"):
                problems.append(f"lane {lid}: artifact {art['path']} does not match the digest the manifest bound")
        if not lane.get("artifacts"):
            problems.append(f"lane {lid}: the manifest binds NO artifact for this lane")
        if lane.get("counts") is None:
            problems.append(f"lane {lid}: the manifest carrieth NO parsed counts -- a lane whose population nobody "
                            f"recorded cannot be shown to have executed its roster")
    return problems


def _closure_problems(doc: dict, *, base: Path) -> list[str]:
    problems: list[str] = []
    closure = doc.get("closure") or {}
    ledger = doc.get("ledger") or {}
    derived = doc.get("derived_counts") or {}
    cref = closure.get("record") or {}
    # *** A CLOSURE BLOCK THAT CARRIETH ITS OWN NAMED PROBLEMS IS REFUSED BY THEM. ***
    for p in closure.get("problems") or []:
        problems.append(f"closure: {p}")
    if not cref.get("sha256"):
        problems.append("the manifest binds NO closure-record digest")
    else:
        disk = base / cref["path"]
        if not disk.is_file():
            problems.append(f"closure record {cref['path']} is NOT PRESENT")
        elif sha256_file(disk) != cref["sha256"]:
            problems.append(f"closure record {cref['path']} does not match the digest the manifest bound")
    lref = ledger.get("record") or {}
    if not lref.get("sha256"):
        problems.append("the manifest binds NO ledger digest")
    else:
        disk = base / lref["path"]
        if not disk.is_file():
            problems.append(f"ledger {lref['path']} is NOT PRESENT")
        elif sha256_file(disk) != lref["sha256"]:
            problems.append(f"ledger {lref['path']} does not match the digest the manifest bound")
    # re-derive the structured counts and require exact agreement
    if not derived:
        problems.append("the manifest binds NO derived structured counts")
    else:
        try:
            bsc = _import_script("build_structured_closure", base)
            live = bsc.counts(bsc.build(bsc.load(
                base / (lref.get("path") or "docs/remediation/REMEDIATION_STATE.json"))))
        except Exception as exc:  # noqa: BLE001
            problems.append(f"the structured counts could not be re-derived from the bound ledger: "
                            f"{type(exc).__name__}: {exc}")
        else:
            for key in sorted(set(derived) | set(live)):
                if derived.get(key) != live.get(key):
                    problems.append(f"structured counts DISAGREE: manifest {key}={derived.get(key)!r} != derived "
                                    f"{live.get(key)!r} -- the closure ledger mismatch this contract refuses")
        if ledger.get("structured_counts") and ledger["structured_counts"] != derived:
            problems.append("the ledger's PERSISTED structured_counts differ from the derivation -- a second, stale "
                            "representation of the same state")
    status = closure.get("status")
    if status in ("COMPLETE", "READY_FOR_EXTERNAL_REAUDIT") and derived.get("internal_obligations_open"):
        problems.append(f"the closure status is {status!r} while {derived.get('internal_obligations_open')} internal "
                        f"obligation(s) are OPEN -- the control plane may not report closure over live internal work")
    # *** AND A PASS MANIFEST REQUIRETH EVERY INTERNAL SEMANTIC OBLIGATION CLOSED -- NOT MERELY A STATUS ENUM. ***
    #
    # *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: the closure law bit only when the STATUS was already
    # `COMPLETE`/`READY_FOR_EXTERNAL_REAUDIT`, so a manifest could stand PASS over a control plane that still carried
    # live internal obligations -- the derived population, which is the MEASURED half, was never required to be empty.*
    # **So the derived counts themselves are the gate: a PASS manifest requireth `internal_obligations_open == 0` AND
    # `findings_with_internal_status_open == 0`, i.e. every semantic obligation DISCHARGED; and the per-obligation
    # semantic provenance must be present with no refused control. `verified_fixed` still belongs to the independent
    # auditor alone.**
    if derived:
        open_count = derived.get("internal_obligations_open")
        open_findings = derived.get("findings_with_internal_status_open")
        if open_count:
            problems.append(f"{open_count} internal semantic obligation(s) remain OPEN -- a PASS manifest requireth "
                            f"EVERY internal obligation CLOSED (the derived population, not a status enum), because a "
                            f"manifest that bound live internal work would certify the overclaim this contract refuseth")
        if open_findings:
            problems.append(f"{open_findings} finding(s) still carry internal_status OPEN -- readiness requireth BOTH "
                            f"populations empty, because a finding can be open with no obligations to count")
    semantics = closure.get("semantics")
    if not isinstance(semantics, dict):
        problems.append("the manifest binds NO structured semantic provenance -- *a count without the per-obligation "
                        "controls, gaps and dependencies is a number, not a measurably closed population*")
    else:
        for entry in semantics.get("refused_controls") or []:
            problems.append(f"{entry.get('obligation')}: the terminal claim carrieth NO measurable control -- a "
                            f"DISCHARGED obligation with no authored `structured_discharge` is refused")
    if closure.get("verified_fixed") not in (None, 0):
        problems.append(f"closure.verified_fixed is {closure.get('verified_fixed')!r} -- only an INDEPENDENT auditor "
                        f"may write it")
    return problems


def _external_problems(block: dict, *, base: Path,
                       candidate_sha: str | None, candidate_tag: str | None,
                       candidate_tree_sha: str | None = None, repo: str | None = None,
                       rebind: Path | None = None) -> list[str]:
    problems: list[str] = []
    if not block:
        problems.append("the manifest carrieth NO external-evidence block -- external and historical identities must "
                        "be bound or explicitly recorded as absent")
        return problems
    for name in ("blockers", "release_gates"):
        entry = block.get(name)
        if not isinstance(entry, dict) or not entry.get("record"):
            continue  # *an absent release-gate register is recorded as absent, not inferred green*
        rec = entry["record"]
        disk = base / rec["path"]
        if not disk.is_file():
            problems.append(f"external register {rec['path']} is NOT PRESENT")
        elif sha256_file(disk) != rec.get("sha256"):
            problems.append(f"external register {rec['path']} does not match the digest the manifest bound")
    for entry in block.get("historical") or []:
        # *** THE WORKING DIGEST IS AN OBSERVATION; THE ANCHOR CLAUSE OWNS PRESERVATION. ***
        #
        # *A clean worktree at `C` legitimately lacks the original rc14 attestation (it exists only on `A14`), so the
        # historical row carrieth no sha256 there and no claim is inferred. When the file IS present its digest is
        # re-derived; the git-object anchor is judged separately and independently.* **A row that explicitly CLAIMETH
        # `missing: true`, however, is a named historical identity the manifest says it bound and then did not -- that
        # is refused by name.**
        if entry.get("missing"):
            problems.append(f"historical evidence {entry.get('path')!r} is MISSING")
            continue
        if not entry.get("sha256"):
            continue
        disk = base / entry["path"]
        if not disk.is_file():
            problems.append(f"historical evidence {entry['path']} is NOT PRESENT")
        elif sha256_file(disk) != entry["sha256"]:
            problems.append(f"historical evidence {entry['path']} does not match the digest the manifest bound")
    problems.extend(_anchor_problems(block.get("anchors") or {}, base=base))
    rp_block = block.get("release_proof") or {}
    if rebind is not None and isinstance(rp_block, dict):
        # *** A FRESH READER MAPS EACH RELEASE-PROOF RECORD BY IDENTITY; THE ORIGINAL DIGEST IS STILL REQUIRED. ***
        # *The block is COPIED, never mutated: `check_manifest` is read-only and the caller's document must be
        # unchanged after a validation.*
        rp_block = {**rp_block, "records": [
            {**entry, "record": {**((entry.get("record") or {})),
                                 "path": str(Path(rebind) / Path((entry.get("record") or {}).get("path", "")).name)}}
            if (entry.get("record") or {}).get("path") else entry
            for entry in (rp_block.get("records") or [])]}
    problems.extend(release_evidence_problems(rp_block,
                                              candidate_sha=candidate_sha, candidate_tag=candidate_tag,
                                              candidate_tree_sha=candidate_tree_sha, repo=repo))
    return problems


# ----------------------------------------------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------------------------------------------
def _write_atomic(path: Path, blob: str) -> None:
    """Write through a temporary sibling and `os.replace`, so a crash never leaves a truncated manifest."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(blob, encoding="utf-8")
    os.replace(tmp, path)


def gather_default_facts(base: Path = ROOT, *, campaign_dir: Path | None = None,
                         published: dict[str, str] | None = None,
                         evidence_root: Path | None = None,
                         proof_dir: Path | None = None) -> dict:
    """Gather campaign/lane/closure/external facts for a real run at `base`.

    *** AN ABSENT CAMPAIGN DIRECTORY IS A NAMED REFUSAL, NEVER A STALE DEFAULT. *** *The committed rc11 envelope is
    evidence about a PAST candidate; binding it as though it described this run would be the stale-authority defect.
    So a caller that declared no campaign dir getteth a campaign block that carrieth the refusal -- and `check_manifest`
    then reddens on it by name.*
    """
    return {
        "campaign": (campaign_facts(campaign_dir, base) if campaign_dir is not None
                     else {"problems": ["no campaign directory was declared for this run -- *a campaign must be run "
                                        "for the CURRENT candidate at its own baseline; the committed rc11 envelope is "
                                        "evidence about a past candidate and is NOT a default*"],
                           "manifest_path": None, "digest": None, "population": {}, "tested_inputs": {},
                           "baseline_sha": None, "all_killed": False}),
        "lanes": [lane_facts(l, base, published=published, evidence_root=evidence_root)
                  for l in REQUIRED_LANES],
        "closure": closure_facts(base / "docs/production-readiness/BOARD1_CLOSURE.json",
                                 base / "docs/remediation/REMEDIATION_STATE.json", base),
        "external": external_evidence_facts(base, proof_dir=proof_dir),
    }


def resolve_campaign_dir(campaign_dir, base: Path = ROOT) -> Path | None:
    """*** ONE PLACE DECIDES WHERE THE CAMPAIGN LIVED. ***

    *The campaign directory may be ABSOLUTE (a runner's scratch root), REPOSITORY-RELATIVE (the committed evidence
    path), or absent.* **AN ABSENT ONE IS `None`, NOT A STALE rc11 DEFAULT: the campaign is run for the CURRENT
    candidate at its own baseline, so binding the committed rc11 envelope as though it described this run would be the
    stale-authority defect -- a campaign digest that re-derives against old bytes is not evidence about these.*** *The
    manifest then carrieth a NAMED "no campaign directory declared" problem, and the gate set refuseth the unresolved
    `{campaign_dir}` token, so neither road can pass on stale evidence.*
    """
    if campaign_dir in (None, ""):
        return None
    path = Path(campaign_dir)
    return path if path.is_absolute() else (base / path)


def build_from_gates(*, gate_facts: list[dict], base: Path = ROOT, tag: str | None = None,
                     published: dict[str, str] | None = None,
                     lanes: list[dict] | None = None,
                     campaign_dir=None, proof_dir: Path | None = None,
                     evidence_root: Path | None = None,
                     frozen_artifacts: Path | None = None,
                     frozen_campaign_dir: Path | None = None,
                     frozen_evidence_root: Path | None = None,
                     frozen_proof_dir: Path | None = None,
                     pre_gate: dict | None = None) -> dict:
    """Emit a manifest from a live (or downloaded) gate run, gathering the rest of the facts at `base`.

    *** THE CLEAN-START SNAPSHOT IS TAKEN BY THE CALLER *BEFORE* THE GATES RUN, OR TAKEN HERE. ***
    // *THE DEFECT THIS CLOSES: `clean_start` was captured AFTER the gates had already executed, so a gate that
    // dropped a file into the tree could dirty it without the "start" measurement ever seeing a clean tree. The
    // caller (`board1.verify`) passes the snapshot it took BEFORE the first gate; a caller that passes none getteth a
    // measurement taken now, clearly labelled as such.*
    """
    ident = tag_identity(tag, cwd=base) if tag else None
    work = workdir_identity(cwd=base)
    # *** `--tag` NAMES THE FROZEN CANDIDATE `C`. *** *At the final-main `A` verification the gates run on the
    # successor's HEAD (`A`), so the candidate binding is the tag's peel (`C`) and the executing revision is HEAD. The
    # frozen clause is admitted ONLY after the committed-attestation authentication below, so `--tag` resolves `C` only
    # once the attestation binding C is authenticated.*
    if ident and ident.get("exists"):
        candidate = {"tag": tag, "sha": ident["peeled_commit"], "tree_sha": ident["tree_sha"],
                     "sha_source": "tag"}
    else:
        candidate = {"tag": tag, "sha": work.get("head_sha"), "tree_sha": work.get("head_tree"),
                     "sha_source": "workdir"}
    # *** THE FROZEN-C RELOCATION CONTEXT, FOR AUTHENTICATING THE COMMITTED ATTESTATION AND THE EMBEDDED C EVIDENCE. ***
    frozen_rebind = {}
    if frozen_artifacts is not None:
        frozen_rebind["gates"] = frozen_artifacts
    if frozen_campaign_dir is not None:
        frozen_rebind["campaign"] = frozen_campaign_dir
    if frozen_evidence_root is not None:
        frozen_rebind["evidence"] = frozen_evidence_root
    if frozen_proof_dir is not None:
        frozen_rebind["proof"] = frozen_proof_dir
    # *** WHEN THE GATES EXECUTE AT `A` WHILE THE FROZEN CANDIDATE IS `C`, RECORD AND PROVE THE RELATIONSHIP. ***
    #
    # *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: the final-main verification re-runneth the SAME canonical runner
    # FRESHLY on the successor `A`, so its executing revision is `A` while the frozen candidate must remain `C`. **The
    # manifest must therefore EXPOSE all three -- the executing HEAD/tree, the frozen candidate, and the relationship --
    # and the difference is admitted ONLY when the canonical authority proveth it is the exact attestation-only direct
    # child, never a generic ancestor allowance or a filename prefix.*** *When the executing revision IS the candidate,
    # nothing is added and the strict execution check applies unchanged.*
    if (ident and ident.get("exists") and work.get("head_sha")
            and work["head_sha"] != candidate["sha"]):
        sys.path.insert(0, str(ROOT / "ci"))
        import check_candidate_binding as _ccb_rel  # noqa: PLC0415 - the ONE successor-policy authority
        att_rel = _ccb_rel.FREEZE_ATTESTATION_SUCCESSOR_PATH
        # *** THE RELATION -- STRUCTURAL AND FULLY AUTHENTICATED -- IS ADJUDICATED BY THE ONE SHARED HELPER, WITH THE
        # FROZEN-C RELOCATION CONTEXT PASSED THROUGH (so a fresh reader authenticates the COMMITTED bytes from the
        # supplied C evidence roots, never the A gate directories). ***
        problems_rel = _ccb_rel.executing_successor_problems(
            candidate=candidate["sha"], successor=work["head_sha"], attestation_path=att_rel,
            rebind=frozen_rebind or None)
        if not problems_rel:
            candidate["frozen"] = {"sha": candidate["sha"], "tree_sha": candidate["tree_sha"],
                                   "tag": tag, "sha_source": "tag"}
            candidate["executing"] = {"sha": work.get("head_sha"), "tree_sha": work.get("head_tree"),
                                      "frozen_sha": candidate["sha"], "frozen_tree_sha": candidate["tree_sha"],
                                      "relationship": "exact-attestation-only-direct-child",
                                      "attestation": att_rel}
    resolved_campaign = resolve_campaign_dir(campaign_dir, base)
    facts = gather_default_facts(base, campaign_dir=resolved_campaign, published=published,
                                 evidence_root=evidence_root, proof_dir=proof_dir)
    # *** THE ALLOWANCE IS THE ONE EXACT ARTIFACT PATH THIS RUN ITSELF WRITES -- NEVER A PREFIX. ***
    allow = (str(MANIFEST_PATH_DEFAULT.relative_to(ROOT)),)
    start = pre_gate or {"before": {"head_sha": work.get("head_sha"), "head_tree": work.get("head_tree"),
                                    "measured_utc": _now_utc(),
                                    "ok": not dirt_report(allow=allow, cwd=base)["all"],
                                    "status_error": None, **dirt_report(allow=allow, cwd=base)},
                         "taken": "at-build"}
    before = start.get("before") or {}
    # *** AND THE EXECUTING HEAD/TREE MUST MATCH WHAT THE GATES ACTUALLY RAN ON. ***
    for problem in _candidate_execution_problems(candidate, before, work):
        facts["external"].setdefault("problems", []).append(problem)
    end_dirt = dirt_report(allow=allow, cwd=base)
    # *** AND THE END SNAPSHOT CARRIETH THE MEASURED HEAD/TREE, NOT ONLY THE DIRT. ***
    #
    # *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: `clean_end` omitteth `head_sha`/`head_tree`, so a gate that
    # committed -- or a tree whose revision moved during the run -- left the END identity unrecorded and the validator
    # could not compare the two ends. **`clean_start` and `clean_end` are the same MEASUREMENT at two moments, so BOTH
    # must carry the executing revision; a missing end identity is refused rather than accepted by omission.***
    end_work = workdir_identity(cwd=base)
    return build_manifest(gate_facts=gate_facts, base=base, candidate=candidate,
                          campaign=facts["campaign"],
                          lanes=lanes if lanes is not None else facts["lanes"],
                          closure=facts["closure"], external=facts["external"],
                          clean_start={**before, "head_sha": before.get("head_sha", work.get("head_sha")),
                                       "head_tree": before.get("head_tree", work.get("head_tree"))},
                          clean_end={**end_dirt, "ok": not end_dirt["all"],
                                     "head_sha": end_work.get("head_sha"),
                                     "head_tree": end_work.get("head_tree")},
                          campaign_dir_override=resolved_campaign,
                          evidence_root=evidence_root,
                          frozen_rebind=frozen_rebind or None)


def pre_gate_snapshot(base: Path = ROOT, *, allow: tuple[str, ...] = ()) -> dict:
    """*** A SNAPSHOT TAKEN *BEFORE* THE FIRST GATE RUNS. ***

    *The `clean_start` block must describe the tree the gates BEGAN on, so it is captured by the caller before it
    invokes anything. This helper existeth so there is ONE way to take it, and it returneth the `clean_start` block
    itself -- a dirt report, plus the executing HEAD/TREE the manifest's candidate clause compareth against.*
    """
    work = workdir_identity(cwd=base)
    dirt = dirt_report(allow=allow, cwd=base)
    return {"before": {"head_sha": work.get("head_sha"), "head_tree": work.get("head_tree"),
                       "measured_utc": _now_utc(), "ok": not dirt["all"],
                       "status_error": dirt.get("status_error"),
                       "tracked": dirt.get("tracked"), "untracked": dirt.get("untracked"),
                       "all": dirt.get("all"), "allow": dirt.get("allow")},
            "taken": "before-gates"}


def _candidate_execution_problems(candidate: dict, before: dict, work: dict) -> list[str]:
    """*** THE GATES MUST HAVE EXECUTED *THE CANDIDATE*, NOT SOME OTHER CHECKOUT. ***

    *THE DEFECT THIS CLOSES: the manifest could name candidate `C` while the gates ran in a work tree whose HEAD was
    something else -- a passed `--tag` derived the binding from the TAG while the executing tree was unrelated.*
    **So the pre-gate HEAD/TREE is compared to the candidate's, and a mismatch is a NAMED refusal.**
    """
    problems: list[str] = []
    start_head = before.get("head_sha")
    start_tree = before.get("head_tree")
    if start_head is None or start_tree is None:
        problems.append("the pre-gate snapshot carrieth NO head/tree -- the executing revision of the gate run is "
                        "unrecorded, so the run cannot be shown to have judged the candidate")
        return problems
    if candidate.get("sha") and start_head != candidate["sha"]:
        problems.append(f"the gates executed at HEAD {start_head} but the manifest bindeth candidate "
                        f"{candidate['sha']} -- *a gate run from another checkout is not evidence about this "
                        f"candidate*")
    if candidate.get("tree_sha") and start_tree != candidate["tree_sha"]:
        problems.append(f"the gates executed on tree {start_tree} but the manifest bindeth tree "
                        f"{candidate['tree_sha']}")
    if work.get("head_sha") and start_head and work.get("head_sha") != start_head:
        problems.append(f"the tree's HEAD MOVED DURING THE GATE RUN: {start_head} -> {work.get('head_sha')} -- "
                        f"*a run whose revision changed underneath it is evidence about neither*")
    return problems


# ----------------------------------------------------------------------------------------------------------------
# the selftest: real throwaway repos, real bytes, real mutations, each an OBSERVED refusal
# ----------------------------------------------------------------------------------------------------------------
def base_script_for_derivation() -> Path:
    """The closure generator itself -- copied into the fixture so its derivation runs against the fixture's ledger."""
    return ROOT / "scripts" / "build_structured_closure.py"


def _fixture_repo(root: Path) -> Path:
    """A real, minimal git repository: an annotated tag, a committed tree, a campaign dir and lane artifacts.

    *These are NOT mocks. The fixture carries an actual annotated tag object, actual files with actual digests and an
    actual campaign envelope whose tested-input map is derived from THIS tree -- so a check that quietly stopped
    looking at git or at the bytes would not be exercised at all.*
    """
    import subprocess as sp
    repo = root / "repo"
    repo.mkdir(parents=True)

    def run(*args, **kw):
        return sp.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False, **kw)

    run("init", "-q", "-b", "main")
    run("config", "user.email", "selftest@example.invalid")
    run("config", "user.name", "selftest")
    (repo / "docs/remediation/evidence/board1-rc11-rods/logs").mkdir(parents=True)
    (repo / "docs/production-readiness").mkdir(parents=True, exist_ok=True)
    (repo / "src").mkdir(parents=True, exist_ok=True)
    (repo / "src/prod.swift").write_text("let x = 1\n", encoding="utf-8")
    # *** THE REAL LEDGER, THE REAL GENERATOR AND THE REAL ROD LEDGER ARE COPIED IN, NOT STUBBED. *** *The structured
    # counts must be the ones this repository's own generator DERIVES from this ledger, and the campaign population
    # the ledger's own required set declares -- so the positive case exercises the real derivations and every refusal
    # is a delta against them.*
    import shutil
    shutil.copyfile(CLOSURE, repo / "docs/production-readiness/BOARD1_CLOSURE.json")
    shutil.copyfile(LEDGER, repo / "docs/remediation/REMEDIATION_STATE.json")
    (repo / "scripts").mkdir(exist_ok=True)
    shutil.copyfile(ROOT / "scripts" / "build_structured_closure.py",
                    repo / "scripts" / "build_structured_closure.py")
    (repo / "ci").mkdir(exist_ok=True)
    copy_rod_ledger(repo)
    shutil.copyfile(ROOT / "ci" / "check_lane_results.py", repo / "ci" / "check_lane_results.py")
    normalize_fixture_ledger(repo, status="READY_FOR_EXTERNAL_REAUDIT")
    register_lane_overrides(repo, digest=lambda _l: "d" * 64,
                            check=lambda _l: ([], {"tests": 3, "skipped": 0, "failures": 0, "errors": 0}),
                            roster=lambda _l: 3)
    run("add", "-A")
    run("commit", "-q", "-m", "fixture")
    run("tag", "-a", "board1-fixture-rc", "-m", "the fixture candidate")
    # *** AND THE FIXTURE'S OWN IMMUTABLE ANCHOR: a REAL child commit carrying a REAL blob, with a spec derived from
    # the fixture's own git objects. The real repository's rc14 anchor is not reproducible in a throwaway repo, so the
    # fixture carries an anchor of the SAME SHAPE and `anchor_facts` derives every identity from git.*
    register_anchor_specs(repo, _fixture_anchor_spec(repo))
    return repo


def _selftest_gate_facts(gate_dir: Path, *, argv_override=None, rc_override=None,
                         drop=None, log_edit=None, no_log=None) -> list[dict]:
    """Build gate facts over a REAL directory of `<id>.rc`/`<id>.log`/`<id>.cmd` artifacts."""
    gate_dir.mkdir(parents=True, exist_ok=True)
    facts = []
    inputs = {token: str(gate_dir.resolve() / token.strip("{}")) for token in GATE_INPUT_TOKENS}
    for spec in canonical_gate_rows(inputs=inputs):
        gid = spec["id"]
        argv = list(spec["argv"])
        if argv_override and gid in argv_override:
            argv = argv_override[gid]
        rc = (rc_override or {}).get(gid, 0)
        log_path = gate_dir / f"{gid}.log"
        log_path.write_text(f"gate {gid} ran; argv={argv!r}\n", encoding="utf-8")
        if log_edit and gid in log_edit:
            log_path.write_text(log_edit[gid], encoding="utf-8")
        (gate_dir / f"{gid}.rc").write_text(f"{rc}\n", encoding="utf-8")
        (gate_dir / f"{gid}.cmd").write_text(json.dumps(argv) + "\n", encoding="utf-8")
        if no_log and gid in no_log:
            log_path.unlink()
        if drop and gid in drop:
            (gate_dir / f"{gid}.rc").unlink()
        facts.append({"id": gid, "label": spec["label"], "argv": argv, "rc": rc,
                      "log_path": str(log_path), "verdict": "PASS" if rc == 0 else "FAIL"})
    return facts


#: *Appended to the FIXTURE's copy of the closure generator: a synthetic ledger authors no obligations, so the
#: derivation is clean and a READY claim is lawful. The derivation still RUNS -- it is the real generator, over the
#: fixture's own ledger -- so the counts the fixture writes are DERIVED, never asserted.*
_FIXTURE_MUTATIONS_TRAILER = (
    "\n\n# (fixture) the synthetic ledger carries only the rods it defines\n"
    "BOARD1_REQUIRED_IDS = tuple(i for i in BOARD1_REQUIRED_IDS if i in {s['id'] for s in SEMANTIC})\n")


_FIXTURE_GENERATOR_TRAILER = (
    "\n\n# (fixture) the synthetic ledger authors NO obligations, so every finding's terminality follows its own\n"
    "# recorded status and the derivation is coherent. *Emptying the map -- rather than marking the real obligations\n"
    "# DISCHARGED -- keeps the fixture honest: a discharge without an authored `structured_discharge` would be the\n"
    "# very unmeasured terminal claim the semantics gate existeth to refuse, so the fixture must not carry one.*\n"
    "# *The AUDIT key is kept with an EMPTY list because `build()` synthesises that finding's obligations from it.*\n"
    "PARTIAL_OBLIGATIONS = {k: [] for k in PARTIAL_OBLIGATIONS}\n")


def normalize_fixture_ledger(repo: Path, *, status: str = "REMEDIATION_IN_PROGRESS") -> dict:
    """Make a fixture's copied ledger internally consistent, using the COPY's own generator.

    *Both fixtures (this module's selftest and the readiness court) copy the real ledger and the real generator so the
    derivation is genuine. The copy's obligations are then emptied and its persisted counts REGENERATED through the
    copy's own `counts()` -- so `structured_counts` and `finding_closure` equal what the derivation produceth, which is
    exactly the state `--write` leaveth behind. Nothing is asserted that the generator did not derive.*
    """
    mutations = repo / "ci" / "mutations.py"
    if mutations.is_file():
        mutations.write_text(mutations.read_text(encoding="utf-8") + _FIXTURE_MUTATIONS_TRAILER,
                             encoding="utf-8")
    # *** THE CLOSURE GENERATOR IS A SIBLING'S FILE, EDITED WHILE RUNS HAPPEN. *** *If the copied generator does not
    # PARSE, a minimal stand-in is written whose `build`/`counts`/`load` carry the same shape -- so the fixture's
    # checks still exercise MY code, and a real generator that will not parse is a NAMED refusal at the real gate.*
    import ast as _ast
    script = repo / "scripts" / "build_structured_closure.py"
    source = script.read_text(encoding="utf-8") if script.is_file() else ""
    try:
        _ast.parse(source + _FIXTURE_GENERATOR_TRAILER)
    except SyntaxError:
        script.write_text(
            '"""A minimal stand-in for a fixture: the real generator did not parse."""\n'
            'import json\n'
            'def load(p):\n'
            '    return json.loads(open(p, encoding="utf-8").read())\n'
            'def build(ledger):\n'
            '    return {}\n'
            'def counts(closure):\n'
            '    return {"findings_total": 0, "findings_internal_open": 0,\n'
            '            "findings_with_internal_status_open": 0, "internal_obligations_open": 0,\n'
            '            "internal_obligations_unresolved": 0, "obligations_by_state": {},\n'
            '            "external_obligations": 0}\n', encoding="utf-8")
    else:
        script.write_text(source + _FIXTURE_GENERATOR_TRAILER, encoding="utf-8")
    bsc = _import_script("build_structured_closure", repo)
    ledger_path = repo / "docs/remediation/REMEDIATION_STATE.json"
    ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
    # *** AND EVERY FINDING IS SET COMPLETE, so the generator's own 'OPEN with all-terminal obligations' law -- which
    # is CORRECT for a real ledger -- does not fire on a synthetic one. The derivation still RUNS over the copy.*
    for group in (ledger.get("findings") or {},
                  (ledger.get("independent_audit_new_findings") or {}).get("findings") or {}):
        for entry in group.values():
            if "my_status" in entry:
                entry["my_status"] = "FIX_SUBMITTED"
            elif "status" in entry:
                entry["status"] = "FIX_SUBMITTED"
    closure = bsc.build(ledger)
    ca = ledger.setdefault("current_assessment", {})
    ca["finding_closure"] = closure
    ca["structured_counts"] = bsc.counts(closure)
    ledger_path.write_text(json.dumps(ledger, indent=1, ensure_ascii=False), encoding="utf-8")
    closure_path = repo / "docs/production-readiness/BOARD1_CLOSURE.json"
    doc = json.loads(closure_path.read_text(encoding="utf-8"))
    doc["status"] = status
    doc["verified_fixed"] = 0
    closure_path.write_text(json.dumps(doc, indent=1), encoding="utf-8")
    return doc


def _selftest_dirt(clean: bool, *, head: str | None = None, tree: str | None = None) -> dict:
    """A dirt report in the shape `dirt_report` produceth, for a clean or dirty fixture tree.

    *The pre-gate block also carrieth the EXECUTING head/tree, because the validator now requires the gates to have
    run at the candidate's own revision -- so a fixture that omitted them would refuse, for the right reason.*
    """
    dirty = [] if clean else ["src/prod.swift"]
    return {"tracked": dirty, "untracked": [], "all": dirty, "allow": [], "status_error": None,
            "measured_utc": _now_utc(), "ok": clean, "head_sha": head, "head_tree": tree}


def _selftest_doc(base: Path, gate_dir: Path, *, tag: str = "board1-fixture-rc",
                  campaign_dir: Path | None = None, lane_inject=None,
                  external_override=None, closure_override=None, clean=True,
                  candidate_override: dict | None = None, clean_head: str | None = None,
                  clean_tree: str | None = None, release_proof_dir: Path | None = None) -> dict:
    """Build a POSITIVE manifest over the fixture -- every check satisfied -- so each mutation is one delta.

    *`candidate_override`/`clean_head`/`clean_tree` let a case construct the final-main `A` execution (frozen `C`,
    proven executing `A`) without touching the fixture's own commit.*
    """
    import tempfile as _tf  # noqa: F401
    facts = _selftest_gate_facts(gate_dir)
    gate_facts = [{"id": f["id"], "label": f["label"], "argv": f["argv"], "rc": f["rc"],
                   "log": artifact_record(Path(f["log_path"]), base), "verdict": "PASS"} for f in facts]
    work = workdir_identity(cwd=base)
    campaign = campaign_facts(campaign_dir, base) if campaign_dir else _fixture_campaign(base)
    lanes = lane_inject(base, campaign) if lane_inject else _fixture_lanes(base)
    closure = closure_override or _fixture_closure(base)
    external = external_override or _fixture_external(base, release_proof_dir=release_proof_dir)
    cdir = _fixture_campaign_dir(base)
    _stamp_fixture_baseline(base, cdir)
    campaign = campaign_facts(cdir, base)
    exec_head = clean_head or work["head_sha"]
    exec_tree = clean_tree or work["head_tree"]
    doc = build_manifest(gate_facts=gate_facts, base=base,
                         candidate=(candidate_override if candidate_override is not None else
                                    {"tag": tag, "sha": work["head_sha"], "tree_sha": work["head_tree"],
                                     "sha_source": "tag", "tag_state": "annotated"}),
                         campaign=campaign, lanes=lanes, closure=closure, external=external,
                         clean_start=_selftest_dirt(clean, head=exec_head, tree=exec_tree),
                         clean_end=_selftest_dirt(clean, head=exec_head, tree=exec_tree),
                         campaign_dir_override=cdir,
                         ledger_ids_fn=lambda: default_ledger_ids(base),
                         tested_inputs_fn=lambda: _import_ci("mutations", base)._tested_input_digests())
    return doc


def _stamp_fixture_baseline(base: Path, cdir: Path) -> None:
    """*** STAMP THE FIXTURE CAMPAIGN WITH THE **CANDIDATE** COMMIT, WHICH A LATER `A` COMMIT DID NOT MOVE. ***

    *THE DEFECT THIS CLOSES: this used `HEAD`, so after a case committed the successor `A` the campaign was re-stamped
    at `A` -- while the manifest bindeth `C`. **The campaign ran at the CANDIDATE (a campaign for a candidate is run
    before its attestation), so the baseline is the fixture's committed candidate tag's peel, not whatever HEAD happens
    to be.***
    """
    path = cdir / "manifest.json"
    env = json.loads(path.read_text(encoding="utf-8"))
    tag = _fixture_tag(base)
    peeled = _git("rev-parse", f"{tag}^{{commit}}", cwd=base).stdout.strip() or \
        _git("rev-parse", "HEAD", cwd=base).stdout.strip()
    tree = _git("rev-parse", f"{peeled}^{{tree}}", cwd=base).stdout.strip()
    env["baseline_sha"] = peeled
    env["tested_tree_sha"] = tree
    for row in env.get("rows") or []:
        row["baseline_sha"] = peeled
        row["tested_tree_sha"] = tree
    path.write_text(json.dumps(env, indent=1) + "\n", encoding="utf-8")


def copy_rod_ledger(repo: Path) -> None:
    """Copy the rod ledger into a fixture, or write a MINIMAL STAND-IN IF THE COPY DOES NOT PARSE.

    *** WHY A STAND-IN IS HONEST HERE: THE ROD LEDGER IS A SIBLING'S FILE, AND IT IS EDITED WHILE CAMPAIGNS RUN. ***
    *A fixture that imported a syntactically broken copy would report the SIBLING's mid-flight state as MY court's
    failure. The stand-in keeps every property the fixture's checks depend on -- a `SEMANTIC` list, a
    `BOARD1_REQUIRED_IDS` set derived from it, and `_tested_input_digests()` over the FIXTURE's own tree -- so the
    refusals tested are still about MY code. Production never has a stand-in: it imports the real ledger, and a real
    ledger that will not parse is a NAMED refusal at the gate.*
    """
    import ast
    source = (ROOT / "ci" / "mutations.py").read_text(encoding="utf-8")
    try:
        ast.parse(source)
    except SyntaxError:
        (repo / "ci" / "mutations.py").write_text(
            '"""A minimal stand-in for a fixture: the real ledger did not parse."""\n'
            'import hashlib, os\n'
            'ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))\n'
            'SEMANTIC = [{"id": "FIXTURE-ROD-%d" % i} for i in range(3)]\n'
            'BOARD1_REQUIRED_IDS = tuple(s["id"] for s in SEMANTIC)\n'
            # *A FIXED, SMALL file family -- NOT a whole-tree walk. A whole-tree digest moves the moment an\n'
            # *attestation is written, which would make the fixture's own campaign look stale.*\n'
            'def _tested_input_digests():\n'
            '    h = hashlib.sha256()\n'
            '    for rel in ("src/prod.swift", "ci/mutations.py"):\n'
            '        p = os.path.join(ROOT, rel)\n'
            '        if os.path.exists(p):\n'
            '            h.update(rel.encode()); h.update(open(p, "rb").read())\n'
            '    return {"fixture_inputs": h.hexdigest()}\n', encoding="utf-8")
        return
    (repo / "ci" / "mutations.py").write_text(source, encoding="utf-8")


def _fixture_campaign_dir(base: Path) -> Path:
    """Where a fixture's campaign lives: BESIDE the repository, never inside it.

    *** A COMMIT CANNOT CONTAIN ITS OWN SHA. *** *The campaign envelope records the commit it ran at
    (`baseline_sha`), so an envelope COMMITTED into the tree could never name the commit that carries it -- which is
    exactly why the real terminal job writes it to its scratch root. The fixture does the same.*
    """
    return base.parent / (base.name + "-campaign")


def _fixture_head(base: Path) -> str:
    return _git("rev-parse", "HEAD", cwd=base).stdout.strip()


def _fixture_tree(base: Path) -> str:
    return _git("rev-parse", "HEAD^{tree}", cwd=base).stdout.strip()


def _fixture_campaign(base: Path) -> dict:
    """A REAL campaign directory: an envelope whose population is the ledger's own required set.

    *The rows are generated for EVERY id `ci/mutations.py` (the fixture's own copy) declares required, and the
    tested-input map is the derivation over THIS tree -- so the fixture's campaign is bound to the fixture's bytes the
    same way the real one is bound to the repository's.*
    """
    cdir = _fixture_campaign_dir(base)
    logs = cdir / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    mutations = _import_ci("mutations", base)
    ids = list(mutations.BOARD1_REQUIRED_IDS)
    rows = []
    for rid in ids:
        for phase in ("baseline", "mutant", "restored"):
            (logs / f"{rid}.{phase}.log").write_text(f"{rid} {phase} green roster\n", encoding="utf-8")
        rows.append({"id": rid, "outcome": "KILLED", "baseline_sha": _fixture_head(base),
                     "tested_tree_sha": _fixture_tree(base),
                     "phase_logs": {ph: {"path": f"logs/{rid}.{ph}.log",
                                         "sha256": sha256_file(logs / f"{rid}.{ph}.log")}
                                    for ph in ("baseline", "mutant", "restored")},
                     "restored_green": {"ok": True, "run": 3, "skipped": 0, "failed": []}})
    env = {"schema": 1, "lineage": "semantic", "baseline_sha": _fixture_head(base),
           "tested_tree_sha": _fixture_tree(base), "group": "board1",
           "required_ids": ids, "selected_ids": ids, "unselected_ids": [],
           "inputs": mutations._tested_input_digests(),
           "toolchain": {"swift": "x"}, "generated_utc": "2026-01-01T00:00:00Z", "rows": rows}
    (cdir / "manifest.json").write_text(json.dumps(env, indent=1) + "\n", encoding="utf-8")
    return campaign_facts(cdir, base)


def _fixture_lanes(base: Path) -> list[dict]:
    """Lane facts whose artifacts and sidecars exist in the fixture, with a digest that is re-derivable."""
    lanes = []
    for lane_id in REQUIRED_LANES:
        src = LANE_SOURCES[lane_id]
        for side in src["sidecars"]:
            (base / side).write_text("d" * 64 + "\n", encoding="utf-8")
        pattern = src["result_glob"]
        if pattern.endswith(".log"):
            produced = [base / pattern]
        else:
            produced = [base / pattern.replace("*.xml", "TEST-Fixture.xml")]
        for path in produced:
            path.parent.mkdir(parents=True, exist_ok=True)
            if path.suffix == ".xml":
                path.write_text('<?xml version="1.0"?><testsuite tests="3" skipped="0" '
                                'failures="0" errors="0"></testsuite>\n', encoding="utf-8")
            else:
                path.write_text("Test Suite 'Fixture' passed\n", encoding="utf-8")
        artifacts = [{"path": str(p.relative_to(base)), "sha256": sha256_file(p),
                      "bytes": p.stat().st_size, "kind": "file"} for p in produced]
        for extra in src.get("extra", ()):
            (base / extra).write_text("x\n", encoding="utf-8")
            artifacts.append({"path": extra, "sha256": sha256_file(base / extra), "bytes": 2, "kind": "file"})
        lanes.append({"id": lane_id, "digest": "d" * 64, "digest_recorded": "d" * 64,
                      "sidecars": [{"path": s, "sha256": sha256_file(base / s), "bytes": 65, "kind": "file"}
                                   for s in src["sidecars"]],
                      "roster_size": 3, "counts": {"tests": 3, "skipped": 0, "failures": 0, "errors": 0},
                      "problems": [], "artifacts": artifacts, "result_glob": src["result_glob"]})
    return lanes


def _fixture_closure(base: Path) -> dict:
    """The closure/ledger block over the COPIED, REAL records -- with the counts DERIVED, not asserted."""
    facts = closure_facts(base / "docs/production-readiness/BOARD1_CLOSURE.json",
                          base / "docs/remediation/REMEDIATION_STATE.json", base)
    return facts


_FIXTURE_RELEASE_ORIGINALS: dict[str, object] = {}
_FIXTURE_RELEASE_CACHE: dict[str, object] = {}


def _fixture_release_seam(base: Path) -> Path | None:
    """*** A GENUINE CAPTURED RELEASE PROOF FOR THE FIXTURE'S CANDIDATE, OVER THE RAW TRANSPORT SEAM. ***

    *The release proof is MANDATORY law, so every positive fixture MUST carry a real one -- and the reader's admission
    RE-CAPTURES it through the same owner authority, so the raw-GH transport seam is (re)installed for THIS base on
    every call, making this fixture's seam the ACTIVE one while its validators run. It is produced through the owner's
    OWN capture authority (`capture_release_proof.capture`) with the raw GH transport faked to answer the five
    release-gates jobs and the required artifact population for THIS fixture's candidate -- never by mocking the
    authenticator. The captured document is written into a scratch proof root OUTSIDE the candidate tree, exactly as
    the real terminal job does (it must not dirty the tracked tree).*
    """
    import importlib as _il  # noqa: PLC0415
    key = str(base.resolve())
    if str(ROOT / "tools" / "supplychain") not in sys.path:
        sys.path.insert(0, str(ROOT / "tools" / "supplychain"))
    try:
        cp = _il.import_module("capture_release_proof")
    except Exception:  # noqa: BLE001 - an unimportable capture authority leaves the block `available: false`
        return None
    if "gh" not in _FIXTURE_RELEASE_ORIGINALS:
        _FIXTURE_RELEASE_ORIGINALS["gh"] = cp.gh_api
        _FIXTURE_RELEASE_ORIGINALS["log"] = cp.job_log_text
        _FIXTURE_RELEASE_ORIGINALS["cp"] = cp
    sha = _git("rev-parse", "HEAD", cwd=base).stdout.strip()
    tree = _git("rev-parse", "HEAD^{tree}", cwd=base).stdout.strip()
    repo = _release_repo() or "o/r"
    run_id, attempt = 424242, 1
    run = {"id": run_id, "run_attempt": attempt, "name": "release-gates", "event": "push",
           "head_branch": "main", "head_sha": sha, "conclusion": "failure",
           "workflow_path": cp.WORKFLOW_PATH, "repository": {"full_name": repo}}
    jobs, logs = [], {}
    for i, spec in enumerate(cp.INTERNAL_JOB_SPECS):
        jobs.append({"id": 900 + i, "name": spec["display_name"], "conclusion": "success",
                     "steps": [{"name": "artifact-inspection", "conclusion": "success"}]})
    for i, spec in enumerate(cp.EXTERNAL_JOB_SPECS):
        jid = 950 + i
        jobs.append({"id": jid, "name": spec["display_name"], "conclusion": "failure", "steps": []})
        logs[str(jid)] = cp.marker_log(spec["boundary"], f"{spec['boundary']}-src", "ABSENT")
    uploaded = [{"name": a, "digest": "sha256:" + "c" * 64, "size_in_bytes": 10}
                for spec in cp.INTERNAL_JOB_SPECS for a in spec["artifacts"]]
    # *** THE SEAM IS INSTALLED FOR THIS BASE: THE READER'S MANDATORY AUTHENTICATION RE-CAPTURES THE SAME RUN. ***
    cp.gh_api = lambda path: (run if f"/actions/runs/{run_id}" in path and "/attempts/" not in path
                              and "/artifacts" not in path and "/jobs" not in path
                              else {"jobs": jobs} if path.endswith("/jobs?per_page=100")
                              else {"artifacts": uploaded} if "/artifacts" in path
                              else {"commit": {"tree": {"sha": tree}}} if "/commits/" in path else None)
    cp.job_log_text = lambda repo_, job_id: logs.get(str(job_id), "")
    if key not in _FIXTURE_RELEASE_CACHE:
        proof_dir = base.parent / "board1-release-proof-fixture"
        proof_dir.mkdir(parents=True, exist_ok=True)
        try:
            doc = cp.capture(repo, run_id, attempt, sha)
            (proof_dir / f"{run_id}-{attempt}.json").write_text(json.dumps(doc), encoding="utf-8")
            _FIXTURE_RELEASE_CACHE[key] = proof_dir
        except Exception:  # noqa: BLE001 - a capture that cannot run leaves the block `available: false`
            _FIXTURE_RELEASE_CACHE[key] = None
    return _FIXTURE_RELEASE_CACHE[key]


def _restore_fixture_release_seams() -> None:
    """Restore the original raw-GH transport (call once at the end of a selftest/court)."""
    cp = _FIXTURE_RELEASE_ORIGINALS.get("cp")
    if cp is not None:
        if "gh" in _FIXTURE_RELEASE_ORIGINALS:
            cp.gh_api = _FIXTURE_RELEASE_ORIGINALS["gh"]
        if "log" in _FIXTURE_RELEASE_ORIGINALS:
            cp.job_log_text = _FIXTURE_RELEASE_ORIGINALS["log"]
    _FIXTURE_RELEASE_ORIGINALS.clear()
    _FIXTURE_RELEASE_CACHE.clear()


def _fixture_external(base: Path, *, anchors: dict | None = None,
                      release_proof_dir: Path | None = None) -> dict:
    (base / "docs/production-readiness/EXTERNAL_BLOCKERS.json").write_text(
        json.dumps({"blockers": [{"id": "A06", "status": "BLOCKED_EXTERNAL"}]}), encoding="utf-8")
    blockers_rec = artifact_record(base / "docs/production-readiness/EXTERNAL_BLOCKERS.json", base)
    if anchors is None:
        # *** THE FIXTURE CARRIES NO rc14 OBJECTS, SO ITS ANCHOR SPEC IS REGISTERED OVER THE FIXTURE'S OWN TAG. ***
        # *`anchor_facts` still DERIVES every identity from git -- the fixture's own annotated tag, its child commit
        # and the blob at that child -- so the anchor clause is exercised by real derivation, not stubbed out.*
        anchors = anchor_facts(base)
    historical = []
    for spec in anchor_specs_for(base):
        hist_rec = artifact_record(base / spec["path"], base)
        historical.append({**(hist_rec or {"path": spec["path"]}), "anchor": spec["sha256"]})
    if release_proof_dir is not None:
        proof_block = release_proof_facts(release_proof_dir, base)
    else:
        proof_dir = _fixture_release_seam(base)
        proof_block = (release_proof_facts(proof_dir, base) if proof_dir is not None
                       else {"interface": RELEASE_PROOF_INTERFACE, "available": False, "required": True,
                             "records": [], "problems": []})
    return {"blockers": {"record": blockers_rec, "count": 1, "statuses": {"A06": "BLOCKED_EXTERNAL"}},
            "release_gates": {"record": None, "note": "absent"},
            "historical": historical, "problems": [],
            "anchors": anchors,
            "release_proof": proof_block}


def _fixture_anchor_spec(base: Path, *, tag: str | None = None) -> tuple[dict, ...]:
    """A REAL anchor spec for the fixture: its own annotated tag, its direct child and the blob at that child.

    *THE FIXTURE CANNOT CARRY rc14 -- that candidate belongs to the real repository. So it carries its OWN immutable
    anchor in the same SHAPE: the candidate is the TAGGED commit `C`, and the anchor file exists ONLY on `C`'s
    DIRECT CHILD, exactly as the original rc14 attestation exists only on `A14`.* **The child is a REAL commit -- made
    by committing the file and then `git reset --hard` back to `C`, so the child's parent IS `C`, the file IS in the
    child's tree, and the fixture's HEAD stays at `C` with a clean worktree.** *`anchor_facts` then derives every
    identity -- tag object, peel, tree, the child's parent, the child's blob and its sha256 -- from these REAL git
    objects, so a check that stopped reading git would fail here exactly as it would on the real rc14 anchor.*
    """
    rel = "docs/remediation/evidence/FREEZE_ATTESTATION_fixture.json"
    run = lambda *a: subprocess.run(["git", "-C", str(base), *a], capture_output=True, text=True, check=False)
    tag = tag or _fixture_tag(base)
    peel = run("rev-parse", f"{tag}^{{commit}}")
    if peel.returncode != 0:
        raise RuntimeError(f"the fixture anchor needs an existing annotated tag; {tag!r} does not resolve")
    peeled = peel.stdout.strip()
    tree = run("rev-parse", f"{peeled}^{{tree}}").stdout.strip()
    anchor_path = base / rel
    anchor_path.parent.mkdir(parents=True, exist_ok=True)
    anchor_path.write_text('{"fixture": "the immutable anchor of the fixture candidate"}\n', encoding="utf-8")
    run("add", "-A")
    commit = run("commit", "-q", "-m", "the fixture anchor child")
    if commit.returncode != 0:
        raise RuntimeError(f"the fixture anchor child commit failed: {commit.stderr.strip()[:200]}")
    child = run("rev-parse", "HEAD").stdout.strip()
    blob_sha = run("rev-parse", f"{child}:{rel}").stdout.strip()
    digest = sha256_file(anchor_path)
    # *** AND THE FIXTURE RETURNS TO `C`, SO ITS OWN WORKTREE IS CLEAN AT THE CANDIDATE. ***
    reset = run("reset", "--hard", peeled)
    if reset.returncode != 0:
        raise RuntimeError(f"the fixture could not return to the candidate: {reset.stderr.strip()[:200]}")
    return ({
        "path": rel,
        "tag": tag,
        "tag_object_sha": run("rev-parse", tag).stdout.strip(),
        "peeled_commit": peeled,
        "tree_sha": tree,
        "child": child,
        "blob_sha": blob_sha,
        "sha256": digest,
    },)


def _fixture_tag(base: Path) -> str:
    """The fixture candidate tag: the repository's own ANNOTATED tag, discovered rather than assumed."""
    run = lambda *a: subprocess.run(["git", "-C", str(base), *a], capture_output=True, text=True, check=False)
    out = run("for-each-ref", "--format=%(objecttype) %(refname:short)", "refs/tags").stdout
    for line in out.splitlines():
        kind, _, name = line.partition(" ")
        if kind.strip() == "tag" and name.strip():
            return name.strip()
    raise RuntimeError("the fixture repository carries no annotated tag to anchor")


def selftest() -> int:
    """*** ADVERSARIAL, DETERMINISTIC, AND AGAINST REAL BYTES. ***

    *Every case runs over a REAL throwaway git repository with a REAL annotated tag and REAL artifact files, so a
    check that quietly stopped reading git, the bytes or the campaign envelope would be caught here. Each REFUSAL case
    asserts the exact refusal text, so a mutation that merely crashed the checker would not pass for a kill; the
    POSITIVE case proves the same construction is accepted, so a check that refused everything would not pass either.*
    """
    import tempfile
    failures = 0
    checks = 0

    def expect(problems: list[str], needle: str, label: str) -> None:
        nonlocal failures, checks
        checks += 1
        if any(needle in p for p in problems):
            print(f"   PASS: {label}")
        else:
            print(f"   FAIL: {label} -- expected {needle!r}, got {problems[:4]}")
            failures += 1

    def expect_ok(problems: list[str], label: str) -> None:
        nonlocal failures, checks
        checks += 1
        if problems:
            print(f"   FAIL: {label} -- REFUSED the positive fixture: {problems[:4]}")
            failures += 1
        else:
            print(f"   PASS: {label}")

    def expect_refused(fn, needle: str, label: str) -> None:
        nonlocal failures, checks
        checks += 1
        try:
            fn()
        except ManifestRefused as exc:
            if any(needle in p for p in exc.problems):
                print(f"   PASS: {label}")
                return
            print(f"   FAIL: {label} -- refused for the WRONG reason: {exc.problems[:4]}")
            failures += 1
            return
        print(f"   FAIL: {label} -- the builder ACCEPTED an incomplete run")
        failures += 1

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        base = _fixture_repo(root)
        gate_dir = root / "gates"
        doc = _selftest_doc(base, gate_dir)
        print(f"BOARD 1 manifest selftest (fixture repo at {base})")

        # ---- POSITIVE: the fixture construction is ACCEPTED, with every check re-derived ----
        expect_ok(check_manifest(doc, base=base), "the full fixture manifest is accepted")
        expect_ok(check_manifest(doc, base=base), "validation is IDEMPOTENT (writes nothing, takes no timestamp)")

        # ---- 1. absent candidate: no tag, no sha ----
        bad = json.loads(json.dumps(doc))
        bad["candidate"] = {"tag": None, "sha": None, "tree_sha": None}
        expect(check_manifest(bad, base=base), "is not a full 40-hex commit",
               "a manifest with no candidate SHA is refused")
        expect(check_manifest(bad, base=base), "is not a full 40-hex tree",
               "a manifest with no candidate TREE is refused")

        # ---- 2. missing gate row ----
        bad = json.loads(json.dumps(doc))
        bad["gates"]["rows"] = [r for r in bad["gates"]["rows"] if r["id"] != "lane-results"]
        expect(check_manifest(bad, base=base), "omits required gate(s): ['lane-results']",
               "a manifest omitting a required gate is refused")

        # ---- 3. extra / renamed gate ----
        bad = json.loads(json.dumps(doc))
        bad["gates"]["rows"][0]["id"] = "renamed-gate"
        expect(check_manifest(bad, base=base), "does not define", "a renamed gate id is refused")

        # ---- 4. duplicated gate id ----
        bad = json.loads(json.dumps(doc))
        bad["gates"]["rows"].append(dict(bad["gates"]["rows"][0]))
        expect(check_manifest(bad, base=base), "duplicated gate id(s)",
               "a duplicated gate row is refused")

        # ---- 5. nonzero rc smuggled into a PASS verdict ----
        bad = json.loads(json.dumps(doc))
        bad["gates"]["rows"][2]["rc"] = 1
        expect(check_manifest(bad, base=base), "only a full run in which EVERY required gate returned zero",
               "a non-zero gate exit is refused")

        # ---- 6. tampered gate log ----
        bad = json.loads(json.dumps(doc))
        log_rel = bad["gates"]["rows"][0]["log"]["path"]
        (base / log_rel).write_text("EDITED AFTER THE MANIFEST BOUND IT\n", encoding="utf-8")
        expect(check_manifest(bad, base=base), "was EDITED after the manifest bound it",
               "a tampered gate log is refused")
        _selftest_gate_facts(gate_dir)  # restore

        # ---- 7. missing gate log file ----
        bad = json.loads(json.dumps(doc))
        (base / bad["gates"]["rows"][3]["log"]["path"]).unlink()
        expect(check_manifest(bad, base=base), "is NOT PRESENT", "an absent gate log is refused")

        # ---- 8. wrong argv ----
        bad = json.loads(json.dumps(doc))
        bad["gates"]["rows"][1]["argv"] = [sys.executable, "-c", "pass"]
        expect(check_manifest(bad, base=base), "an unaccounted command is not this contract's gate",
               "a gate run with different argv is refused")
        doc = _selftest_doc(base, gate_dir)

        # ---- 9. dirty start/end ----
        bad = json.loads(json.dumps(doc))
        bad["clean_start"] = {**doc["clean_start"], "ok": False, "tracked": ["src/prod.swift"],
                              "all": ["src/prod.swift"]}
        expect(check_manifest(bad, base=base), "uncommitted TRACKED change(s)",
               "a dirty start is refused")
        bad = json.loads(json.dumps(doc))
        bad["clean_end"] = {**doc["clean_end"], "ok": False, "tracked": ["src/prod.swift"],
                            "all": ["src/prod.swift"]}
        expect(check_manifest(bad, base=base), "uncommitted TRACKED change(s)",
               "a dirty end is refused")
        # *** AND UNTRACKED PATHS MAKE A STATUS UNCLEAN TOO. ***
        bad = json.loads(json.dumps(doc))
        bad["clean_start"] = {**doc["clean_start"], "ok": False, "untracked": ["scratch/"],
                              "all": ["scratch/"]}
        expect(check_manifest(bad, base=base), "UNTRACKED path(s)",
               "an UNTRACKED path in the tree is refused")

        # ---- 10. lightweight tag ----
        import subprocess as sp
        sp.run(["git", "-C", str(base), "tag", "board1-light", "-f", doc["candidate"]["sha"]],
               capture_output=True, text=True)
        bad = json.loads(json.dumps(doc))
        bad["candidate"]["tag"] = "board1-light"
        expect(check_manifest(bad, base=base), "is LIGHTWEIGHT", "a lightweight candidate tag is refused")

        # ---- 11. tag/sha disagreement ----
        bad = json.loads(json.dumps(doc))
        bad["candidate"]["tree_sha"] = "0" * 40
        expect(check_manifest(bad, base=base), "the manifest stateth tree",
               "a stated tree the tag does not carry is refused")

        # ---- 12. campaign: missing row for a required id ----
        bad = json.loads(json.dumps(doc))
        bad["campaign"] = json.loads(json.dumps(doc["campaign"]))
        bad["campaign"]["population"]["missing_rows"] = [REQUIRED_ROD_SAMPLE[1]]
        expect(check_manifest(bad, base=base), "carrieth NO row for selected id(s)",
               "a campaign missing a required row is refused")

        # ---- 13. campaign: a rod not KILLED ----
        bad = json.loads(json.dumps(doc))
        bad["campaign"] = json.loads(json.dumps(doc["campaign"]))
        bad["campaign"]["population"]["rows_by_id"][REQUIRED_ROD_SAMPLE[0]] = "ESCAPED"
        bad["campaign"]["all_killed"] = False
        expect(check_manifest(bad, base=base), "required rod(s) not KILLED",
               "a campaign rod that ESCAPED is refused")

        # ---- 14. campaign: narrowed selection ----
        bad = json.loads(json.dumps(doc))
        bad["campaign"] = json.loads(json.dumps(doc["campaign"]))
        bad["campaign"]["population"]["selected_ids"] = [REQUIRED_ROD_SAMPLE[0]]
        bad["campaign"]["population"]["unselected_required"] = [REQUIRED_ROD_SAMPLE[1]]
        expect(check_manifest(bad, base=base), "OMITTED", "a narrowed campaign population is refused")

        # ---- 15. campaign: tested input MOVED ----
        bad = json.loads(json.dumps(doc))
        bad["campaign"] = json.loads(json.dumps(doc["campaign"]))
        moved = dict(bad["campaign"]["tested_inputs"])
        moved["ci/mutations.py"] = "1" * 64
        bad["campaign"]["tested_inputs"] = moved
        expect(check_manifest(bad, base=base), "has MOVED since the campaign",
               "a campaign whose tested input moved is refused")

        # ---- 16. campaign: manifest digest / directory changed (a phase log edited) ----
        bad = json.loads(json.dumps(doc))
        (_fixture_campaign_dir(base) / "logs"
         / f"{REQUIRED_ROD_SAMPLE[0]}.mutant.log").write_text("EDITED\n", encoding="utf-8")
        expect(check_manifest(bad, base=base), "the campaign directory digest does not recompute",
               "a campaign phase log edited after binding is refused")
        _fixture_campaign(base)
        doc = _selftest_doc(base, gate_dir)

        # ---- 17. campaign manifest absent ----
        bad = json.loads(json.dumps(doc))
        bad["campaign"] = json.loads(json.dumps(doc["campaign"]))
        bad["campaign"]["manifest_path"] = str(_fixture_campaign_dir(base) / "manifest.json")
        (base / bad["campaign"]["manifest_path"]).unlink()
        expect(check_manifest(bad, base=base), "is NOT PRESENT", "an absent campaign manifest is refused")
        _fixture_campaign(base)
        doc = _selftest_doc(base, gate_dir)

        # ---- 18. stale lane digest ----
        bad = json.loads(json.dumps(doc))
        bad["lanes"][0]["digest"] = "0" * 64
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "THE LANE IS STALE", "a stale lane source digest is refused")

        # ---- 19. lane sidecar missing / pre-post disagree ----
        bad = json.loads(json.dumps(doc))
        side = bad["lanes"][0]["sidecars"][0]["path"]
        (base / side).unlink()
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "is NOT PRESENT", "an absent lane sidecar is refused")
        _fixture_lanes(base)
        doc = _selftest_doc(base, gate_dir)
        bad = json.loads(json.dumps(doc))
        bad["lanes"][0]["sidecars"][0]["sha256"] = "0" * 64
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "does not match the digest the manifest bound",
               "a lane sidecar whose bytes moved is refused")
        _fixture_lanes(base)
        bad = json.loads(json.dumps(doc))
        pre = REQUIRED_LANES[0]
        (base / LANE_SOURCES[pre]["sidecars"][0]).write_text("a" * 64 + "\n", encoding="utf-8")
        bad = json.loads(json.dumps(doc))
        bad["lanes"][0]["sidecars"][0]["sha256"] = sha256_file(base / LANE_SOURCES[pre]["sidecars"][0])
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "does not match POST-RUN", "a lane whose input changed mid-run is refused")
        doc = _selftest_doc(base, gate_dir)

        # ---- 20. lane omitted entirely ----
        bad = json.loads(json.dumps(doc))
        bad["lanes"] = [l for l in bad["lanes"] if l["id"] != "ios:simulator"]
        expect(check_manifest(bad, base=base), "omits required lane(s): ['ios:simulator']",
               "a manifest omitting a required lane is refused")

        # ---- 21. lane with no counts recorded ----
        bad = json.loads(json.dumps(doc))
        bad["lanes"][1]["counts"] = None
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "carrieth NO parsed counts", "a lane with no parsed counts is refused")

        # ---- 22. lane artifact absent and not published ----
        bad = json.loads(json.dumps(doc))
        art = bad["lanes"][0]["artifacts"][0]["path"]
        (base / art).unlink()
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "names NO hosted artifact", "an absent, unidentified lane artifact is refused")
        _fixture_lanes(base)
        doc = _selftest_doc(base, gate_dir)

        # ---- 23. lane whose own checker goes RED on re-check ----
        expect(check_manifest(doc, base=base, lane_digest_fn=lambda _l: "d" * 64,
                              lane_problems_fn=lambda _l: ["a required arm did not execute"]),
               "(re-checked): a required arm did not execute",
               "a lane that goes red on re-check is refused")

        # ---- 24. lane roster changed ----
        expect(check_manifest(doc, base=base, lane_digest_fn=lambda _l: "d" * 64,
                              lane_roster_fn=lambda _l: 4),
               "roster size", "a lane whose roster changed since the run is refused")

        # ---- 24b. THE REPORT-LANE TABLES AND THE REGISTRY: ONE TRUTH, OR A NAMED REFUSAL ----
        # *The manifest hardcodes WHERE to look; the registry OWNS what lives there. An unobserved drift between
        # them (evidence path renamed, a court dropped from the required population, a lane omitted from the
        # roster obligation) would make the manifest certify paths that no longer exist -- so equality is checked
        # at the source, not trusted from either table.*
        reg = _lane_registry()
        drift = []
        for _lid in reg.REPORT_LANES:
            _src = LANE_SOURCES.get(_lid) or {}
            _spec = reg.LANE_SPECS[_lid]
            if _src.get("result_glob") != _spec["results_glob"]:
                drift.append(f"{_lid}: manifest result_glob {_src.get('result_glob')!r} is not the registry's "
                             f"{_spec['results_glob']!r}")
            if set(_src.get("sidecars") or ()) != {_spec["sidecar"], _spec["pre_sidecar"]}:
                drift.append(f"{_lid}: manifest sidecars {tuple(_src.get('sidecars') or ())!r} are not the "
                             f"registry's ({_spec['sidecar']!r}, {_spec['pre_sidecar']!r})")
            if _lid not in REQUIRED_LANES:
                drift.append(f"{_lid}: a report lane is absent from REQUIRED_LANES -- unrun would pass uncounted")
            if _report_class_roster(_lid) != len(_spec.get("required_classes", ())):
                drift.append(f"{_lid}: the roster derivation does not reproduce the registry's required population")
        expect_ok(drift, "the manifest's report-lane tables mirror the registry -- no second truth to drift")

        # ---- 25. closure record tampered ----
        bad = json.loads(json.dumps(doc))
        (base / "docs/production-readiness/BOARD1_CLOSURE.json").write_text(
            json.dumps({"status": "READY_FOR_EXTERNAL_REAUDIT", "verified_fixed": 0}), encoding="utf-8")
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "does not match the digest the manifest bound",
               "a closure record edited after binding is refused")
        (base / "docs/production-readiness/BOARD1_CLOSURE.json").write_text(
            json.dumps({"status": "REMEDIATION_IN_PROGRESS", "verified_fixed": 0}), encoding="utf-8")
        doc = _selftest_doc(base, gate_dir)

        # ---- 26. closure/ledger structured-count disagreement ----
        drifted = dict(doc["derived_counts"])
        drifted["internal_obligations_open"] = drifted.get("internal_obligations_open", 0) + 3
        expect(check_manifest({**doc, "derived_counts": drifted},
                              base=base, lane_digest_fn=lambda _l: "d" * 64),
               "structured counts DISAGREE",
               "a manifest whose structured counts disagree with the ledger is refused")

        # ---- 27. closure CLOSED over live internal work: the counts AGREE with the ledger, and the ledger carries
        #    open obligations -- so the refusal is the closure LAW, not a digest mismatch.
        bad = json.loads(json.dumps(doc))
        bad["closure"]["status"] = "READY_FOR_EXTERNAL_REAUDIT"
        bad["closure"]["record"] = artifact_record(base / "docs/production-readiness/BOARD1_CLOSURE.json", base)
        bad["derived_counts"] = {**doc["derived_counts"], "internal_obligations_open": 2}
        real_check = globals()["_import_script"]
        globals()["_import_script"] = lambda name, b=base: _StubClosure(bad["derived_counts"])
        try:
            expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
                   "the control plane may not report closure over live internal work",
                   "a closure claim over open internal obligations is refused")
        finally:
            globals()["_import_script"] = real_check

        # ---- 28. verified_fixed written by the builder ----
        bad = json.loads(json.dumps(doc))
        bad["closure"]["verified_fixed"] = 1
        bad["closure"]["record"] = artifact_record(base / "docs/production-readiness/BOARD1_CLOSURE.json", base)
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "only an INDEPENDENT auditor may write it",
               "a builder-written verified_fixed is refused")

        # ---- 29. external evidence: blockers edited / historical missing ----
        bad = json.loads(json.dumps(doc))
        (base / "docs/production-readiness/EXTERNAL_BLOCKERS.json").write_text("{}", encoding="utf-8")
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "does not match the digest the manifest bound",
               "an edited external register is refused")
        _fixture_external(base)
        bad = json.loads(json.dumps(doc))
        bad["external_evidence"]["historical"] = [{"path": "docs/remediation/evidence/GONE.json", "missing": True}]
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "is MISSING", "an absent historical evidence identity is refused")

        # ---- 29b. *** THE IMMUTABLE ANCHOR: A RE-POINTED TAG, A REWRITTEN BLOB OR A RE-HASHED FILE. *** ----
        #
        # *THE DEFECT THIS CLOSES: historical evidence was bound only by the digest of the WORKING file, so a manifest
        # could certify re-hashed bytes as the frozen original and a moved tag would go unnoticed. The anchor is now
        # re-derived from Git objects, and each of the three forgeries is refused BY NAME.*
        bad = json.loads(json.dumps(doc))
        bad["external_evidence"]["anchors"]["anchors"][0]["tag_object"] = "0" * 40
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "the manifest stateth tag_object", "a re-pointed anchor tag is refused")
        bad = json.loads(json.dumps(doc))
        bad["external_evidence"]["anchors"]["anchors"][0]["blob_sha"] = "0" * 40
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "the manifest stateth blob_sha", "a rewritten anchor blob is refused")
        bad = json.loads(json.dumps(doc))
        bad["external_evidence"]["anchors"]["anchors"][0]["blob_sha256"] = "0" * 64
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "the manifest stateth blob_sha256", "a re-hashed anchor blob is refused")
        # *AND THE LIVE DERIVATION BITES INDEPENDENTLY: a manifest that omits the block entirely is refused.*
        bad = json.loads(json.dumps(doc))
        bad["external_evidence"]["anchors"] = {}
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "NO immutable-anchor block", "a manifest that binds no immutable anchor is refused")
        # *AND A LIVE TAG MOVE IS CAUGHT BY THE DERIVATION, NOT BY THE MANIFEST'S OWN RECORD: the anchor spec is
        # re-pointed so the LIVE tag no longer matches the spec, and the validator -- which re-derives the live facts
        # -- refuses.*
        specs = list(ANCHOR_SPEC_OVERRIDES[str(Path(base).resolve())])
        moved = [dict(specs[0], tag_object_sha="0" * 40)]
        register_anchor_specs(base, tuple(moved))
        try:
            expect(check_manifest(doc, base=base, lane_digest_fn=lambda _l: "d" * 64),
                   "RE-POINTED", "a tag whose object no longer matches the anchor is refused")
        finally:
            register_anchor_specs(base, tuple(specs))

        # ---- 29c. *** THE GATES MUST HAVE RUN AT THE CANDIDATE'S OWN REVISION. *** ----
        bad = json.loads(json.dumps(doc))
        bad["clean_start"] = {**bad["clean_start"], "head_sha": "0" * 40}
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "gates executed at HEAD", "a gate run from another checkout is refused")
        bad = json.loads(json.dumps(doc))
        bad["clean_start"] = {**bad["clean_start"], "head_sha": None}
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "NO executing HEAD", "a gate run whose revision is unrecorded is refused")
        bad = json.loads(json.dumps(doc))
        bad["clean_end"] = {**bad["clean_end"], "head_sha": "1" * 40}
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "HEAD MOVED during the gate run", "a revision that moved mid-run is refused")
        # *** 29d. THE MISSING END IDENTITY AND THE DRIFTED END TREE -- THE DEFECT THIS MISSION CLOSES. ***
        #    *`build_from_gates` used to omit these, and the old validator only bit WHEN they happened to exist; now a
        #    missing end HEAD/TREE is itself named, so "nothing recorded" can never pass for "nothing moved".*
        bad = json.loads(json.dumps(doc))
        bad["clean_end"] = {k: v for k, v in bad["clean_end"].items() if k not in ("head_sha", "head_tree")}
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "clean_end carrieth NO executing HEAD", "a MISSING end identity is refused, not skipped")
        bad = json.loads(json.dumps(doc))
        bad["clean_end"] = {**bad["clean_end"], "head_tree": "2" * 40}
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "the tree DRIFTED during the run", "an end TREE that drifted from the candidate is refused")
        bad = json.loads(json.dumps(doc))
        bad["clean_start"] = {**bad["clean_start"], "head_tree": "3" * 40}
        bad["clean_end"] = {**bad["clean_end"], "head_tree": "4" * 40}
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "TREE MOVED during the gate run", "a TREE that moved mid-run is refused even when heads agree")

        # ---- 29e. *** THE INTERNAL SEMANTIC OBLIGATIONS MUST BE CLOSED, NOT MERELY A STATUS ENUM. *** ----
        #    *The derived population is the MEASURED half: a manifest standing PASS over live internal obligations is the
        #    overclaim this contract refuseth, whatever the closure STATUS sayeth.*
        bad = json.loads(json.dumps(doc))
        bad["derived_counts"] = {**bad["derived_counts"], "internal_obligations_open": 2}
        bad["ledger"] = {**bad["ledger"],
                         "structured_counts": dict(bad["derived_counts"])}
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "internal semantic obligation(s) remain OPEN",
               "a manifest over open internal semantic obligations is refused")
        # *And the semantic provenance block is REQUIRED: a manifest binding no per-obligation semantics is refused.*
        bad = json.loads(json.dumps(doc))
        bad["closure"] = {k: v for k, v in bad["closure"].items() if k != "semantics"}
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "binds NO structured semantic provenance",
               "a manifest with no per-obligation semantic provenance is refused")
        # *And a terminal claim with no measurable control is refused by name.*
        bad = json.loads(json.dumps(doc))
        bad["closure"]["semantics"] = {**bad["closure"]["semantics"],
                                       "refused_controls": [{"finding": "F", "obligation": "o-1", "why": "x"}]}
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "NO measurable control",
               "a DISCHARGED obligation with no measurable control is refused")

        # ---- 29f. *** THE SUCCESSOR RELATION: THE EXACT ONE-FILE DIRECT CHILD vs A SECOND CHANGED FILE. *** ----
        #
        # *THE RELATION HAS TWO HALVES: a STRUCTURAL half (direct child, delta exactly the one attestation, document
        # declares C) and an AUTHENTICATED half (the full terminal authority).* **The structural half is exercised
        # HERE against the fixture's own git -- it needs no hosted run; the AUTHENTICATED half is exercised by the
        # class-arm courts with a stubbed transport serving REAL bytes, and by the board1 CLI court.** *The fixture
        # resets the branch to `C` (the candidate tag's peel) so this case's commit is `C`'s DIRECT CHILD, and stages
        # EXACTLY the one attestation file -- an `-A` stage would sweep the lane sidecars into `A` and make the delta
        # seven files.*
        att_rel = "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"
        cand_c_sha = _git("rev-parse", "board1-fixture-rc^{commit}", cwd=base).stdout.strip()
        cand_c_tree = _git("rev-parse", f"{cand_c_sha}^{{tree}}", cwd=base).stdout.strip()
        sys.path.insert(0, str(ROOT / "ci"))
        import check_candidate_binding as _ccb_scope  # noqa: PLC0415
        _saved_ccb_root = _ccb_scope.ROOT
        _ccb_scope.ROOT = base
        _git("reset", "--hard", cand_c_sha, cwd=base)
        att_file = base / att_rel
        att_file.parent.mkdir(parents=True, exist_ok=True)
        att_file.write_text(json.dumps({"candidate_sha": cand_c_sha,
                                        "candidate_tree_sha": cand_c_tree}), encoding="utf-8")
        # *** THE `A` COMMIT STAGES EXACTLY THE ONE ATTESTATION FILE (never `-A`: the lane sidecars would join it). ***
        _git("add", "--", att_rel, cwd=base)
        _git("commit", "-q", "-m", "attestation", cwd=base)
        a_sha = _git("rev-parse", "HEAD", cwd=base).stdout.strip()
        # *A SECOND changed file makes the delta more than the one attestation.*
        (base / "src" / "extra.txt").write_text("x\n", encoding="utf-8")
        _git("add", "--", "src/extra.txt", cwd=base)
        _git("commit", "-q", "-m", "second file", cwd=base)
        a2 = _git("rev-parse", "HEAD", cwd=base).stdout.strip()
        # *** THE STRUCTURAL DELTA LAW, DRIVEN DIRECTLY: ONE FILE ADMITTED, TWO REFUSED. ***
        checks += 1
        rel_ok = _ccb_attest_exclusion_policy_delta(cand_c_sha, a_sha, att_rel, base)
        rel_bad = _ccb_attest_exclusion_policy_delta(cand_c_sha, a2, att_rel, base)
        if not rel_ok and any("delta" in p for p in rel_bad):
            print("   PASS: the delta law admits the ONE-file A and refuses the TWO-file successor")
        else:
            print(f"   FAIL: the delta law mis-judged the successors -- ok={rel_ok}, bad={rel_bad}")
            failures += 1
        # *** AND A DOCUMENT THAT DECLARES ANOTHER CANDIDATE IS REFUSED BY THE STRUCTURAL HALF. ***
        att_file.write_text(json.dumps({"candidate_sha": "f" * 40}), encoding="utf-8")
        _git("add", "--", att_rel, cwd=base)
        _git("commit", "-q", "--amend", "-m", "attestation", cwd=base)
        a3 = _git("rev-parse", "HEAD", cwd=base).stdout.strip()
        checks += 1
        if any("bindeth candidate" in p for p in _ccb_attest_exclusion_policy_delta(cand_c_sha, a3, att_rel, base)):
            print("   PASS: the structural half refuses a document that declares ANOTHER candidate")
        else:
            print("   FAIL: a wrong-binding successor was not refused by the structural half")
            failures += 1
        _git("reset", "--hard", doc["candidate"]["sha"], cwd=base)
        if att_file.is_file():
            att_file.unlink()
        _ccb_scope.ROOT = _saved_ccb_root
        doc = _selftest_doc(base, gate_dir)

        # ---- 29g. *** THE LANE COUNTS MUST BE DERIVED FROM THE SUPPLIED EVIDENCE ROOT. *** ----
        # *A JUnit XML placed under an evidence root (never in the tree) must drive the lane's parsed counts.*
        evr = root / "evr"
        xml_rel = LANE_SOURCES["android:app"]["result_glob"].replace("*.xml", "TEST-Rooted.xml")
        (evr / xml_rel).parent.mkdir(parents=True, exist_ok=True)
        (evr / xml_rel).write_text('<?xml version="1.0"?><testsuite tests="5" skipped="0" failures="0" '
                                   'errors="0"></testsuite>\n', encoding="utf-8")
        rooted = android_lane_totals("android:app", base, evidence_root=evr)
        checks += 1
        if rooted["tests"] == 5:
            print("   PASS: the Android lane counts are derived from the SUPPLIED evidence root")
        else:
            print(f"   FAIL: the lane counts ignored the evidence root -- got {rooted}")
            failures += 1

        # ---- 31. release evidence: a record unbound to the candidate ----
        bad = json.loads(json.dumps(doc))
        body = {"schema": 1, "run_id": "1", "run_attempt": 2, "head_sha": doc["candidate"]["sha"],
                "workflow": "repository-verification", "job": "ios core + mesh tests + Archive-only xcodebuild",
                "steps": [], "external_ids": {}, "artifacts": [], "verdict": "PASS", "refusals": [],
                "candidate": {"sha": "f" * 40, "tag": "board1-fixture-rc"}}
        body["document_sha256"] = sha256_bytes(
            json.dumps(body, sort_keys=True, separators=(",", ":")).encode("utf-8"))
        bad["external_evidence"]["release_proof"] = {
            "interface": RELEASE_PROOF_INTERFACE, "available": False, "required": False,
            "records": [{"record": {"path": "docs/remediation/evidence/board1-release-proof/1-2.json",
                                    "sha256": "0" * 64, "bytes": 1},
                         "document_sha256": body["document_sha256"],
                         "candidate": body["candidate"], "run_id": "1", "run_attempt": 2, "problems": []}],
            "problems": []}
        expect(check_manifest(bad, base=base, lane_digest_fn=lambda _l: "d" * 64),
               "not the candidate", "a release proof bound to another candidate is refused")

        # ---- 32. the BUILDER refuses to emit from an incomplete run (missing gate artifact) ----
        incomplete = _selftest_gate_facts(root / "gates2", drop={"readiness-suites"})
        facts = [{"id": f["id"], "label": f["label"], "argv": f["argv"], "rc": f["rc"],
                  "log": artifact_record(Path(f["log_path"]), base) if Path(f["log_path"]).is_file() else None,
                  "verdict": "PASS" if f["rc"] == 0 else "FAIL"} for f in incomplete]
        for f in facts:
            if f["id"] == "readiness-suites":
                f["verdict"] = "MISSING"
                f["log"] = None
        campaign = _fixture_campaign(base)
        expect_refused(lambda: build_manifest(gate_facts=facts, base=base,
                                              candidate=doc["candidate"], campaign=campaign,
                                              lanes=_fixture_lanes(base), closure=_fixture_closure(base),
                                              external=_fixture_external(base),
                                              clean_start={"ok": True, "dirty_tracked": []},
                                              clean_end={"ok": True, "dirty_tracked": []}),
                       "NO artifact at all", "the builder REFUSES to emit from an incomplete gate run")

        # ---- 33. the BUILDER refuses on a non-zero gate ----
        nonzero = _selftest_gate_facts(root / "gates3", rc_override={"evidence-digests": 1})
        facts = [{"id": f["id"], "label": f["label"], "argv": f["argv"], "rc": f["rc"],
                  "log": artifact_record(Path(f["log_path"]), base), "verdict": "PASS" if f["rc"] == 0 else "FAIL"}
                 for f in nonzero]
        expect_refused(lambda: build_manifest(gate_facts=facts, base=base,
                                              candidate=doc["candidate"], campaign=_fixture_campaign(base),
                                              lanes=_fixture_lanes(base), closure=_fixture_closure(base),
                                              external=_fixture_external(base),
                                              clean_start={"ok": True, "dirty_tracked": []},
                                              clean_end={"ok": True, "dirty_tracked": []}),
                       "NON-ZERO", "the builder REFUSES to emit after a non-zero gate")

        # ---- 34. a tampered manifest on disk is refused READ-ONLY, and never rewritten ----
        out = root / "manifest.json"
        _write_atomic(out, json.dumps(doc, indent=1) + "\n")
        before = out.read_bytes()
        problems = check_manifest(json.loads(out.read_text(encoding="utf-8")), base=base)
        print(f"   PASS: on-disk manifest validates read-only ({len(problems)} problem(s))" if not problems
              else f"   FAIL: the on-disk fixture manifest did not validate: {problems[:3]}")
        checks += 1
        failures += 1 if problems else 0
        tampered = json.loads(before.decode("utf-8"))
        tampered["gates"]["rows"][0]["rc"] = 3
        _write_atomic(out, json.dumps(tampered, indent=1) + "\n")
        problems = check_manifest(json.loads(out.read_text(encoding="utf-8")), base=base)
        expect(problems, "only a full run in which EVERY required gate returned zero",
               "a tampered on-disk manifest is refused")

    print(f"\nboard1 manifest selftest: {checks - failures}/{checks} mutations killed")
    return 1 if failures else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="the Board 1 candidate-bound gate manifest")
    ap.add_argument("--build", action="store_true",
                    help="emit a manifest; REFUSES unless every required gate is accounted for and zero")
    ap.add_argument("--gate-dir", "--artifact-dir", dest="gate_dir", default=None,
                    help="build: a directory of downloaded <id>.rc/<id>.log/<id>.cmd artifacts (the runner may "
                         "name this its artifact/temp root; the file naming is what is load-bearing)")
    ap.add_argument("--campaign-dir", default=None,
                    help="build: where the mutation campaign lived -- an absolute path (a runner's scratch root) or "
                         "a repository-relative path; defaults to the committed evidence directory")
    ap.add_argument("--tag", default=None, help="build: the annotated candidate tag to derive SHA/tree from")
    ap.add_argument("--manifest", default=None, help="validate: the manifest to re-derive (read-only)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    if args.build:
        if args.gate_dir:
            facts = gate_facts_from_dir(Path(args.gate_dir))
        else:
            print("::error::--build requires --gate-dir; an in-process run must call build_from_gates() so the "
                  "runner's own rc/log facts are used", file=sys.stderr)
            return 2
        try:
            doc = build_from_gates(gate_facts=facts, tag=args.tag,
                                   campaign_dir=args.campaign_dir)
        except ManifestRefused as exc:
            for p in exc.problems:
                print(f"::error::{p}", file=sys.stderr)
            return 1
        _write_atomic(Path(args.out), json.dumps(doc, indent=1) + "\n")
        print(f"board1 manifest: PASS written to {args.out} "
              f"(candidate {str(doc['candidate'].get('sha'))[:12]}… tree "
              f"{str(doc['candidate'].get('tree_sha'))[:12]}…, {len(doc['gates']['rows'])} gates)")
        return 0

    path = Path(args.manifest or MANIFEST_PATH_DEFAULT)
    if not path.is_file():
        print(f"::error::no manifest at {path} -- an absent manifest is not a pass", file=sys.stderr)
        return 1
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        print(f"::error::the manifest at {path} is not valid JSON: {exc}", file=sys.stderr)
        return 1
    # *** THE RELEASE PROOF IS MANDATORY LAW: `check_manifest` ALWAYS REQUIRES IT (no boolean). ***
    problems = check_manifest(doc, require_candidate=True)
    if args.json:
        print(json.dumps({"problems": problems, "candidate": doc.get("candidate"),
                          "verdict": doc.get("verdict")}, indent=1))
        return 1 if problems else 0
    for p in problems:
        print(f"::error::{p}")
    if problems:
        print(f"board1 manifest: FAILED ({len(problems)} defect(s))")
        return 1
    cand = doc.get("candidate") or {}
    print(f"board1 manifest: VALID (candidate {cand.get('tag')} -> {str(cand.get('sha'))[:12]}… tree "
          f"{str(cand.get('tree_sha'))[:12]}…, {len(doc['gates']['rows'])} gates accounted, campaign "
          f"{len((doc.get('campaign') or {}).get('population', {}).get('required_ids') or [])} rods, "
          f"{len(doc.get('lanes') or [])} lanes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
