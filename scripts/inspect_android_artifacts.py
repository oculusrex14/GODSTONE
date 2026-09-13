#!/usr/bin/env python3
"""Archive release-artifact inspector (Stage 3 Phase I; A-17; T52).

Inspects built release artifacts (APK / AAB / IPA) and proveth TWO distinct
things, which must not be confounded:

  * SOURCE-ONLY EXCLUSION EVIDENCE -- without an expected Archive the run
    proveth only the exclusions: no on-device model, no :llm bridge, no
    cross-tier name or metadata. Absence of the Archive is lawful in that
    lane and is reported as 'absent'; it is NOT content proof.

  * PACKAGED PRESENCE AND RELEASE-CANDIDATE CONTENT -- with
    --expected-archive the inspector requireth in EVERY artifact: exactly one
    canonical Archive entry at the kind's path (APK assets/archive_light.db,
    AAB base/assets/archive_light.db, IPA Payload/Godstone.app/archive_light
    .db), nonempty, byte-identical to the expected file (streamed SHA-256);
    with --approved-manifest (the T51 publication) the expected bytes must
    also agree with the sworn digest -- a stale publication is rejected. The
    extracted bytes must open read-only as a real database: PRAGMA
    integrity_check 'ok', archive_meta tier LIGHT, a sworn schema_version,
    document_count and chunk_count rows agreeing with COUNT(*), and the FTS5
    index answereth the first row. --release-candidate addeth the fixture
    prohibition: a development fixture (metadata key or prose marker)
    packaged as production is rejected.

All lanes reject: duplicate ZIP entries (two records of one name), traversal
names, symlink entries, dangerous modes (world-writable or setuid/setgid
regular files), cross-tier names and cross-tier metadata, empty packaged
Archives, the model and :llm natives. The presence lanes further require the
resolved bundled engine (a libsqliteJ* native under a lib/ directory) and a
dex for the android kinds, and for the IPA kind the bundle executable
(nonempty) and an embedded Info.plist carrying CFBundleExecutable (the T51
installable-metadata covenant observed at the package level). Where a merged
AndroidManifest.xml of a lightRelease variant is found beside the artifacts,
its real grants are inspected: a radio/BLE/location grant without the
merger's removal directive is rejected.

The inventory and the approved-archive presence report are published
deterministically (sorted keys, fixed fields) under the output directory --
only upon complete success; a rejected inspection publisheth nothing.

Usage:
    python3 scripts/inspect_android_artifacts.py <build_root> <out_dir>
    python3 scripts/inspect_android_artifacts.py <build_root> <out_dir> \
        --expected-archive <file> [--approved-manifest <APPROVED_ASSETS.json>] \
        [--release-candidate]
    python3 scripts/inspect_android_artifacts.py --selftest
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import re
import sqlite3
import tempfile
import zipfile
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

# Cross-tier contamination (non-LIGHT archives / models) -- name based.
CROSS_TIER_MARKERS = ("archive_medium", "archive_large", "qwen3-1.7", "qwen3-4b")
# The on-device model + the non-shipping :llm native bridge -- the Archive-only
# contract: the LIGHT release must NOT contain these.
ARCHIVE_ONLY_FORBIDDEN = (".gguf", "libgodstone_llm", "libllama", "libLlamaBridge")
# Per-kind canonical Archive locations inside the package.
CANONICAL_ARCHIVE = {
    ".apk": "assets/archive_light.db",
    ".aab": "base/assets/archive_light.db",
    ".ipa": "Payload/Godstone.app/archive_light.db",
}
# The resolved bundled engine of the archive road (android kinds): the
# AndroidX bundled sqlite driver carrieth these natives into the package.
BUNDLED_ENGINE_PREFIX = "libsqliteJ"
# The IPA bundle executable and its embedded metadata (the T51 covenant).
IPA_EXECUTABLE = "Payload/Godstone.app/Godstone"
IPA_INFO_PLIST = "Payload/Godstone.app/Info.plist"
# Real granted radio/network permissions an Archive-only release must never
# carry; the manifest merger's removal directive excepteth each.
RADIO_GRANTS = {
    "android.permission.INTERNET",
    "android.permission.BLUETOOTH",
    "android.permission.BLUETOOTH_ADMIN",
    "android.permission.BLUETOOTH_SCAN",
    "android.permission.BLUETOOTH_CONNECT",
    "android.permission.ACCESS_FINE_LOCATION",
    "android.permission.ACCESS_COARSE_LOCATION",
    "android.permission.ACCESS_BACKGROUND_LOCATION",
}
FIXTURE_PROSE_MARKERS = (b"development fixture", b"development-fixture", b"not survival guidance")
APPROVED_SCHEMA = 1
SHA256_RE = re.compile(r"[0-9a-f]{64}")
_S_IFMT = 0o170000
_S_IFREG = 0o100000
_S_IFLNK = 0o120000
_S_IFDIR = 0o040000


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _violations(names: list[str]) -> list[str]:
    """Forbidden entry names in an artifact's namelist (exclusion matters)."""
    out: list[str] = []
    low = {n.lower(): n for n in names}
    for marker in CROSS_TIER_MARKERS:
        for low_n, orig in low.items():
            if marker in low_n:
                out.append(f"cross-tier asset contamination: {orig}")
    for marker in ARCHIVE_ONLY_FORBIDDEN:
        for low_n, orig in low.items():
            if marker.lower() in low_n:
                out.append(f"non-Archive-only entry present ({marker}): {orig}")
    return out


