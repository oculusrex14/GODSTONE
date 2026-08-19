package io.godstone.mesh.identity

import android.database.Cursor
import net.zetetic.database.sqlcipher.SQLiteDatabase

/**
 * Canonical peer-identity database schema and guarded SQL contracts (ADR-003, Phase C8.2B).
 *
 * Physical separation:
 * - Database: `godstone_peer_identities.db` (physically independent peer database).
 * - Table: `peer_identities`.
 * - Schema version: 1.
 * - CHECK constraints enforce dimensions, uint32 domain, pending coupling, generation monotonicity,
 *   static key divergence, and revocation consistency.
 */
internal object PeerIdentitySchema {
    const val DB_NAME = "godstone_peer_identities.db"
    const val DB_VERSION = 1
    const val TABLE = "peer_identities"
    const val KEY_PREFS = "godstone_peer_identity_store_key"

    const val COL_NODE_ID = "node_id"
    const val COL_SIGNING_PUBLIC_KEY = "signing_public_key"
    const val COL_ACCEPTED_STATIC_DH_PUBLIC_KEY = "accepted_static_dh_public_key"
    const val COL_ACCEPTED_GENERATION = "accepted_generation"
    const val COL_TRUST_LEVEL = "trust_level"
    const val COL_PENDING_STATIC_DH_PUBLIC_KEY = "pending_static_dh_public_key"
    const val COL_PENDING_GENERATION = "pending_generation"

    const val CREATE_TABLE_SQL = """
        CREATE TABLE peer_identities (
            node_id BLOB PRIMARY KEY NOT NULL,
            signing_public_key BLOB NOT NULL,
            accepted_static_dh_public_key BLOB NOT NULL,
            accepted_generation INTEGER NOT NULL,
            trust_level INTEGER NOT NULL,
            pending_static_dh_public_key BLOB,
            pending_generation INTEGER,

            CHECK (length(node_id) = 16),
            CHECK (length(signing_public_key) = 32),
            CHECK (length(accepted_static_dh_public_key) = 32),

            CHECK (
                accepted_generation BETWEEN 0 AND 4294967295
            ),

            CHECK (
                trust_level IN (1,2,3)
            ),

            CHECK (
                (
                    pending_static_dh_public_key IS NULL
                    AND pending_generation IS NULL
                )
                OR
                (
                    pending_static_dh_public_key IS NOT NULL
                    AND pending_generation IS NOT NULL
                )
            ),

            CHECK (
                pending_static_dh_public_key IS NULL
                OR length(pending_static_dh_public_key) = 32
            ),

            CHECK (
                pending_generation IS NULL
                OR pending_generation BETWEEN 0 AND 4294967295
            ),

            CHECK (
                pending_generation IS NULL
                OR pending_generation > accepted_generation
            ),

            CHECK (
                pending_static_dh_public_key IS NULL
                OR pending_static_dh_public_key != accepted_static_dh_public_key
            ),

            CHECK (
                trust_level != 3
                OR (
                    pending_static_dh_public_key IS NULL
                    AND pending_generation IS NULL
                )
            )
        )
    """

    const val READ_RAW_SQL = """
        SELECT node_id, signing_public_key, accepted_static_dh_public_key,
               accepted_generation, trust_level, pending_static_dh_public_key,
               pending_generation
        FROM peer_identities
        WHERE node_id = ?
    """

    const val INSERT_FIRST_SEEN_SQL = """
        INSERT INTO peer_identities (
            node_id, signing_public_key, accepted_static_dh_public_key,
            accepted_generation, trust_level, pending_static_dh_public_key,
            pending_generation
        ) VALUES (?, ?, ?, ?, ?, NULL, NULL)
    """

    const val SET_INITIAL_PENDING_SQL = """
        UPDATE peer_identities
        SET pending_static_dh_public_key = ?, pending_generation = ?
        WHERE node_id = ?
          AND signing_public_key = ?
          AND accepted_static_dh_public_key = ?
          AND accepted_generation = ?
          AND trust_level = ?
          AND pending_static_dh_public_key IS NULL
          AND pending_generation IS NULL
    """

    const val ADVANCE_PENDING_SQL = """
        UPDATE peer_identities
        SET pending_static_dh_public_key = ?, pending_generation = ?
        WHERE node_id = ?
          AND signing_public_key = ?
          AND accepted_static_dh_public_key = ?
          AND accepted_generation = ?
          AND trust_level = ?
          AND pending_static_dh_public_key = ?
          AND pending_generation = ?
    """

    /**
     * Validate the exact table DDL fingerprint from sqlite_master on every open.
     * Normalized whitespace comparison prevents false mismatches due to indentation.
     */
    fun validateSchema(db: SQLiteDatabase) {
        val cursor: Cursor = db.rawQuery(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
            arrayOf(TABLE)
        )
        cursor.use {
            if (!it.moveToFirst()) {
                throw IllegalStateException("Peer identity table '$TABLE' missing in database")
            }
            val actualDdl = it.getString(0) ?: ""
            if (normalizeSql(actualDdl) != normalizeSql(CREATE_TABLE_SQL)) {
                throw IllegalStateException("Peer identity table DDL mismatch.\nExpected:\n$CREATE_TABLE_SQL\nActual:\n$actualDdl")
            }
        }
    }

    fun normalizeSql(sql: String): String =
        sql.trim().replace(Regex("\\s+"), " ")
}
