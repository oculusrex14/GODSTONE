package io.godstone.mesh.identity

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import net.zetetic.database.sqlcipher.SQLiteDatabase
import net.zetetic.database.sqlcipher.SQLiteOpenHelper
import net.zetetic.database.sqlcipher.SQLiteStatement
import java.io.File
import java.security.SecureRandom

/**
 * Raw durable row loaded directly from the database (ADR-003, Phase C8.2B).
 *
 * Immutability:
 * - Constructor and getters perform defensive copying of all ByteArrays.
 * - Backing storage uses private arrays for equals and hashCode calculations.
 * - Generation values use signed Long to avoid premature truncation before strict validation.
 */
internal class PeerIdentityRow(
    nodeIdRaw: ByteArray,
    signingPublicKeyRaw: ByteArray,
    acceptedStaticDhPublicKeyRaw: ByteArray,
    val acceptedGenerationRaw: Long,
    val trustCodeRaw: Int,
    pendingStaticDhPublicKeyRaw: ByteArray? = null,
    val pendingGenerationRaw: Long? = null,
) {
    private val _nodeIdRaw: ByteArray = nodeIdRaw.copyOf()
    private val _signingPublicKeyRaw: ByteArray = signingPublicKeyRaw.copyOf()
    private val _acceptedStaticDhPublicKeyRaw: ByteArray = acceptedStaticDhPublicKeyRaw.copyOf()
    private val _pendingStaticDhPublicKeyRaw: ByteArray? = pendingStaticDhPublicKeyRaw?.copyOf()

    val nodeIdRaw: ByteArray get() = _nodeIdRaw.copyOf()
    val signingPublicKeyRaw: ByteArray get() = _signingPublicKeyRaw.copyOf()
    val acceptedStaticDhPublicKeyRaw: ByteArray get() = _acceptedStaticDhPublicKeyRaw.copyOf()
    val pendingStaticDhPublicKeyRaw: ByteArray? get() = _pendingStaticDhPublicKeyRaw?.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is PeerIdentityRow) return false
        return _nodeIdRaw.contentEquals(other._nodeIdRaw) &&
               _signingPublicKeyRaw.contentEquals(other._signingPublicKeyRaw) &&
               _acceptedStaticDhPublicKeyRaw.contentEquals(other._acceptedStaticDhPublicKeyRaw) &&
               acceptedGenerationRaw == other.acceptedGenerationRaw &&
               trustCodeRaw == other.trustCodeRaw &&
               ((_pendingStaticDhPublicKeyRaw == null && other._pendingStaticDhPublicKeyRaw == null) ||
                (_pendingStaticDhPublicKeyRaw != null && other._pendingStaticDhPublicKeyRaw != null &&
                 _pendingStaticDhPublicKeyRaw.contentEquals(other._pendingStaticDhPublicKeyRaw))) &&
               pendingGenerationRaw == other.pendingGenerationRaw
    }

    override fun hashCode(): Int {
        var result = _nodeIdRaw.contentHashCode()
        result = 31 * result + _signingPublicKeyRaw.contentHashCode()
        result = 31 * result + _acceptedStaticDhPublicKeyRaw.contentHashCode()
        result = 31 * result + acceptedGenerationRaw.hashCode()
        result = 31 * result + trustCodeRaw.hashCode()
        result = 31 * result + (_pendingStaticDhPublicKeyRaw?.contentHashCode() ?: 0)
        result = 31 * result + (pendingGenerationRaw?.hashCode() ?: 0)
        return result
    }
}

/**
 * Storage abstraction for peer identity persistence (ADR-003, Phase C8.2B).
 */
internal interface PeerIdentityStore : AutoCloseable {
    fun <T> inImmediateTransaction(block: (PeerIdentityStore) -> T): T

    fun readRaw(nodeId: ByteArray): PeerIdentityRow?

    fun insertFirstSeen(
        nodeId: ByteArray,
        signingPub: ByteArray,
        acceptedStatic: ByteArray,
        acceptedGeneration: Long,
        trustCode: Int
    ): Int

    fun setInitialPendingGuarded(
        nodeId: ByteArray,
        signingPub: ByteArray,
        acceptedStatic: ByteArray,
        acceptedGeneration: Long,
        trustLevel: Int,
        newPendingStatic: ByteArray,
        newPendingGeneration: Long
    ): Int

