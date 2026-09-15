"""Synthetic, non-medical archive fixtures; these are not release approvals."""
from pathlib import Path
import contextlib
import sqlite3

ROOT = Path(__file__).resolve().parents[2]


def write_archive(path: Path, *, reviewed: bool = False) -> None:
    with contextlib.closing(sqlite3.connect(path)) as db, db:
        db.executescript((ROOT / "content/db/schema.sql").read_text())
        db.execute("INSERT INTO documents VALUES(1, 'Fixture', 'reference', 'fixture', 'CC0', '1', 'LIGHT', 8, 0)")
        db.execute("INSERT INTO chunks VALUES(1, 1, 0, 'Fixture section', 'Synthetic fixture content', 6)")
        metadata = {
            "schema_version": "3", "tier": "LIGHT", "document_count": "1",
            "chunk_count": "1", "corpus_sha256": "4" * 64,
        }
        if reviewed:
            # This fixture exercises the provenance contract without asserting
            # that any real clinical material has received approval.
            metadata.update({
                "source_manifest_sha256": "1" * 64,
                "review_manifest_sha256": "2" * 64,
                "release_manifest_set_sha256": "3" * 64,
                # GS-CONTENT-001 (convergence, round 99): the final chunk approvals became part
                # of the provenance a RELEASE archive must carry, and the coverage count is now
                # bound to the archive's OWN chunk cardinality. The fixture therefore carrieth
                # BOTH, with the coverage count matching the ONE chunk it holdeth -- exactly as
                # the independent probe installed them. It remaineth a FIXTURE: the digest is
                # synthetic and it asserteth nothing about any real review.
                "approvals_sha256": "5" * 64,
                "approvals_covered": "1",
            })
        db.executemany("INSERT INTO archive_meta VALUES(?, ?)", metadata.items())
        db.executescript((ROOT / "content/db/indexes.sql").read_text())
