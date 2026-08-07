plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    // MeshService is @AndroidEntryPoint-injected (audit P0-02: the node is
    // injected, not fetched from a holder). The :mesh module therefore needs
    // Hilt + KSP, mirroring :app. Plugin versions are pinned once in the root
    // build.gradle.kts (apply false); here they are applied unversioned.
    id("com.google.dagger.hilt.android")
    id("com.google.devtools.ksp")
}

android {
    namespace = "io.godstone.mesh"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation(project(":core"))
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // Hilt for MeshService's @AndroidEntryPoint + @Inject (javax.inject.Inject
    // arrives transitively via dagger). Versions match :app (Hilt 2.52).
    implementation("com.google.dagger:hilt-android:2.52")
    ksp("com.google.dagger:hilt-compiler:2.52")

    // Noise Protocol Framework, Java reference implementation (Rhys Weatherley,
    // Southern Storm Software; MIT). The original coordinate
    // "com.southernstorm:noise-java" was NEVER published to Maven Central or any
    // public Maven repository (the author distributed source only -- see
    // rweather/noise-java issues #5 and #9). The build therefore could not
    // resolve :mesh:debugCompileClasspath (ModuleVersionNotFoundException,
    // demonstrated by evidence/android-phase0-online/gradle-phase0.log). The
    // re-published fork com.github.auties00:noise-java:1.0 is the same rweather
    // source, byte-compatible at the API surface -- it keeps the original
    // com.southernstorm.noise.{crypto,protocol} packages verbatim (verified by
    // inspecting the jar: CipherStatePair.class and HandshakeState.class live at
    // com/southernstorm/noise/protocol/), so NoiseSession.kt's imports resolve
    // unchanged. It is on Maven Central, so no new repository is required
    // (settings.gradle.kts already declares mavenCentral()). sha256 of the jar:
    // cd74c31ac946b1c83f4b27743cc5fd7178b2f61ef586590a2d9140b408c08246.
    implementation("com.github.auties00:noise-java:1.0")

    // BouncyCastle for BLAKE2s and Ed25519 where the platform lacks them.
    implementation("org.bouncycastle:bcprov-jdk18on:1.78.1")

    // Encrypted local storage for the message store (threat A6).
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("net.zetetic:sqlcipher-android:4.17.0")
    implementation("androidx.sqlite:sqlite:2.6.2")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("org.jetbrains.kotlin:kotlin-test:2.0.20")
    // Real on-disk SQLite for the durable-store tests (Stage 3 Phase E). The jar
    // ships native SQLite for the host OS, so SqliteMessageStoreTest runs the
    // real schema/eviction/dedup SQL in CI host unit tests with no device. The
    // same SQL is shared with the production SQLCipher engine via StoreSchema;
    // SQLCipher == SQLite + page encryption, so the SQL semantics are identical.
    // Test-only (testImplementation), in a non-shipping module -- never reaches
    // a shipping classpath.
    testImplementation("org.xerial:sqlite-jdbc:3.46.1.3")
}
