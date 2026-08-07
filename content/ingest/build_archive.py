#!/usr/bin/env python3
"""Build a Godstone Archive database for one tier.

    python -m content.ingest.build_archive --tier LIGHT --out dist/archive_light.db

The build is deterministic: the same corpus and the same tier always produce
byte-identical chunk text, chunk ordering and chunk ids. That is what makes
corpus_sha256 meaningful, and it is what lets a user verify that the database
on their phone is the one that was published (constraint C2 - no accounts, so
a hash is the only trust anchor we have).

Nothing here touches the network (C1). Sources are vendored under content/seed
and models are already on disk; if a path is missing the build fails loudly
rather than fetching anything.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import sys
from dataclasses import dataclass
from pathlib import Path

import yaml

from .chunker import Chunk, chunk_document
from .embedder import Embedder
from content.release_gate import validate_release_corpus

SCHEMA_VERSION = 3

ROOT = Path(__file__).resolve().parents[2]
SEED = ROOT / "content" / "seed"
DB_DIR = ROOT / "content" / "db"


# Mirrors the tier table in 00_README section 3 and docs/packaging/TIERS.md.
# These three dicts are the single source of truth for what ships in a build;
# if they disagree with the Gradle flavours (tab 03) or Tier.swift (tab 06) the
# app will look for a model file that is not there.
TIERS = {
    "LIGHT": {
        "model_file": "qwen3-0.6b-q4km.gguf",
        "embed_model": "bge-small-en-v1.5-q8.gguf",
        "embed_dim": 384,
        "context_tokens": 2048,
        "chunk_tokens": 320,
        "chunk_overlap": 48,
        "target_chunks": 40_000,
        "db_name": "archive_light.db",
    },
    "MEDIUM": {
        "model_file": "qwen3-1.7b-q4km.gguf",
        "embed_model": "bge-small-en-v1.5-q8.gguf",
        "embed_dim": 384,
        "context_tokens": 4096,
        "chunk_tokens": 384,
        "chunk_overlap": 64,
        "target_chunks": 150_000,
        "db_name": "archive_medium.db",
    },
    "LARGE": {
        "model_file": "qwen3-4b-q5km.gguf",
        "embed_model": "bge-base-en-v1.5-q8.gguf",
        "embed_dim": 768,
        "context_tokens": 8192,
        "chunk_tokens": 448,
        "chunk_overlap": 64,
        "target_chunks": 400_000,
        "db_name": "archive_large.db",
    },
}

# A LIGHT database contains only LIGHT documents; MEDIUM contains LIGHT and
# MEDIUM, and so on. Tier is cumulative, never exclusive.
TIER_RANK = {"LIGHT": 0, "MEDIUM": 1, "LARGE": 2}

REQUIRED_FRONT_MATTER = ("title", "domain", "source", "licence", "revision")

# Audit A-09. A release archive may not contain clinically unreviewed material.
# The check lives in the BUILD, not in a checklist, because a checklist is a
# claim and a build step is a control -- the distinction this whole repository
# is about. `--release` refuses; the default build warns and continues, so
# development against worked examples stays possible.
REVIEW_FIELDS = ("reviewed_by", "reviewed_on")
UNREVIEWED_SENTINEL = "UNREVIEWED-EXAMPLE"


@dataclass
class Document:
    path: Path
    title: str
    domain: str
    source_id: str
    licence: str
    revision: str
    tier_min: str
    reading_level: int
    is_critical: bool
    reviewed_by: str
    reviewed_on: str
    body: str


def parse_front_matter(path: Path) -> Document:
    """Read a seed markdown file with YAML front matter.

    Fails hard on a missing key. An unattributed document is a licence
    violation and an uncitable answer, and both are unacceptable (C3).
    """
    raw = path.read_text(encoding="utf-8")
    if not raw.startswith("---"):
        raise ValueError(f"{path}: missing YAML front matter")

    _, fm_text, body = raw.split("---", 2)
    fm = yaml.safe_load(fm_text) or {}

    missing = [k for k in REQUIRED_FRONT_MATTER if k not in fm]
    if missing:
        raise ValueError(f"{path}: front matter missing {missing}")

    reading_level = int(fm.get("reading_level", 8))
    if reading_level > 9:
        print(f"warning: {path} reads at grade {reading_level}; "
              f"aim for 9 or below (C7)", file=sys.stderr)

    return Document(
        path=path,
        title=str(fm["title"]).strip(),
        domain=str(fm["domain"]).strip(),
        source_id=str(fm["source"]).strip(),
        licence=str(fm["licence"]).strip(),
        revision=str(fm["revision"]).strip(),
        tier_min=str(fm.get("tier_min", "LIGHT")).strip().upper(),
        reading_level=reading_level,
        is_critical=bool(fm.get("critical", False)),
        reviewed_by=str(fm.get("reviewed_by", UNREVIEWED_SENTINEL)).strip(),
        reviewed_on=str(fm.get("reviewed_on", "")).strip(),
        body=body.strip(),
    )


def load_corpus(tier: str) -> list[Document]:
    """Collect every seed document that belongs in this tier.

    Sorted by path so document_id and chunk_id are stable across machines and
    across runs. Filesystem iteration order is not, and a nondeterministic id
    would make corpus_sha256 worthless.
    """
    taxonomy = yaml.safe_load((SEED / "taxonomy.yaml").read_text(encoding="utf-8"))
    known_domains = {d["id"] for d in taxonomy["domains"]}

    limit = TIER_RANK[tier]
    docs: list[Document] = []

    for path in sorted((SEED / "docs").rglob("*.md")):
        doc = parse_front_matter(path)
        if doc.domain not in known_domains:
            raise ValueError(f"{path}: unknown domain {doc.domain!r}")
        if TIER_RANK[doc.tier_min] <= limit:
            docs.append(doc)

    if not docs:
        raise SystemExit(f"no documents qualify for tier {tier}")
    return docs


def corpus_digest(docs: list[Document], chunks: list[Chunk]) -> str:
    """Hash of everything that ends up in the database.

    Covers document metadata and chunk text but deliberately not the embedding
    bytes: a different embedding model produces the same knowledge and should
    not look like a different corpus.
    """
    h = hashlib.sha256()
    for doc in docs:
        h.update(doc.title.encode("utf-8"))
        h.update(doc.revision.encode("utf-8"))
        h.update(doc.source_id.encode("utf-8"))
    for ch in chunks:
        h.update(ch.section.encode("utf-8"))
        h.update(ch.text.encode("utf-8"))
    return h.hexdigest()


def build(tier: str, out_path: Path, embed: bool = True,
          release: bool = False) -> None:
    cfg = TIERS[tier]
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if out_path.exists():
        out_path.unlink()

    docs = load_corpus(tier)
    print(f"tier {tier}: {len(docs)} documents")

    # ---- editorial gate (A-09) -------------------------------------------
    unreviewed = [d for d in docs if d.reviewed_by == UNREVIEWED_SENTINEL]
    if unreviewed:
        names = ", ".join(d.path.name for d in unreviewed)
        if release:
            raise SystemExit(
                f"::error::REFUSING to build a release archive: {len(unreviewed)} "
                f"document(s) have no clinical review ({names}). See "
                f"docs/editorial/REVIEW.md. A release archive may not carry "
                f"unreviewed medical instructions.")
        print(f"warning: {len(unreviewed)} document(s) are UNREVIEWED worked "
              f"examples ({names}). --release would refuse this build.",
              file=sys.stderr)

    release_validation = None
    if release:
        release_validation = validate_release_corpus(
            docs,
            ROOT / "content" / "manifests" / "documents",
            evidence_root=ROOT / "content" / "manifests",
        )
        print(f"validated {len(release_validation.documents)} production document manifest(s)")

    conn = sqlite3.connect(out_path)
    conn.executescript((DB_DIR / "schema.sql").read_text(encoding="utf-8"))

    all_chunks: list[Chunk] = []
    chunk_id = 0

    for document_id, doc in enumerate(docs, start=1):
        conn.execute(
            "INSERT INTO documents (document_id, title, domain, source_id, "
            "licence, revision, tier_min, reading_level, is_critical) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (document_id, doc.title, doc.domain, doc.source_id, doc.licence,
             doc.revision, doc.tier_min, doc.reading_level, int(doc.is_critical)),
        )

        chunks = chunk_document(
            doc.body,
            max_tokens=cfg["chunk_tokens"],
            overlap_tokens=cfg["chunk_overlap"],
        )
        for ordinal, ch in enumerate(chunks):
            chunk_id += 1
            ch.chunk_id = chunk_id
            ch.document_id = document_id
            conn.execute(
                "INSERT INTO chunks (chunk_id, document_id, ordinal, section, "
                "text, token_count) VALUES (?, ?, ?, ?, ?, ?)",
                (chunk_id, document_id, ordinal, ch.section, ch.text, ch.token_count),
            )
            all_chunks.append(ch)

    print(f"tier {tier}: {len(all_chunks)} chunks "
          f"(target ~{cfg['target_chunks']:,})")

    if embed:
        embedder = Embedder(model_file=cfg["embed_model"], dim=cfg["embed_dim"])
        for ch in all_chunks:
            # The heading path is prepended before embedding. 'Apply above the
            # wound' is nearly meaningless on its own; with its section title
            # it retrieves correctly.
            vec, scale = embedder.encode_int8(f"{ch.section}\n{ch.text}")
            conn.execute(
                "INSERT INTO vectors (chunk_id, dim, scale, vec) VALUES (?, ?, ?, ?)",
                (ch.chunk_id, cfg["embed_dim"], scale, vec),
            )
        embedder.close()

    media_path = SEED / "media_manifest.yaml"
    if media_path.exists():
        insert_media(conn, media_path, tier, {d.source_id: i + 1
                                              for i, d in enumerate(docs)})

    digest = corpus_digest(docs, all_chunks)
    meta = {
        "schema_version": str(SCHEMA_VERSION),
        "tier": tier,
        "embed_dim": str(cfg["embed_dim"]),
        "embed_model": cfg["embed_model"],
        "model_file": cfg["model_file"],
        "context_tokens": str(cfg["context_tokens"]),
        "document_count": str(len(docs)),
        "chunk_count": str(len(all_chunks)),
        "corpus_sha256": digest,
    }
    if release_validation is not None:
        meta.update({
            "source_manifest_sha256": release_validation.source_set_sha256,
            "review_manifest_sha256": release_validation.review_set_sha256,
            "release_manifest_set_sha256": release_validation.manifest_set_sha256,
        })

    conn.executemany("INSERT INTO archive_meta (key, value) VALUES (?, ?)",
                     sorted(meta.items()))

    conn.executescript((DB_DIR / "indexes.sql").read_text(encoding="utf-8"))
    conn.commit()
    conn.close()

    size_mb = out_path.stat().st_size / (1024 * 1024)
    print(f"wrote {out_path} ({size_mb:.1f} MB)")
    print(f"corpus_sha256 {digest}")


def insert_media(conn: sqlite3.Connection, manifest: Path, tier: str,
                 doc_ids: dict[str, int]) -> None:
    """Register media that this tier is allowed to carry.

    LIGHT ships diagrams only, MEDIUM adds voice and 480p, LARGE adds 1080p.
    Media files themselves are copied by scripts in tab 11; this only indexes.
    """
    allowed = {
        "LIGHT": {"diagram"},
        "MEDIUM": {"diagram", "audio", "video_480"},
        "LARGE": {"diagram", "audio", "video_480", "video_1080"},
    }[tier]

    entries = yaml.safe_load(manifest.read_text(encoding="utf-8")) or {}
    media_id = 0
    for item in entries.get("media", []):
        if item["kind"] not in allowed:
            continue
        document_id = doc_ids.get(item["source"])
        if document_id is None:
            continue
        media_id += 1
        conn.execute(
            "INSERT INTO media (media_id, document_id, kind, relpath, caption, "
            "bytes, sha256) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (media_id, document_id, item["kind"], item["path"],
             item["caption"], int(item.get("bytes", 0)), item.get("sha256", "")),
        )


def main() -> None:
    ap = argparse.ArgumentParser(description="Build a Godstone Archive database")
    ap.add_argument("--tier", required=True, choices=sorted(TIERS))
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--no-embed", action="store_true",
                    help="skip embeddings; lexical search only. Fast smoke test.")
    ap.add_argument("--print-config", action="store_true")
    ap.add_argument("--release", action="store_true",
                    help="refuse to build if any document lacks clinical review")
    args = ap.parse_args()

    if args.print_config:
        print(json.dumps(TIERS[args.tier], indent=2))
        return

    out = args.out or (ROOT / "dist" / TIERS[args.tier]["db_name"])
    build(args.tier, out, embed=not args.no_embed, release=args.release)


if __name__ == "__main__":
    main()
