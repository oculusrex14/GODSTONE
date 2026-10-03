#!/usr/bin/env python3
"""*** BOARD 1: THE ONE REPOSITORY-OWNED ROAD TO `verify` AND `freeze`. ***

*THE OBLIGATION: "Add `tools/readiness/board1.py` (helper) plus a `board1 verify|freeze` subcommand in
`tools/readiness/run.py`: `verify` runs the ordered internal gate set importably and prints one verdict; `freeze
--run-id R --tag T --attest-out P` performs the freeze sequence."*

*** WHY A SINGLE OBVIOUS PATH RATHER THAN A LIST OF COMMANDS IN A DOCUMENT. *** *A reader who must assemble the gate set
from prose will run a subset, and a subset that is green readeth as the whole being green -- which is the vacuous-green
class this programme keeps removing.* **HERE THE SET IS ONE PYTHON LIST, IN ORDER, WITH EACH ENTRY NAMED AND ITS EXIT
CODE CHECKED; `verify` runneth them all and printeth ONE verdict.**

**AND `freeze` IS DELIBERATELY NON-CIRCULAR:** *the candidate commit carrieth `run_id: null` (it cannot name a run that
has not happened yet), the tag is created on that commit, the push produceth the hosted run, and ONLY THEN is the
attestation written against `--run-id` -- so no artifact ever claims a result it could not have known.*
"""
from __future__ import annotations

import datetime
import hashlib
import json
import re
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# *** THE GATE SET IS IMPORTED, NEVER RE-DECLARED. ***
#
# *`ci/check_board1_manifest.py` owneth ONE canonical definition -- the ordered required set, each gate's stable id,
# its label and its exact argv -- and this road USES it rather than carrying a private copy. A second literal here
# would drift from the manifest contract the moment either moved, and a gate set that a manifest does not know about
# is a gate no reader can account for.* **The import is lazy (inside `_gate_set()`), so a host without the checker
# degrades with a NAMED error rather than at import time.**
#
# *The tuple shape `(label, argv)` is kept for the printer; the manifest's rows are derived from the same objects.*
def _gate_set(*, campaign_dir=None, proof_dir=None, evidence_root=None,
              base: Path | None = None) -> list[tuple[str, list[str]]]:
    """The ordered required gate set, from the ONE canonical definition.

    *When `campaign_dir` is supplied, the `{campaign_dir}` token in the campaign gate's argv is RESOLVED to it -- so
    the gate judged the directory the caller actually ran the campaign against, and the manifest row records that
    resolved path.*
    """
    sys.path.insert(0, str(ROOT / "ci"))
    import check_board1_manifest as cbm  # noqa: PLC0415 - imported here so a missing checker degrades loudly
    inputs = cbm.resolve_gate_inputs(campaign_dir=campaign_dir, proof_dir=proof_dir,
                                    evidence_root=evidence_root or ROOT)
    rows = cbm.canonical_gate_rows(inputs=inputs)
    return [(g["label"], list(g["argv"])) for g in rows]


def _gate_ids() -> list[str]:
    sys.path.insert(0, str(ROOT / "ci"))
    import check_board1_manifest as cbm  # noqa: PLC0415
    return list(cbm.REQUIRED_GATE_IDS)


