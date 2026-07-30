-- Godstone Archive - indexes, FTS population and final optimisation.
--
-- Applied by content/ingest/build_archive.py AFTER all rows are inserted.
-- Building indexes last is measurably faster and produces a tighter file.

-- ---------------------------------------------------------------------------
-- 1. Ordinary indexes
-- ---------------------------------------------------------------------------

-- Retriever.loadChunk() and the 'read the whole procedure' navigation.
CREATE INDEX idx_chunks_document ON chunks (document_id, ordinal);

-- Browse-by-domain in the UI, and the domain hint passed into retrieval.
CREATE INDEX idx_documents_domain ON documents (domain, tier_min);

-- Critical-first ordering for the emergency shortcuts on the home screen.
CREATE INDEX idx_documents_critical ON documents (is_critical) WHERE is_critical = 1;

-- Media lookup when a source card is expanded.
CREATE INDEX idx_media_document ON media (document_id, kind);

-- ---------------------------------------------------------------------------
-- 2. Populate the external-content FTS index
--
-- A full rebuild rather than incremental triggers. The build is a batch job,
-- rebuild is faster, and it cannot leave the index half-synchronised if the
-- ingester is interrupted part way through.
-- ---------------------------------------------------------------------------
INSERT INTO chunks_fts (chunks_fts) VALUES ('rebuild');

-- Merge the index into as few b-tree segments as possible. Costs build time,
-- buys query latency on every single question the user ever asks.
INSERT INTO chunks_fts (chunks_fts, rank) VALUES ('merge', -500);

-- ---------------------------------------------------------------------------
-- 3. Statistics and compaction
-- ---------------------------------------------------------------------------
ANALYZE;

-- VACUUM last. The database is shipped read-only and never grows, so there is
-- no reason to carry a single free page onto a user's phone.
VACUUM;
