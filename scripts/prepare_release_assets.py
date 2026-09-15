#!/usr/bin/env python3
"""Verify and stage exactly one LIGHT release asset set.

The command never downloads assets. It rejects examples, missing hashes,
cross-tier names, unexpected files, and archives without a trusted signed
manifest. The verified archive replaces the previous file atomically; the
approved-resource manifest is published only after a successful staging, so
a consumer can never observe a manifest that promises bytes which were not
sworn in. The release owner must select --trust-store separately; the
untrusted asset manifest is never allowed to choose its own signing
authority. T52 restored the pre-T51 VERIFICATION-ONLY deputy face (under
the T39 back-compatibility precedent, for the sealed T45/T46 courts whose
fixtures recordeth the pointer fields by their own cards' law): omitting
--trust-store on --check-only runneth that old route, which readeth the
document's own archive_manifest/archive_trust_store pointers and bindeth
the SAME verifier (load_trust_store + verify_manifest, tier LIGHT, schema
3) with no relaxation. Staging and publication remain operator-selected
only: no deputy path may ever write an output directory.

T51 (s17): '... an approved-resource manifest only after successful
staging' and 'Never solve missing production content by copying a fixture
into Approved'. The publication order below is the law of this file:
validate -> stage -> re-verify -> replace archive -> publish manifest.
Every refusal precedes every write; no failing path toucheth the
authoritative output.

T66: the held-out evaluation rides the same publication order. When the
release owner supplieth --heldout-evaluation (a record published by
content.eval.heldout), the archive now being staged must BE the corpus that
evaluation was run against, the model lock it bound must still stand as it
stood, the ledger must be COMPLETE, and no case may have been allowed that
the manifest requires refused. The verified summary is published inside
APPROVED_ASSETS.json, so a consumer of the staged bytes can see which
evaluation those bytes carry. The gate never demanded an evaluation by
itself -- that is the release owner's call through
--require-heldout-evaluation -- because the held-out manifest and the
clinical review behind it are external artifacts this repository cannot
manufacture.

T77: the update is TRANSACTIONAL and the last-approved bytes remain
available under an explicit policy. When the release owner supplieth
--retain-previous (a retention directory OUTSIDE the estate), the previous
authoritative pair -- the archive and its published APPROVED_ASSETS.json --
is copied and fsynced into that directory, together with a RETENTION.json
record naming both digests, BEFORE either file of the pair is replaced. A
half pair (one file present without the other) is refused by name rather
than retained as if it had been sworn, and no retention directory may live
inside the estate it retaineth. The default (no --retain-previous) is
byte-for-byte the old behavior: the sealed courts and their fixtures are
untouched. The publication boundaries -- validated, retained,
before_archive_replace, after_archive_replace, before_manifest_publish,
published -- may be observed (and, by a caller that is PROVING recovery,
interrupted) through the PublishHooks seam. The default hook speaketh not.
The recovery authority that consumes this seam and the compatibility matrix
that decideth which schema may replace which is
scripts/upgrade_recovery.py; the policy of what may be rolled back is NOT
decided here.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any, Mapping

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from content.archive_manifest import (
    ArchiveManifestError, load_trust_store, strict_json_loads,
    verify_manifest)

# LIGHT shipeth exactly one archive under exactly one role; the model
# assets are not intake at this gate (the NATIVE_MODELS gate keepeth its
# own counsel elsewhere).
ROLE_NAMES = {"archive": "archive_light.db"}
ALLOWED_NAMES = set(ROLE_NAMES.values())
ALLOWED_ROLES = set(ROLE_NAMES)
APPROVED_MANIFEST_NAME = "APPROVED_ASSETS.json"
APPROVED_MANIFEST_SCHEMA = 1
SHA256_RE = re.compile(r"[0-9a-f]{64}")

# T77: the retention record and the publication boundaries. The retention
# directory holdeth the previous authoritative PAIR (the archive and the
# published manifest that named it) plus one record swearing both digests.
RETENTION_RECORD_NAME = "RETENTION.json"
RETENTION_SCHEMA = 1

# The publication boundaries, in the order the transaction reacheth them. A
# caller proving recovery interrupteth at one of these NAMES; nothing else is
# a boundary, and a name outside this tuple is a caller's fault.
PUBLISH_BOUNDARIES = (
    "validated",
    "retained",
    "before_archive_replace",
    "after_archive_replace",
    "before_manifest_publish",
    "published",
)


class PublishHooks:
    """The observation seam over one publication (T77).

    The default instance speaketh not and raiseth never: a caller that
    merely wanteth the old behavior passeth nothing at all. A prover of
    recovery passeth a subclass whose ``at`` raiseth at the named boundary,
    or a callable, and the transaction is then observed to leave the
    previous authoritative estate whole.
    """

    def at(self, boundary: str) -> None:  # pragma: no cover -- the default is a no-op
        return None


def _boundary(hooks: "PublishHooks | None", boundary: str) -> None:
    if boundary not in PUBLISH_BOUNDARIES:
        raise ValueError(f"unknown publication boundary: {boundary}")
    if hooks is not None:
        hooks.at(boundary)


def _swear(path: Path) -> dict[str, Any]:
    """One file's immutable identity as the retention record telleth it."""
    return {"name": path.name, "bytes": path.stat().st_size, "sha256": sha256(path)}


