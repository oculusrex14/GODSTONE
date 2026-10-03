#! /usr/bin/env python3
"""*** THE EVIDENCE POPULATION BUNDLE: WHAT BYTES THIS REPOSITORY OWNS, AND WHAT IT MERELY EXAMINED. ***

WHY THIS EXISTS. Two different things have been called "evidence", and a clean clone can only be required to carry one
of them:

  * REPOSITORY-OWNED CURRENT bytes -- TRACKED under `docs/remediation/evidence/`. These MUST be present in a clean
    clone, and a missing one is a REAL failure rather than a deferral.
  * OUT-OF-REPOSITORY HISTORICAL bytes -- the builder evidence root (`GODSTONE_BUILDER_EVIDENCE`), untracked by
    design. These are EXAMINED where they exist and DECLARED ABSENT where they do not; **they may never be the reason
    an internal gate is green, and their absence must not be silently skipped.**

*** AND A FROZEN HISTORICAL RUN IS A THIRD THING AGAIN: tracked bytes that describe a PAST run (the rc11 evidence,
which the closure record citeth by name). They are PRESENT and DIGESTED here, but they are marked HISTORICAL so no
reader mistakes a frozen result for a current one. ***

*THE FIELD THAT MAKES THIS HONEST IS `counts_accounted` AND THE FIVE-WAY PARTITION: registered == examined +
unresolved + unnamed + declared_lost + undigested. A denominator that quietly shrank is the defect this whole family
of instruments existeth to refuse.*

*** THE THREE DEFECTS THIS GENERATOR NOW REFUSES, EACH MEASURED RATHER THAN ARGUED. ***

  1. **THE DIGEST SET WAS DERIVED FROM A DIRECTORY WALK.** `rglob("*")` digesteth EVERY file under the evidence
     directory, including UNTRACKED files the user owns (protected archives, in-flight artifacts) -- while the notes
     claimed the set was "every TRACKED file a clean clone carries". *A walk and a clean-clone namespace are not the
     same population: a digest a clone cannot carry is not a clean-clone claim, and a protected untracked archive was
     being absorbed into the candidate's namespace.* **So the population is now `git ls-files` (TRACKED ONLY), the
     untracked-but-present files are NAMED rather than digested, and a git failure REFUSETH instead of falling back to
     the walk that caused the defect.**
  2. **`--check` VALIDATED ONLY THE LISTED DIGESTS.** A file that DISAPPEARED from the list, or an extra one that
     appeared in the tree, was invisible: the check confirmed the entries it was given and never compared the list to
     the live population. **So membership is now checked in BOTH directions -- every digested path must be tracked and
     present, and every tracked evidence file must be digested -- and the stored count is re-derived rather than
     trusted.**
  3. **THE LEDGER PARTITION WAS TRUSTED FROM STORED JSON.** `counts_accounted` was read from the record and reported;
     a stored `true` over a partition that no longer closed would have passed. **So the partition is RECOMPUTED here
     and the stored value must equal the recomputation -- the arithmetic, not the assertion, is the check.**

  AND THREE FAIL-CLOSED RULES: a MISSING/MALFORMED release-gate document is an ERROR rather than an empty external
  population (an empty gate population readeth as "no external work", which is the false all-clear this file exists to
  refuse), the HISTORICAL digests are taken from the IMMUTABLE rc14 ANCHOR (tag object -> commit -> blob) rather
  than from current working-tree bytes (a frozen run may not be silently rewritten and still read as frozen), and a
  file TRACKED in the index but ABSENT from the working tree is a NAMED defect, never a silent omission from the
  digest map -- a map that quietly dropped it would let the clean-clone claim cover a file no clone could carry.
  **AND ONE IMPORTED LAW: the future post-tag attestation policy is adjudicated by the canonical freeze authority
  (`ci/check_candidate_binding.py::validate_attestation`), which this file NAMES and DELEGATES to -- never restates.**

Usage:
    python3 scripts/build_evidence_bundle.py --write
    python3 scripts/build_evidence_bundle.py --check
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "remediation" / "evidence" / "board1-evidence-bundle.json"
EVIDENCE_DIR = ROOT / "docs" / "remediation" / "evidence"
EVIDENCE_REL = "docs/remediation/evidence"
LEDGER = ROOT / "docs" / "remediation" / "REMEDIATION_STATE.json"
RELEASE_GATES = ROOT / "docs" / "production" / "RELEASE_GATES_STATUS.json"
CLOSURE_RECORD = ROOT / "docs" / "production-readiness" / "BOARD1_CLOSURE.json"

#: *** THE IMMUTABLE HISTORICAL ANCHOR: ORIGINAL A14 COMMIT, C14 PARENT, TAG OBJECT AND ATTESTATION BLOB. ***
#:
#: *The original rc14 attestation exists ONLY on direct child A14 (4c0569eef6f79871afc4108346e34f461f241cd4), NOT on
#: tag C14 (f76c5ae3cd54a19ca7489f492441e91af50edddc, tree 4157f3eb23a23cdbb33a86b7590ffd665f8ef14a). A14^1 == C14,
#: and the delta is EXACTLY docs/remediation/evidence/FREEZE_ATTESTATION_rc14.json with Git blob
#: 67930bbbef50d8811901f8308043abee18fd1dc7 and SHA-256 fe3720404acedb3a4efd7530eaa01d43d370419d44e66e6c85edd1aad6bb8717.*
#: **This anchor is IMMUTABLE and provided: historical records read from A14's blobs, FREEZE_ATTESTATION_rc14.json
#: remains historical, registered, and digested in the clean-clone namespace (NOT excluded), and the tag object
#: 2481e66d7dad7417d142507d74bdce0b06a8ec24 is pinned so a moved tag is refused.**
HISTORICAL_ANCHOR = {
    "tag": "production-readiness-board1-rc14",
    "tag_object_sha": "2481e66d7dad7417d142507d74bdce0b06a8ec24",
    "commit_sha": "4c0569eef6f79871afc4108346e34f461f241cd4",  # A14 commit carrying attestation
    "candidate_c14_sha": "f76c5ae3cd54a19ca7489f492441e91af50edddc",  # A14^1 == C14
    "candidate_c14_tree": "4157f3eb23a23cdbb33a86b7590ffd665f8ef14a",
    "attestation_blob_sha": "67930bbbef50d8811901f8308043abee18fd1dc7",
    "attestation_sha256": "fe3720404acedb3a4efd7530eaa01d43d370419d44e66e6c85edd1aad6bb8717",
    "attestation_path": "docs/remediation/evidence/FREEZE_ATTESTATION_rc14.json",
}

#: *** FROZEN HISTORICAL RUNS, BY NAME. *** *These tracked directories hold the bytes of a PAST run; they are present
#: and digested, and they are marked HISTORICAL so a frozen result is never read as a current one.*
HISTORICAL_PREFIXES = (
    "board1-rc11-crash/",
    "board1-rc11-integration/",
    "board1-rc11-rods/",
    "board1-rods/",
    "rc11-step13/",
    "rc11-verify/",
    "gs-stress-001-30k-samples/",
)

EXTERNAL_BLOCKED_STATUSES = ("BLOCKED_EXTERNAL", "OPEN", "CLOSED")

#: *** THE DECLARED PLANNED NEXT ATTESTATION PATH FOR FUTURE CANDIDATE 15. ***
#:
#: *The planned next unused candidate attestation is `FREEZE_ATTESTATION_rc15.json` (the parent orchestrates
#: candidate 15). At candidate C this future file is 0-tracked and the check never requires it; at post-tag commit
#: A15 the delta is adjudicated by the IMPORTED canonical freeze authority, `check_candidate_binding.
#: validate_attestation` -- exactly one validated direct child (A15^1 == C15) against this ONE exact path,
#: compared by equality, never a prefix, glob, or directory allowance, and never the historical rc14 attestation.*
PLANNED_FUTURE_ATTESTATION = "docs/remediation/evidence/FREEZE_ATTESTATION_rc15.json"


class BundleError(RuntimeError):
    """A condition under which a bundle may not be written or accepted."""


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, timeout=120)


def canonical_freeze():
    """*** IMPORT THE CANONICAL FREEZE AUTHORITY; NEVER RESTATE ITS LAW. ***

    The post-tag attestation policy -- exact-path allowance, exactly one validated direct child at the
    successor, never a prefix/glob/directory, rc14 immutable -- is OWNED by `ci/check_candidate_binding.py`
    (the CanonicalFreeze instrument). *This bundle DECLARES the planned path and DELEGATES the adjudication.*
    A failure to import is raised to the caller as a REFUSAL: a policy one cannot read may not be assumed.
    """
    ci_dir = str(ROOT / "ci")
    if ci_dir not in sys.path:
        sys.path.insert(0, ci_dir)
    import check_candidate_binding
    return check_candidate_binding


def tracked_evidence_paths() -> list[str]:
    """*** THE CLEAN-CLONE POPULATION: TRACKED FILES UNDER THE EVIDENCE ROOT, AND NOTHING ELSE. ***

    *THE DEFECT THIS CLOSES: a directory walk absorbed UNTRACKED user archives into a set the notes called "tracked
    files a clean clone carries".* **A digest the clone cannot reproduce is not a clean-clone claim.** *The repository's
    own index is the authority, and a git failure REFUSETH -- falling back to the walk would reproduce the defect
    exactly when the index cannot speak.*
    """
    proc = _git("ls-files", "-z", "--", EVIDENCE_REL)
    if proc.returncode != 0:
        raise BundleError(
            f"git ls-files failed for {EVIDENCE_REL} (rc={proc.returncode}): {proc.stderr.strip()} -- the tracked "
            f"population cannot be established, so no clean-clone claim may be made")
    out = [p for p in proc.stdout.split("\0") if p]
    self_rel = str(OUT.relative_to(ROOT))
    return sorted(p for p in out if p != self_rel and Path(p).suffix != ".pyc")




def post_tag_exclusion_problems() -> list[str]:
    """Adjudicate the exact future path through the canonical authority.

    Candidate territory is the measured HEAD, never a historical-tag fallback.
    Successor territory requires the full committed-attestation reader, including
    tag identity, clean direct-child relation and authenticated terminal evidence.
    """
    problems: list[str] = []
    p = PLANNED_FUTURE_ATTESTATION
    if not p or any(ch in p for ch in "*?[]"):
        problems.append(f"PLANNED_FUTURE_ATTESTATION must be ONE LITERAL path, not a wildcard/prefix allowance "
                        f"(got {p!r}) -- the declared exclusion nameth the exact future-A attestation, never a family")
        return problems
    if Path(p).is_absolute() or ".." in Path(p).parts:
        problems.append(f"PLANNED_FUTURE_ATTESTATION {p!r} must be a repository-relative path inside the tree")
        return problems
    if p == HISTORICAL_ANCHOR["attestation_path"]:
        problems.append("PLANNED_FUTURE_ATTESTATION cannot be the historical rc14 attestation -- rc14 remains "
                        "historical, registered, and anchored to the original A14 blob")
    try:
        canonical = canonical_freeze()
    except Exception as exc:
        problems.append(f"the canonical freeze authority could not be imported ({exc}) -- the post-tag delta law "
                        f"is IMPORTED from ci/check_candidate_binding.py, and a policy that cannot be read may "
                        f"not be assumed")
        return problems
    required = ("attest_exclusion_policy", "validate_attestation", "rebind_from_environment")
    missing = [n for n in required if not callable(getattr(canonical, n, None))]
    if missing:
        problems.append(f"the canonical freeze authority exposeth not {missing} -- the future-A law is IMPORTED, "
                        f"and a delegation target that doth not exist may not be replaced by a local opinion")
        return problems
    future_path = getattr(canonical, "FREEZE_ATTESTATION_SUCCESSOR_PATH", None)
    if future_path != p:
        problems.append(f"the declared PLANNED_FUTURE_ATTESTATION {p!r} drifts from the authority's "
                        f"FREEZE_ATTESTATION_SUCCESSOR_PATH {future_path!r} -- one path, named once")
        return problems
    head_result = _git("rev-parse", "HEAD")
    head = head_result.stdout.strip()
    if head_result.returncode != 0 or not head:
        problems.append("HEAD could not be resolved; no future-attestation exclusion may be granted")
        return problems
    if p not in set(tracked_evidence_paths()):
        verdict = canonical.attest_exclusion_policy(future_path=future_path, candidate=head)
        problems.extend(f"the canonical freeze authority refused the future-A exclusion: {msg}"
                        for msg in verdict)
        return problems
    try:
        rebind = canonical.rebind_from_environment()
        verdict = canonical.validate_attestation(ROOT / future_path, rebind=rebind or None)
    except Exception as exc:
        problems.append(f"the full canonical attestation reader could not adjudicate the successor: {exc}")
        return problems
    problems.extend(f"the canonical freeze authority refused the executing successor: {msg}"
                    for msg in verdict)
    return problems


def untracked_evidence_paths() -> list[str]:
    """*** FILES PRESENT UNDER THE EVIDENCE ROOT THAT THE REPOSITORY DOES NOT OWN -- NAMED, NEVER DIGESTED. ***

    *A protected user archive, or an artifact another owner has not yet committed, is REPORTED here so a reader can
    see it exists; it is never folded into the candidate's digest namespace and never silently ignored.*
    """
    proc = _git("ls-files", "--others", "--exclude-standard", "-z", "--", EVIDENCE_REL)
    if proc.returncode != 0:
        raise BundleError(
            f"git ls-files --others failed for {EVIDENCE_REL} (rc={proc.returncode}): {proc.stderr.strip()}")
    return sorted(p for p in proc.stdout.split("\0") if p and Path(p).suffix != ".pyc")


def repo_evidence_digests() -> dict[str, str]:
    """Every TRACKED file under the canonical in-repo evidence directory, keyed repo-relative.

    *** THE BUNDLE MAY NOT DIGEST ITSELF. *** *A document that carried its own hash inside its own digest set would
    have to change whenever it changed -- the self-reference the candidate-sha rule already forbids. So the bundle's own
    path is excluded from its digest map, and its integrity is carried by `document_sha256` OVER THE BODY instead.*

    *** AND THE HISTORICAL rc14 ATTESTATION IS PRESERVED AND DIGESTED IN THE CLEAN-CLONE NAMESPACE. ***
    *The population count is derived from `git ls-files` at every run, never pinned here as prose.* The planned
    future post-tag attestation is excluded from the digest map only once it is tracked -- at C it is 0-tracked.
    """
    out: dict[str, str] = {}
    self_rel = str(OUT.relative_to(ROOT))
    excluded = {self_rel}
    tracked = tracked_evidence_paths()
    if PLANNED_FUTURE_ATTESTATION in tracked:
        excluded.add(PLANNED_FUTURE_ATTESTATION)
    for rel in tracked:
        if rel in excluded:
            continue
        p = ROOT / rel
        if not p.is_file():
            # A TRACKED PATH ABSENT FROM THE WORKING TREE IS A REAL DEFECT, NOT A SKIP.
            continue
        out[rel] = sha256_file(p)
    return out


def historical_anchor_facts() -> tuple[dict, list[str]]:
    """*** RESOLVE THE IMMUTABLE ANCHOR AT ORIGINAL A14, OR SAY WHY IT CANNOT BE RESOLVED. ***"""
    problems: list[str] = []
    facts = dict(HISTORICAL_ANCHOR)
    tag = HISTORICAL_ANCHOR["tag"]
    obj = _git("rev-parse", tag)
    peel = _git("rev-parse", f"{tag}^{{commit}}")
    tree = _git("rev-parse", f"{tag}^{{tree}}")
    if obj.returncode != 0 or peel.returncode != 0 or tree.returncode != 0:
        problems.append(f"the historical anchor tag {tag!r} does not resolve locally -- the frozen bytes cannot be "
                        f"read, and current working-tree bytes are NOT a substitute for history")
        return facts, problems
    live_tag_obj = obj.stdout.strip()
    live_c14_commit = peel.stdout.strip()
    live_c14_tree = tree.stdout.strip()
    facts["live_tag_object_sha"] = live_tag_obj
    facts["live_candidate_c14_sha"] = live_c14_commit
    facts["live_candidate_c14_tree"] = live_c14_tree
    if live_tag_obj != HISTORICAL_ANCHOR["tag_object_sha"]:
        problems.append(f"the anchor tag {tag!r} carrieth object {live_tag_obj} while the immutable record "
                        f"nameth {HISTORICAL_ANCHOR['tag_object_sha']} -- a MOVED tag is not an anchor")
    if live_c14_commit != HISTORICAL_ANCHOR["candidate_c14_sha"] or live_c14_tree != HISTORICAL_ANCHOR["candidate_c14_tree"]:
        problems.append(f"the anchor tag {tag!r} peeleth to commit {live_c14_commit} tree {live_c14_tree} "
                        f"while the immutable record nameth {HISTORICAL_ANCHOR['candidate_c14_sha']} / "
                        f"{HISTORICAL_ANCHOR['candidate_c14_tree']}")
    a14 = HISTORICAL_ANCHOR["commit_sha"]
    a14_parent = _git("rev-parse", f"{a14}^")
    if a14_parent.returncode != 0 or a14_parent.stdout.strip() != live_c14_commit:
        problems.append(f"A14 commit {a14} parent is {a14_parent.stdout.strip()!r}, expected C14 commit {live_c14_commit}")
    blob_proc = _git("rev-parse", f"{a14}:{HISTORICAL_ANCHOR['attestation_path']}")
    if blob_proc.returncode != 0:
        problems.append(f"the historical attestation {HISTORICAL_ANCHOR['attestation_path']} does not exist in A14 commit {a14}")
    elif blob_proc.stdout.strip() != HISTORICAL_ANCHOR["attestation_blob_sha"]:
        problems.append(f"historical attestation blob in A14 is {blob_proc.stdout.strip()}, expected {HISTORICAL_ANCHOR['attestation_blob_sha']}")
    else:
        data = blob_at(a14, HISTORICAL_ANCHOR["attestation_path"])
        if data is None or sha256_bytes(data) != HISTORICAL_ANCHOR["attestation_sha256"]:
            problems.append(f"historical attestation blob SHA-256 mismatch against {HISTORICAL_ANCHOR['attestation_sha256']}")
        p = ROOT / HISTORICAL_ANCHOR["attestation_path"]
        if not p.is_file():
            problems.append(f"the historical attestation {p} is missing from the working tree")
        elif sha256_file(p) != HISTORICAL_ANCHOR["attestation_sha256"]:
            problems.append(f"the live attestation {p} does not match the original A14 sha256")
    return facts, problems


def blob_at(commit: str, rel: str) -> bytes | None:
    proc = subprocess.run(["git", "-C", str(ROOT), "cat-file", "blob", f"{commit}:{rel}"],
                          capture_output=True, timeout=120)
    return proc.stdout if proc.returncode == 0 else None


def historical_records(commit: str | None) -> list[dict]:
    """*** THE FROZEN TRACKED EVIDENCE FILES, DIGESTED AT THE ANCHOR COMMIT. ***

    *THE DEFECT THIS CLOSES: the digest was taken from the WORKING TREE, so a historical file could be edited and
    still be reported as frozen.* **Now the blob at the anchor commit is the authority, and the live file (when it
    exists) is compared to it.** *A mismatch is refused by `--check`, because a frozen run whose bytes moved is no
    longer the run it names.*
    """
    records: list[dict] = []
    digests = repo_evidence_digests()
    if commit is None:
        return records
    for rel in sorted(digests):
        rel_in = rel.split("evidence/", 1)[-1]
        if not any(rel_in.startswith(p) for p in HISTORICAL_PREFIXES):
            continue
        data = blob_at(commit, rel)
        if data is None:
            records.append({
                "id": rel_in, "path": rel, "sha256": None, "anchor_commit": commit,
                "blob_sha": None, "scope": "HISTORICAL -- ANCHOR BLOB ABSENT",
                "superseded_by": None,
            })
            continue
        records.append({
            "id": rel_in,
            "path": rel,
            "sha256": sha256_bytes(data),
            "anchor_commit": commit,
            "blob_sha": subprocess.run(["git", "-C", str(ROOT), "rev-parse", f"{commit}:{rel}"],
                                       capture_output=True, text=True, timeout=120).stdout.strip(),
            "scope": "HISTORICAL -- a FROZEN run read at the immutable anchor, not a current one",
            "superseded_by": None,
        })
    return records


def load_ledger_counts(document: dict | None = None) -> dict:
    """Classify every authored reference ONCE, against the record's own declared evidence root.

    *A caller that hath already read the ledger passeth the parsed document, so the register is classified a
    single time and every consumer of one build seeth the SAME partition.* **Two classifications of one record
    are two authorities, which is the drift class this family refuseth.** User-owned archives are not opened:
    the classifier examineth Git-owned bytes and the declared builder root only.
    """
    if str(ROOT / "scripts") not in sys.path:
        sys.path.insert(0, str(ROOT / "scripts"))
    from evidence_registry import RegistryError, classify
    try:
        if document is None:
            document = json.loads(LEDGER.read_text(encoding="utf-8"))
        return classify(document, root=ROOT, anchor_commit=HISTORICAL_ANCHOR["commit_sha"])
    except (OSError, ValueError, RegistryError) as exc:
        raise BundleError(f"the SOURCE evidence registry cannot be derived: {exc}") from exc


def external_identities() -> tuple[list[dict], list[str]]:
    """*** THE EXTERNAL GATES, BY IDENTITY, FROM THE AUTHORITATIVE RELEASE-GATE DOCUMENT. ***

    *THE DEFECT THIS CLOSES: a missing or malformed release-gate document became an EMPTY gate population -- which
    readeth as "no external work remains", the false all-clear.* **So absence and malformation are PROBLEMS, returned
    to the caller to refuse on, and an empty `gates` list is itself a problem rather than a green population.**
    """
    problems: list[str] = []
    out: list[dict] = []
    if not RELEASE_GATES.is_file():
        try:
            shown = RELEASE_GATES.relative_to(ROOT)
        except ValueError:
            shown = RELEASE_GATES
        problems.append(f"the authoritative release-gate document {shown} is ABSENT -- an "
                        f"external population that cannot be read is NOT an empty one")
        return out, problems
    try:
        doc = json.loads(RELEASE_GATES.read_text(encoding="utf-8"))
    except ValueError as exc:
        problems.append(f"the release-gate document is MALFORMED JSON: {exc} -- a gate population that cannot be "
                        f"read must fail closed")
        return out, problems
    gates = doc.get("gates")
    if not isinstance(gates, list) or not gates:
        problems.append("the release-gate document carrieth NO gates -- an EMPTY external population is refused, "
                        "because it readeth as 'no external work remains'")
        return out, problems
    for gate in gates:
        if not isinstance(gate, dict) or not gate.get("gate"):
            problems.append(f"a release-gate entry is malformed (no id): {gate!r}")
            continue
        raw = str(gate.get("status", "")).upper()
        status = {"OPEN": "OPEN", "BLOCKED": "BLOCKED_EXTERNAL", "CLOSED": "CLOSED"}.get(raw)
        if status is None:
            problems.append(f"release gate {gate.get('gate')!r} carrieth status {gate.get('status')!r}, which maps "
                            f"to no known external class")
            continue
        out.append({
            "id": gate.get("gate"),
            "class": gate.get("class") or "external-gate",
            "status": status,
            "closure_evidence": gate.get("evidence_commit"),
            "required_artifact_schema": gate.get("closure_requirement"),
        })
    return out, problems


def document_digest(body: dict) -> str:
    canonical = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def build() -> tuple[dict, list[str]]:
    problems: list[str] = []
    anchor_facts, anchor_problems = historical_anchor_facts()
    problems.extend(anchor_problems)
    problems.extend(post_tag_exclusion_problems())
    digests = repo_evidence_digests()
    untracked = untracked_evidence_paths()
    ledger_document = json.loads(LEDGER.read_text(encoding="utf-8"))
    ledger_counts = load_ledger_counts(ledger_document)
    # *** A TRACKED FILE ABSENT FROM THE TREE IS A NAMED DEFECT, NEVER A SILENT OMISSION. ***
    # *`repo_evidence_digests` skipmeth tracked-but-absent paths, so the map could shrink without a word while the
    # notes still claimed full clean-clone coverage.* **The diff against the INDEX is taken here and each missing
    # path is named: restore it or untrack it -- the choice is the reader's, the silence is not.**
    for rel in sorted(set(tracked_evidence_paths()) - set(digests) - {PLANNED_FUTURE_ATTESTATION}):
        problems.append(f"{rel}: TRACKED in the git index but ABSENT from the working tree -- a clean clone "
                        f"could not carry it, so the digest map may not silently omit it either")
    external, external_problems = external_identities()
    problems.extend(external_problems)
    if not ledger_counts["counts_accounted"]:
        problems.append(f"the ledger's five-way partition does NOT close: registered "
                        f"{ledger_counts['registered']} != accounted {ledger_counts['accounted']}")
    historical = historical_records(anchor_facts.get("commit_sha"))
    missing_anchor = [r["path"] for r in historical if r["sha256"] is None]
    if missing_anchor:
        problems.append(f"{len(missing_anchor)} historical file(s) are not carried by the anchor commit: "
                        f"{missing_anchor[:3]}")
    body = {
        "schema": 2,
        # *** A DECLARED ROOT THAT IS THE REPOSITORY ITSELF. *** *A clean clone carries these bytes, so a consumer may
        # REQUIRE them; the out-of-repository builder root is DECLARED SEPARATELY and is never required.*
        "evidence_root": "repo:docs/remediation/evidence",
        "namespace_rule": ("TRACKED files under docs/remediation/evidence -- the clean-clone population, derived from "
                          "`git ls-files`, never from a directory walk. Only this bundle itself is excluded (self-reference rule)."),
        "planned_post_tag_attestation": PLANNED_FUTURE_ATTESTATION,
        "post_tag_exclusion_policy": (
            f"DECLARED plan; IMPORTED law. The planned next unused candidate attestation is {PLANNED_FUTURE_ATTESTATION}. "
            f"At candidate C it is 0-tracked and the check never requires it. At successor A15 the delta is adjudicated by "
            f"ci/check_candidate_binding.py::validate_attestation -- exactly one validated direct-child change "
            f"(A15^1 == C15) against this ONE exact path, compared by equality, never a prefix, glob, or directory. "
            f"The historical rc14 attestation ({HISTORICAL_ANCHOR['attestation_path']}) is immutable historical evidence "
            f"from A14: tracked, digested, and anchored to original A14 blob {HISTORICAL_ANCHOR['attestation_blob_sha']}."
        ),
        "historical_root_declared": {
            "path": str(ledger_document.get("evidence_root") or ""),
            "availability": "out-of-repo, NOT required for the internal gate; examined where present, "
                            "declared absent where not",
        },
        "digests": digests,
        "repo_internal": {
            "files": len(digests),
            "root": "docs/remediation/evidence",
            "namespace": "tracked-only",
        },
        # *** UNTRACKED FILES ARE NAMED, NEVER DIGESTED. *** *A protected user archive or an in-flight artifact is
        # reported so a reader seeth it; it is not absorbed into the candidate's clean-clone namespace.*
        "untracked_present": untracked,
        "ledger_registered_partition": ledger_counts,
        "registered": ledger_counts["registered"],
        "examined": ledger_counts["examined"],
        "verified": ledger_counts["verified"],
        "mismatched": ledger_counts["mismatched"],
        "unresolved": ledger_counts["unresolved"],
        "unnamed": ledger_counts["unnamed"],
        "declared_lost": ledger_counts["declared_lost"],
        "undigested": ledger_counts["undigested"],
        "counts_accounted": ledger_counts["counts_accounted"],
        "accounted": ledger_counts["accounted"],
        "partition_rule": ledger_counts["partition_rule"],
        "historical_anchor": anchor_facts,
        "historical": historical,
        "external": external,
        "external_problems": external_problems,
        "notes": (
            "digests cover every TRACKED file under docs/remediation/evidence, which a clean clone carries; a file "
            "present but untracked is named in `untracked_present` and never digested. The out-of-repository builder "
            "evidence root is DECLARED in historical_root_declared and is NEVER required: its absence defers "
            "historical arms rather than failing the internal gate, and its presence can never make an internal court "
            "green because no internal court reads it. Historical digests are read at the immutable rc14 anchor."
        ),
    }
    body["document_sha256"] = document_digest(body)
    return body, problems


def check(doc: dict) -> list[str]:
    """*** EVERY CLAIM THE BUNDLE MAKETH, RE-DERIVED FROM THE LIVE TREE. ***

    *Membership is checked in BOTH directions (a missing entry and an extra file are each a defect), the namespace is
    the TRACKED population, the historical digests are re-read at the anchor, the partition arithmetic is recomputed,
    and the external population must be present and non-empty.*
    """
    problems: list[str] = []
    self_rel = str(OUT.relative_to(ROOT))
    claimed = doc.get("document_sha256")
    body = {k: v for k, v in doc.items() if k != "document_sha256"}
    if claimed != document_digest(body):
        problems.append("document_sha256 does not re-derive over the body")

    # (1) MEMBERSHIP, BOTH DIRECTIONS, AGAINST THE TRACKED POPULATION.
    try:
        live = repo_evidence_digests()
        tracked = set(tracked_evidence_paths())
    except BundleError as exc:
        return problems + [f"the tracked population cannot be established: {exc}"]
    recorded = doc.get("digests") or {}
    for rel in sorted(set(recorded) - set(live)):
        problems.append(f"{rel}: digested in the bundle but NOT a tracked evidence file now present in the tree")
    for rel in sorted(set(live) - set(recorded)):
        problems.append(f"{rel}: a tracked evidence file the bundle does NOT digest -- the namespace is not covered")
    # *** THE PLANNED NEXT ATTESTATION POLICY: VALIDATED, NEVER A BROAD WILDCARD OR EXCLUDING rc14. ***
    problems.extend(post_tag_exclusion_problems())
    if doc.get("planned_post_tag_attestation") != PLANNED_FUTURE_ATTESTATION:
        problems.append(f"planned_post_tag_attestation is {doc.get('planned_post_tag_attestation')!r} but expected "
                        f"{PLANNED_FUTURE_ATTESTATION!r}")
    # Historical rc14 attestation MUST be digested as part of the clean-clone namespace!
    rc14_path = HISTORICAL_ANCHOR["attestation_path"]
    if rc14_path not in recorded:
        problems.append(f"{rc14_path}: historical rc14 attestation must be digested in the candidate's namespace "
                        f"(cannot be discarded as self namespace)")
    elif recorded[rc14_path] != HISTORICAL_ANCHOR["attestation_sha256"]:
        problems.append(f"{rc14_path}: digest {recorded[rc14_path][:12]}... does not match original A14 sha256 "
                        f"{HISTORICAL_ANCHOR['attestation_sha256'][:12]}...")
    # The planned future attestation must not be digested at C (0 tracked allowed)
    if PLANNED_FUTURE_ATTESTATION in recorded:
        problems.append(f"{PLANNED_FUTURE_ATTESTATION}: the future candidate attestation may NOT be digested at C")
    # *** AND THE BUNDLE MAY NOT DIGEST ITSELF. *** *The self-reference the document_sha256 existeth to avoid.*
    if self_rel in recorded:
        problems.append(f"{self_rel}: the bundle digests ITSELF -- a member of its own clean-clone namespace; "
                        f"its integrity is carried by document_sha256 over the body, not by a self-digest")
    for rel, want in recorded.items():
        p = ROOT / rel
        if rel not in tracked:
            problems.append(f"{rel}: digested but NOT TRACKED -- a clean clone cannot carry it")
        elif not p.is_file():
            problems.append(f"{rel}: TRACKED but ABSENT from the tree")
        elif sha256_file(p) != want:
            problems.append(f"{rel}: digest does not match the file")

    # (2) UNTRACKED PRESENT FILES ARE NAMED, AND NEVER APPEAR AS DIGESTS.
    try:
        untracked = set(untracked_evidence_paths())
    except BundleError as exc:
        untracked = set()
        problems.append(f"the untracked population cannot be established: {exc}")
    if set(doc.get("untracked_present") or []) != untracked:
        problems.append(f"untracked_present is stale: bundle {sorted(doc.get('untracked_present') or [])!r} != live "
                        f"{sorted(untracked)!r}")
    for rel in recorded:
        if rel in untracked:
            problems.append(f"{rel}: digested although UNTRACKED -- the candidate's namespace may not absorb it")

    # (3) THE HISTORICAL DIGESTS, RE-READ AT THE ANCHOR.
    anchor_facts, anchor_problems = historical_anchor_facts()
    problems.extend(anchor_problems)
    if (doc.get("historical_anchor") or {}).get("tag_object_sha") != anchor_facts.get("tag_object_sha"):
        problems.append("historical_anchor.tag_object_sha disagrees with the live tag object -- the anchor moved")
    anchor_commit = anchor_facts.get("commit_sha")
    live_hist = {r["path"]: r for r in historical_records(anchor_commit)}
    recorded_hist = {r["path"]: r for r in (doc.get("historical") or [])}
    for rel in sorted(set(recorded_hist) | set(live_hist)):
        rec, live_rec = recorded_hist.get(rel), live_hist.get(rel)
        if rec is None:
            problems.append(f"historical {rel}: carried at the anchor but ABSENT from the bundle")
        elif live_rec is None:
            problems.append(f"historical {rel}: in the bundle but not historical under the live prefix set")
        elif rec.get("sha256") != live_rec.get("sha256"):
            problems.append(f"historical {rel}: digest at the anchor differs from the bundle")
        else:
            p = ROOT / rel
            if not p.is_file():
                problems.append(f"historical {rel}: ABSENT from the tree (an absent historical identity is a REFUSAL)")
            elif sha256_file(p) != rec["sha256"]:
                problems.append(f"historical {rel}: the LIVE bytes differ from the anchor blob -- a frozen run may "
                                f"not be rewritten")

    # (4) THE PARTITION ARITHMETIC, RECOMPUTED HERE.
    recorded_part = doc.get("ledger_registered_partition") or {}
    try:
        live_part = load_ledger_counts()
    except BundleError as exc:
        return problems + [f"the ledger partition cannot be derived: {exc}"]
    for key in ("registered", "examined", "verified", "mismatched", "unresolved", "unnamed", "declared_lost",
                "undigested", "accounted", "counts_accounted", "populations", "partition_rule",
                "records_sha256", "source_sha256", "problems", "historical_anchor_commit",
                "external_proof_scope", "declared_evidence_root", "declared_root_state"):
        if recorded_part.get(key) != live_part.get(key):
            problems.append(f"ledger_registered_partition.{key}: bundle {recorded_part.get(key)!r} != re-derived "
                            f"{live_part.get(key)!r}")
    accounted = (live_part["examined"] + live_part["unresolved"] + live_part["unnamed"]
                 + live_part["declared_lost"] + live_part["undigested"])
    if accounted != live_part["registered"]:
        problems.append(f"the five-way partition does NOT close: registered {live_part['registered']} != "
                        f"accounted {accounted}")
    for key in ("registered", "examined", "verified", "mismatched", "unresolved", "unnamed", "declared_lost",
                "undigested", "counts_accounted", "accounted", "partition_rule"):
        if doc.get(key) != live_part.get(key):
            problems.append(f"{key}: bundle {doc.get(key)!r} != re-derived {live_part.get(key)!r}")
    if not doc.get("counts_accounted"):
        problems.append("counts_accounted is not true")

    # (5) THE EXTERNAL POPULATION MUST BE PRESENT, NON-EMPTY AND FAIL-CLOSED.
    if doc.get("external_problems"):
        for p in doc["external_problems"]:
            problems.append(f"external: {p}")
    external, external_problems = external_identities()
    for p in external_problems:
        problems.append(f"external: {p}")
    recorded_ext = {g.get("id"): g for g in (doc.get("external") or [])}
    live_ext = {g.get("id"): g for g in external}
    if not recorded_ext:
        problems.append("the bundle carrieth NO external gates -- an empty external population is refused")
    for gid in sorted(set(recorded_ext) | set(live_ext)):
        rec, live_g = recorded_ext.get(gid), live_ext.get(gid)
        if rec is None:
            problems.append(f"external gate {gid}: live but ABSENT from the bundle")
        elif live_g is None:
            problems.append(f"external gate {gid}: bundled but not live")
        else:
            for key in ("class", "status", "closure_evidence"):
                if rec.get(key) != live_g.get(key):
                    problems.append(f"external gate {gid}.{key}: bundle {rec.get(key)!r} != live {live_g.get(key)!r}")
    return problems


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="evidence population bundle")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args(argv)

    try:
        bundle, problems = build()
    except BundleError as exc:
        print(f"  ::error:: {exc}")
        return 1
    for p in problems:
        print(f"  ::error:: {p}")

    print(f"  repo-internal evidence files : {bundle['repo_internal']['files']} (tracked)")
    print(f"  untracked (named, not read)  : {len(bundle['untracked_present'])}")
    print(f"  historical (frozen) records  : {len(bundle['historical'])} @ {bundle['historical_anchor'].get('commit_sha')}")
    print(f"  external identities          : {len(bundle['external'])}")
    print(f"  ledger registered partition  : {{'registered': {bundle['registered']}, 'examined': {bundle['examined']}, "
          f"'verified': {bundle['verified']}, 'mismatched': {bundle['mismatched']}, 'unresolved': {bundle['unresolved']}, "
          f"'unnamed': {bundle['unnamed']}, 'declared_lost': {bundle['declared_lost']}, "
          f"'undigested': {bundle['undigested']}, 'counts_accounted': {bundle['counts_accounted']}, "
          f"'accounted': {bundle['accounted']}}}")

    if problems:
        print("  ::error:: the bundle could NOT be derived coherently; refusing to write or accept")
        return 1

    if args.write:
        OUT.write_text(json.dumps(bundle, indent=1, ensure_ascii=False), encoding="utf-8")
        print(f"  wrote {OUT.relative_to(ROOT)}")

    if args.check:
        if not OUT.is_file():
            print(f"  ::error:: {OUT.relative_to(ROOT)} is absent")
            return 1
        doc = json.loads(OUT.read_text(encoding="utf-8"))
        failures = check(doc)
        for msg in failures[:40]:
            print(f"  ::error:: {msg}")
        if len(failures) > 40:
            print(f"  ::error:: ... and {len(failures) - 40} more")
        if failures:
            return 1
        print("  evidence bundle: PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
