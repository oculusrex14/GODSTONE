-- Godstone Archive - canonical SQLite schema.
--
-- The Archive is built once on a workstation and shipped read-only inside the
-- app bundle. Nothing in either app ever writes to it, so every choice below
-- optimises for read speed, small size and corruption resistance, and never
-- for write throughput.
--
-- Consumed verbatim by:
--     android/llm/src/main/java/io/godstone/llm/rag/Retriever.kt   (tab 05)
--     ios/Godstone/Sources/GodstoneLLM/Retriever.swift             (tab 08)
--
-- Both retrievers issue byte-identical SQL. If a column is renamed here it must
-- be renamed in both, or one platform silently stops answering while the other
-- keeps working - the worst possible failure for a life-safety product.

PRAGMA page_size = 4096;
PRAGMA encoding  = 'UTF-8';

-- ---------------------------------------------------------------------------
-- documents - one row per manual, article or procedure.
-- ---------------------------------------------------------------------------
CREATE TABLE documents (
    document_id   INTEGER PRIMARY KEY,
    title         TEXT    NOT NULL,
    domain        TEXT    NOT NULL,
    source_id     TEXT    NOT NULL,
    licence       TEXT    NOT NULL,
    revision      TEXT    NOT NULL,

    -- Lowest tier that ships this document. A LIGHT build contains only
    -- tier_min = 'LIGHT' rows, so one pipeline emits all three SKUs.
    tier_min      TEXT    NOT NULL DEFAULT 'LIGHT'
                  CHECK (tier_min IN ('LIGHT', 'MEDIUM', 'LARGE')),

    -- Grade level of the prose. Survival instructions are read by frightened
    -- people in bad light; the ingester warns above 9.
    reading_level INTEGER NOT NULL DEFAULT 8,

    -- Life-critical procedures (haemorrhage, airway, fallout, hypothermia).
    -- The UI surfaces these first and the eval harness in tab 12 requires a
    -- higher retrieval recall on them.
    is_critical   INTEGER NOT NULL DEFAULT 0 CHECK (is_critical IN (0, 1))
);

-- ---------------------------------------------------------------------------
-- chunks - the retrieval unit. One row per passage.
-- ---------------------------------------------------------------------------
CREATE TABLE chunks (
    chunk_id    INTEGER PRIMARY KEY,
    document_id INTEGER NOT NULL REFERENCES documents(document_id),

    -- Position within the parent document, so the UI can show a chunk in
    -- context and offer 'read the whole procedure'.
    ordinal     INTEGER NOT NULL,

    -- Heading path, e.g. 'Treatment > Tourniquet application'. Carried into
    -- the Citation shown to the user, so a source card names the exact
    -- section rather than only the manual.
    section     TEXT    NOT NULL,

    text        TEXT    NOT NULL,
    token_count INTEGER NOT NULL,

    UNIQUE (document_id, ordinal)
);

-- ---------------------------------------------------------------------------
-- chunks_fts - FTS5 lexical index (BM25).
--
-- External-content table: the text lives once in chunks and FTS5 stores only
-- the index. That saves roughly 40 percent of the database size, which at
-- LARGE tier is several hundred megabytes of somebody's phone.
--
-- content_rowid = chunk_id is what makes the retriever join
--     JOIN chunks c ON c.chunk_id = chunks_fts.rowid
-- correct. Do not change it without changing both retrievers.
-- ---------------------------------------------------------------------------
CREATE VIRTUAL TABLE chunks_fts USING fts5(
    text,
    section,
    content       = 'chunks',
    content_rowid = 'chunk_id',
    tokenize      = "porter unicode61 remove_diacritics 2",
    prefix        = '2 3 4'
);

-- ---------------------------------------------------------------------------
-- vectors - int8 quantised embeddings for semantic search.
--
-- Stored as a flat BLOB of dim signed bytes. The retriever brute-force scans
-- this table: at LARGE tier that is ~400k dot products over 768 dims, about
-- 150 ms on a mid-range 2023 SoC. An ANN index would be faster and would add
-- an entire class of index-corruption failures for a saving nobody can feel.
-- Simplicity is a survival feature.
--
-- scale is the value that was mapped to 127 during quantisation. Cosine
-- similarity is scale invariant so the retrievers ignore it, but it is stored
-- so a vector can be dequantised exactly for the offline eval in tab 12.
-- ---------------------------------------------------------------------------
CREATE TABLE vectors (
    chunk_id INTEGER PRIMARY KEY REFERENCES chunks(chunk_id),
    dim      INTEGER NOT NULL,
    scale    REAL    NOT NULL,
    vec      BLOB    NOT NULL
);

-- ---------------------------------------------------------------------------
-- media - diagrams, audio and video attached to a document.
-- Files live beside the database in the bundle; only metadata is indexed.
-- ---------------------------------------------------------------------------
CREATE TABLE media (
    media_id    INTEGER PRIMARY KEY,
    document_id INTEGER NOT NULL REFERENCES documents(document_id),
    kind        TEXT    NOT NULL
                CHECK (kind IN ('diagram', 'audio', 'video_480', 'video_1080')),
    relpath     TEXT    NOT NULL,
    caption     TEXT    NOT NULL,
    bytes       INTEGER NOT NULL,
    sha256      TEXT    NOT NULL
);

-- ---------------------------------------------------------------------------
-- archive_meta - single provenance record, one row per key.
--
-- Read on first launch. If schema_version does not match what the app expects,
-- or corpus_sha256 does not match the shipped corpus, the app falls back to
-- browse-only mode and says so rather than serving a half-built index (C5).
-- ---------------------------------------------------------------------------
CREATE TABLE archive_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Convenience view. Keeps the citation join in one place instead of having it
-- duplicated across two retrievers written in two different languages.
CREATE VIEW chunk_citations AS
SELECT c.chunk_id,
       c.document_id,
       c.section,
       c.ordinal,
       c.text,
       d.title,
       d.domain,
       d.source_id,
       d.licence,
       d.is_critical
FROM chunks c
JOIN documents d ON d.document_id = c.document_id;
