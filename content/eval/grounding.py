#!/usr/bin/env python3
"""Constraint C3 regression test, enforced at the retrieval layer.

    python -m content.eval.grounding --db /tmp/archive_light.db --strict

C3 says the model never answers from parametric memory alone. That promise is
kept in two places, and this checks the first one: if retrieval returns nothing
above the confidence floor, PromptBuilder is never even asked for a prompt and
the app says it does not know. A retrieval layer that confidently returns
loosely-related chunks for a question the corpus cannot answer defeats the
gate before generation is reached.

Checking at the retrieval layer rather than the generation layer means this
needs no model, no GPU and no weights, so it runs on an ordinary CI runner in
seconds and cannot be flaky in the way an LLM-judged eval always is.

WHAT THIS CANNOT SEE

The shipped retrievers fuse two rankings: BM25 over FTS5, and cosine over int8
embeddings. Embedding a query requires the model, and CI builds its archive
with --no-embed, so the vectors table is empty and only the lexical leg can
run here. This is therefore a necessary but not sufficient check: it catches a
corpus that has quietly grown material it should not have, and it catches an
FTS index whose sanitiser has become too permissive. It cannot catch a
semantic false positive. The full hybrid eval runs offline where the weights
live; see docs/packaging.

To keep that honest, the lexical-only score is computed with the same RRF
arithmetic the app uses, with one leg absent - which caps any single result at
0.5 rather than 1.0. The floor is compared against that same scale.
"""

from __future__ import annotations

import argparse
import re
import sqlite3
import sys
from pathlib import Path

# Must match android .../rag/Retriever.kt and ios .../GodstoneLLM/Retriever.swift.
RRF_K = 60.0
LEXICAL_CANDIDATES = 20

# Android RetrievalResult.CONFIDENCE_THRESHOLD. The iOS RagPipeline currently
# uses 0.28; that drift is tracked separately and is not this script's to fix.
CONFIDENCE_THRESHOLD = 0.35

# Words carrying no retrieval signal. Kept short on purpose: an over-eager stop
# list would hide exactly the false positives this script exists to find.
STOPWORDS = frozenset("""
a an the is are was were be been being do does did how what when where which
who whom why can could should would will shall may might must i you he she it
we they my your of to in on at for from with without and or but if then than
that this these those there here about into over under my me
""".split())


# ---------------------------------------------------------------------------
# Probes
#
# Out-of-corpus questions are plausible things a frightened person might ask a
# survival app that this app has deliberately not been given the material to
# answer. Several are near-misses on purpose - they share vocabulary with the
# corpus (water, radiation, bleeding) so that a retriever which has become too
# permissive lights up here rather than in production.
# ---------------------------------------------------------------------------
OUT_OF_CORPUS = (
    "What was the closing share price of Volkswagen on 3 March 1997?",
    "Who won the 1962 Eurovision Song Contest and with which song?",
    "What is the airspeed velocity of an unladen African swallow?",
    "Summarise the plot of the novel Middlemarch chapter by chapter.",
    "What dose of amoxicillin should I inject to treat radiation sickness?",
    "Which cryptocurrency should I buy before the grid comes back online?",
    "Give me the phone number of the nearest FEMA field office.",
    "What is my current GPS latitude and longitude?",
    "Translate the entire Book of Job into Old Church Slavonic.",
    "How do I synthesise methamphetamine from cold medicine?",
)

# Questions the corpus exists to answer. If these stop retrieving, the archive
# or the FTS index is broken, and a grounding check that only ever asserts
# 'nothing was found' would pass happily on an empty database.
IN_CORPUS = (
    "How do I stop severe bleeding from a leg wound?",
    "How long should I boil water to make it safe to drink?",
    "How do I shelter from radioactive fallout?",
)


def sanitise_fts(query: str) -> str:
    """Port of Retriever.sanitiseFts. Must stay byte-compatible with it.

    Strips FTS5 operators so a plain question cannot become a syntax error,
    then ORs the surviving terms. OR is what makes the recall leg forgiving -
    and it is exactly why an out-of-corpus probe can still match something.
    """
    cleaned = re.sub(r'["*():^-]', " ", query)
    terms = [t for t in re.split(r"\s+", cleaned) if t.strip()]
    return " OR ".join('"' + t + '"' for t in terms)


def content_terms(query: str) -> list[str]:
    """Distinctive words of a question, lowercased, stopwords removed."""
    cleaned = re.sub(r'["*():^-]', " ", query.lower())
    return [t for t in re.split(r"\W+", cleaned)
            if len(t) > 2 and t not in STOPWORDS]


def bm25_search(db: sqlite3.Connection, query: str, limit: int) -> list[tuple]:
    """The exact join both retrievers issue, with the same ordering."""
    sql = """
        SELECT c.chunk_id, d.title, c.section, c.text, bm25(chunks_fts) AS rank
        FROM chunks_fts
        JOIN chunks c ON c.chunk_id = chunks_fts.rowid
        JOIN documents d ON d.document_id = c.document_id
        WHERE chunks_fts MATCH ?
        ORDER BY rank
        LIMIT ?
    """
    return db.execute(sql, (sanitise_fts(query), limit)).fetchall()


