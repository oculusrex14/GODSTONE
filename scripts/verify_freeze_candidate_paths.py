#!/usr/bin/env python3
"""*** THE FREEZE'S PATH VERIFIER: EVERY CANDIDATE ARTIFACT PATH MUST RESOLVE, SURVIVE THE FREEZE, AND
NEVER LEAK A BUILD OR TEMP DIRECTORY INTO AN ATTESTATION PAYLOAD. ***

*THE DEFECT THIS CLOSES, AND WHY IT IS THE DANGEROUS CLASS.* A manifest and an attestation are full of paths --
gate logs, the campaign tree, the lane sidecars and result artifacts, the closure record, the ledger, the rc14 anchor,
the release-proof records, and the ONE future-attestation path -- **and a verifier that merely echoes those strings
back proves nothing.** A recorded path can be RELATIVE where the reader resolves it under another root, ABSOLUTE
under a hosted runner's scratch directory that no reader ever carries, MISSING entirely, or a `build/`-directory path
that a reader's own tooling would regenerate. Each of those shapes readeth GREEN under string equality while the real
file access is BROKEN: the verifier then lieth about readiness, and the deployment fails when the real path resolves
(which is the entire build). **So this road RESOLVES every path with the repository's OWN resolution utilities --
`ci/check_board1_manifest._rebind_artifact_path`, `ci/check_candidate_binding._rebind_record_path`,
`tools/readiness/board1._freeze_rebind`, `ci/check_candidate_binding.attest_exclusion_policy` and the real
`check_manifest` -- and refuseth, BY NAME and NON-ZERO, on a path that is missing, ambiguous, absolute-forbidden,
escaping the tree, or a build/temp directory that must never reach an attestation.**

*** IT IS MANIFEST-DRIVEN AND READ-ONLY. *** *The manifest is the authority that lists what the freeze binds; this
road traverseth ITS OWN records rather than a caller-supplied list, so a path a caller forgot cannot be omitted from
the check. It writeth nothing, taketh no timestamp, and is safe to run twice.*

USAGE

    python3 scripts/verify_freeze_candidate_paths.py --manifest PATH \\
        [--base ROOT] [--evidence-root DIR] [--artifacts DIR] [--campaign-dir DIR] [--proof-dir DIR] \\
        [--attestation PATH] [--json]

    python3 -m pytest ci/test_freeze_path_verification.py -q     # the focused selftests

EXIT: 0 when every recorded path resolves, survives the freeze and leaks no build/temp directory; non-zero with a
named refusal otherwise.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

#: *** THE BUILD/TEMP COMPONENTS THAT MUST NEVER APPEAR IN A STABLE, REPO-RELATIVE ARTIFACT PATH OR AN ATTESTATION. ***
#:
#: *These are the directories a build regenerates or a runner discards: a frozen artifact that nameth one is naming
#: bytes that will not exist for the reader who checks out the candidate. The lane RESULTS legitimately live under
#: `.../build/test-results/...` in the downloaded evidence tree -- that is the workflow's own layout, and evidence-class
#: records are EXEMPT for exactly that reason.*
FORBIDDEN_BUILD_COMPONENTS = ("build", ".gradle", "DerivedData", ".build", ".swiftpm")

#: *** THE TEMPORARY PREFIXES (AND A RUNNER_TEMP-SHAPED COMPONENT) THAT MARK A SCRATCH PATH. ***
#:
#: *`/tmp` is a symlink to `/private/tmp` on macOS, `$RUNNER_TEMP` is `.../work/_temp` on a hosted runner -- a path
#: under ANY of these is scratch and may never be a frozen, repo-relative artifact path or an attestation payload.*
FORBIDDEN_TEMP_PREFIXES = ("/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/var/folders", "/dev/shm")
FORBIDDEN_TEMP_COMPONENTS = ("_temp",)

#: The record classes a manifest payload carrieth, and how each resolveth.
#:
#:   * `repo`     -- a stable, repository-relative candidate artifact (closure, ledger, external register).
#:   * `campaign` -- the campaign envelope and the phase logs inside the campaign tree (scratch-rooted on a runner).
#:   * `evidence` -- a downloaded lane artifact/sidecar, joined under the reader's evidence root (build nesting kept).
#:   * `gate-log` -- a gate's retained log, resolved under the `gates` rebind root (or the base).
#:   * `proof`    -- an exact-candidate release-proof record.
#:   * `anchor`   -- an IMMUTABLE ANCHOR whose bytes live in Git, not the work tree (so its WORKING presence is an
#:                   observation, never a requirement -- see `RC14_ANCHOR.file_absent_at_tag_commit`).
CLASS_REPO = "repo"
#: The campaign ENVELOPE path: a BASE-relative path (or mapped by BASENAME under a reader-side campaign root), EXACTLY
#: as `check_manifest` resolveth it. *Distinct from the phase-log rels below, which are CAMPAIGN-ROOT-relative.*
CLASS_CAMPAIGN_MANIFEST = "campaign-manifest"
#: A phase log INSIDE the campaign tree: its recorded path is relative to the campaign digest ROOT.
CLASS_CAMPAIGN_FILE = "campaign-file"
CLASS_EVIDENCE = "evidence"
CLASS_GATE_LOG = "gate-log"
CLASS_PROOF = "proof"
CLASS_ANCHOR = "anchor"
#: An UNRESOLVED substitution token (`{campaign_dir}`) is its own class: it resolves to nothing, so it is refused.
CLASS_TOKEN = "token"

#: Classes whose recorded path is a STABLE artifact that must survive on disk, and so must `exist()`.
_EXISTENCE_REQUIRED = (CLASS_REPO, CLASS_CAMPAIGN_MANIFEST, CLASS_CAMPAIGN_FILE, CLASS_EVIDENCE, CLASS_GATE_LOG,
                       CLASS_PROOF)

#: Classes exempt from the build-component scan, because their real layout legitimately carrieth `build/`.
_BUILD_EXEMPT = (CLASS_EVIDENCE, CLASS_CAMPAIGN_MANIFEST, CLASS_CAMPAIGN_FILE, CLASS_GATE_LOG, CLASS_PROOF)

#: Classes exempt from the temp-prefix scan, because their root is a runner's scratch directory BY CONTRACT.
_TEMP_EXEMPT = (CLASS_CAMPAIGN_MANIFEST, CLASS_CAMPAIGN_FILE, CLASS_EVIDENCE, CLASS_GATE_LOG, CLASS_PROOF)


def _ccb():
    """The ONE candidate-binding authority (the freeze's own path policy lives there)."""
    if str(ROOT / "ci") not in sys.path:
        sys.path.insert(0, str(ROOT / "ci"))
    import check_candidate_binding  # noqa: PLC0415 - imported here so a missing authority degrades loudly
    return check_candidate_binding


def _cbm():
    """The ONE manifest contract (the resolution utility lives there)."""
    if str(ROOT / "ci") not in sys.path:
        sys.path.insert(0, str(ROOT / "ci"))
    import check_board1_manifest  # noqa: PLC0415
    return check_board1_manifest


# ---------------------------------------------------------------------------------------------------------------
# path shape: forbidden, escaping, absolute
# ---------------------------------------------------------------------------------------------------------------
def _components(text: str) -> tuple[str, ...]:
    return tuple(Path(text.replace("\\", "/")).parts)


def forbidden_path_problems(path_text: str, *, label: str, check_build: bool = True,
                            check_temp: bool = True) -> list[str]:
    """*** NAMED PROBLEMS FOR A PATH THAT MUST BE STABLE, REPO-RELATIVE AND NON-SCRATCH. ***

    *`check_build`/`check_temp` are the deliberate per-class carve-outs: an evidence record carrieth the workflow's
    real `.../build/test-results/...` nesting and a gate log carrieth a runner scratch root, so their classes skip the
    scan. Every stable repo-relative record -- and EVERY field of an attestation payload -- is refused a build or temp
    component BY NAME.*
    """
    problems: list[str] = []
    if not isinstance(path_text, str) or not path_text.strip():
        return [f"{label}: the recorded path is EMPTY -- an absent path cannot be resolved, and must never read green"]
    comps = _components(path_text)
    if ".." in comps:
        problems.append(f"{label}: path {path_text!r} carrieth '..' -- *a relative path that escapes an unspecified "
                        f"ancestor is resolved against whatever root the reader happens to be in, never a stable "
                        f"artifact*")
    if check_temp:
        if path_text.startswith("/"):
            for prefix in FORBIDDEN_TEMP_PREFIXES:
                if path_text == prefix or path_text.startswith(prefix.rstrip("/") + "/"):
                    problems.append(f"{label}: path {path_text!r} is under the temporary root {prefix!r} -- *a scratch "
                                    f"path is discarded by the runner and will not exist for the reader who checks out "
                                    f"the candidate*")
                    break
        if any(c in FORBIDDEN_TEMP_COMPONENTS for c in comps):
            problems.append(f"{label}: path {path_text!r} carrieth a temporary component "
                            f"{FORBIDDEN_TEMP_COMPONENTS!r} -- *a RUNNER_TEMP-shaped scratch path is never a frozen "
                            f"artifact path*")
    if check_build and any(c in FORBIDDEN_BUILD_COMPONENTS for c in comps):
        problems.append(f"{label}: path {path_text!r} carrieth a build-directory component -- *a `build/`/`.gradle/`/"
                        f"`DerivedData/`/`.build/` path is REGENERATED by a later build and must never be bound as a "
                        f"frozen artifact*")
    return problems


def _within(child: Path, parent: Path) -> bool:
    """Reuse the manifest contract's own containment rule (never a private re-implementation)."""
    return _cbm()._is_within(child, parent)


# ---------------------------------------------------------------------------------------------------------------
# manifest-driven traversal
# ---------------------------------------------------------------------------------------------------------------
def _rec(label: str, path_text, klass: str, *, rec: dict | None = None) -> dict:
    return {"label": label, "path": path_text, "class": klass, "rec": rec}


def _present(value) -> bool:
    """*** A PATH KEY THAT IS PRESENT IS A RECORD, EVEN WHEN THE VALUE IS EMPTY. ***

    *The defect this guard closeth: a truthiness guard (`rec.get("path")`) SILENTLY SKIPPED an empty path, so a
    manifest whose record named nothing read GREEN -- exactly the broken-file-access class this verifier existeth to
    catch. A present-but-empty path must become a record so `forbidden_path_problems` can refuse it BY NAME.*
    """
    return value is not None


def manifest_path_records(doc: dict) -> list[dict]:
    """*** EVERY PATH THE MANIFEST PAYLOAD NAMES, DERIVED FROM ITS OWN SHAPE. ***

    *The traversal is MANIFEST-DRIVEN because a caller-supplied list would omit exactly the path the caller forgot.
    Each record is tagged with the class that decideth how it resolves and which components are forbidden.* **Gate
    `argv` words are traversed ONLY for an unresolved substitution token -- an input directory the runner resolved may
    legitimately be under `build/` or a scratch root, so requiring it to exist here would red a correct manifest.***
    """
    out: list[dict] = []
    if not isinstance(doc, dict):
        return out
    gates = doc.get("gates") or {}
    for row in gates.get("rows") or []:
        row = row or {}
        gid = row.get("id")
        log = row.get("log") or {}
        if isinstance(log, dict) and _present(log.get("path")):
            out.append(_rec(f"gates.{gid}.log", log.get("path"), CLASS_GATE_LOG, rec=log))
        for i, word in enumerate(row.get("argv") or []):
            if isinstance(word, str) and ("{" in word or "}" in word):
                out.append(_rec(f"gates.{gid}.argv[{i}]", word, CLASS_TOKEN))
    campaign = doc.get("campaign") or {}
    if _present(campaign.get("manifest_path")):
        out.append(_rec("campaign.manifest_path", campaign.get("manifest_path"), CLASS_CAMPAIGN_MANIFEST))
    for i, f in enumerate(campaign.get("files") or []):
        if isinstance(f, dict) and _present(f.get("path")):
            out.append(_rec(f"campaign.files[{i}]", f.get("path"), CLASS_CAMPAIGN_FILE, rec=f))
    for lane in doc.get("lanes") or []:
        lane = lane or {}
        lid = lane.get("id")
        for i, s in enumerate(lane.get("sidecars") or []):
            if isinstance(s, dict) and _present(s.get("rel") or s.get("path")):
                out.append(_rec(f"lanes.{lid}.sidecars[{i}]", s.get("rel") or s.get("path"), CLASS_EVIDENCE, rec=s))
        for i, a in enumerate(lane.get("artifacts") or []):
            if isinstance(a, dict) and _present(a.get("rel") or a.get("path")):
                out.append(_rec(f"lanes.{lid}.artifacts[{i}]", a.get("rel") or a.get("path"), CLASS_EVIDENCE, rec=a))
    for lab, block in (("closure", doc.get("closure")), ("ledger", doc.get("ledger"))):
        rec = (block or {}).get("record")
        if isinstance(rec, dict) and _present(rec.get("path")):
            out.append(_rec(lab, rec.get("path"), CLASS_REPO, rec=rec))
    ext = doc.get("external_evidence") or {}
    for lab, block in (("blockers", ext.get("blockers")), ("release_gates", ext.get("release_gates"))):
        rec = (block or {}).get("record")
        if isinstance(rec, dict) and _present(rec.get("path")):
            out.append(_rec(f"external.{lab}", rec.get("path"), CLASS_REPO, rec=rec))
    for i, entry in enumerate((ext.get("release_proof") or {}).get("records") or []):
        rec = (entry or {}).get("record")
        if isinstance(rec, dict) and _present(rec.get("path")):
            out.append(_rec(f"external.release_proof[{i}]", rec.get("path"), CLASS_PROOF, rec=rec))
    for i, row in enumerate(ext.get("historical") or []):
        if isinstance(row, dict) and _present(row.get("path")):
            out.append(_rec(f"external.historical[{i}]", row.get("path"), CLASS_ANCHOR, rec=row))
    for i, row in enumerate((ext.get("anchors") or {}).get("anchors") or []):
        spec = (row or {}).get("spec") or {}
        if _present(spec.get("path")):
            out.append(_rec(f"external.anchors[{i}].spec", spec.get("path"), CLASS_ANCHOR))
    return out


# ---------------------------------------------------------------------------------------------------------------
# resolution: the REAL utilities, never a private handler
# ---------------------------------------------------------------------------------------------------------------
def resolve_record(record: dict, *, base: Path, rebind: dict | None = None,
                   evidence_root: Path | None = None) -> tuple[Path | None, list[str]]:
    """*** RESOLVE ONE RECORDED PATH WITH THE REPOSITORY'S OWN UTILITIES. ***

    *A `repo` record is joined under `base` and refused when it escapes it; an `evidence` record goeth through
    `ci/check_board1_manifest._rebind_artifact_path` (which PRESERVES the recorded evidence-relative nesting, so a
    lane artifact's real `.../build/test-results/...` layout is not flattened); a `campaign`/`gate-log`/`proof` record
    whose recorded path is absolute is mapped by IDENTITY (`ci/check_candidate_binding._rebind_record_path`) under its
    class root. **When the recorded path is absolute and no root is supplied, the recorded path itself is used -- and
    if it does not exist on this host the resolution FAILS, which is a refusal, never a pass on a path this host
    cannot read.***
    """
    label = record["label"]
    path_text = record["path"]
    klass = record["class"]
    rebind = rebind or {}
    cbm = _cbm()
    ccb = _ccb()

    problems: list[str] = []
    if klass == CLASS_TOKEN or any(ch in str(path_text) for ch in "{}"):
        return None, [f"{label}: path {path_text!r} still carrieth an UNRESOLVED substitution token -- *a manifest "
                      f"row that never named a real directory cannot be verified, and must never read green*"]

    check_build = klass not in _BUILD_EXEMPT
    check_temp = klass not in _TEMP_EXEMPT
    problems.extend(forbidden_path_problems(path_text, label=label, check_build=check_build, check_temp=check_temp))

    rec = record.get("rec") or {}
    _ROOT_KEY = {CLASS_GATE_LOG: "gates", CLASS_PROOF: "proof", CLASS_EVIDENCE: "evidence",
                 CLASS_CAMPAIGN_MANIFEST: "campaign", CLASS_CAMPAIGN_FILE: "campaign"}
    root = rebind.get(_ROOT_KEY.get(klass, klass))
    if klass == CLASS_EVIDENCE:
        evr = evidence_root or rebind.get("evidence")
        if evr is not None:
            disk = cbm._rebind_artifact_path(rec, Path(evr), base)
        elif str(path_text).startswith("/"):
            disk = Path(path_text)
        else:
            disk = base / str(path_text)
    elif klass == CLASS_ANCHOR:
        # *** AN ANCHOR'S BYTES LIVE IN GIT. *** *Its WORKING presence is an observation, never a requirement (the
        # original rc14 attestation exists only on the candidate's direct child, so a clean work tree at `C`
        # legitimately carrieth no such file). Its path is still resolved and shape-checked, and the anchor's own
        # authenticated re-derivation is the manifest consumer's job.*
        disk = (Path(path_text) if str(path_text).startswith("/") else base / str(path_text))
    elif klass == CLASS_REPO:
        if str(path_text).startswith("/"):
            return None, problems + [f"{label}: the repository-relative record {path_text!r} is ABSOLUTE -- *a stable "
                                     f"candidate artifact is named relative to the tree, and an absolute path would "
                                     f"resolve to whatever root the reader happens to be in*"]
        disk = base / str(path_text)
    else:  # CLASS_CAMPAIGN_MANIFEST / CLASS_CAMPAIGN_FILE / CLASS_GATE_LOG / CLASS_PROOF
        if klass == CLASS_CAMPAIGN_MANIFEST:
            # EXACTLY `check_manifest`: a rebind root WINNETH (basename by identity); otherwise the recorded path is
            # BASE-relative -- so a relative envelope is never double-joined under the campaign root.
            if root is not None:
                disk = Path(ccb._rebind_record_path(str(path_text), Path(root)))
            else:
                disk = Path(path_text) if str(path_text).startswith("/") else base / str(path_text)
        elif str(path_text).startswith("/") and root is not None:
            disk = Path(ccb._rebind_record_path(path_text, Path(root)))
        elif str(path_text).startswith("/"):
            disk = Path(path_text)
        elif klass == CLASS_CAMPAIGN_FILE and root is not None:
            # The phase-log rel is relative to the campaign DIGEST root (preserving its nested `logs/...` layout).
            disk = Path(root) / str(path_text)
        else:
            disk = base / str(path_text)

    if klass == CLASS_REPO and not _within(disk, base):
        problems.append(f"{label}: path {path_text!r} resolves to {disk}, which ESCAPES the repository {base} -- "
                        f"*an artifact outside the tree is not one any reader finds*")
        return None, problems
    return disk, problems


def manifest_path_problems(doc: dict, *, base: Path = ROOT, evidence_root: Path | None = None,
                           rebind: dict | None = None, require_exists: bool = True) -> list[str]:
    """*** TRAVERSE EVERY MANIFEST PATH RECORD, RESOLVE IT, AND REFUSE WHAT DOES NOT SURVIVE. ***

    *A path that resolves to nothing `exist()`s -- and that is the exact defect this road existeth to catch: a
    verifier that string-matched the record would pass while the real file access is broken.*
    """
    problems: list[str] = []
    records = manifest_path_records(doc)
    if not records:
        problems.append("the manifest payload names NO artifact path at all -- *a manifest with no resolvable path is "
                        "not a bound candidate*")
    campaign_manifest = None
    campaign = doc.get("campaign") or {}
    if campaign.get("manifest_path"):
        raw = Path(str(campaign["manifest_path"]))
        if raw.is_absolute():
            root = (rebind or {}).get("campaign")
            campaign_manifest = Path(_ccb()._rebind_record_path(str(raw), Path(root))) if root else raw
        else:
            campaign_manifest = base / raw
    rebind = dict(rebind or {})
    if campaign_manifest is not None:
        rebind.setdefault("campaign", campaign_manifest.parent)
    for record in records:
        disk, rproblems = resolve_record(record, base=base, rebind=rebind, evidence_root=evidence_root)
        problems.extend(rproblems)
        if disk is None:
            continue
        if require_exists and record["class"] in _EXISTENCE_REQUIRED and not disk.exists():
            problems.append(f"{record['label']}: recorded path {record['path']!r} resolveth to {disk}, which does "
                            f"NOT EXIST -- *the verifier may never report success while the real file access is "
                            f"broken*")
    return problems


# ---------------------------------------------------------------------------------------------------------------
# attestation payloads: no build/temp leak, and the ONE lawful future path
# ---------------------------------------------------------------------------------------------------------------
def attestation_path_problems(att: dict) -> list[str]:
    """*** NO BUILD OR TEMP PATH MAY LEAK INTO AN ATTESTATION PAYLOAD. ***

    *An attestation is the FROZEN historical artifact: every path it names must still resolve for a reader who checks
    out the candidate. A `build/`/`.gradle/`/`DerivedData/`/`.build/` component or a `/tmp`-shaped scratch path in
    its payload is a path that will be regenerated or discarded -- so it is refused by name, whichever field carrieth
    it.*
    """
    if not isinstance(att, dict):
        return ["the attestation payload is not a JSON object -- nothing can be verified about its paths"]
    problems: list[str] = []
    for pointer, value in _walk_strings(att):
        if _looks_like_path(value):
            problems.extend(forbidden_path_problems(value, label=f"attestation{pointer}"))
    return problems


def _walk_strings(obj, pointer: str = ""):
    if isinstance(obj, dict):
        for key, value in obj.items():
            yield from _walk_strings(value, f"{pointer}/{key}")
    elif isinstance(obj, list):
        for i, value in enumerate(obj):
            yield from _walk_strings(value, f"{pointer}[{i}]")
    elif isinstance(obj, str):
        yield pointer, obj


def _looks_like_path(value: str) -> bool:
    if not value or len(value) > 400:
        return False
    if value.startswith("http://") or value.startswith("https://"):
        return False
    return value.startswith("/") or "/" in value or "\\" in value


def future_attestation_path_problems(declared: str | None) -> list[str]:
    """*** THE FREEZE'S OWN PATH POLICY, REUSED -- NEVER RE-IMPLEMENTED. ***

    *The ONE lawful future-attestation path is adjudicated by `ci/check_candidate_binding.attest_exclusion_policy`; a
    declared path that is not exactly that literal -- a `build/` path, a temp path, a prefix, a glob, rc14 or an
    absolute path -- is refused BY THE AUTHORITY ITSELF, so this road cannot drift from it.* **Its one CONTEXT
    requirement (that a no-candidate/no-successor call near an EXISTING attestation is a successor state) is dropped
    here, because this road judges PATH SHAPE, not the successor relation; the authority literal is always shape-valid,
    and every path is additionally scanned for build/temp components BY NAME.**
    """
    if not declared:
        return ["no future-attestation path was declared -- *a freeze writeth exactly one attestation, and a payload "
                "that does not name it is not a freeze payload*"]
    ccb = _ccb()
    problems = [p for p in ccb.attest_exclusion_policy(future_path=declared)
                if "was called with NO candidate/successor" not in p]
    problems.extend(forbidden_path_problems(declared, label="post_tag_attestation"))
    return problems


# ---------------------------------------------------------------------------------------------------------------
# the integration point: real manifest validation + the real freeze path policy
# ---------------------------------------------------------------------------------------------------------------
def _load_json(path: Path) -> tuple[dict | None, list[str]]:
    if not path.is_file():
        return None, [f"no document at {path} -- an absent payload cannot be verified"]
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        return None, [f"the document at {path} is not valid JSON: {exc}"]
    if not isinstance(doc, dict):
        return None, [f"the document at {path} is not a JSON object"]
    return doc, []


def _default_rebind(*, artifacts: Path | None, campaign_dir: Path | None, evidence_root: Path | None,
                    proof_dir: Path | None) -> dict:
    """*** THE READER-SIDE ROOTS, ASSEMBLED BY THE FREEZE'S OWN HELPER. ***

    *`tools/readiness/board1.py:_freeze_rebind` is the ONE place that maps the four classes to roots; this road USES
    it so the gates/campaign/evidence/proof mapping can never drift from the freeze's own.*
    """
    if str(ROOT / "tools" / "readiness") not in sys.path:
        sys.path.insert(0, str(ROOT / "tools" / "readiness"))
    import board1  # noqa: PLC0415
    return board1._freeze_rebind(artifact_dir=artifacts, campaign_dir=campaign_dir,
                                 evidence_root=evidence_root, proof_dir=proof_dir) or {}


def verify_freeze_candidate_paths(*, manifest: Path | str | None = None, attestation: Path | str | None = None,
                                  base: Path = ROOT, evidence_root: Path | None = None,
                                  rebind: dict | None = None, artifacts: Path | None = None,
                                  campaign_dir: Path | None = None, proof_dir: Path | None = None,
                                  require_exists: bool = True,
                                  consumer_checks: bool = True) -> list[str]:
    """*** THE ONE ENTRY POINT: MANIFEST-DRIVEN TRAVERSAL + THE FREEZE'S REAL PATH CHECKS. EMPTY = VERIFIED. ***

    *THE THREE OBLIGATIONS, EACH NAMED:*
      1. **every frozen candidate artifact path RESOLVES** -- each manifest record is resolved with the repository's
         utilities, and a path this host cannot resolve (an unresolved token, a `..` escape, an absolute
         repository-relative record) is a refusal;
      2. **no temporary/build-dir path LEAKS into an attestation payload** -- the declared future-attestation path is
         judged by the binding authority's own policy, and every path-shaped field of the attestation document is
         scanned for build/temp components;
      3. **every path SURVIVES the freeze** -- each resolved record that binds bytes must still `exist()`, so a missing
         file is a refusal rather than a green on a string.

    *** AND THE CONSUMER CHECK IS THE REAL ONE. *** *When `consumer_checks` is set the manifest is handed to
    `ci/check_board1_manifest.check_manifest` -- the exact validator the freeze itself runs -- so a path the freeze
    would refuse reddens this road too, rather than this road passing a manifest the freeze then rejects.*
    """
    base = Path(base)
    problems: list[str] = []
    if rebind is None:
        try:
            rebind = _default_rebind(artifacts=artifacts, campaign_dir=campaign_dir,
                                     evidence_root=evidence_root, proof_dir=proof_dir)
        except Exception as exc:  # noqa: BLE001 - an unassemblable rebind is a named refusal
            problems.append(f"the reader-side rebind roots could not be assembled: {type(exc).__name__}: {exc}")
            rebind = {}
    if evidence_root is not None:
        rebind = {**rebind, "evidence": Path(evidence_root)}

    if manifest is None:
        return ["no manifest named -- *the manifest is the authority that lists the bound candidate's paths, and "
                "there is no default: a verifier with nothing to traverse verifies nothing*"]
    manifest_path = Path(manifest)
    if not manifest_path.is_absolute():
        manifest_path = base / manifest_path
    doc, load_problems = _load_json(manifest_path)
    problems.extend(load_problems)
    if doc is None:
        return problems

    # (1)+(3) traverse and resolve every recorded path, requiring it to survive.
    problems.extend(manifest_path_problems(doc, base=base, evidence_root=evidence_root, rebind=rebind,
                                           require_exists=require_exists))

    # (2) the ONE lawful future-attestation path, from the binding authority's own literal.
    problems.extend(future_attestation_path_problems(_ccb().FREEZE_ATTESTATION_SUCCESSOR_PATH))

    # (2, continued) the attestation document itself, when supplied: its payload must leak no build/temp path, and any
    # future-attestation path it declares is judged by the same authority.
    if attestation is not None:
        att_path = Path(attestation)
        if not att_path.is_absolute():
            att_path = base / att_path
        att, att_problems = _load_json(att_path)
        problems.extend(att_problems)
        if att is not None:
            problems.extend(attestation_path_problems(att))
            declared = att.get("post_tag_attestation")
            if declared:
                problems.extend(future_attestation_path_problems(declared))

    # (integration) the freeze's REAL manifest validator, so a path the freeze would refuse reddens here too.
    if consumer_checks:
        try:
            cbm = _cbm()
            problems.extend(cbm.check_manifest(doc, base=base, evidence_root=evidence_root, rebind=rebind or None))
        except Exception as exc:  # noqa: BLE001 - an un-runnable consumer is a named refusal, never a silent skip
            problems.append(f"the manifest consumer `check_manifest` could not be run: {type(exc).__name__}: {exc}")
    return problems


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--manifest", required=True, help="the candidate-bound gate manifest to verify")
    parser.add_argument("--attestation", default=None, help="the freeze attestation whose payload must leak nothing")
    parser.add_argument("--base", default=str(ROOT), help="the repository root the manifest is read against")
    parser.add_argument("--evidence-root", default=None, help="the downloaded lane-evidence root")
    parser.add_argument("--artifacts", "--artifact-dir", dest="artifacts", default=None,
                        help="the gate-log root (the runner may name this its artifact/temp root)")
    parser.add_argument("--campaign-dir", default=None, help="the campaign tree root")
    parser.add_argument("--proof-dir", default=None, help="the release-proof records root")
    parser.add_argument("--no-require-exists", action="store_true",
                        help="resolve paths without requiring their bytes to be present (diagnosis only)")
    parser.add_argument("--no-consumer-checks", action="store_true",
                        help="skip the real `check_manifest` consumer check (diagnosis only)")
    parser.add_argument("--json", action="store_true", help="emit the problems as JSON")
    args = parser.parse_args(argv)

    problems = verify_freeze_candidate_paths(
        manifest=Path(args.manifest), attestation=Path(args.attestation) if args.attestation else None,
        base=Path(args.base),
        evidence_root=Path(args.evidence_root) if args.evidence_root else None,
        artifacts=Path(args.artifacts) if args.artifacts else None,
        campaign_dir=Path(args.campaign_dir) if args.campaign_dir else None,
        proof_dir=Path(args.proof_dir) if args.proof_dir else None,
        require_exists=not args.no_require_exists,
        consumer_checks=not args.no_consumer_checks)
    if args.json:
        print(json.dumps({"ok": not problems, "problems": problems}, indent=1))
    else:
        for problem in problems:
            print(f"::error::{problem}", file=sys.stderr)
        if not problems:
            print(f"freeze candidate paths: VERIFIED ({args.manifest})")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
