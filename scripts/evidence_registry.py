"""Enumerate source evidence references without absorbing workstation-owned archives.

Every reference is one row with one namespace and one disposition. Counts are computed from those rows, never from a
stored counter. Repository-owned bytes are claimed only through the Git index or the immutable anchor commit.
External references are re-derived from a tracked, content-addressed proof archive
(evidence/external-registry-proof/<sha256>.gz), so the same dispositions hold in a clean clone wherever it runs. The
builder evidence root the record declares (evidence_root) is validated as an identity but never read by the consumer;
it is never required, never an input to an internal gate, and the protected user archives are never opened.
"""
from __future__ import annotations

import gzip
import hashlib
import json
import re
import subprocess
import zlib
from pathlib import Path

DISPOSITIONS = ("examined", "unresolved", "unnamed", "declared_lost", "undigested")
PROTECTED_ROOTS = ("AUDIT_FINAL_2026-09-15", "GODSTONE_BLUEPRINT_HANDOFF", "godstone-audit")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")

# The clone-carried proof archive: external evidence made re-derivable in a clean clone.
#
# Each registered external reference's original bytes are stored gzip-compressed as
# evidence/external-registry-proof/<registered-sha256>.gz. The file name is the digest the bytes must hash to, so a
# tampered, missing, untracked or symlinked entry is a named refusal rather than a declared pass. The archive is the
# only authority the consumer re-derives external proof from; the builder root is never read by classify().
CLONE_PROOF_DIRNAME = "evidence/external-registry-proof"
# Archive entry extension. The stored bytes are logs and reports, not necessarily JSON, so the suffix is plain .gz;
# the file name (the registered SHA-256) is the whole content-addressing contract.
ARCHIVE_SUFFIX = ".gz"


def _archive_entry(root: Path, expected_sha: str, tracked: set[str]) -> Path | None:
    """Return the archive entry for a registered SHA-256, or None when it is not a lawful clone-carried proof.

    The entry `<registered-sha256>.gz` must be named by exactly that digest and be a tracked, regular, non-symlink
    file whose every path component under the repository is a real directory. A symlinked leaf, a symlinked archive
    directory, an untracked entry, or a path that resolves outside the repository is refused; None then makes the
    reference re-derive unresolved.
    """
    if not isinstance(expected_sha, str) or not DIGEST.fullmatch(expected_sha):
        return None
    rel = f"{CLONE_PROOF_DIRNAME}/{expected_sha}{ARCHIVE_SUFFIX}"
    if rel not in tracked:
        return None
    entry = root / rel
    # No path component -- leaf or ancestor -- may be a symlink, and the resolved leaf must stay inside the resolved
    # repository root. lstat (is_symlink) does not follow links, so a symlinked parent cannot smuggle a target in.
    try:
        for parent in entry.parents:
            if parent == root.parent:
                break
            if parent.is_symlink():
                return None
        if entry.is_symlink() or not entry.is_file():
            return None
        resolved = entry.resolve()
        resolve_root = root.resolve()
        if resolved != resolve_root and resolve_root not in resolved.parents:
            return None
    except OSError:
        return None
    return entry


def _clone_carried_bytes(root: Path, expected_sha: str, tracked: set[str]) -> bytes | None:
    """Return one registered reference's bytes from the tracked content-addressed archive, or None.

    The entry must decompress to bytes whose SHA-256 equals its name. A missing, untracked, symlinked, unreadable or
    tampered entry returns None, so the reference re-derives unresolved rather than passing.
    """
    entry = _archive_entry(root, expected_sha, tracked)
    if entry is None:
        return None
    try:
        raw = gzip.decompress(entry.read_bytes())
    except (OSError, EOFError, gzip.BadGzipFile, zlib.error):
        return None
    if hashlib.sha256(raw).hexdigest() != expected_sha:
        return None
    return raw


