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
    fun execRawSql(sql: String)

    fun close()
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

    override fun execRawSql(sql: String) {
        helper.writableDatabase.execSQL(sql)
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
         *
         * Key-State Matrix:
         * A. key absent + DB absent -> generate 32 bytes, commit synchronously, open DB.
         * B. key present + DB absent -> decode exact 32 bytes, create DB.
         * C. key present + DB present -> decode exact 32 bytes, open DB.
         * D. key absent + DB present -> FAIL CLOSED (do not regenerate replacement key!).
         * E. malformed Base64 -> FAIL CLOSED.
         * F. decoded key length != 32 -> FAIL CLOSED.
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
            if (stored != null) {
                val decoded: ByteArray
                try {
                    decoded = android.util.Base64.decode(stored, android.util.Base64.NO_WRAP)
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
            val key = ByteArray(32).also { SecureRandom().nextBytes(it) }
            val encoded = android.util.Base64.encodeToString(key, android.util.Base64.NO_WRAP)
            val committed = prefs.edit().putString("k", encoded).commit()
            if (!committed) {
                throw IllegalStateException("Failed to synchronously commit peer identity store key")
            }
            return key
        }
    }
}
