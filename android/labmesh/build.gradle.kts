// ---------------------------------------------------------------------------
// T54 -- the nonshipping LabMesh Android target.
//
// The shipped app intentionally excludes the mesh runtime: `:app` carrieth one
// application identity (io.godstone.app), one shippable tier, and NO `:mesh` /
// `:llm` edge on a shipping configuration. Testing complete product flows needs
// the REAL composition, though, so this module buildeth a SEPARATE application
// with:
//
//   * its own applicationId (io.godstone.labmesh) -- a lab install can never be
//     confused with, nor upgraded over, the shipping identity;
//   * dependencies on the SAME canonical components the mesh tests use
//     (`:core`, `:mesh`), never a copy or a stub;
//   * NO synthetic READY setter: it cannot manufacture crypto readiness, and the
//     readiness flags stay false everywhere (T54's gate asserteth this).
//
// It is NOT a product flavour of `:app`. scripts/check_tiers.py requires Gradle to
// declare EXACTLY the shipping tiers, and a lab flavour would either ship a
// non-shipping tier or force that invariant open; a separate module keeps the
// shipping graph untouched. ci/check_lab_isolation.py resolveth both profiles
// from this file and :app's, and fails if a lab source set or a readiness
// override ever reaches the LIGHT release.
// ---------------------------------------------------------------------------
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.godstone.labmesh"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.godstone.labmesh"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.0.0-lab"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // the lab profile is visible to the runtime AND to a reader of the
        // artifact: a build that claimeth LIGHT may not carry this
        buildConfigField("String", "PROFILE", "\"LABMESH\"")
        buildConfigField("boolean", "EXPERIMENTAL", "true")
        buildConfigField("boolean", "MANUFACTURES_READINESS", "false")
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // the SAME canonical runtime components the shipping app would use, never a
    // lab-only twin
    implementation(project(":core"))
    implementation(project(":mesh"))

    testImplementation("junit:junit:4.13.2")
    // the SAME test stack :mesh's own courts use, so the lab adds no new
    // third-party artifact to the pinned supply-chain set
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("org.jetbrains.kotlin:kotlin-test:2.0.20")
}
