package io.godstone.mesh.store

import org.junit.Test
import kotlin.test.assertTrue
import kotlin.test.assertNotNull

/**
 * Structural pin for the A-06 plaintext-engine regression (Stage 3 Phase E).
 *
 * A-06 found that `net.zetetic:sqlcipher-android` was declared in build.gradle.kts
 * but never imported: the store used plain `android.database.sqlite`, so a seized
 * device exposed the whole message history in cleartext while the threat model
 * promised encryption. A declared dependency is not a control; only the import
 * that replaces the plaintext engine is.
 *
 * This test reflects on the production engine class and asserts its helper field
 * is the SQLCipher `SQLiteOpenHelper`, not the plain-Android one. It runs on the
 * host JVM without loading the native sqlcipher core (reflection on field types
 * does not invoke native code), so it lives in the repo-owned green path. A
 * future regression that swaps the engine back to `android.database.sqlite`
 * makes this test fail -- the closure cannot revert silently.
 *
 * What this test does NOT prove: that the on-disk file is actually encrypted.
 * That is a device/instrumented concern (the SQLCipher native core + Keystore
 * must initialise). The SQL invariants (schema, dedup, bounded capacity, SOS
 * retention) are proven host-side in [SqliteMessageStoreTest]; the encryption is
 * pinned structurally here and verified on device.
 */
class StoreEngineTest {

    @Test
    fun `production store engine is SQLCipher not plain Android SQLite`() {
        // Do NOT initialize the class: SqlcipherStoreDb's <init> calls
        // System.loadLibrary("sqlcipher"), which has no host native core. Reflection
        // on declared field types does not run <init>, so this is host-safe.
        val cls = Class.forName(
            "io.godstone.mesh.store.SqlcipherStoreDb", /*initialize=*/ false,
            this::class.java.classLoader,
        )
        val helperField = cls.declaredFields.firstOrNull {
            it.type.name.endsWith("SQLiteOpenHelper")
        }
        assertNotNull(helperField, "SqlcipherStoreDb must hold a SQLiteOpenHelper helper")
        assertTrue(
            helperField.type.name.startsWith("net.zetetic.database.sqlcipher"),
            "production engine must use net.zetetic.database.sqlcipher, not " +
                "android.database.sqlite; was ${helperField.type.name}",
        )
    }

    @Test
    fun `production engine type is resolvable on the classpath`() {
        // The sqlcipher Java classes are on the :mesh compile classpath; this
        // confirms the dependency is actually wired (not merely declared in a
        // .kts that the build never resolved). initialize=false: no native load.
        val cls = Class.forName(
            "io.godstone.mesh.store.SqlcipherStoreDb", /*initialize=*/ false,
            this::class.java.classLoader,
        )
        assertTrue(cls.name == "io.godstone.mesh.store.SqlcipherStoreDb")
    }
}