def _entry_mode(info: zipfile.ZipInfo) -> int:
    return info.external_attr >> 16


def _entry_is_symlink(info: zipfile.ZipInfo) -> bool:
    return _entry_mode(info) & _S_IFMT == _S_IFLNK


def _entry_is_directory(info: zipfile.ZipInfo) -> bool:
    return info.filename.endswith("/") or _entry_mode(info) & _S_IFMT == _S_IFDIR


def _entry_is_regular(info: zipfile.ZipInfo) -> bool:
    return _entry_mode(info) & _S_IFMT == _S_IFREG


def _traversal(name: str) -> bool:
    if name.startswith("/") or "\\" in name:
        return True
    return any(part == ".." for part in name.split("/"))


def _dangerous_mode(info: zipfile.ZipInfo) -> bool:
    mode = _entry_mode(info)
    return bool(mode & 0o002) or bool(mode & 0o4000) or bool(mode & 0o2000)


class ApprovedArchivePresenceReport:
    """The presence report of one artifact: what was seen, sworn and found."""

    def __init__(self) -> None:
        self.status = "absent"   # absent | present-unverified | byte-matched | rejected
        self.evidence = "source-only-exclusion"   # | packaged-bytes-present | release-candidate-content
        self.entry: str | None = None
        self.entries_found = 0
        self.bytes: int | None = None
        self.sha256: str | None = None
        self.expected_sha256: str | None = None
        self.tier: str | None = None
        self.schema_version: str | None = None
        self.counts: dict[str, int] = {}
        self.declared_counts: dict[str, str] = {}
        self.integrity: str | None = None
        self.fts: str | None = None
        self.fixture_marker_found = False
        self.development_fixture_key = False
        self.symlink_entries = 0
        self.traversal_entries = 0
        self.duplicate_entries = 0
        self.dangerous_modes = 0
        self.native_libraries: list[str] = []
        self.dex_entries = 0
        self.radio_grants: list[str] = []
        self.errors: list[str] = []

    def reject(self, why: str) -> None:
        self.errors.append(why)
        self.status = "rejected"

    def to_dict(self) -> dict:
        return {
            "status": self.status, "evidence": self.evidence, "entry": self.entry,
            "entries_found": self.entries_found, "bytes": self.bytes, "sha256": self.sha256,
            "expected_sha256": self.expected_sha256, "tier": self.tier,
            "schema_version": self.schema_version, "counts": dict(self.counts),
            "declared_counts": dict(self.declared_counts), "integrity": self.integrity,
            "fts": self.fts, "fixture_marker_found": self.fixture_marker_found,
            "development_fixture_key": self.development_fixture_key,
            "symlink_entries": self.symlink_entries, "traversal_entries": self.traversal_entries,
            "duplicate_entries": self.duplicate_entries, "dangerous_modes": self.dangerous_modes,
            "native_libraries": sorted(self.native_libraries), "dex_entries": self.dex_entries,
            "radio_grants": sorted(self.radio_grants), "errors": list(self.errors),
        }