    fun advancePendingGuarded(
        nodeId: ByteArray,
        signingPub: ByteArray,
        acceptedStatic: ByteArray,
        acceptedGeneration: Long,
        trustLevel: Int,
        oldPendingStatic: ByteArray,
        oldPendingGeneration: Long,
        newPendingStatic: ByteArray,
        newPendingGeneration: Long
    ): Int

    fun approvePendingRotationGuarded(
        nodeId: ByteArray,
        signingPub: ByteArray,
        acceptedStatic: ByteArray,
        acceptedGeneration: Long,
        trustLevel: Int,
        expectedPendingStatic: ByteArray,
        expectedPendingGeneration: Long
    ): Int

    fun revokePeerGuarded(
        nodeId: ByteArray,
        signingPub: ByteArray,
        acceptedStatic: ByteArray,
        acceptedGeneration: Long,
        currentTrustLevel: Int,
        oldPendingStatic: ByteArray?,
        oldPendingGeneration: Long?
    ): Int

    override fun close()
}

/**
 * Key-state resolution helper for peer identity database encryption keys (ADR-003, Phase C8.2B.1).
 *
 * Matrix:
 * K1. key absent + DB absent -> generate 32 bytes, commit synchronously, return key.
 * K2. key present + DB absent -> decode exact 32 bytes, return key (generator NOT called).
 * K3. key present + DB present -> decode exact 32 bytes, return key (generator NOT called).
 * K4. key absent + DB present -> FAIL CLOSED (generator NOT called, persistence NOT called).
 * K5. malformed Base64 -> FAIL CLOSED.
 * K6. decoded key length < 32 (e.g. 31) -> FAIL CLOSED.
 * K7. decoded key length > 32 (e.g. 33) -> FAIL CLOSED.
 * K8. synchronous persistence fails (returns false) -> FAIL CLOSED.
 */
internal object PeerStoreKeyState {
    fun resolve(
        dbExists: Boolean,
        storedEncodedKey: String?,
        generate: () -> ByteArray,
        persist: (String) -> Boolean
    ): ByteArray {
        if (storedEncodedKey != null) {
            val decoded: ByteArray
            try {
                decoded = java.util.Base64.getDecoder().decode(storedEncodedKey)
            } catch (e: Exception) {
                throw IllegalStateException("Malformed Base64 in peer identity key preference", e)
            }
            if (decoded.size != 32) {
                throw IllegalStateException(
                    "Stored peer identity key length must be 32 bytes, got ${decoded.size}"
                )
            }
            return decoded
        }

        // Stored key is absent: if DB file already exists, we must fail closed!
        if (dbExists) {
            throw IllegalStateException(
                "Peer identity database exists but encryption key is missing; refusing to recreate key"
            )
        }

        // Fresh state: generate 32 CSPRNG bytes and commit synchronously
        val key = generate()
        if (key.size != 32) {
            throw IllegalStateException("Generated key length must be 32 bytes, got ${key.size}")
        }
        val encoded = java.util.Base64.getEncoder().encodeToString(key)
        val committed = persist(encoded)
        if (!committed) {
            throw IllegalStateException("Failed to synchronously commit peer identity store key")
        }
        return key
    }
}

/**
 * Production Android peer identity store backed by dedicated SQLCipher encryption at rest (ADR-003, Phase C8.2B).
 */
internal class SqlcipherPeerIdentityStore(ctx: Context) : PeerIdentityStore {
    private val helper: SQLiteOpenHelper

    init {
        // Explicit SQLCipher native library loading
        System.loadLibrary("sqlcipher")
        val passphrase = getOrCreatePassphrase(ctx)
        helper = Helper(ctx, passphrase)
    }

    override fun <T> inImmediateTransaction(block: (PeerIdentityStore) -> T): T {
        val db = helper.writableDatabase
        db.beginTransaction()
        try {
            val result = block(this)
            db.setTransactionSuccessful()
            return result
        } finally {
            db.endTransaction()
        }
    }