def declared_root_declaration(document: dict, root: Path):
    """Validate the root the record declares (an identity), without requiring it to exist or reading it.

    Presence on the current host is not a property of the candidate: external proof is re-derived from the tracked
    archive, so the document re-derives identically wherever it runs. The declared path must be absolute, outside the
    repository, and not a protected user archive; a malformed declaration returns None plus a named reason rather
    than a value the archive can hide behind.
    """
    declared = document.get("evidence_root")
    if not isinstance(declared, str) or not declared.strip():
        return None, "the record declares no evidence_root"
    candidate = Path(declared)
    if not candidate.is_absolute():
        return None, f"the declared evidence_root {declared!r} is not absolute"
    try:
        resolved = candidate.resolve()
    except OSError:
        resolved = candidate
    root_resolved = root.resolve()
    if resolved == root_resolved or root_resolved in resolved.parents:
        return None, ("the declared root lies inside the repository; repository bytes are claimed "
                      "through the Git index and the anchor commit only")
    for name in PROTECTED_ROOTS:
        if name in resolved.parts:
            return None, f"the declared root names the protected user archive {name!r}: never opened"
    return candidate, None


class RegistryError(RuntimeError):
    pass


def canonical_digest(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=False).encode("utf-8")).hexdigest()


def _git(root: Path, *args: str, binary: bool = False):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True,
                            text=not binary, timeout=120)
    if result.returncode:
        detail = result.stderr.decode("utf-8", "replace") if binary else result.stderr
        raise RegistryError(f"Git registry authority unavailable: {' '.join(args)}: {detail.strip()}")
    return result.stdout


def _values(value) -> list:
    # Preserve empty/malformed slots: dropping one changes the denominator.
    return value if isinstance(value, list) else [value]


def references(document: dict) -> list[dict]:
    """Walk all registered logs and explicit path/digest records, before judgment."""
    rows: list[dict] = []

    def walk(value, address: str, population: str, force: bool = False):
        if isinstance(value, dict):
            field = "log" if force or "log" in value else (
                "path" if "path" in value and ("sha256" in value or "log_sha256" in value) else None)
            if field:
                paths = _values(value.get(field))
                hashes = _values(value.get("sha256", value.get("log_sha256")))
                # Extra digest slots are malformed references too, not silently dropped.
                for index in range(max(len(paths), len(hashes))):
                    rows.append({"id": f"{address}#{index}", "population": population,
                                 "path": paths[index] if index < len(paths) else None,
                                 "sha256": hashes[index] if index < len(hashes) else None,
                                 "declared_lost": value.get("declared_lost"),
                                 "superseded_sha256": value.get("sha256_superseded"),
                                 "repoint_reason": value.get("repoint_reason")})
            for key, child in value.items():
                if key == "declared_lost":
                    continue
                # Historical audit-map members are references, not current proof.
                if key.endswith("_sha256") and isinstance(child, dict):
                    base = value.get(key[:-7])
                    if isinstance(base, str):
                        for name, digest in sorted(child.items()):
                            rows.append({"id": f"{address}.{key}.{name}", "population": population,
                                         "path": str(Path(base) / name), "sha256": digest,
                                         "declared_lost": None})
                        continue
                walk(child, f"{address}.{key}", population, force=key == "my_logs")
        elif isinstance(value, list):
            for index, child in enumerate(value):
                walk(child, f"{address}[{index}]", population, force)
        elif force:
            rows.append({"id": f"{address}#0", "population": population,
                         "path": None, "sha256": None, "declared_lost": None})

    for key, value in document.items():
        # Generated accounting repeats authored records; it is not another register.
        if key == "current_assessment":
            authored = {k: v for k, v in value.items() if k not in (
                "finding_closure", "structured_counts", "structured_semantics",
                "discharged_prose_dispositions", "source_evidence_registry")}
            walk(authored, key, "other")
        else:
            population = key if key in ("findings", "convergence") else "other"
            walk(value, key, population)
    return rows