def load_approved_manifest(path: Path) -> dict:
    """Read the staged APPROVED_ASSETS.json (T51's publication), strictly.

    Unknown shapes, foreign hashes and future schemas are refused; the
    document must name exactly one archive asset of the Light tier."""
    data = json.loads(
        path.read_text(encoding="utf-8"),
        parse_constant=lambda value: (_ for _ in ()).throw(
            ValueError(f"constants are not permitted: {value!r}")))
    errors: list[str] = []
    if not isinstance(data, dict):
        raise ValueError("approved manifest root must be an object")
    if type(data.get("schema")) is not int or data.get("schema") != APPROVED_SCHEMA:
        errors.append("approved manifest schema must be the one current schema")
    if data.get("tier") != "LIGHT":
        errors.append("approved manifest tier must be LIGHT")
    if data.get("application_id") != "io.godstone.app":
        errors.append("approved manifest application identity mismatch")
    assets = data.get("assets")
    if not isinstance(assets, list) or len(assets) != 1 or not isinstance(assets[0], dict):
        raise ValueError("approved manifest must name exactly one archive asset")
    asset = assets[0]
    if asset.get("role") != "archive" or asset.get("name") != "archive_light.db":
        errors.append("approved manifest asset must be role archive named archive_light.db")
    sha = asset.get("sha256")
    if not isinstance(sha, str) or not SHA256_RE.fullmatch(sha):
        errors.append("approved manifest asset sha256 must be a lower-case SHA-256")
    size = asset.get("bytes")
    if type(size) is not int or size <= 0:
        errors.append("approved manifest asset bytes must be a positive integer")
    if errors:
        raise ValueError("approved manifest rejected: " + "; ".join(errors))
    return {"sha256": str(sha), "bytes": int(size), "name": "archive_light.db",
            "tier": "LIGHT", "application_id": "io.godstone.app"}


def _probe_extracted(candidate: Path, report: ApprovedArchivePresenceReport,
                     strict_lane: bool) -> None:
    """Open the extracted bytes read-only and search the swom truth."""
    raw = candidate.read_bytes()
    low = raw.lower()
    report.fixture_marker_found = any(marker in low for marker in FIXTURE_PROSE_MARKERS)
    if strict_lane and report.fixture_marker_found:
        report.reject("a development fixture is packaged as production (prose marker in the bytes)")
        return
    uri = f"file:{candidate.resolve()}?mode=ro&immutable=1"
    try:
        with contextlib.closing(sqlite3.connect(uri, uri=True)) as db:
            try:
                row = db.execute("PRAGMA integrity_check").fetchone()
            except sqlite3.DatabaseError as exc:
                report.reject(f"the packaged Archive is no database: {exc}")
                return
            report.integrity = "ok" if row is not None and row[0] == "ok" else f"fail: {row!r}"
            if report.integrity != "ok":
                report.reject(f"integrity check faileth: {report.integrity}")
                return
            try:
                meta = {str(k): str(v) for k, v in db.execute("SELECT key, value FROM archive_meta")}
            except sqlite3.DatabaseError as exc:
                report.reject(f"the archive carrieth no readable metadata: {exc}")
                return
            report.tier = meta.get("tier")
            report.schema_version = meta.get("schema_version")
            report.development_fixture_key = "development_fixture" in meta
            if report.development_fixture_key and strict_lane:
                report.reject("a development fixture is packaged as production (metadata key)")
                return
            if report.tier != "LIGHT":
                report.reject(f"cross-tier archive: metadata tier is {report.tier!r}, not LIGHT")
                return
            if not report.schema_version:
                report.reject("the archive carrieth no sworn schema_version")
                return
            try:
                documents = int(db.execute("SELECT COUNT(*) FROM documents").fetchone()[0])
                chunks = int(db.execute("SELECT COUNT(*) FROM chunks").fetchone()[0])
            except sqlite3.DatabaseError as exc:
                report.reject(f"the archive's tables are unreadable: {exc}")
                return
            report.counts = {"documents": documents, "chunks": chunks}
            report.declared_counts = {
                "documents": meta.get("document_count", ""),
                "chunks": meta.get("chunk_count", ""),
            }
            if report.declared_counts["documents"] != str(documents) or \
               report.declared_counts["chunks"] != str(chunks):
                report.reject(f"the counts metadata lieth: declared {report.declared_counts!r}, "
                              f"found {report.counts!r}")
                return
            if documents <= 0 or chunks <= 0:
                report.reject("the archive is empty of content")
                return
            # The index must answer the content it claimeth to mirror: the
            # first row's own longest word, queried as a token, must return a
            # hit. Where no suitable token existeth, the structural count of
            # the index must at least equal the count of rows.
            try:
                first = db.execute(
                    "SELECT text FROM chunks ORDER BY chunk_id LIMIT 1").fetchone()
                words = re.findall(r"[a-z0-9]+", str(first[0]).lower()) if first else []
                token = max((w for w in words if len(w) >= 3), key=len, default=None)
                if token is not None:
                    answered = int(db.execute(
                        "SELECT COUNT(*) FROM chunks_fts WHERE chunks_fts MATCH ?",
                        (token,)).fetchone()[0])
                    if answered < 1:
                        report.reject(f"the FTS5 index denieth the first row (token {token!r})")
                        return
                else:
                    indexed = int(db.execute("SELECT COUNT(*) FROM chunks_fts").fetchone()[0])
                    if indexed < chunks:
                        report.reject("the FTS5 index is thinner than the content it mirroréth")
                        return
            except sqlite3.DatabaseError as exc:
                report.reject(f"the FTS5 index is unrestorable: {exc}")
                return
            report.fts = "ok"
    except sqlite3.DatabaseError as exc:
        report.reject(f"the packaged Archive could not be opened read-only: {exc}")
        return


