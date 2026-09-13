plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.godstone.core"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("org.bouncycastle:bcprov-jdk18on:1.78.1")

    // T47 (s17): the Archive read path rideth on the PINNED AndroidX
    // BUNDLED SQLite, not on the platform engine whose FTS5 availability
    // is not a portable contract. The interfaces live in :sqlite; the
    // concrete driver is installed out of band by the app wiring
    // (ArchiveDrivers), which is why :core compileth against the
    // interfaces alone. The readiness court installseth the very same
    // driver class built for the host (-bundled-jvm), so the court
    // proveth the ACTUAL engine answers on both roads.
    implementation("androidx.sqlite:sqlite:2.5.2")

    testImplementation("junit:junit:4.13.2")
    testImplementation("androidx.sqlite:sqlite-bundled-jvm:2.5.2")
}