    override fun readRaw(nodeId: ByteArray): PeerIdentityRow? {
        val db = helper.readableDatabase
        return db.rawQuery(PeerIdentitySchema.READ_RAW_SQL, arrayOf(nodeId)).use { cursor ->
            if (!cursor.moveToFirst()) null
            else {
                val nodeIdBytes = cursor.getBlob(0)
                val signPubBytes = cursor.getBlob(1)
                val accStaticBytes = cursor.getBlob(2)
                val accGen = cursor.getLong(3)
                val trustCode = cursor.getInt(4)
                val pendStaticBytes = if (cursor.isNull(5)) null else cursor.getBlob(5)
                val pendGen = if (cursor.isNull(6)) null else cursor.getLong(6)

                PeerIdentityRow(
                    nodeIdRaw = nodeIdBytes,
                    signingPublicKeyRaw = signPubBytes,
                    acceptedStaticDhPublicKeyRaw = accStaticBytes,
                    acceptedGenerationRaw = accGen,
                    trustCodeRaw = trustCode,
                    pendingStaticDhPublicKeyRaw = pendStaticBytes,
                    pendingGenerationRaw = pendGen
                )
            }
        }
    }

    override fun insertFirstSeen(
        nodeId: ByteArray,
        signingPub: ByteArray,
        acceptedStatic: ByteArray,
        acceptedGeneration: Long,
        trustCode: Int
    ): Int {
        val db = helper.writableDatabase
        return db.compileStatement(PeerIdentitySchema.INSERT_FIRST_SEEN_SQL).use { stmt: SQLiteStatement ->
            stmt.bindBlob(1, nodeId)
            stmt.bindBlob(2, signingPub)
            stmt.bindBlob(3, acceptedStatic)
            stmt.bindLong(4, acceptedGeneration)
            stmt.bindLong(5, trustCode.toLong())
            stmt.executeUpdateDelete()
        }
    }

    override fun setInitialPendingGuarded(
        nodeId: ByteArray,
        signingPub: ByteArray,
        acceptedStatic: ByteArray,
        acceptedGeneration: Long,
        trustLevel: Int,
        newPendingStatic: ByteArray,
        newPendingGeneration: Long
    ): Int {
        val db = helper.writableDatabase
        return db.compileStatement(PeerIdentitySchema.SET_INITIAL_PENDING_SQL).use { stmt: SQLiteStatement ->
            stmt.bindBlob(1, newPendingStatic)
            stmt.bindLong(2, newPendingGeneration)
            stmt.bindBlob(3, nodeId)
            stmt.bindBlob(4, signingPub)
            stmt.bindBlob(5, acceptedStatic)
            stmt.bindLong(6, acceptedGeneration)
            stmt.bindLong(7, trustLevel.toLong())
            stmt.executeUpdateDelete()
        }
    }

    override fun advancePendingGuarded(
        nodeId: ByteArray,
        signingPub: ByteArray,
        acceptedStatic: ByteArray,
        acceptedGeneration: Long,
        trustLevel: Int,
        oldPendingStatic: ByteArray,
        oldPendingGeneration: Long,
        newPendingStatic: ByteArray,
        newPendingGeneration: Long
    ): Int {
        val db = helper.writableDatabase
        return db.compileStatement(PeerIdentitySchema.ADVANCE_PENDING_SQL).use { stmt: SQLiteStatement ->
            stmt.bindBlob(1, newPendingStatic)
            stmt.bindLong(2, newPendingGeneration)
            stmt.bindBlob(3, nodeId)
            stmt.bindBlob(4, signingPub)
            stmt.bindBlob(5, acceptedStatic)
            stmt.bindLong(6, acceptedGeneration)
            stmt.bindLong(7, trustLevel.toLong())
            stmt.bindBlob(8, oldPendingStatic)
            stmt.bindLong(9, oldPendingGeneration)
            stmt.executeUpdateDelete()
        }
    }

    override fun approvePendingRotationGuarded(
        nodeId: ByteArray,
        signingPub: ByteArray,
        acceptedStatic: ByteArray,
        acceptedGeneration: Long,
        trustLevel: Int,
        expectedPendingStatic: ByteArray,
        expectedPendingGeneration: Long
    ): Int {
        val db = helper.writableDatabase
        return db.compileStatement(PeerIdentitySchema.APPROVE_PENDING_ROTATION_SQL).use { stmt: SQLiteStatement ->
            stmt.bindBlob(1, nodeId)
            stmt.bindBlob(2, signingPub)
            stmt.bindBlob(3, acceptedStatic)
            stmt.bindLong(4, acceptedGeneration)
            stmt.bindLong(5, trustLevel.toLong())
            stmt.bindBlob(6, expectedPendingStatic)
            stmt.bindLong(7, expectedPendingGeneration)
            stmt.executeUpdateDelete()
        }
    }