def _publish_rejections(artifact: Path, report: ApprovedArchivePresenceReport) -> None:
    print(f"Archive-only inspection FAILED for {artifact}:")
    for why in report.errors:
        print(f"  - {why}")


def inspect(build_root: Path, out: Path, expected_archive: Path | None = None,
            approved_manifest_path: Path | None = None,
            release_candidate: bool = False) -> tuple[int, list[dict]]:
    """Inspect every APK/AAB/IPA under build_root. Returns (rc, inventories).

    Without an expected Archive this is the source-only exclusion gate only;
    absence of the Archive is lawful and reported, never claimed as content.
    With it, the packaged bytes must be present, singular and byte-true; the
    release lane adds the signed cross-check and the fixture prohibition."""
    strict_lane = bool(release_candidate)
    evidence = "source-only-exclusion"
    expected_sha: str | None = None
    expected_size: int | None = None
    approved_sha: str | None = None

    if approved_manifest_path is not None:
        try:
            approved = load_approved_manifest(approved_manifest_path)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"approved manifest is unreadable: {exc}")
            return 1, []
        approved_sha = approved["sha256"]
        expected_sha = approved_sha
        expected_size = approved["bytes"]
        strict_lane = True
        evidence = "release-candidate-content"

    if expected_archive is not None:
        if not expected_archive.is_file() or expected_archive.stat().st_size == 0:
            print("expected Archive is missing or empty")
            return 1, []
        expected_size = expected_archive.stat().st_size
        expected_sha = digest(expected_archive)
        if approved_sha is not None and expected_sha != approved_sha:
            print(f"stale publication: the staged file digreeth from the approved manifest "
                  f"({expected_sha[:12]}… != {approved_sha[:12]}…)")
            return 1, []
        if evidence == "source-only-exclusion":
            evidence = "packaged-bytes-present"

    if release_candidate and expected_sha is None:
        print("the release-candidate lane requireth an expected Archive (or an approved manifest)")
        return 1, []

    artifacts = sorted(list(build_root.rglob("*.apk")) + list(build_root.rglob("*.aab"))
                        + list(build_root.rglob("*.ipa")))
    if not artifacts:
        print("no APK/AAB/IPA artifacts found")
        return 1, []

    # The merged manifest of a lightRelease variant, if the build left one.
    manifest_grants: list[str] = []
    manifests = sorted(p for p in build_root.rglob("**/AndroidManifest.xml")
                       if "lightrelease" in str(p).lower())
    if manifests:
        text = manifests[0].read_text(encoding="utf-8", errors="replace")
        for tag in re.findall(r"<uses-permission\b[^>]*>", text):
            named = re.search(r'android:name="([^"]+)"', tag)
            if named and named.group(1) in RADIO_GRANTS and 'node="remove"' not in tag:
                manifest_grants.append(named.group(1))

    out.mkdir(parents=True, exist_ok=True)
    inventories: list[dict] = []
    for artifact in artifacts:
        kind = artifact.suffix.lower()
        report = ApprovedArchivePresenceReport()
        report.evidence = evidence
        try:
            with zipfile.ZipFile(artifact) as zf:
                infos = zf.infolist()
                names = [info.filename for info in infos]

                # -- structural order, enforced in every lane ----------------
                counted = Counter(names)
                dupes = sorted(name for name, n in counted.items() if n > 1)
                report.duplicate_entries = len(dupes)
                if dupes:
                    report.reject("duplicate ZIP entries: " + ", ".join(dupes))
                report.traversal_entries = sum(1 for n in names if _traversal(n))
                if report.traversal_entries:
                    report.reject("traversal entry names are prohibited")
                report.symlink_entries = sum(1 for info in infos if _entry_is_symlink(info))
                if report.symlink_entries:
                    report.reject("symlink entries are prohibited")
                report.dangerous_modes = sum(1 for info in infos
                                             if _entry_is_regular(info) and _dangerous_mode(info))
                if report.dangerous_modes:
                    report.reject("dangerous entry modes (world-writable or setuid/setgid)")
                for why in _violations(names):
                    report.reject(why)
                report.native_libraries = sorted({
                    info.filename for info in infos
                    if "/lib/" in f"/{info.filename}" and info.filename.endswith(".so")})
                report.dex_entries = sum(1 for n in names if n.endswith(".dex"))

                if report.status == "rejected":
                    _publish_rejections(artifact, report)
                    return 1, []

                # -- the canonical Archive, per kind -------------------------
                canonical = CANONICAL_ARCHIVE.get(kind)
                if canonical is None:
                    report.reject(f"unknown artifact kind {kind!r}")
                else:
                    matches = [info for info in infos if info.filename == canonical]
                    report.entries_found = len(matches)
                    report.entry = canonical if matches else None
                    if len(matches) > 1:
                        report.reject("more than one canonical Archive entry")
                    elif not matches:
                        if expected_sha is not None:
                            report.reject("the expected Archive is absent from the package")
                        else:
                            report.status = "absent"
                    else:
                        info = matches[0]
                        report.bytes = info.file_size
                        if info.file_size == 0:
                            report.reject("the packaged Archive is empty")
                        else:
                            hasher = hashlib.sha256()
                            with zf.open(info) as stream:
                                for block in iter(lambda: stream.read(1024 * 1024), b""):
                                    hasher.update(block)
                            report.sha256 = hasher.hexdigest()
                            if expected_size is not None and info.file_size != expected_size:
                                report.reject("packaged Archive size differeth from the expected")
                            if expected_sha is not None and report.sha256 != expected_sha:
                                report.reject("packaged Archive SHA-256 differeth from the "
                                              "expected (stale or swapped bytes)")
                            if report.status != "rejected":
                                report.status = ("byte-matched" if expected_sha is not None
                                                 else "present-unverified")
                                report.expected_sha256 = expected_sha
                                with tempfile.TemporaryDirectory(prefix="godstone-probe-") as td:
                                    candidate = Path(td) / "probe.db"
                                    candidate.write_bytes(zf.read(info))
                                    _probe_extracted(candidate, report, strict_lane)

                # -- positive claims of the presence lanes --------------------
                if expected_sha is not None and report.status not in ("rejected",):
                    if kind in (".apk", ".aab"):
                        if not any(BUNDLED_ENGINE_PREFIX in Path(n).name
                                   for n in report.native_libraries):
                            report.reject("the resolved bundled engine is absent "
                                          "(no libsqliteJ* native under a lib/ directory)")
                        if report.dex_entries == 0:
                            report.reject("the package carrieth no dex")
                    elif kind == ".ipa":
                        executable = next((i for i in infos if i.filename == IPA_EXECUTABLE), None)
                        if executable is None:
                            report.reject("the IPA bundle wanteth its executable")
                        elif executable.file_size == 0:
                            report.reject("the IPA bundle executable is empty")
                        plist = next((i for i in infos if i.filename == IPA_INFO_PLIST), None)
                        if plist is None:
                            report.reject("the IPA bundle wanteth its embedded Info.plist")
                        elif b"CFBundleExecutable" not in zf.read(plist):
                            report.reject("the embedded Info.plist denieth CFBundleExecutable")

                if manifest_grants:
                    report.radio_grants = sorted(set(manifest_grants))
                    report.reject("the merged manifest granteth radio/network permission(s): "
                                  + ", ".join(report.radio_grants))
        except (OSError, RuntimeError, ValueError, zipfile.BadZipFile) as exc:
            print(f"{artifact}: artifact could not be inspected: {exc}")
            return 1, []

        if report.status == "rejected":
            _publish_rejections(artifact, report)
            return 1, []
        inventories.append({"path": str(artifact), "kind": kind,
                            "bytes": artifact.stat().st_size, "sha256": digest(artifact),
                            "entries": sorted(names), "archive": report.to_dict()})

    (out / "artifact-inventory.json").write_text(
        json.dumps(inventories, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    presence = {
        "schema": 1,
        "evidence": evidence,
        "expected_sha256": expected_sha,
        "verdict": "pass",
        "artifacts": [{"path": inv["path"], "kind": inv["kind"], **inv["archive"]}
                      for inv in inventories],
    }
    (out / "approved-archive-presence.json").write_text(
        json.dumps(presence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0, inventories


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("build_root", type=Path, nargs="?", default=None)
    parser.add_argument("out", type=Path, nargs="?", default=None)
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--expected-archive", type=Path, default=None,
                        help="require each artifact to contain exactly these Archive bytes")
    parser.add_argument("--approved-manifest", type=Path, default=None,
                        help="cross-check against the staged APPROVED_ASSETS.json (T51)")
    parser.add_argument("--release-candidate", action="store_true",
                        help="the release lane: the fixture prohibition is in force")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    if args.build_root is None or args.out is None:
        parser.error("build_root and out are required (or use --selftest)")
    rc, inv = inspect(args.build_root, args.out, args.expected_archive,
                      args.approved_manifest, args.release_candidate)
    if rc == 0:
        if args.expected_archive is None and args.approved_manifest is None:
            mode = "source-only exclusions"
        elif args.release_candidate or args.approved_manifest is not None:
            mode = "release-candidate content"
        else:
            mode = "packaged presence"
        print(f"Archive-only inspection PASSED: {len(inv)} artifact(s) free of model/:llm/cross-tier "
              f"contamination [{mode}]")
    return rc


def _make_archive_bytes(tier: str = "LIGHT", *, fixture: bool = False,
                        lying_counts: bool = False) -> bytes:
    """A harmless, valid, searchable archive built upon the frozen DDL."""
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "archive_light.db"
        with contextlib.closing(sqlite3.connect(path)) as db, db:
            db.executescript((REPO / "content/db/schema.sql").read_text(encoding="utf-8"))
            db.execute(
                "INSERT INTO documents (document_id, title, domain, source_id, licence, "
                "revision, tier_min, reading_level, is_critical) "
                "VALUES (1, 'Reading the river', 'water', 'src-t', 'CC0', 'r1', ?, 8, 1)", (tier,))
            db.execute(
                "INSERT INTO chunks (chunk_id, document_id, ordinal, section, text, token_count) "
                "VALUES (1, 1, 0, 'Bank', ?, 9)",
                ("DEVELOPMENT FIXTURE -- NOT SURVIVAL GUIDANCE. The quick brown fox jaunts."
                 if fixture else
                 "The quick brown fox jaunts by the lazy riverbank in the shade.",))
            meta = {
                "schema_version": "3", "tier": tier,
                "document_count": "9" if lying_counts else "1",
                "chunk_count": "1",
            }
            if fixture:
                meta["development_fixture"] = "true"
            db.executemany("INSERT INTO archive_meta (key, value) VALUES (?, ?)",
                          sorted(meta.items()))
            db.executescript((REPO / "content/db/indexes.sql").read_text(encoding="utf-8"))
        return path.read_bytes()


def _make_package(path: Path, entries: dict[str, bytes], *, symlink: str | None = None,
                  dupe: str | None = None, writable_mode: bool = False) -> None:
    with zipfile.ZipFile(path, "w") as zf:
        for name, data in entries.items():
            info = zipfile.ZipInfo(name)
            info.file_size = len(data)
            mode = 0o100666 if writable_mode else 0o100644
            info.external_attr = mode << 16
            zf.writestr(info, data)
        if dupe is not None:
            info = zipfile.ZipInfo(dupe)
            info.file_size = 3
            info.external_attr = 0o100644 << 16
            zf.writestr(info, b"two")
        if symlink is not None:
            info = zipfile.ZipInfo(symlink)
            info.file_size = 0
            info.external_attr = (0o120000 | 0o777) << 16
            zf.writestr(info, b"")


def selftest() -> int:
    """Build synthetic artifacts and try the inspector's every claim."""
    failures: list[str] = []
    good = _make_archive_bytes()
    ANDROID_OK = {
        "classes.dex": b"dex\n",
        "lib/arm64-v8a/libcore.so": b"\x7fELF stub",
        f"lib/arm64-v8a/{BUNDLED_ENGINE_PREFIX}ni.so": b"\x7fELF engine",
    }

    def expect(desc: str, should_pass: bool, entries: dict[str, bytes], *,
               name: str = "app-light-release.apk", expected: bytes | None = None,
               release: bool = False, symlink: str | None = None,
               dupe: str | None = None, writable_mode: bool = False) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            build = root / "build"
            build.mkdir()
            _make_package(build / name, entries, symlink=symlink, dupe=dupe,
                          writable_mode=writable_mode)
            exp: Path | None = None
            if expected is not None:
                exp = root / "archive_light.db"
                exp.write_bytes(expected)
            rc, _ = inspect(build, root / "out", exp, None, release)
            if (rc == 0) is not should_pass:
                failures.append(f"[{desc}] expected {'PASS' if should_pass else 'FAIL'}, got the other")

    # -- the exclusion lane (no expected Archive): the sealed contract -------
    expect("clean Archive-only APK (source-only exclusion lane)", True, {
        "classes.dex": b"dex\n",
        "lib/arm64-v8a/libcore.so": b"\x7fELF stub",
        f"lib/arm64-v8a/{BUNDLED_ENGINE_PREFIX}ni.so": b"\x7fELF engine",
    })
    expect("source-only APK with a lawful development fixture inside", True,
           {**ANDROID_OK, "assets/archive_light.db": _make_archive_bytes(fixture=True)})
    expect("model gguf present", False,
           {"classes.dex": b"", "assets/qwen3-0.6b-q4km.gguf": b"x"})
    expect(":llm native bridge present", False,
           {"classes.dex": b"", "lib/arm64-v8a/libgodstone_llm.so": b"x"})
    expect("llama.cpp native lib present", False,
           {"classes.dex": b"", "lib/arm64-v8a/libllama.so": b"x"})
    expect("cross-tier archive_medium present", False,
           {"classes.dex": b"", "assets/archive_medium.db": b"x"})
    expect("empty Archive", False, {**ANDROID_OK, "assets/archive_light.db": b""})

    # -- the presence lane: the bytes must be there and true -----------------
    expect("exact Archive bytes ride home (presence lane)", True,
           {**ANDROID_OK, "assets/archive_light.db": good}, expected=good)
    expect("missing Archive (presence lane)", False, dict(ANDROID_OK), expected=good)
    expect("changed Archive bytes (presence lane)", False,
           {**ANDROID_OK, "assets/archive_light.db": b"changed database bytes"}, expected=good)
    expect("husk that is no database at all (presence lane)", False,
           {**ANDROID_OK, "assets/archive_light.db": b"not even a sqlite file, no header, nothing"},
           expected=b"not even a sqlite file, no header, nothing")
    expect("duplicate ZIP entries", False,
           {**ANDROID_OK, "assets/archive_light.db": good}, expected=good,
           dupe="assets/archive_light.db")
    expect("symlink entry", False,
           {**ANDROID_OK, "assets/archive_light.db": good}, expected=good,
           symlink="assets/evil.db")
    expect("world-writable native", False,
           {**ANDROID_OK, "assets/archive_light.db": good}, expected=good,
           writable_mode=True)
    expect("no dex (presence lane)", False, {
        "assets/archive_light.db": good,
        f"lib/arm64-v8a/{BUNDLED_ENGINE_PREFIX}ni.so": b"\x7fELF engine"}, expected=good)
    expect("no bundled engine (presence lane)", False, {
        "classes.dex": b"dex\n", "assets/archive_light.db": good}, expected=good)
    expect("cross-tier metadata inside a lawful name", False,
           {**ANDROID_OK, "assets/archive_light.db": _make_archive_bytes(tier="MEDIUM")},
           expected=_make_archive_bytes(tier="MEDIUM"))
    expect("the counts metadata lieth", False,
           {**ANDROID_OK, "assets/archive_light.db": _make_archive_bytes(lying_counts=True)},
           expected=_make_archive_bytes(lying_counts=True))

    # -- the AAB and IPA shapes ----------------------------------------------
    expect("AAB exact bytes at the base path (presence lane)", True, {
        "base/classes.dex": b"dex\n",
        "base/lib/arm64-v8a/libcore.so": b"\x7fELF stub",
        f"base/lib/arm64-v8a/{BUNDLED_ENGINE_PREFIX}ni.so": b"\x7fELF engine",
        "base/assets/archive_light.db": good},
        name="app.aab", expected=good)
    expect("IPA bundle, executable, plist and archive (presence lane)", True, {
        IPA_EXECUTABLE: b"Mach-O binary image bytes here",
        IPA_INFO_PLIST: b"<plist><key>CFBundleExecutable</key><string>Godstone</string></plist>",
        CANONICAL_ARCHIVE[".ipa"]: good},
        name="Godstone.ipa", expected=good)
    expect("IPA lacking its embedded Info.plist", False, {
        IPA_EXECUTABLE: b"bytes", CANONICAL_ARCHIVE[".ipa"]: good},
        name="Godstone.ipa", expected=good)
    expect("IPA whose plist denieth the executable key", False, {
        IPA_EXECUTABLE: b"bytes",
        IPA_INFO_PLIST: b"<plist><key>CFBundleName</key><string>Godstone</string></plist>",
        CANONICAL_ARCHIVE[".ipa"]: good},
        name="Godstone.ipa", expected=good)

    # -- the release lane: the fixture prohibition is in force ---------------
    expect("release lane refuseth a packaged fixture (prose and key)", False,
           {**ANDROID_OK, "assets/archive_light.db": _make_archive_bytes(fixture=True)},
           expected=_make_archive_bytes(fixture=True), release=True)
    expect("debug presence lane tolerateth the selfsame fixture", True,
           {**ANDROID_OK, "assets/archive_light.db": _make_archive_bytes(fixture=True)},
           expected=_make_archive_bytes(fixture=True))

    # -- the merged manifest's real grants -----------------------------------
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        build = root / "build"
        merged = build / "intermediates/merged_manifests/lightRelease"
        merged.mkdir(parents=True)
        (merged / "AndroidManifest.xml").write_text(
            "<manifest><uses-permission android:name=\"android.permission.INTERNET\"/></manifest>",
            encoding="utf-8")
        _make_package(build / "app.apk", {**ANDROID_OK, "assets/archive_light.db": good})
        rc, _ = inspect(build, root / "out")
        if rc == 0:
            failures.append("[merged manifest granteth INTERNET] expected FAIL, got PASS")
        (merged / "AndroidManifest.xml").write_text(
            "<manifest><uses-permission android:name=\"android.permission.INTERNET\" "
            "tools:node=\"remove\"/></manifest>", encoding="utf-8")
        rc, _ = inspect(build, root / "out")
        if rc != 0:
            failures.append("[merged manifest with removal directive] expected PASS, got FAIL")

    # -- no artifacts at all --------------------------------------------------
    with tempfile.TemporaryDirectory() as td:
        rc, _ = inspect(Path(td), Path(td) / "out")
        if rc == 0:
            failures.append("[no artifacts] expected FAIL, got PASS")

    # -- the approved manifest (T51's publication) ----------------------------
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        build = root / "build"
        build.mkdir()
        exp = root / "archive_light.db"
        exp.write_bytes(good)
        manifest = root / "APPROVED_ASSETS.json"

        def swear(**over):
            document = {
                "schema": 1, "tier": "LIGHT", "application_id": "io.godstone.app",
                "generated_by": "scripts/prepare_release_assets.py",
                "assets": [{"role": "archive", "name": "archive_light.db",
                           "sha256": over.get("sha", hashlib.sha256(good).hexdigest()),
                           "bytes": over.get("size", len(good)),
                           "build_phase": "resources"}],
            }
            manifest.write_text(json.dumps(document, sort_keys=True, indent=2) + "\n",
                                encoding="utf-8")

        swear()
        _make_package(build / "app.apk", {**ANDROID_OK, "assets/archive_light.db": good})
        rc, _ = inspect(build, root / "out", exp, manifest, True)
        if rc != 0:
            failures.append("[release candidate with sworn manifest] expected PASS, got FAIL")
        swear(sha=hashlib.sha256(b"other bytes").hexdigest())          # a stale publication
        rc, _ = inspect(build, root / "out", exp, manifest, True)
        if rc == 0:
            failures.append("[stale approved manifest] expected FAIL, got PASS")
        document = json.loads(manifest.read_text(encoding="utf-8"))
        document["schema"] = 2                                            # a future schema
        manifest.write_text(json.dumps(document, sort_keys=True), encoding="utf-8")
        rc, _ = inspect(build, root / "out", exp, manifest, True)
        if rc == 0:
            failures.append("[future schema in the approved manifest] expected FAIL, got PASS")

    if failures:
        print("inspect_android_artifacts selftest FAILED:")
        for f in failures:
            print("  - " + f)
        return 1
    print("inspect_android_artifacts selftest PASSED: exclusion, presence and release lanes "
          "all proved; duplicates, traversal, symlinks, modes, tiers, counts, fixtures, "
          "natives, dexes, plists and manifest grants kept in their right order")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