def _retain_previous_estate(output: Path, retention: Path, name: str) -> dict[str, Any] | None:
    """Copy the previous authoritative pair into ``retention`` before it is
    replaced, and swear it (T77).

    Returneth the record that was published, or None when no estate standeth
    yet (a fresh install retaineth nothing, and a first install is never
    called an update). A HALF pair -- one of the two files present without
    the other -- is refused by name: it is a wipe in progress or a broken
    estate, and neither may be retained as though it had been whole. The
    previous pair is copied whole and fsynced, then the record is published
    last, so a retention directory that carrieth a record carrieth sworn
    bytes behind it.
    """
    archive = output / name
    manifest = output / APPROVED_MANIFEST_NAME
    present = (archive.is_file(), manifest.is_file())
    if present == (False, False):
        return None
    if present != (True, True):
        absent = APPROVED_MANIFEST_NAME if present[0] else name
        raise ValueError(
            "the previous estate is incomplete: " + absent + " is missing beside " +
            "its pair; a half pair is never retained as though it had been sworn")
    if retention.resolve() == output.resolve() or retention.resolve().is_relative_to(output.resolve()):
        raise ValueError("the retention directory must not live inside the estate it retaineth")
    retention.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=".godstone-retain-", dir=retention.parent
                                 if retention.parent.is_dir() else retention))
    try:
        for source in (archive, manifest):
            copied = work / source.name
            shutil.copyfile(source, copied)
            with copied.open("rb") as stream:
                os.fsync(stream.fileno())
            os.replace(copied, retention / source.name)
        record = {
            "schema": RETENTION_SCHEMA,
            "reason": "the previous authoritative estate, retained before replacement",
            "archive": _swear(retention / name),
            "approved_manifest": _swear(retention / APPROVED_MANIFEST_NAME),
        }
        record_path = work / RETENTION_RECORD_NAME
        record_path.write_text(
            json.dumps(record, sort_keys=True, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8")
        with record_path.open("rb") as stream:
            os.fsync(stream.fileno())
        os.replace(record_path, retention / RETENTION_RECORD_NAME)
        return record
    finally:
        shutil.rmtree(work, ignore_errors=True)

# The archive's own meta must carry these production review digests, and
# the signed manifest must swear the same values: a development fixture
# signed by a real key still lacks them and is refused.
#: GS-CONTENT-001: the production review provenance a RELEASE archive must carry. The
#: final chunk approvals are included, because an archive whose chunks were never approved
#: is precisely what staged a release the audit reproduced: "an archive lacks production
#: review provenance: approvals_sha256".
PROVENANCE_FIELDS = (
    ("source_manifest_sha256", "source_manifest_sha256"),
    ("review_manifest_sha256", "review_manifest_sha256"),
    ("release_manifest_set_sha256", "corpus_manifest_sha256"),
    ("approvals_sha256", "approvals_sha256"),
)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def local_file(root: Path, value: Any, field: str) -> Path:
    """A relative, non-NUL, non-absolute name resolving inside root."""
    if not isinstance(value, str) or not value.strip() or "\0" in value:
        raise ValueError(f"{field} must be a relative file path")
    if Path(value).is_absolute():
        raise ValueError(f"{field} must be a relative file path")
    path = (root / value).resolve()
    if not path.is_relative_to(root):
        raise ValueError(f"{field} escapes manifest directory")
    if not path.is_file():
        raise ValueError(f"{field} is missing: {value}")
    return path


def _approved_manifest_document(staged: Mapping[str, Any],
                                evaluation: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """The approved-resource manifest's own bytes: deterministic (no
    timestamps, sorted keys, fixed fields), so a rendered project refereth
    to the very same document twice and readeth the same. The evaluation
    block, when the release owner furnished one, is transcribed from the
    record rather than from the clock."""
    asset = staged["assets"][0]
    document = {
        "schema": APPROVED_MANIFEST_SCHEMA,
        "tier": staged["tier"],
        "application_id": staged["application_id"],
        "generated_by": "scripts/prepare_release_assets.py",
        "assets": [{
            "role": asset["role"],
            "name": asset["name"],
            "sha256": asset["sha256"],
            "bytes": asset["bytes"],
            "build_phase": "resources",
        }],
    }
    if evaluation is not None:
        document["evaluation"] = dict(evaluation)
    return document


EVALUATION_BLOCK_SCHEMA = 1


def _heldout_evaluation(evaluation_path: Path, *,
                        heldout_manifest_path: Path | None,
                        model_lock_path: Path | None,
                        expected_corpus_sha256: str) -> tuple[list[str], dict[str, Any] | None]:
    """Verify a held-out evaluation record against the archive being staged.

    The import is deliberately lazy: a staging run that carrieth no
    evaluation neither loads nor depends on the evaluation package."""
    from content.eval import heldout as heldout_eval
    try:
        record = heldout_eval.load_record(Path(evaluation_path))
        manifest = (heldout_eval.load_manifest(Path(heldout_manifest_path))
                    if heldout_manifest_path is not None else None)
        errors, summary = heldout_eval.verify_record(
            record, manifest=manifest, expected_corpus_sha256=expected_corpus_sha256,
            model_lock_path=Path(model_lock_path) if model_lock_path is not None else None)
    except heldout_eval.HeldOutError as exc:
        return [f"held-out evaluation rejected: {exc}"], None
    except (OSError, ValueError) as exc:
        return [f"held-out evaluation unreadable: {exc}"], None
    if errors:
        return [f"held-out evaluation rejected: {item}" for item in errors], None
    summary = dict(summary)
    summary["schema"] = EVALUATION_BLOCK_SCHEMA
    summary["record_sha256"] = hashlib.sha256(
        Path(evaluation_path).read_bytes()).hexdigest()
    summary["record_path"] = Path(evaluation_path).name
    return [], summary


def _validate_operator_selected(manifest_path: Path, *, trust_store_path: Path,
                                heldout_evaluation: Path | None = None,
                                heldout_manifest: Path | None = None,
                                model_lock_path: Path | None = None,
                                require_heldout_evaluation: bool = False,
                                ) -> tuple[dict[str, Any], list[tuple[Path, str]]]:
    root = manifest_path.resolve().parent
    try:
        data = strict_json_loads(manifest_path.read_text(encoding="utf-8"),
                                  str(manifest_path))
    except ArchiveManifestError as exc:
        raise ValueError(str(exc)) from exc
    if not isinstance(data, Mapping):
        raise ValueError("asset manifest root must be an object")
    errors: list[str] = []
    if type(data.get("schema")) is not int or data.get("schema") != 1:
        errors.append("schema must be 1")
    if data.get("tier") != "LIGHT":
        errors.append("only LIGHT is an approved initial tier")
    if data.get("application_id") != "io.godstone.app":
        errors.append("application identity mismatch")
    if data.get("status") != "approved" or data.get("production_ready") is not True:
        errors.append("asset manifest is not approved for production")
    # The trust is the operator's to select, never the bundle's to name.
    if "archive_trust_store" in data:
        errors.append("the trust store is selected by the operator, never by the manifest")
    assets = data.get("assets")
    if not isinstance(assets, list):
        errors.append("assets must be an array"); assets = []
    staged: list[tuple[Path, str]] = []
    roles: set[str] = set()
    names: set[str] = set()
    sources_seen: set[Path] = set()
    archive_path: Path | None = None
    for index, item in enumerate(assets):
        if not isinstance(item, Mapping):
            errors.append(f"assets[{index}] is not an object"); continue
        role, name = str(item.get("role", "")), str(item.get("name", ""))
        if role not in ALLOWED_ROLES: errors.append(f"assets[{index}].role is invalid")
        if ROLE_NAMES.get(role) != name:
            errors.append(f"assets[{index}] role/name mismatch; LIGHT ships only archive_light.db")
        if role in roles: errors.append(f"duplicate asset role: {role}")
        roles.add(role)
        if name not in ALLOWED_NAMES: errors.append(f"assets[{index}].name is invalid or cross-tier")
        if name in names: errors.append(f"duplicate asset name: {name}")
        names.add(name)
        try:
            source = local_file(root, item.get("source"), f"assets[{index}].source")
        except ValueError as exc:
            errors.append(str(exc)); continue
        if source in sources_seen:
            errors.append(f"duplicate asset source: assets[{index}].source"); continue
        sources_seen.add(source)
        if type(item.get("bytes")) is not int or item.get("bytes") != source.stat().st_size:
            errors.append(f"size mismatch: {name}")
        expected = str(item.get("sha256", ""))
        if not SHA256_RE.fullmatch(expected) or sha256(source) != expected:
            errors.append(f"SHA-256 mismatch: {name}")
        staged.append((source, name))
        if role == "archive": archive_path = source
    if roles != {"archive"} or len(assets) != 1:
        errors.append("exactly one Archive and no other assets are permitted")
    if archive_path is not None:
        manifest_ref = data.get("archive_manifest")
        if not manifest_ref:
            errors.append("signed archive manifest is required")
        else:
            try:
                signed_path = local_file(root, manifest_ref, "archive_manifest")
            except ValueError as exc:
                errors.append(str(exc)); signed_path = None
            if signed_path is not None:
                try:
                    result = verify_manifest(
                        signed_path, archive_path, load_trust_store(trust_store_path),
                        expected_tier="LIGHT", expected_archive_schema=3,
                    )
                    errors.extend(result.errors)
                    if result.ok:
                        signed = result.manifest
                        if signed is None:
                            errors.append("verified manifest document is missing from the verdict")
                        else:
                            # Only --release builds contain these validation
                            # digests. Signing an example archive cannot
                            # substitute for running the source, rights,
                            # clinical and chunk approval gate.
                            meta = signed.get("archive_meta")
                            if not isinstance(meta, Mapping):
                                errors.append("signed manifest carries no archive metadata to cross-check")
                            else:
                                for field, signed_field in PROVENANCE_FIELDS:
                                    value = meta.get(field)
                                    if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
                                        errors.append(f"archive lacks production review provenance: {field}")
                                    elif signed.get(signed_field) != value:
                                        errors.append(f"signed production provenance mismatch: {field}")
                except (ArchiveManifestError, OSError, ValueError) as exc:
                    errors.append(str(exc))
    # T66: the held-out evaluation of the very bytes being staged. Checked
    # only once the artifact itself standeth sound, so the operator readeth
    # the primary fault first rather than a cascade.
    summary: dict[str, Any] | None = None
    if not errors:
        if require_heldout_evaluation and heldout_evaluation is None:
            errors.append("the release owner requireth a held-out evaluation and none "
                          "was furnished (--heldout-evaluation)")
        elif heldout_evaluation is not None:
            if archive_path is None:
                errors.append("a held-out evaluation requireth the Archive it was run "
                              "against")
            else:
                problems, summary = _heldout_evaluation(
                    heldout_evaluation, heldout_manifest_path=heldout_manifest,
                    model_lock_path=model_lock_path,
                    expected_corpus_sha256=sha256(archive_path))
                errors.extend(problems)
    if errors:
        raise ValueError("release assets rejected:\n- " + "\n- ".join(errors))
    document = dict(data)
    if summary is not None:
        document["_heldout_evaluation"] = summary
    return document, staged


DEPUTY_ALLOWED_NAMES = {"archive_light.db", "generation.gguf", "embedding.gguf"}
DEPUTY_ALLOWED_ROLES = {"archive", "generation_model", "embedding_model"}


def validate(manifest_path: Path, *, trust_store_path: Path | None = None,
             heldout_evaluation: Path | None = None,
             heldout_manifest: Path | None = None,
             model_lock_path: Path | None = None,
             require_heldout_evaluation: bool = False,
             ) -> tuple[dict[str, Any], list[tuple[Path, str]]]:
    """Two lawful faces of one gate (T52, under the T39 back-compatibility
    precedent). The operator standing present selecteth the trust store
    explicitly -- the T51 law, arm unchanged byte for byte. Absent the
    operator, the legacy deputy face of the pre-T51 era readeth the
    document's own pointers and bindeth the same verifier. The deputy
    faceth never publish'th, so a held-out evaluation -- which existeth to
    be published beside staged bytes -- is refused there by name."""
    if trust_store_path is None:
        # GS-CONTENT-003: THE DEPUTY FACE IS GONE. It read the trust store FROM THE BUNDLE,
        # which meant a bundle could nominate the very key that signed it -- the audit
        # reproduced that `prep.validate(bundle)` returned successfully for a bundle naming
        # `attacker-trust.json` signed by `ATTACKER-NOT-OPERATOR`. The T51 law is now
        # unconditional on EVERY path, including --check-only: the trust store is selected
        # by the operator, never by the manifest it is used to judge.
        raise ValueError(
            "the trust store is selected by the operator, never by the manifest: pass "
            "--trust-store <operator trust store>; a bundle may not nominate the key that "
            "signeth it (the default release-validation path refuseth this by name)")
    # GS-CONTENT-003 (AUDIT-004 step 2): THE OBSOLETE HELD-OUT REFUSAL STOOD HERE. It was
    # written for the LEGACY DEPUTY BRANCH, where no operator trust store existed at all --
    # but it ran AFTER the trust-store law above, so once an operator trust store WAS supplied
    # every supplied held-out evaluation was refused BEFORE `_validate_operator_selected` (the
    # verifier that accepts it) was ever called. The independent review reproduced the
    # REGRESSION against the prior baseline: it passed at c683a2bf and failed on the repaired
    # source. The refusal is REMOVED, not weakened -- the operator-selected face forwardeth the
    # held-out arguments DIRECTLY to the lower verifier, which is left to enforce every
    # missing, incomplete, mismatched or tampered evaluation requirement itself.
    return _validate_operator_selected(
        manifest_path, trust_store_path=trust_store_path,
        heldout_evaluation=heldout_evaluation, heldout_manifest=heldout_manifest,
        model_lock_path=model_lock_path,
        require_heldout_evaluation=require_heldout_evaluation)


def publish_verified(name: str, source: Path, *, output: Path,
                     expected_hash: str, expected_bytes: int,
                     approved_document: Mapping[str, Any],
                     retention: Path | None = None,
                     hooks: "PublishHooks | None" = None) -> None:
    """The publication transaction, and its ONLY owner (T77 split it out of
    ``stage`` so that the recovery authority can drive the very same order).

    A caller must have verified ``source`` already -- this function re-verifieth
    the copy it made, but it decideth nothing about approval. ``stage`` calleth
    it only after the release asset gate accepted the bundle; the rehearsal
    face of scripts/upgrade_recovery.py calleth it only after the same verifier
    primitives accepted a labelled development candidate, and it is the
    CALLER that must label what it published.

    The order is unchanged and remains the law: validate (by the caller) ->
    retain the previous authoritative pair -> copy and RE-verify -> replace the
    archive -> publish the manifest. Every refusal precedeth every write.
    """
    output = Path(output)
    target = output / name
    # T77: the previous pair is sworn into the retention directory BEFORE
    # either file of it is replaced, so a refusal or an interruption always
    # leaveth a rollback target behind.
    _boundary(hooks, "validated")
    if retention is not None:
        _retain_previous_estate(output, retention, name)
    _boundary(hooks, "retained")
    # The archive is replaced in place (never deleted-then-copied: no gap in
    # which a build could observe an Approved dir without its bytes), and the
    # approved-resource manifest is published only after the archive, the
    # copy re-verified, and the replacement sworn.
    with tempfile.TemporaryDirectory(prefix=".godstone-assets-", dir=output.parent) as work:
        candidate = Path(work) / name
        shutil.copyfile(source, candidate)
        if candidate.stat().st_size != expected_bytes or sha256(candidate) != expected_hash:
            raise ValueError("archive changed during staging")
        with candidate.open("rb") as stream:
            os.fsync(stream.fileno())
        _boundary(hooks, "before_archive_replace")
        os.replace(candidate, target)
        _boundary(hooks, "after_archive_replace")
        # The archive is in place and true; now publish its manifest, and
        # only now. A consumer that findeth the manifest findeth verified
        # bytes behind it; a failed publish leaveth the old pair as it was.
        manifest_candidate = Path(work) / APPROVED_MANIFEST_NAME
        manifest_candidate.write_text(
            json.dumps(approved_document, sort_keys=True, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8")
        with manifest_candidate.open("rb") as stream:
            os.fsync(stream.fileno())
        _boundary(hooks, "before_manifest_publish")
        os.replace(manifest_candidate, output / APPROVED_MANIFEST_NAME)
        _boundary(hooks, "published")


def stage(manifest_path: Path, output: Path, *, trust_store_path: Path,
          heldout_evaluation: Path | None = None,
          heldout_manifest: Path | None = None,
          model_lock_path: Path | None = None,
          require_heldout_evaluation: bool = False,
          retention: Path | None = None,
          hooks: "PublishHooks | None" = None) -> None:
    data, assets = validate(manifest_path, trust_store_path=trust_store_path,
                            heldout_evaluation=heldout_evaluation,
                            heldout_manifest=heldout_manifest,
                            model_lock_path=model_lock_path,
                            require_heldout_evaluation=require_heldout_evaluation)
    evaluation = data.pop("_heldout_evaluation", None)
    root = manifest_path.resolve().parent
    # An output that contains its own inputs could overwrite approved source
    # files or their evidence. Symlinks are not output directories or files.
    if output.is_symlink():
        raise ValueError("output directory must not be a symlink")
    output = output.absolute()
    output = output.resolve()
    if root.is_relative_to(output):
        raise ValueError("output directory must not contain the input manifest")
    source, name = assets[0]
    target = output / name
    if target.resolve() == source:
        raise ValueError("output archive must not overwrite its source")
    if target.resolve() == trust_store_path.resolve():
        raise ValueError("output archive must not overwrite the trust store")
    output.mkdir(parents=True, exist_ok=True)
    entries = list(output.iterdir())
    if any(entry.name not in {name, APPROVED_MANIFEST_NAME} or entry.is_symlink() or not entry.is_file()
           for entry in entries):
        raise ValueError("output directory contains unexpected entries; use a dedicated Archive asset directory")
    publish_verified(name, source, output=output,
                     expected_hash=data["assets"][0]["sha256"],
                     expected_bytes=data["assets"][0]["bytes"],
                     approved_document=_approved_manifest_document(data, evaluation),
                     retention=retention, hooks=hooks)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--trust-store", type=Path, default=None,
                        help="release-owner-selected Ed25519 trust store (independent of the asset "
                             "manifest); required for staging, omitted on --check-only the legacy "
                             "deputy face readeth the document's own pointers")
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--heldout-evaluation", type=Path, default=None,
                        help="the held-out evaluation record (content.eval.heldout) "
                             "that was run against this very Archive; it must be "
                             "COMPLETE, bound to the same corpus and model lock, and "
                             "free of false allows, or staging is refused")
    parser.add_argument("--heldout-manifest", type=Path, default=None,
                        help="the held-out manifest the record answers, for the full "
                             "case-by-case cross-check")
    parser.add_argument("--model-lock", type=Path, default=None,
                        help="the model lock the evaluation bound (defaults to "
                             "docs/packaging/MODELS.lock.json)")
    parser.add_argument("--require-heldout-evaluation", action="store_true",
                        help="refuse to stage when no held-out evaluation is furnished")
    parser.add_argument("--retain-previous", type=Path, default=None,
                        help="T77: a directory OUTSIDE the estate into which the previous "
                             "authoritative pair and a RETENTION.json record are sworn before "
                             "either file is replaced; the last-approved bytes stay available "
                             "under the operator's policy, and a half pair is refused")
    args = parser.parse_args()
    if not args.check_only and args.trust_store is None:
        parser.error("staging requireth the operator-selected --trust-store")
    if args.heldout_evaluation is not None and args.model_lock is None:
        args.model_lock = REPOSITORY_ROOT / "docs" / "packaging" / "MODELS.lock.json"
    try:
        options = {
            "heldout_evaluation": args.heldout_evaluation,
            "heldout_manifest": args.heldout_manifest,
            "model_lock_path": args.model_lock,
            "require_heldout_evaluation": args.require_heldout_evaluation,
        }
        if args.check_only:
            if args.trust_store is not None:
                validate(args.manifest, trust_store_path=args.trust_store, **options)
            else:
                validate(args.manifest, **options)
        else:
            stage(args.manifest, args.out, trust_store_path=args.trust_store,
                  retention=args.retain_previous, **options)
    except (ArchiveManifestError, OSError, ValueError) as exc:
        print(exc)
        return 1
    print("release assets verified" if args.check_only else "staged 1 verified archive and published its approved-resource manifest")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
