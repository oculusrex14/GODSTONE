#!/usr/bin/env python3
"""Create a harmless, visibly labelled Archive for development and package checks.

This is not a corpus build and cannot pass production asset staging. It contains
only instructions for navigating the app, no medical or survival guidance.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DOCUMENTS = (
    ("Development fixture: Using the Archive", "reference", (
        ("Development fixture", "DEVELOPMENT FIXTURE — NOT SURVIVAL GUIDANCE. These sample pages test the offline reader. They are not an approved survival archive."),
        ("Browse", "Open a document to read all its passages in order. Return to the document list using Back or All documents."),
        ("Search", "Search for lantern to find a sample passage. Choose Read full document to read the surrounding sections."),
    )),
    ("Development fixture: Finding a lantern", "equipment", (
        ("Sample entry", "The word lantern appears here so that a search has a predictable result. This page gives no equipment or emergency advice."),
        ("Full document context", "This second section lets a developer check that opening a search result displays the complete document, including surrounding context."),
    )),
    ("Development fixture: Offline reading", "reference", (
        ("On your device", "The Archive reader loads text from a local database. This fixture can be used to exercise browsing and search without a network connection."),
        ("Read comfortably", "Increase the device text size and check that headings, passages, search controls, and navigation remain readable."),
    )),
)


def build(output: Path, *, variant: str = "default", schema_version: int = 3) -> None:
    """Write one harmless development Archive.

    ``variant`` (T77) addeth a visible marker to every passage so that two
    variants of the same corpus are DISTINCT bytes -- a rehearsal of content
    replacement needeth two archives that differ, and a fixture that silently
    reproduced the first one would prove nothing. The default variant and the
    default schema version produce byte-identical output to the pre-T77 build.
    ``schema_version`` (T77) letteth a rehearsal declare an estate's schema,
    including an unknown FUTURE one that the release path must refuse.
    """
    if variant != "default":
        suffix = f" [variant {variant}]"
    else:
        suffix = ""
    documents = tuple(
        (f"{title}{suffix}", domain,
         tuple((section, f"{text}{suffix}") for section, text in passages))
        for title, domain, passages in DOCUMENTS)
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, candidate_name = tempfile.mkstemp(prefix=".archive-fixture-", suffix=".db", dir=output.parent)
    os.close(fd)
    candidate = Path(candidate_name)
    try:
        with sqlite3.connect(candidate) as db:
            db.executescript((ROOT / "content/db/schema.sql").read_text())
            chunk_id = 0
            for document_id, (title, domain, passages) in enumerate(documents, 1):
                db.execute("INSERT INTO documents (document_id,title,domain,source_id,licence,revision) VALUES (?,?,?,?,?,?)",
                           (document_id, title, domain, "development-fixture", "TEST-ONLY", "1"))
                for ordinal, (section, text) in enumerate(passages):
                    chunk_id += 1
                    db.execute("INSERT INTO chunks VALUES (?,?,?,?,?,?)",
                               (chunk_id, document_id, ordinal, section, text, len(text.split())))
            metadata = {
                "schema_version": str(schema_version), "tier": "LIGHT",
                "development_fixture": "true",
                "document_count": str(len(documents)), "chunk_count": str(chunk_id),
                "corpus_sha256": hashlib.sha256(json.dumps(documents, ensure_ascii=False).encode()).hexdigest(),
            }
            if variant != "default":
                metadata["development_fixture_variant"] = variant
            db.executemany("INSERT INTO archive_meta VALUES (?,?)", sorted(metadata.items()))
            db.executescript((ROOT / "content/db/indexes.sql").read_text())
            assert db.execute("SELECT count(*) FROM chunks_fts WHERE chunks_fts MATCH 'lantern'").fetchone()[0] > 0
            assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        with candidate.open("rb") as stream:
            os.fsync(stream.fileno())
        os.replace(candidate, output)
    finally:
        candidate.unlink(missing_ok=True)
    print(f"Development fixture only: {output} ({len(documents)} documents, {chunk_id} passages, "
          f"variant {variant}, schema {schema_version})")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--variant", default="default",
                        help="T77: a label that maketh this build DISTINCT bytes from another "
                             "variant of the same corpus (default: byte-identical to the old build)")
    parser.add_argument("--schema-version", type=int, default=3,
                        help="T77: the schema_version this fixture carrieth in archive_meta")
    args = parser.parse_args()
    build(args.out, variant=args.variant, schema_version=args.schema_version)


if __name__ == "__main__":
    main()