def _slug(label: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")


def _gate_id_by_label() -> dict[str, str]:
    sys.path.insert(0, str(ROOT / "ci"))
    import check_board1_manifest as cbm  # noqa: PLC0415
    return {g["label"]: g["id"] for g in cbm.GATE_DEFINITIONS}

CLOSURE = ROOT / "docs" / "production-readiness" / "BOARD1_CLOSURE.json"
LEDGER = ROOT / "docs" / "remediation" / "REMEDIATION_STATE.json"


#: *** THE NORMALIZED FROZEN-C EVIDENCE ENVIRONMENT, PASSED INTO EVERY GATE SUBPROCESS. ***
#:
#: *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: the manifest validator and the freeze got the frozen-C roots, but
#: the CANONICAL GATE SUBPROCESSES -- notably `scripts/build_evidence_bundle.py --check`, whose terminal authentication
#: needeth the SAME C replay roots -- ran with no such context.* **So `verify` normalizeth the `--frozen-*` roots into
#: these names and passes them to EVERY gate subprocess; a gate that needs the frozen evidence (the bundle) readeth them,
#: a gate that does not is unaffected, and the C-domain future-absence case worketh with NO frozen roots set (the names
#: are simply absent).** *No source globals, no mocks -- the environment IS the convention.*
FROZEN_ENV = {
    "gates": "GODSTONE_BOARD1_FROZEN_ARTIFACTS",
    "campaign": "GODSTONE_BOARD1_FROZEN_CAMPAIGN_DIR",
    "evidence": "GODSTONE_BOARD1_FROZEN_EVIDENCE_ROOT",
    "proof": "GODSTONE_BOARD1_FROZEN_PROOF_DIR",
}


def frozen_environment(*, artifact_dir: Path | None = None, campaign_dir: Path | None = None,
                       evidence_root: Path | None = None, proof_dir: Path | None = None) -> dict:
    """The normalized `GODSTONE_BOARD1_FROZEN_*` environment for the frozen-C roots (only set when supplied)."""
    out: dict = {}
    for cls, value in (("gates", artifact_dir), ("campaign", campaign_dir),
                       ("evidence", evidence_root), ("proof", proof_dir)):
        if value is not None:
            out[FROZEN_ENV[cls]] = str(Path(value))
    return out


#: *** THE DOWNLOADED INTEGRATION-FIXTURES ROOT, EXPORTED TO EVERY GATE SUBPROCESS. ***
#:
#: *`ci/check_integration_evidence.py` resolves its committed-fixture reads (`_fixture_run_ids`, the collision refusal's
#: path text, the `selftest` base) through `resolve_fixtures_root()` -- supplied `--fixtures-root`, then this env, then
#: the IN-CHECKOUT `tools/integration-fixtures/`. **On a fresh reader/worktree that ignored directory is ABSENT or
#: stale, so without this export the fixture-collision control would silently judge the wrong (or no) fixtures.*** *The
#: downloaded evidence carries `tools/integration-fixtures/**`; so `verify` points the env at the supplied evidence
#: root and the checker judges the DOWNLOADED bytes, never a stale checkout copy.*
INTEGRATION_FIXTURES_ENV = "GODSTONE_BOARD1_INTEGRATION_FIXTURES_ROOT"
INTEGRATION_FIXTURES_REL = Path("tools") / "integration-fixtures"


def integration_fixtures_environment(*, evidence_root: Path | None = None,
                                     frozen_evidence_root: Path | None = None) -> dict:
    """*** THE FIXTURES-ROOT ENV FOR THE ACTUAL GATES: THE FROZEN-C ROOT IS AUTHORITATIVE WHEN SUPPLIED. ***

    *The committed fixtures are fixed at `C`, so when a frozen-C evidence root is supplied its
    `tools/integration-fixtures/` IS the source of truth -- and it is used EXCLUSIVELY: a fresh `A` root's fixtures are
    NEVER a fallback, because the frozen-C reader must judge the C fixtures, not a current-A copy.* **A supplied root
    that carries no `tools/integration-fixtures/` seteth NOTHING (never the other root): the checker's own
    `resolve_fixtures_root` then refuseth by name rather than this caller silently pointing it somewhere weaker.***
    """
    if frozen_evidence_root is not None:
        chosen = Path(frozen_evidence_root)
    else:
        # *** THE FRESH ROOT COMES FROM THE FLAG OR THE CANONICAL ENV THE GATES ALREADY READ. *** *`resolve_gate_inputs`
        # consulteth `GODSTONE_BOARD1_EVIDENCE_ROOT` when no flag is given, so this caller edge must resolve the SAME
        # value or it would point the fixtures env at nothing while the gates judged the env-named root.*
        fresh = evidence_root
        if fresh is None:
            sys.path.insert(0, str(ROOT / "ci"))
            import check_board1_manifest as _cbm  # noqa: PLC0415 - the ONE token authority
            fresh = os.environ.get(_cbm.GATE_INPUT_TOKENS[_cbm.EVIDENCE_ROOT_TOKEN][0])
        if fresh in (None, ""):
            return {}
        chosen = Path(fresh)
    # *** SET UNCONDITIONALLY WHEN A ROOT IS SUPPLIED: NO SILENT FALLBACK TO A STALE/ABSENT IN-CHECKOUT COPY. *** *If
    # the supplied root carrieth no `tools/integration-fixtures/`, the checker's `resolve_fixtures_root` refuseth BY
    # NAME -- so "the fixtures were not downloaded" is visible rather than judged against the wrong directory.*
    return {INTEGRATION_FIXTURES_ENV: str(chosen / INTEGRATION_FIXTURES_REL)}


def _run(argv: list[str], timeout: int = 3600, env: dict | None = None) -> tuple[int, str, str]:
    """Run one gate from the REPOSITORY ROOT, returning `(rc, tail, full_output)`.

    *`env` is an OVERLAY on the ambient environment, used to hand a gate the frozen-C evidence roots (see `FROZEN_ENV`)
    without inventing source globals.*

    *`capture_output` is used so the verdict is parsed rather than merely printed; the TAIL is returned for the
    concise terminal summary and the FULL output for the retained artifact, which is the lesson the lane checker
    already paid for.*
    """
    try:
        proc = subprocess.run(argv, cwd=str(ROOT), capture_output=True, text=True, timeout=timeout,
                              env={**os.environ, **(env or {})})
        rc, blob = proc.returncode, (proc.stdout or "") + (proc.stderr or "")
    except subprocess.TimeoutExpired as exc:
        # *** A HUNG GATE IS A FAILURE WITH ITS PARTIAL OUTPUT, NOT A LOST GATE. ***
        # *The default handler would propagate and take the whole verdict with it, leaving no artifact for the gate
        # that hung -- which is exactly the shape a run with no verdict wears.*
        rc = 124
        partial = exc.stdout or ""
        if isinstance(partial, bytes):
            partial = partial.decode("utf-8", "replace")
        blob = f"(the gate did not settle inside {timeout}s)\n{partial}"
    return rc, "\n".join(blob.strip().splitlines()[-12:]), blob


def run_gates(*, only: list[str] | None = None,
              artifact_dir: Path | None = None,
              campaign_dir: str | Path | None = None,
              evidence_root: Path | None = None,
              frozen_env: dict | None = None,
              base: Path | None = None) -> tuple[list[tuple[str, str]], list[dict]]:
    """Run the ordered gate set, retaining EACH gate's full output as its own artifact.

    *Returns `(failed, rows)`, where a row carrieth `{id, label, argv, rc, log_path}` -- the exact facts a manifest
    must bind. Every gate writeth `<dir>/<id>.log` (its full streams), `<dir>/<id>.rc` (its raw exit code) and
    `<dir>/<id>.cmd` (its exact argv as JSON), so a gate can be ACCOUNTED FOR from artifacts alone.*
    """
    if artifact_dir is None:
        artifact_dir = Path(tempfile.mkdtemp(prefix="board1-gates-", dir=os.environ.get("RUNNER_TEMP")))
    gates = _gate_set(campaign_dir=campaign_dir, proof_dir=artifact_dir,
                      evidence_root=evidence_root, base=base)
    ids = _gate_ids()
    id_of = dict(zip([lbl for lbl, _ in gates], ids))
    selected = [(lbl, argv) for lbl, argv in gates if not only or lbl in only]
    unknown = sorted(set(only or ()) - {lbl for lbl, _ in gates})
    if unknown:
        print(f"::error::unknown gate(s): {', '.join(unknown)}", file=sys.stderr)
        return [("unknown gates", ", ".join(unknown))], []
    if artifact_dir is not None:
        artifact_dir.mkdir(parents=True, exist_ok=True)
    failed: list[tuple[str, str]] = []
    rows: list[dict] = []
    print(f"BOARD 1 verify: {len(selected)} gate(s)"
          + (" (A SUBSET -- this is not the whole set)" if only else ""))
    for label, argv in selected:
        gate_id = id_of[label]
        rc, tail, blob = _run(argv, env=frozen_env)
        log_path = None
        if artifact_dir is not None:
            log_path = artifact_dir / f"{gate_id}.log"
            log_path.write_text(f"# gate: {label}\n# argv: {' '.join(argv)}\n# rc: {rc}\n\n{blob}",
                                encoding="utf-8")
            (artifact_dir / f"{gate_id}.rc").write_text(f"{rc}\n", encoding="utf-8")
            (artifact_dir / f"{gate_id}.cmd").write_text(json.dumps(argv) + "\n", encoding="utf-8")
        rows.append({"id": gate_id, "label": label, "argv": list(argv), "rc": rc,
                     "log_path": str(log_path) if log_path else None})
        print(f"  {'PASS' if rc == 0 else 'FAIL'}  {label}  (rc={rc})")
        if rc != 0:
            failed.append((label, tail))
    if failed:
        print("\nBOARD 1 verify: FAILED")
        for label, tail in failed:
            print(f"\n--- {label} ---")
            print(tail)
        return failed, rows
    print("\nBOARD 1 verify: PASSED" + (f" ({len(selected)} of {len(gates)} gates)" if only else ""))
    return [], rows

def verify(*, only: list[str] | None = None, artifact_dir: Path | None = None,
           build_manifest_out: Path | None = None, tag: str | None = None,
           campaign_dir: str | Path | None = None, proof_dir: Path | None = None,
           evidence_root: Path | None = None,
           frozen_artifacts: Path | None = None,
           frozen_campaign_dir: Path | None = None,
           frozen_evidence_root: Path | None = None,
           frozen_proof_dir: Path | None = None) -> int:
    """*** RUN THE ORDERED GATE SET AND PRINT ONE VERDICT. ***

    *A subset is allowed (`--only`), but the verdict then SAYETH it judged a subset -- so a partial run can never be
    quoted as the whole.* **Every failing gate is named WITH ITS OWN OUTPUT TAIL**, because a bare "one gate failed"
    would send the next reader hunting.

    *** AND EVERY GATE'S COMPLETE OUTPUT IS RETAINED, NOT ONLY THE LAST TWELVE LINES. *** *Each gate writeth
    `<dir>/<id>.log` with its exit status and full streams, beside `<id>.rc` and `<id>.cmd` -- so the hosted terminal
    job can DOWNLOAD the same artifacts this road produced and a manifest can bind them by digest.*

    *** WHEN `--manifest-out` IS SUPPLIED, A FULL RUN EMITS THE CANDIDATE-BOUND MANIFEST. *** *It is emitted ONLY after
    every required gate has been accounted for and returned zero, and it re-derives the campaign, lane, closure and
    external blocks from the tree; a partial or failing run REFUSES to emit one.*

    *** THE CLEAN-START SNAPSHOT IS TAKEN *BEFORE* THE FIRST GATE RUNS. ***
    // *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: `clean_start` was captured AFTER the gates, so a gate that
    // dropped a file into the tree could dirty it with the "start" measurement never seeing a clean state. The
    // snapshot is now taken here, before `run_gates`, and handed to the manifest builder.*
    """
    sys.path.insert(0, str(ROOT / "ci"))
    import check_board1_manifest as _cbm  # noqa: PLC0415
    _allow = (str(_cbm.MANIFEST_PATH_DEFAULT.relative_to(_cbm.ROOT)),)
    pre_gate = _cbm.pre_gate_snapshot(ROOT, allow=_allow)
    # *** THE FROZEN-C ROOTS ARE NORMALIZED INTO THE ENVIRONMENT OF EVERY GATE SUBPROCESS. ***
    # *The bundle's terminal authentication needeth the SAME C replay roots the validator uses; passing them only to the
    # manifest builder would leave the LIVE canonical gate unable to authenticate the C artifacts.*
    frozen_env = frozen_environment(artifact_dir=frozen_artifacts, campaign_dir=frozen_campaign_dir,
                                    evidence_root=frozen_evidence_root, proof_dir=frozen_proof_dir)
    # *** AND THE DOWNLOADED INTEGRATION-FIXTURES ROOT IS EXPORTED TO EVERY ACTUAL GATE. *** *The two
    # `ci/check_integration_evidence.py` gates need the DOWNLOADED `tools/integration-fixtures/` -- on a fresh worktree
    # the in-checkout (ignored) copy is absent, so the supplied/frozen evidence root's copy is what they judge.*
    frozen_env.update(integration_fixtures_environment(evidence_root=evidence_root,
                                                       frozen_evidence_root=frozen_evidence_root))
    failed, rows = run_gates(only=only, artifact_dir=artifact_dir, campaign_dir=campaign_dir,
                            evidence_root=evidence_root, frozen_env=frozen_env or None)
    if failed:
        return 1
    if build_manifest_out is not None:
        if only:
            print("::error::a manifest may only be emitted by the FULL gate run; `--only` judged a subset, and a "
                  "subset manifest would be a partial result wearing a complete one's shape", file=sys.stderr)
            return 2
        sys.path.insert(0, str(ROOT / "ci"))
        import check_board1_manifest as cbm  # noqa: PLC0415
        try:
            # *** THE FULL-C BUILD REQUIRETH THE CANDIDATE-BOUND RELEASE PROOF. *** *The terminal C job CAPTURETH the
            # actual release-gates proof for the exact candidate BEFORE it emitteth this manifest, so a build without
            # one REFUSES; the A verification later authenticates the SAME frozen-C proof root.*
            doc = cbm.build_from_gates(gate_facts=cbm.gate_facts_from_run(rows, ROOT), base=ROOT, tag=tag,
                                       campaign_dir=campaign_dir, proof_dir=proof_dir,
                                       evidence_root=evidence_root, pre_gate=pre_gate,
                                       frozen_artifacts=frozen_artifacts,
                                       frozen_campaign_dir=frozen_campaign_dir,
                                       frozen_evidence_root=frozen_evidence_root,
                                       frozen_proof_dir=frozen_proof_dir)
        except cbm.ManifestRefused as exc:
            for problem in exc.problems:
                print(f"::error::{problem}", file=sys.stderr)
            return 1
        manifest_out_path = Path(build_manifest_out)
        if not manifest_out_path.is_absolute():
            manifest_out_path = ROOT / manifest_out_path
        cbm._write_atomic(manifest_out_path, json.dumps(doc, indent=1) + "\n")
        print(f"board1 manifest: PASS written to {build_manifest_out} "
              f"(candidate {str(doc['candidate'].get('sha'))[:12]}… tree "
              f"{str(doc['candidate'].get('tree_sha'))[:12]}…)")
    return 0


def _sha256(path: Path) -> str | None:
    if not path.is_file():
        return None
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, timeout=300)


