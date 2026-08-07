from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from content.archive_manifest import (
    create_manifest,
    generate_test_keypair,
    load_private_key,
    load_trust_store,
    verify_manifest,
)


class ArchiveManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.archive = self.root / "archive_light.db"
        conn = sqlite3.connect(self.archive)
        conn.executescript("""
            CREATE TABLE archive_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO archive_meta VALUES('schema_version','3');
            INSERT INTO archive_meta VALUES('tier','LIGHT');
            CREATE TABLE documents(document_id INTEGER PRIMARY KEY, title TEXT);
            CREATE TABLE chunks(chunk_id INTEGER PRIMARY KEY, document_id INTEGER, text TEXT);
            CREATE TABLE vectors(chunk_id INTEGER PRIMARY KEY, vec BLOB);
            CREATE VIRTUAL TABLE chunks_fts USING fts5(text);
            INSERT INTO documents VALUES(1,'Fixture');
            INSERT INTO chunks VALUES(1,1,'safe fixture');
            INSERT INTO chunks_fts(rowid,text) VALUES(1,'safe fixture');
        """)
        conn.commit(); conn.close()
        self.private = self.root / "test.key"
        self.trust = self.root / "trust.json"
        generate_test_keypair(self.private, self.trust)
        self.manifest = self.root / "archive.manifest.json"
        create_manifest(
            self.archive, self.manifest, tier="LIGHT", archive_schema=3,
            source_manifest_sha256="1" * 64,
            review_manifest_sha256="2" * 64,
            corpus_manifest_sha256="3" * 64,
            build_tool_commit="b7daf5aceb642277807e9bfbe3bbb486112a64ec",
            private_key=load_private_key(self.private), key_id="TEST-ONLY",
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def verify(self, **kwargs):
        return verify_manifest(
            self.manifest, self.archive, load_trust_store(self.trust),
            expected_tier=kwargs.get("tier", "LIGHT"), expected_archive_schema=3,
        )

    def test_valid_signed_archive_passes(self) -> None:
        self.assertTrue(self.verify().ok)

    def test_archive_mutation_is_detected(self) -> None:
        with self.archive.open("ab") as stream:
            stream.write(b"tamper")
        result = self.verify()
        self.assertFalse(result.ok)
        self.assertTrue(any("SHA-256" in item or "size" in item for item in result.errors))

    def test_wrong_tier_is_detected(self) -> None:
        result = self.verify(tier="MEDIUM")
        self.assertFalse(result.ok)
        self.assertIn("archive tier does not match the application variant", result.errors)

    def test_manifest_mutation_breaks_signature(self) -> None:
        data = json.loads(self.manifest.read_text(encoding="utf-8"))
        data["counts"]["chunks"] = 99
        self.manifest.write_text(json.dumps(data), encoding="utf-8")
        result = self.verify()
        self.assertFalse(result.ok)
        self.assertTrue(any("signature" in item for item in result.errors))


if __name__ == "__main__":
    unittest.main()
