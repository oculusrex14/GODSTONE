#!/usr/bin/env python3
"""Model-provenance authority (T61): strict locks, content-addressed artifacts,
bounded temporary files, atomic promotion.

This module is the repository's single tested-Python authority for the
provenance registers named in the card:

  * ModelLockV1      -- the strict model lock (docs/packaging/MODELS.lock.json):
        every artifact is sworn with id, kind, tiers, repo, an IMMUTABLE
        source_commit (a 40-hex revision, never a branch name like 'main'),
        source_file, output_file, sha256, size_bytes, license, tokenizer,
        context_tokens and -- for embedding models -- an
        EmbeddingFingerprint (pooling, normalization, dimension). A
        compatible native ABI is named per artifact and must be listed by
        the native lock.
  * NativeLockV1     -- the native build register: the llama.cpp source
        revision, the pinned build flags, the pinned toolchains and the
        list of compatible ABIs. The values recorded here are transcribed
        from the repository's own build files (android/llm/build.gradle.kts
        ndkVersion/abiFilters/cmake args, android/llm/src/main/cpp/
        CMakeLists.txt, ios/Godstone/Package.swift header search paths);
        the upstream revision itself is null until the external
        NATIVE_MODELS gate verifies and pins it -- no fixture may close it.
  * ContentAddressedArtifact -- the bytes a lock entry speaks of are its
        SHA-256 digest, its exact length and its parseable GGUF header.
        A filename, a size or a dimension is NEVER trusted alone: every
        restore re-computes the digest and walks the header. This is the
        card's named falsification ('trust filename or dimension alone
        without model hash: incompatible-model fixture fails').
  * restore / fetch  -- validate inputs, stage to a bounded temporary file
        (.part, hard ceiling at the declared size), verify the staged
        bytes, then promote atomically (os.replace). A failed verification
        unlinketh the temporary and leaveth the authoritative destination
        exactly as it found it. An existing destination that fails its own
        oath is refused, never silently overwritten.

Doctrine:
  * The network fetch path (this module's `fetch` subcommand, driven by
    scripts/fetch_models.sh) is developer tooling ONLY. Nothing here is
    ever wired into the shipping runtime; the apps carry the bytes as
    packaged artefacts and the runtime gates (ModelManager.kt /
    ModelManager.swift) verify the file against the lock entry before a
    worker is built.
  * The lock is versioned: schema 1 is the legacy proposed-coordinates
    style, schema 2 is the strict register. Unknown or future versions are
    REFUSED, never auto-detected.
  * While the register status is UNPINNED every provenance field of every
    artifact must stand null: a half-pinned register (some coordinates
    sworn, others not) is the very mutable-trusting disease this gate
    keeps. The fetch and verify commands refuse an UNPINNED register.

Usage:
    python3 scripts/model_provenance.py --selftest
    python3 scripts/model_provenance.py validate [--lock PATH] [--tier ALL]
    python3 scripts/model_provenance.py verify   [--lock PATH] [--dest DIR] [--tier ALL]
    python3 scripts/model_provenance.py fetch    [--lock PATH] [--dest DIR] [--tier ALL]
                                                [--transport-dir DIR]

--transport-dir is a developer-local mirror used by tests and audits:
fetch readeth <transport-dir>/<output_file> instead of the network. The
default transport is HTTPS against the immutable pinned coordinates.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

MAX_CHUNK = 1024 * 1024          # streamed verification chunk size
GGUF_MAGIC = b"GGUF"
GGUF_MAX_VERSION = 3
# GGUF metadata value types (0..8); the header walk skips them by size.
_VALUE_SIZES = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1}

_HEX40 = re.compile(r"[0-9a-f]{40}")
_HEX64 = re.compile(r"[0-9a-f]{64}")
_BASENAME_SAFE = re.compile(r"[A-Za-z0-9._-]+\.gguf")
_ID_SAFE = re.compile(r"[a-z0-9][a-z0-9_-]*")
_REPO_SAFE = re.compile(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+")
_FLAG_SAFE = re.compile(r"-[A-Za-z0-9+=,/._%-]+")
_VERSION_SAFE = re.compile(r"[0-9][0-9.]*")

TIERS = ("LIGHT", "MEDIUM", "LARGE")
POOLINGS = ("none", "mean", "cls", "last")
NORMALIZATIONS = ("none", "l2")
KINDS = ("generation", "embedding")
ABIS = ("arm64-v8a", "x86-64")
STATUSES = ("UNPINNED", "PINNED")
MODEL_LOCK_SCHEMAS = (1, 2)
CURRENT_MODEL_LOCK_SCHEMA = 2
ACCEPTED_TOP_KEYS = {"schema", "status", "verified_on", "verified_by", "notes",
                     "native", "artifacts"}
ACCEPTED_NATIVE_KEYS = {"llama_revision", "source_repo", "build_flags",
                        "toolchains", "abis"}
ARTIFACT_KEYS = {"id", "kind", "tiers", "repo", "source_commit", "source_file",
                 "output_file", "sha256", "size_bytes", "license", "tokenizer",
                 "context_tokens", "embedding", "native_abi"}
PROVENANCE_KEYS = ("source_commit", "sha256", "size_bytes", "license",
                   "tokenizer", "context_tokens", "embedding", "native_abi")
COORDINATE_KEYS = ("id", "kind", "tiers", "repo", "source_file", "output_file")
ACCEPTED_EMBEDDING_KEYS = {"pooling", "normalization", "dimension"}
ACCEPTED_TOOLCHAIN_KEYS = {"name", "version"}


class ProvenanceError(ValueError):
    """Raised when a lock, a header or a restore refuseth its subject."""


def _require(condition, cry):
    if not condition:
        raise ProvenanceError(cry)


def _t_str(value, label):
    _require(isinstance(value, str) and value != "",
             ProvenanceError(f"{label} must be a non-empty string"))
    return value


def _t_hex40(value, label):
    _require(isinstance(value, str) and _HEX40.fullmatch(value),
             ProvenanceError(
                 f"{label} must be a full 40-character lower-case hexadecimal revision, "
                 f"never a mutable branch name: {value!r}"))
    return value


def _t_hex64(value, label):
    _require(isinstance(value, str) and _HEX64.fullmatch(value),
             ProvenanceError(f"{label} must be a full 64-character lower-case hexadecimal digest"))
    return value


def _t_pos(value, label):
    _require(type(value) is int and not isinstance(value, bool) and value > 0,
             ProvenanceError(f"{label} must be a positive integer"))
    return value


def _t_basename(value, label):
    _require(isinstance(value, str) and _BASENAME_SAFE.fullmatch(value),
             ProvenanceError(f"{label} must be a plain .gguf basename without "
                             f"separators or traversal: {value!r}"))
    return value


class EmbeddingFingerprint:
    """The pooling, normalization and dimension a compatible embedding model
    must swear to (parity with rag/Embedder.kt and the iOS twin: mean-pooled,
    L2-normalised, dimension pinned)."""

    __slots__ = ("pooling", "normalization", "dimension")

    def __init__(self, pooling, normalization, dimension):
        _require(pooling in POOLINGS, ProvenanceError(
            f"unknown pooling {pooling!r}; must be one of {list(POOLINGS)}"))
        _require(normalization in NORMALIZATIONS, ProvenanceError(
            f"unknown normalization {normalization!r}; must be one of {list(NORMALIZATIONS)}"))
        _t_pos(dimension, "embedding dimension")
        self.pooling = pooling
        self.normalization = normalization
        self.dimension = dimension

    @classmethod
    def fromlock(cls, blob, label):
        _require(isinstance(blob, dict),
                 ProvenanceError(f"{label}: embedding fingerprint must be an object"))
        _require(set(blob) <= ACCEPTED_EMBEDDING_KEYS, ProvenanceError(
            f"{label}: unknown embedding fingerprint field(s) "
            f"{sorted(set(blob) - ACCEPTED_EMBEDDING_KEYS)}"))
        missing = ACCEPTED_EMBEDDING_KEYS - set(blob)
        _require(not missing, ProvenanceError(
            f"{label}: embedding fingerprint wanteth field(s) {sorted(missing)}"))
        return cls(blob["pooling"], blob["normalization"], blob["dimension"])

    def asdict(self):
        return {"pooling": self.pooling, "normalization": self.normalization,
                "dimension": self.dimension}


class ContentAddressedArtifact:
    """The bytes a lock entry speaketh of are its digest, its exact length
    and its parseable GGUF header -- never its name."""

    __slots__ = ("id", "kind", "tiers", "repo", "source_commit", "source_file",
                 "output_file", "sha256", "size_bytes", "license_name",
                 "tokenizer", "context_tokens", "fingerprint", "native_abi")

    def __init__(self, id, kind, tiers, repo, source_commit, source_file,
                 output_file, sha256, size_bytes, license_name, tokenizer,
                 context_tokens, fingerprint, native_abi):
        _require(_ID_SAFE.fullmatch(id), ProvenanceError(
            f"artifact id must match [a-z0-9][a-z0-9_-]*: {id!r}"))
        _require(kind in KINDS, ProvenanceError(
            f"{id}: kind must be one of {list(KINDS)}, got {kind!r}"))
        _require(isinstance(tiers, (tuple, list)) and tiers and
                 all(t in TIERS for t in tiers), ProvenanceError(
            f"{id}: tiers must be a non-empty list drawn from {list(TIERS)}"))
        _require(_REPO_SAFE.fullmatch(repo), ProvenanceError(
            f"{id}: repo must be 'owner/name': {repo!r}"))
        _t_basename(source_file, f"{id}.source_file")
        _t_basename(output_file, f"{id}.output_file")
        _t_hex40(source_commit, f"{id}.source_commit")
        _t_hex64(sha256, f"{id}.sha256")
        _t_pos(size_bytes, f"{id}.size_bytes")
        _t_str(license_name, f"{id}.license")
        _t_str(tokenizer, f"{id}.tokenizer")
        _t_pos(context_tokens, f"{id}.context_tokens")
        _require(native_abi in ABIS, ProvenanceError(
            f"{id}: native_abi {native_abi!r} is not a compatible ABI of this "
            f"repository (known: {list(ABIS)})"))
        if kind == "embedding":
            _require(isinstance(fingerprint, EmbeddingFingerprint), ProvenanceError(
                f"{id}: an embedding model must swear its full fingerprint "
                f"(pooling, normalization, dimension)"))
        else:
            _require(fingerprint is None, ProvenanceError(
                f"{id}: a generation model hath no embedding fingerprint to swear"))
        self.id = id
        self.kind = kind
        self.tiers = tuple(tiers)
        self.repo = repo
        self.source_commit = source_commit
        self.source_file = source_file
        self.output_file = output_file
        self.sha256 = sha256
        self.size_bytes = size_bytes
        self.license_name = license_name
        self.tokenizer = tokenizer
        self.context_tokens = context_tokens
        self.fingerprint = fingerprint
        self.native_abi = native_abi

    @classmethod
    def fromlock(cls, blob):
        """Build one sworn artifact from a lock blob; every field must stand
        complete or the blob is refused."""
        _require(isinstance(blob, dict), ProvenanceError("artifact must be an object"))
        _require(set(blob) <= ARTIFACT_KEYS, ProvenanceError(
            f"artifact {blob.get('id')!r}: unknown field(s) "
            f"{sorted(set(blob) - ARTIFACT_KEYS)}"))
        missing = ARTIFACT_KEYS - set(blob)
        _require(not missing, ProvenanceError(
            f"artifact {blob.get('id')!r}: wanteth field(s) {sorted(missing)}"))
        label = str(blob.get("id"))
        fingerprint = None
        if blob["embedding"] is not None:
            fingerprint = EmbeddingFingerprint.fromlock(blob["embedding"], label)
        return cls(label, blob["kind"], blob["tiers"], blob["repo"],
                   blob["source_commit"], blob["source_file"], blob["output_file"],
                   blob["sha256"], blob["size_bytes"], blob["license"],
                   blob["tokenizer"], blob["context_tokens"], fingerprint,
                   blob["native_abi"])

    def asdict(self):
        return {"id": self.id, "kind": self.kind, "tiers": list(self.tiers),
                "repo": self.repo, "source_commit": self.source_commit,
                "source_file": self.source_file, "output_file": self.output_file,
                "sha256": self.sha256, "size_bytes": self.size_bytes,
                "license": self.license_name, "tokenizer": self.tokenizer,
                "context_tokens": self.context_tokens,
                "embedding": self.fingerprint.asdict() if self.fingerprint else None,
                "native_abi": self.native_abi}

    def url(self):
        """The immutable coordinate the bytes are fetched from: a pinned
        commit, never a mutable branch like 'main'."""
        return (f"https://huggingface.co/{self.repo}/resolve/"
                f"{self.source_commit}/{self.source_file}")


class NativeLockV1:
    """The native build register: llama.cpp revision, build flags, toolchains
    and the compatible ABIs. Values are transcribed from the repository's own
    build files; the upstream revision stands null until the external gate
    pins it (see the module tale)."""

    __slots__ = ("llama_revision", "source_repo", "build_flags", "toolchains", "abis")

    def __init__(self, llama_revision, source_repo, build_flags, toolchains, abis):
        if llama_revision is not None:
            _t_hex40(llama_revision, "native.llama_revision")
        _require(_REPO_SAFE.fullmatch(source_repo), ProvenanceError(
            f"native.source_repo must be 'owner/name': {source_repo!r}"))
        _require(isinstance(build_flags, list) and build_flags, ProvenanceError(
            "native.build_flags must be a non-empty list"))
        for flag in build_flags:
            _require(_FLAG_SAFE.fullmatch(flag), ProvenanceError(
                f"native build flag must be a single -D/-f/-W token without "
                f"separators or traversal: {flag!r}"))
        _require(isinstance(toolchains, list) and toolchains, ProvenanceError(
            "native.toolchains must be a non-empty list"))
        for tc in toolchains:
            _require(isinstance(tc, dict) and set(tc) == ACCEPTED_TOOLCHAIN_KEYS,
                     ProvenanceError(
                         f"toolchain entry must have exactly {sorted(ACCEPTED_TOOLCHAIN_KEYS)}: {tc!r}"))
            _t_str(tc["name"], "toolchain name")
            _require(_VERSION_SAFE.fullmatch(tc["version"]),
                     ProvenanceError(f"toolchain version must be dotted digits: {tc['version']!r}"))
        _require(isinstance(abis, list) and abis and all(a in ABIS for a in abis),
                 ProvenanceError(
                     f"native.abis must be a non-empty list drawn from {list(ABIS)}"))
        self.llama_revision = llama_revision
        self.source_repo = source_repo
        self.build_flags = list(build_flags)
        self.toolchains = list(toolchains)
        self.abis = list(abis)

    @classmethod
    def fromlock(cls, blob):
        _require(isinstance(blob, dict), ProvenanceError("native block must be an object"))
        _require(set(blob) <= ACCEPTED_NATIVE_KEYS, ProvenanceError(
            f"native block: unknown field(s) {sorted(set(blob) - ACCEPTED_NATIVE_KEYS)}"))
        missing = ACCEPTED_NATIVE_KEYS - set(blob)
        _require(not missing, ProvenanceError(
            f"native block wanteth field(s) {sorted(missing)}"))
        return cls(blob["llama_revision"], blob["source_repo"], blob["build_flags"],
                   blob["toolchains"], blob["abis"])

    def asdict(self):
        return {"llama_revision": self.llama_revision, "source_repo": self.source_repo,
                "build_flags": list(self.build_flags),
                "toolchains": [dict(tc) for tc in self.toolchains], "abis": list(self.abis)}


def _validate_legacy(status, verified_on, verified_by, blobs):
    """The pre-T61 schema-1 law verbatim: coordinates, nullable digests."""
    for b in blobs:
        _require(isinstance(b, dict), ProvenanceError("legacy artifact must be an object"))
        _require(isinstance(b.get("id"), str) and b["id"], ProvenanceError("legacy artifact wanteth an id"))
        _require(isinstance(b.get("repo"), str) and b["repo"], ProvenanceError(f"{b.get('id')}: legacy artifact wanteth a repo"))
        for k in ("source_file", "output_file"):
            v = b.get(k)
            _require(isinstance(v, str) and v and "/" not in v and v not in {".", ".."},
                     ProvenanceError(f"{b.get('id')}: legacy unsafe {k} {v!r}"))
        tiers = b.get("tiers", [])
        _require(isinstance(tiers, list) and tiers and all(t in TIERS for t in tiers),
                 ProvenanceError(f"{b.get('id')}: legacy tiers must be drawn from {list(TIERS)}"))
        sha = b.get("sha256")
        if status == "PINNED":
            _require(verified_on and verified_by, ProvenanceError("PINNED legacy lock lacks verifier metadata"))
            _require(isinstance(sha, str) and _HEX64.fullmatch(sha),
                     ProvenanceError(f"{b.get('id')}: PINNED legacy artifact lacks a valid sha256"))
        else:
            _require(not sha, ProvenanceError(f"{b.get('id')}: UNPINNED legacy artifact must keep sha256 null"))


def _reject_constant(token):
    raise ValueError(f"the JSON constant {token!r} hath no place in a strict register")


def _reject_float(token):
    raise ValueError(f"fractional number {token!r} hath no place in a strict register")


def _pairs_no_duplicates(pairs):
    seen = set()
    for key, _ in pairs:
        _require(key not in seen, ProvenanceError(
            f"duplicate key '{key}' in one object"))
        seen.add(key)
    return dict(pairs)


def _load_strict(text):
    try:
        return json.loads(text, object_pairs_hook=_pairs_no_duplicates,
                          parse_constant=_reject_constant,
                          parse_float=_reject_float)
    except ProvenanceError:
        raise
    except ValueError as exc:
        raise ProvenanceError(f"model lock is not strict JSON: {exc}") from exc


class ModelLockV1:
    """The strict model lock. Under status PINNED every artifact is sworn
    complete (ContentAddressedArtifact.fromlock enforceth it); under status
    UNPINNED every provenance field of every artifact must stand null -- a
    half-pinned register is refused as loudly as the fetch refuseth it."""

    __slots__ = ("schema", "status", "verified_on", "verified_by", "notes",
                 "native", "blobs", "sworn")

    def __init__(self, schema, status, verified_on, verified_by, notes, native,
                 artifacts):
        _require(schema in MODEL_LOCK_SCHEMAS, ProvenanceError(
            f"unsupported model-lock schema {schema!r}; this tool understandeth "
            f"{list(MODEL_LOCK_SCHEMAS)} and refuseth every future version"))
        _require(status in STATUSES, ProvenanceError(
            f"lock status {status!r} is not one of {list(STATUSES)}"))
        _require(isinstance(artifacts, list) and artifacts, ProvenanceError(
            "model lock containeth no artifacts"))
        if schema == 1:
            # The legacy estate: coordinates only, hashes nullable, no native
            # block law. Held to the old rules verbatim so an archived
            # register still loads for audit -- but it is READ ONLY: fetch and
            # verify demand the strict schema 2 estate below.
            _require(native is None or (isinstance(native, dict) and native == {}),
                     ProvenanceError("schema 1 is the legacy estate; it knoweth no native block"))
            self.blobs = [dict(b) for b in artifacts]
            _validate_legacy(status, verified_on, verified_by, self.blobs)
            self.sworn = []
            self.native = NativeLockV1.fromlock({
                "llama_revision": None, "source_repo": "ggml-org/llama.cpp",
                "build_flags": ["-O0"], "toolchains": [{"name": "bootstrap", "version": "0"}],
                "abis": ["arm64-v8a"]})
            self.verified_on = verified_on
            self.verified_by = verified_by
            self.schema = schema
            self.status = status
            self.notes = notes
            return
        _require(isinstance(native, dict), ProvenanceError(
            "model lock wanteth field 'native'"))
        if status == "PINNED":
            _t_str(verified_on, "verified_on")
            _t_str(verified_by, "verified_by")
        else:
            _require(verified_on is None and verified_by is None, ProvenanceError(
                "an UNPINNED lock must not name a verifier or a date: the oath "
                "belongeth to the PINNED estate only"))
        if not isinstance(native, NativeLockV1):
            native = NativeLockV1.fromlock(native)
        self.schema = schema
        self.status = status
        self.verified_on = verified_on
        self.verified_by = verified_by
        self.notes = notes
        self.native = native
        self.blobs = []
        self.sworn = []
        seen_ids = set()
        seen_outputs = set()
        for blob in artifacts:
            _require(isinstance(blob, dict), ProvenanceError("artifact must be an object"))
            _require(set(blob) <= ARTIFACT_KEYS, ProvenanceError(
                f"artifact {blob.get('id')!r}: unknown field(s) "
                f"{sorted(set(blob) - ARTIFACT_KEYS)}"))
            missing = ARTIFACT_KEYS - set(blob)
            _require(not missing, ProvenanceError(
                f"artifact {blob.get('id')!r}: wanteth field(s) {sorted(missing)}"))
            label = str(blob.get("id"))
            _require(label not in seen_ids, ProvenanceError(f"duplicate artifact id {label!r}"))
            output = blob["output_file"]
            _require(output not in seen_outputs, ProvenanceError(
                f"duplicate output_file {output!r} (two ids, one destination is a collision)"))
            seen_ids.add(label)
            seen_outputs.add(output)
            if status == "PINNED":
                art = ContentAddressedArtifact.fromlock(blob)
                _require(art.native_abi in native.abis, ProvenanceError(
                    f"{art.id}: native_abi {art.native_abi!r} is not compatible: "
                    f"the native lock listeth {native.abis}"))
                self.sworn.append(art)
            else:
                # An UNPINNED register must be wholly unpinned: every
                # provenance field standeth null, coordinates aside.
                sworn_already = [k for k in PROVENANCE_KEYS if blob.get(k) is not None]
                _require(not sworn_already, ProvenanceError(
                    f"{label}: the register is UNPINNED yet these provenance fields "
                    f"are sworn: {sworn_already} -- verify them all or none"))
                # the coordinates themselves must still be tellingly sane
                _require(_ID_SAFE.fullmatch(label), ProvenanceError(
                    f"artifact id must match [a-z0-9][a-z0-9_-]*: {label!r}"))
                _require(blob["kind"] in KINDS, ProvenanceError(
                    f"{label}: kind must be one of {list(KINDS)}, got {blob['kind']!r}"))
                _require(isinstance(blob["tiers"], (tuple, list)) and blob["tiers"] and
                         all(t in TIERS for t in blob["tiers"]), ProvenanceError(
                    f"{label}: tiers must be a non-empty list drawn from {list(TIERS)}"))
                _require(_REPO_SAFE.fullmatch(blob["repo"]), ProvenanceError(
                    f"{label}: repo must be 'owner/name': {blob['repo']!r}"))
                _t_basename(blob["source_file"], f"{label}.source_file")
                _t_basename(blob["output_file"], f"{label}.output_file")
            self.blobs.append(dict(blob))

    @classmethod
    def load(cls, path):
        path = Path(path)
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            raise ProvenanceError(f"cannot read model lock {path}: {exc}") from exc
        try:
            blob = _load_strict(text)
        except ValueError as exc:
            raise ProvenanceError(f"model lock {path} is not valid JSON: {exc}") from exc
        _require(isinstance(blob, dict), ProvenanceError("model lock must be an object"))
        _require(set(blob) <= ACCEPTED_TOP_KEYS, ProvenanceError(
            f"model lock: unknown top-level field(s) "
            f"{sorted(set(blob) - ACCEPTED_TOP_KEYS)}"))
        want = {"schema", "status", "artifacts"}
        _require(want <= set(blob), ProvenanceError(
            f"model lock wanteth field(s) {sorted(want - set(blob))}"))
        return cls(blob["schema"], blob["status"], blob.get("verified_on"),
                   blob.get("verified_by"), blob.get("notes"), blob.get("native"),
                   blob["artifacts"])

    def asdict(self):
        return {"schema": self.schema, "status": self.status,
                "verified_on": self.verified_on, "verified_by": self.verified_by,
                "notes": self.notes, "native": self.native.asdict(),
                "artifacts": [a.asdict() for a in self.sworn] if self.status == "PINNED"
                else [dict(b) for b in self.blobs]}

    def select_for_tier(self, tier):
        """The sworn artifacts whose tiers name the asked tier (PINNED only)."""
        _require(self.schema == CURRENT_MODEL_LOCK_SCHEMA, ProvenanceError(
            "schema 1 is the legacy proposed-coordinates estate: validate only; "
            "reforge the register to schema 2 before fetch or verify"))
        _require(self.status == "PINNED", ProvenanceError(
            "the model lock is UNPINNED; independently verify every upstream "
            "artifact and its SHA-256 before use (status must read PINNED with "
            "verified_on/verified_by sworn)"))
        _require(tier == "ALL" or tier in TIERS, ProvenanceError(
            f"tier must be ALL, LIGHT, MEDIUM or LARGE, got {tier!r}"))
        chosen = [a for a in self.sworn if tier == "ALL" or tier in a.tiers]
        _require(chosen, ProvenanceError(f"no locked artifacts selected for tier {tier}"))
        return chosen


# -- GGUF header walk ------------------------------------------------------------

def gguf_verify(data):
    """Walk a GGUF container's header wholly; return
    (version, n_tensors, n_tensors_seen, n_kv_pairs) or raise ProvenanceError.
    A truncated container -- header, metadata pairs or tensor infos running
    out of bytes -- is refused by name, even when its digest would match."""
    _require(isinstance(data, (bytes, bytearray)),
             ProvenanceError("gguf_verify wanteth bytes"))
    buf = bytes(data)
    at = 0

    def _take(n, what):
        nonlocal at
        _require(len(buf) - at >= n, ProvenanceError(
            f"gguf header truncated: wanteth {n} byte(s) for {what}, "
            f"the container holdeth but {len(buf) - at}"))
        out = buf[at:at + n]
        at += n
        return out

    def _u32(what):
        return int.from_bytes(_take(4, what), "little")

    def _u64(what):
        return int.from_bytes(_take(8, what), "little")

    def _string(what):
        n = _u32(f"{what} length")
        _require(n <= MAX_CHUNK, ProvenanceError(
            f"{what} length {n} exceedeth the bounded chunk {MAX_CHUNK}"))
        return _take(n, what).decode("utf-8", errors="strict")

    _require(len(buf) >= 24 and buf[:4] == GGUF_MAGIC,
             ProvenanceError("not a GGUF container: magic mismatch"))
    # The walk steppeth over the magic (and never trusteth the name `pos`,
    # which this world's builtins shadoweth with a callable).
    _take(4, "magic")
    version = _u32("version")
    _require(1 <= version <= GGUF_MAX_VERSION, ProvenanceError(
        f"unsupported GGUF version {version}; this walk understandeth "
        f"1..{GGUF_MAX_VERSION}"))
    n_tensors = _u64("n_tensors")
    n_kv = _u64("n_kv")
    _require(n_tensors <= 65536 and n_kv <= 4096, ProvenanceError(
        f"implausible header counts (n_tensors={n_tensors}, n_kv={n_kv})"))
    for _ in range(n_kv):
        key = _string("metadata key")
        vtype = _take(1, f"metadata value type of {key!r}")[0]
        _require(vtype in _VALUE_SIZES or vtype == 8, ProvenanceError(
            f"{key}: unknown GGUF metadata value type {vtype}"))
        if vtype == 8:                       # array: element type u8, count u32
            elem = _take(1, f"{key!r} array element type")[0]
            _require(elem in _VALUE_SIZES, ProvenanceError(
                f"{key}: unknown GGUF array element type {elem}"))
            count = _u32(f"{key!r} array count")
            _require(count * _VALUE_SIZES[elem] <= 1024 * MAX_CHUNK, ProvenanceError(
                f"{key}: array byte count {count} out of bounds"))
            _take(count * _VALUE_SIZES[elem], f"{key!r} array bytes")
        else:
            _take(_VALUE_SIZES[vtype], f"{key!r} value")
    seen = 0
    for _ in range(n_tensors):
        _string("tensor name")                    # raiseth when truncated
        n_dims = _u32("tensor n_dims")
        _require(n_dims <= 16, ProvenanceError(
            f"implausible tensor rank {n_dims} (a GGUF tensor rank is tiny)"))
        _take(8 * n_dims, "tensor dimensions")
        _take(1, "tensor type")
        _take(8, "tensor offset")
        seen += 1
    _require(seen == n_tensors, ProvenanceError(
        f"GGUF tensor count mismatch: header promised {n_tensors}, "
        f"the walk fond {seen}"))
    return version, n_tensors, seen, n_kv


def verify_content_addressed(artifact, data):
    """The card's law: the digest, the exact length AND the header walk -- a
    filename or a dimension is never trusted alone. Returneth the list of
    cries (empty is the clean bill of health)."""
    cries = []
    digest = hashlib.sha256(data).hexdigest()
    if digest != artifact.sha256:
        cries.append(f"{artifact.output_file}: content digest mismatch -- the "
                     f"lock sweareth {artifact.sha256}, the bytes answer to "
                     f"{digest} (a file of the same name is NOT the sworn content)")
    if len(data) != artifact.size_bytes:
        cries.append(f"{artifact.output_file}: length mismatch -- the lock "
                     f"sweareth {artifact.size_bytes} byte(s), the bytes "
                     f"count {len(data)}")
    try:
        gguf_verify(data)
    except ProvenanceError as exc:
        cries.append(f"{artifact.output_file}: {exc}")
    return cries


# -- bounded temporary files with atomic promotion --------------------------------

def restore(artifact, data, dest_dir):
    """Restore one locked artifact from fully-given bytes into dest_dir with
    atomic promotion: verify first, stage to <name>.part, verify the staged
    bytes again, then os.replace. A corruption is refused BEFORE any
    authoritative file is touched; an existing verified destination is
    reused, never rewritten. Returneth {'action','path','digest'}."""
    dest_dir = Path(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)
    final = dest_dir / artifact.output_file
    if final.exists():
        existing = final.read_bytes()
        cries = verify_content_addressed(artifact, existing)
        _require(not cries, ProvenanceError(
            f"{final} standeth corrupt and refuseth the restore: " + "; ".join(cries)))
        return {"action": "reused", "path": str(final),
                "digest": hashlib.sha256(existing).hexdigest()}
    # The given bytes are sworn first -- no byte toucheth the destination
    # until the whole bill of health is clean.
    cries = verify_content_addressed(artifact, data)
    _require(not cries, ProvenanceError("; ".join(cries)))
    part = dest_dir / (artifact.output_file + ".part")
    if part.exists():
        part.unlink()                     # a crashed temporary is perished
    fd = os.open(str(part), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        view = memoryview(data)
        written = 0
        while written < len(view):
            os.write(fd, view[written:written + MAX_CHUNK])
            written += min(MAX_CHUNK, len(view) - written)
        os.fsync(fd)
    except OSError as exc:
        os.close(fd)
        part.unlink(missing_ok=True)
        raise ProvenanceError(f"staging failed for {artifact.output_file}: {exc}")
    os.close(fd)
    staged = part.read_bytes()            # read the promoted temporary back
    cries = verify_content_addressed(artifact, staged)
    if cries:
        part.unlink(missing_ok=True)
        raise ProvenanceError("staged bytes failed the final verification: "
                              + "; ".join(cries))
    os.replace(str(part), str(final))     # atomic promotion
    return {"action": "promoted", "path": str(final),
            "digest": hashlib.sha256(staged).hexdigest()}


def _http_read(url, ceiling):
    """Bounded HTTPS read: the stream is perished the moment it exceedeth the
    declared size -- an unbounded download is no provenance."""
    from urllib.error import HTTPError, URLError
    from urllib.request import Request, urlopen
    req = Request(url, headers={"User-Agent": "godstone-model-provenance/1"})
    try:
        with urlopen(req, timeout=60) as resp:
            if resp.status != 200:
                raise ProvenanceError(f"{url}: server answered {resp.status}")
            chunks = []
            total = 0
            while True:
                chunk = resp.read(MAX_CHUNK)
                if not chunk:
                    break
                total += len(chunk)
                if total > ceiling:
                    raise ProvenanceError(
                        f"{url}: stream exceeded the declared size {ceiling} "
                        f"(the transfer is perished)")
                chunks.append(chunk)
            return b"".join(chunks)
    except HTTPError as exc:
        raise ProvenanceError(f"{url}: server answered {exc.code}") from exc
    except (URLError, OSError, TimeoutError) as exc:
        raise ProvenanceError(f"{url}: cannot fetch ({exc})") from exc


def fetch(artifact, dest_dir, *, transport_dir=None, opener=None):
    """Fetch one locked artifact into dest_dir with atomic promotion: bounded
    temporary file, verification against the sworn digest, os.replace. The
    network path is developer tooling only (see the module tale)."""
    dest_dir = Path(dest_dir)
    final = dest_dir / artifact.output_file
    if final.exists():
        cries = verify_content_addressed(artifact, final.read_bytes())
        if not cries:
            return {"action": "reused", "path": str(final), "digest": artifact.sha256}
    if transport_dir is not None:
        source = Path(transport_dir) / artifact.output_file
        _require(source.is_file(), ProvenanceError(
            f"transport mirror hath not {artifact.output_file}"))
        data = source.read_bytes()
    else:
        read = opener or _http_read
        data = read(artifact.url(), artifact.size_bytes)
    verdict = restore(artifact, data, dest_dir)
    verdict.setdefault("source", str(transport_dir or artifact.url()))
    return verdict


def verify_cli_paths(lock, dest_dir, tier):
    """The quantise face: every selected artifact must stand verified in
    dest_dir. Returneth [{'id','ok','why'}]."""
    out = []
    for art in lock.select_for_tier(tier):
        path = Path(dest_dir) / art.output_file
        if not path.is_file():
            out.append({"id": art.id, "file": art.output_file, "ok": False,
                       "why": f"missing {path}; run the fetch first"})
            continue
        cries = verify_content_addressed(art, path.read_bytes())
        out.append({"id": art.id, "file": art.output_file, "ok": not cries,
                    "why": "; ".join(cries)})
    return out


# -- the ever-living selftest ------------------------------------------------------

def _synth_gguf(n_tensors=2, n_kv=2, junk_tail=b"", version=3):
    """Build a well-formed GGUF container: header, metadata pairs, tensor
    infos -- the form the header walk must finish wholly."""
    import struct
    out = bytearray()
    out += GGUF_MAGIC
    out += struct.pack("<I", version)
    out += struct.pack("<Q", n_tensors)
    out += struct.pack("<Q", n_kv)

    def _s(text):
        raw = text.encode("utf-8")
        return struct.pack("<I", len(raw)) + raw

    # two metadata pairs: a string and an u32-array
    out += _s("general.name") + struct.pack("<B", 8) + struct.pack("<B", 4) \
        + struct.pack("<I", 2) + struct.pack("<II", 7, 11)
    out += _s("tokenizer.ggml.add_bos") + struct.pack("<B", 7) + struct.pack("<B", 1)
    for i in range(n_tensors):
        out += _s(f"blk.{i}.weight")
        out += struct.pack("<I", 2) + struct.pack("<QQ", 64, 32)
        out += struct.pack("<B", 10)                  # f32 per the GGUF enum
        out += struct.pack("<Q", 4096 * i)
    out += junk_tail
    return bytes(out)


def _synth_artifact(**over):
    good = {"id": "generation-synth", "kind": "generation", "tiers": ["LIGHT"],
            "repo": "godstone-tests/synth", "source_commit": "a" * 40,
            "source_file": "Synth.gguf", "output_file": "synth.gguf",
            "sha256": None, "size_bytes": None, "license": "apache-2.0",
            "tokenizer": "gpt2", "context_tokens": 2048, "embedding": None,
            "native_abi": "arm64-v8a"}
    good.update(over)
    data = good.pop("_bytes", None) or _synth_gguf()
    if good["sha256"] is None:
        good["sha256"] = hashlib.sha256(data).hexdigest()
    if good["size_bytes"] is None:
        good["size_bytes"] = len(data)
    return ContentAddressedArtifact.fromlock(good), data


def _unsworn_blob(**over):
    """A coordinate-complete, provenance-empty blob -- the shape of the
    shipped UNPINNED register."""
    blob = {"id": "generation-synth", "kind": "generation", "tiers": ["LIGHT"],
            "repo": "godstone-tests/synth", "source_commit": None,
            "source_file": "Synth.gguf", "output_file": "synth.gguf",
            "sha256": None, "size_bytes": None, "license": None,
            "tokenizer": None, "context_tokens": None, "embedding": None,
            "native_abi": None}
    blob.update(over)
    return blob


def _synth_lock(**over):
    good = {"schema": 2, "status": "PINNED", "verified_on": "2026-09-13",
            "verified_by": "the builder's own eye", "notes": "synthetic",
            "native": {"llama_revision": None, "source_repo": "ggml-org/llama.cpp",
                       "build_flags": ["-O3", "-ffast-math", "-fno-exceptions"],
                       "toolchains": [{"name": "ndk", "version": "27.0.12077973"},
                                       {"name": "cmake", "version": "3.22.1"}],
                       "abis": ["arm64-v8a"]},
            "artifacts": None}
    good.update(over)
    if good["artifacts"] is None:
        art, _ = _synth_artifact()
        good["artifacts"] = [art.asdict()]
    return good


def _write_lock(blob) -> Path:
    import tempfile
    fd, name = tempfile.mkstemp(prefix="lock-", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(blob, stream)
    return Path(name)


def _selftest() -> int:
    """Every rule the authority speaketh is witnessed by a corruption that
    must be refused; the lawful register must pass; promotion and repeated
    restore must be atomic and determinist."""
    import tempfile
    cases = []

    def refuse(label, thunk):
        cases.append((label, thunk))

    def lock_with(**blob_over):
        def go():
            blob = _synth_lock(**blob_over)
            ModelLockV1.load(_write_lock(blob))
        return go

    def artifact_with(**over):
        base = _synth_lock()["artifacts"][0]
        blob = dict(base)
        blob.update(over)
        return lock_with(artifacts=[blob])

    def bad_json(text):
        def go():
            _load_strict(text)
        return go

    refuse("duplicate keys in one JSON object", bad_json('{"a": 1, "a": 2}'))
    refuse("fractional number in the document", bad_json('{"size_bytes": 1.5}'))
    refuse("the NaN constant in the document", bad_json('{"size_bytes": NaN}'))
    refuse("the legacy estate carrying a native block",
           lock_with(schema=1, native={"abis": ["arm64-v8a"]}))
    refuse("the strict estate lacking the native block",
           lock_with(schema=2, native=None))
    refuse("future schema version", lock_with(schema=3))
    refuse("mutable coordinate (branch, not revision)",
           artifact_with(source_commit="main"))
    refuse("truncated digest", artifact_with(sha256="a" * 63))
    refuse("half-pinned register (license null under PINNED)",
           artifact_with(license=None))
    refuse("path traversal in output_file",
           artifact_with(output_file="../evil.gguf"))
    refuse("duplicate artifact ids",
           lambda: ModelLockV1.load(_write_lock(_synth_lock(
               artifacts=[dict(_synth_lock()["artifacts"][0]),
                          dict(_synth_lock()["artifacts"][0])]))))
    refuse("duplicate output_files under different ids",
           lambda: ModelLockV1.load(_write_lock(_synth_lock(
               artifacts=[dict(_synth_lock()["artifacts"][0]),
                          dict(_synth_lock()["artifacts"][0],
                               id="generation-synth-twin")]))))
    refuse("unsupported architecture", artifact_with(native_abi="riscv-9"))
    refuse("unknown top-level field",
           lambda: ModelLockV1.load(_write_lock(
               dict(_synth_lock(), future_field="auto-detect me not"))))
    refuse("missing verifier oath under PINNED",
           lock_with(verified_by=None))
    refuse("sworn date without verifier (verified_on orphan)",
           lambda: ModelLockV1.load(_write_lock(_synth_lock(
               status="UNPINNED", verified_on="2026-09-13", verified_by=None,
               artifacts=[_unsworn_blob()]))))
    refuse("embedding model without its fingerprint",
           artifact_with(id="embedding-synth", kind="embedding"))
    refuse("generation model swearing a fingerprint",
           lambda: ModelLockV1.load(_write_lock(_synth_lock(artifacts=[
               dict(_synth_lock()["artifacts"][0],
                    embedding={"pooling": "mean", "normalization": "l2",
                               "dimension": 384})]))))
    refuse("unpinned register with a sworn digest",
           lambda: ModelLockV1.load(_write_lock(_synth_lock(
               status="UNPINNED", verified_on=None, verified_by=None,
               artifacts=[dict(_synth_lock()["artifacts"][0])]))))
    # bytes-level refusals: the content-addressed law itself
    art, data = _synth_artifact()
    wrong = bytearray(data)
    wrong[-1] ^= 0xFF                       # same name, same length, wrong bytes
    tampered = bytes(wrong)
    refuse("content digest mismatch (name and size trusted alone)",
           lambda: _require(not verify_content_addressed(art, tampered),
                           ProvenanceError("refused")))
    refuse("length mismatch under a matching digest is impossible; the pair "
           "must disagree together",
           lambda: _require(not verify_content_addressed(art, data + b"x"),
                            ProvenanceError("refused")))
    refuse("truncated GGUF header", lambda: gguf_verify(data[: len(data) // 2]))
    refuse("GGUF magic impostor", lambda: gguf_verify(b"NMT!" + data[4:]))
    refuse("GGUF version beyond the walk",
           lambda: gguf_verify(_synth_gguf(version=99)))
    refuse("tensor count promise broken (the last tensor info cut short)",
           lambda: gguf_verify(_synth_gguf(n_tensors=1)[:-20]))
    refuse("restore of mismatched bytes refuseth promotion",
           lambda: restore(art, tampered, tempfile.mkdtemp()))
    refuse("restore past a corrupt standing destination is refused",
           lambda: _corrupt_destination_refused(art, data, tampered))

    failed = []
    for label, thunk in cases:
        try:
            thunk()
        except ProvenanceError:
            pass
        except Exception as exc:                    # the wrong kind of cry
            failed.append(f"{label}: raised {type(exc).__name__}: {exc}")
        else:
            failed.append(f"{label}: the corruption passeth -- REFUSE FAILED")
    # the lawful way: validate, fetch twice (determinist), verify
    with tempfile.TemporaryDirectory(prefix="t61-selftest-") as td:
        td = Path(td)
        mirror = td / "mirror"
        mirror.mkdir()
        dest = td / "models"
        lock = ModelLockV1.load(_write_lock(_synth_lock()))
        sworn = lock.select_for_tier("ALL")[0]
        (mirror / sworn.output_file).write_bytes(_synth_gguf())
        first = fetch(sworn, dest, transport_dir=mirror)
        second = fetch(sworn, dest, transport_dir=mirror)
        if first["action"] != "promoted" or second["action"] != "reused" \
                or first["digest"] != second["digest"] != sworn.sha256:
            failed.append("repeated restore is not determinist")
        if (dest / (sworn.output_file + ".part")).exists():
            failed.append("a temporary survived the promotion")
        verdicts = verify_cli_paths(lock, dest, "ALL")
        if [v for v in verdicts if v["ok"]] != verdicts:
            failed.append("the verify walk fell upon a lawful tree")
    # The shipped register itself is witnessed ever-living: its UNPINNED
    # conformance is part of the authority's own health, not a trusty tale.
    shipped = Path(__file__).resolve().parent.parent / "docs" / "packaging" / "MODELS.lock.json"
    try:
        reg = ModelLockV1.load(shipped)
        if reg.schema != 2 or reg.status != "UNPINNED" or len(reg.blobs) != 5:
            failed.append(f"the shipped register is out of conformance: {reg.schema}/{reg.status}")
        for b in reg.blobs:
            for k in PROVENANCE_KEYS:
                if b.get(k) is not None:
                    failed.append(f"shipped register {b.get('id')}: {k} is sworn while UNPINNED")
        if reg.native.llama_revision is not None or reg.native.abis != ["arm64-v8a"]:
            failed.append("the shipped native block is out of its tale")
        if [tc["name"] for tc in reg.native.toolchains] != ["ndk", "cmake"]:
            failed.append("the shipped toolchain pair is misnumbered")
        if len(reg.native.build_flags) != 5:
            failed.append("the shipped build-flag tale is misnumbered")
    except ProvenanceError as exc:
        failed.append(f"the shipped register refuseth its own loading: {exc}")
    refused = len(cases) - len(failed)
    for f in failed:
        print(f"::error::selftest: {f}")
    print(f"ok: model-provenance selftest refuseth {refused} of {len(cases)} "
          f"corruptions; the lawful register, the atomic promotion and the "
          f"determinist repeat all pass")
    return 1 if failed else 0


def _corrupt_destination_refused(art, good, bad):
    """Pre-establish a corrupt destination, then the restore must refuse to
    write over it -- the prior authoritative state stayeth as it was."""
    import tempfile
    dest = Path(tempfile.mkdtemp())          # mkdtemp hath already made it
    (dest / art.output_file).write_bytes(bad)      # a corrupt standing file
    try:
        restore(art, good, dest)
    except ProvenanceError:
        # the corrupt file must stand untouched (neither replaced nor perished)
        if (dest / art.output_file).read_bytes() != bad:
            raise ProvenanceError("the restore meddled with the standing file")
        if list(dest.glob("*.part")):
            raise ProvenanceError("a temporary was left standing")
        raise
    raise AssertionError("a corrupt destination was silently overwritten")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="T61 model-provenance authority (locks, restore, verify)")
    ap.add_argument("--selftest", action="store_true",
                    help="run the ever-living corruptions and exit")
    sub = ap.add_subparsers(dest="command")
    for name in ("validate", "verify", "fetch"):
        sp = sub.add_parser(name)
        sp.add_argument("--lock", default="docs/packaging/MODELS.lock.json")
        sp.add_argument("--tier", default="ALL")
        if name != "validate":
            sp.add_argument("--dest",
                            default=os.environ.get("GODSTONE_MODEL_DIR", "models"))
        if name == "fetch":
            sp.add_argument("--transport-dir", default=None)
    args = ap.parse_args(argv)
    # An authority that can not refute its own corruptions can not certify a
    # register: the selftest is ever-living, before every verdict.
    rc = _selftest()
    if rc != 0:
        print("::error::model-provenance selftest is failing; every command is "
              "refused until it passeth", file=sys.stderr)
        return rc
    if args.selftest:
        return 0
    if not getattr(args, "command", None):
        ap.print_usage(sys.stderr)
        return 2
    try:
        lock = ModelLockV1.load(args.lock)
        tier = args.tier
        if args.command == "validate":
            selected = [b["id"] for b in lock.blobs
                        if tier == "ALL" or tier in b["tiers"]]
            _require(selected, ProvenanceError(
                f"no locked artifacts selected for tier {tier}"))
            _require(tier == "ALL" or tier in TIERS, ProvenanceError(
                f"tier must be ALL, LIGHT, MEDIUM or LARGE, got {tier!r}"))
            print(f"ok: model lock schema {lock.schema} status {lock.status}; "
                  f"{len(lock.blobs)} artifact(s), {len(selected)} selected for "
                  f"tier {tier}; native ABIs {lock.native.abis}; llama.cpp revision "
                  f"{lock.native.llama_revision or 'UNPINNED'}")
            return 0
        if args.command == "verify":
            verdicts = verify_cli_paths(lock, args.dest, tier)
            cries = [v for v in verdicts if not v["ok"]]
            for v in verdicts:
                print(("ok       " if v["ok"] else "error:   ") + v["file"])
            for v in cries:
                print(f"error: {v['id']}: {v['why']}", file=sys.stderr)
            if cries:
                return 1
            print("model set is verified; no re-quantisation is required")
            return 0
        # fetch: the developer tooling path; an UNPINNED register refuseth
        for art in lock.select_for_tier(tier):
            verdict = fetch(art, args.dest,
                            transport_dir=(Path(args.transport_dir)
                                           if args.transport_dir else None))
            if verdict["action"] == "reused":
                print(f"ok       {art.output_file} (already verified)")
            else:
                print(f"fetching {art.source_file} from {art.repo}")
                print(f"ok       {art.output_file}")
        print(f"locked model artifacts are in {args.dest}")
        return 0
    except ProvenanceError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