def _relative(path: str, root: Path) -> str | None:
    candidate = Path(path)
    if candidate.is_absolute():
        try:
            candidate = candidate.relative_to(root)
        except ValueError:
            return None
    if ".." in candidate.parts:
        return None
    return candidate.as_posix()

def _is_within(child: Path, parent: Path) -> bool:
    """Containment with BOTH sides resolved -- a symlink must not carry bytes across a boundary."""
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except (ValueError, OSError):
        return False


def ownership_namespace(path, expected, root: Path, tracked: set[str],
                        historical_pairs: set[tuple[str, str]]) -> tuple[str, str | None]:
    """Return (namespace, repository-relative path) for one reference -- the single ownership authority.

    Used by both the consumer (classify) and the materializer's required-population enumeration, so the two never
    diverge. Namespaces: protected-historical (a protected user archive), repository-historical (tracked and anchored
    in history), repository-current (tracked now), external-historical (everything else).
    """
    rel = _relative(path, root) if isinstance(path, str) else None
    protected = rel is not None and any(rel == p or rel.startswith(p + "/") for p in PROTECTED_ROOTS)
    historical = (path, expected) in historical_pairs
    # An absolute historical path can name a checkout on another workstation.
    if rel is None and isinstance(path, str) and "/GODSTONE/" in path:
        suffix = path.split("/GODSTONE/", 1)[1]
        if suffix in tracked:
            rel = suffix
        protected = any(suffix == p or suffix.startswith(p + "/") for p in PROTECTED_ROOTS)
    if protected:
        return "protected-historical", rel
    if historical and rel in tracked:
        return "repository-historical", rel
    if rel in tracked:
        return "repository-current", rel
    return "external-historical", rel


def valid_anchored_loss(source: dict, historical_pairs: set[tuple[str, str]]) -> bool:
    """True when a declared_lost is well-formed AND its exact (path, sha256) is anchored in the immutable ledger."""
    loss = source.get("declared_lost")
    path, expected = source.get("path"), source.get("sha256")
    return (isinstance(loss, dict) and loss.get("log") == path and loss.get("sha256") == expected
            and isinstance(loss.get("reason"), str) and bool(loss["reason"].strip())
            and isinstance(loss.get("date"), str) and bool(loss["date"].strip())
            and (path, expected) in historical_pairs)


def _declared_evidence_root(document: dict, root: Path):
    """Return the declared builder evidence root after validating it, or (None, reason).

    This is the materializer's read-only source road; the consumer (classify) never calls it and re-derives external
    proof from the tracked archive. The path is read from the ledger's evidence_root field. A declared root that is
    absent, malformed, inside the repository, or a protected user archive returns None plus a named reason, so the
    materializer refuses rather than fabricating or reading bytes elsewhere.
    """
    declared = document.get("evidence_root")
    if not isinstance(declared, str) or not declared.strip():
        return None, "the record declares no evidence_root"
    candidate = Path(declared)
    if not candidate.is_absolute():
        return None, f"the declared evidence_root {declared!r} is not absolute"
    try:
        resolved = candidate.resolve()
    except OSError:
        return None, "the declared evidence_root could not be resolved"
    root_resolved = root.resolve()
    if resolved == root_resolved or root_resolved in resolved.parents:
        return None, ("the declared root lies inside the repository; repository bytes are claimed "
                      "through the Git index and the anchor commit only")
    for name in PROTECTED_ROOTS:
        if name in resolved.parts:
            return None, f"the declared root names the protected user archive {name!r}: never opened"
    if not resolved.is_dir():
        return None, f"the declared root {resolved} is ABSENT on this host: declared absent, not skipped"
    return resolved, None


