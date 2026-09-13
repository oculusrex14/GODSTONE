package io.godstone.core.archive

import androidx.sqlite.SQLiteDriver

/**
 * The driver seam of the Archive read path (s17).
 *
 * Platform SQLite's FTS5 availability is NOT a portable contract: devices
 * ship whatever the platform felt like. The LIGHT shipping classpath
 * therefore carries its OWN bundled SQLite (androidx.sqlite, pinned in
 * the build file) and nothing on this path may reach for
 * `android.database.*`. The concrete driver is installed by the app
 * wiring (out of band, at process start) so that `:core` main compiles
 * against the stable interfaces only; the host readiness court installs
 * the very same driver class built for the host, which is what lets the
 * court prove the ACTUAL engine answers on both roads.
 */
object ArchiveDrivers {
    @Volatile
    private var provider: (() -> SQLiteDriver)? = null

    /** Install (or replace) the driver provider. The provider is a
     * thunk: the driver object -- and with it the native library load --
     * is created only at first use, never at class-init of the wiring. */
    fun install(provider: () -> SQLiteDriver) {
        this.provider = provider
    }

    /** The driver for this process. Throws when the wiring was skipped;
     * there is no silent fallback to the platform, by design. */
    fun required(): SQLiteDriver {
        val p = provider
        if (p === null) {
            throw IllegalStateException(
                "no bundled SQLite driver installed; the Archive read path " +
                    "refuseth to fall back to the platform sqlite")
        }
        return p()
    }

    /** Test-only: forget the installed provider (courts re-install their own). */
    fun clearForTesting() {
        provider = null
    }
}