def lexical_only_score(rank_index: int) -> float:
    """RRF score for a result at rank_index, with the semantic leg absent.

    Retriever normalises by maxPossible = 2 / (RRF_K + 1), the score a chunk
    would get by ranking first in both lists. With one list the best attainable
    is half of that, so a top lexical hit scores 0.5 - above the 0.35 floor.
    A raw score comparison would therefore pass every probe trivially, which is
    why coverage below is what actually decides the verdict.
    """
    return (1.0 / (RRF_K + rank_index + 1)) / (2.0 / (RRF_K + 1))


def coverage(query: str, chunk_text: str, section: str, title: str) -> float:
    """Fraction of the question's distinctive terms present in a result.

    This is the discriminator the OR-joined FTS query cannot provide on its
    own. A chunk about boiling water matching only the word 'water' in
    'radiation sickness water dose' covers one term in three and is correctly
    judged unsupporting.
    """
    terms = content_terms(query)
    if not terms:
        return 0.0
    hay = (chunk_text + " " + section + " " + title).lower()
    hits = sum(1 for t in terms if t in hay)
    return hits / len(terms)


# A result covering fewer than this fraction of a question's content words is
# not supporting evidence, whatever BM25 thought of it.
COVERAGE_FLOOR = 0.5


def evaluate(db: sqlite3.Connection, query: str) -> dict:
    rows = bm25_search(db, query, LEXICAL_CANDIDATES)
    if not rows:
        return {"query": query, "hits": 0, "best_score": 0.0,
                "best_coverage": 0.0, "best_title": None, "best_section": None}

    best_i, best_cov = 0, -1.0
    for i, (_cid, title, section, text, _rank) in enumerate(rows):
        cov = coverage(query, text, section, title)
        if cov > best_cov:
            best_i, best_cov = i, cov

    _cid, title, section, _text, _rank = rows[best_i]
    return {
        "query": query,
        "hits": len(rows),
        "best_score": lexical_only_score(best_i),
        "best_coverage": best_cov,
        "best_title": title,
        "best_section": section,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="C3 grounding regression over a built Archive"
    )
    parser.add_argument("--db", required=True, type=Path,
                        help="path to an archive_*.db built by build_archive")
    parser.add_argument("--strict", action="store_true",
                        help="treat warnings as failures")
    parser.add_argument("--coverage-floor", type=float, default=COVERAGE_FLOOR,
                        help="minimum supporting-term fraction (default 0.5)")
    args = parser.parse_args()

    if not args.db.exists():
        print("::error::archive not found: " + str(args.db), file=sys.stderr)
        print("hint: the grounding job needs the archive built by the content "
              "job; GitHub Actions does not share /tmp between jobs, so either "
              "rebuild it here or pass it as an uploaded artifact.",
              file=sys.stderr)
        return 1

    db = sqlite3.connect("file:" + str(args.db) + "?mode=ro", uri=True)
    db.execute("PRAGMA query_only = ON")

    chunks = db.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
    vectors = db.execute("SELECT COUNT(*) FROM vectors").fetchone()[0]
    tier = dict(db.execute("SELECT key, value FROM archive_meta")).get("tier")

    print("archive: " + str(args.db))
    print("tier=" + str(tier) + " chunks=" + str(chunks) + " vectors=" + str(vectors))
    if vectors == 0:
        print("mode: lexical only - vectors table empty (--no-embed build). "
              "Semantic false positives are NOT covered by this run.")
    print("floor: confidence " + str(CONFIDENCE_THRESHOLD)
          + ", coverage " + str(args.coverage_floor))
    print("")

    failures = 0
    warnings = 0

    print("out-of-corpus probes (must retrieve no supporting chunk)")
    for query in OUT_OF_CORPUS:
        r = evaluate(db, query)
        grounded = (r["best_coverage"] >= args.coverage_floor
                    and r["best_score"] >= CONFIDENCE_THRESHOLD)
        if grounded:
            failures += 1
            print("  FAIL  cov=" + format(r["best_coverage"], ".2f")
                  + " score=" + format(r["best_score"], ".2f")
                  + "  " + r["query"])
            print("        claimed support: " + str(r["best_title"])
                  + " / " + str(r["best_section"]))
        else:
            print("  ok    cov=" + format(r["best_coverage"], ".2f")
                  + " hits=" + str(r["hits"]) + "  " + r["query"][:58])

    print("")
    print("in-corpus controls (must retrieve supporting chunks)")
    for query in IN_CORPUS:
        r = evaluate(db, query)
        if r["hits"] == 0:
            failures += 1
            print("  FAIL  no results at all  " + r["query"])
        elif r["best_coverage"] < args.coverage_floor:
            warnings += 1
            print("  WARN  cov=" + format(r["best_coverage"], ".2f")
                  + "  " + r["query"])
            print("        best was: " + str(r["best_title"])
                  + " / " + str(r["best_section"]))
        else:
            print("  ok    cov=" + format(r["best_coverage"], ".2f")
                  + "  " + str(r["best_title"]))

    db.close()

    print("")
    print("probes=" + str(len(OUT_OF_CORPUS) + len(IN_CORPUS))
          + " failures=" + str(failures) + " warnings=" + str(warnings))

    if failures:
        print("::error::C3 grounding regression: " + str(failures)
              + " probe(s) failed", file=sys.stderr)
        return 1
    if warnings and args.strict:
        print("::error::" + str(warnings) + " warning(s) under --strict",
              file=sys.stderr)
        return 1

    print("ok: no out-of-corpus question found supporting evidence")
    return 0


if __name__ == "__main__":
    sys.exit(main())