def _canonical_sha(doc) -> str:
    """The digest of a document's canonical JSON encoding -- order-independent, whitespace-independent."""
    return hashlib.sha256(json.dumps(doc, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def _within(child: Path, parent: Path) -> bool:
    try:
        (child if child.is_absolute() else parent / child).resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def _freeze_rebind(artifact_dir: Path | None, campaign_dir, evidence_root: Path | None,
                   proof_dir: Path | None) -> dict | None:
    """*** THE SAME EXACT DOWNLOAD MAP THE FRESH READER USES, FOR THE FREEZE'S OWN C-MANIFEST VALIDATION. ***

    *A C manifest is produced on the hosted runner under `RUNNER_TEMP`, so validating it in a fresh C checkout needs the
    records MAPPED to their downloaded locations -- the gate logs (`--artifacts`), the campaign tree, the lane evidence
    (`--evidence-root`) and the release-proof records.* **The mapping is by recorded relative identity and every mapped
    file must still carry the ORIGINAL bound digest; the hosted-bytes authentication (`hosted_manifest_problems`) runs
    BEFORE this map, so a mapped file can only ever agree with the hosted document, never substitute for it.** *No
    weaker logic: an unmapped record falls back to the recorded path, which then must exist.*
    """
    rebind: dict = {}
    if artifact_dir is not None:
        rebind["gates"] = Path(artifact_dir)
    if campaign_dir not in (None, ""):
        rebind["campaign"] = Path(campaign_dir)
    if evidence_root is not None:
        rebind["evidence"] = Path(evidence_root)
    if proof_dir is not None:
        rebind["proof"] = Path(proof_dir)
    return rebind or None


def freeze(run_id: str, tag: str, attest_out: Path, attempt: int, *,
           manifest: Path | None = None, campaign_dir: str | Path | None = None,
           manifest_artifact: str = "board1-gate-manifest",
           proof_dir: Path | None = None,
           artifact_dir: Path | None = None,
           evidence_root: Path | None = None) -> int:
    """*** THE FREEZE SEQUENCE: TAG ON THE COMMIT, BIND THE HOSTED RUN, WRITE THE ATTESTATION. ***

    *IT REFUSES TO PERFORM THE PARTS A HUMAN MUST DO (the tag creation and the push), and it CHECKS they happened
    before it writes anything:* **a `freeze` that created its own tag would be attesting a state it had just made,
    which is the circularity this whole sequence exists to avoid.**

    *** `--attempt N` IS MANDATORY, AND THE ATTEMPT IS FETCHED RATHER THAN COMPARED. ***
    // *The old road read `actions/runs/R` and `actions/runs/R/jobs` -- THE LATEST ATTEMPT'S ENDPOINTS -- and then
    // compared the returned `run_attempt` to a pinned number. If the pinned attempt had failed and a later re-run went
    // green, those endpoints answered GREEN and only the numeric comparison stood in the way; a caller who omitted the
    // attempt skipped even that.* **So the attempt is now REQUIRED, and `_run_facts` fetcheth `attempts/{N}` and
    // `attempts/{N}/jobs` -- the pinned attempt's own facts, which cannot be satisfied by a sibling attempt.**
    """
    # (1) THE TAG MUST ALREADY EXIST AND BE ANNOTATED -- created by a human against a commit that exists.
    peel = _git("rev-parse", f"{tag}^{{commit}}")
    obj = _git("rev-parse", tag)
    if peel.returncode != 0:
        print(f"::error::candidate tag {tag!r} does not exist -- create it first "
              f"(`git tag -a {tag} <commit> -m '<identity>'`) and push it", file=sys.stderr)
        return 1
    peeled, tag_object = peel.stdout.strip(), obj.stdout.strip()
    if tag_object == peeled:
        print(f"::error::candidate tag {tag!r} is LIGHTWEIGHT -- it carrieth no tag object and can be re-pointed "
              f"without trace", file=sys.stderr)
        return 1
    tree = _git("rev-parse", f"{peeled}^{{tree}}").stdout.strip()

    # *** AND THE REMOTE TAG MUST AGREE WITH THE LOCAL ONE -- A LOCAL TAG NOBODY PUSHED IS NOT THE BOUND ARTIFACT. ***
    remote = _git("ls-remote", "--tags", "origin", tag)
    if remote.returncode == 0 and remote.stdout.strip():
        remote_obj = remote.stdout.split()[0]
        if remote_obj != tag_object:
            print(f"::error::the REMOTE tag {tag!r} carrieth object {remote_obj} while the local one carrieth "
                  f"{tag_object} -- a moved or re-pointed remote tag is not the artifact the candidate froze",
                  file=sys.stderr)
            return 1
    else:
        print(f"::error::the remote (origin) carrieth NO tag {tag!r} -- the candidate tag must be PUSHED before a "
              f"freeze can bind it (a local-only tag is not the artifact a reader checks out)", file=sys.stderr)
        return 1

    # *** THE ALLOWED PATH IS RESOLVED BEFORE IT IS RELATIVISED. ***
    #
    # *THE DEFECT THIS CLOSES, MEASURED: `attest_out.relative_to(ROOT)` RAISETH `ValueError` when the caller passeth a
    # RELATIVE path -- and `--attest-out docs/remediation/evidence/FREEZE_ATTESTATION_rcNN.json`, the exact form the
    # plan's own command line uses, IS relative. So the freeze crashed with an unhandled traceback BEFORE the tag,
    # run, or dirty-tree checks could speak: the operator saw a Python stack trace instead of the named refusal that
    # told them what to fix.* **A RELATIVE PATH IS RESOLVED AGAINST THE REPOSITORY ROOT -- the cwd this road already
    # runs from -- and a path OUTSIDE the repository is refused BY NAME, because an attestation written outside the
    # tree is not an artifact any reader would find.**
    attest_abs = attest_out if attest_out.is_absolute() else (ROOT / attest_out)
    try:
        attest_rel = str(attest_abs.resolve().relative_to(ROOT.resolve()))
    except ValueError:
        print(f"::error::--attest-out {attest_out} resolveth to {attest_abs}, which is OUTSIDE the repository "
              f"{ROOT} -- the attestation must be a tracked path a reader can find, and the post-tag allowlist "
              f"cannot name a path outside the candidate's own tree", file=sys.stderr)
        return 1

    # *** AND THE PATH MUST BE EXACTLY THE ONE AUTHORITATIVE FUTURE ATTESTATION. ***
    #
    # *THE DEFECT THIS CLOSES: any in-repo path was accepted, so a caller could name `FREEZE_ATTESTATION_rc11.json` (or
    # any other file) and the post-tag allowance would follow it. **The freeze writeth exactly ONE artifact, at the path
    # the canonical binding authority declares; the path is compared by EQUALITY against
    # `ccb.FREEZE_ATTESTATION_SUCCESSOR_PATH`, never a prefix, glob or directory, and the historical rc14 attestation is
    # never a permitted output.*** *The policy call further down re-derives the same law from the same place.*
    import check_candidate_binding as _ccb_path  # noqa: PLC0415 - the ONE authority for the successor path
    if attest_rel != _ccb_path.FREEZE_ATTESTATION_SUCCESSOR_PATH:
        print(f"::error::--attest-out resolves to {attest_rel!r}, not the ONE authoritative future attestation "
              f"{_ccb_path.FREEZE_ATTESTATION_SUCCESSOR_PATH!r} -- *a freeze writeth exactly one artifact, at the exact "
              f"path the binding authority declares; an rc11/rc14-era name, a prefix or a directory is not admitted*",
              file=sys.stderr)
        return 1

    # (2) THE CITED RUN MUST BE THE CANDIDATE'S OWN, WITH THE WHOLE GREEN SHAPE, FROM THE PINNED ATTEMPT.
    sys.path.insert(0, str(ROOT / "ci"))
    import check_candidate_binding as ccb  # noqa: PLC0415 - imported here so a missing module degrades loudly
    facts = ccb._run_facts(run_id, attempt=attempt)
    if facts is None:
        print(f"::error::hosted run {run_id} attempt {attempt} could NOT be read -- a freeze may not cite a run it "
              f"cannot verify", file=sys.stderr)
        return 1
    if facts.get("head_sha") != peeled:
        print(f"::error::hosted run {run_id} attempt {attempt} reports head_sha {facts.get('head_sha')} but {tag!r} "
              f"peels to {peeled} -- A GREEN RUN FROM ANOTHER SHA CANNOT BE BORROWED", file=sys.stderr)
        return 1
    if facts.get("run_attempt") != attempt:
        print(f"::error::hosted run {run_id} attempt {attempt} answered with run_attempt="
              f"{facts.get('run_attempt')!r} -- the attempt-specific endpoint did not describe the pinned attempt",
              file=sys.stderr)
        return 1
    for what, want in (("conclusion", "success"), ("workflow", "repository-verification"),
                       ("event", "push"), ("status", "completed")):
        if facts.get(what) != want:
            print(f"::error::hosted run {run_id} attempt {attempt} carrieth {what}={facts.get(what)!r}, not {want!r}",
                  file=sys.stderr)
            return 1
    # *** THE EXACT JOB NAMES, WITH ANNOTATIONS -- DELEGATED TO THE ONE VALIDATOR, SO THE TWO ROADS AGREE. ***
    problems = ccb.binding_problems(
        {"candidate_ref": tag,
         "candidate_tree_sha": tree,
         "repository_verification": {"run_id": run_id, "run_attempt": attempt, "repository": facts.get("repository"),
                                     "branch": facts.get("head_branch")},
         # *** THE ONE PATH THIS FREEZE MAY WRITE, NAMED EXACTLY -- never a directory. ***
         "post_tag_attestation": attest_rel,
         },
        workdir_record=ccb._file_at(peeled, "docs/production-readiness/BOARD1_CLOSURE.json"),
        freeze=True,
        run_facts=lambda _r: facts,
        tree_delta=lambda p: ccb._tree_delta(p, allow=(attest_rel,)),
        annotations=ccb._job_annotations,
        dirty_paths=lambda: ccb.dirty_tracked_paths(allow=(attest_rel,)),
    )
    # The record at the tag need not yet name the attestation path; only the run/jobs/delta/dirty clauses are judged
    # here, so a `candidate_ref` mismatch in the synthetic record above is filtered out deliberately.
    problems = [p for p in problems if "has been edited since the candidate was frozen" not in p]
    if problems:
        for p in problems:
            print(f"::error::{p}", file=sys.stderr)
        return 1

    # (3) *** THE AT-TAG DIGESTS: THE CLOSURE RECORD AND THE LEDGER AS THEY STOOD AT THE CANDIDATE. ***
    # *A digest taken now would describe the WORKING tree; the attestation must describe the CANDIDATE.*
    closure_at = ccb._file_at(peeled, "docs/production-readiness/BOARD1_CLOSURE.json")
    ledger_at = ccb._file_at(peeled, "docs/remediation/REMEDIATION_STATE.json")
    if closure_at is None or ledger_at is None:
        print(f"::error::candidate {tag!r} carrieth no closure record and/or ledger at the tag", file=sys.stderr)
        return 1
    try:
        closure_doc = json.loads(closure_at)
    except ValueError as exc:
        print(f"::error::the closure record at {tag!r} is not valid JSON: {exc}", file=sys.stderr)
        return 1
    # *** THE FREEZE REQUIRETH THE INTERNAL SEMANTIC OBLIGATIONS CLOSED -- NOT A PREMATURE `READY` ON `C`. ***
    #
    # *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: the freeze demanded that the CANDIDATE's own closure record
    # already stand `READY_FOR_EXTERNAL_REAUDIT`. **But `C` cannot honestly claim READY: its own hosted terminal proof
    # does not exist until the tag is pushed, and READY belongs to the AUTHENTICATED SUCCESSOR `A`. So the candidate's
    # static status is expected to remain `REMEDIATION_IN_PROGRESS` (pending terminal proof), and the freeze's real
    # requirement is the MEASURED one: every internal semantic obligation is DISCHARGED (derived
    # `internal_obligations_open == 0` and `findings_with_internal_status_open == 0`), which is a semantic obligation
    # closure rather than a status enum.***
    #
    # *AND A CANDIDATE THAT *DOES* CLAIM READY MAY NOT DO SO OVER OPEN WORK -- the derived counts are re-derived here
    # from the AT-TAG ledger, so a READY status beside live obligations is refused exactly as the manifest refuseth
    # it.*
    derived_at: dict = {}
    try:
        sys.path.insert(0, str(ROOT / "ci"))
        import check_board1_manifest as _cbm  # noqa: PLC0415 - the ONE loader for the closure generator
        bsc = _cbm._import_script("build_structured_closure", ROOT)
        derived_at = bsc.counts(bsc.build(json.loads(ledger_at)))
    except Exception as exc:  # noqa: BLE001 - an underivable population is a NAMED refusal
        print(f"::error::the internal obligation population at {tag!r} could NOT be derived: "
              f"{type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    if derived_at.get("internal_obligations_open"):
        print(f"::error::the candidate {tag!r} carrieth {derived_at.get('internal_obligations_open')} OPEN internal "
              f"semantic obligation(s) -- a freeze requireth EVERY obligation CLOSED, because a candidate frozen over "
              f"live internal work is the overclaim this control plane existeth to refuse", file=sys.stderr)
        return 1
    if derived_at.get("findings_with_internal_status_open"):
        print(f"::error::the candidate {tag!r} carrieth {derived_at.get('findings_with_internal_status_open')} "
              f"finding(s) with internal_status OPEN -- BOTH populations must be empty before a freeze", file=sys.stderr)
        return 1
    if closure_doc.get("status") == "READY_FOR_EXTERNAL_REAUDIT" and derived_at.get("internal_obligations_open"):
        print(f"::error::the closure record at {tag!r} claimeth READY over live internal work", file=sys.stderr)
        return 1
    if closure_doc.get("verified_fixed") not in (None, 0):
        print(f"::error::the closure record at {tag!r} carrieth verified_fixed="
              f"{closure_doc.get('verified_fixed')!r} -- only the INDEPENDENT auditor may write it", file=sys.stderr)
        return 1

    # *** THE ATTESTATION IS WRITE-ONCE: AN EXISTING FILE IS REFUSED, EVEN MALFORMED. ***
    #
    # *THE DEFECT THIS CLOSES: the previous guard compared the existing JSON against a stub and REFUSED only when the
    # parsed document disagreed -- so a MALFORMED existing file (`existing is None`) fell through and was OVERWRITTEN,
    # and so was a file whose stub happened to match. **An attestation is a historical artifact: if the path exists at
    # all, the freeze refuseth rather than silently re-authoring it.*** *The single honest road is to remove the file
    # deliberately if it is truly a stray, which is a decision the operator must make explicitly.*
    if attest_out.is_file():
        print(f"::error::{attest_out} already EXISTETH -- an attestation is written ONCE. Refusing to overwrite it "
              f"(even malformed bytes are left untouched: a reader must be able to see exactly what was written "
              f"first)", file=sys.stderr)
        return 1

    # (4) *** THE GATE MANIFEST, WHICH THE FREEZE BINDS BY DIGEST AND RE-DERIVES. ***
    #
    # *A FREEZE THAT NAMED A RUN BUT NOT THE INTERNAL GATES THAT RAN AGAINST THE CANDIDATE WOULD BE BINDING A HOSTED
    # RESULT TO NOTHING THE REPOSITORY ITSELF EXECUTED.* **So the manifest is READ, its candidate re-derived, its
    # required gates re-accounted and its campaign/lane/closure populations re-derived -- and its digest is written
    # into the attestation, so the two artifacts describe one candidate or neither is trustworthy.**
    #
    # *THE MANIFEST'S SHA MUST BE THE CANDIDATE'S OWN: a manifest whose `candidate.sha` is not `peeled` is describing
    # another tree, which is the stale-authority defect the whole binding exists to refuse.*
    import check_board1_manifest as cbm  # noqa: PLC0415 - alongside `ccb`, from the same `ci/`
    manifest_path = Path(manifest) if manifest else cbm.MANIFEST_PATH_DEFAULT
    if not manifest_path.is_absolute():
        manifest_path = ROOT / manifest_path
    if not manifest_path.is_file():
        print(f"::error::no Board 1 gate manifest at {manifest_path} -- a freeze requireth the candidate-bound "
              f"internal gate run; run `run.py board1 verify --manifest-out {manifest_path}` against the candidate "
              f"first", file=sys.stderr)
        return 1
    try:
        manifest_doc = json.loads(manifest_path.read_text(encoding="utf-8"))
    except ValueError as exc:
        print(f"::error::the Board 1 gate manifest at {manifest_path} is not valid JSON: {exc}", file=sys.stderr)
        return 1
    # *** AND IT MUST BE THE ARTIFACT THE PINNED RUN UPLOADED -- NOT A FILE THIS HOST WROTE. ***
    manifest_bytes = manifest_path.read_bytes()
    hosted_problems = ccb.hosted_manifest_problems(run_id, name=manifest_artifact,
                                                   manifest_bytes=manifest_bytes, attempt=attempt)
    if hosted_problems:
        for problem in hosted_problems:
            print(f"::error::{problem}", file=sys.stderr)
        return 1
    artifact_rows = ccb._run_artifacts(run_id, attempt=attempt) or []
    bound_artifact = next((a for a in artifact_rows if a.get("name") == manifest_artifact
                           and not a.get("expired")), None)
    manifest_problems = cbm.check_manifest(
        manifest_doc, base=ROOT, require_candidate=True,
        campaign_dir_override=(cbm.resolve_campaign_dir(campaign_dir, ROOT) if campaign_dir else None),
        evidence_root=(Path(evidence_root) if evidence_root else None),
        rebind=_freeze_rebind(artifact_dir, campaign_dir, evidence_root, proof_dir))
    if manifest_problems:
        for problem in manifest_problems:
            print(f"::error::gate manifest: {problem}", file=sys.stderr)
        return 1
    # *** AND THE EXACT-CANDIDATE RELEASE PROOF IS REQUIRED *HERE* TOO, IN THE ATTESTATION'S OWN BLOCK. ***
    #
    # *The full-C gate manifest now carrieth the mandatory release block; the freeze ALSO authenticates the records
    # for the attestation's `release_evidence` block so a fresh reader can re-derive both. The proof's identity is
    # embedded in the attestation separately from the gate manifest.*
    proof_dir = Path(proof_dir) if proof_dir else None
    proof_dir = proof_dir or (ROOT / "docs/remediation/evidence/board1-release-proof")
    if not proof_dir.is_absolute():
        proof_dir = ROOT / proof_dir
    proof_block = cbm.release_proof_facts(proof_dir, ROOT)
    # *** THE FREEZE AUTHENTICATES THE RELEASE PROOF MANDATORILY, BOUND TO THE EXACT CANDIDATE SHA AND TREE, AGAINST
    # THE TRUSTED REPOSITORY (the tag's own tree, never the proof's claim). ***
    proof_problems = cbm.release_evidence_problems(
        proof_block, candidate_sha=peeled, candidate_tag=tag,
        candidate_tree_sha=tree, repo=cbm._release_repo())
    if proof_problems:
        for problem in proof_problems:
            print(f"::error::release proof: {problem}", file=sys.stderr)
        return 1
    bound_proofs = [{"record": e.get("record"), "document_sha256": e.get("document_sha256"),
                     "candidate": e.get("candidate"), "run_id": e.get("run_id"),
                     "run_attempt": e.get("run_attempt")} for e in proof_block.get("records") or []]

    m_cand = manifest_doc.get("candidate") or {}
    if m_cand.get("sha") != peeled:
        print(f"::error::the gate manifest bindeth candidate {m_cand.get('sha')} but {tag!r} peels to {peeled} -- a "
              f"freeze may not bind a manifest describing another tree", file=sys.stderr)
        return 1
    if m_cand.get("tree_sha") != tree:
        print(f"::error::the gate manifest bindeth tree {m_cand.get('tree_sha')} but {tag!r} carrieth tree {tree}",
              file=sys.stderr)
        return 1

    attestation = {
        "schema": 1,
        "candidate_ref": tag,
        "candidate_sha": peeled,
        "candidate_tree_sha": tree,
        "tag_object_sha": tag_object,
        "closure_record_sha": peeled,
        "run": {
            "id": int(run_id) if str(run_id).isdigit() else run_id,
            "attempt": attempt,
            "workflow": facts.get("workflow"),
            "workflow_path": facts.get("path"),
            "event": facts.get("event"),
            "repository": facts.get("repository"),
            "head_branch": facts.get("head_branch"),
            "head_sha": facts.get("head_sha"),
            "conclusion": facts.get("conclusion"),
            "jobs": facts.get("jobs"),
        },
        "at_tag_closure_sha256": hashlib.sha256(closure_at.encode("utf-8")).hexdigest(),
        "at_tag_ledger_sha256": hashlib.sha256(ledger_at.encode("utf-8")).hexdigest(),
        # *** THE INTERNAL GATE MANIFEST, EMBEDDED WHOLE *AND* BY DIGEST. ***
        #
        # *THE ATTESTATION IS THE ONE FILE COMMITTED AFTER THE CANDIDATE (successor `A`), SO IT MUST CARRY EVERYTHING A
        # READER NEEDS: the manifest's digest proves WHICH manifest was bound, and the embedded document means the
        # gate rows, campaign population, lane identities and closure counts travel WITH the attestation -- a reader
        # can re-derive them from the attestation alone, without a path that may not exist in their clone.*
        #
        # **THE EMBEDDED COPY IS NOT A SECOND AUTHORITY:** `validate_attestation` RE-DERIVES the embedded document
        # (gate population, argv, proof, campaign inputs, lane digests, closure counts) exactly as it rederiveth a
        # manifest read from disk -- so an embedded copy edited to disagree with the candidate is refused.
        "gate_manifest": {
            "path": str(manifest_path.relative_to(ROOT)) if _within(manifest_path, ROOT) else str(manifest_path),
            "sha256": _sha256(manifest_path),
            "candidate_sha": m_cand.get("sha"),
            "candidate_tree_sha": m_cand.get("tree_sha"),
            "generated_utc": manifest_doc.get("generated_utc"),
            "started_utc": manifest_doc.get("started_utc"),
            "completed_utc": manifest_doc.get("completed_utc"),
            "schema": manifest_doc.get("schema"),
            "gate_count": len((manifest_doc.get("gates") or {}).get("rows") or []),
            # *** THE IMMUTABLE HOSTED IDENTITY OF THE BYTES, SO A FRESH CLONE CAN RE-FETCH AND RE-DERIVE. ***
            "hosted_artifact": {
                "run_id": int(run_id) if str(run_id).isdigit() else run_id,
                "run_attempt": attempt,
                "name": manifest_artifact,
                "artifact_id": (bound_artifact or {}).get("id"),
                "archive_sha256": (bound_artifact or {}).get("archive_sha256"),
                "size_in_bytes": (bound_artifact or {}).get("size_in_bytes"),
            },
            "document": manifest_doc,
        },
        # *** THE EXACT-CANDIDATE RELEASE EVIDENCE, BY IDENTITY, SEPARATE FROM THE INTERNAL GATE MANIFEST. ***
        "release_evidence": {
            "interface": cbm.RELEASE_PROOF_INTERFACE,
            "available": proof_block.get("available"),
            "records": bound_proofs,
        },
        "measured_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "builder_verdict": "READY_FOR_EXTERNAL_REAUDIT",
        # *** THE AUDITOR'S BLOCK STAYS NULL: ONLY AN INDEPENDENT AUDIT MAY WRITE IT. ***
        "auditor": {"verdict": None, "signed_at": None},
    }
    attest_out.parent.mkdir(parents=True, exist_ok=True)
    attest_out.write_text(json.dumps(attestation, indent=1) + "\n", encoding="utf-8")
    print(f"FREEZE: {tag} -> {peeled} (tree {tree}) bound to run {run_id} attempt {attempt} "
          f"{len(ccb.CANONICAL_JOB_NAMES)}/{len(ccb.CANONICAL_JOB_NAMES)} jobs success")
    print(f"  attestation written to {attest_out}")
    print(f"  auditor block stays NULL: the terminal builder verdict is READY_FOR_EXTERNAL_REAUDIT, "
          f"NEVER VERIFIED_FIXED")
    return 0


def validate_attestation(path: Path, *, artifact_dir: Path | None = None, campaign_dir: Path | None = None,
                         evidence_root: Path | None = None, proof_dir: Path | None = None) -> int:
    """*** READ-ONLY: RE-DERIVE EVERYTHING AN ATTESTATION CLAIMS, WITHOUT REWRITING IT. ***

    *THE DEFECT THIS CLOSES: the only way to check an attestation was to RUN `freeze`, WHICH IS A WRITER -- it
    regenerates the timestamp and rewrites the file.* **So `verify --attestation` recomputeth the tag object, the peeled
    commit, the tree, the at-tag closure/ledger hashes and the pinned attempt's facts, and REFUSETH any disagreement --
    taking no timestamp and writing no file.**

    *** AND THE WHOLE TERMINAL AUTHENTICATION LIVES IN THE ONE SHARED READER. *** *THE DEFECT THIS CLOSES, FROM THE
    HOSTILE REVIEW: this wrapper used to restate a SECOND, weaker authentication while the evidence bundle called
    `ccb.validate_attestation` DIRECTLY -- so the two could drift.* **Now there is ONE implementation: the shared reader
    authenticates the hosted bytes, the seven jobs and their annotations, the embedded manifest's whole contract
    (including closed internal semantics) and the exact-candidate release proofs; this wrapper merely delegates to it
    and adds the on-disk manifest-vs-embedded byte-equality check.***

    *** `--artifacts`, `--campaign-dir`, `--evidence-root` AND `--proof-dir` REBIND THE RECORDS BY IDENTITY. *** *The
    hosted runner wrote those bytes under its own scratch root; a fresh clone maps each record's basename under these
    roots, and EVERY mapped file must still carry the ORIGINAL bound digest -- a wrong or missing map is refused, the
    authenticated document is never rewritten, and no rc11 path is guessed.*
    """
    sys.path.insert(0, str(ROOT / "ci"))
    import check_candidate_binding as ccb  # noqa: PLC0415
    rebind = {}
    if artifact_dir is not None:
        rebind["gates"] = artifact_dir
    if campaign_dir is not None:
        rebind["campaign"] = campaign_dir
    if evidence_root is not None:
        rebind["evidence"] = evidence_root
    if proof_dir is not None:
        rebind["proof"] = proof_dir
    problems = list(ccb.validate_attestation(path, rebind=rebind or None))
    # *** AND, WHEN THE BOUND MANIFEST IS ALSO PRESENT ON DISK, THE TWO MUST BE THE SAME BYTES. ***
    att = json.loads(path.read_text(encoding="utf-8"))
    bound = att.get("gate_manifest") or {}
    if bound.get("document") and bound.get("path"):
        manifest_path = Path(bound["path"])
        manifest_path = manifest_path if manifest_path.is_absolute() else (ROOT / manifest_path)
        if manifest_path.is_file():
            if _sha256(manifest_path) != bound.get("sha256"):
                problems.append(f"the gate manifest at {bound['path']} does not match the digest the attestation "
                                f"bound")
            try:
                on_disk = json.loads(manifest_path.read_text(encoding="utf-8"))
            except ValueError as exc:
                problems.append(f"the gate manifest at {bound['path']} is not valid JSON: {exc}")
            else:
                if on_disk != bound["document"]:
                    problems.append(f"the embedded gate manifest DISAGREES with the copy at {bound['path']} -- one of "
                                    f"the two was edited")
    if problems:
        for p in problems:
            print(f"::error::{p}", file=sys.stderr)
        return 1
    print(f"ATTESTATION VALID: {att.get('candidate_ref')} -> {att.get('candidate_sha')} "
          f"(tree {att.get('candidate_tree_sha')}); run {(att.get('run') or {}).get('id')} attempt "
          f"{(att.get('run') or {}).get('attempt')}; re-derived without rewriting the file")
    return 0


def replay(run_id: str, attempt: int, out_root: Path, *, candidate_tag: str,
           repo: str | None = None, attestation: Path | None = None,
           release_run_id: str | None = None, release_attempt: int | None = None) -> int:
    """*** READ-ONLY HYDRATE: DOWNLOAD A FROZEN C RUN'S ARTIFACTS AND RE-CAPTURE ITS RELEASE PROOFS. ***

    *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: the fresh-reader/fresh-A verification requireth the ORIGINAL C
    evidence, but a flag alone cannot produce it -- a runnable download path is needed.* **This command DOWNLOADS the
    pinned C CANONICAL run's artifacts (`board1-terminal-evidence`, the six producer artifacts, and the gate manifest)
    into an out-of-repository root in the run's OWN layout, and RE-CAPTURES each required release-proof record through
    the supply-chain owner's deterministic capture authority. It authenticates NOTHING and grants NO default/metadata-SHA
    admission: it only reads and downloads, then the SHARED reader validates the ORIGINAL committed document against
    these bound digests.**

    *** THE CANONICAL `repository-verification` (7-job) RUN IS NEVER CAPTURED AS A RELEASE PROOF. *** *A release proof
    is captured from the RELEASE run, whose `(run_id, attempt)` the attestation's `release_evidence.records` declare.*

    **TWO MODES, chosen by whether the attestation exists:**
      * **POST-ATTESTATION (`--attestation` given):** the COMMITTED document is read FIRST, its declared
        `release_evidence.records` are the record population, and `--run-id/--attempt/--tag` MUST match that document
        before anything is downloaded. Each distinct `(run_id, attempt)` is captured into `<out>/proof`.
      * **PRE-FREEZE (`--attestation` absent):** there are NO declared record ids yet, and NONE are invented. Either
        the caller names the actual RELEASE run explicitly (`--release-run-id/--release-attempt`), or only the
        canonical download is done and the proof is captured separately (the boring default -- no implicit ids).

    Layout:
      <out>/board1-gate-manifest.json    <out>/gates/<id>.{log,rc,cmd}    <out>/campaign/{manifest.json,logs/...}
      <out>/evidence/<repo-relative paths>    <out>/proof/<release>-<attempt>.json
    """
    sys.path.insert(0, str(ROOT / "ci"))
    import check_candidate_binding as ccb  # noqa: PLC0415 - the ONE gh-fetch authority
    repo = repo or ccb._repository()
    out = out_root.resolve()
    if out == ROOT or ROOT in out.parents:
        print(f"::error::--out {out} must be OUTSIDE the repository {ROOT} -- the frozen evidence is downloaded, never "
              f"committed into the candidate tree", file=sys.stderr)
        return 1
    # *** POST-ATTESTATION MODE: THE COMMITTED DOC DECLARES THE RECORD POPULATION, AND THE ARGS MUST MATCH IT. ***
    declared_records: list[tuple[str, int]] = []
    if attestation is not None:
        if not attestation.is_file():
            print(f"::error::--attestation {attestation} is absent -- a reader cannot derive declared record ids from "
                  f"a document that is not there", file=sys.stderr)
            return 1
        try:
            att_doc = json.loads(attestation.read_text(encoding="utf-8"))
        except ValueError as exc:
            print(f"::error::the attestation at {attestation} is not valid JSON: {exc}", file=sys.stderr)
            return 1
        if str(att_doc.get("candidate_ref")) != candidate_tag or str(att_doc.get("run", {}).get("id")) != str(run_id) \
                or att_doc.get("run", {}).get("attempt") != attempt:
            print(f"::error::--run-id/--attempt/--tag do not match the COMMITTED attestation's "
                  f"(run {(att_doc.get('run') or {}).get('id')}/{att_doc.get('run', {}).get('attempt')}, tag "
                  f"{att_doc.get('candidate_ref')!r}) -- hydrate only after the args match the document",
                  file=sys.stderr)
            return 1
        declared_records = sorted({(str(e.get("run_id")), int(e.get("run_attempt")))
                                   for e in (att_doc.get("release_evidence") or {}).get("records") or []
                                   if e.get("run_id") is not None and e.get("run_attempt") is not None})
        if not declared_records:
            print(f"::error::the committed attestation declares NO release_evidence record ids -- a missing population "
                  f"is refused, never defaulted", file=sys.stderr)
            return 1
    elif (release_run_id is None) != (release_attempt is None):
        print(f"::error::--release-run-id and --release-attempt must be given together, or neither", file=sys.stderr)
        return 1
    facts = ccb._run_facts(str(run_id), attempt=attempt)
    if facts is None:
        print(f"::error::the frozen run {run_id} attempt {attempt} could NOT be read", file=sys.stderr)
        return 1
    c_sha = facts.get("head_sha")
    rows = ccb._run_artifacts(str(run_id), attempt=attempt)
    if rows is None:
        print(f"::error::the frozen run {run_id} attempt {attempt}'s artifact list could NOT be read", file=sys.stderr)
        return 1
    (out / "gates").mkdir(parents=True, exist_ok=True)
    (out / "campaign").mkdir(parents=True, exist_ok=True)
    (out / "evidence").mkdir(parents=True, exist_ok=True)
    (out / "proof").mkdir(parents=True, exist_ok=True)
    # *** DOWNLOAD EACH NAMED ARTIFACT'S ZIP AND EXTRACT IT IN ITS OWN DESTINATION LAYOUT. ***
    #
    # *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: every evidence artifact was extracted into ONE `evidence/`
    # root, so the `ios-simulator-xcresult` UPLOAD (the CONTENTS of the xcresult directory, whose enclosing directory
    # GitHub does not restore) landed at the evidence root instead of `evidence/ios-simulator-lane.xcresult`, and the
    # light-artifact roots were merged. **So each artifact is extracted into the EXACT per-artifact destination the
    # workflow uses** (see .github/workflows/repository-verification.yml), matching the manifest's recorded paths.*
    import io
    import zipfile
    dest = {"board1-gate-manifest": out,
            "board1-terminal-evidence": out,
            "android-test-results": out / "evidence",
            "ios-lane-evidence": out / "evidence",
            "board1-integration-evidence": out / "evidence",
            "ios-simulator-xcresult": out / "evidence" / "ios-simulator-lane.xcresult",
            "ios-light-artifact-evidence": out / "evidence" / "ios-light",
            "android-light-artifact-evidence": out / "evidence" / "android-light"}
    for entry in rows:
        name = entry.get("name")
        if name not in dest or entry.get("expired"):
            continue
        blob = ccb._artifact_zip(entry.get("id"))
        if blob is None:
            print(f"::error::the frozen artifact {name!r} could NOT be downloaded", file=sys.stderr)
            return 1
        target = dest[name]
        target.mkdir(parents=True, exist_ok=True)
        try:
            with zipfile.ZipFile(io.BytesIO(blob)) as bundle:
                bundle.extractall(target)
        except zipfile.BadZipFile:
            print(f"::error::the frozen artifact {name!r} is not a readable ZIP archive", file=sys.stderr)
            return 1
    # *The terminal evidence artifact carries board1-gates/, board1-campaign/, board1-readiness/; relocate the gates and
    # campaign under their canonical directory names so the reader's recorded relative identities resolve.*
    for sub in ("gates", "campaign"):
        nested = out / ("board1-" + sub)
        if nested.is_dir() and nested != (out / sub):
            for child in nested.iterdir():
                target = (out / sub) / child.name
                if not target.exists():
                    child.rename(target)
    # *** AND RE-CAPTURE EACH DECLARED RELEASE RECORD -- NEVER THE CANONICAL RUN. ***
    #
    # *The capture authority (`map_facts` uses NO wallclock) reproduces the exact bound document at
    # `<proof_dir>/<run>-<attempt>.json`; each distinct released `(run_id, attempt)` is captured, and the reproduced
    # `document_sha256` is compared to the DECLARED value when the attestation is present.*
    capture = ROOT / "tools" / "supplychain" / "capture_release_proof.py"
    if not capture.is_file():
        print(f"::error::the release-proof capture authority {capture} is ABSENT", file=sys.stderr)
        return 1
    proof_dir = out / "proof"
    if release_run_id is not None:
        declared_records = [(str(release_run_id), int(release_attempt))]
    if declared_records:
        for rel_run, rel_attempt in declared_records:
            proc = subprocess.run([sys.executable, str(capture), "--repo", repo, "--run-id", str(rel_run),
                                   "--attempt", str(rel_attempt), "--candidate-sha", str(c_sha),
                                   "--out", str(proof_dir)], capture_output=True, text=True, timeout=1800)
            if proc.returncode != 0:
                print(f"::error::the release proof for run {rel_run} attempt {rel_attempt} could NOT be re-captured: "
                      f"{proc.stderr.strip()[:200]}", file=sys.stderr)
                return 1
        # *AND EACH REPRODUCED FILE'S DIGEST IS COMPARED TO THE COMMITTED RECORD'S BOUND FILE DIGEST -- a re-capture
        # that moved is refused. (`record.sha256` is the file digest the attestation bound; `document_sha256` is the
        # owner's internal body digest and is re-checked by the shared reader.)*
        if attestation is not None:
            for entry in (att_doc.get("release_evidence") or {}).get("records") or []:
                rec = entry.get("record") or {}
                reproduced = proof_dir / f"{entry.get('run_id')}-{entry.get('run_attempt')}.json"
                if not reproduced.is_file():
                    print(f"::error::the release proof {reproduced.name} was not reproduced", file=sys.stderr)
                    return 1
                if rec.get("sha256") and _sha256(reproduced) != rec.get("sha256"):
                    print(f"::error::the re-captured release proof for run {entry.get('run_id')} attempt "
                          f"{entry.get('run_attempt')} carrieth a different digit than the committed record bound",
                          file=sys.stderr)
                    return 1
    else:
        print("note: no release record ids were declared and no --release-run-id was given, so ONLY the canonical "
              "download was done; capture the release proof separately (no implicit ids are invented)")
    print(f"REPLAY HYDRATED: frozen C {str(c_sha)[:12]}… run {run_id} attempt {attempt} -> {out}")
    print("  fresh-A verify flags:")
    print(f"    --tag {candidate_tag} --frozen-artifacts {out / 'gates'} "
          f"--frozen-campaign-dir {out / 'campaign'} --frozen-evidence-root {out / 'evidence'} "
          f"--frozen-proof-dir {proof_dir}")
    if attestation is not None:
        # *** THE STANDALONE REPLAY EXPORTS THE DOWNLOADED INTEGRATION-FIXTURES ROOT FOR ITS OWN READER TOO. *** *The
        # bundle/attestation validation spawns the integration checker over the DOWNLOADED evidence; the env names the
        # downloaded `tools/integration-fixtures/` so the collision control judges the downloaded bytes, not a stale
        # (or absent) in-checkout copy.*
        os.environ.update(integration_fixtures_environment(evidence_root=out / "evidence"))
        return validate_attestation(attestation, artifact_dir=out / "gates", campaign_dir=out / "campaign",
                                    evidence_root=out / "evidence", proof_dir=proof_dir)
    return 0


def main(argv=None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Board 1: the repository-owned verify/freeze road")
    sub = ap.add_subparsers(dest="command", required=True)
    p_verify = sub.add_parser("verify", help="run the ordered internal gate set and print one verdict")
    p_verify.add_argument("--only", action="append", default=None,
                          help="run only this gate (repeatable); the verdict then SAYETH it judged a subset")
    p_verify.add_argument("--artifacts", default=None,
                          help="verify: a directory to retain EVERY gate's full output (not only the twelve-line "
                               "summary), one <slug>.log per gate")
    p_verify.add_argument("--attestation", default=None,
                          help="READ-ONLY: re-derive the claims of a written freeze attestation instead of running "
                               "the gates; never regenerates the timestamp or rewrites the file")
    p_verify.add_argument("--manifest-out", default=None,
                          help="verify: AFTER a full, all-zero gate run, emit the candidate-bound gate manifest to "
                               "this path (a subset or failing run REFUSES to emit one)")
    p_verify.add_argument("--tag", default=None,
                          help="verify: derive the manifest's candidate SHA/tree from this annotated tag (default: "
                               "the working HEAD, recorded as sha_source=workdir)")
    p_verify.add_argument("--validate-manifest", default=None,
                          help="READ-ONLY: re-derive a written gate manifest instead of running the gates")
    p_freeze = sub.add_parser("freeze", help="write the freeze attestation against a hosted run")
    p_freeze.add_argument("--run-id", required=True)
    p_freeze.add_argument("--attempt", type=int, required=True,
                          help="the run's ATTEMPT number (mandatory: the pinned attempt's own facts are fetched, "
                               "never the latest attempt's)")
    p_freeze.add_argument("--tag", required=True)
    p_freeze.add_argument("--attest-out", required=True)
    p_freeze.add_argument("--manifest", default=None,
                          help="freeze: the candidate-bound gate manifest to bind (default: "
                               "docs/remediation/evidence/board1-gate-manifest.json)")
    p_freeze.add_argument("--manifest-artifact", default="board1-gate-manifest",
                          help="freeze: the hosted artifact NAME the pinned run uploaded the gate manifest as")
    # *** THE FLAGS `verify`/`freeze` ACTUALLY CONSUME, SO A CALLER CAN NAME THEM FROM EITHER ROAD. ***
    p_freeze.add_argument("--campaign-dir", default=None,
                          help="freeze: where the mutation campaign lived (absolute or repository-relative)")
    p_freeze.add_argument("--proof-dir", default=None,
                          help="freeze: where the exact-candidate release-proof records live (MANDATORY law: a "
                               "freeze without a candidate-bound release proof fails)")
    # *** THE DOWNLOADED C-EVIDENCE ROOTS, SO A FRESH C CHECKOUT CAN VALIDATE THE HOSTED C MANIFEST. ***
    p_freeze.add_argument("--artifacts", default=None,
                          help="freeze: the downloaded C gate-log root (the manifest's gate logs live outside the "
                               "candidate tree on the runner)")
    p_freeze.add_argument("--evidence-root", default=None,
                          help="freeze: the downloaded C lane-evidence root")
    p_verify.add_argument("--campaign-dir", default=None,
                          help="verify: where the mutation campaign lived -- absolute (a runner scratch root) or "
                               "repository-relative; defaults to the committed evidence directory")
    p_verify.add_argument("--proof-dir", default=None,
                          help="verify: where the exact-candidate release-proof records live")
    p_verify.add_argument("--evidence-root", default=None,
                          help="verify: where the downloaded LANE artifacts live; defaults to the repository root")
    # *** THE FROZEN-C RELOCATION ROOTS, FOR THE FINAL-MAIN `A` FRESH VERIFICATION. ***
    #
    # *On `A` the `--artifacts/--campaign-dir/--evidence-root/--proof-dir` flags name the FRESH A inputs/outputs, and
    # `--tag` names the FROZEN candidate `C`; these DISTINCT roots carry the FROZEN-C evidence for authenticating the
    # committed attestation and its embedded C manifest.*
    p_verify.add_argument("--frozen-artifacts", default=None,
                          help="verify: the downloaded FROZEN-C gate-log root (for authenticating committed C evidence)")
    p_verify.add_argument("--frozen-campaign-dir", default=None,
                          help="verify: the FROZEN-C campaign tree (embedded in the committed attestation)")
    p_verify.add_argument("--frozen-evidence-root", default=None,
                          help="verify: the downloaded FROZEN-C lane-evidence root")
    p_verify.add_argument("--frozen-proof-dir", default=None,
                          help="verify: the FROZEN-C release-proof records")
    # *** `replay`: THE READ-ONLY HYDRATE THAT DOWNLOADS A FROZEN C RUN'S EVIDENCE AND RE-CAPTURES ITS PROOFS. ***
    p_replay = sub.add_parser("replay", help="download a frozen C run's evidence out-of-repo and re-capture its "
                                             "release proofs (then prints the fresh-A verify flags)")
    p_replay.add_argument("--run-id", required=True, help="the frozen C run id")
    p_replay.add_argument("--attempt", type=int, required=True, help="the pinned C run attempt")
    p_replay.add_argument("--tag", required=True, help="the frozen candidate tag C")
    p_replay.add_argument("--out", required=True, help="an out-of-repository root to hydrate into")
    p_replay.add_argument("--repo", default=None, help="owner/name (default: the origin remote)")
    p_replay.add_argument("--attestation", default=None,
                          help="optional: after hydrating, run the shared read-only reader over this attestation "
                               "using the hydrated roots")
    p_replay.add_argument("--release-run-id", default=None,
                          help="pre-freeze only: the actual RELEASE run id to capture a proof from (no implicit ids)")
    p_replay.add_argument("--release-attempt", type=int, default=None,
                          help="pre-freeze only: the actual RELEASE run attempt")
    args = ap.parse_args(argv)
    if args.command == "replay":
        return replay(args.run_id, args.attempt, Path(args.out), candidate_tag=args.tag, repo=args.repo,
                      attestation=Path(args.attestation) if args.attestation else None,
                      release_run_id=args.release_run_id, release_attempt=args.release_attempt)
    if args.command == "verify":
        if args.validate_manifest:
            sys.path.insert(0, str(ROOT / "ci"))
            import check_board1_manifest as cbm  # noqa: PLC0415
            return cbm.main(["--manifest", args.validate_manifest])
        if args.attestation:
            # *** THE READER REBINDS THE RECORDS BY IDENTITY, FROM THE EXPLICIT READER-SIDE ROOTS. ***
            return validate_attestation(
                Path(args.attestation),
                artifact_dir=Path(args.artifacts) if args.artifacts else None,
                campaign_dir=Path(args.campaign_dir) if args.campaign_dir else None,
                evidence_root=Path(args.evidence_root) if args.evidence_root else None,
                proof_dir=Path(args.proof_dir) if args.proof_dir else None)
        return verify(only=args.only,
                      artifact_dir=Path(args.artifacts) if args.artifacts else None,
                      build_manifest_out=Path(args.manifest_out) if args.manifest_out else None,
                      tag=args.tag, campaign_dir=args.campaign_dir,
                      proof_dir=Path(args.proof_dir) if args.proof_dir else None,
                      evidence_root=Path(args.evidence_root) if args.evidence_root else None,
                      frozen_artifacts=Path(args.frozen_artifacts) if args.frozen_artifacts else None,
                      frozen_campaign_dir=Path(args.frozen_campaign_dir) if args.frozen_campaign_dir else None,
                      frozen_evidence_root=Path(args.frozen_evidence_root) if args.frozen_evidence_root else None,
                      frozen_proof_dir=Path(args.frozen_proof_dir) if args.frozen_proof_dir else None)
    if args.command == "freeze":
        return freeze(args.run_id, args.tag, Path(args.attest_out), args.attempt,
                      manifest=Path(args.manifest) if args.manifest else None,
                      campaign_dir=args.campaign_dir,
                      manifest_artifact=args.manifest_artifact,
                      proof_dir=Path(args.proof_dir) if args.proof_dir else None,
                      artifact_dir=Path(args.artifacts) if args.artifacts else None,
                      evidence_root=Path(args.evidence_root) if args.evidence_root else None)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