def _external_bytes(declared_root, declared_note, path_text: str):
    """Return the declared root's bytes for one reference, or (None, reason).

    This is the materializer's read-only source road; the consumer never calls it. Resolution order is (root, then
    root/REMEDIATION); an absolute path qualifies only inside the verified declared root, and a symlink never carries
    evidence across the boundary. The builder root is never written and never required.
    """
    if declared_root is None:
        return None, f"external bytes not examined: {declared_note}"
    candidate = Path(path_text)
    if candidate.is_absolute():
        if not _is_within(candidate, declared_root):
            return None, "absolute path lies outside the declared evidence root: no read is taken"
        target = candidate
    else:
        if ".." in candidate.parts:
            return None, "path traversal is refused"
        target = None
        for base in (declared_root, declared_root / "REMEDIATION"):
            probe = base / candidate
            if probe.is_file():
                target = probe
                break
        if target is None:
            return None, "resolves nowhere under the declared evidence root"
    if target.is_symlink():
        return None, "symlinked external bytes are not owned evidence"
    if not _is_within(target, declared_root):
        return None, "the resolved target escapes the declared evidence root"
    try:
        return target.resolve().read_bytes(), None
    except OSError as exc:
        return None, f"declared bytes could not be read: {exc}"


def classify(document: dict, *, root: Path, anchor_commit: str,
             ledger_relative: str = "docs/remediation/REMEDIATION_STATE.json") -> dict:
    """Regenerate the complete partition from source records and Git-owned bytes."""
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise RegistryError("Evidence register is absent, malformed, or has an unsupported schema")
    if not isinstance(document.get("findings"), dict) or not document["findings"]:
        raise RegistryError("Evidence register has no findings population")
    tracked = set(_git(root, "ls-files", "-z").split("\0")) - {""}
    declared_root, declared_note = declared_root_declaration(document, root)
    declared_root_state = ("DECLARED; the tracked clone-carried proof archive is the authority"
                           if declared_root is not None else declared_note)
    declaration_problems = ([] if declared_root is not None
                            else [f"the declared evidence_root is malformed or unlawful: {declared_note}"])
    anchor_text = _git(root, "show", f"{anchor_commit}:{ledger_relative}")
    try:
        anchor_document = json.loads(anchor_text)
    except (TypeError, ValueError) as exc:
        raise RegistryError("Immutable historical ledger is malformed") from exc
    anchor_references = references(anchor_document)
    historical_pairs = {(r["path"], r["sha256"]) for r in anchor_references
                        if isinstance(r["path"], str) and isinstance(r["sha256"], str)}
    source_rows = references(document)
    if not source_rows:
        raise RegistryError("Evidence register has no registered references")
    rows: list[dict] = []
    problems: list[str] = list(declaration_problems)
    for source in source_rows:
        row = {"id": source["id"], "population": source["population"],
               "path": source["path"], "registered_sha256": source["sha256"]}
        path, expected = source["path"], source["sha256"]
        if not isinstance(path, str) or not path.strip():
            row.update(namespace="unnamed", disposition="unnamed", proof=False,
                       reason="Registered reference has no valid path")
            rows.append(row)
            continue
        namespace, rel = ownership_namespace(path, expected, root, tracked, historical_pairs)
        row["namespace"] = namespace
        if not isinstance(expected, str) or not DIGEST.fullmatch(expected):
            row.update(disposition="undigested", proof=False, reason="Missing or malformed registered SHA-256")
            rows.append(row)
            continue
        loss = source.get("declared_lost")
        if loss is not None:
            if not valid_anchored_loss(source, historical_pairs):
                row.update(disposition="unresolved", proof=False, reason="Malformed or unanchored declared loss")
                problems.append(f"{row['id']}: malformed or unanchored declared_lost")
                rows.append(row)
                continue
            row.update(disposition="declared_lost", proof=False, loss=loss,
                       reason="Exact reference and original digest anchored in immutable historical ledger")
            rows.append(row)
            continue
        data = None
        why_absent = "No owned bytes available; protected archives are never read by any road"
        if namespace == "repository-historical":
            try:
                data = _git(root, "cat-file", "blob", f"{anchor_commit}:{rel}", binary=True)
                row["anchor_commit"] = anchor_commit
                row["blob_sha"] = _git(root, "rev-parse", f"{anchor_commit}:{rel}").strip()
            except RegistryError:
                # The reference stays counted; absent historical bytes are not invented.
                data = None
                why_absent = ("not carried by the immutable anchor commit; historical bytes are Git-owned "
                              "and are not invented")
        elif namespace == "repository-current":
            file = root / rel
            try:
                # A tracked symlink to a user's archive must not import external bytes.
                file.resolve().relative_to(root.resolve())
                if file.is_symlink():
                    raise ValueError("Tracked symlink is not owned evidence bytes")
                data = file.read_bytes() if file.is_file() else None
            except (OSError, ValueError):
                data = None
            if data is None:
                why_absent = "tracked bytes absent from the working tree or symlinked out of the repository"
        elif namespace == "external-historical":
            # External dispositions are re-derived only from the tracked content-addressed archive, so the document
            # re-derives identically wherever it runs. A missing, untracked, symlinked or tampered entry leaves the
            # reference unresolved (a named refusal), and the user's builder root is never read here.
            data = _clone_carried_bytes(root, expected, tracked)
            if data is not None:
                row["read_via"] = "clone-carried-proof-archive"
                row["proof_scope"] = ("external proof re-derived from the tracked content-addressed archive "
                                      f"{CLONE_PROOF_DIRNAME}; the builder root is never required")
            else:
                why_absent = (f"no tracked clone-carried proof archive entry "
                              f"{CLONE_PROOF_DIRNAME}/{expected}{ARCHIVE_SUFFIX}")
        if data is None:
            row.update(disposition="unresolved", proof=False, reason=why_absent)
        else:
            actual = hashlib.sha256(data).hexdigest()
            row.update(disposition="examined", actual_sha256=actual, proof=actual == expected)
            if actual != expected:
                row["reason"] = "Digest mismatch; examined does not mean verified"
        if namespace == "repository-current" and not row["proof"]:
            problems.append(f"{row['id']}: current repository proof incomplete ({path})")
        rows.append(row)
    # All namespaces retain malformed slots; such corruption cannot disappear into an empty register.
    for row in rows:
        if row["disposition"] in ("unnamed", "undigested"):
            problems.append(f"{row['id']}: {row['disposition']} registered evidence")
    counts = {name: sum(row["disposition"] == name for row in rows) for name in DISPOSITIONS}
    counts.update(registered=len(rows), verified=sum(row["proof"] for row in rows),
                  mismatched=sum(row["disposition"] == "examined" and not row["proof"] for row in rows))
    counts["accounted"] = sum(counts[name] for name in DISPOSITIONS)
    counts["counts_accounted"] = counts["registered"] == counts["accounted"]
    populations = {}
    for population in sorted({row["population"] for row in rows}):
        selected = [row for row in rows if row["population"] == population]
        populations[population] = {name: sum(row["disposition"] == name for row in selected)
                                   for name in DISPOSITIONS}
        populations[population].update(registered=len(selected), verified=sum(row["proof"] for row in selected))
    return {**counts, "partition_rule": "registered == examined + unresolved + unnamed + declared_lost + undigested",
            "external_proof_scope": ("external proof is re-derived from the tracked content-addressed archive "
                                     f"{CLONE_PROOF_DIRNAME}; the builder root is declared but never required, "
                                     "and no internal gate reads its bytes"),
            "declared_evidence_root": str(declared_root) if declared_root is not None else None,
            "declared_root_state": declared_root_state,
            "populations": populations, "records": rows, "records_sha256": canonical_digest(rows),
            "source_sha256": canonical_digest(document), "historical_anchor_commit": anchor_commit,
            "problems": problems}