    override fun revokePeerGuarded(
        nodeId: ByteArray,
        signingPub: ByteArray,
        acceptedStatic: ByteArray,
        acceptedGeneration: Long,
        currentTrustLevel: Int,
        oldPendingStatic: ByteArray?,
        oldPendingGeneration: Long?
    ): Int {
        val db = helper.writableDatabase
        return if (oldPendingStatic != null && oldPendingGeneration != null) {
            db.compileStatement(PeerIdentitySchema.REVOKE_WITH_PENDING_SQL).use { stmt: SQLiteStatement ->
                stmt.bindBlob(1, nodeId)
                stmt.bindBlob(2, signingPub)
                stmt.bindBlob(3, acceptedStatic)
                stmt.bindLong(4, acceptedGeneration)
                stmt.bindLong(5, currentTrustLevel.toLong())
                stmt.bindBlob(6, oldPendingStatic)
                stmt.bindLong(7, oldPendingGeneration)
                stmt.executeUpdateDelete()
            }
        } else {
            db.compileStatement(PeerIdentitySchema.REVOKE_NO_PENDING_SQL).use { stmt: SQLiteStatement ->
                stmt.bindBlob(1, nodeId)
                stmt.bindBlob(2, signingPub)
                stmt.bindBlob(3, acceptedStatic)
                stmt.bindLong(4, acceptedGeneration)
                stmt.bindLong(5, currentTrustLevel.toLong())
                stmt.executeUpdateDelete()
            }
        }
    }

    override fun close() {
        helper.close()
    }

    private class Helper(ctx: Context, key: ByteArray) :
        SQLiteOpenHelper(
            ctx,
            PeerIdentitySchema.DB_NAME,
            key,
            null,
            PeerIdentitySchema.DB_VERSION,
            1,
            null,
            null,
            false
        ) {

        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL(PeerIdentitySchema.CREATE_TABLE_SQL)
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            // Peer trust contains irreplaceable TOFU, USER_VERIFIED, and quarantine state.
            // Destructive drop-and-recreate is strictly forbidden.
            throw IllegalStateException(
                "Unimplemented peer store schema migration from version $oldVersion to $newVersion"
            )
        }

        override fun onDowngrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            // Downgrades must fail closed unconditionally.
            throw IllegalStateException(
                "Downgrade not supported for peer store from version $oldVersion to $newVersion"
            )
        }

        override fun onOpen(db: SQLiteDatabase) {
            // Validate exact DDL fingerprint on every open to prevent operating on malformed stores.
            PeerIdentitySchema.validateSchema(db)
        }
    }

    companion object {
        /**
         * Manage dedicated 32-byte CSPRNG passphrase in EncryptedSharedPreferences.
         */
        internal fun getOrCreatePassphrase(ctx: Context): ByteArray {
            val dbFile: File = ctx.getDatabasePath(PeerIdentitySchema.DB_NAME)
            val dbExists = dbFile.exists()

            val master = MasterKey.Builder(ctx)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            val prefs = EncryptedSharedPreferences.create(
                ctx,
                PeerIdentitySchema.KEY_PREFS,
                master,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )

            val stored = prefs.getString("k", null)
            return PeerStoreKeyState.resolve(
                dbExists = dbExists,
                storedEncodedKey = stored,
                generate = { ByteArray(32).also { SecureRandom().nextBytes(it) } },
                persist = { encoded -> prefs.edit().putString("k", encoded).commit() }
            )
        }

        /**
         * Panic wipe (ADR-004 criterion 5, Phase C8.2C).
         * Deletes the peer identity database, its sidecar files (-wal, -shm, -journal),
         * and the dedicated encryption key preference file.
         * Fails closed if deletion of existing files fails.
         * Never recreates the key or database. Idempotent.
         */
        fun panicWipe(ctx: Context) {
            ctx.deleteDatabase(PeerIdentitySchema.DB_NAME)
            ctx.deleteSharedPreferences(PeerIdentitySchema.KEY_PREFS)
            val dbFile = ctx.getDatabasePath(PeerIdentitySchema.DB_NAME)
            if (dbFile.exists()) {
                throw IllegalStateException("Failed to delete peer identity database during panic wipe")
            }
            listOf("-wal", "-shm", "-journal").forEach { ext ->
                val sidecar = File(dbFile.path + ext)
                if (sidecar.exists()) {
                    sidecar.delete()
                }
            }
        }
    }
}
